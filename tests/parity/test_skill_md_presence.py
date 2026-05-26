"""Presence-only parity test for ``SKILL.md`` across managed skills.

For every entry in ``MANAGED_SKILLS`` (mirrored from
``scripts/check-prompt-parity.sh``), assert that BOTH
``plugins/skein/skills/<skill>/SKILL.md`` AND
``plugins/skein-codex/skills/<skill>/SKILL.md`` exist on disk.

This is intentionally a presence-only check. Content parity for SKILL.md
prompt blocks is handled by ``scripts/check-prompt-parity.sh`` (the
GENERIC FINDING SCHEMA AND MERGE block extraction). This test catches a
distinct failure mode: a runtime-side SKILL.md being absent altogether
(e.g. accidental deletion or a new skill added on one side only).

The repo root is detected by walking up from this file until a ``.git``
directory is found.
"""

from __future__ import annotations

from pathlib import Path

import pytest


def _repo_root() -> Path:
    here = Path(__file__).resolve()
    for parent in [here, *here.parents]:
        if (parent / ".git").exists():
            return parent
    raise RuntimeError(f"could not locate repo root from {here}")


# Intentionally asserts the repo-default managed skill set documented in
# scripts/check-prompt-parity.sh, not caller-scoped MANAGED_SKILLS overrides.
MANAGED_SKILLS = [
    "conduct",
    "content-draft",
    "content-review",
    "deep-review",
    "dev-plan",
    "fan-out",
    "plan-view",
    "review-plan",
    "rfc-finder",
    "spec-compliance",
    "update-docs",
]


@pytest.mark.parametrize("skill", MANAGED_SKILLS)
def test_skill_md_present_on_both_runtimes(skill: str) -> None:
    root = _repo_root()
    claude_skill_md = root / "plugins" / "skein" / "skills" / skill / "SKILL.md"
    codex_skill_md = root / "plugins" / "skein-codex" / "skills" / skill / "SKILL.md"
    assert claude_skill_md.is_file(), f"missing {claude_skill_md}"
    assert codex_skill_md.is_file(), f"missing {codex_skill_md}"
