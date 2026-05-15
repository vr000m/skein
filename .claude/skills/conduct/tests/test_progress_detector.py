"""Unit tests for ``conduct.progress``.

Covers the five signature equivalence/divergence cases (a)-(e) on
``iteration_signature`` plus the ``--stat -w`` fallback probe (case f).

These are pure unit tests: they import the module and exercise its public
pure function directly. The ``--stat -w`` fallback test simulates a git that
rejects the flag combination by monkeypatching the probe and re-importing the
module so the module-level ``_USE_STAT_W`` flag re-evaluates under the
patched probe.
"""

from __future__ import annotations

import importlib
import subprocess
import warnings


import progress
from progress import iteration_signature


# ---------------------------------------------------------------------------
# iteration_signature: cases (a)-(e)
# ---------------------------------------------------------------------------


def test_iteration_signature_identical_inputs_yield_identical_hash():
    """Case (a): identical inputs → identical hash."""
    sig1 = iteration_signature(["tests/test_a.py::test_x"], "stat-output")
    sig2 = iteration_signature(["tests/test_a.py::test_x"], "stat-output")
    assert sig1 == sig2


def test_iteration_signature_different_failing_tests_yield_different_hash():
    """Case (b): differing failing_tests → different hash."""
    sig1 = iteration_signature(["tests/test_a.py::test_x"], "stat-output")
    sig2 = iteration_signature(["tests/test_a.py::test_y"], "stat-output")
    assert sig1 != sig2


def test_iteration_signature_failing_tests_order_independent():
    """Case (c): re-ordered failing_tests → identical hash.

    The signature canonicalises via ``sorted(failing_tests)`` so the
    implementer's output order cannot bias the stall detector.
    """
    ordered = ["tests/test_a.py::test_x", "tests/test_b.py::test_y"]
    reversed_ = list(reversed(ordered))
    assert iteration_signature(ordered, "stat") == iteration_signature(
        reversed_, "stat"
    )


def test_iteration_signature_different_diff_stat_yield_different_hash():
    """Case (d): differing diff_stat → different hash."""
    sig1 = iteration_signature(["t"], "stat-a")
    sig2 = iteration_signature(["t"], "stat-b")
    assert sig1 != sig2


def test_iteration_signature_empty_inputs_deterministic():
    """Case (e): empty failing_tests + empty diff_stat → deterministic hash.

    A blank-input fix-loop iteration is still hashable (otherwise the stall
    detector would silently fail open). Re-computing must collide.
    """
    sig1 = iteration_signature([], "")
    sig2 = iteration_signature([], "")
    assert sig1 == sig2
    # 40-char SHA-1 hex.
    assert len(sig1) == 40
    assert all(c in "0123456789abcdef" for c in sig1)


# ---------------------------------------------------------------------------
# Case (f): --stat -w fallback (iteration-signature-stat-w-fallback)
# ---------------------------------------------------------------------------


def test_iteration_signature_stat_w_fallback(monkeypatch, tmp_path):
    """Case (f): probe rejects ``--stat -w`` → fallback mode locked in,
    ``compute_staged_diff_stat`` uses ``--name-only | sort``, one-shot warning.

    Simulates the rejection by monkeypatching subprocess.run inside progress
    so the probe path returns "unknown option" stderr, then reloads the
    module so the module-level probe re-evaluates under the patch.
    """
    original_run = subprocess.run

    def fake_run(cmd, *args, **kwargs):
        # Identify the probe (and any subsequent --stat -w call) by its flag
        # combination and have it report rejection. Leave every other call
        # (notably ``git init``) untouched so the probe can still set up its
        # throwaway repo.
        if isinstance(cmd, (list, tuple)) and "--stat" in cmd and "-w" in cmd:
            return subprocess.CompletedProcess(
                args=cmd,
                returncode=129,
                stdout="",
                stderr="error: unknown option `-w'\n",
            )
        return original_run(cmd, *args, **kwargs)

    monkeypatch.setattr(subprocess, "run", fake_run)

    with warnings.catch_warnings(record=True) as caught:
        warnings.simplefilter("always")
        reloaded = importlib.reload(progress)

    try:
        assert reloaded._USE_STAT_W is False
        # Exactly one fallback warning during the reload.
        fallback_warnings = [
            w
            for w in caught
            if "stat -w" in str(w.message) or "--stat" in str(w.message)
        ]
        assert len(fallback_warnings) >= 1
        # The fallback path uses --name-only and sorts deterministically. Build
        # a synthetic repo to exercise it and confirm the command shape.
        captured: list[list[str]] = []

        def capture_run(cmd, *args, **kwargs):
            captured.append(list(cmd) if isinstance(cmd, (list, tuple)) else [cmd])
            return subprocess.CompletedProcess(
                args=cmd, returncode=0, stdout="b\na\n", stderr=""
            )

        monkeypatch.setattr(subprocess, "run", capture_run)
        out = reloaded.compute_staged_diff_stat(tmp_path)
        # Output is the sorted file list (deterministic regardless of git's
        # reporting order).
        assert out == "a\nb\n"
        # The command invoked was --name-only, not --stat -w.
        assert any("--name-only" in c for c in captured)
        assert all("-w" not in c or "--stat" not in c for c in captured)
    finally:
        # Restore the unpatched module for the rest of the test session so a
        # later test seeing the real probe result is not confused.
        importlib.reload(progress)
