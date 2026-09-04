"""Phase 3 state-schema migration tests for the Codex conductor."""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

import pytest

from conduct import conductor
from conduct.conductor import ConductOptions, _state_path
from conduct.marker import compute_plan_hash, write_marker


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


def _plan(repo: Path) -> Path:
    plan_dir = repo / "docs" / "dev_plans"
    plan_dir.mkdir(parents=True, exist_ok=True)
    plan = plan_dir / "20260513-schema-migration.md"
    plan.write_text(
        "\n".join(
            [
                "# Scratch",
                "## Implementation Checklist",
                "",
                "### Phase 1: Phase 1",
                "",
                "**Impl files:** src/p1.py",
                "**Test files:** tests/test_p1.py",
                "**Test command:** `true`",
                "",
                "- [ ] task 1",
                "",
            ]
        )
    )
    write_marker(plan)
    return plan


def _opts(repo: Path, plan: Path, **overrides) -> ConductOptions:
    return ConductOptions(
        plan_path=plan, repo_root=repo, spawn=lambda r: "", **overrides
    )


def _seed_state(opts: ConductOptions, payload: dict) -> Path:
    sp = _state_path(opts)
    sp.parent.mkdir(parents=True, exist_ok=True)
    sp.write_text(json.dumps(payload))
    return sp


def _base_state(repo: Path, plan: Path) -> dict:
    return {
        "plan_path": str(plan),
        "plan_content_hash": compute_plan_hash(plan),
        "base_sha": _git(["rev-parse", "HEAD"], repo).stdout.strip(),
        "completed_phases": [],
        "iteration_count": 0,
    }


def test_absent_schema_version_resumes_cleanly_and_persists_v2(repo) -> None:
    plan = _plan(repo)
    opts = _opts(repo, plan, resume=True)
    sp = _seed_state(opts, _base_state(repo, plan))

    state, existed = conductor._load_or_init_state(opts, compute_plan_hash(plan))
    assert existed is True
    assert state["schema_version"] == conductor.STATE_SCHEMA_VERSION
    assert state["state_author"] == "codex"
    assert state["stall_signatures"] == []
    assert state["stall_count"] == 0
    assert "plan_id" in state

    state["ci_parity_dispatched"] = False
    state["ci_parity_missing_resume_count"] = 0
    state["plan_id"] = conductor._compute_cross_runtime_plan_id(plan)
    conductor._persist_state(opts, state)
    on_disk = json.loads(sp.read_text())
    assert on_disk["schema_version"] == conductor.STATE_SCHEMA_VERSION
    assert on_disk["ci_parity_dispatched"] is False


def test_explicit_schema_version_1_resumes_cleanly_and_keeps_ci_fields(repo) -> None:
    plan = _plan(repo)
    opts = _opts(repo, plan, resume=True)
    sp = _seed_state(
        opts,
        _base_state(repo, plan)
        | {
            "schema_version": 1,
            "ci_parity_request": {"plan_id": "x", "request_written_at_unix": 1.0},
            "ci_parity_missing_resume_count": 2,
        },
    )

    state, existed = conductor._load_or_init_state(opts, compute_plan_hash(plan))
    assert existed is True
    assert state["schema_version"] == conductor.STATE_SCHEMA_VERSION
    assert state["ci_parity_request"]["plan_id"] == "x"
    assert state["ci_parity_missing_resume_count"] == 2

    conductor._persist_state(opts, state)
    on_disk = json.loads(sp.read_text())
    assert on_disk["schema_version"] == conductor.STATE_SCHEMA_VERSION
    assert on_disk["ci_parity_request"]["plan_id"] == "x"


def test_v2_state_file_roundtrips_phase3_fields(repo) -> None:
    plan = _plan(repo)
    opts = _opts(repo, plan, resume=True)
    full_v2 = _base_state(repo, plan) | {
        "schema_version": conductor.STATE_SCHEMA_VERSION,
        "stall_signatures": ["aaaa", "bbbb"],
        "stall_count": 1,
        "autonomous": True,
        "plan_id": "0123456789ab",
        "state_author": "codex",
        "ci_parity_request": {
            "plan_path": str(plan),
            "base_sha": "deadbeef",
            "head_sha": "cafebabe",
            "ci_entrypoint_kind": "make",
            "ci_cmd": "make ci",
            "repo_root": str(repo),
            "plan_id": "0123456789ab",
            "request_written_at_unix": 12345.0,
        },
        "ci_parity_request_written_at": 12345.0,
        "ci_parity_result": {"status": "passed"},
        "ci_parity_dispatched": True,
        "ci_parity_missing_resume_count": 0,
    }
    sp = _seed_state(opts, full_v2)

    state, existed = conductor._load_or_init_state(opts, compute_plan_hash(plan))
    assert existed is True
    for key, value in full_v2.items():
        if key == "autonomous":
            assert state[key] is True
        else:
            assert state[key] == value, key

    conductor._persist_state(opts, state)
    on_disk = json.loads(sp.read_text())
    for key in (
        "ci_parity_request",
        "ci_parity_request_written_at",
        "ci_parity_result",
        "ci_parity_dispatched",
        "ci_parity_missing_resume_count",
    ):
        assert on_disk[key] == full_v2[key], key


def test_unknown_schema_version_99_resumes_with_one_shot_stderr_warning(
    repo,
    capsys: pytest.CaptureFixture[str],
) -> None:
    plan = _plan(repo)
    opts = _opts(repo, plan, resume=True)
    conductor._UNKNOWN_SCHEMA_VERSION_WARNED = False
    _seed_state(
        opts,
        _base_state(repo, plan)
        | {
            "schema_version": 99,
            "ci_parity_dispatched": True,
            "ci_parity_missing_resume_count": 2,
        },
    )

    state, existed = conductor._load_or_init_state(opts, compute_plan_hash(plan))
    assert existed is True
    assert state["ci_parity_dispatched"] is True
    assert state["ci_parity_missing_resume_count"] == 2

    err = capsys.readouterr().err
    assert (
        "state file written by newer schema_version=99; reading known fields only"
        in err
    )

    conductor._load_or_init_state(opts, compute_plan_hash(plan))
    err = capsys.readouterr().err
    assert "state file written by newer schema_version=99" not in err
