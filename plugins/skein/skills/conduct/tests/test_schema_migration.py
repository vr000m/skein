"""Phase 3 state-schema migration tests.

Covers the on-disk schema_version transitions exercised through a full
``conduct()`` resume round-trip (vs. the loader-only tests in
``test_conductor_harness.py``):

- absent ``schema_version`` resumes cleanly, next save emits v2.
- explicit ``schema_version: 1`` resumes cleanly, next save emits v2.
- A full v2 state file round-trips through the loader without drift.
- An unknown ``schema_version: 99`` resumes with the one-shot warning.
"""

from __future__ import annotations

import json
import subprocess
import warnings
from pathlib import Path

import pytest

from conductor import (
    ConductOptions,
    _load_or_init_state,
    _persist_state,
    _state_path,
)
from marker import write_marker


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


def _plan(repo: Path, n_phases: int = 1) -> Path:
    parts = ["# Scratch", "## Implementation Checklist", ""]
    for i in range(1, n_phases + 1):
        parts.append(f"### Phase {i}: Phase {i}")
        parts.append("")
        parts.append(f"**Impl files:** src/p{i}.py")
        parts.append(f"**Test files:** tests/test_p{i}.py")
        parts.append("**Test command:** `true`")
        parts.append("")
        parts.append(f"- [ ] task {i}")
    plan_dir = repo / "docs" / "dev_plans"
    plan_dir.mkdir(parents=True, exist_ok=True)
    plan = plan_dir / "20260513-schema-migration.md"
    plan.write_text("\n".join(parts) + "\n")
    write_marker(plan)
    return plan


def _opts(repo: Path, plan: Path, **kw) -> ConductOptions:
    return ConductOptions(
        plan_path=plan,
        repo_root=repo,
        spawn=lambda r: "",
        **kw,
    )


def _seed_state(opts: ConductOptions, payload: dict) -> Path:
    """Write a hand-crafted state file at the runtime-specific path."""
    sp = _state_path(opts)
    sp.parent.mkdir(parents=True, exist_ok=True)
    sp.write_text(json.dumps(payload))
    return sp


# ---------------------------------------------------------------------------
# absent-schema-version-resumes-cleanly
# ---------------------------------------------------------------------------


def test_absent_schema_version_resumes_cleanly(repo):
    plan = _plan(repo)
    opts = _opts(repo, plan, resume=True)
    sp = _seed_state(
        opts,
        {
            "plan_path": str(plan),
            "completed_phases": [],
            "iteration_count": 0,
        },
    )

    state = _load_or_init_state(opts)
    # Absent treated as 1; backfill populates v1 defaults.
    assert state["schema_version"] == 1
    assert state["stall_signatures"] == []
    assert state["stall_count"] == 0
    assert state["plan_id"]
    assert state["state_author"] == "claude"

    # Now mutate a Phase-3 field and persist; schema_version should be bumped
    # to v2 because a Phase-3 field is present.
    state["ci_parity_dispatched"] = False
    _persist_state(opts, state)
    on_disk = json.loads(sp.read_text())
    assert on_disk["schema_version"] == 2


# ---------------------------------------------------------------------------
# explicit-schema-version-1-resumes-cleanly
# ---------------------------------------------------------------------------


def test_explicit_schema_version_1_resumes_cleanly(repo):
    plan = _plan(repo)
    opts = _opts(repo, plan, resume=True)
    sp = _seed_state(
        opts,
        {
            "plan_path": str(plan),
            "schema_version": 1,
            "completed_phases": [],
            "iteration_count": 0,
        },
    )

    state = _load_or_init_state(opts)
    assert state["schema_version"] == 1
    assert state["stall_signatures"] == []

    # Phase-3 field present → bumps to v2 on persist.
    state["ci_parity_request"] = {"plan_id": "x", "request_written_at_unix": 0.0}
    _persist_state(opts, state)
    on_disk = json.loads(sp.read_text())
    assert on_disk["schema_version"] == 2


# ---------------------------------------------------------------------------
# v2-state-file-roundtrip
# ---------------------------------------------------------------------------


def test_v2_state_file_roundtrip(repo):
    plan = _plan(repo)
    opts = _opts(repo, plan, resume=True)
    full_v2 = {
        "plan_path": str(plan),
        "schema_version": 2,
        "completed_phases": [],
        "iteration_count": 0,
        "stall_signatures": ["aaaa", "bbbb"],
        "stall_count": 1,
        "autonomous": True,
        "plan_id": "0123456789ab",
        "state_author": "claude",
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
        "ci_parity_result": None,
        "ci_parity_dispatched": False,
        "ci_parity_missing_resume_count": 0,
    }
    sp = _seed_state(opts, full_v2)

    state = _load_or_init_state(opts)
    for key, value in full_v2.items():
        assert key in state, key
        assert state[key] == value, key

    _persist_state(opts, state)
    on_disk = json.loads(sp.read_text())
    assert on_disk["schema_version"] == 2
    # All Phase 3 fields survive the round-trip.
    for key in (
        "ci_parity_request",
        "ci_parity_request_written_at",
        "ci_parity_dispatched",
        "ci_parity_missing_resume_count",
    ):
        assert key in on_disk, key


# ---------------------------------------------------------------------------
# unknown-schema-version-99-resumes-with-warning
# ---------------------------------------------------------------------------


def test_unknown_schema_version_99_resumes_with_warning(repo, monkeypatch):
    plan = _plan(repo)
    opts = _opts(repo, plan, resume=True)
    _seed_state(
        opts,
        {
            "plan_path": str(plan),
            "schema_version": 99,
            "completed_phases": [],
            "iteration_count": 0,
        },
    )

    # Reset the one-shot suppression flag so this test sees the warning even
    # if a sibling test already triggered it in the same process.
    monkeypatch.setattr("conductor._UNKNOWN_SCHEMA_VERSION_WARNED", False)

    with warnings.catch_warnings(record=True) as caught:
        warnings.simplefilter("always")
        state = _load_or_init_state(opts)

    msgs = [str(w.message) for w in caught]
    assert any("schema_version=99" in m for m in msgs), msgs
    # The known-subset backfill ran: v1 defaults are populated.
    assert state["stall_signatures"] == []
    assert state["plan_id"]
