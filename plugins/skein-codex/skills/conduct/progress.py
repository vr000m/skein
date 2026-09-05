"""Progress-aware fix-loop helpers for the Codex conduct conductor."""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import tempfile
import warnings
from pathlib import Path


def _probe_stat_w() -> bool:
    """Return True when the installed git accepts `diff --cached --stat -w`."""
    try:
        with tempfile.TemporaryDirectory() as td:
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
            return (
                proc.returncode == 0
                and "unknown option" not in (proc.stderr or "").lower()
            )
    except (OSError, subprocess.SubprocessError):
        return False


_USE_STAT_W = _probe_stat_w()

if not _USE_STAT_W:
    warnings.warn(
        "conduct.progress: `git diff --cached --stat -w` unavailable; "
        "falling back to `git diff --cached --name-only | sort` for "
        "diff-stat canonicalisation (sticky for process lifetime).",
        RuntimeWarning,
        stacklevel=2,
    )


def iteration_signature(failing_tests: list[str], staged_diff_stat: str) -> str:
    """Return a stable SHA-1 signature for failure names plus staged diff stat."""
    diff_stat_hash = hashlib.sha1(staged_diff_stat.encode("utf-8")).hexdigest()
    envelope = json.dumps(
        {"tests": sorted(failing_tests), "diff_stat_hash": diff_stat_hash},
        sort_keys=True,
    )
    return hashlib.sha1(envelope.encode("utf-8")).hexdigest()


def compute_staged_diff_stat(repo_root: Path | str) -> str:
    """Return canonical staged-diff signal for progress/stall detection."""
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
    lines = [line for line in output.splitlines() if line]
    return "\n".join(sorted(lines)) + ("\n" if lines else "")
