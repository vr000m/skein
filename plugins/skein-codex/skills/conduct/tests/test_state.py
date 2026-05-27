"""Tests for state-file schema round-trip and lockfile semantics.

The schema test asserts the JSON round-trip for the documented keys; it does
not assert against any runtime code that writes the state file (main Codex
writes it via the skill flow). Lock tests exercise acquire, release,
contention, flock safety, and stale fallback-lockdir handling on
``lock.StateLock``.
"""

from __future__ import annotations

import json
import os
import time
from pathlib import Path

import pytest

from conduct.lock import STALE_SECONDS, LockError, StateLock, lock_is_held, main as lock_main


STATE_REQUIRED_KEYS = {
    "schema_version",
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
    "paused_stash_rev",
}


def test_state_schema_round_trip(tmp_path: Path):
    state = {
        "schema_version": 2,
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
        "paused_stash_rev": None,
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


def test_old_flock_lockfile_does_not_split_lock_ownership(tmp_path: Path):
    lockfile = tmp_path / "state.json.lock"
    first = StateLock(lockfile)
    first.acquire()
    old = time.time() - (STALE_SECONDS + 60)
    os.utime(lockfile, (old, old))
    try:
        with pytest.raises(LockError):
            StateLock(lockfile).acquire()
    finally:
        first.release()


def test_stale_fallback_lockdir_breaks_when_owner_dead(tmp_path: Path, monkeypatch):
    monkeypatch.setattr("conduct.lock.fcntl", None)
    lockfile = tmp_path / "state.json.lock"
    lockdir = lockfile.with_suffix(lockfile.suffix + ".lockdir")
    lockdir.mkdir()
    (lockdir / "pid").write_text("999999\n")
    old = time.time() - (STALE_SECONDS + 60)
    os.utime(lockdir, (old, old))
    with StateLock(lockfile):
        pass


def test_lock_cli_rejects_release_action():
    assert lock_main(["lock.py", "release", "state.json.lock"]) == 2


def test_lock_is_held_returns_false_when_lockfile_disappears_before_open(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
):
    lockfile = tmp_path / "state.json.lock"
    lockfile.write_text("")
    original_open = os.open

    def flaky_open(path: str, flags: int, mode: int = 0o777):
        if Path(path) == lockfile:
            raise FileNotFoundError
        return original_open(path, flags, mode)

    monkeypatch.setattr("conduct.lock.os.open", flaky_open)
    assert lock_is_held(lockfile) is False
