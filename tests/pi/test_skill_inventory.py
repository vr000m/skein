"""Keep the documented readiness matrix and shipped Pi surface aligned."""

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PLAN = ROOT / "docs/dev_plans/20260929-feature-pi-plugin-port.md"
READY = {"show-me", "content-draft", "content-review"}
SKIPPED = {"plan-view", "rfc-finder", "spec-compliance"}
EXPECTED = {
    "conduct",
    "content-draft",
    "content-review",
    "deep-review",
    "dev-plan",
    "fan-out",
    "grill",
    "plan-view",
    "release",
    "review-gauntlet",
    "review-plan",
    "rfc-finder",
    "show-me",
    "spec-compliance",
    "update-docs",
}


def test_inventory_covers_both_harnesses_and_exact_readiness():
    for mirror in ("skein", "skein-codex"):
        actual = {
            p.parent.name
            for p in (ROOT / "plugins" / mirror / "skills").glob("*/SKILL.md")
        }
        assert actual == EXPECTED
    text = PLAN.read_text().split("### Phase 1 capability inventory\n", 1)[1]
    table = text.split("### Phase 1 installation and verification", 1)[0]
    rows = [
        [cell.strip() for cell in line.strip("|").split("|")]
        for line in table.splitlines()
        if line.startswith("| ") and "/skill:skein-" in line
    ]
    assert len(rows) == 15
    assert {row[0] for row in rows} == EXPECTED
    for name, command, readiness, dependencies, claude, codex, pi in rows:
        assert command == f"`/skill:skein-{name}`"
        if name in READY:
            assert readiness == "ready"
        elif name in SKIPPED:
            assert readiness == "skipped (unavailable)"
        elif name == "update-docs":
            assert readiness == "implemented (review pending)"
        elif name in {"dev-plan", "grill"}:
            assert readiness.startswith("staged (Phase 3")
        else:
            assert readiness.startswith("blocked (Phase ")
        assert all((dependencies, claude, codex, pi))
    ready = [row[0] for row in rows if row[2] == "ready"]
    manifest = json.loads((ROOT / "package.json").read_text())
    assert manifest["pi"]["skills"] == [
        f"./plugins/skein-pi/skills/{name}/SKILL.md" for name in ready
    ]
    assert ready == ["show-me", "content-draft", "content-review"]


def test_show_me_port_is_standalone_and_pi_native():
    path = ROOT / "plugins/skein-pi/skills/show-me/SKILL.md"
    text = path.read_text()
    assert text.startswith("---\n")
    _, frontmatter, body = text.split("---\n", 2)
    fields = dict(line.split(": ", 1) for line in frontmatter.strip().splitlines())
    assert fields["name"] == "skein-show-me"
    assert re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", fields["name"])
    assert len(fields["name"]) <= 64
    assert 0 < len(fields["description"]) <= 1024
    assert set(fields) == {"name", "description"}
    assert set(re.findall(r"/skill:([a-z0-9-]+)", body)) == {"skein-show-me"}
    for forbidden in (
        "CLAUDE_PLUGIN_ROOT",
        "$SKILL_DIR",
        "spawn_agent",
        "Agent tool",
        "skein:",
        "~/.claude",
        "~/.codex",
    ):
        assert forbidden not in text
    for format_name in (
        "Pseudocode",
        "Call tree",
        "Component tree",
        "File tree",
        "Mermaid",
        "Diff",
        "HTML",
    ):
        assert format_name in body
    # Standalone replacements for the source mirror's external artifact helpers.
    for contract in (
        "no worker",
        "user's selected model",
        "ask what to visualise",
        "Do not overwrite",
        "Escape embedded source text",
        "avoid remote assets",
        "Do not open a browser or publish",
        "tree fallback",
        "unless asked",
    ):
        assert contract in body
