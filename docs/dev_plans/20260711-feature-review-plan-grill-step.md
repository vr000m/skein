# Task: Grill-mode decision interview for `/review-plan` Step 6.4

**Status**: Not Started
**Component**: review-skills
**Assigned to**: Claude
**Priority**: Medium
**Branch**: feature/review-plan-grill-step
**Created**: 2026-07-11
**Completed**: (fill when done)
**Review Gates**: none

## Objective

Sharpen `/review-plan`'s existing Step 6.4 (Interactive Triage-and-Clarify Elicitation Loop) so that findings representing genuine open **decisions** — architecture/component boundaries, third-party integration contracts, security, rate-limiting — are walked one at a time with a single proposed recommendation per finding (grill-style), instead of being clarified with the same generic 2–3-option picker used for every finding regardless of topic.

## Context

`skein:review-plan` already runs five parallel lens agents (architecture, sequencing, spec-and-testing, assumptions, codebase-claims) and, since Step 6.4 shipped, already elicits the user's triage/clarify decisions interactively and records them back into the plan via `/dev-plan update` (`plugins/skein/skills/review-plan/SKILL.md:518-541`). This is not a greenfield feature — it is a targeted enhancement to a loop that already exists and already works.

The trigger for this plan was a conversation about [mattpocock/skills](https://github.com/mattpocock/skills)' `grilling` skill (`skills/productivity/grilling/SKILL.md`), which runs a relentless one-question-at-a-time interview over a plan, proposing a recommended answer for each question and refusing to proceed until the user has answered, explicitly splitting **facts** (look up yourself) from **decisions** (must go to the human). Two things about the existing Step 6.4 don't match that protocol:

1. **No topic/decision filter.** Step 6.4's Clarify sub-step (`SKILL.md:527`) runs over every finding the user selected in Triage, regardless of whether it's a mechanical fact (e.g. a `codebase-claims` `Nonexistent Reference` — the path moved, just fix the reference) or a genuine judgment call (e.g. an `assumptions` finding about how a third-party API rate-limits, or an `architecture` finding about where a new component boundary should sit). Both currently get the same "here are 2–3 options, pick one" treatment.
2. **No single-recommendation, serial-wait protocol.** The `grilling` skill's contract is: propose *one* recommended answer, wait for that answer before continuing to the next question. Step 6.4's Clarify sub-step offers 2–3 *equally-weighted* options with no explicit single recommendation, and doesn't specify serial pacing.

This plan closes both gaps **by extending Step 6.4 in place** rather than adding a new step or a new companion skill. Rationale (see Architecture Decisions): Step 6.4 already owns the triage → clarify → route → `/dev-plan update` pipeline, the write-then-hash ordering invariant with Step 6.5/Step 7, and the `--batch` opt-out. A second, parallel interview mechanism would duplicate all of that plumbing for no benefit — the actual gap is *how* Clarify presents grill-eligible findings, not *whether* a clarify step exists.

## Requirements

- Findings are classified during Clarify (not Triage — Triage's free-form selection stays unchanged) into **grill-eligible** (open decision: architecture/component-boundary, third-party integration, security, rate-limiting topics) vs **standard** (everything else, including all `codebase-claims`/`Nonexistent Reference` findings, which are facts by definition and never grill-eligible).
- Grill-eligible findings are presented **one at a time**, each with exactly **one proposed recommended resolution** (not 2–3 undifferentiated options), and the loop blocks on that finding's answer before moving to the next grill-eligible finding.
- The user must be able to accept the recommendation, override it with their own answer, or waive the finding — three fixed outcomes, compatible with a 4-option picker.
- Standard findings keep today's 2–3-option Clarify behavior, unchanged.
- Resolved grill decisions are recorded via the existing `/dev-plan update` route (above the marker, in Technical Specifications) — no new persistence mechanism. Each grill-derived edit is prefixed `Decision (grilled):` in the prose handed to `/dev-plan update` so a future reader (or `/deep-review`) can tell a grill-resolved judgment call apart from a routine review-finding fix.
- `--batch` continues to skip Step 6.4 entirely, including the new grill classification — unchanged escape hatch, no new flag introduced.
- The classification and single-recommendation logic is main-agent prose judgment, consistent with the rest of Step 6.4 ("no shell script is involved" — `SKILL.md:520`). No new script, no new category enum value (the existing `{Assumption, Constraint, Ambiguity, Risk, Sequencing, Missing Task, Testing Gap, Nonexistent Reference}` enum is untouched).
- `rubric.md` gains gradeable criteria for the new grill behavior, kept byte-identical between `.claude` and `.codex` mirrors (enforced by `scripts/check-prompt-parity.sh`).
- The `.codex` mirror (`plugins/skein-codex/skills/review-plan/SKILL.md`) gets the semantically-equivalent Step 6.4 enhancement, edited via `codex:rescue` per this repo's convention for Codex-mirror `SKILL.md` content (prose wording may differ per harness; behavior must not).
- Both plugin manifests (`plugins/skein/.claude-plugin/plugin.json`, `plugins/skein-codex/.codex-plugin/plugin.json`) are version-bumped together, and `CHANGELOG.md` gets an `[Unreleased]`/next-version entry.

## Review Focus

- Lens-scope discipline: the classification criteria for "grill-eligible" must stay a narrow, named topic list (architecture/component boundaries, third-party integration, security, rate-limiting) — not an open-ended "anything judgment-y," which would swallow most `assumptions`/`architecture` findings and defeat the purpose of a *targeted* interview.
- `codebase-claims` findings (`Nonexistent Reference`) must never be classified grill-eligible — they are facts by the existing lens-scope contract (`SKILL.md:389`), not decisions.
- Write-then-hash ordering invariant (`SKILL.md:534-539`): the new grill sub-step's `/dev-plan update` calls must complete and flush to disk before Step 6.5/Step 7 run, same as existing Clarify/Route calls — this plan must not introduce a new writer that races that invariant.
- `scripts/check-prompt-parity.sh` must pass after the rubric.md edit (byte-identity across `.claude`/`.codex`) and after the GENERIC-block-adjacent prose changes (the Step 6.4 text itself is not byte-parity-enforced by the script, only the GENERIC finding-schema block and rubric.md are — confirmed via Explore).

## Implementation Checklist

### Phase 1: Classify + grill sub-step in `SKILL.md`

**Impl files:** `plugins/skein/skills/review-plan/SKILL.md`
**Test files:** (none — Step 6.4 is prose-driven with no existing script/test coverage; see Testing Notes)
**Test command:** `bash scripts/check-prompt-parity.sh`
**Goal:** Grill-eligible classification is a narrow, named-topic filter (architecture/component-boundary, third-party integration, security, rate-limiting) that never includes `codebase-claims` findings; grill-eligible findings are walked strictly one at a time with a single recommendation each, blocking until answered.

- In Step 6.4's Clarify sub-step (`SKILL.md:527`), insert a classification pass: for each finding selected in Triage, the main agent judges whether it is grill-eligible (decision on architecture/component boundaries, third-party integration contracts, security, or rate-limiting) or standard (everything else, including all `Nonexistent Reference` findings, which are always standard).
- For grill-eligible findings: process strictly serially, one at a time. For each, state the finding, propose exactly one recommended resolution, and present a fixed-option picker (`Accept recommendation` / `Propose alternative` / `Waive`) — do not advance to the next grill-eligible finding until this one is answered.
- For standard findings: unchanged 2–3-option Clarify behavior.
- Route sub-step (`SKILL.md:528-531`): grill-derived "act on" decisions call `/dev-plan update` with the prose summary prefixed `Decision (grilled): <what to change and why>`; grill-derived waivers go to `### Review Waivers` exactly like existing waivers, with no special tag (the waiver subheading itself is sufficient provenance).
- Confirm the write-then-hash ordering invariant text (`SKILL.md:534-539`) already covers this — it references "this loop's `/dev-plan update`" generically, so no wording change needed there; verify by re-reading after the edit.

### Phase 2: Rubric criteria + Codex mirror parity

**Impl files:** `plugins/skein/skills/review-plan/rubric.md`, `plugins/skein-codex/skills/review-plan/rubric.md`, `plugins/skein-codex/skills/review-plan/SKILL.md`
**Test files:** (none)
**Test command:** `bash scripts/check-prompt-parity.sh`
**Goal:** rubric.md stays byte-identical across mirrors per the parity script's existing enforcement; the Codex SKILL.md gains the same grill behavior in Codex-appropriate wording, without disturbing the `$SKILL_DIR`-vs-`${CLAUDE_PLUGIN_ROOT}` path-anchor divergence this repo maintains intentionally between mirrors.

- Add a "Grill Discipline" section to `plugins/skein/skills/review-plan/rubric.md` with gradeable criteria: (a) grill-eligible findings are limited to the named topic list, (b) `Nonexistent Reference` findings are never grill-eligible, (c) grill-eligible findings are presented one at a time with exactly one recommendation, (d) the loop blocks until each grill-eligible finding is answered, (e) grill-derived plan edits are prefixed `Decision (grilled):`.
- Copy the identical rubric.md content to `plugins/skein-codex/skills/review-plan/rubric.md` (byte-identical, per the existing parity contract — this is a plain data-file copy, not Codex-specific prose, so it does not need to go through `codex:rescue`).
- Delegate the Codex `SKILL.md` Step 6.4 enhancement to `codex:rescue` (per this repo's convention that Codex-mirror `SKILL.md` content is edited via `codex:rescue`, not directly) — brief it with the same classification/serial/recommendation behavior from Phase 1, and remind it to preserve `$SKILL_DIR` anchoring (not `${CLAUDE_PLUGIN_ROOT}`) per the harness-divergent path-anchor convention.

### Phase 3: Version bump + changelog

**Impl files:** `plugins/skein/.claude-plugin/plugin.json`, `plugins/skein-codex/.codex-plugin/plugin.json`, `CHANGELOG.md`
**Test files:** (none)
**Test command:** `bash scripts/check-prompt-parity.sh`
**Validation cmd:** `git diff --stat plugins/skein/.claude-plugin/plugin.json plugins/skein-codex/.codex-plugin/plugin.json`

- Bump both manifests from `0.4.1` to `0.5.0` (new feature, not a patch) — dual bump is mandatory per this repo's release convention; a single-manifest bump has broken the Codex update-cache key before.
- Add a `CHANGELOG.md` entry under `[Unreleased]` (or a new version heading, matching the file's existing convention) describing the grill-mode Clarify enhancement.

## Technical Specifications

### Files to Modify
- `plugins/skein/skills/review-plan/SKILL.md` — Step 6.4 Clarify sub-step gains classification + serial single-recommendation grill behavior.
- `plugins/skein/skills/review-plan/rubric.md` — new "Grill Discipline" section.
- `plugins/skein-codex/skills/review-plan/SKILL.md` — semantically-equivalent Codex mirror update, via `codex:rescue`.
- `plugins/skein-codex/skills/review-plan/rubric.md` — byte-identical copy of the Claude rubric.md addition.
- `plugins/skein/.claude-plugin/plugin.json`, `plugins/skein-codex/.codex-plugin/plugin.json` — version bump `0.4.1` → `0.5.0`.
- `CHANGELOG.md` — new entry.

### New Files to Create
- None.

### Architecture Decisions
- **Extend Step 6.4 rather than add a new step or companion skill.** Step 6.4 already owns triage → clarify → route → `/dev-plan update`, the write-then-hash ordering invariant, and the `--batch` opt-out. A parallel "grill" mechanism would duplicate that plumbing (marker-hash ordering, `/dev-plan update` routing, waiver recording) for no behavioral gain — the actual gap is presentation-and-pacing within Clarify for a narrow finding subset, not a missing pipeline stage.
- **No new CLI flag.** Grill-style presentation applies automatically to grill-eligible findings within the existing default-on Step 6.4; `--batch` remains the only opt-out, unchanged. A separate `--grill` flag was considered and rejected — it would let a caller run Step 6.4 without grilling, which contradicts the point of narrowing Clarify's behavior for decision-class findings in the first place. *(Named as a judgment call in Review Focus — flag for scrutiny during `/review-plan` on this plan.)*
- **Classification stays prose judgment, not a script or new category enum.** Consistent with Step 6.4's existing design ("no shell script is involved"), and with the finding-schema constraint that `category` is a closed enum with no value for "requires human judgment." A keyword/regex classifier was considered and rejected as brittle for an inherently judgment-based distinction (the same finding text can be a decision in one plan and a settled fact in another, depending on what the plan's Review Focus already pins down).
- **`Decision (grilled):` prefix convention, not a new persistence field.** Recorded decisions still flow through `/dev-plan update` into Technical Specifications, above the marker — no new plan section, no schema change. The prefix is a lightweight provenance marker for human/`/deep-review` readers, nothing more.

### Dependencies
- None (no new runtime dependency; this is a prose/rubric/version change to existing markdown-driven skills).

### Integration Seams

| Seam | Writer (task) | Caller (task) | Contract |
|------|---------------|---------------|----------|
| Grill classification → Clarify presentation | Phase 1 (`SKILL.md` Clarify sub-step) | Step 6.4's Route sub-step (unchanged) | Grill-eligible findings must still resolve to exactly one of {act-on, waive} before Route runs — Route's existing branching logic is not modified, only what feeds it |
| Rubric parity | Phase 2 (`.claude` rubric.md edit) | `scripts/check-prompt-parity.sh` | `.codex` rubric.md must be byte-identical after Phase 2, or the parity check fails the build |
| Codex mirror semantic parity | Phase 2 (`codex:rescue` delegation) | Human/PR reviewer | Codex `SKILL.md` Step 6.4 must produce equivalent grill behavior using `$SKILL_DIR` anchoring; not asserted byte-identical by any script (confirmed via Explore — only the GENERIC finding-schema block and rubric.md are script-enforced), so this seam is reviewed manually |

## Testing Notes

### Test Approach
- [ ] `scripts/check-prompt-parity.sh` passes (rubric.md byte-identity, GENERIC block unaffected)
- [ ] Existing `tests/reconciliation/` and `tests/auto-fix/` suites pass unchanged (regression check — this plan does not touch the reconciler, renderer, or auto-fix appliers)
- [ ] Manual walkthrough: run `/review-plan` against a synthetic plan seeded with a mix of finding types (one `codebase-claims`/`Nonexistent Reference`, one `architecture` finding about a component boundary, one `assumptions` finding about a third-party rate limit) and confirm: the fact finding is never grill-presented, the two decision findings are each presented one at a time with a single recommendation, and accepted/waived outcomes land correctly (act-on → `/dev-plan update` with `Decision (grilled):` prefix; waived → `### Review Waivers`)

### Test Results
- [ ] All existing tests pass
- [ ] Manual verification complete

### Edge Cases Tested
- [ ] A finding that is borderline (e.g. touches both "architecture" and "testing gap" territory) — confirm classification picks one lane and doesn't double-present it
- [ ] All selected findings are standard (none grill-eligible) — confirm Clarify behaves exactly as it does today, no regression
- [ ] All selected findings are grill-eligible — confirm strict serial pacing (no batching, no early Route)
- [ ] `--batch` still skips Step 6.4 entirely, including grill classification

## Acceptance Criteria

- Grill-eligible findings (architecture/component-boundary, third-party integration, security, rate-limiting) are presented one at a time with exactly one recommendation each, blocking until answered.
- `codebase-claims`/`Nonexistent Reference` findings are never grill-presented.
- Standard findings keep today's 2–3-option Clarify behavior, unmodified.
- `--batch` still skips Step 6.4 entirely — no new flag introduced.
- `rubric.md` is byte-identical across `.claude`/`.codex` mirrors and passes `scripts/check-prompt-parity.sh`.
- `.codex` `SKILL.md` has semantically-equivalent grill behavior, edited via `codex:rescue`.
- Both plugin manifests bumped in lockstep; `CHANGELOG.md` updated.
- Code reviewed and approved
- Tests passing (parity script + existing regression suites)
- Documentation updated (`docs/dev_plans/README.md` task table)

<!-- reviewed: YYYY-MM-DD @ <hash> -->
<!-- /review-plan writes the marker line above. Everything below is the workspace: edits here do NOT invalidate the marker. -->

## Progress

- [ ] Phase 1: Classify + grill sub-step in `SKILL.md`
- [ ] Phase 2: Rubric criteria + Codex mirror parity
- [ ] Phase 3: Version bump + changelog

## Findings

- (append findings here as work proceeds)

## Issues & Solutions

(none yet)

## Final Results

(fill when complete)
