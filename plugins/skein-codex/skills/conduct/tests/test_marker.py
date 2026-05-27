"""Tests for review-marker hashing and writing.

Covers contract/workspace split semantics (marker-shaped lines in body must
NOT be stripped), hash idempotency across append-or-replace, and staleness
detection after a contract edit.

Runs ``git hash-object`` via subprocess; skips if git is not available.
"""

from __future__ import annotations

import shutil
import subprocess
import textwrap
from pathlib import Path

import pytest

from conduct.marker import (
    MARKER_RE,
    compute_plan_hash,
    marker_is_stale,
    read_marker,
    strip_marker_for_hashing,
    write_marker,
)


requires_git = pytest.mark.skipif(
    shutil.which("git") is None, reason="git not available"
)


def test_marker_regex_accepts_valid():
    assert MARKER_RE.match(
        "<!-- reviewed: 2026-04-22 @ 0123456789abcdef0123456789abcdef01234567 -->"
    )


def test_marker_regex_rejects_short_hash():
    assert not MARKER_RE.match("<!-- reviewed: 2026-04-22 @ 0123 -->")


def test_strip_leaves_body_marker_shaped_text_alone():
    plan = textwrap.dedent(
        """\
        # Plan

        Here is an example: `<!-- reviewed: 2026-04-22 @ {} -->`.

        And in a fence:

            <!-- reviewed: 2026-04-22 @ {} -->

        More body.
        """
    ).format("a" * 40, "b" * 40)
    assert strip_marker_for_hashing(plan) == plan


def test_strip_removes_trailing_marker_and_trailing_blanks():
    body = "# Plan\n\nsome text\n"
    marker = "<!-- reviewed: 2026-04-22 @ " + "c" * 40 + " -->"
    plan = body + marker + "\n\n"
    stripped = strip_marker_for_hashing(plan)
    assert stripped == body


def test_strip_removes_marker_and_workspace_below_it():
    body = "# Plan\n\nsome text\n"
    marker = "<!-- reviewed: 2026-04-22 @ " + "c" * 40 + " -->"
    workspace = "\n## Progress\n\n- [x] Phase 1: Done\n"
    stripped = strip_marker_for_hashing(body + marker + workspace)
    assert stripped == body


def test_strip_removes_template_placeholder_and_workspace_below_it():
    body = "# Plan\n\nsome text\n"
    placeholder = "<!-- reviewed: YYYY-MM-DD @ <hash> -->"
    workspace = "\n## Progress\n\n- [x] Phase 1: Done\n"
    stripped = strip_marker_for_hashing(body + placeholder + workspace)
    assert stripped == body


def test_strip_ignores_marker_shaped_text_inside_fence():
    plan = textwrap.dedent(
        f"""\
        # Plan

        ```
        <!-- reviewed: 2026-04-22 @ {"c" * 40} -->
        ```
        """
    )
    assert strip_marker_for_hashing(plan) == plan


@requires_git
def test_write_marker_idempotent_on_unchanged_plan(tmp_path: Path):
    plan_path = tmp_path / "plan.md"
    plan_path.write_text("# Plan\n\nbody\n")
    sha1 = write_marker(plan_path)
    sha2 = write_marker(plan_path)
    assert sha1 == sha2
    # Running twice must not stack markers — the final-line check gives one.
    lines = plan_path.read_text().splitlines()
    assert sum(1 for line in lines if MARKER_RE.match(line)) == 1


@requires_git
def test_write_marker_preserves_workspace_below_existing_marker(tmp_path: Path):
    plan_path = tmp_path / "plan.md"
    plan_path.write_text("# Plan\n\nbody\n")
    write_marker(plan_path)
    plan_path.write_text(
        plan_path.read_text()
        + "\n## Progress\n\n- [x] Phase 1: Done\n\n## Findings\n\n- Kept.\n"
    )

    sha1 = compute_plan_hash(plan_path)
    sha2 = write_marker(plan_path)
    text = plan_path.read_text()

    assert sha2 == sha1
    assert "## Progress\n\n- [x] Phase 1: Done" in text
    assert "## Findings\n\n- Kept." in text
    assert marker_is_stale(plan_path) is False


@requires_git
def test_write_marker_replaces_template_placeholder(tmp_path: Path):
    plan_path = tmp_path / "plan.md"
    plan_path.write_text(
        textwrap.dedent(
            """\
            # Plan

            body

            <!-- reviewed: YYYY-MM-DD @ <hash> -->
            <!-- /review-plan writes the marker line above. Everything below is workspace. -->

            ## Progress

            - [ ] Phase 1: First
            """
        )
    )

    assert read_marker(plan_path) is None
    sha = write_marker(plan_path)
    text = plan_path.read_text()

    assert "<!-- reviewed: YYYY-MM-DD @ <hash> -->" not in text
    iso, recorded_sha = read_marker(plan_path)
    assert recorded_sha == sha
    assert text.index("<!-- reviewed:") < text.index("## Progress")
    assert marker_is_stale(plan_path) is False

    plan_path.write_text(text.replace("- [ ] Phase 1: First", "- [x] Phase 1: First"))
    assert marker_is_stale(plan_path) is False


@requires_git
def test_write_marker_idempotent_when_only_blank_lines_below_marker(tmp_path: Path):
    """A marker followed only by trailing blank lines must not accumulate stray
    blank workspace on rewrite — the file should round-trip identically.
    """
    plan_path = tmp_path / "plan.md"
    plan_path.write_text("# Plan\n\nbody\n")
    write_marker(plan_path)
    plan_path.write_text(plan_path.read_text() + "\n\n\n")
    sha_first = write_marker(plan_path)
    text_first = plan_path.read_text()
    sha_second = write_marker(plan_path)
    assert sha_second == sha_first
    assert plan_path.read_text() == text_first
    assert not plan_path.read_text().endswith("\n\n\n")


@requires_git
def test_write_marker_updates_hash_when_body_changes(tmp_path: Path):
    plan_path = tmp_path / "plan.md"
    plan_path.write_text("# Plan\n\nbody v1\n")
    first = write_marker(plan_path)

    text = plan_path.read_text()
    # Mutate body but keep marker at end.
    lines = text.splitlines()
    lines[2] = "body v2"
    plan_path.write_text("\n".join(lines) + "\n")

    assert marker_is_stale(plan_path) is True
    second = write_marker(plan_path)
    assert first != second
    assert marker_is_stale(plan_path) is False


@requires_git
def test_read_marker_ignores_body_examples(tmp_path: Path):
    plan_path = tmp_path / "plan.md"
    plan_path.write_text(
        textwrap.dedent(
            f"""\
            # Plan

            Example in prose: `<!-- reviewed: 2020-01-01 @ {"d" * 40} -->`.
            """
        )
    )
    assert read_marker(plan_path) is None
    # Add a real marker; verify the reader picks the real one.
    sha = write_marker(plan_path)
    date_sha = read_marker(plan_path)
    assert date_sha is not None
    assert date_sha[1] == sha


@requires_git
def test_compute_plan_hash_matches_git_hash_object(tmp_path: Path):
    plan_path = tmp_path / "plan.md"
    plan_path.write_text("# Plan\n\nbody\n")
    expected = subprocess.check_output(
        ["git", "hash-object", str(plan_path)], text=True
    ).strip()
    assert compute_plan_hash(plan_path) == expected


# ---------------------------------------------------------------------------
# /review-plan auto-fix tier integration (Phase 3)
#
# An auto-fix run records `marker_pending` in its own manifest and applies
# prose edits, but never writes a real review marker. From the perspective of
# the conduct marker authority, the plan still has NO marker until the normal
# /review-plan Step 6 acceptance write runs. These tests pin that invariant
# so the auto-fix applier cannot silently bless an unmarked plan.
# ---------------------------------------------------------------------------


def test_marker_pending_plan_still_reads_as_unmarked(tmp_path: Path):
    """A plan that the auto-fix applier has edited (prose typo fix) but
    on which it has only recorded `marker_pending` in its manifest must
    still report `read_marker(...) is None` to the conduct runtime.

    `marker_pending` is a manifest status, NOT a plan-file state. The plan
    file itself carries no real marker line, so conduct preflight must
    refuse to run.
    """
    plan_path = tmp_path / "plan.md"
    plan_path.write_text("# Plan\n\nSome the prose with a typo to fix.\n")
    # No write_marker call — applier never writes the real marker.
    assert read_marker(plan_path) is None
    assert marker_is_stale(plan_path) is None  # sentinel: no marker


@requires_git
def test_acceptance_write_marker_unblocks_preflight(tmp_path: Path):
    """After the normal /review-plan acceptance step runs `write_marker`
    on the post-edit plan, the marker hash matches `git hash-object` of
    the stripped contract and `marker_is_stale` returns False — i.e. the
    /conduct preflight authority would accept the plan.
    """
    plan_path = tmp_path / "plan.md"
    plan_path.write_text("# Plan\n\nSome the prose with a typo to fix.\n")
    sha = write_marker(plan_path)
    assert read_marker(plan_path) is not None
    assert read_marker(plan_path)[1] == sha
    assert marker_is_stale(plan_path) is False


@requires_git
def test_marker_pending_then_workspace_progress_still_valid(tmp_path: Path):
    """After acceptance, the workspace below the marker may carry the
    auto-fix manifest summary or progress ticks. Those edits must not
    invalidate the marker (mirrors the workspace-below-marker invariant
    used by /conduct's marker-refresh tests).
    """
    plan_path = tmp_path / "plan.md"
    plan_path.write_text("# Plan\n\nSome the prose with a typo to fix.\n")
    write_marker(plan_path)
    plan_path.write_text(
        plan_path.read_text()
        + "\n## Progress\n\n- [x] auto-fix: prose_typo at plan.md:3\n"
    )
    assert marker_is_stale(plan_path) is False
