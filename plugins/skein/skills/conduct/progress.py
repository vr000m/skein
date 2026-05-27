"""Progress-aware fix-loop helpers for the conductor.

This module provides three primitives used by ``conductor._check_iteration_bound``
to decide whether an iteration represents real progress or a stall:

- ``iteration_signature(failing_tests, staged_diff_stat) -> str``: pure SHA-1
  over a canonical JSON envelope. Two consecutive identical signatures across
  fix-loop iterations indicate the implementer is producing byte-identical
  output (a "stall").
- ``compute_staged_diff_stat(repo_root) -> str``: shells out to ``git diff
  --cached`` using either ``--stat -w`` (preferred, collapses pure-whitespace
  edits) or ``--name-only`` (deterministic-sort fallback). The choice is fixed
  for the lifetime of the process by the module-level probe below.
- Module-level probe: at import time, runs ``git diff --cached --stat -w``
  against the empty staging area of a throwaway repo to detect whether the
  installed git version accepts the flag combination. On any failure (probe
  raises, returns non-zero, or stderr contains "unknown option") sets
  ``_USE_STAT_W = False`` and emits a one-shot ``warnings.warn`` so callers
  (and tests) can observe the decision. The decision is sticky for the
  lifetime of the Python process.

Stdlib-only. No third-party imports.
"""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import tempfile
import warnings
from pathlib import Path


# ---------------------------------------------------------------------------
# Module-level --stat -w probe (sticky for process lifetime)
# ---------------------------------------------------------------------------


def _probe_stat_w() -> bool:
    """Return True iff ``git diff --cached --stat -w`` is accepted.

    Runs the probe against a throwaway repo with an empty staging area so the
    output is uninteresting; we only care whether git rejects the flag combo.
    Tolerant of being run in an environment without git on PATH or without a
    usable tempdir — both cases fall back to ``_USE_STAT_W = False`` so module
    import never raises.
    """
    try:
        with tempfile.TemporaryDirectory() as td:
            # Initialise a minimal repo so ``git diff --cached`` has somewhere
            # to look. ``git init -q`` is portable across the supported git
            # versions.
            init = subprocess.run(
                ["git", "init", "-q", td],
                capture_output=True,
                text=True,
                check=False,
            )
            if init.returncode != 0:
                return False
            proc = subprocess.run(
                ["git", "-C", td, "diff", "--cached", "--stat", "-w"],
                capture_output=True,
                text=True,
                check=False,
            )
            if proc.returncode != 0:
                return False
            if "unknown option" in (proc.stderr or "").lower():
                return False
            return True
    except (OSError, subprocess.SubprocessError, FileNotFoundError):
        return False


_USE_STAT_W: bool = _probe_stat_w()

if not _USE_STAT_W:
    warnings.warn(
        "conduct.progress: `git diff --cached --stat -w` unavailable; "
        "falling back to `git diff --cached --name-only | sort` for "
        "diff-stat canonicalisation (sticky for process lifetime).",
        RuntimeWarning,
        stacklevel=2,
    )


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def iteration_signature(failing_tests: list[str], staged_diff_stat: str) -> str:
    """Return SHA-1 hex over canonical JSON of (sorted tests, hashed diff-stat).

    Two consecutive identical signatures across fix-loop iterations indicate a
    stall: the failing test set has not changed AND the staged diff stat has
    not changed. Inputs are normalised before hashing so semantically-identical
    inputs from differently-ordered sources collide.
    """
    diff_stat_hash = hashlib.sha1(staged_diff_stat.encode("utf-8")).hexdigest()
    envelope = json.dumps(
        {"tests": sorted(failing_tests), "diff_stat_hash": diff_stat_hash},
        sort_keys=True,
    )
    return hashlib.sha1(envelope.encode("utf-8")).hexdigest()


def compute_staged_diff_stat(repo_root: Path | str) -> str:
    """Return the canonical staged-diff representation for this process.

    Stat mode (``_USE_STAT_W=True``): ``git -C <repo_root> diff --cached
    --stat -w`` so pure-whitespace edits collapse against content edits in the
    same file.

    Fallback mode (``_USE_STAT_W=False``): ``git -C <repo_root> diff --cached
    --name-only`` piped through Python's ``sorted()`` for deterministic order
    independent of git's report order.

    Returns an empty string if git itself fails (missing binary, repo
    corruption, etc.) so the caller still gets a stable signature input.
    """
    cwd = os.fspath(repo_root)
    if _USE_STAT_W:
        cmd = ["git", "-C", cwd, "diff", "--cached", "--stat", "-w"]
    else:
        cmd = ["git", "-C", cwd, "diff", "--cached", "--name-only"]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    except (OSError, subprocess.SubprocessError):
        return ""
    if proc.returncode != 0:
        return ""
    output = proc.stdout or ""
    if _USE_STAT_W:
        return output
    # Fallback: deterministic sort of newline-separated file list.
    lines = [ln for ln in output.splitlines() if ln]
    return "\n".join(sorted(lines)) + ("\n" if lines else "")
