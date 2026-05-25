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
    assert 'href="plan-20260101-feature-y&quot; onclick=&quot;alert(1).rich.html"' in page
