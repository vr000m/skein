"""Tests for the test-runner subprocess wrapper."""

from __future__ import annotations

import shlex
import sys
import time
from pathlib import Path

from conduct.runner import run_tests


def test_run_tests_zero_exit_returns_zero():
    result = run_tests("true", timeout=5)
    assert result.returncode == 0
    assert result.timed_out is False


def test_run_tests_non_zero_exit_propagates():
    result = run_tests("false", timeout=5)
    assert result.returncode != 0
    assert result.timed_out is False


def test_run_tests_captures_stdout_and_stderr():
    result = run_tests("echo out; echo err >&2", timeout=5)
    assert "out" in result.output
    assert "err" in result.output


def test_run_tests_timeout_kills_long_command():
    result = run_tests("sleep 10", timeout=0.5)
    assert result.timed_out is True
    assert result.returncode == -1
    assert "exceeded" in result.output
    assert result.duration_seconds < 5  # killed promptly


def test_run_tests_shell_features_work():
    # Pipes / && rely on shell=True.
    result = run_tests("echo hello | tr a-z A-Z && echo done", timeout=5)
    assert result.returncode == 0
    assert "HELLO" in result.output
    assert "done" in result.output


def test_run_tests_timeout_kills_descendant_processes(tmp_path: Path):
    leak = tmp_path / "leak.txt"
    child = (
        "import pathlib, time; "
        f"time.sleep(1); pathlib.Path({str(leak)!r}).write_text('leaked')"
    )
    command = (
        f"{shlex.quote(sys.executable)} -c "
        f"{shlex.quote(f'import subprocess, sys, time; subprocess.Popen([sys.executable, \"-c\", {child!r}]); time.sleep(10)')}"
    )
    result = run_tests(command, timeout=0.2)
    assert result.timed_out is True
    time.sleep(1.3)
    assert not leak.exists()
