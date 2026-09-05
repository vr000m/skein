"""Regression coverage for destructive legacy flat-skill cleanup."""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DELETE_SKILLS = ROOT / "scripts/delete-skills.sh"


def test_delete_skills_preserves_post_migration_personal_skills(
    tmp_path: Path,
) -> None:
    home = tmp_path / "home"
    personal_markers: list[Path] = []
    legacy_paths: list[Path] = []

    for harness in (".claude", ".codex"):
        skills = home / harness / "skills"
        for skill in ("grill", "release", "review-gauntlet"):
            personal_skill = skills / skill
            personal_skill.mkdir(parents=True, exist_ok=True)
            marker = personal_skill / "personal-marker.txt"
            marker.write_text("unrelated personal skill")
            personal_markers.append(marker)

        legacy_conduct = skills / "conduct"
        legacy_conduct.mkdir()
        (legacy_conduct / "SKILL.md").write_text("legacy skein copy")
        legacy_paths.append(legacy_conduct)

    env = os.environ.copy()
    env["HOME"] = str(home)
    subprocess.run(
        ["bash", str(DELETE_SKILLS)],
        check=True,
        capture_output=True,
        text=True,
        env=env,
    )

    assert all(
        marker.read_text() == "unrelated personal skill" for marker in personal_markers
    )
    assert all(not path.exists() for path in legacy_paths)
