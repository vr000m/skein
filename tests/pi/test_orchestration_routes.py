"""Pi conduct/release route safety contracts; no provider or remote mutation."""

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def read_skill(name):
    return (ROOT / f"plugins/skein-pi/skills/{name}/SKILL.md").read_text()


def test_conduct_is_pi_native_sequential_and_main_owned():
    text = read_skill("conduct")
    assert text.startswith("---\nname: skein-conduct\n")
    for forbidden in ("agent tool", "spawn_agent", "claude", "codex"):
        assert forbidden not in text.lower()
    for phrase in (
        "reviewed plan marker",
        "skein_worker",
        "no tools",
        "cannot write files",
        "main session",
        "max-iterations",
        "never invokes fan-out",
        "explicit paths",
    ):
        assert phrase in text


def test_release_is_user_invoked_read_only_by_default():
    text = read_skill("release")
    assert "disable-model-invocation: true" in text
    for phrase in (
        "read-only audit",
        "dry-run",
        "second explicit confirmation",
        "strict SemVer",
        "Treat `CHANGELOG.md`",
        "never display raw remote URLs",
        "failed re-read",
        "Never expose credentials",
    ):
        assert phrase in text
    assert (
        "fan-out" not in json.loads((ROOT / "package.json").read_text())["pi"]["skills"]
    )


def test_fan_out_stays_undiscoverable():
    manifest = json.loads((ROOT / "package.json").read_text())
    paths = manifest["pi"]["skills"]
    assert not any(path.endswith("/fan-out/SKILL.md") for path in paths)
    assert not (ROOT / "plugins/skein-pi/skills/fan-out").exists()
