"""Tests for plan parsing.

Covers the phase heading regex (colons in title, parenthesised annotations,
non-contiguous numbering, non-numeric labels, already-completed phases) and
the Test command regex (backticks, multiple matches, malformed).
"""

from __future__ import annotations

import textwrap

from conduct.parser import (
    PHASE_HEADING_RE,
    TEST_COMMAND_RE,
    VALIDATION_COMMAND_RE,
    files_overlap,
    parse_phases,
    parse_progress,
)


def test_phase_heading_plain():
    m = PHASE_HEADING_RE.match("### Phase 1: Bootstrap")
    assert m and m.group(1) == "1" and m.group(2) == "Bootstrap"


def test_phase_heading_colon_in_title():
    m = PHASE_HEADING_RE.match("### Phase 2: review-plan: marker footer")
    assert m
    assert m.group(1) == "2"
    assert m.group(2) == "review-plan: marker footer"


def test_phase_heading_parenthesised_annotation_stripped():
    m = PHASE_HEADING_RE.match("### Phase 3a: Scaffolding (safe to parallelise)")
    assert m
    assert m.group(1) == "3a"
    assert m.group(2) == "Scaffolding"
    assert m.group(3) == "(safe to parallelise)"


def test_phase_heading_non_numeric_label():
    m = PHASE_HEADING_RE.match("### Phase alpha: Research spike")
    assert m and m.group(1) == "alpha"


def test_phase_heading_em_dash_separator():
    m = PHASE_HEADING_RE.match("### Phase 1 — Bootstrap")
    assert m and m.group(1) == "1" and m.group(2) == "Bootstrap"


def test_phase_heading_em_dash_no_surrounding_whitespace():
    m = PHASE_HEADING_RE.match("### Phase 1—Bootstrap")
    assert m and m.group(1) == "1" and m.group(2) == "Bootstrap"


def test_phase_heading_en_dash_separator():
    m = PHASE_HEADING_RE.match("### Phase 2a – Scaffolding (parallel)")
    assert m
    assert m.group(1) == "2a"
    assert m.group(2) == "Scaffolding"
    assert m.group(3) == "(parallel)"


def test_phase_heading_rejects_non_heading():
    assert PHASE_HEADING_RE.match("#### Phase 1: too deep") is None
    assert PHASE_HEADING_RE.match("### phase 1: lowercase") is None


def test_test_command_regex_matches_backticks():
    m = TEST_COMMAND_RE.match("**Test command:** `pytest -q`")
    assert m and m.group(1) == "pytest -q"


def test_test_command_regex_rejects_unbacked():
    assert TEST_COMMAND_RE.match("**Test command:** pytest -q") is None


def test_validation_command_regex_matches_backticks():
    m = VALIDATION_COMMAND_RE.match("**Validation cmd:** `python smoke.py`")
    assert m and m.group(1) == "python smoke.py"


def test_parse_phases_picks_phases_in_order_with_slots():
    plan = textwrap.dedent(
        """\
        # Some Plan

        ## Implementation Checklist

        ### Phase 1: First

        **Impl files:** src/a.py, src/b.py
        **Test files:** tests/test_a.py
        **Test command:** `pytest tests/test_a.py -v`

        - [x] done
        - [x] also done

        ### Phase 2: Second (optional)

        **Impl files:** src/c.py
        **Test files:** src/c.py
        **Test command:** `pytest tests/test_c.py`
        **Validation cmd:** `python verify.py`

        - [ ] todo

        ### Phase 3a: Third with colon: tail

        - [ ] todo

        ## Something Else
        """
    )
    phases = parse_phases(plan)
    labels = [(p.position, p.label, p.title) for p in phases]
    assert labels == [
        (0, "1", "First"),
        (1, "2", "Second"),
        (2, "3a", "Third with colon: tail"),
    ]
    assert phases[0].is_complete is True
    assert phases[1].is_complete is False
    assert phases[0].impl_files == ["src/a.py", "src/b.py"]
    assert phases[0].test_files == ["tests/test_a.py"]
    assert phases[0].test_command == "pytest tests/test_a.py -v"
    assert phases[1].test_command == "pytest tests/test_c.py"
    assert phases[1].validation_command == "python verify.py"
    # Missing slots → None
    assert phases[2].impl_files is None
    assert phases[2].test_files is None
    assert phases[2].test_command is None
    assert phases[2].validation_command is None


def test_parse_phases_multiple_test_commands_picks_first():
    plan = textwrap.dedent(
        """\
        ## Implementation Checklist

        ### Phase 1: Duplicates

        **Test command:** `first`
        **Test command:** `second`

        - [ ] x
        """
    )
    phases = parse_phases(plan)
    assert phases[0].test_command == "first"


def test_parse_file_slots_strip_optional_backticks():
    plan = textwrap.dedent(
        """\
        ## Implementation Checklist

        ### Phase 1: Backticked slots

        **Impl files:** `src/a.py, src/b.py`
        **Test files:** `tests/test_a.py`
        **Test command:** `pytest -q`

        - [ ] x
        """
    )
    phases = parse_phases(plan)
    assert phases[0].impl_files == ["src/a.py", "src/b.py"]
    assert phases[0].test_files == ["tests/test_a.py"]


def test_parse_phases_no_checklist_header_returns_empty():
    plan = "# No checklist here\n"
    assert parse_phases(plan) == []


def test_parse_phases_non_phase_h3_inside_body_does_not_end_phase():
    # Regression: a non-Phase `### Notes` subheading inside a phase body used
    # to silently reset current=None, dropping the rest of the phase. Now it
    # is absorbed as body content and the phase's checkboxes + slots remain
    # reachable.
    plan = textwrap.dedent(
        """\
        ## Implementation Checklist

        ### Phase 1: With subheading

        **Impl files:** src/a.py
        **Test command:** `pytest`

        ### Notes

        Some prose.

        - [x] done one
        - [x] done two

        ## Next Section
        """
    )
    phases = parse_phases(plan)
    assert len(phases) == 1
    assert phases[0].impl_files == ["src/a.py"]
    assert phases[0].test_command == "pytest"
    assert phases[0].is_complete is True


def test_parse_phases_h2_still_ends_phase_scope():
    plan = textwrap.dedent(
        """\
        ## Implementation Checklist

        ### Phase 1: Bounded

        - [ ] inside phase

        ## Technical Specifications

        - [ ] outside phase, must not count toward phase 1
        """
    )
    phases = parse_phases(plan)
    assert len(phases) == 1
    assert phases[0].is_complete is False
    # Only the in-phase checkbox contributes.
    assert sum(1 for line in phases[0].body_lines if "inside phase" in line) == 1
    assert not any("outside phase" in line for line in phases[0].body_lines)


def test_parse_progress_reads_below_marker_section():
    plan = textwrap.dedent(
        """\
        ## Implementation Checklist

        ### Phase 1: First

        **Test command:** `pytest`

        ### Phase 2: Second

        **Test command:** `pytest`

        <!-- reviewed: 2026-05-01 @ 0123456789abcdef0123456789abcdef01234567 -->

        ## Progress

        - [x] Phase 1: First
        - [ ] Phase 2: Second

        ## Findings
        - Phase 1 ran clean.
        """
    )
    progress = parse_progress(plan)
    assert progress == {"1": True, "2": False}


def test_parse_progress_drives_phase_completion():
    """Phase completion is sourced from the Progress section, not body checkboxes."""
    plan = textwrap.dedent(
        """\
        ## Implementation Checklist

        ### Phase 1: First

        **Test command:** `pytest`

        ### Phase 2: Second

        **Test command:** `pytest`

        <!-- reviewed: 2026-05-01 @ 0123456789abcdef0123456789abcdef01234567 -->

        ## Progress

        - [x] Phase 1: First
        - [ ] Phase 2: Second
        """
    )
    phases = parse_phases(plan)
    assert phases[0].is_complete is True
    assert phases[1].is_complete is False


def test_parse_progress_em_dash_separator_accepted():
    plan = textwrap.dedent(
        """\
        ## Implementation Checklist

        ### Phase 1: First

        **Test command:** `pytest`

        ## Progress

        - [x] Phase 1 — First
        """
    )
    progress = parse_progress(plan)
    assert progress == {"1": True}


def test_parse_progress_above_marker_is_ignored():
    """A ``## Progress`` heading placed in the contract section (above the
    review marker) must NOT bind. Otherwise a stray heading there would silently
    take precedence while edits to it would also bust the marker hash. Treat it
    as no-Progress-section so callers fall back to body checkboxes.
    """
    plan = textwrap.dedent(
        """\
        ## Implementation Checklist

        ### Phase 1: First

        **Test command:** `pytest`

        ## Progress

        - [x] Phase 1: First (this is in the contract — must be ignored)

        <!-- reviewed: 2026-05-01 @ 0123456789abcdef0123456789abcdef01234567 -->
        """
    )
    assert parse_progress(plan) is None


def test_parse_progress_present_but_label_missing_means_not_done():
    """When ``## Progress`` exists but a phase label isn't listed, the phase is
    not done. Do not silently fall back to body checkboxes (which the new
    template renders as plain bullets, never ticked).
    """
    plan = textwrap.dedent(
        """\
        ## Implementation Checklist

        ### Phase 1: First

        **Test command:** `pytest`

        - [x] task one
        - [x] task two

        ### Phase 2: Second

        **Test command:** `pytest`

        - [x] task

        <!-- reviewed: 2026-05-01 @ 0123456789abcdef0123456789abcdef01234567 -->

        ## Progress

        - [x] Phase 1: First
        """
    )
    phases = parse_phases(plan)
    assert phases[0].is_complete is True
    # Phase 2 has every body checkbox ticked but is not in Progress → still
    # not done. The fallback to body checkboxes only applies when there is no
    # Progress section at all.
    assert phases[1].is_complete is False


def test_parse_progress_absent_falls_back_to_body_checkboxes():
    """Old-format plans (no Progress section) keep the original semantics:
    completion comes from body checkbox state.
    """
    plan = textwrap.dedent(
        """\
        ## Implementation Checklist

        ### Phase 1: First

        **Test command:** `pytest`

        - [x] done one
        - [x] done two
        """
    )
    phases = parse_phases(plan)
    assert phases[0].is_complete is True


def test_files_overlap_detects_same_path():
    assert files_overlap(["src/a.py"], ["src/a.py"]) is True


def test_files_overlap_detects_subpath():
    assert files_overlap(["src/"], ["src/a.py"]) is True
    assert files_overlap(["src/a.py"], ["src"]) is True


def test_files_overlap_disjoint():
    assert files_overlap(["src/a.py"], ["tests/test_a.py"]) is False


def test_files_overlap_missing_slot_is_false():
    assert files_overlap(None, ["tests/test_a.py"]) is False
    assert files_overlap(["src/a.py"], None) is False
    assert files_overlap([], ["x"]) is False


def test_files_overlap_globs_are_conservative():
    # Cannot prove disjointness against glob entries → overlap True so
    # caller falls back to sequential.
    assert files_overlap(["src/*.py"], ["tests/test_a.py"]) is True
    assert files_overlap(["src/a.py"], ["tests/**/*.py"]) is True
    assert files_overlap(["src/[ab].py"], ["docs/x.md"]) is True
    assert files_overlap(["src/?.py"], ["docs/x.md"]) is True
    # Same glob on both sides → still overlap (was the silent-bug case).
    assert files_overlap(["src/*.py"], ["src/*.py"]) is True
