"""Readiness contracts for registered text-only worker skills."""

import json
import re
from pathlib import Path

from test_package import ALLOWLIST, ROOT

READY = ("content-draft", "content-review")
SPECIALIZED = ("update-docs",)


def skill(name):
    return ROOT / f"plugins/skein-pi/skills/{name}/SKILL.md"


def test_manifest_registers_only_readiness_tested_skill_files():
    manifest = json.loads((ROOT / "package.json").read_text())
    assert manifest["pi"]["skills"] == ALLOWLIST
    assert manifest["pi"]["extensions"] == ["./plugins/skein-pi/extension.ts"]
    assert not any(
        "*" in path or path.endswith("/") for path in manifest["pi"]["skills"]
    )
    assert {Path(path).parent.name for path in manifest["pi"]["skills"]} == {
        "show-me",
        *READY,
        *SPECIALIZED,
        "dev-plan",
        "grill",
        "review-plan",
        "deep-review",
        "review-gauntlet",
        "conduct",
        "release",
    }


def test_worker_skills_have_pi_native_frontmatter_and_fail_closed_contracts():
    for name in READY:
        text = skill(name).read_text()
        _, frontmatter, body = text.split("---\n", 2)
        fields = dict(line.split(": ", 1) for line in frontmatter.strip().splitlines())
        assert fields["name"] == f"skein-{name}"
        assert re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", fields["name"])
        assert 0 < len(fields["description"]) <= 1024
        assert set(fields) == {"name", "description"}
        assert f"skein_content_{name.split('-')[1]}_worker" in body
        assert "mechanical role" in body
        assert '"schema_version": 1' in body
        assert '"status": "ok"' in body
        assert '"artifact"' in body
        assert "exact" in body and "approval" in body
        assert "never" in body.lower() and "file" in body.lower()
        assert "non-completed" in body
        for forbidden in (
            "CLAUDE_PLUGIN_ROOT",
            "$SKILL_DIR",
            "spawn_agent",
            "Agent tool",
            "model: sonnet",
            "skein:",
            "~/.claude",
            "~/.codex",
        ):
            assert forbidden not in text


def test_content_draft_confirmation_and_write_boundaries():
    text = skill("content-draft").read_text()
    for contract in (
        "ask the user to confirm the type and title",
        "Show that summary and ask the user to correct or confirm it",
        "Do not dispatch before confirmation",
        "Do not write it to disk unless the user explicitly asks",
        "status: 'draft'",
        "/skill:skein-content-review",
    ):
        assert contract in text
    assert "unregistered" not in text


def test_content_review_scope_and_edit_boundaries():
    text = skill("content-review").read_text()
    for contract in (
        "ask the user to confirm/change it",
        "one file at a time",
        "Never edit during review",
        "Apply nothing until the user explicitly chooses fixes",
        "verify the quoted original still matches",
        "Return at most 100 findings",
    ):
        assert contract in text
    assert "directory/glob" in text


def test_pi_references_are_complete_canonical_copies():
    canonical = ROOT / "plugins/skein-codex/skills/content-review/references"
    draft = ROOT / "plugins/skein-pi/skills/content-draft/references"
    review = ROOT / "plugins/skein-pi/skills/content-review/references"
    for name in ("content-guidelines.md", "ai-writing-signs.md"):
        assert (draft / name).read_bytes() == (canonical / name).read_bytes()
    for name in (
        "content-guidelines.md",
        "writing-style-rules.md",
        "ai-writing-signs.md",
    ):
        assert (review / name).read_bytes() == (canonical / name).read_bytes()


def test_review_worker_worst_case_ascii_prompt_fits_task_budget():
    """Pin the review input cap against the embedded references.

    The cap counts characters; the budget counts UTF-8 bytes. The assertion
    covers the ASCII worst case. Non-ASCII text can still exceed the budget and
    fails closed with task_too_large (documented in the content-review skill).
    """
    extension = (ROOT / "plugins/skein-pi/extension.ts").read_text()
    assert "const MAX_TASK_BYTES = 128 * 1024;" in extension
    match = re.search(
        r'type: StringEnum\(\["blog", "til", "technical-doc", "notion", "general"\] as const\),\s*'
        r"path: Type\.Optional\(Type\.String\(\{ maxLength: (\d+) \}\)\),\s*"
        r"content: Type\.String\(\{ minLength: 1, maxLength: (\d+) \}\)",
        extension,
    )
    assert match, "review worker schema changed; update this budget test"
    path_cap, content_cap = int(match.group(1)), int(match.group(2))
    assert content_cap == 90000
    references = ROOT / "plugins/skein-pi/skills/content-review/references"
    rules = max(
        len((references / "content-guidelines.md").read_bytes()),
        len((references / "writing-style-rules.md").read_bytes()),
    ) + len((references / "ai-writing-signs.md").read_bytes())
    scaffold_allowance = 4096  # prompt template text around the rules and content
    worst = rules + content_cap + path_cap + scaffold_allowance
    assert worst <= 128 * 1024, f"worst-case prompt {worst} bytes exceeds 128 KiB"


def test_worker_prompt_budget_has_no_silent_truncation():
    for name in READY:
        text = skill(name).read_text()
        assert "fails rather than silently truncating" in text
        assert "untrusted" in text
