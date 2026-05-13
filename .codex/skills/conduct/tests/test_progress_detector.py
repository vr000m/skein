from __future__ import annotations

import hashlib
import importlib
import json
import subprocess
import sys
from pathlib import Path

import pytest


def _progress_module():
    try:
        return importlib.import_module("conduct.progress")
    except ModuleNotFoundError as exc:
        pytest.fail(f"conduct.progress module is missing: {exc}")


def _expected_signature(failing_tests: list[str], staged_diff_stat: str) -> str:
    payload = {
        "tests": sorted(failing_tests),
        "diff_stat_hash": hashlib.sha1(staged_diff_stat.encode("utf-8")).hexdigest(),
    }
    return hashlib.sha1(json.dumps(payload, sort_keys=True).encode("utf-8")).hexdigest()


def test_iteration_signature_is_order_insensitive_for_failing_tests():
    progress = _progress_module()

    assert progress.iteration_signature(["b", "a"], " src/a.py | 1 +\n") == progress.iteration_signature(
        ["a", "b"], " src/a.py | 1 +\n"
    )


def test_iteration_signature_changes_when_failing_tests_change():
    progress = _progress_module()

    assert progress.iteration_signature(["tests/test_a.py::test_a"], "same") != progress.iteration_signature(
        ["tests/test_b.py::test_b"], "same"
    )


def test_iteration_signature_changes_when_diff_stat_changes():
    progress = _progress_module()

    assert progress.iteration_signature(["same"], " src/a.py | 1 +\n") != progress.iteration_signature(
        ["same"], " src/a.py | 2 ++\n"
    )


def test_iteration_signature_hashes_canonical_json_payload():
    progress = _progress_module()
    staged_diff_stat = " src/a.py | 2 ++\n"
    failing_tests = ["z", "a"]

    assert progress.iteration_signature(failing_tests, staged_diff_stat) == _expected_signature(
        failing_tests, staged_diff_stat
    )


def test_iteration_signature_handles_empty_failure_list():
    progress = _progress_module()

    assert progress.iteration_signature([], " src/a.py | 1 +\n") == _expected_signature(
        [], " src/a.py | 1 +\n"
    )


def test_iteration_signature_stat_w_fallback_warns_once_and_uses_name_only(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
):
    sys.modules.pop("conduct.progress", None)
    calls: list[list[str]] = []

    def fake_run(args, cwd=None, capture_output=True, text=True, check=False, **kwargs):
        calls.append(list(args))
        if args[:3] == ["git", "init", "-q"]:
            return subprocess.CompletedProcess(args, 0, stdout="", stderr="")
        if args[:3] == ["git", "-C", str(tmp_path)] and args[3:] == [
            "diff",
            "--cached",
            "--name-only",
        ]:
            return subprocess.CompletedProcess(args, 0, stdout="b.py\na.py\n", stderr="")
        if args[:2] == ["git", "-C"] and args[3:] == ["diff", "--cached", "--stat", "-w"]:
            return subprocess.CompletedProcess(args, 129, stdout="", stderr="error: unknown option `w'")
        raise AssertionError(f"unexpected command: {args!r}")

    monkeypatch.setattr(subprocess, "run", fake_run)

    with pytest.warns(RuntimeWarning, match="falling back"):
        progress = importlib.import_module("conduct.progress")
    assert progress._USE_STAT_W is False

    first = progress.compute_staged_diff_stat(tmp_path)
    second = progress.compute_staged_diff_stat(tmp_path)

    assert first == "a.py\nb.py\n"
    assert second == "a.py\nb.py\n"
    assert sum(call[3:] == ["diff", "--cached", "--stat", "-w"] for call in calls) == 1
    assert calls.count(["git", "-C", str(tmp_path), "diff", "--cached", "--name-only"]) == 2
