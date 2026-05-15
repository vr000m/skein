"""Filesystem primitives for the conduct skill (stdlib only).

This module holds I/O helpers that are layered below ``conductor.py``: the
atomic-write adapter used by the ci-parity result-file persistence path, and
a ``plan_id`` shape validator that gates any filesystem path derived from
on-disk state. Both helpers are stdlib-only and have no conductor-specific
dependencies — they live here so they can be unit-tested without importing
the 1000+-line conductor module, and so future I/O primitives have an
obvious home.
"""

from __future__ import annotations

import os
import re
import stat
import tempfile
from pathlib import Path


_PLAN_ID_RE = re.compile(r"^[a-f0-9]{12}$")
MAX_RESULT_FILE_BYTES = 1024 * 1024


class InvalidPlanIdError(ValueError):
    """Raised when a value claiming to be a ``plan_id`` does not match the
    canonical 12-char lowercase-hex shape emitted by
    ``_compute_cross_runtime_plan_id``.

    A ``plan_id`` is used to construct filesystem paths under ``.conduct/``;
    accepting any string from on-disk state would let a state-file containing
    ``../`` segments escape the directory. Validating shape at the entry of
    every helper that touches the filesystem is the defence-in-depth check.
    """


def validate_plan_id(plan_id: str) -> str:
    """Return ``plan_id`` unchanged when it matches the canonical shape.

    Raises ``InvalidPlanIdError`` otherwise. Used by both the read-path
    (preflight) and write-path (orchestrator-owned result persistence) so
    that any path derived from ``plan_id`` is byte-bounded.
    """
    if not isinstance(plan_id, str) or not _PLAN_ID_RE.match(plan_id):
        raise InvalidPlanIdError(
            f"plan_id must match {_PLAN_ID_RE.pattern}; got {plan_id!r}"
        )
    return plan_id


def atomic_write_result_file(path: Path, text: str) -> None:
    """Crash-safe write for the ci-parity result file.

    Writes ``text`` to a tmp file in ``path``'s parent directory created via
    ``tempfile.mkstemp`` (``O_CREAT | O_EXCL | O_RDWR``, unpredictable
    suffix), ``fsync``s, closes, and then ``os.replace``s onto ``path``
    (atomic on POSIX). The tmp file is unlinked on any failure between
    create and replace so preflight observes ``absent`` rather than a stray
    tmp.

    Properties this guarantees that the previous in-conductor implementation
    did not:

      * Unique tmp name regardless of timing — ``mkstemp`` uses an
        unpredictable suffix and ``O_EXCL`` semantics, so two writes in the
        same wall-clock second from the same PID cannot collide on the tmp
        path.
      * No silent overwrite of a pre-placed tmp file — ``O_EXCL`` rejects
        any existing file at the chosen tmp path.
    """
    parent = path.parent
    parent.mkdir(parents=True, exist_ok=True)
    # ``mkstemp`` returns an open fd + path; both are owned by us. Suffix
    # ``.tmp`` makes the role obvious if a crash leaves a stray.
    fd, tmp_name = tempfile.mkstemp(
        prefix=path.name + ".",
        suffix=".tmp",
        dir=str(parent),
    )
    tmp_path = Path(tmp_name)
    try:
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                fh.write(text)
                fh.flush()
                os.fsync(fh.fileno())
        except BaseException:
            # ``fdopen`` may have raised before taking ownership of ``fd``;
            # close defensively if it's still open.
            try:
                os.close(fd)
            except OSError:
                pass
            raise
        os.replace(str(tmp_path), str(path))
    except BaseException:
        try:
            if tmp_path.exists():
                tmp_path.unlink()
        except OSError:
            pass
        raise


def read_result_file(
    path: Path, max_bytes: int = MAX_RESULT_FILE_BYTES
) -> tuple[str, float]:
    """Read a ci-parity result file through a non-following fd.

    Returns ``(text, mtime)`` from the same opened file descriptor, avoiding
    the separate ``is_symlink`` / ``read_text`` / ``stat`` race. The size cap
    prevents a repo-local process from forcing unbounded memory use on resume.
    """
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(str(path), flags)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise OSError(f"not a regular file: {path}")
        if info.st_size > max_bytes:
            raise OSError(f"ci-parity result file exceeds {max_bytes} bytes: {path}")
        data = os.read(fd, max_bytes + 1)
        if len(data) > max_bytes:
            raise OSError(f"ci-parity result file exceeds {max_bytes} bytes: {path}")
        return data.decode("utf-8"), info.st_mtime
    finally:
        os.close(fd)


def ensure_under_directory(path: Path, root: Path) -> None:
    """Raise ``ValueError`` if ``path`` (resolved) is not under ``root``.

    Resolves both sides and uses ``Path.is_relative_to`` (Python ≥ 3.9) so
    that ``..`` segments in ``path`` cannot escape ``root``. The previous
    parents-set check accepted ``.conduct/foo/../../escape.json`` because
    the literal ``.conduct`` component remained in ``path.parents``.
    """
    resolved_path = path.resolve(strict=False)
    resolved_root = root.resolve(strict=False)
    if not resolved_path.is_relative_to(resolved_root):
        raise ValueError(f"path must live under {resolved_root}: {resolved_path}")
