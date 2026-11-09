"""Guards for the skein.sh static site (site/).

The site is hand-written, so the risks are drift (a skill added without a
graph node, an install command that no longer matches the README) and CSP
breakage (the _headers policy forbids inline script and style).
"""

import json
import re
from html.parser import HTMLParser
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SITE = REPO / "site"
SKILLS = REPO / "plugins" / "skein" / "skills"
GRAPH = json.loads((SITE / "graph.json").read_text())
PAGES = [SITE / "index.html", SITE / "install" / "index.html", SITE / "404.html"]


def skill_names():
    return {p.parent.name for p in SKILLS.glob("*/SKILL.md")}


def test_every_skill_is_on_the_site_exactly_once():
    on_site = [n["id"] for n in GRAPH["nodes"] if n["kind"] == "skill"]
    on_site += [t["id"] for t in GRAPH["tools"]]
    assert len(on_site) == len(set(on_site)), "a skill appears twice on the site"
    assert set(on_site) == skill_names()


def test_graph_references_resolve():
    lanes = [lane["id"] for lane in GRAPH["lanes"]]
    groups = lanes + [b["id"] for b in GRAPH.get("bands", [])]
    ids = {n["id"] for n in GRAPH["nodes"]}
    by_id = {n["id"]: n for n in GRAPH["nodes"]}
    for n in GRAPH["nodes"]:
        assert n["lane"] in groups, n["id"]
        assert n["kind"] in {"skill", "builtin", "manual"}, n["id"]
        if "parent" in n:
            assert n["parent"] in ids and "parent" not in by_id[n["parent"]]
            assert by_id[n["parent"]]["lane"] == n["lane"]
    for e in GRAPH["edges"]:
        for end in (e["from"], e["to"]):
            assert end in ids, e
            assert "parent" not in by_id[end], f"edge touches a child node: {e}"
            assert by_id[end]["lane"] in lanes, f"edge touches a band node: {e}"
        # The renderer only draws forward cross-lane edges or same-lane ones.
        assert lanes.index(by_id[e["from"]]["lane"]) <= lanes.index(
            by_id[e["to"]]["lane"]
        ), e
    for n in GRAPH["nodes"]:
        for u in n.get("uses", []):
            assert u["id"] in ids and u["note"], (n["id"], u)
    known = ids | {t["id"] for t in GRAPH["tools"]}
    for t in GRAPH["tools"]:
        assert set(t["pairsWith"]) <= known, t["id"]


def test_install_commands_match_readme():
    readme = (REPO / "README.md").read_text()
    # The home page hero carries install commands too, so check both pages.
    # `.flow` blocks are example slash-commands, not install commands.
    for page in (SITE / "index.html", SITE / "install" / "index.html"):
        cmds = re.findall(r'<div class="cmd"><code>([^<]+)</code>', page.read_text())
        assert cmds, f"{page.name}: no install commands found"
        for cmd in cmds:
            assert cmd.replace("vX.Y.Z", "main") in readme, (
                f"{page.name}: not in README: {cmd}"
            )


class _Inline(HTMLParser):
    def __init__(self):
        super().__init__()
        self.problems = []
        self.links = []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "script" and "src" not in a:
            self.problems.append("inline <script>")
        if tag == "style":
            self.problems.append("inline <style>")
        if "style" in a:
            self.problems.append(f"style attribute on <{tag}>")
        if any(k.startswith("on") for k in a):
            self.problems.append(f"event handler attribute on <{tag}>")
        for key in ("href", "src"):
            if key in a:
                self.links.append(a[key])


def test_pages_satisfy_csp_and_internal_links_resolve():
    for page in PAGES:
        p = _Inline()
        p.feed(page.read_text())
        assert not p.problems, f"{page.name}: {p.problems}"
        for link in p.links:
            if link.startswith(("http://", "https://", "#", "mailto:")):
                continue
            path = link.split("#")[0].split("?")[0]
            if path == "/" or path == "":
                continue
            target = SITE / path.lstrip("/")
            ok = target.is_file() or (SITE / path.lstrip("/") / "index.html").is_file()
            assert ok, f"{page.name}: broken link {link}"


def test_wrangler_serves_site_dir():
    cfg = (REPO / "wrangler.jsonc").read_text()
    assert '"directory": "./site"' in cfg


def test_wrangler_has_no_stray_hostnames():
    cfg = (REPO / "wrangler.jsonc").read_text()
    assert '"workers_dev": false' in cfg
    assert '"preview_urls": false' in cfg
    assert '"pattern": "skein.sh"' in cfg and '"pattern": "www.skein.sh"' in cfg


def test_pages_declare_canonical_url():
    for page, url in [
        (SITE / "index.html", "https://skein.sh/"),
        (SITE / "install" / "index.html", "https://skein.sh/install/"),
    ]:
        assert f'<link rel="canonical" href="{url}">' in page.read_text(), page.name
