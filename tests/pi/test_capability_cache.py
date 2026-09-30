"""Capability absence is cached only when stable and fingerprint-matched."""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[2] / "plugins/skein-pi/lib"))

import capability_cache


def test_stable_absence_round_trip_and_fingerprint_invalidation(tmp_path):
    path = tmp_path / ".review-plan" / "capabilities.json"
    current = capability_cache.fingerprint({"pi": "0.87.1", "gate": "absent"})
    capability_cache.record(path, "security-review", current, "gate_not_installed")
    assert capability_cache.load(path, "security-review", current) == {
        "status": "unavailable",
        "reason": "gate_not_installed",
    }
    changed = capability_cache.fingerprint({"pi": "0.87.2", "gate": "absent"})
    assert capability_cache.load(path, "security-review", changed) is None
    assert (path.stat().st_mode & 0o777) == 0o600
    assert (path.parent.stat().st_mode & 0o777) == 0o700


def test_corrupt_cache_and_transient_outcomes_are_not_reused(tmp_path):
    path = tmp_path / "capabilities.json"
    path.write_text("not json")
    assert capability_cache.load(path, "gate", "fp") is None
    payload = {
        "schema_version": 1,
        "entries": {
            "gate": {"status": "timeout", "fingerprint": "fp", "reason": "slow"}
        },
    }
    path.write_text(json.dumps(payload))
    assert capability_cache.load(path, "gate", "fp") is None


def test_symlinked_cache_directory_is_refused(tmp_path):
    outside = tmp_path / "outside"
    outside.mkdir()
    cache_dir = tmp_path / ".review-plan"
    cache_dir.symlink_to(outside, target_is_directory=True)
    try:
        capability_cache.record(
            cache_dir / "capabilities.json", "gate", "fp", "missing"
        )
    except ValueError as error:
        assert "symlink" in str(error)
    else:
        raise AssertionError("symlinked capability cache path was accepted")
    assert not (outside / "capabilities.json").exists()


def test_refresh_removes_cache_and_rejects_empty_entries(tmp_path):
    path = tmp_path / "capabilities.json"
    capability_cache.record(path, "gate", "fp", "missing_executable")
    capability_cache.clear(path)
    assert not path.exists()
    try:
        capability_cache.record(path, "", "fp", "reason")
    except ValueError:
        pass
    else:
        raise AssertionError("empty capability key was accepted")
