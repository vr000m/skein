"""Golden-input tests for parse_plan, _find_edges, edge precedence, and href safety.

Lock the regex catalogue against silent drift as plan conventions evolve.
"""

from pathlib import Path

import generate as G


def _write(tmp_path: Path, name: str, body: str) -> Path:
    p = tmp_path / name
    p.write_text(body, encoding="utf-8")
    return p


def test_parse_plan_basic_status_and_title(tmp_path: Path) -> None:
    path = _write(
        tmp_path,
        "20260101-feature-thing.md",
        "# Thing\n\n**Status:** In Progress\n\n## Phases\n\n### Phase 1\n### Phase 2\n",
    )
    plan = G.parse_plan(path)
    assert plan.title == "Thing"
    assert plan.bucket == "in-progress"
    assert plan.phases_total == 2
    assert plan.slug == "20260101-feature-thing"


def test_parse_plan_checkbox_count_scoped_to_progress_section(tmp_path: Path) -> None:
    body = (
        "# T\n\n**Status:** Planned\n\n"
        "## Progress\n- [x] one\n- [ ] two\n- [x] three\n\n"
        "## Other\n- [ ] should not count\n"
    )
    plan = G.parse_plan(_write(tmp_path, "20260101-feature-x.md", body))
    assert (plan.progress_done, plan.progress_total) == (2, 3)


def test_find_edges_precedence(tmp_path: Path) -> None:
    # Same target appears as both a bare reference and a structural-fix-of —
    # higher-precedence kind must win and the duplicate must be dropped.
    body = (
        "Some text linking 20260101-bug-leak.md once.\n"
        "Structurally fixed by 20260101-bug-leak\n"
    )
    edges = G._find_edges(body)
    assert len(edges) == 1
    assert edges[0].kind == "structural-fix-of"
    assert edges[0].target_slug == "20260101-bug-leak"


def test_find_edges_recognises_all_kinds(tmp_path: Path) -> None:
    body = (
        "**Follows:** 20260101-feature-a\n"
        "tracked in 20260102-feature-b\n"
        "superseded by 20260103-feature-c\n"
        "structurally fixed by 20260104-bug-d\n"
        "stray ref to 20260105-feature-e.md\n"
    )
    kinds = {e.kind: e.target_slug for e in G._find_edges(body)}
    assert kinds["follows"] == "20260101-feature-a"
    assert kinds["tracked-in"] == "20260102-feature-b"
    assert kinds["supersedes"] == "20260103-feature-c"
    assert kinds["structural-fix-of"] == "20260104-bug-d"
    assert kinds["references"] == "20260105-feature-e"


def test_safe_href_blocks_javascript_and_data_urls() -> None:
    assert G._safe_href("javascript:alert(1)") == "#"
    assert G._safe_href("JavaScript:alert(1)") == "#"
    assert G._safe_href("data:text/html,<script>") == "#"
    assert G._safe_href("vbscript:msgbox") == "#"
    # Allowed
    assert G._safe_href("https://example.com") == "https://example.com"
    assert G._safe_href("http://example.com") == "http://example.com"
    assert G._safe_href("mailto:a@b.co") == "mailto:a@b.co"
    assert G._safe_href("/abs/path") == "/abs/path"
    assert G._safe_href("./rel.html") == "./rel.html"
    assert G._safe_href("plan-foo.html") == "plan-foo.html"
    assert G._safe_href("#anchor") == "#anchor"


def test_inline_md_link_strips_javascript() -> None:
    out = G._inline_md("click [here](javascript:alert(1))")
    assert "javascript:" not in out
    assert 'href="#"' in out


def test_link_edges_is_idempotent(tmp_path: Path) -> None:
    src = G.parse_plan(
        _write(
            tmp_path,
            "20260101-feature-src.md",
            "# Src\n\n**Status:** Shipped\n\nstructurally fixed by 20260101-bug-tgt\n",
        )
    )
    tgt = G.parse_plan(
        _write(tmp_path, "20260101-bug-tgt.md", "# Tgt\n\n**Status:** In Progress\n")
    )
    plans = {src.slug: src, tgt.slug: tgt}
    G.link_edges(plans)
    G.link_edges(plans)  # second call must not duplicate
    assert tgt.edges_in == [("structural-fix-of", src.slug)]
    assert tgt.fixed_by == src.slug


def test_render_sha_changes_when_corpus_state_changes(tmp_path: Path) -> None:
    a = G.parse_plan(
        _write(tmp_path, "20260101-feature-a.md", "# A\n\n**Status:** Planned\n")
    )
    b = G.parse_plan(
        _write(
            tmp_path,
            "20260101-feature-b.md",
            "# B\n\n**Status:** Shipped\n\nreferences 20260101-feature-a.md\n",
        )
    )
    # First scenario: a stands alone
    plans1 = {a.slug: G.parse_plan(a.path)}
    G.link_edges(plans1)
    G.compute_render_shas(plans1)
    sha_alone = plans1[a.slug].render_sha
    # Second scenario: b now references a — a's markdown is byte-identical
    plans2 = {a.slug: G.parse_plan(a.path), b.slug: G.parse_plan(b.path)}
    G.link_edges(plans2)
    G.compute_render_shas(plans2)
    sha_with_xref = plans2[a.slug].render_sha
    assert sha_alone != sha_with_xref, "render_sha must reflect backfilled edges_in"
