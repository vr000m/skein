"""Filesystem primitives for the Codex conduct skill."""

from __future__ import annotations

import os
import re
import stat
import tempfile
from pathlib import Path

_PLAN_ID_RE = re.compile(r"^[a-f0-9]{12}$")
MAX_RESULT_FILE_BYTES = 1024 * 1024


class InvalidPlanIdError(ValueError):
    """Raised when a ``plan_id`` is not the canonical 12-char lowercase hex."""


def validate_plan_id(plan_id: str) -> str:
    if not isinstance(plan_id, str) or not _PLAN_ID_RE.fullmatch(plan_id):
        raise InvalidPlanIdError(
            f"plan_id must match {_PLAN_ID_RE.pattern}; got {plan_id!r}"
        )
    return plan_id


def ensure_direct_child(path: Path, parent: Path) -> None:
    resolved_path = path.resolve(strict=False)
    resolved_parent = parent.resolve(strict=False)
    if resolved_path.parent != resolved_parent:
        raise ValueError(
            f"path must live directly under {resolved_parent}: {resolved_path}"
        )


def atomic_write_result_file(path: Path, text: str) -> None:
    parent = path.parent
    parent.mkdir(parents=True, exist_ok=True)
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
