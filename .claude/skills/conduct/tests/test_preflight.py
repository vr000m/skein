"""End-to-end preflight integration tests.

Composes marker check + plan parsing the way SKILL.md describes the conductor's
preflight, on synthetic plans with realistic edge cases:

- no marker → preflight rejects
- stale marker → preflight rejects
- valid marker on the same content → preflight accepts
- marker-shaped lines in the body do NOT cause false-positive marker reads
  (the conductor anchors only on the final non-empty line)
- phase parsing on a plan with completed phases, glob slots, and tricky titles

These cover Phase 6 manual scenarios "Preflight hard stop", "Preflight stale
marker", "Marker-in-body safety", and "Phase parsing" as integration checks
rather than ad-hoc shell invocations.
"""

from __future__ import annotations

import textwrap
from pathlib import Path

import pytest

from conductor import ConductOptions, run_preflight
from marker import (
    compute_plan_hash,
    marker_is_stale,
    read_marker,
    write_marker,
)
from parser import files_overlap, parse_phases


def _scratch_plan(tmp_path: Path, body: str) -> Path:
    plan = tmp_path / "20260422-scratch.md"
    plan.write_text(textwrap.dedent(body))
    return plan


PHASE_BODY = """\
# Scratch Plan

Some prose.

## Implementation Checklist

### Phase 1: First thing

**Impl files:** src/a.py
**Test files:** tests/test_a.py
**Test command:** `pytest tests/test_a.py -v`

- [ ] do the thing

### Phase 2: Second (with annotation)

**Impl files:** src/*.py
**Test files:** tests/test_b.py
**Test command:** `pytest -q`

- [ ] do the other thing

### Phase 3: Already done

**Impl files:** src/c.py

- [x] finished
- [x] also finished
"""


def test_preflight_rejects_unmarked_plan(tmp_path):
    plan = _scratch_plan(tmp_path, PHASE_BODY)
    assert read_marker(plan) is None
    assert marker_is_stale(plan) is None  # sentinel "no marker"


def test_preflight_accepts_freshly_marked_plan(tmp_path):
    plan = _scratch_plan(tmp_path, PHASE_BODY)
    sha = write_marker(plan)
    assert read_marker(plan) == (read_marker(plan)[0], sha)
    assert marker_is_stale(plan) is False


def test_preflight_detects_stale_marker(tmp_path):
    plan = _scratch_plan(tmp_path, PHASE_BODY)
    write_marker(plan)
    # Edit the body, not the marker.
    text = plan.read_text()
    plan.write_text(text.replace("First thing", "First thing (edited)"))
    assert marker_is_stale(plan) is True


def test_preflight_marker_in_body_does_not_falsely_validate(tmp_path):
    """Body contains marker-shaped lines (in prose AND inside a fenced block).
    Without a real trailing marker, preflight must report 'no marker' rather
    than picking up the in-body example.
    """
    body = PHASE_BODY + textwrap.dedent(
        """

            ## Notes

            Earlier reviews looked like:

                <!-- reviewed: 2025-12-01 @ 0123456789abcdef0123456789abcdef01234567 -->

            ```
            <!-- reviewed: 2025-12-02 @ fedcba9876543210fedcba9876543210fedcba98 -->
            ```
            """
    )
    plan = _scratch_plan(tmp_path, body)
    assert read_marker(plan) is None
    assert marker_is_stale(plan) is None


def test_preflight_marker_after_in_body_examples_is_the_one_that_counts(tmp_path):
    """Same scenario, but with a real trailing marker. The conductor must hash
    against the body (in-body examples included) and accept.
    """
    body = PHASE_BODY + textwrap.dedent(
        """

            ## Notes

            Earlier reviews looked like:

                <!-- reviewed: 2025-12-01 @ 0123456789abcdef0123456789abcdef01234567 -->
            """
    )
    plan = _scratch_plan(tmp_path, body)
    write_marker(plan)
    assert marker_is_stale(plan) is False
    iso, sha = read_marker(plan)
    # Sanity: the recorded sha matches the recomputed hash of the stripped body.
    assert sha == compute_plan_hash(plan)


def test_preflight_parses_phases_with_completion_and_glob_slots(tmp_path):
    plan = _scratch_plan(tmp_path, PHASE_BODY)
    phases = parse_phases(plan.read_text())
    labels = [(p.label, p.title, p.is_complete) for p in phases]
    assert labels == [
        ("1", "First thing", False),
        ("2", "Second", False),  # parenthesised annotation stripped
        ("3", "Already done", True),
    ]
    # Glob in phase 2 forces sequential fallback (per the C2 fix in parser.py).
    p2 = phases[1]
    assert files_overlap(p2.impl_files, p2.test_files) is True


def test_preflight_full_composition_happy_path(tmp_path):
    """Simulate what the conductor's preflight does:
    1. Read marker; bail if missing.
    2. Compare against current hash; bail if stale.
    3. Parse phases; pick first non-complete.
    """
    plan = _scratch_plan(tmp_path, PHASE_BODY)
    write_marker(plan)
    assert read_marker(plan) is not None
    assert marker_is_stale(plan) is False
    phases = parse_phases(plan.read_text())
    next_phase = next(p for p in phases if not p.is_complete)
    assert next_phase.label == "1"


@pytest.mark.parametrize(
    "mutation",
    [
        lambda t: t.replace("Phase 1", "Phase one"),
        lambda t: t.replace("- [ ] do the thing", "- [x] do the thing"),
    ],
)
def test_preflight_above_marker_change_invalidates_marker(tmp_path, mutation):
    """Any edit to the contract section (above the marker) must invalidate the
    marker. The conductor refuses to run on a stale plan and surfaces
    ``/review-plan`` as the recovery action.
    """
    plan = _scratch_plan(tmp_path, PHASE_BODY)
    write_marker(plan)
    plan.write_text(mutation(plan.read_text()))
    assert marker_is_stale(plan) is not False


def test_preflight_workspace_edits_below_marker_do_not_invalidate(tmp_path):
    """Editing the workspace below the marker (``## Progress``, ``## Findings``,
    appended notes) must NOT invalidate the marker. This is the entire point of
    moving progress out of the contract: the conductor or the user can tick
    boxes and append findings during a run without re-running ``/review-plan``.
    """
    plan = _scratch_plan(tmp_path, PHASE_BODY)
    write_marker(plan)
    text = plan.read_text()
    workspace = (
        "\n"
        "## Progress\n\n"
        "- [x] Phase 1: First thing\n"
        "- [ ] Phase 2: Second\n\n"
        "## Findings\n\n"
        "- Phase 1 turned up no surprises.\n"
    )
    plan.write_text(text + workspace)
    assert marker_is_stale(plan) is False


# ---------------------------------------------------------------------------
# Marker auto-refresh on resume (above-marker amendments mid-run)
# ---------------------------------------------------------------------------


def _opts(plan: Path, *, resume: bool, repo: Path) -> "ConductOptions":
    return ConductOptions(
        plan_path=plan,
        repo_root=repo,
        spawn=lambda req: "",
        lint_check=lambda: None,
        resume=resume,
    )


def _git_init(tmp_path: Path) -> Path:
    import subprocess

    subprocess.run(["git", "init", "-q"], cwd=str(tmp_path), check=True)
    subprocess.run(
        ["git", "config", "user.email", "harness@test"], cwd=str(tmp_path), check=True
    )
    subprocess.run(
        ["git", "config", "user.name", "Harness"], cwd=str(tmp_path), check=True
    )
    (tmp_path / "README.md").write_text("seed\n")
    subprocess.run(["git", "add", "README.md"], cwd=str(tmp_path), check=True)
    subprocess.run(["git", "commit", "-q", "-m", "seed"], cwd=str(tmp_path), check=True)
    return tmp_path


def test_run_preflight_hard_stops_on_stale_marker_without_resume(tmp_path, capsys):
    """Initial run (no --resume) on a stale marker must hard-stop — refreshing
    here would silently bless drift between /review-plan and the first phase.
    """
    repo = _git_init(tmp_path)
    plan = repo / "20260508-scratch.md"
    plan.write_text(textwrap.dedent(PHASE_BODY))
    write_marker(plan)
    plan.write_text(plan.read_text().replace("First thing", "First thing (edited)"))

    result = run_preflight(_opts(plan, resume=False, repo=repo))

    assert result is not None
    assert result.status == "preflight_fail"
    assert result.summary == "stale review marker"
    # Marker line is unchanged: the SHA recorded in the marker still points at
    # the pre-edit hash, and the in-place plan file still carries the original
    # marker.
    assert marker_is_stale(plan) is True


def test_run_preflight_auto_refreshes_marker_on_resume(tmp_path, capsys):
    """When a phase legitimately amends the contract section above the marker,
    --resume preflight rewrites the marker rather than failing — the user has
    already committed to this plan by starting the run.
    """
    repo = _git_init(tmp_path)
    plan = repo / "20260508-scratch.md"
    plan.write_text(textwrap.dedent(PHASE_BODY))
    write_marker(plan)
    pre_marker = read_marker(plan)
    assert pre_marker is not None

    plan.write_text(plan.read_text().replace("First thing", "First thing (edited)"))
    assert marker_is_stale(plan) is True  # sanity

    result = run_preflight(_opts(plan, resume=True, repo=repo))

    assert result is None  # preflight passes
    # Marker has been rewritten in place to match the new content.
    assert marker_is_stale(plan) is False
    post_marker = read_marker(plan)
    assert post_marker is not None
    assert post_marker[1] != pre_marker[1]  # SHA refreshed
    assert post_marker[1] == compute_plan_hash(plan)
    # User-visible info trail on stderr.
    captured = capsys.readouterr()
    assert "auto-refreshed on resume" in captured.err
    assert pre_marker[1][:12] in captured.err
    assert post_marker[1][:12] in captured.err


def test_run_preflight_resume_without_marker_still_hard_stops(tmp_path):
    """--resume does not bless an unmarked plan. Only stale (= already-marked-
    but-content-drifted) markers are auto-refreshed; missing markers still
    require /review-plan.
    """
    repo = _git_init(tmp_path)
    plan = repo / "20260508-scratch.md"
    plan.write_text(textwrap.dedent(PHASE_BODY))
    # No write_marker call — plan is unmarked.

    result = run_preflight(_opts(plan, resume=True, repo=repo))

    assert result is not None
    assert result.status == "preflight_fail"
    assert result.summary == "no review marker"
    assert read_marker(plan) is None  # still unmarked


# ---------------------------------------------------------------------------
# /review-plan auto-fix tier — `marker_pending` preflight regression (Phase 3)
#
# After a `/review-plan --auto-fix=trivial` run, the applier records
# `marker_pending` in its own manifest at .review-plan/auto-fix-<unix>.json
# and applies prose edits, but does NOT write a real `<!-- reviewed: ... -->`
# marker to the plan file. /conduct preflight MUST reject such a plan as
# unmarked — the auto-fix tier never grants /conduct eligibility on its own.
# Only the normal /review-plan Step 6 marker write (after user yes/waive)
# unblocks preflight.
# ---------------------------------------------------------------------------


def test_run_preflight_rejects_plan_with_marker_pending_manifest(tmp_path):
    """Simulate a post-auto-fix workspace: the plan has prose edits applied
    and a `.review-plan/auto-fix-<unix>.json` manifest with
    `status: marker_pending`, but no real marker line. Preflight MUST
    reject as unmarked — the auto-fix tier never grants /conduct
    eligibility on its own.
    """
    repo = _git_init(tmp_path)
    plan = repo / "20260516-scratch.md"
    plan.write_text(textwrap.dedent(PHASE_BODY))
    # Simulate the applier's manifest write WITHOUT a real marker.
    rp_dir = repo / ".review-plan"
    rp_dir.mkdir()
    (rp_dir / "auto-fix-1715000000.json").write_text(
        '[{"kind":"prose_typo","file":"20260516-scratch.md","line":3,'
        '"commit_sha":"deadbeef","before_sha":"cafebabe",'
        '"status":"marker_pending"}]\n'
    )

    result = run_preflight(_opts(plan, resume=False, repo=repo))

    assert result is not None
    assert result.status == "preflight_fail"
    assert result.summary == "no review marker"


def test_run_preflight_accepts_plan_after_acceptance_marker_write(tmp_path):
    """Round-trip: the auto-fix prose edits land, the manifest records
    marker_pending, the user accepts and /review-plan Step 6 calls
    write_marker, then preflight accepts the plan.
    """
    repo = _git_init(tmp_path)
    plan = repo / "20260516-scratch.md"
    plan.write_text(textwrap.dedent(PHASE_BODY))
    rp_dir = repo / ".review-plan"
    rp_dir.mkdir()
    (rp_dir / "auto-fix-1715000000.json").write_text(
        '[{"kind":"prose_typo","file":"20260516-scratch.md","line":3,'
        '"commit_sha":"deadbeef","before_sha":"cafebabe",'
        '"status":"marker_pending"}]\n'
    )
    # Acceptance step.
    sha = write_marker(plan)

    result = run_preflight(_opts(plan, resume=False, repo=repo))

    assert result is None  # preflight passes
    assert read_marker(plan) == (read_marker(plan)[0], sha)
    assert marker_is_stale(plan) is False
