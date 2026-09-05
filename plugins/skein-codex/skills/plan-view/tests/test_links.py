"""Cross-links between deterministic pages and their rich counterparts.

The rich link is emitted unconditionally from the deterministic filename
mapping (plan-<slug>.html <-> plan-<slug>.rich.html), so it appears whether or
not the rich file exists yet.
"""

from pathlib import Path

import generate as G

SKILL_DIR = Path(G.__file__).resolve().parent


def _make_plan(tmp_path: Path, name: str, body: str) -> G.Plan:
    p = tmp_path / name
    p.write_text(body, encoding="utf-8")
    return G.parse_plan(p)


def test_dashboard_card_links_to_rich(tmp_path: Path) -> None:
    plan = _make_plan(tmp_path, "20260101-feature-x.md", "# X\n\nbody\n")
    plans = {plan.slug: plan}
    card = G._render_card(plan, plans)
    assert f'href="plan-{plan.slug}.rich.html"' in card
    # Deterministic link still present alongside it.
    assert f'href="plan-{plan.slug}.html"' in card


def test_plan_page_header_links_to_rich(tmp_path: Path) -> None:
    plan = _make_plan(tmp_path, "20260101-feature-y.md", "# Y\n\nbody\n")
    plans = {plan.slug: plan}
    template = (SKILL_DIR / "plan-template.html").read_text(encoding="utf-8")
    page = G.render_plan_page(
        plan, plans, "abc1234", template, "generate.py", "~/plans"
    )
    assert f'href="plan-{plan.slug}.rich.html"' in page
    # Breadcrumb back to the dashboard is retained.
    assert 'href="index.html"' in page
    # No unsubstituted placeholder leaked.
    assert "{{RICH_HREF}}" not in page


def test_plan_page_rich_href_escapes_slug() -> None:
    plan = G.Plan(
        slug='20260101-feature-y" onclick="alert(1)',
        path=Path("20260101-feature-y.md"),
        raw="# Y\n",
        sha256="0" * 64,
        title="Y",
    )
    template = (SKILL_DIR / "plan-template.html").read_text(encoding="utf-8")
    page = G.render_plan_page(
        plan, {plan.slug: plan}, "abc1234", template, "generate.py", "~/plans"
    )
    assert (
        'href="plan-20260101-feature-y&quot; onclick=&quot;alert(1).rich.html"' in page
    )


# ---------------------------------------------------------------------------
# relink_rich_pages — deterministic back-link injection into existing rich pages
# ---------------------------------------------------------------------------


def _write_rich(out_dir: Path, slug: str, body_inner: str = "<h1>x</h1>") -> Path:
    p = out_dir / f"plan-{slug}.rich.html"
    p.write_text(
        f"<!doctype html><html><head></head><body>\n{body_inner}\n</body></html>\n",
        encoding="utf-8",
    )
    return p


def test_relink_injects_backlink_after_body(tmp_path: Path) -> None:
    slug = "20260101-feature-x"
    page = _write_rich(tmp_path, slug)
    relinked, skipped = G.relink_rich_pages(tmp_path)
    assert (relinked, skipped) == (1, 0)
    html = page.read_text(encoding="utf-8")
    assert G.RICH_BACKLINK_MARKER in html
    # Back-link targets derived from the filename slug.
    assert 'href="index.html"' in html
    assert f'href="plan-{slug}.html"' in html
    assert "deterministic view" in html
    # Injected immediately after the opening <body> tag, before page content.
    body_idx = html.index("<body>")
    assert html.index(G.RICH_BACKLINK_MARKER) < html.index("<h1>x</h1>")
    assert body_idx < html.index(G.RICH_BACKLINK_MARKER)


def test_relink_is_idempotent(tmp_path: Path) -> None:
    _write_rich(tmp_path, "20260101-feature-x")
    G.relink_rich_pages(tmp_path)
    page = tmp_path / "plan-20260101-feature-x.rich.html"
    first = page.read_text(encoding="utf-8")
    relinked, skipped = G.relink_rich_pages(tmp_path)
    assert (relinked, skipped) == (0, 1)
    assert page.read_text(encoding="utf-8") == first  # no double-inject
    assert first.count(G.RICH_BACKLINK_MARKER) == 1


def test_relink_skips_page_without_body(tmp_path: Path) -> None:
    p = tmp_path / "plan-20260101-feature-x.rich.html"
    p.write_text("<div>no body tag here</div>\n", encoding="utf-8")
    relinked, skipped = G.relink_rich_pages(tmp_path)
    assert (relinked, skipped) == (0, 1)
    assert G.RICH_BACKLINK_MARKER not in p.read_text(encoding="utf-8")


def test_relink_only_touches_rich_html(tmp_path: Path) -> None:
    # Deterministic pages must not be rewritten by the rich relink pass.
    (tmp_path / "plan-20260101-feature-x.html").write_text(
        "<html><body><h1>plain</h1></body></html>", encoding="utf-8"
    )
    (tmp_path / "index.html").write_text(
        "<html><body>dash</body></html>", encoding="utf-8"
    )
    relinked, _skipped = G.relink_rich_pages(tmp_path)
    assert relinked == 0
    assert G.RICH_BACKLINK_MARKER not in (
        tmp_path / "plan-20260101-feature-x.html"
    ).read_text(encoding="utf-8")


def test_relink_skips_symlinked_rich_page(tmp_path: Path) -> None:
    # A symlinked rich page must not be followed: the in-place rewrite could
    # otherwise escape out_dir and mutate a file elsewhere.
    target = tmp_path / "outside.html"
    target.write_text(
        "<!doctype html><html><body>\n<h1>secret</h1>\n</body></html>\n",
        encoding="utf-8",
    )
    link = tmp_path / "plan-20260101-feature-x.rich.html"
    link.symlink_to(target)
    relinked, skipped = G.relink_rich_pages(tmp_path)
    assert (relinked, skipped) == (0, 1)
    # The symlink target was left untouched.
    assert G.RICH_BACKLINK_MARKER not in target.read_text(encoding="utf-8")


def test_relink_skips_invalid_utf8(tmp_path: Path) -> None:
    # A rich page that is not valid UTF-8 was not produced by the generator;
    # skip it rather than lossily rewriting it with replacement characters.
    p = tmp_path / "plan-20260101-feature-x.rich.html"
    p.write_bytes(b"<html><body>\n\xff\xfe bad bytes\n</body></html>\n")
    before = p.read_bytes()
    relinked, skipped = G.relink_rich_pages(tmp_path)
    assert (relinked, skipped) == (0, 1)
    # File left byte-for-byte untouched (no U+FFFD substitution written back).
    assert p.read_bytes() == before
