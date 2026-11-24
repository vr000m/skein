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
    normalized = " ".join(text.split())
    for phrase in (
        "with explicit approval for each launch",
        "Both role requests use only `role` and `prompt`",
        "outside untrusted snapshots",
        "first launches and every retry for both the implementer and test-writer",
        "For both the implementer and test-writer, include the static Comments rule",
        "Every retry carries the same static Comments rule",
        "Comment only a non-obvious why",
        "comment that restates the code",
        "comment that excuses a hack: fix the hack, or report it",
        "docstrings, linter and type pragmas, license headers",
        "a full issue URL or `#N`",
        "tautology or stale and lies inside a hunk or function the change already touches",
        "never sweep untouched code",
        "Never delete an excuse comment silently",
        "cross-file or long-lived decision stays in place",
        "`Excuse: <file:line> <why>`",
        "`Decision candidate: <file:line> <why>`",
        "Validate labelled notices",
        "Print validated `Excuse:` and `Decision candidate:` notices",
        "one notice block per phase boundary",
        "not persisted, and may be lost on `--resume`",
        "Add no new report keys",
    ):
        assert phrase in normalized, phrase


def test_conduct_completion_pointer_is_terminal_text_after_comment_notices():
    text = read_skill("conduct")
    pointer = text.split("### Completion pointer", 1)[1]
    normalized = " ".join(pointer.split())
    assert (
        "Only when all declared phases, tests/validation and approval/verification "
        "requirements are complete"
    ) in normalized
    assert "after any validated comment notices" in normalized
    assert (
        "Next: run /skill:skein-update-docs to sync the docs and offer decision-record promotion."
    ) in pointer
    assert "text only: conduct never invokes the update-docs skill itself" in pointer
    assert "no automatic chain or new execution modes" in pointer
    assert "`Excuse:` / `Decision candidate:`" in pointer
    assert "a completion pointer never replaces them" in pointer
    assert (
        "| Healthy terminal: all declared phases, tests/validation and approval/verification complete | Print after comment notices |"
        in pointer
    )


def test_conduct_intermediate_handback_omits_completion_pointer():
    assert "| Intermediate phase summary: more phases remain | Omit |" in read_skill(
        "conduct"
    )


def test_conduct_blocked_handback_omits_completion_pointer():
    assert (
        "| Blocked: tests or validation failed, or a required step is unresolved | Omit |"
        in read_skill("conduct")
    )


def test_conduct_declined_handback_omits_completion_pointer():
    assert (
        "| Declined: worker, patch or commit approval was declined or unanswered | Omit |"
        in read_skill("conduct")
    )


def test_conduct_degraded_handback_omits_completion_pointer():
    assert (
        "| Degraded: unavailable worker, partial result, skipped tests or unverified patch | Omit |"
        in read_skill("conduct")
    )


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
        "SemVer `-prerelease` and/or `+build` tail of dot-separated non-empty identifiers",
        # Summary boundary = the audit split: leading blanks skipped, 1-6 hashes.
        "blank lines before the summary's first text are skipped",
        "levels 1-6",
        # Clause (a) is the one publishable-content definition, applied by
        # name by the hard stop and the A4 re-test (every offered row).
        "the CHANGELOG section has publishable content",
        "ignoring compare-shaped lines",
        "A section with no publishable content (clause (a) below) is a hard stop",
        "contains a CHANGELOG version-header line",
        "is never reused",
        "a compare-shaped line is not a trigger",
        # Round-1 G5: the compare line that marks a headingless prefix (and
        # ends a recovered summary) is the recovery template's -- the one the
        # old body was cut under -- as resync-summary's recovery_label.
        "carrying the recovery template's own compare line, is not a summary",
        "the summary already ends at the recovery template's own compare line",
        "The **recovery template** is the one the old body was cut under",
        # Round-1 G5: the refresh choice is withheld exactly when regeneration
        # would fail audit (resync-summary's regenerate_safe false).
        "but only when the regenerated body would itself pass audit",
        "otherwise never offer it",
        "every fixable row, whatever field drifted",
        "withheld from re-sync only when re-sync itself would stop",
        "with clause (a)'s publishable-content test",
        "needs CHANGELOG/template edit",
        # Round 7 (aligned with the Claude/Codex resync-gate/resync-summary
        # sites): the A4 gate IS the composition hard stop's test, preservation
        # is judged under the current committed template after the stale
        # trailer is dropped, and a discard names its line.
        "the very test the composition hard stop applies",
        "that is a valid body under the current committed template is preserved",
        "the old body's own stale compare trailer dropped",
        "states that it was discarded and which line caused it",
        # Round 7: the restored "or" (Pi's only statement of the rule), the
        # round-trip discard, and the honest prose-only scope.
        "version-header line (clause (c)'s definition), or an active",
        "would make the re-synced body drift in audit",
        "these re-sync rules exist only as this prose",
        # Round 8: the regenerate branch is checked too (Claude/Codex:
        # resync-summary's regenerate_safe); Pi states it as a stop.
        "stop instead of publishing it",
        # Round 9: the regenerate check is judged with the summary the body
        # will carry, stops a new release too, and gates the audit offer.
        "judged with the summary it will carry",
        "the same check stops a new release",
        "keeps it (never a bare body)",
        "plus the regenerated-body drift check",
        # Compact-notes round 2: the refresh example states the script's exact
        # condition (resync-summary's regenerate_safe), with an unsafe and a
        # safe case, and clause (a) carries the publishable-bytes rule.
        "the refresh is unsafe only when no publishable content remains after that split",
        "(a section holding only `## What's New` and its paragraph)",
        "a section with more after the paragraph (`### Added` items) regenerates safely",
        "those published bytes are NUL-free valid UTF-8",
    ):
        assert phrase in text, phrase
    # Round 2: a leading `## What's New` alone never made regeneration unsafe.
    assert "over a section that opens with `## What's New`: regeneration" not in text
    assert "reads the whole regenerated block as the summary" not in text
    assert "or on explicit request" not in text
    assert "the summary ends at the first blank line" not in text
    assert "or a compare-shaped line (never publishable" not in text


def test_fan_out_stays_undiscoverable():
    manifest = json.loads((ROOT / "package.json").read_text())
    paths = manifest["pi"]["skills"]
    assert not any(path.endswith("/fan-out/SKILL.md") for path in paths)
    assert not (ROOT / "plugins/skein-pi/skills/fan-out").exists()
