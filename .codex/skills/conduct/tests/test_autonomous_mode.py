"""Phase 2 autonomous-mode tests for the Codex conductor mirror."""

from __future__ import annotations

import json
import subprocess
import textwrap
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

import pytest

from conduct.conductor import ConductOptions, SpawnRequest, conduct
from conduct.marker import write_marker
from conduct.runner import TestResult as _TestResult


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


def test_autonomous_3_phase_success(repo, lock_counter):
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
    assert [p["label"] for p in result.state["completed_phases"]] == ["1", "2", "3"]
    assert lock_counter.count == 1


def test_autonomous_rogue_commit_handback_at_phase_2(repo, lock_counter):
    plan = _scratch_plan(repo, _plan_with_phases(3))
    spawner = StubSpawner(repo)
    _wire_normal_phase(spawner, "1")

    def rogue_impl(req: SpawnRequest, r: Path) -> str:
        _stage(r, "src/p2.py", "v=2\n")
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
    assert [p["label"] for p in completed] == ["1", "2"]
    assert completed[0]["commit_sha"] is not None
    assert completed[0].get("rogue_commit_sha") is None
    assert completed[1]["commit_sha"] is None
    assert completed[1]["rogue_commit_sha"] is not None
    assert not any(c.phase_label == "3" for c in spawner.calls)
    assert lock_counter.count == 1


def test_autonomous_schema_error_handback_at_phase_1(repo, lock_counter):
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
    assert not any(c.phase_label == "2" for c in spawner.calls)
    assert lock_counter.count == 1


def test_autonomous_validation_cmd_failure_handback_at_phase_2(repo, lock_counter):
    plan = _scratch_plan(repo, _plan_with_validation(failing_phase=2, n=3))
    spawner = StubSpawner(repo)
    for label in ("1", "2", "3"):
        _wire_normal_phase(spawner, label)
    runner = StubTestRunner(
        queue=[
            _passing(),
            _passing(),
            _failing("validation: live-data check failed"),
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
    assert [p["label"] for p in result.state["completed_phases"]] == ["1"]
    assert not any(c.phase_label == "3" for c in spawner.calls)
    assert lock_counter.count == 1


def test_max_phases_cap_4_phase_fixture_cap_2(repo, lock_counter):
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
    assert not any(c.phase_label in {"3", "4"} for c in spawner.calls)
    assert lock_counter.count == 1


def test_max_phases_cap_respects_post_commit_count(repo, lock_counter):
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
    assert [p["label"] for p in result.state["completed_phases"]] == ["1", "2"]
    assert [c for c in spawner.calls if c.phase_label == "3"] == []
    assert lock_counter.count == 1
