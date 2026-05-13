"""Phase 2 autonomous-mode tests for the conductor.

Covers the `--autonomous` flag, the explicit phase loop, auto-advance under a
single lock acquisition, and the `--max-phases` safety cap. The CI-parity
gate lands in Phase 3 — these tests assert that with no gate present, the
post-loop fall-through is a plain ``status="complete"`` return.

Test fixture: ``LockAcquisitionCounter`` (defined in ``conftest.py``) wraps
``conductor.StateLock`` so we can assert one acquisition per autonomous run
vs. one per ``--resume`` in legacy mode.
"""

from __future__ import annotations

import json
import subprocess
import textwrap
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

import pytest

from conductor import ConductOptions, SpawnRequest, conduct
from marker import write_marker
from runner import TestResult as _TestResult


# ---------------------------------------------------------------------------
# Shared scaffolding (mirrors test_conductor_harness.py patterns)
# ---------------------------------------------------------------------------


def _git(args: list[str], cwd: Path, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", *args], cwd=str(cwd), capture_output=True, text=True, check=check
    )


@pytest.fixture
def repo(tmp_path: Path) -> Path:
    _git(["init", "-q"], tmp_path)
    _git(["config", "user.email", "harness@test"], tmp_path)
    _git(["config", "user.name", "Harness"], tmp_path)
    _git(["config", "commit.gpgsign", "false"], tmp_path)
    (tmp_path / "README.md").write_text("seed\n")
    _git(["add", "README.md"], tmp_path)
    _git(["commit", "-q", "-m", "seed"], tmp_path)
    return tmp_path


def _plan_with_phases(n: int) -> str:
    parts = ["# Scratch", "## Implementation Checklist", ""]
    for i in range(1, n + 1):
        parts.append(f"### Phase {i}: Phase {i}")
        parts.append("")
        parts.append(f"**Impl files:** src/p{i}.py")
        parts.append(f"**Test files:** tests/test_p{i}.py")
        parts.append("**Test command:** `true`")
        parts.append("")
        parts.append(f"- [ ] task {i}")
        if i != n:
            parts.append("")
    return "\n".join(parts) + "\n"


def _plan_with_validation(failing_phase: int, n: int = 2) -> str:
    """Like ``_plan_with_phases`` but phase ``failing_phase`` has a
    Validation cmd: that the test runner will be scripted to fail.
    """
    parts = ["# Scratch", "## Implementation Checklist", ""]
    for i in range(1, n + 1):
        parts.append(f"### Phase {i}: Phase {i}")
        parts.append("")
        parts.append(f"**Impl files:** src/p{i}.py")
        parts.append(f"**Test files:** tests/test_p{i}.py")
        parts.append("**Test command:** `true`")
        if i == failing_phase:
            parts.append("**Validation cmd:** `false`")
        parts.append("")
        parts.append(f"- [ ] task {i}")
        if i != n:
            parts.append("")
    return "\n".join(parts) + "\n"


def _scratch_plan(repo: Path, body: str) -> Path:
    plans_dir = repo / "docs" / "dev_plans"
    plans_dir.mkdir(parents=True)
    plan = plans_dir / "20260513-autonomous.md"
    plan.write_text(textwrap.dedent(body))
    write_marker(plan)
    return plan


def _impl_report(label: str, files: list[str]) -> str:
    payload = {
        "role": "implementer",
        "phase_position": 0,
        "phase_label": label,
        "iteration": 0,
        "files_changed": files,
        "summary": "stub",
        "flags": {
            "blocked": False,
            "test_contract_mismatch": False,
            "explanation": None,
            "needs_test_coverage": [],
        },
    }
    return f"prose\n```json\n{json.dumps(payload)}\n```"


def _test_report(label: str = "1") -> str:
    payload = {
        "role": "test-writer",
        "phase_position": 0,
        "phase_label": label,
        "iteration": 0,
        "test_files_added": ["tests/test_a.py"],
        "test_commands": ["true"],
        "coverage_summary": "stub",
        "flags": {"blocked": False, "needs_impl_clarification": None},
    }
    return f"```json\n{json.dumps(payload)}\n```"


def _stage(repo: Path, path: str, content: str) -> None:
    full = repo / path
    full.parent.mkdir(parents=True, exist_ok=True)
    full.write_text(content)
    _git(["add", path], repo)


@dataclass
class StubSpawner:
    repo: Path
    scripts: dict[tuple[str, str, int], Callable[[SpawnRequest, Path], str]] = field(
        default_factory=dict
    )
    calls: list[SpawnRequest] = field(default_factory=list)

    def script(
        self,
        role: str,
        phase_label: str,
        iteration: int,
        fn: Callable[[SpawnRequest, Path], str],
    ) -> None:
        self.scripts[(role, phase_label, iteration)] = fn

    def __call__(self, req: SpawnRequest) -> str:
        self.calls.append(req)
        key = (req.role, req.phase_label, req.iteration)
        if key not in self.scripts:
            raise AssertionError(f"no scripted reply for {key}")
        return self.scripts[key](req, self.repo)


def _wire_normal_phase(spawner: StubSpawner, label: str) -> None:
    """Script implementer + test-writer for the named phase: stage one file
    under ``src/p<label>.py`` and emit a valid impl report.
    """

    def impl(req: SpawnRequest, r: Path) -> str:
        _stage(r, f"src/p{label}.py", f"v={label}\n")
        return _impl_report(label, [f"src/p{label}.py"])

    spawner.script("implementer", label, 0, impl)
    spawner.script("test-writer", label, 0, lambda req, r: _test_report(label))


@dataclass
class StubTestRunner:
    queue: list[_TestResult] = field(default_factory=list)
    calls: list[tuple[str, float]] = field(default_factory=list)

    def __call__(self, cmd: str, timeout: float) -> _TestResult:
        self.calls.append((cmd, timeout))
        if not self.queue:
            raise AssertionError(f"test runner exhausted (cmd={cmd!r})")
        return self.queue.pop(0)


def _passing() -> _TestResult:
    return _TestResult(
        returncode=0, output="ok\n", timed_out=False, duration_seconds=0.01
    )


def _failing(msg: str = "validation failed") -> _TestResult:
    return _TestResult(
        returncode=1, output=msg + "\n", timed_out=False, duration_seconds=0.01
    )


# ---------------------------------------------------------------------------
# autonomous-3-phase-success
# ---------------------------------------------------------------------------


def test_autonomous_3_phase_success(repo, lock_counter):
    """3 phases walk under one lock acquisition in a single invocation.

    Phase 2 lands the autonomous loop without the CI-parity gate; the
    post-loop fall-through returns ``status="complete"``.
    """
    plan = _scratch_plan(repo, _plan_with_phases(3))
    spawner = StubSpawner(repo)
    for label in ("1", "2", "3"):
        _wire_normal_phase(spawner, label)
    runner = StubTestRunner(queue=[_passing(), _passing(), _passing()])

    result = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=spawner,
            test_runner=runner,
            autonomous=True,
        )
    )

    assert result.status == "complete", result.summary
    assert len(result.state["completed_phases"]) == 3
    assert [p["label"] for p in result.state["completed_phases"]] == ["1", "2", "3"]
    # Single-lock-acquisition invariant under --autonomous.
    assert lock_counter.count == 1


# ---------------------------------------------------------------------------
# autonomous-rogue-commit-handback-at-phase-2
# ---------------------------------------------------------------------------


def test_autonomous_rogue_commit_handback_at_phase_2(repo, lock_counter):
    """Rogue commit in phase 2 of an autonomous run hands back at phase 2.

    Phase 1 must complete normally; phase 3 must never enter ``_run_phase``.
    """
    plan = _scratch_plan(repo, _plan_with_phases(3))
    spawner = StubSpawner(repo)
    _wire_normal_phase(spawner, "1")

    def rogue_impl(req: SpawnRequest, r: Path) -> str:
        _stage(r, "src/p2.py", "v=2\n")
        # Subagent commits its own work — conductor must detect and refuse.
        _git(["commit", "-q", "-m", "rogue subagent commit"], r)
        return _impl_report("2", ["src/p2.py"])

    spawner.script("implementer", "2", 0, rogue_impl)
    spawner.script("test-writer", "2", 0, lambda req, r: _test_report("2"))
    _wire_normal_phase(spawner, "3")
    runner = StubTestRunner(queue=[_passing(), _passing()])

    result = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=spawner,
            test_runner=runner,
            autonomous=True,
        )
    )

    assert result.status == "awaiting_user", result.summary
    completed = result.state["completed_phases"]
    # Phase 1 success, phase 2 captured as rogue, no phase 3.
    assert [p["label"] for p in completed] == ["1", "2"]
    assert completed[0]["commit_sha"] is not None
    assert completed[0].get("rogue_commit_sha") is None
    assert completed[1]["commit_sha"] is None
    assert completed[1]["rogue_commit_sha"] is not None
    # Phase 3 never spawned.
    assert not any(c.phase_label == "3" for c in spawner.calls)
    # Single lock acquisition even on hard-stop mid-run.
    assert lock_counter.count == 1


# ---------------------------------------------------------------------------
# autonomous-schema-error-handback-at-phase-1
# ---------------------------------------------------------------------------


def test_autonomous_schema_error_handback_at_phase_1(repo, lock_counter):
    """Malformed JSON from the implementer in phase 1 hard-stops without
    advancing to phase 2.
    """
    plan = _scratch_plan(repo, _plan_with_phases(2))
    spawner = StubSpawner(repo)

    def garbled(req: SpawnRequest, r: Path) -> str:
        _stage(r, "src/p1.py", "v=1\n")
        return "no json fence here, just prose"

    spawner.script("implementer", "1", 0, garbled)
    spawner.script("test-writer", "1", 0, lambda req, r: _test_report("1"))
    runner = StubTestRunner()

    result = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=spawner,
            test_runner=runner,
            autonomous=True,
        )
    )

    assert result.status == "schema_error"
    # Phase 2 never spawned.
    assert not any(c.phase_label == "2" for c in spawner.calls)
    assert lock_counter.count == 1


# ---------------------------------------------------------------------------
# autonomous-validation-cmd-failure-handback-at-phase-2
# ---------------------------------------------------------------------------


def test_autonomous_validation_cmd_failure_handback_at_phase_2(repo, lock_counter):
    """Phase 2's Validation cmd: returns non-zero — handback, no phase 3."""
    plan = _scratch_plan(repo, _plan_with_validation(failing_phase=2, n=3))
    spawner = StubSpawner(repo)
    for label in ("1", "2", "3"):
        _wire_normal_phase(spawner, label)
    # Phase 1: tests pass. Phase 2: tests pass, then validation cmd fails.
    runner = StubTestRunner(
        queue=[
            _passing(),  # phase 1 tests
            _passing(),  # phase 2 tests
            _failing("validation: live-data check failed"),  # phase 2 validation
        ]
    )

    result = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=spawner,
            test_runner=runner,
            autonomous=True,
        )
    )

    assert result.status == "awaiting_user", result.summary
    assert "validation failed" in result.state["blocker"]
    # Phase 1 should be the only completed phase. Phase 2 hit validation
    # failure BEFORE the boundary commit, so it is not appended.
    completed = result.state["completed_phases"]
    assert [p["label"] for p in completed] == ["1"]
    # Phase 3 never spawned.
    assert not any(c.phase_label == "3" for c in spawner.calls)
    assert lock_counter.count == 1


# ---------------------------------------------------------------------------
# max-phases-cap-4-phase-fixture-cap-2
# ---------------------------------------------------------------------------


def test_max_phases_cap_4_phase_fixture_cap_2(repo, lock_counter):
    """4-phase plan with ``--max-phases 2`` hands back after phase 2 with
    blocker ``max_phases ceiling hit (2)``.
    """
    plan = _scratch_plan(repo, _plan_with_phases(4))
    spawner = StubSpawner(repo)
    for label in ("1", "2", "3", "4"):
        _wire_normal_phase(spawner, label)
    runner = StubTestRunner(queue=[_passing(), _passing()])

    result = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=spawner,
            test_runner=runner,
            autonomous=True,
            max_phases=2,
        )
    )

    assert result.status == "blocked", result.summary
    assert result.state["blocker"] == "max_phases ceiling hit (2)"
    assert [p["label"] for p in result.state["completed_phases"]] == ["1", "2"]
    # Phase 3 and 4 never spawned.
    assert not any(c.phase_label in {"3", "4"} for c in spawner.calls)
    assert lock_counter.count == 1


# ---------------------------------------------------------------------------
# max-phases-cap-respects-post-commit-count
# ---------------------------------------------------------------------------


def test_max_phases_cap_respects_post_commit_count(repo, lock_counter):
    """Boundary case: ``--max-phases 2`` with a 3-phase fixture.

    The loop's ``max_phases`` check reads the post-commit count, so after
    phase 2 completes (count == 2 == cap) the check fires on the next
    iteration and phase 3 never enters ``_run_phase``. Asserted via the
    spawner's call log: no implementer or test-writer call with
    ``phase_label == "3"``.
    """
    plan = _scratch_plan(repo, _plan_with_phases(3))
    spawner = StubSpawner(repo)
    for label in ("1", "2", "3"):
        _wire_normal_phase(spawner, label)
    runner = StubTestRunner(queue=[_passing(), _passing()])

    result = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=spawner,
            test_runner=runner,
            autonomous=True,
            max_phases=2,
        )
    )

    assert result.status == "blocked"
    assert result.state["blocker"] == "max_phases ceiling hit (2)"
    # The structural invariant: phase 3 never enters _run_phase. Detected by
    # the absence of ANY spawn call (implementer or test-writer) carrying
    # phase_label == "3" — _run_phase always spawns at iteration 0 before it
    # can hard-stop.
    phase_3_spawns = [c for c in spawner.calls if c.phase_label == "3"]
    assert phase_3_spawns == [], phase_3_spawns
    # And phase 2 must actually have completed (post-commit count, not
    # pre-commit) for the cap to fire on iteration 3.
    assert len(result.state["completed_phases"]) == 2
    assert lock_counter.count == 1
