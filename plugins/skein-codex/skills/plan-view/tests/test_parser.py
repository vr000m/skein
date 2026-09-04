"""Golden-input tests for parse_plan, _find_edges, edge precedence, and href safety.

Lock the regex catalogue against silent drift as plan conventions evolve.
"""

from pathlib import Path

import generate as G
import pytest


def test_field_parser_handles_colon_outside_bold(tmp_path: Path) -> None:
    # The documented form `**Field**: value` (colon AFTER the bold) must not
    # leak the colon into the captured value.
    body = (
        "# Title\n\n**Status**: Shipped\n**Branch**: feat/plan-view-skill\n"
        "**Created**: 2026-05-21\n"
    )
    p = tmp_path / "20260521-feature-x.md"
    p.write_text(body, encoding="utf-8")
    plan = G.parse_plan(p)
    assert plan.status_raw == "Shipped"
    assert plan.branch == "feat/plan-view-skill"
    assert plan.created == "2026-05-21"


def test_field_parser_handles_colon_inside_bold(tmp_path: Path) -> None:
    # The older form `**Field:** value` (colon INSIDE the bold) still works.
    body = "# Title\n\n**Status:** Shipped\n**Branch:** feat/x\n"
    p = tmp_path / "20260521-feature-y.md"
    p.write_text(body, encoding="utf-8")
    plan = G.parse_plan(p)
    assert plan.status_raw == "Shipped"
    assert plan.branch == "feat/x"


def test_component_read_from_field_not_slug(tmp_path: Path) -> None:
    # Component comes from the **Component** field, not a slug heuristic.
    body = "# Title\n\n**Status**: Shipped\n**Component**: plan-view\n"
    p = tmp_path / "20260521-feature-bot-harness.md"
    p.write_text(body, encoding="utf-8")
    plan = G.parse_plan(p)
    assert plan.component == "plan-view"


def test_component_from_field_table_row(tmp_path: Path) -> None:
    body = (
        "# Title\n\n| Field | Value |\n|---|---|\n"
        "| **Status** | Shipped |\n| **Component** | Review Skills |\n"
    )
    p = tmp_path / "20260521-feature-x.md"
    p.write_text(body, encoding="utf-8")
    # Case-normalised + whitespace-collapsed grouping key.
    assert G.parse_plan(p).component == "review skills"


def test_component_missing_falls_to_uncategorized(tmp_path: Path) -> None:
    p = tmp_path / "20260521-feature-x.md"
    p.write_text("# Title\n\n**Status**: Planned\n", encoding="utf-8")
    assert G.parse_plan(p).component == G.UNCATEGORIZED


def test_component_case_normalised(tmp_path: Path) -> None:
    p1 = tmp_path / "20260101-feature-a.md"
    p1.write_text("# A\n\n**Component**: ASR\n", encoding="utf-8")
    p2 = tmp_path / "20260102-feature-b.md"
    p2.write_text("# B\n\n**Component**:   asr  \n", encoding="utf-8")
    assert G.parse_plan(p1).component == G.parse_plan(p2).component == "asr"


def test_component_multi_takes_primary(tmp_path: Path) -> None:
    p = tmp_path / "20260101-feature-a.md"
    p.write_text("# A\n\n**Component**: api, data, frontend\n", encoding="utf-8")
    assert G.parse_plan(p).component == "api"


def test_render_plan_page_escapes_component(tmp_path: Path) -> None:
    p = tmp_path / "20260101-feature-a.md"
    p.write_text(
        "# A\n\n**Status**: Planned\n**Component**: <img src=x onerror=alert(1)>\n",
        encoding="utf-8",
    )
    plan = G.parse_plan(p)
    html = G.render_plan_page(
        plan,
        {plan.slug: plan},
        git_head_sha="",
        template="<code>{{COMPONENT}}</code>",
        script_path="plugins/skein-codex/skills/plan-view/generate.py",
        plans_dir_short="docs/dev_plans",
    )
    assert "<img" not in html
    assert "&lt;img src=x onerror=alert(1)&gt;" in html


def test_render_plan_page_escapes_source_path(tmp_path: Path) -> None:
    p = tmp_path / '20260101-feature-"<img>.md'
    p.write_text("# A\n\n**Status**: Planned\n", encoding="utf-8")
    plan = G.parse_plan(p)
    html = G.render_plan_page(
        plan,
        {plan.slug: plan},
        git_head_sha="",
        template='<meta content="{{SOURCE_PATH}}">',
        script_path="plugins/skein-codex/skills/plan-view/generate.py",
        plans_dir_short="docs/dev_plans",
    )
    assert "<img" not in html
    assert "&quot;&lt;img&gt;" in html


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


def test_inline_md_link_does_not_double_escape_ampersand() -> None:
    out = G._inline_md("see [docs](https://x.com/a?b=1&c=2)")
    assert 'href="https://x.com/a?b=1&amp;c=2"' in out
    assert "&amp;amp;" not in out


def test_inline_md_link_escapes_quote_in_href() -> None:
    # A double-quote in the URL must not break out of the href attribute.
    out = G._inline_md('[x](/a"onmouseover=alert(1))')
    assert '"onmouseover' not in out
    assert "&quot;onmouseover" in out


def test_inline_md_does_not_format_inside_inline_code() -> None:
    # Bold/italic/link markers inside `code` must stay literal.
    assert G._inline_md("a `**b**` c") == "a <code>**b**</code> c"
    out = G._inline_md("mix `x&y` and **b** and [t](/p)")
    assert "<code>x&amp;y</code>" in out
    assert "<strong>b</strong>" in out
    assert '<a href="/p">t</a>' in out


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


def test_self_reference_does_not_create_self_edge(tmp_path: Path) -> None:
    # A plan mentioning its own filename must not link to itself (review #5).
    slug = "20260521-feature-self"
    body = f"# Self\n\n**Status:** Shipped\n\nsee the original {slug}.md for context\n"
    p = tmp_path / f"{slug}.md"
    p.write_text(body, encoding="utf-8")
    plan = G.parse_plan(p)
    assert all(e.target_slug != slug for e in plan.edges_out)
    plans = {slug: plan}
    G.link_edges(plans)
    assert plans[slug].edges_in == []


def test_frontmatter_closing_fence_at_eof(tmp_path: Path) -> None:
    # Closing `---` as the final line with no trailing newline must still parse
    # (review #6) — including a frontmatter-only file.
    fm, body = G._strip_frontmatter("---\ntitle: X\nbranch: feat/y\n---")
    assert fm == {"title": "X", "branch": "feat/y"}
    assert body == ""


def test_branch_value_strips_surrounding_backticks(tmp_path: Path) -> None:
    # The merged field parser keeps strip_backticks behaviour for Branch (#2).
    body = "# T\n\n**Status:** Shipped\n**Branch:** `feat/with-ticks`\n"
    p = tmp_path / "20260521-feature-ticks.md"
    p.write_text(body, encoding="utf-8")
    plan = G.parse_plan(p)
    assert plan.branch == "feat/with-ticks"


def test_render_sha_reflects_commit_changes(tmp_path: Path) -> None:
    # render_sha must fold in git-derived fields so a changed commit subject
    # shifts it — otherwise the drift guard falsely refuses a regen (#1).
    p = tmp_path / "20260521-feature-commits.md"
    p.write_text("# C\n\n**Status:** Shipped\n", encoding="utf-8")
    plan = G.parse_plan(p)
    plan.commits = [G.Commit(sha="a" * 40, date="2026-05-21", subject="initial")]
    before = plan.compute_render_sha()
    plan.commits = [G.Commit(sha="a" * 40, date="2026-05-21", subject="reworded")]
    after = plan.compute_render_sha()
    assert before != after, "render_sha must change when a commit subject changes"


def test_render_sha_reflects_rendered_script_path(tmp_path: Path) -> None:
    p = tmp_path / "20260521-feature-script-path.md"
    p.write_text("# C\n\n**Status:** Shipped\n", encoding="utf-8")
    plan = G.parse_plan(p)
    before = plan.compute_render_sha("~/old/generate.py")
    after = plan.compute_render_sha("~/new/generate.py")
    assert before != after, "render_sha must change with the rendered script path"


def test_render_sha_reflects_relocated_source_and_plans_directory(tmp_path: Path) -> None:
    first_dir = tmp_path / "first" / "docs" / "dev_plans"
    second_dir = tmp_path / "second" / "docs" / "dev_plans"
    first_dir.mkdir(parents=True)
    second_dir.mkdir(parents=True)
    body = "# C\n\n**Status**: Shipped\n"
    first_path = _write(first_dir, "20260521-feature-relocation.md", body)
    second_path = _write(second_dir, "20260521-feature-relocation.md", body)
    first = G.parse_plan(first_path)
    second = G.parse_plan(second_path)
    first_plans = {first.slug: first}
    second_plans = {second.slug: second}
    G.compute_render_shas(first_plans, plans_dir_short="~/first/docs/dev_plans")
    G.compute_render_shas(second_plans, plans_dir_short="~/second/docs/dev_plans")
    assert first.render_sha != second.render_sha
    assert G.corpus_sha(first_plans, first_dir) != G.corpus_sha(second_plans, second_dir)


def test_render_markdown_code_fence_keeps_language_class() -> None:
    # Regression: a section-scanner fence regex once shadowed the markdown
    # renderer's _FENCE_RE (module-global name collision), making fenced code
    # emit class="lang-```" instead of the captured language.
    out = G.render_markdown("```python\nx = 1\n```\n")
    assert 'class="lang-python"' in out
    assert "lang-```" not in out


@pytest.mark.parametrize(
    "src",
    [
        "```mermaid\ngraph LR\n    A-->B\n```\n",
        "```mermaid\ngraph LR\n    A-->B\n```",  # no trailing newline before EOF
    ],
)
def test_render_markdown_mermaid_fence(src: str) -> None:
    out = G.render_markdown(src)
    assert '<pre class="mermaid">' in out
    assert '<code class="lang-mermaid">' not in out


def test_render_markdown_mermaid_fence_empty() -> None:
    out = G.render_markdown("```mermaid\n```\n")
    assert '<pre class="mermaid"></pre>' in out


def test_templates_load_mermaid_runtime() -> None:
    from pathlib import Path as _P

    skill_dir = _P(G.__file__).resolve().parent
    for name in ("template.html", "plan-template.html"):
        html_text = (skill_dir / name).read_text(encoding="utf-8")
        head_idx = html_text.index("</head>")
        before_head = html_text[:head_idx]
        assert "mermaid.esm.min.mjs" in before_head, (
            f"{name}: mermaid script missing before </head>"
        )
        assert 'type="module"' in before_head, (
            f"{name}: module script tag missing before </head>"
        )


def test_footer_script_path_is_repo_relative_inside_repo(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    script = repo / "plugins" / "skein" / "skills" / "plan-view" / "generate.py"
    script.parent.mkdir(parents=True)
    script.write_text("", encoding="utf-8")
    assert (
        G.footer_script_path(script, repo)
        == "plugins/skein/skills/plan-view/generate.py"
    )


def test_footer_script_path_outside_repo_hides_home(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    home = tmp_path / "home"
    cache = home / ".claude" / "plugins" / "cache" / "skein" / "skills" / "plan-view"
    cache.mkdir(parents=True)
    script = cache / "generate.py"
    script.write_text("", encoding="utf-8")
    repo = tmp_path / "elsewhere"
    repo.mkdir()
    monkeypatch.setattr(Path, "home", classmethod(lambda cls: home))
    out = G.footer_script_path(script, repo)
    assert out.startswith("~/"), out
    assert str(home) not in out
    assert out == "~/.claude/plugins/cache/skein/skills/plan-view/generate.py"


def test_footer_script_path_home_root_is_tilde(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    home = tmp_path / "home"
    home.mkdir()
    repo = tmp_path / "elsewhere"
    repo.mkdir()
    monkeypatch.setattr(Path, "home", classmethod(lambda cls: home))
    assert G.footer_script_path(home, repo) == "~"


def test_footer_script_path_does_not_shorten_home_prefix_sibling(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    home = tmp_path / "alice"
    sibling = tmp_path / "alice2" / "cache" / "generate.py"
    sibling.parent.mkdir(parents=True)
    sibling.write_text("", encoding="utf-8")
    repo = tmp_path / "elsewhere"
    repo.mkdir()
    monkeypatch.setattr(Path, "home", classmethod(lambda cls: home))
    assert G.footer_script_path(sibling, repo) == str(sibling.resolve())
