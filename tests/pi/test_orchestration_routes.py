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


def test_release_editorial_policy_is_advisory_without_fake_measurement():
    text = read_skill("release")
    for phrase in (
        "at or below 3,000",
        "above 700",
        "does not run the bundled measured checker",
        "claim measured counts",
        "accept the exact body as shown, revise it, or abort without mutation",
        "adds no mutation authority",
        "replace the second explicit confirmation",
    ):
        assert phrase in text


def test_release_valid_body_contract_matches_the_claude_codex_mirrors():
    """Pi cannot read the Claude/Codex release skill, so it carries the full
    valid-body predicate and the re-sync rules audit classification depends
    on (moved from tests/release/test-scripts.sh's V9 prose greps)."""
    raw = read_skill("release")
    text = " ".join(raw.split())
    for phrase in (
        "## [Unreleased]",
        "leading/trailing whitespace",
        "typographic apostrophe",
        "refresh content from CHANGELOG",
        "release is verbatim by default and goes compact only when",
        "may only restate what the section",
        "no `###` heading line anywhere in the body, including inside the summary",
        "up to 3 leading spaces",
        "non-empty SemVer `-prerelease`/`+build` tail",
        # Clause (a) is the one publishable-content definition, applied by
        # name by the hard stop, the summary-discard rule and the A4 re-test.
        "the CHANGELOG section has publishable content",
        "ignoring compare-shaped lines",
        "A section with no publishable content (clause (a) below) is a hard stop",
        "contains a CHANGELOG version-header line",
        "or a compare-shaped line (never publishable content under clause (a))",
        "is never reused",
        "withheld from re-sync only when re-sync itself would stop",
        "with clause (a)'s publishable-content test",
        "needs CHANGELOG/template edit",
    ):
        assert phrase in text, phrase
    assert "or on explicit request" not in text


def test_fan_out_stays_undiscoverable():
    manifest = json.loads((ROOT / "package.json").read_text())
    paths = manifest["pi"]["skills"]
    assert not any(path.endswith("/fan-out/SKILL.md") for path in paths)
    assert not (ROOT / "plugins/skein-pi/skills/fan-out").exists()
