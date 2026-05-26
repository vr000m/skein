"""Tests for state-file schema round-trip and lockfile semantics.

The schema test asserts the JSON round-trip for the documented keys; it does
not assert against any runtime code that writes the state file (main Claude
writes it via Bash in the skill flow). Lock tests exercise acquire, release,
contention, and stale-break behaviour on ``lock.StateLock``.
"""

from __future__ import annotations

import json
import os
import time
from pathlib import Path

import pytest

from lock import STALE_SECONDS, LockError, StateLock


STATE_REQUIRED_KEYS = {
    "plan_path",
    "plan_content_hash",
    "base_sha",
    "phase_index",
    "current_phase_title",
    "completed_phases",
    "last_summary",
    "iteration_count",
    "status",
    "blocker",
}


def test_state_schema_round_trip(tmp_path: Path):
    state = {
        "plan_path": "docs/dev_plans/example.md",
        "plan_content_hash": "a" * 40,
        "base_sha": "b" * 40,
        "phase_index": 2,
        "current_phase_title": "Scaffolding",
        "completed_phases": [
            {
                "index": 1,
                "label": "1",
                "title": "First",
                "commit_sha": "c" * 40,
                "tests": "passed",
                "iterations": 1,
            }
        ],
        "last_summary": "All good.",
        "iteration_count": 0,
        "status": "awaiting_user",
        "blocker": None,
    }
    assert STATE_REQUIRED_KEYS.issubset(state.keys())
    path = tmp_path / "state.json"
    path.write_text(json.dumps(state))
    loaded = json.loads(path.read_text())
    assert loaded == state


def test_lock_acquire_and_release_roundtrip(tmp_path: Path):
    lockfile = tmp_path / "state.json.lock"
    with StateLock(lockfile):
        assert lockfile.exists()
    # Released — second acquire must succeed.
    with StateLock(lockfile):
        pass


def test_lock_contention_raises(tmp_path: Path):
    lockfile = tmp_path / "state.json.lock"
    first = StateLock(lockfile)
    first.acquire()
    try:
        with pytest.raises(LockError):
            StateLock(lockfile).acquire()
    finally:
        first.release()


def test_lock_stale_break(tmp_path: Path):
    lockfile = tmp_path / "state.json.lock"
    # Manually plant a stale lockfile.
    lockfile.write_text(f"{os.getpid() ^ 0xDEAD}\n")
    old = time.time() - (STALE_SECONDS + 60)
    os.utime(lockfile, (old, old))
    # Acquire should break the stale lock rather than raise.
    with StateLock(lockfile):
        pass
