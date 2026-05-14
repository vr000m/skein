"""Phase 3 end-of-plan CI-parity gate tests.

Covers:
- ``detect_ci_entrypoint`` priority and None-on-empty cases.
- ``--ci-cmd`` override + autonomous / standalone cross-products.
- Pass / fail dispatch through the test-injection ``ci_parity_spawn`` seam.
- ``--skip-ci-parity`` short-circuit (eager + awaiting-state preserve-artifacts).
- Single-dispatch invariant (gate fires once at end-of-plan).
- 3-phase autonomous walk with the gate inline (LockAcquisitionCounter == 1)
  vs. via the production result-file path (LockAcquisitionCounter == 2).
- Five-sub-case result-file preflight (present-valid / stale / stale-by-timestamp
  / stale-by-request-written-at / malformed / missing / TOCTOU-recovery).
- Missing-counter reset rule on any non-absent outcome AND on consume.
- ``_write_ci_parity_result`` adapter is the single result-file write surface.
- ``ci-parity-prompt.md`` placeholder rendering (file-content check).

The CI-parity dispatch helper is exercised via the public ``conduct()`` entry
point + ``ConductOptions`` (no direct internal calls). Where a test needs the
result-file path's full contract (atomic write, consumed move, stale detection)
we write the file via the conductor-owned ``_write_ci_parity_result`` adapter
so the production write path is tested end-to-end.
"""

from __future__ import annotations

import json
import time
import warnings
from pathlib import Path

import conductor as conductor_mod
from _scaffold import (
    StubSpawner,
    StubTestRunner,
    _git,
    _passing,
    _plan_with_phases,
    _scratch_plan,
    _wire_normal_phase,
)
from ci_parity import detect_ci_entrypoint
from conductor import (
    CIParitySpawnRequest,
    ConductOptions,
    _ci_parity_result_path,
    _compute_cross_runtime_plan_id,
    _state_path,
    _write_ci_parity_result,
    conduct,
)


def _ci_parity_report(plan_id: str, written_at: float, status: str, **extra) -> str:
    """Render a worker JSON-fenced report. Used by the scripted spawner."""
    payload = {
        "role": "ci-parity",
        "schema_version": 1,
        "plan_id": plan_id,
        "request_written_at_unix": written_at,
        "status": status,
        "command_run": extra.pop("command_run", "true"),
        "summary": extra.pop("summary", "ok"),
        **extra,
    }
    return f"```json\n{json.dumps(payload)}\n```"


def _scripted_spawner(status: str = "passed", **extra):
    """Return a ci_parity_spawn function that returns a valid worker report."""
    captured: list[CIParitySpawnRequest] = []

    def spawn(req: CIParitySpawnRequest) -> str:
        captured.append(req)
        return _ci_parity_report(
            req.plan_id, req.request_written_at_unix, status, **extra
        )

    spawn.captured = captured  # type: ignore[attr-defined]
    return spawn


# ---------------------------------------------------------------------------
# detect_ci_entrypoint — priority rules
# ---------------------------------------------------------------------------


def _seed_justfile(repo: Path) -> None:
    (repo / "justfile").write_text("ci:\n\techo ci\n")


def _seed_makefile(repo: Path) -> None:
    (repo / "Makefile").write_text("ci:\n\techo ci\n")


def _seed_package_json_with_ci(repo: Path) -> None:
    (repo / "package.json").write_text(json.dumps({"scripts": {"ci": "echo ci"}}))


def _seed_cargo(repo: Path) -> None:
    (repo / "Cargo.toml").write_text('[package]\nname = "p"\nversion = "0.1.0"\n')


def test_detect_priority_just_over_make(tmp_path: Path) -> None:
    _seed_justfile(tmp_path)
    _seed_makefile(tmp_path)
    detected = detect_ci_entrypoint(tmp_path)
    assert detected == ("just", "just ci"), detected


def test_detect_priority_make_over_npm(tmp_path: Path) -> None:
    _seed_makefile(tmp_path)
    _seed_package_json_with_ci(tmp_path)
    detected = detect_ci_entrypoint(tmp_path)
    assert detected == ("make", "make ci"), detected


def test_detect_priority_npm_over_cargo(tmp_path: Path) -> None:
    _seed_package_json_with_ci(tmp_path)
    _seed_cargo(tmp_path)
    detected = detect_ci_entrypoint(tmp_path)
    assert detected == ("npm", "npm run ci"), detected


def test_detect_returns_none_on_empty_repo(tmp_path: Path) -> None:
    assert detect_ci_entrypoint(tmp_path) is None


def test_detect_cargo_only_returns_cargo_test_all(tmp_path: Path) -> None:
    _seed_cargo(tmp_path)
    detected = detect_ci_entrypoint(tmp_path)
    assert detected == ("cargo", "cargo test --all"), detected


# ---------------------------------------------------------------------------
# --ci-cmd override
# ---------------------------------------------------------------------------


def test_ci_cmd_override_bypasses_detection(repo, lock_counter):
    _seed_makefile(repo)
    plan = _scratch_plan(repo, _plan_with_phases(1))
    spawner = StubSpawner(repo)
    _wire_normal_phase(spawner, "1")
    runner = StubTestRunner(queue=[_passing()])
    spawn = _scripted_spawner("passed")

    result = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=spawner,
            test_runner=runner,
            autonomous=True,
            ci_cmd="echo custom",
            ci_parity_spawn=spawn,
        )
    )

    assert result.status == "complete"
    assert len(spawn.captured) == 1
    assert spawn.captured[0].ci_cmd == "echo custom"
    assert spawn.captured[0].ci_entrypoint_kind == "override"


def test_ci_cmd_override_with_autonomous_3_phase(repo, lock_counter):
    plan = _scratch_plan(repo, _plan_with_phases(3))
    spawner = StubSpawner(repo)
    for label in ("1", "2", "3"):
        _wire_normal_phase(spawner, label)
    runner = StubTestRunner(queue=[_passing(), _passing(), _passing()])
    spawn = _scripted_spawner("passed")

    result = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=spawner,
            test_runner=runner,
            autonomous=True,
            ci_cmd="just ci",
            ci_parity_spawn=spawn,
        )
    )

    assert result.status == "complete"
    assert len(result.state["completed_phases"]) == 3
    assert len(spawn.captured) == 1
    assert spawn.captured[0].ci_cmd == "just ci"


def test_ci_cmd_override_with_run_ci_parity_only(repo, lock_counter):
    plan = _scratch_plan(repo, _plan_with_phases(1))
    spawner = StubSpawner(repo)
    _wire_normal_phase(spawner, "1")
    runner = StubTestRunner(queue=[_passing()])
    spawn = _scripted_spawner("passed")

    # Non-autonomous, one-phase plan: phase 1 walks then hands back; --resume
    # fires the gate.
    r1 = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=spawner,
            test_runner=runner,
            run_ci_parity=True,
            ci_cmd="echo override",
            ci_parity_spawn=spawn,
        )
    )
    assert r1.status == "awaiting_user"
    assert len(spawn.captured) == 0

    result = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=spawner,
            test_runner=runner,
            run_ci_parity=True,
            ci_cmd="echo override",
            ci_parity_spawn=spawn,
            resume=True,
        )
    )
    assert result.status == "complete"
    assert len(spawn.captured) == 1
    assert spawn.captured[0].ci_cmd == "echo override"


# ---------------------------------------------------------------------------
# pass/fail/skip outcomes
# ---------------------------------------------------------------------------


def test_ci_parity_pass_sets_complete(repo, lock_counter):
    plan = _scratch_plan(repo, _plan_with_phases(1))
    spawner = StubSpawner(repo)
    _wire_normal_phase(spawner, "1")
    runner = StubTestRunner(queue=[_passing()])
    spawn = _scripted_spawner("passed", summary="green build")

    result = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=spawner,
            test_runner=runner,
            autonomous=True,
            ci_cmd="echo ci",
            ci_parity_spawn=spawn,
        )
    )

    assert result.status == "complete"
    assert "green build" in result.state["last_summary"]
    assert result.state["ci_parity_dispatched"] is True


def test_ci_parity_fail_sets_ci_failed_and_handback(repo, lock_counter):
    plan = _scratch_plan(repo, _plan_with_phases(1))
    spawner = StubSpawner(repo)
    _wire_normal_phase(spawner, "1")
    runner = StubTestRunner(queue=[_passing()])
    spawn = _scripted_spawner("failed", summary="3 tests failed")

    result = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=spawner,
            test_runner=runner,
            autonomous=True,
            ci_cmd="echo ci",
            ci_parity_spawn=spawn,
        )
    )

    assert result.status == "ci_failed"
    assert "3 tests failed" in (result.state.get("blocker") or "")
    assert result.state["ci_parity_result"]["status"] == "failed"


def test_ci_parity_skip_workflow_less(repo, lock_counter):
    """No entrypoint + no override → warning + status complete (not ci_failed)."""
    plan = _scratch_plan(repo, _plan_with_phases(1))
    spawner = StubSpawner(repo)
    _wire_normal_phase(spawner, "1")
    runner = StubTestRunner(queue=[_passing()])

    with warnings.catch_warnings(record=True) as caught:
        warnings.simplefilter("always")
        result = conduct(
            ConductOptions(
                plan_path=plan,
                repo_root=repo,
                spawn=spawner,
                test_runner=runner,
                autonomous=True,
            )
        )

    assert result.status == "complete"
    msgs = [str(w.message) for w in caught]
    assert any("no CI entrypoint detected" in m for m in msgs), msgs


def test_ci_parity_skip_ci_parity_flag_shortcuts_gate(repo, lock_counter):
    plan = _scratch_plan(repo, _plan_with_phases(1))
    spawner = StubSpawner(repo)
    _wire_normal_phase(spawner, "1")
    runner = StubTestRunner(queue=[_passing()])

    result = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=spawner,
            test_runner=runner,
            autonomous=True,
            skip_ci_parity=True,
        )
    )

    assert result.status == "complete"
    assert "skip" in (result.state.get("last_summary") or "").lower()


def test_ci_parity_skip_ci_parity_during_awaiting_preserves_artifacts(repo):
    """``--resume --skip-ci-parity`` from awaiting_ci_parity preserves files."""
    plan = _scratch_plan(repo, _plan_with_phases(1))
    plan_id = _compute_cross_runtime_plan_id(plan)
    result_path = _ci_parity_result_path(
        ConductOptions(plan_path=plan, repo_root=repo, spawn=lambda r: ""),
        plan_id,
    )
    result_path.parent.mkdir(parents=True, exist_ok=True)

    # Seed state directly into the runtime-specific state file as if the gate
    # had already dispatched.
    opts_seed = ConductOptions(plan_path=plan, repo_root=repo, spawn=lambda r: "")
    sp = _state_path(opts_seed)
    sp.parent.mkdir(parents=True, exist_ok=True)
    written_at = time.time()
    state_seed = {
        "plan_path": str(plan),
        "schema_version": 2,
        "completed_phases": [{"label": "1", "title": "x", "commit_sha": "abc"}],
        "iteration_count": 0,
        "status": "awaiting_ci_parity",
        "ci_parity_request": {
            "plan_path": str(plan),
            "base_sha": "",
            "head_sha": "",
            "ci_entrypoint_kind": "make",
            "ci_cmd": "make ci",
            "repo_root": str(repo),
            "plan_id": plan_id,
            "request_written_at_unix": written_at,
        },
        "ci_parity_request_written_at": written_at,
        "ci_parity_dispatched": False,
        "ci_parity_missing_resume_count": 0,
        "plan_id": plan_id,
        "state_author": "claude",
        "stall_signatures": [],
        "stall_count": 0,
    }
    sp.write_text(json.dumps(state_seed))

    # And drop a stale result file on disk — we want to confirm it survives.
    payload = _ci_parity_report(plan_id, written_at, "passed")
    _write_ci_parity_result(result_path, payload)
    request_path_artifact = result_path  # preserve a reference for the assertion

    spawner = StubSpawner(repo)
    runner = StubTestRunner()
    result = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=spawner,
            test_runner=runner,
            resume=True,
            skip_ci_parity=True,
        )
    )
    assert result.status == "complete"
    assert request_path_artifact.exists(), (
        "result file must be preserved on --skip-ci-parity from awaiting state"
    )


# ---------------------------------------------------------------------------
# single-dispatch invariant
# ---------------------------------------------------------------------------


def test_ci_parity_standalone_no_autonomous(repo):
    """--run-ci-parity (no --autonomous): gate fires only at final --resume."""
    plan = _scratch_plan(repo, _plan_with_phases(2))
    spawn = _scripted_spawner("passed")

    spawner = StubSpawner(repo)
    for label in ("1", "2"):
        _wire_normal_phase(spawner, label)
    runner = StubTestRunner(queue=[_passing(), _passing()])

    # Phase 1 walk — no gate yet.
    r1 = conduct(
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
    assert r1.status == "awaiting_user"
    assert len(spawn.captured) == 0

    # Phase 2 walk via --resume — should hand back with phase_success.
    r2 = conduct(
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
    assert r2.status == "awaiting_user"
    assert len(spawn.captured) == 0

    # Final --resume after all phases complete → gate fires.
    r3 = conduct(
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
    assert r3.status == "complete"
    assert len(spawn.captured) == 1


def test_ci_parity_single_dispatch_no_fire_on_intermediate_resume_without_autonomous(
    repo,
):
    """Explicit: gate NOT dispatched after phase 1; IS dispatched after final."""
    plan = _scratch_plan(repo, _plan_with_phases(2))
    spawn = _scripted_spawner("passed")
    spawner = StubSpawner(repo)
    for label in ("1", "2"):
        _wire_normal_phase(spawner, label)
    runner = StubTestRunner(queue=[_passing(), _passing()])

    r1 = conduct(
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
    assert len(r1.state["completed_phases"]) == 1
    assert len(spawn.captured) == 0  # gate not dispatched after intermediate phase

    r2 = conduct(
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
    # The conductor returns awaiting_user after phase 2's boundary commit; the
    # final --resume below fires the gate.
    assert len(r2.state["completed_phases"]) == 2

    r3 = conduct(
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
    assert r3.status == "complete"
    assert len(spawn.captured) == 1


def test_ci_parity_single_dispatch_fires_once_with_autonomous(repo, lock_counter):
    plan = _scratch_plan(repo, _plan_with_phases(3))
    spawner = StubSpawner(repo)
    for label in ("1", "2", "3"):
        _wire_normal_phase(spawner, label)
    runner = StubTestRunner(queue=[_passing(), _passing(), _passing()])
    spawn = _scripted_spawner("passed")

    result = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=spawner,
            test_runner=runner,
            autonomous=True,
            ci_cmd="echo ci",
            ci_parity_spawn=spawn,
        )
    )

    assert result.status == "complete"
    assert len(spawn.captured) == 1
    assert len(result.state["completed_phases"]) == 3


# ---------------------------------------------------------------------------
# moved-from-Phase-2 lock-acquisition tests
# ---------------------------------------------------------------------------


def test_autonomous_3_phase_success_with_ci_parity_injection(repo, lock_counter):
    """Inline (test-injection) gate dispatch keeps the single-lock invariant."""
    plan = _scratch_plan(repo, _plan_with_phases(3))
    spawner = StubSpawner(repo)
    for label in ("1", "2", "3"):
        _wire_normal_phase(spawner, label)
    runner = StubTestRunner(queue=[_passing(), _passing(), _passing()])
    spawn = _scripted_spawner("passed")

    result = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=spawner,
            test_runner=runner,
            autonomous=True,
            ci_cmd="echo ci",
            ci_parity_spawn=spawn,
        )
    )

    assert result.status == "complete"
    assert len(result.state["completed_phases"]) == 3
    assert len(spawn.captured) == 1
    # The whole walk + inline gate consume happens in one lock acquisition.
    assert lock_counter.count == 1


def test_autonomous_3_phase_success_with_ci_parity_result_file(repo, lock_counter):
    """Production result-file path: conduct releases the lock before returning
    awaiting_ci_parity, then re-acquires on --resume to consume.
    """
    plan = _scratch_plan(repo, _plan_with_phases(3))
    spawner = StubSpawner(repo)
    for label in ("1", "2", "3"):
        _wire_normal_phase(spawner, label)
    runner = StubTestRunner(queue=[_passing(), _passing(), _passing()])

    # First invocation: no ci_parity_spawn → production path. Conduct should
    # complete the 3 phases and return awaiting_ci_parity.
    r1 = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=spawner,
            test_runner=runner,
            autonomous=True,
            ci_cmd="echo ci",
        )
    )
    assert r1.status == "awaiting_ci_parity"
    assert r1.request is not None
    plan_id = r1.request["plan_id"]
    written_at = r1.request["request_written_at_unix"]

    # Orchestrator writes the result file via the adapter. Sleep so the file
    # mtime is unambiguously >= state's ci_parity_request_written_at (HFS+ /
    # ext4 mtime resolution can otherwise tie at the same second and trip the
    # stale-by-timestamp guard).
    time.sleep(1.1)
    result_path = _ci_parity_result_path(
        ConductOptions(plan_path=plan, repo_root=repo, spawn=lambda req: ""),
        plan_id,
    )
    payload = _ci_parity_report(plan_id, written_at, "passed")
    _write_ci_parity_result(result_path, payload)

    # --resume consumes the result file.
    r2 = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=spawner,
            test_runner=runner,
            autonomous=True,
            ci_cmd="echo ci",
            resume=True,
        )
    )
    assert r2.status == "complete"
    assert len(r2.state["completed_phases"]) == 3
    # Two acquisitions: dispatch + resume-consume.
    assert lock_counter.count == 2


def test_autonomous_ci_parity_not_fired_after_intermediate_phase(repo, lock_counter):
    """Scripted spawner counter asserts gate is not invoked between phases."""
    plan = _scratch_plan(repo, _plan_with_phases(3))
    spawner = StubSpawner(repo)
    for label in ("1", "2", "3"):
        _wire_normal_phase(spawner, label)
    runner = StubTestRunner(queue=[_passing(), _passing(), _passing()])

    call_log: list[float] = []

    def counting_spawn(req: CIParitySpawnRequest) -> str:
        call_log.append(req.request_written_at_unix)
        return _ci_parity_report(req.plan_id, req.request_written_at_unix, "passed")

    result = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=spawner,
            test_runner=runner,
            autonomous=True,
            ci_cmd="echo ci",
            ci_parity_spawn=counting_spawn,
        )
    )
    assert result.status == "complete"
    # Exactly one ci-parity dispatch — and it happens after phase 3.
    assert len(call_log) == 1
    assert len(result.state["completed_phases"]) == 3


# ---------------------------------------------------------------------------
# Missing-counter reset rules
# ---------------------------------------------------------------------------


def _seed_awaiting_state(repo: Path, plan: Path, written_at: float, **overrides):
    plan_id = _compute_cross_runtime_plan_id(plan)
    opts = ConductOptions(plan_path=plan, repo_root=repo, spawn=lambda r: "")
    sp = _state_path(opts)
    sp.parent.mkdir(parents=True, exist_ok=True)
    state = {
        "plan_path": str(plan),
        "schema_version": 2,
        "completed_phases": [{"label": "1", "title": "x", "commit_sha": "abc"}],
        "iteration_count": 0,
        "status": "awaiting_ci_parity",
        "ci_parity_request": {
            "plan_path": str(plan),
            "base_sha": "",
            "head_sha": "",
            "ci_entrypoint_kind": "make",
            "ci_cmd": "make ci",
            "repo_root": str(repo),
            "plan_id": plan_id,
            "request_written_at_unix": written_at,
        },
        "ci_parity_request_written_at": written_at,
        "ci_parity_dispatched": False,
        "ci_parity_missing_resume_count": 0,
        "plan_id": plan_id,
        "state_author": "claude",
        "stall_signatures": [],
        "stall_count": 0,
    }
    state.update(overrides)
    sp.write_text(json.dumps(state))
    return plan_id


def test_ci_parity_missing_counter_resets_on_non_absent_outcome(repo):
    """absent → stale → absent → absent → absent (handback on the 3rd post-reset)."""
    plan = _scratch_plan(repo, _plan_with_phases(1))
    written_at = time.time()
    plan_id = _seed_awaiting_state(repo, plan, written_at)
    result_path = _ci_parity_result_path(
        ConductOptions(plan_path=plan, repo_root=repo, spawn=lambda r: ""),
        plan_id,
    )

    def resume() -> tuple[str, dict]:
        r = conduct(
            ConductOptions(
                plan_path=plan,
                repo_root=repo,
                spawn=StubSpawner(repo),
                test_runner=StubTestRunner(),
                ci_cmd="echo ci",
                resume=True,
            )
        )
        return r.status, r.state

    # Absent (1st).
    status, state = resume()
    assert status == "awaiting_ci_parity"
    assert state["ci_parity_missing_resume_count"] == 1

    # Stale: write a result file with plan_id mismatch — preflight ignores AND
    # resets the missing counter to 0.
    stale_payload = _ci_parity_report("ffffffffffff", written_at, "passed")
    _write_ci_parity_result(result_path, stale_payload)
    status, state = resume()
    assert status == "awaiting_ci_parity"
    assert state["ci_parity_missing_resume_count"] == 0

    # Remove the stale file so the next resume sees absent again.
    result_path.unlink()

    # Three consecutive absent observations post-reset → handback at the 3rd.
    status, state = resume()
    assert status == "awaiting_ci_parity"
    assert state["ci_parity_missing_resume_count"] == 1

    status, state = resume()
    assert status == "awaiting_ci_parity"
    assert state["ci_parity_missing_resume_count"] == 2

    status, state = resume()
    assert status == "blocked"
    assert "3 resume attempts" in (state.get("blocker") or "")


def test_ci_parity_missing_counter_resets_on_consume(repo):
    plan = _scratch_plan(repo, _plan_with_phases(1))
    written_at = time.time()
    plan_id = _seed_awaiting_state(repo, plan, written_at)
    result_path = _ci_parity_result_path(
        ConductOptions(plan_path=plan, repo_root=repo, spawn=lambda r: ""),
        plan_id,
    )

    def resume() -> tuple[str, dict]:
        r = conduct(
            ConductOptions(
                plan_path=plan,
                repo_root=repo,
                spawn=StubSpawner(repo),
                test_runner=StubTestRunner(),
                ci_cmd="echo ci",
                resume=True,
            )
        )
        return r.status, r.state

    # absent, absent
    status, state = resume()
    assert state["ci_parity_missing_resume_count"] == 1
    status, state = resume()
    assert state["ci_parity_missing_resume_count"] == 2

    # consume: write a valid result file.
    payload = _ci_parity_report(plan_id, written_at, "passed")
    _write_ci_parity_result(result_path, payload)
    status, state = resume()
    assert status == "complete"
    assert state["ci_parity_missing_resume_count"] == 0


# ---------------------------------------------------------------------------
# Result-file robustness sub-cases
# ---------------------------------------------------------------------------


def test_ci_parity_result_file_present_and_valid_consumes(repo):
    plan = _scratch_plan(repo, _plan_with_phases(1))
    written_at = time.time()
    plan_id = _seed_awaiting_state(repo, plan, written_at)
    result_path = _ci_parity_result_path(
        ConductOptions(plan_path=plan, repo_root=repo, spawn=lambda r: ""),
        plan_id,
    )
    _write_ci_parity_result(
        result_path, _ci_parity_report(plan_id, written_at, "passed")
    )

    r = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=StubSpawner(repo),
            test_runner=StubTestRunner(),
            ci_cmd="echo ci",
            resume=True,
        )
    )
    assert r.status == "complete"
    # File moved to .consumed-<unix>.json — active file gone.
    assert not result_path.exists()
    consumed = list(
        (repo / ".conduct").glob(f"ci-parity-result-{plan_id}.consumed-*.json")
    )
    assert consumed, "expected consumed result file on disk"


def test_ci_parity_stale_result_file_rejected(repo):
    """plan_id mismatch → preflight ignores, re-emits awaiting_ci_parity."""
    plan = _scratch_plan(repo, _plan_with_phases(1))
    written_at = time.time()
    plan_id = _seed_awaiting_state(repo, plan, written_at)
    result_path = _ci_parity_result_path(
        ConductOptions(plan_path=plan, repo_root=repo, spawn=lambda r: ""),
        plan_id,
    )
    # plan_id intentionally wrong.
    _write_ci_parity_result(
        result_path, _ci_parity_report("0" * 12, written_at, "passed")
    )

    r = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=StubSpawner(repo),
            test_runner=StubTestRunner(),
            ci_cmd="echo ci",
            resume=True,
        )
    )
    assert r.status == "awaiting_ci_parity"
    assert result_path.exists()  # stale file is preserved (just ignored)


def test_ci_parity_stale_by_timestamp_result_file_rejected(repo):
    """mtime older than state's ci_parity_request_written_at → stale."""
    plan = _scratch_plan(repo, _plan_with_phases(1))
    request_written_at = (
        time.time() + 60
    )  # state says "request was written in the future"
    plan_id = _seed_awaiting_state(repo, plan, request_written_at)
    result_path = _ci_parity_result_path(
        ConductOptions(plan_path=plan, repo_root=repo, spawn=lambda r: ""),
        plan_id,
    )
    # File reports the (correct) request_written_at but mtime is now (< state).
    # The mismatch in request_written_at also triggers stale.
    _write_ci_parity_result(
        result_path, _ci_parity_report(plan_id, time.time() - 120, "passed")
    )

    r = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=StubSpawner(repo),
            test_runner=StubTestRunner(),
            ci_cmd="echo ci",
            resume=True,
        )
    )
    assert r.status == "awaiting_ci_parity"


def test_ci_parity_stale_by_request_written_at_mismatch(repo):
    """request_written_at_unix mismatch between file and state → stale."""
    plan = _scratch_plan(repo, _plan_with_phases(1))
    state_written_at = time.time()
    plan_id = _seed_awaiting_state(repo, plan, state_written_at)
    result_path = _ci_parity_result_path(
        ConductOptions(plan_path=plan, repo_root=repo, spawn=lambda r: ""),
        plan_id,
    )
    # File reports a different request_written_at.
    _write_ci_parity_result(
        result_path,
        _ci_parity_report(plan_id, state_written_at - 999, "passed"),
    )

    r = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=StubSpawner(repo),
            test_runner=StubTestRunner(),
            ci_cmd="echo ci",
            resume=True,
        )
    )
    assert r.status == "awaiting_ci_parity"


def test_ci_parity_malformed_result_file_handback(repo):
    plan = _scratch_plan(repo, _plan_with_phases(1))
    written_at = time.time()
    plan_id = _seed_awaiting_state(repo, plan, written_at)
    result_path = _ci_parity_result_path(
        ConductOptions(plan_path=plan, repo_root=repo, spawn=lambda r: ""),
        plan_id,
    )
    # Write garbage that the parser will reject.
    _write_ci_parity_result(result_path, "{not valid json")

    r = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=StubSpawner(repo),
            test_runner=StubTestRunner(),
            ci_cmd="echo ci",
            resume=True,
        )
    )
    assert r.status == "schema_error"
    assert result_path.exists()  # malformed file is preserved for inspection


def test_ci_parity_missing_result_file_at_resume_counter_increments(repo):
    plan = _scratch_plan(repo, _plan_with_phases(1))
    written_at = time.time()
    _seed_awaiting_state(repo, plan, written_at)

    def resume_once():
        return conduct(
            ConductOptions(
                plan_path=plan,
                repo_root=repo,
                spawn=StubSpawner(repo),
                test_runner=StubTestRunner(),
                ci_cmd="echo ci",
                resume=True,
            )
        )

    r1 = resume_once()
    assert r1.status == "awaiting_ci_parity"
    assert r1.state["ci_parity_missing_resume_count"] == 1
    r2 = resume_once()
    assert r2.state["ci_parity_missing_resume_count"] == 2
    r3 = resume_once()
    assert r3.status == "blocked"
    assert "3 resume attempts" in (r3.state.get("blocker") or "")


def test_ci_parity_resume_during_awaiting_without_result_file(repo):
    """Idempotent re-emit when --resume hits awaiting + missing file."""
    plan = _scratch_plan(repo, _plan_with_phases(1))
    written_at = time.time()
    _seed_awaiting_state(repo, plan, written_at)

    r = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=StubSpawner(repo),
            test_runner=StubTestRunner(),
            ci_cmd="echo ci",
            resume=True,
        )
    )
    assert r.status == "awaiting_ci_parity"
    assert r.request is not None
    assert r.request["request_written_at_unix"] == written_at


def test_ci_parity_non_resume_against_awaiting_hard_fails(repo):
    plan = _scratch_plan(repo, _plan_with_phases(1))
    written_at = time.time()
    _seed_awaiting_state(repo, plan, written_at)

    r = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=StubSpawner(repo),
            test_runner=StubTestRunner(),
            ci_cmd="echo ci",
            # NOT resume=True
        )
    )
    assert r.status == "blocked"
    assert "awaiting_ci_parity" in (r.summary or "")
    assert "--resume" in (r.summary or "")


def test_ci_parity_atomic_write_survives_tmp_cleanup(repo):
    """Partial write before os.replace → preflight sees absent (not corrupt)."""
    plan = _scratch_plan(repo, _plan_with_phases(1))
    written_at = time.time()
    plan_id = _seed_awaiting_state(repo, plan, written_at)
    result_path = _ci_parity_result_path(
        ConductOptions(plan_path=plan, repo_root=repo, spawn=lambda r: ""),
        plan_id,
    )

    # Simulate: a tmp file landed but the rename never happened. The adapter's
    # contract is that callers either see the final file or no file — and any
    # tmp residue must not be picked up by preflight.
    result_path.parent.mkdir(parents=True, exist_ok=True)
    leftover_tmp = result_path.with_name(
        result_path.name + f".tmp-12345-{int(time.time())}"
    )
    leftover_tmp.write_text("{")  # corrupt-looking residue

    r = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=StubSpawner(repo),
            test_runner=StubTestRunner(),
            ci_cmd="echo ci",
            resume=True,
        )
    )
    # Preflight sees the active result_path as absent and re-emits.
    assert r.status == "awaiting_ci_parity"
    assert r.state["ci_parity_missing_resume_count"] == 1


def test_ci_parity_absent_active_but_matching_consumed_recovers(repo):
    """TOCTOU recovery: orchestrator consumed file already, no active file."""
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

    r = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=StubSpawner(repo),
            test_runner=StubTestRunner(),
            ci_cmd="echo ci",
            resume=True,
        )
    )
    assert r.status == "complete"
    assert r.state["ci_parity_dispatched"] is True


# ---------------------------------------------------------------------------
# Test/production code-path parity
# ---------------------------------------------------------------------------


def _normalised_state_for_diff(state: dict) -> dict:
    """Strip fields that legitimately differ between the two paths (e.g. mtime-
    derived markers, last_summary phrasing variants) so the remaining fields
    are byte-identical when both paths consume the same scripted report.
    """
    out = dict(state)
    # ci_parity_request_written_at and request payload depend on dispatch time
    # — keep them but the test seeds the same written_at on both sides.
    out.pop("resume_base_sha", None)
    out.pop("_internal", None)
    return out


def test_ci_parity_injection_and_result_file_paths_share_consume_code(
    repo, tmp_path_factory
):
    """Identical scripted report through both consume paths → byte-identical
    state mutations on the ci_parity_* fields and on status.
    """
    # Path A: injection (synchronous spawner consumes inline).
    repo_a = repo
    plan_a = _scratch_plan(repo_a, _plan_with_phases(1), name="a.md")
    spawner_a = StubSpawner(repo_a)
    _wire_normal_phase(spawner_a, "1")
    runner_a = StubTestRunner(queue=[_passing()])

    # Capture the dispatched request so Path B uses the same written_at.
    captured_a: list[CIParitySpawnRequest] = []

    def spawn_a(req: CIParitySpawnRequest) -> str:
        captured_a.append(req)
        return _ci_parity_report(
            req.plan_id,
            req.request_written_at_unix,
            "passed",
            summary="ok",
            command_run="echo ci",
        )

    result_a = conduct(
        ConductOptions(
            plan_path=plan_a,
            repo_root=repo_a,
            spawn=spawner_a,
            test_runner=runner_a,
            autonomous=True,
            ci_cmd="echo ci",
            ci_parity_spawn=spawn_a,
        )
    )
    assert result_a.status == "complete"

    # Path B: production result file.
    repo_b = tmp_path_factory.mktemp("repo_b")
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
    runner_b = StubTestRunner(queue=[_passing()])

    r1 = conduct(
        ConductOptions(
            plan_path=plan_b,
            repo_root=repo_b,
            spawn=spawner_b,
            test_runner=runner_b,
            autonomous=True,
            ci_cmd="echo ci",
        )
    )
    assert r1.status == "awaiting_ci_parity"
    plan_id_b = r1.request["plan_id"]
    written_at_b = r1.request["request_written_at_unix"]

    result_path_b = _ci_parity_result_path(
        ConductOptions(plan_path=plan_b, repo_root=repo_b, spawn=lambda r: ""),
        plan_id_b,
    )
    _write_ci_parity_result(
        result_path_b,
        _ci_parity_report(
            plan_id_b, written_at_b, "passed", summary="ok", command_run="echo ci"
        ),
    )

    r2 = conduct(
        ConductOptions(
            plan_path=plan_b,
            repo_root=repo_b,
            spawn=spawner_b,
            test_runner=runner_b,
            autonomous=True,
            ci_cmd="echo ci",
            resume=True,
        )
    )
    assert r2.status == "complete"

    # Compare the post-consume ci_parity_* fields. Both consume paths flow
    # through _consume_ci_parity_result, so these MUST match.
    a = result_a.state
    b = r2.state
    for key in ("status", "ci_parity_dispatched", "ci_parity_missing_resume_count"):
        assert a[key] == b[key], (key, a.get(key), b.get(key))
    # The reports compare equal modulo plan_id / written_at (which obviously
    # differ between repos). Strip those.
    rep_a = dict(a["ci_parity_result"])
    rep_b = dict(b["ci_parity_result"])
    rep_a.pop("plan_id")
    rep_b.pop("plan_id")
    rep_a.pop("request_written_at_unix")
    rep_b.pop("request_written_at_unix")
    assert rep_a == rep_b
    # last_summary is set from the same source.
    assert a["last_summary"] == b["last_summary"]


# ---------------------------------------------------------------------------
# Adapter invariant — result file always written through _write_ci_parity_result
# ---------------------------------------------------------------------------


def test_ci_parity_result_write_path_uses_adapter(repo, monkeypatch):
    """The ci-parity result file is written via _write_ci_parity_result →
    _atomic_write_result_file, and NOT via _safe_write_text directly.
    """
    plan = _scratch_plan(repo, _plan_with_phases(1))
    plan_id = _compute_cross_runtime_plan_id(plan)
    result_path = _ci_parity_result_path(
        ConductOptions(plan_path=plan, repo_root=repo, spawn=lambda r: ""),
        plan_id,
    )

    write_calls: list[Path] = []
    atomic_calls: list[Path] = []
    safe_write_calls: list[Path] = []

    real_atomic = conductor_mod._atomic_write_result_file
    real_safe = conductor_mod._safe_write_text
    real_adapter = conductor_mod._write_ci_parity_result

    def fake_adapter(path: Path, text: str) -> None:
        write_calls.append(Path(path))
        real_adapter(path, text)

    def fake_atomic(path: Path, text: str) -> None:
        atomic_calls.append(Path(path))
        real_atomic(path, text)

    def fake_safe_write(path: Path, text: str) -> None:
        safe_write_calls.append(Path(path))
        real_safe(path, text)

    monkeypatch.setattr(conductor_mod, "_write_ci_parity_result", fake_adapter)
    monkeypatch.setattr(conductor_mod, "_atomic_write_result_file", fake_atomic)
    monkeypatch.setattr(conductor_mod, "_safe_write_text", fake_safe_write)

    # Drive the full cycle: dispatch → orchestrator-write → consume.
    spawner = StubSpawner(repo)
    _wire_normal_phase(spawner, "1")
    runner = StubTestRunner(queue=[_passing()])
    r1 = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=spawner,
            test_runner=runner,
            autonomous=True,
            ci_cmd="echo ci",
        )
    )
    assert r1.status == "awaiting_ci_parity"

    # Orchestrator writes the result through the adapter.
    conductor_mod._write_ci_parity_result(
        result_path,
        _ci_parity_report(plan_id, r1.request["request_written_at_unix"], "passed"),
    )

    spawner2 = StubSpawner(repo)
    _wire_normal_phase(spawner2, "1")
    r2 = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=spawner2,
            test_runner=StubTestRunner(),
            autonomous=True,
            ci_cmd="echo ci",
            resume=True,
        )
    )
    assert r2.status == "complete"

    # _write_ci_parity_result was called on the result-file path.
    assert any(p == result_path for p in write_calls), write_calls
    # _atomic_write_result_file was called for the same path.
    assert any(p == result_path for p in atomic_calls), atomic_calls
    # _safe_write_text was NOT called on the result-file path directly — only
    # on its tmp sibling via the adapter, and on state-file writes elsewhere.
    direct_result_writes = [p for p in safe_write_calls if p == result_path]
    assert direct_result_writes == [], direct_result_writes


# ---------------------------------------------------------------------------
# Miscellaneous acceptance
# ---------------------------------------------------------------------------


def test_max_phases_default_resolves_to_phases_plus_one(repo, lock_counter):
    plan = _scratch_plan(repo, _plan_with_phases(2))
    spawner = StubSpawner(repo)
    for label in ("1", "2"):
        _wire_normal_phase(spawner, label)
    runner = StubTestRunner(queue=[_passing(), _passing()])
    spawn = _scripted_spawner("passed")

    # max_phases=None must resolve to len(phases)+1 = 3 — so 2 phases walk
    # under the cap and the gate fires.
    result = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=spawner,
            test_runner=runner,
            autonomous=True,
            ci_cmd="echo ci",
            ci_parity_spawn=spawn,
            max_phases=None,
        )
    )
    assert result.status == "complete"
    assert len(result.state["completed_phases"]) == 2


def test_incompatible_with_pre_vn_loader_passes_on_falsy_values(repo):
    """``incompatible_with_pre_vN: false`` / 0 → loader must NOT hard-fail."""
    from conductor import _load_or_init_state

    plan = _scratch_plan(repo, _plan_with_phases(1))
    opts = ConductOptions(
        plan_path=plan, repo_root=repo, spawn=lambda r: "", resume=True
    )
    sp = _state_path(opts)
    sp.parent.mkdir(parents=True, exist_ok=True)

    for falsy in (False, 0):
        sp.write_text(
            json.dumps(
                {
                    "plan_path": str(plan),
                    "schema_version": 2,
                    "completed_phases": [],
                    "iteration_count": 0,
                    "incompatible_with_pre_vN": falsy,
                }
            )
        )
        # Must not raise.
        state = _load_or_init_state(opts)
        assert state["plan_path"] == str(plan)


def test_ci_parity_resume_different_plan_id_unaffected(repo, tmp_path_factory):
    """Two distinct plans on disk; one awaiting; resume against the OTHER plan
    must not consume / interact with the first one's request.
    """
    plan_a = _scratch_plan(repo, _plan_with_phases(1), name="a.md")
    written_at = time.time()
    _seed_awaiting_state(repo, plan_a, written_at)

    # A second, independent plan in the same repo.
    plan_b = _scratch_plan(repo, _plan_with_phases(1), name="b.md")
    spawner = StubSpawner(repo)
    _wire_normal_phase(spawner, "1")
    runner = StubTestRunner(queue=[_passing()])

    # Walk plan B once — should complete its phase without touching plan A's
    # awaiting state.
    r = conduct(
        ConductOptions(
            plan_path=plan_b,
            repo_root=repo,
            spawn=spawner,
            test_runner=runner,
        )
    )
    # plan B has no autonomous → after phase 1 it hands back.
    assert r.status == "awaiting_user"

    # Plan A's state file untouched: still in awaiting_ci_parity.
    opts_a = ConductOptions(
        plan_path=plan_a, repo_root=repo, spawn=lambda r: "", resume=True
    )
    sp_a = _state_path(opts_a)
    state_a = json.loads(sp_a.read_text())
    assert state_a["status"] == "awaiting_ci_parity"
    assert state_a["ci_parity_request"]["request_written_at_unix"] == written_at


def test_ci_parity_prompt_placeholder_rendering(repo):
    """A fully-populated CIParitySpawnRequest can substitute every placeholder.

    The CI-parity prompt template lives at ``.claude/skills/conduct/ci-parity-prompt.md``.
    Substituting each ``{{NAME}}`` with the matching request field must remove
    every ``{{`` substring from the rendered output.
    """
    prompt_path = Path(__file__).resolve().parent.parent / "ci-parity-prompt.md"
    template = prompt_path.read_text()
    # The plan documents these as the placeholders supported by the template.
    assert "{{PLAN_PATH}}" in template
    assert "{{BASE_SHA}}" in template
    assert "{{HEAD_SHA}}" in template
    assert "{{CI_ENTRYPOINT_KIND}}" in template
    assert "{{CI_CMD}}" in template
    assert "{{REPO_ROOT}}" in template
    assert "{{PLAN_ID}}" in template
    assert "{{REQUEST_WRITTEN_AT_UNIX}}" in template

    req = CIParitySpawnRequest(
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
    # Each value appears at least once in the rendered output.
    for value in (
        req.plan_path,
        req.base_sha,
        req.head_sha,
        req.ci_entrypoint_kind,
        req.ci_cmd,
        req.repo_root,
        req.plan_id,
    ):
        assert value in rendered, value


def test_ci_parity_legacy_post_consume_resume_no_redispatch(repo):
    """Legacy non-autonomous: after the gate has consumed, a further --resume
    does NOT re-dispatch (guarded by state["ci_parity_dispatched"]).
    """
    plan = _scratch_plan(repo, _plan_with_phases(1))
    spawner = StubSpawner(repo)
    _wire_normal_phase(spawner, "1")
    runner = StubTestRunner(queue=[_passing()])
    spawn = _scripted_spawner("passed")

    # First invocation: walks phase 1 then hands back (non-autonomous).
    r1 = conduct(
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
    assert r1.status == "awaiting_user"
    assert len(spawn.captured) == 0

    # Resume: phases complete → gate fires, consumes.
    r2 = conduct(
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
    assert r2.status == "complete"
    assert len(spawn.captured) == 1

    # Resume again: must NOT re-dispatch.
    r3 = conduct(
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
    assert r3.status == "complete"
    assert len(spawn.captured) == 1  # NO second call


def test_ci_parity_cicmd_override_during_resume_keeps_request_stable(repo):
    """After dispatch, a --resume with a different --ci-cmd must not mutate the
    persisted in-flight ci_parity_request payload.
    """
    plan = _scratch_plan(repo, _plan_with_phases(1))
    spawner = StubSpawner(repo)
    _wire_normal_phase(spawner, "1")
    runner = StubTestRunner(queue=[_passing()])

    # Dispatch with detected entrypoint = "make ci".
    _seed_makefile(repo)
    r1 = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=spawner,
            test_runner=runner,
            autonomous=True,
        )
    )
    assert r1.status == "awaiting_ci_parity"
    original_cmd = r1.request["ci_cmd"]
    original_written_at = r1.request["request_written_at_unix"]

    # Resume with a different --ci-cmd; no result file. Request must be stable.
    r2 = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=spawner,
            test_runner=runner,
            autonomous=True,
            ci_cmd="echo override",
            resume=True,
        )
    )
    assert r2.status == "awaiting_ci_parity"
    assert r2.state["ci_parity_request"]["ci_cmd"] == original_cmd
    assert (
        r2.state["ci_parity_request"]["request_written_at_unix"] == original_written_at
    )
