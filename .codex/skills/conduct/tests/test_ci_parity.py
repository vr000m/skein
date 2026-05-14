"""Phase 3 end-of-plan CI-parity gate tests for the Codex conductor."""

from __future__ import annotations

import json
import os
import subprocess
import textwrap
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

import pytest

import conduct.conductor as conductor
from conduct.conductor import ConductOptions, SpawnRequest, _state_path, conduct
from conduct.marker import compute_plan_hash, write_marker
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
        parts.extend(
            [
                f"### Phase {i}: Phase {i}",
                "",
                f"**Impl files:** src/p{i}.py",
                f"**Test files:** tests/test_p{i}.py",
                "**Test command:** `true`",
                "",
                f"- [ ] task {i}",
                "",
            ]
        )
    return "\n".join(parts).rstrip() + "\n"


def _scratch_plan(repo: Path, body: str, name: str = "20260513-ci-parity.md") -> Path:
    plans_dir = repo / "docs" / "dev_plans"
    plans_dir.mkdir(parents=True, exist_ok=True)
    plan = plans_dir / name
    plan.write_text(textwrap.dedent(body))
    write_marker(plan)
    return plan


def _impl_report(label: str, files: list[str]) -> str:
    payload = {
        "role": "implementer",
        "phase_position": int(label) - 1,
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


def _test_report(label: str) -> str:
    payload = {
        "role": "test-writer",
        "phase_position": int(label) - 1,
        "phase_label": label,
        "iteration": 0,
        "test_files_added": [f"tests/test_p{label}.py"],
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
        _stage(r, f"src/p{label}.py", f"v = {label}\n")
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


def _ci_parity_report(
    plan_id: str,
    written_at: float,
    status: str,
    **extra: Any,
) -> str:
    payload = {
        "role": "ci-parity",
        "schema_version": 1,
        "plan_id": plan_id,
        "request_written_at_unix": written_at,
        "status": status,
        "command_run": extra.pop("command_run", "echo ci"),
        "summary": extra.pop("summary", "ok"),
        **extra,
    }
    return f"```json\n{json.dumps(payload)}\n```"


def _scripted_ci_spawn(status: str = "passed", **extra: Any):
    captured: list[Any] = []

    def spawn(req: Any) -> str:
        captured.append(req)
        report_extra = dict(extra)
        report_extra.setdefault("command_run", req.ci_cmd)
        return _ci_parity_report(
            req.plan_id,
            req.request_written_at_unix,
            status,
            **report_extra,
        )

    spawn.captured = captured  # type: ignore[attr-defined]
    return spawn


def _result_path(repo: Path, plan: Path, plan_id: str | None = None) -> Path:
    plan_id = plan_id or conductor._compute_cross_runtime_plan_id(plan)
    return conductor._ci_parity_result_path(
        ConductOptions(plan_path=plan, repo_root=repo, spawn=lambda r: ""), plan_id
    )


def _write_result(path: Path, text: str) -> None:
    conductor._write_ci_parity_result(path, text)


def _seed_awaiting_state(repo: Path, plan: Path, written_at: float) -> str:
    plan_id = conductor._compute_cross_runtime_plan_id(plan)
    head = _git(["rev-parse", "HEAD"], repo).stdout.strip()
    opts = ConductOptions(
        plan_path=plan, repo_root=repo, spawn=lambda r: "", resume=True
    )
    sp = _state_path(opts)
    sp.parent.mkdir(parents=True, exist_ok=True)
    sp.write_text(
        json.dumps(
            {
                "schema_version": conductor.STATE_SCHEMA_VERSION,
                "plan_path": str(plan),
                "plan_content_hash": compute_plan_hash(plan),
                "base_sha": head,
                "phase_index": 1,
                "current_phase_title": "",
                "completed_phases": [
                    {"index": 0, "label": "1", "title": "Phase 1", "commit_sha": head}
                ],
                "last_summary": "",
                "iteration_count": 0,
                "status": "awaiting_ci_parity",
                "blocker": None,
                "paused_stash_rev": None,
                "stall_signatures": [],
                "stall_count": 0,
                "autonomous": True,
                "plan_id": plan_id,
                "state_author": "codex",
                "ci_parity_request": {
                    "plan_path": str(plan),
                    "base_sha": head,
                    "head_sha": head,
                    "ci_entrypoint_kind": "override",
                    "ci_cmd": "echo ci",
                    "repo_root": str(repo),
                    "plan_id": plan_id,
                    "request_written_at_unix": written_at,
                },
                "ci_parity_request_written_at": written_at,
                "ci_parity_result": None,
                "ci_parity_dispatched": False,
                "ci_parity_missing_resume_count": 0,
            }
        )
    )
    return plan_id


def _resume_ci(repo: Path, plan: Path, **overrides: Any):
    return conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=StubSpawner(repo),
            test_runner=StubTestRunner(),
            resume=True,
            ci_cmd="echo ci",
            **overrides,
        )
    )


def _seed_makefile(repo: Path) -> None:
    (repo / "Makefile").write_text("ci:\n\techo ci\n")


def test_detect_ci_entrypoint_priority_and_empty(tmp_path: Path) -> None:
    from conduct.ci_parity import detect_ci_entrypoint

    (tmp_path / "justfile").write_text("ci:\n\techo ci\n")
    (tmp_path / "Makefile").write_text("ci:\n\techo ci\n")
    assert detect_ci_entrypoint(tmp_path) == ("just", "just ci")

    tmp_path.joinpath("justfile").unlink()
    (tmp_path / "package.json").write_text(json.dumps({"scripts": {"ci": "echo ci"}}))
    assert detect_ci_entrypoint(tmp_path) == ("make", "make ci")

    tmp_path.joinpath("Makefile").unlink()
    (tmp_path / "Cargo.toml").write_text('[package]\nname = "p"\nversion = "0.1.0"\n')
    assert detect_ci_entrypoint(tmp_path) == ("npm", "npm run ci")

    tmp_path.joinpath("package.json").unlink()
    assert detect_ci_entrypoint(tmp_path) == ("cargo", "cargo test --all")

    tmp_path.joinpath("Cargo.toml").unlink()
    assert detect_ci_entrypoint(tmp_path) is None


def test_ci_cmd_override_bypasses_entrypoint_detection(repo, lock_counter) -> None:
    _seed_makefile(repo)
    plan = _scratch_plan(repo, _plan_with_phases(1))
    spawner = StubSpawner(repo)
    _wire_normal_phase(spawner, "1")
    spawn = _scripted_ci_spawn("passed")

    result = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=spawner,
            test_runner=StubTestRunner(queue=[_passing()]),
            autonomous=True,
            ci_cmd="echo custom",
            ci_parity_spawn=spawn,
        )
    )

    assert result.status == "complete"
    assert len(spawn.captured) == 1
    assert spawn.captured[0].ci_entrypoint_kind == "override"
    assert spawn.captured[0].ci_cmd == "echo custom"


def test_ci_parity_standalone_dispatches_only_after_final_resume(repo) -> None:
    plan = _scratch_plan(repo, _plan_with_phases(2))
    spawner = StubSpawner(repo)
    for label in ("1", "2"):
        _wire_normal_phase(spawner, label)
    spawn = _scripted_ci_spawn("passed")
    runner = StubTestRunner(queue=[_passing(), _passing()])

    first = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=spawner,
            test_runner=runner,
            run_ci_parity=True,
            ci_cmd="echo ci",
            ci_parity_spawn=spawn,
        )
    )
    assert first.status == "awaiting_user"
    assert len(spawn.captured) == 0

    second = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=spawner,
            test_runner=runner,
            run_ci_parity=True,
            ci_cmd="echo ci",
            ci_parity_spawn=spawn,
            resume=True,
        )
    )
    assert second.status == "awaiting_user"
    assert len(spawn.captured) == 0

    final = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=spawner,
            test_runner=runner,
            run_ci_parity=True,
            ci_cmd="echo ci",
            ci_parity_spawn=spawn,
            resume=True,
        )
    )
    assert final.status == "complete"
    assert len(spawn.captured) == 1


def test_autonomous_ci_parity_fires_once_at_end_of_plan(repo, lock_counter) -> None:
    plan = _scratch_plan(repo, _plan_with_phases(3))
    spawner = StubSpawner(repo)
    for label in ("1", "2", "3"):
        _wire_normal_phase(spawner, label)
    spawn = _scripted_ci_spawn("passed")

    result = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=spawner,
            test_runner=StubTestRunner(queue=[_passing(), _passing(), _passing()]),
            autonomous=True,
            ci_cmd="echo ci",
            ci_parity_spawn=spawn,
        )
    )

    assert result.status == "complete"
    assert [p["label"] for p in result.state["completed_phases"]] == ["1", "2", "3"]
    assert len(spawn.captured) == 1
    assert lock_counter.count == 1


def test_autonomous_ci_parity_result_file_path_reacquires_lock(
    repo, lock_counter
) -> None:
    plan = _scratch_plan(repo, _plan_with_phases(3))
    spawner = StubSpawner(repo)
    for label in ("1", "2", "3"):
        _wire_normal_phase(spawner, label)

    r1 = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=spawner,
            test_runner=StubTestRunner(queue=[_passing(), _passing(), _passing()]),
            autonomous=True,
            ci_cmd="echo ci",
        )
    )
    assert r1.status == "awaiting_ci_parity"
    assert r1.next_action == "dispatch_ci_parity"

    _write_result(
        _result_path(repo, plan, r1.request["plan_id"]),
        _ci_parity_report(
            r1.request["plan_id"],
            r1.request["request_written_at_unix"],
            "passed",
        ),
    )

    r2 = _resume_ci(repo, plan, autonomous=True)
    assert r2.status == "complete"
    assert len(r2.state["completed_phases"]) == 3
    assert lock_counter.count == 2


def test_ci_parity_pass_fail_and_no_entrypoint_blocks(repo, tmp_path: Path) -> None:
    plan = _scratch_plan(repo, _plan_with_phases(1))
    spawner = StubSpawner(repo)
    _wire_normal_phase(spawner, "1")
    passed_spawn = _scripted_ci_spawn("passed", summary="green build")

    passed = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=spawner,
            test_runner=StubTestRunner(queue=[_passing()]),
            autonomous=True,
            ci_cmd="echo ci",
            ci_parity_spawn=passed_spawn,
        )
    )
    assert passed.status == "complete"
    assert passed.state["ci_parity_dispatched"] is True

    failed_repo = tmp_path / "failed-repo"
    failed_repo.mkdir()
    _git(["init", "-q"], failed_repo)
    _git(["config", "user.email", "harness@test"], failed_repo)
    _git(["config", "user.name", "Harness"], failed_repo)
    _git(["config", "commit.gpgsign", "false"], failed_repo)
    (failed_repo / "README.md").write_text("seed\n")
    _git(["add", "README.md"], failed_repo)
    _git(["commit", "-q", "-m", "seed"], failed_repo)
    failed_plan = _scratch_plan(failed_repo, _plan_with_phases(1))
    failed_spawner = StubSpawner(failed_repo)
    _wire_normal_phase(failed_spawner, "1")
    fail_spawn = _scripted_ci_spawn("failed", summary="3 tests failed")
    failed_result = conduct(
        ConductOptions(
            plan_path=failed_plan,
            repo_root=failed_repo,
            spawn=failed_spawner,
            test_runner=StubTestRunner(queue=[_passing()]),
            autonomous=True,
            ci_cmd="echo ci",
            ci_parity_spawn=fail_spawn,
        )
    )
    assert failed_result.status == "ci_failed"
    assert failed_result.state["ci_parity_result"]["status"] == "failed"

    empty_repo = tmp_path / "empty-ci-repo"
    empty_repo.mkdir()
    _git(["init", "-q"], empty_repo)
    _git(["config", "user.email", "harness@test"], empty_repo)
    _git(["config", "user.name", "Harness"], empty_repo)
    _git(["config", "commit.gpgsign", "false"], empty_repo)
    (empty_repo / "README.md").write_text("seed\n")
    _git(["add", "README.md"], empty_repo)
    _git(["commit", "-q", "-m", "seed"], empty_repo)
    empty_plan = _scratch_plan(empty_repo, _plan_with_phases(1))
    empty_spawner = StubSpawner(empty_repo)
    _wire_normal_phase(empty_spawner, "1")
    blocked = conduct(
        ConductOptions(
            plan_path=empty_plan,
            repo_root=empty_repo,
            spawn=empty_spawner,
            test_runner=StubTestRunner(queue=[_passing()]),
            autonomous=True,
        )
    )
    assert blocked.status == "blocked"
    assert "ci-parity entrypoint not detected" in blocked.summary
    assert "--ci-cmd" in (blocked.diagnostic or "")


def test_skip_ci_parity_shortcuts_and_preserves_awaiting_artifacts(repo) -> None:
    plan = _scratch_plan(repo, _plan_with_phases(1))
    spawner = StubSpawner(repo)
    _wire_normal_phase(spawner, "1")

    skipped = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=spawner,
            test_runner=StubTestRunner(queue=[_passing()]),
            autonomous=True,
            skip_ci_parity=True,
        )
    )
    assert skipped.status == "complete"
    assert "skip" in (skipped.state.get("last_summary") or "").lower()

    awaiting_plan = _scratch_plan(repo, _plan_with_phases(1), name="awaiting.md")
    written_at = time.time()
    plan_id = _seed_awaiting_state(repo, awaiting_plan, written_at)
    result_path = _result_path(repo, awaiting_plan, plan_id)
    _write_result(result_path, _ci_parity_report(plan_id, written_at, "passed"))

    resumed = _resume_ci(repo, awaiting_plan, skip_ci_parity=True)
    assert resumed.status == "complete"
    assert result_path.exists()


def test_ci_parity_result_file_present_valid_consumes_and_moves(repo) -> None:
    plan = _scratch_plan(repo, _plan_with_phases(1))
    written_at = time.time()
    plan_id = _seed_awaiting_state(repo, plan, written_at)
    result_path = _result_path(repo, plan, plan_id)
    _write_result(result_path, _ci_parity_report(plan_id, written_at, "passed"))

    result = _resume_ci(repo, plan)

    assert result.status == "complete"
    assert result.state["ci_parity_result"]["status"] == "passed"
    assert result.state["ci_parity_missing_resume_count"] == 0
    assert not result_path.exists()
    assert list(result_path.parent.glob(f"ci-parity-result-{plan_id}.consumed-*.json"))


def test_ci_parity_invalid_plan_id_in_state_is_schema_error(repo) -> None:
    plan = _scratch_plan(repo, _plan_with_phases(1))
    written_at = time.time()
    _seed_awaiting_state(repo, plan, written_at)
    state_path = _state_path(
        ConductOptions(plan_path=plan, repo_root=repo, spawn=lambda r: "")
    )
    state = json.loads(state_path.read_text())
    state["plan_id"] = "../escape"
    state["ci_parity_request"]["plan_id"] = "../escape"
    state_path.write_text(json.dumps(state))

    result = _resume_ci(repo, plan)

    assert result.status == "schema_error"
    assert "plan_id must match" in (result.diagnostic or "")


def test_write_ci_parity_result_rejects_nested_conduct_escape(repo) -> None:
    escaped = repo / ".conduct" / "nested" / ".." / ".." / "escape.json"

    with pytest.raises(conductor.UnsafeConductPathError):
        _write_result(escaped, "{}")


def test_ci_parity_stale_result_file_reemits_and_resets_missing_counter(repo) -> None:
    plan = _scratch_plan(repo, _plan_with_phases(1))
    written_at = time.time()
    plan_id = _seed_awaiting_state(repo, plan, written_at)
    sp = _state_path(ConductOptions(plan_path=plan, repo_root=repo, spawn=lambda r: ""))
    state = json.loads(sp.read_text())
    state["ci_parity_missing_resume_count"] = 2
    sp.write_text(json.dumps(state))
    _write_result(
        _result_path(repo, plan, plan_id),
        _ci_parity_report("wrong-plan-id", written_at, "passed"),
    )

    stale = _resume_ci(repo, plan)

    assert stale.status == "awaiting_ci_parity"
    assert stale.state["ci_parity_missing_resume_count"] == 0
    assert stale.request["request_written_at_unix"] == written_at


def test_ci_parity_wrong_command_run_is_stale(repo) -> None:
    plan = _scratch_plan(repo, _plan_with_phases(1))
    written_at = time.time()
    plan_id = _seed_awaiting_state(repo, plan, written_at)
    _write_result(
        _result_path(repo, plan, plan_id),
        _ci_parity_report(
            plan_id,
            written_at,
            "passed",
            command_run="wrong command",
        ),
    )

    stale = _resume_ci(repo, plan)

    assert stale.status == "awaiting_ci_parity"
    assert stale.state["ci_parity_missing_resume_count"] == 0


def test_ci_parity_injected_wrong_command_is_schema_error(repo) -> None:
    plan = _scratch_plan(repo, _plan_with_phases(1))
    spawner = StubSpawner(repo)
    _wire_normal_phase(spawner, "1")
    spawn = _scripted_ci_spawn("passed", command_run="wrong command")

    result = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=spawner,
            test_runner=StubTestRunner(queue=[_passing()]),
            autonomous=True,
            ci_cmd="echo ci",
            ci_parity_spawn=spawn,
        )
    )

    assert result.status == "schema_error"
    assert "command_run mismatch" in (result.diagnostic or "")


def test_ci_parity_malformed_result_file_handback_preserves_file(repo) -> None:
    plan = _scratch_plan(repo, _plan_with_phases(1))
    written_at = time.time()
    plan_id = _seed_awaiting_state(repo, plan, written_at)
    result_path = _result_path(repo, plan, plan_id)
    result_path.parent.mkdir(parents=True, exist_ok=True)
    result_path.write_text("{not-json")

    result = _resume_ci(repo, plan)

    assert result.status == "schema_error"
    assert "malformed" in ((result.summary or "") + (result.diagnostic or "")).lower()
    assert result_path.exists()
    assert result.state["ci_parity_missing_resume_count"] == 0


def test_awaiting_ci_parity_resume_rechecks_review_marker(repo) -> None:
    plan = _scratch_plan(repo, _plan_with_phases(1))
    written_at = time.time()
    plan_id = _seed_awaiting_state(repo, plan, written_at)
    _write_result(
        _result_path(repo, plan, plan_id),
        _ci_parity_report(plan_id, written_at, "passed"),
    )
    plan.write_text(plan.read_text().replace("# Scratch", "# Changed Scratch", 1))

    result = _resume_ci(repo, plan)

    assert result.status == "complete"
    state_path = _state_path(
        ConductOptions(plan_path=plan, repo_root=repo, spawn=lambda r: "")
    )
    assert json.loads(state_path.read_text())["plan_content_hash"] == compute_plan_hash(
        plan
    )


def test_ci_parity_consumed_toctou_recovers_when_active_file_absent(repo) -> None:
    plan = _scratch_plan(repo, _plan_with_phases(1))
    written_at = time.time()
    plan_id = _seed_awaiting_state(repo, plan, written_at)
    consumed = (
        repo
        / ".conduct"
        / f"ci-parity-result-{plan_id}.consumed-{int(time.time())}.json"
    )
    consumed.parent.mkdir(parents=True, exist_ok=True)
    consumed.write_text(_ci_parity_report(plan_id, written_at, "passed"))

    result = _resume_ci(repo, plan)

    assert result.status == "complete"
    assert result.state["ci_parity_dispatched"] is True
    assert result.state["ci_parity_result"]["status"] == "passed"


def test_ci_parity_absent_result_file_missing_counter_blocks_after_three(repo) -> None:
    plan = _scratch_plan(repo, _plan_with_phases(1))
    _seed_awaiting_state(repo, plan, time.time())

    assert _resume_ci(repo, plan).state["ci_parity_missing_resume_count"] == 1
    assert _resume_ci(repo, plan).state["ci_parity_missing_resume_count"] == 2
    result = _resume_ci(repo, plan)

    assert result.status == "blocked"
    assert "3 resume attempts" in (result.state.get("blocker") or "")


def test_ci_parity_missing_counter_resets_on_consume(repo) -> None:
    plan = _scratch_plan(repo, _plan_with_phases(1))
    written_at = time.time()
    plan_id = _seed_awaiting_state(repo, plan, written_at)

    assert _resume_ci(repo, plan).state["ci_parity_missing_resume_count"] == 1
    assert _resume_ci(repo, plan).state["ci_parity_missing_resume_count"] == 2

    _write_result(
        _result_path(repo, plan, plan_id),
        _ci_parity_report(plan_id, written_at, "passed"),
    )
    consumed = _resume_ci(repo, plan)

    assert consumed.status == "complete"
    assert consumed.state["ci_parity_missing_resume_count"] == 0


def test_ci_parity_non_resume_against_awaiting_hard_fails(repo) -> None:
    plan = _scratch_plan(repo, _plan_with_phases(1))
    _seed_awaiting_state(repo, plan, time.time())

    result = conduct(
        ConductOptions(plan_path=plan, repo_root=repo, spawn=StubSpawner(repo))
    )

    assert result.status == "blocked"
    text = (result.summary or "") + (result.diagnostic or "")
    assert "awaiting_ci_parity" in text
    assert "--resume" in text


def test_ci_parity_atomic_write_adapter_is_single_result_write_surface(
    repo,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    plan = _scratch_plan(repo, _plan_with_phases(1))
    plan_id = conductor._compute_cross_runtime_plan_id(plan)
    result_path = _result_path(repo, plan, plan_id)

    adapter_calls: list[Path] = []
    atomic_calls: list[Path] = []
    safe_write_calls: list[Path] = []
    real_adapter = conductor._write_ci_parity_result
    real_atomic = conductor._atomic_write_result_file
    real_safe = conductor._safe_write_text

    def adapter(path: Path, text: str) -> None:
        adapter_calls.append(Path(path))
        real_adapter(path, text)

    def atomic(path: Path, text: str) -> None:
        atomic_calls.append(Path(path))
        real_atomic(path, text)

    def safe_write(path: Path, text: str) -> None:
        safe_write_calls.append(Path(path))
        real_safe(path, text)

    monkeypatch.setattr(conductor, "_write_ci_parity_result", adapter)
    monkeypatch.setattr(conductor, "_atomic_write_result_file", atomic)
    monkeypatch.setattr(conductor, "_safe_write_text", safe_write)

    conductor._write_ci_parity_result(
        result_path, _ci_parity_report(plan_id, 1.0, "passed")
    )

    assert result_path in adapter_calls
    assert result_path in atomic_calls
    assert result_path not in safe_write_calls


def test_ci_parity_partial_tmp_write_is_treated_as_absent(repo) -> None:
    plan = _scratch_plan(repo, _plan_with_phases(1))
    written_at = time.time()
    plan_id = _seed_awaiting_state(repo, plan, written_at)
    result_path = _result_path(repo, plan, plan_id)
    result_path.parent.mkdir(parents=True, exist_ok=True)
    result_path.with_name(result_path.name + f".tmp-{os.getpid()}").write_text("{")

    result = _resume_ci(repo, plan)

    assert result.status == "awaiting_ci_parity"
    assert result.state["ci_parity_missing_resume_count"] == 1


def test_ci_parity_injection_and_result_file_paths_share_consume_code(
    repo,
    tmp_path_factory: pytest.TempPathFactory,
) -> None:
    plan_a = _scratch_plan(repo, _plan_with_phases(1), name="a.md")
    spawner_a = StubSpawner(repo)
    _wire_normal_phase(spawner_a, "1")
    spawn_a = _scripted_ci_spawn("passed", summary="same", command_run="echo ci")

    injected = conduct(
        ConductOptions(
            plan_path=plan_a,
            repo_root=repo,
            spawn=spawner_a,
            test_runner=StubTestRunner(queue=[_passing()]),
            autonomous=True,
            ci_cmd="echo ci",
            ci_parity_spawn=spawn_a,
        )
    )
    assert injected.status == "complete"

    repo_b = tmp_path_factory.mktemp("repo-b")
    _git(["init", "-q"], repo_b)
    _git(["config", "user.email", "harness@test"], repo_b)
    _git(["config", "user.name", "Harness"], repo_b)
    _git(["config", "commit.gpgsign", "false"], repo_b)
    (repo_b / "README.md").write_text("seed\n")
    _git(["add", "README.md"], repo_b)
    _git(["commit", "-q", "-m", "seed"], repo_b)
    plan_b = _scratch_plan(repo_b, _plan_with_phases(1), name="a.md")
    spawner_b = StubSpawner(repo_b)
    _wire_normal_phase(spawner_b, "1")

    dispatched = conduct(
        ConductOptions(
            plan_path=plan_b,
            repo_root=repo_b,
            spawn=spawner_b,
            test_runner=StubTestRunner(queue=[_passing()]),
            autonomous=True,
            ci_cmd="echo ci",
        )
    )
    assert dispatched.status == "awaiting_ci_parity"
    _write_result(
        _result_path(repo_b, plan_b, dispatched.request["plan_id"]),
        _ci_parity_report(
            dispatched.request["plan_id"],
            dispatched.request["request_written_at_unix"],
            "passed",
            summary="same",
            command_run="echo ci",
        ),
    )
    consumed = _resume_ci(repo_b, plan_b, autonomous=True)
    assert consumed.status == "complete"

    for key in ("status", "ci_parity_dispatched", "ci_parity_missing_resume_count"):
        assert injected.state[key] == consumed.state[key], key
    injected_report = dict(injected.state["ci_parity_result"])
    consumed_report = dict(consumed.state["ci_parity_result"])
    for report in (injected_report, consumed_report):
        report.pop("plan_id")
        report.pop("request_written_at_unix")
    assert injected_report == consumed_report


def test_ci_parity_no_redispatch_after_consume(repo) -> None:
    plan = _scratch_plan(repo, _plan_with_phases(1))
    spawner = StubSpawner(repo)
    _wire_normal_phase(spawner, "1")
    spawn = _scripted_ci_spawn("passed")

    first = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=spawner,
            test_runner=StubTestRunner(queue=[_passing()]),
            run_ci_parity=True,
            ci_cmd="echo ci",
            ci_parity_spawn=spawn,
        )
    )
    assert first.status == "awaiting_user"

    consumed = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=spawner,
            test_runner=StubTestRunner(),
            run_ci_parity=True,
            ci_cmd="echo ci",
            ci_parity_spawn=spawn,
            resume=True,
        )
    )
    assert consumed.status == "complete"

    after = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=spawner,
            test_runner=StubTestRunner(),
            run_ci_parity=True,
            ci_cmd="echo ci",
            ci_parity_spawn=spawn,
            resume=True,
        )
    )
    assert after.status == "complete"
    assert len(spawn.captured) == 1


def test_ci_parity_prompt_placeholder_rendering_if_prompt_exists() -> None:
    prompt_path = Path(__file__).resolve().parents[1] / "ci-parity-prompt.md"
    if not prompt_path.exists():
        pytest.skip("ci-parity-prompt.md has not landed in the Codex mirror yet")
    template = prompt_path.read_text()
    req = conductor.CIParitySpawnRequest(
        plan_path="/abs/plan.md",
        base_sha="aaaaaaaa",
        head_sha="bbbbbbbb",
        ci_entrypoint_kind="make",
        ci_cmd="make ci",
        repo_root="/abs/repo",
        plan_id="0123456789ab",
        request_written_at_unix=12345.0,
    )

    rendered = (
        template.replace("{{PLAN_PATH}}", req.plan_path)
        .replace("{{BASE_SHA}}", req.base_sha)
        .replace("{{HEAD_SHA}}", req.head_sha)
        .replace("{{CI_ENTRYPOINT_KIND}}", req.ci_entrypoint_kind)
        .replace("{{CI_CMD}}", req.ci_cmd)
        .replace("{{REPO_ROOT}}", req.repo_root)
        .replace("{{PLAN_ID}}", req.plan_id)
        .replace("{{REQUEST_WRITTEN_AT_UNIX}}", str(req.request_written_at_unix))
    )

    assert "{{" not in rendered
    for value in (
        req.plan_path,
        req.base_sha,
        req.head_sha,
        req.ci_entrypoint_kind,
        req.ci_cmd,
        req.repo_root,
        req.plan_id,
        str(req.request_written_at_unix),
    ):
        assert value in rendered
