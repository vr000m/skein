"""Section-fanout: split_into_sections, _needs_sections, assemble_rich_sections."""

from pathlib import Path

import generate as G


def _make_plan(tmp_path: Path, name: str, body: str) -> G.Plan:
    p = tmp_path / name
    p.write_text(body, encoding="utf-8")
    return G.parse_plan(p)


# ---------------------------------------------------------------------------
# split_into_sections
# ---------------------------------------------------------------------------


def test_split_no_h2_falls_back_to_body_section(tmp_path: Path) -> None:
    plan = _make_plan(
        tmp_path,
        "20260101-feature-no-headings.md",
        "# Title\n\nJust prose, no H2 headings anywhere.\n",
    )
    sections = G.split_into_sections(plan)
    assert len(sections) == 1
    assert sections[0].section_id == "body"
    assert sections[0].title == "Body"
    assert "Just prose" in sections[0].markdown


def test_split_preamble_then_h2_sections(tmp_path: Path) -> None:
    plan = _make_plan(
        tmp_path,
        "20260101-feature-preamble.md",
        "# Title\n\n**Status**: Shipped\n\n## Context\n\nctx\n\n## Plan\n\nplan body\n",
    )
    sections = G.split_into_sections(plan)
    ids = [s.section_id for s in sections]
    assert ids == ["preamble", "context", "plan"]
    # preamble captures the title + status, no H2 content
    assert "Status" in sections[0].markdown
    assert "## Context" not in sections[0].markdown
    # Context section is bounded
    assert sections[1].markdown.startswith("## Context")
    assert "## Plan" not in sections[1].markdown


def test_split_duplicate_h2_titles_get_unique_ids(tmp_path: Path) -> None:
    plan = _make_plan(
        tmp_path,
        "20260101-feature-dups.md",
        "## Notes\n\nfirst\n\n## Other\n\nx\n\n## Notes\n\nsecond\n\n## Notes\n\nthird\n",
    )
    sections = G.split_into_sections(plan)
    ids = [s.section_id for s in sections]
    # First "notes" keeps the base slug; subsequent get -2, -3 suffixes
    assert ids == ["notes", "other", "notes-2", "notes-3"]


def test_split_section_sha_changes_with_content(tmp_path: Path) -> None:
    plan_a = (
        _make_plan(
            tmp_path / "a",
            "20260101-feature-x.md",
            "## A\nbody\n",
        )
        if False
        else _make_plan(tmp_path, "20260101-feature-x.md", "## A\nbody\n")
    )
    sha_a = G.split_into_sections(plan_a)[0].section_sha
    plan_b = _make_plan(tmp_path, "20260101-feature-y.md", "## A\nbody changed\n")
    sha_b = G.split_into_sections(plan_b)[0].section_sha
    assert sha_a != sha_b


def test_split_empty_preamble_omitted(tmp_path: Path) -> None:
    # File starts directly with H2 — no preamble section should appear
    plan = _make_plan(tmp_path, "20260101-feature-z.md", "## Only\nbody\n")
    sections = G.split_into_sections(plan)
    ids = [s.section_id for s in sections]
    assert ids == ["only"]


# ---------------------------------------------------------------------------
# _needs_sections threshold
# ---------------------------------------------------------------------------


def test_needs_sections_small_plan_false(tmp_path: Path) -> None:
    plan = _make_plan(
        tmp_path, "20260101-feature-small.md", "## A\nshort\n\n## B\nalso\n"
    )
    assert G._needs_sections(plan) is False


def test_needs_sections_many_h2_true(tmp_path: Path) -> None:
    body = "".join(f"## H{i}\nbody\n\n" for i in range(G.SECTIONS_H2_THRESHOLD + 1))
    plan = _make_plan(tmp_path, "20260101-feature-many.md", body)
    assert G._needs_sections(plan) is True


def test_needs_sections_large_body_true(tmp_path: Path) -> None:
    body = "## Only\n" + ("x " * (G.SECTIONS_CHAR_THRESHOLD // 2 + 100))
    plan = _make_plan(tmp_path, "20260101-feature-big.md", body)
    assert G._needs_sections(plan) is True


# ---------------------------------------------------------------------------
# assemble_rich_sections — end-to-end stitching with hand-written fragments
# ---------------------------------------------------------------------------


SKILL_DIR = Path(G.__file__).resolve().parent


def _setup_corpus(tmp_path: Path) -> tuple[dict, Path, Path]:
    plans_dir = tmp_path / "plans"
    plans_dir.mkdir()
    out_dir = tmp_path / "out"
    out_dir.mkdir()
    (out_dir / "_fragments").mkdir()
    # Force-sections plan via H2 count > threshold
    body = "## Intro\nfirst\n\n" + "".join(
        f"## H{i}\nbody {i}\n\n" for i in range(G.SECTIONS_H2_THRESHOLD)
    )
    p = plans_dir / "20260101-feature-big.md"
    p.write_text(body, encoding="utf-8")
    plan = G.parse_plan(p)
    plans = {plan.slug: plan}
    return plans, plans_dir, out_dir


def test_assemble_skips_when_fragments_missing(tmp_path: Path) -> None:
    plans, plans_dir, out_dir = _setup_corpus(tmp_path)
    assembled, skipped, missing = G.assemble_rich_sections(
        plans, plans_dir, out_dir, SKILL_DIR
    )
    assert assembled == 0
    assert skipped == 1
    assert missing  # at least one missing-fragment line


def test_assemble_stitches_when_all_fragments_present(tmp_path: Path) -> None:
    plans, plans_dir, out_dir = _setup_corpus(tmp_path)
    plan = next(iter(plans.values()))
    sections = G.split_into_sections(plan)
    # Write a minimal fragment per section with the required sha header
    for sec in sections:
        frag = out_dir / "_fragments" / f"{plan.slug}__{sec.section_id}.html"
        frag.write_text(
            f"<!-- plan-view-rich-section-sha256: {sec.section_sha} -->\n"
            f"<p>fragment for {sec.title}</p>\n",
            encoding="utf-8",
        )
    assembled, skipped, missing = G.assemble_rich_sections(
        plans, plans_dir, out_dir, SKILL_DIR
    )
    assert assembled == 1
    assert skipped == 0
    assert not missing
    out_file = out_dir / f"plan-{plan.slug}.rich.html"
    assert out_file.exists()
    html = out_file.read_text(encoding="utf-8")
    # Embeds source sha (for next-run drift gate)
    assert f'plan-view-rich-source-sha256" content="{plan.sha256}"' in html
    # Strategy meta tag present
    assert 'plan-view-rich-strategy" content="sections"' in html
    # All fragment payloads stitched in
    for sec in sections:
        assert f"fragment for {sec.title}" in html
    # Tab labels for each section
    for sec in sections:
        assert f">{sec.title}<" in html
    # Tabs scaffold leading comment was stripped (no documentation comment leaks)
    assert "tabs.html — pure-CSS tabbed container" not in html


def test_assemble_skips_on_stale_fragment_sha(tmp_path: Path) -> None:
    plans, plans_dir, out_dir = _setup_corpus(tmp_path)
    plan = next(iter(plans.values()))
    sections = G.split_into_sections(plan)
    # Write all fragments correctly except one — that one carries a stale sha
    for i, sec in enumerate(sections):
        frag = out_dir / "_fragments" / f"{plan.slug}__{sec.section_id}.html"
        sha = "0" * 64 if i == 0 else sec.section_sha
        frag.write_text(
            f"<!-- plan-view-rich-section-sha256: {sha} -->\n<p>x</p>\n",
            encoding="utf-8",
        )
    assembled, skipped, missing = G.assemble_rich_sections(
        plans, plans_dir, out_dir, SKILL_DIR
    )
    assert assembled == 0
    assert skipped == 1
    # The missing report names the stale section
    assert any(sections[0].section_id in m for m in missing)


def test_h2_inside_code_fence_is_not_a_section_boundary(tmp_path: Path) -> None:
    # A `## ` line inside a fenced code block must not split the section (#4).
    body = (
        "# Title\n\n## Real Heading\n\n"
        "```\n## not a heading\nstill code\n```\n\nafter\n"
    )
    plan = _make_plan(tmp_path, "20260521-feature-fence.md", body)
    sections = G.split_into_sections(plan)
    ids = [s.section_id for s in sections]
    assert "not-a-heading" not in ids
    assert ids == ["preamble", "real-heading"]
    # The fenced pseudo-heading stays inside the real section's markdown
    assert "## not a heading" in sections[1].markdown


def test_needs_sections_ignores_fenced_h2(tmp_path: Path) -> None:
    # H2 count for the threshold must also skip fenced code blocks (#4).
    fenced = "```\n" + "\n".join(f"## fake {i}" for i in range(20)) + "\n```\n"
    plan = _make_plan(
        tmp_path, "20260521-feature-fenced-many.md", "## One\nx\n" + fenced
    )
    assert G._needs_sections(plan) is False
