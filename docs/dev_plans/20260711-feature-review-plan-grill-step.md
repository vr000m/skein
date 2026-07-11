# Task: Standalone `skein:grill` skill + grill-mode decision interview for `/review-plan` Step 6.4

**Status**: Not Started
**Component**: review-skills
**Assigned to**: Claude
**Priority**: Medium
**Branch**: feature/review-plan-grill-step
**Created**: 2026-07-11
**Completed**: (fill when done)
**Review Gates**: none

## Objective

Ship a new general-purpose, user-invocable `skein:grill` skill that runs a relentless, one-question-at-a-time interview (grill-style, inspired by [mattpocock/skills](https://github.com/mattpocock/skills)' `grilling` skill) over any plan, design, or freeform idea the user hands it — proposing one recommended resolution per question, waiting for an answer before advancing, and splitting facts (verified from the codebase) from decisions (must go to the human). Then wire `/review-plan`'s existing Step 6.4 (Interactive Triage-and-Clarify Elicitation Loop) to **delegate to this same skill** for the subset of findings that are genuine open decisions — architecture/component boundaries, third-party integration contracts, security, rate-limiting — instead of re-implementing the interview protocol a second time inline.

## Context

`skein:review-plan` already runs five parallel lens agents (architecture, sequencing, spec-and-testing, assumptions, codebase-claims) and, since Step 6.4 shipped, already elicits the user's triage/clarify decisions interactively and records them back into the plan via `/dev-plan update` (`plugins/skein/skills/review-plan/SKILL.md:518-541`).

The trigger for this plan was a conversation about mattpocock/skills' `grilling` skill (`skills/productivity/grilling/SKILL.md`), which runs a relentless one-question-at-a-time interview over a plan, proposing a recommended answer for each question and refusing to proceed until the user has answered, explicitly splitting **facts** (look up yourself) from **decisions** (must go to the human). The original scope of this plan was to fold that protocol into Step 6.4's Clarify sub-step only. Two things changed that:

1. **Two gaps in Step 6.4's Clarify sub-step, as originally identified**: (a) no topic/decision filter — every finding the user selects in Triage gets the same 2–3-option treatment regardless of whether it's a mechanical fact or a genuine judgment call; (b) no single-recommendation, serial-wait protocol — Clarify offers undifferentiated options rather than one recommendation with blocking pacing.
2. **The grill interview protocol is independently useful outside `review-plan` entirely** — a user may want to stress-test a plan or a freeform idea *before* a plan even exists, or outside the review-plan flow altogether. Gating the interview behind "you first ran `/review-plan` and it produced findings" is unnecessarily narrow.

**Revised architecture (see Architecture Decisions):** rather than duplicating the one-question/one-recommendation interaction pattern in two places, this plan extracts it into a standalone `skein:grill` skill and has `/review-plan` Step 6.4 **call it** for the findings it classifies as grill-eligible. `skein:grill` owns the interview mechanics (serial pacing, single recommendation, fact/decision split, accept/override/waive outcomes); `review-plan` owns finding classification and where resolved decisions get recorded (`/dev-plan update`, above the marker). This is a cleaner split of responsibility than the original single-phase plan, and it means the interview protocol has exactly one authoritative definition instead of two copies that could drift.

## Requirements

### `skein:grill` (new, standalone skill)

- User-invocable directly (`/grill`, or natural-language "grill me on X") — not gated behind having run `/review-plan` first, and not auto-triggered by other skills without an explicit call.
- Accepts either: a file path (most commonly a `docs/dev_plans/*.md` plan, but any markdown/text file), or an inline freeform description of a plan/design/idea typed directly in the conversation.
- Splits the interview's questions into two kinds: **facts** (verifiable from the codebase — look them up directly, never ask) and **decisions** (genuine judgment calls with no single correct answer — must go to the human).
- For each decision, proposes exactly **one recommended resolution**, then presents a fixed three-way choice (Claude: `AskUserQuestion` picker; Codex: equivalent plain-text three-way prompt, per the existing Clarify sub-step's harness-divergence precedent at `SKILL.md:521-527`) — **accept** the recommendation, **propose an alternative** (a follow-up free-text prompt captures the override, mirroring Clarify's existing free-text path for "no clear options"), or **waive**. Blocks on each answer before advancing to the next decision — strictly serial, no batching.
- When the target is a `docs/dev_plans/*.md` plan file, accepted/overridden decisions are recorded via `/dev-plan update` (above the marker, in Technical Specifications); when the target is freeform conversational input with no backing plan file, resolved decisions are summarized back in the conversation, with an offer to run `/dev-plan create` if the user wants them persisted.
- Does not run against a plan whose review marker `/review-plan` has already written (below-marker workspace edits are fine per the usual marker rules — this constraint is about not silently reopening a contract that's already been accepted); it can be re-run before the marker exists, same as `/review-plan`'s Step 6.4.

### `/review-plan` Step 6.4 (revised scope, unchanged goal)

- Findings are classified during Clarify (not Triage — Triage's free-form selection stays unchanged) as **grill-eligible** (open decision: architecture/component-boundary, third-party integration, security, rate-limiting topics) vs **standard** (everything else). The exclusion is a structural predicate on `category`, not on lens membership: any finding whose `category == 'Nonexistent Reference'` is always standard, regardless of which lens(es) contributed to a merged finding — `category` and `lens` are not 1:1 after reconciliation (a merged finding can carry `Lenses: [architecture, codebase-claims]` while its category is `Nonexistent Reference`).
- A finding that plausibly spans two topics (e.g. both "architecture" and "testing gap") is presented **once**, under a deterministic tiebreak: grill-eligible topics (architecture/component-boundary, third-party integration, security, rate-limiting) win over standard topics; if a finding spans two grill-eligible topics, present it once under whichever topic its `category` maps to first in the enum order `{Assumption, Constraint, Ambiguity, Risk}` (the four categories `assumptions`/`architecture` findings typically carry).
- Grill-eligible findings are handed to `skein:grill`'s interview mechanics (one at a time, one recommendation each, blocking) instead of Step 6.4 re-implementing that pacing inline. Standard findings keep today's 2–3-option Clarify behavior, unchanged.
- Resolved grill decisions are recorded via the existing `/dev-plan update` route, prefixed `Decision (grilled): <what to change and why>` in the prose handed to `/dev-plan update`. This prefix is an **authoring instruction to the orchestrating agent** (the same agent runs Step 6.4, invokes `skein:grill`'s protocol, and calls `/dev-plan update` in one continuous session — there is no fresh-context handoff that could drop it), not a claim that some other tool mechanically parses or preserves it; the rubric's gradeable check for it is a self-check on the orchestrator's own output, the same trust model the rest of Step 6.4 already uses.
- `--batch` continues to skip Step 6.4 entirely, including grill classification and delegation — unchanged escape hatch, no new flag introduced.
- The classification logic stays main-agent prose judgment, consistent with the rest of Step 6.4 ("no shell script is involved" — `SKILL.md:520`). No new script, no new category enum value (the existing `{Assumption, Constraint, Ambiguity, Risk, Sequencing, Missing Task, Testing Gap, Nonexistent Reference}` enum is untouched).

### Shared / cross-cutting

- `rubric.md` gains gradeable criteria for the new grill behavior (both the standalone skill and Step 6.4's delegation to it), kept byte-identical between `.claude` and `.codex` mirrors (enforced by `scripts/check-prompt-parity.sh`).
- Both new skill's mirrors (`plugins/skein/skills/grill/SKILL.md` and `plugins/skein-codex/skills/grill/SKILL.md`) and `review-plan`'s Codex mirror are edited: Claude versions directly, Codex versions via `codex:rescue`. Per this repo's own convention docs (`docs/dev_plans/20260707-feature-conduct-phase-goal-field.md:48`), `codex:rescue` is the repo's **route/convention** for Codex-native adaptation and review — it is not a separate CLI command the implementation invokes programmatically; it names how the Codex-mirror work gets authored, not a mechanism the plan calls at runtime.
- Both plugin manifests (`plugins/skein/.claude-plugin/plugin.json`, `plugins/skein-codex/.codex-plugin/plugin.json`) are version-bumped together, and `CHANGELOG.md` gets a new entry.
- The root `README.md` skills table and `docs/dev_plans/README.md` task table both get updated — the latter was already updated when this plan was created (see git history on this branch); the former needs a new `grill` row.

## Review Focus

- Lens-scope discipline: the classification criteria for "grill-eligible" must stay a narrow, named topic list (architecture/component boundaries, third-party integration, security, rate-limiting) — not an open-ended "anything judgment-y."
- The grill-eligible exclusion for `Nonexistent Reference` findings is keyed on `category`, not on `lens` — a finding reconciled from multiple lenses is not 1:1 with a single lens.
- The borderline-classification tiebreak (grill-eligible wins over standard; enum-order tiebreak among grill-eligible categories) must be concrete enough that "picks one lane" is a testable, gradeable outcome, not a vibe.
- Write-then-hash ordering invariant (`SKILL.md:534-539`): `skein:grill`'s `/dev-plan update` calls (whether invoked standalone or via Step 6.4 delegation) must complete and flush to disk before Step 6.5/Step 7 run when the target is a plan under active `/review-plan` — this plan must not introduce a new writer that races that invariant.
- `codex:rescue` must be described accurately as a repo authoring convention, not an invocable command — do not reintroduce the "invocable skill/agent" framing corrected in this plan's own `/review-plan` pass.
- `scripts/check-prompt-parity.sh` must pass after the rubric.md edit (byte-identity across `.claude`/`.codex`) and continue to pass for the new `grill` skill pair once it exists — confirm whether `grill` needs adding to `MANAGED_SKILLS` (only if it ships a `rubric.md` or `*-prompt.md`; a simple single-file interview skill may not need either).
- Both the new `skein:grill` skill and Step 6.4's delegation to it need actual test coverage beyond a single "override path was exercised once" walkthrough — see Testing Notes for the specific gaps this plan must close (write-then-hash post-grill, override outcome, Codex-mirror equivalence).

## Implementation Checklist

### Phase 1: Create standalone `skein:grill` skill (Claude)

**Impl files:** `plugins/skein/skills/grill/SKILL.md`
**Test files:** (none — this is a new prose-driven skill with no script; see Testing Notes)
**Test command:** `bash scripts/check-prompt-parity.sh`
**Goal:** The interview protocol (fact/decision split, one recommendation per decision, strict serial pacing, three-way accept/override/waive outcome, plan-file vs freeform-target persistence) has exactly one authoritative definition, reusable by both direct user invocation and Step 6.4's delegation.

- Author `plugins/skein/skills/grill/SKILL.md`: accepts a target (file path or inline description), classifies each candidate topic as fact vs decision, and for each decision proposes one recommendation via `AskUserQuestion` (three options: accept / propose alternative / waive), blocking until answered before advancing.
- When target is a `docs/dev_plans/*.md` file: route accepted/overridden decisions through `/dev-plan update`, prefixed `Decision (grilled): <what to change and why>`; when target is freeform: summarize resolved decisions in conversation and offer `/dev-plan create` if the user wants persistence.
- Refuse to run against a plan whose review marker is already written without the user explicitly acknowledging they're reopening reviewed content (same posture Step 6.4 already takes toward the marker).

### Phase 2: Wire `/review-plan` Step 6.4 to delegate to `skein:grill`

**Impl files:** `plugins/skein/skills/review-plan/SKILL.md`
**Test files:** (none — Step 6.4 is prose-driven with no existing script/test coverage; see Testing Notes)
**Test command:** `bash scripts/check-prompt-parity.sh`
**Goal:** Grill-eligible classification is a narrow, named-topic filter keyed on `category` (never `Nonexistent Reference`, regardless of which lens(es) contributed); grill-eligible findings are handed to `skein:grill`'s interview protocol rather than re-implemented inline, with a deterministic single-lane tiebreak for borderline findings.

- In Step 6.4's Clarify sub-step (`SKILL.md:527`), insert the classification pass described in Requirements (category-keyed exclusion, enum-order tiebreak for borderline findings).
- For grill-eligible findings: invoke `skein:grill`'s interview protocol (one at a time, one recommendation, blocking) instead of duplicating that prose here — link to `skein:grill`'s SKILL.md as the authoritative definition.
- For standard findings: unchanged 2–3-option Clarify behavior.
- Route sub-step (`SKILL.md:528-531`): grill-derived "act on" decisions call `/dev-plan update` with the prose summary prefixed `Decision (grilled): <what to change and why>` (per Requirements, this is an orchestrator self-instruction, not a mechanically-enforced guarantee); grill-derived waivers go to `### Review Waivers` exactly like existing waivers.
- Confirm the write-then-hash ordering invariant text (`SKILL.md:534-539`) already covers `skein:grill`'s `/dev-plan update` calls generically ("this loop's `/dev-plan update`") — verify by re-reading after the edit; add an explicit manual test (see Testing Notes) rather than relying on an eyeball re-read alone.

**Divergence window (intentional, gate-safe):** between Phase 1/2 landing and Phase 3 landing, the Claude mirrors (`grill` + `review-plan` Step 6.4) and Codex mirrors are semantically divergent — the Codex side hasn't gained the new behavior yet. This is safe: `check-prompt-parity.sh` does not enforce `SKILL.md` byte-identity (only `rubric.md` and the GENERIC finding-schema block), so no gate breaks mid-window. It is not safe to *ship* in this state — Phase 3 must land in the same PR as Phases 1–2, not deferred to a follow-up.

### Phase 3: Rubric criteria + Codex mirrors (both skills)

**Impl files:** `plugins/skein/skills/review-plan/rubric.md`, `plugins/skein-codex/skills/review-plan/rubric.md`, `plugins/skein-codex/skills/review-plan/SKILL.md`, `plugins/skein-codex/skills/grill/SKILL.md`
**Test files:** (none)
**Test command:** `bash scripts/check-prompt-parity.sh`
**Goal:** `rubric.md` stays byte-identical across mirrors; both Codex mirrors (`grill` and `review-plan`'s Step 6.4 delegation) gain semantically equivalent behavior in Codex-appropriate wording, using `$SKILL_DIR` anchoring and the harness's plain-text elicitation idiom instead of `AskUserQuestion`.

- Add a "Grill Discipline" section to `plugins/skein/skills/review-plan/rubric.md` with gradeable criteria: (a) grill-eligible findings are limited to the named topic list, (b) exclusion is keyed on `category == 'Nonexistent Reference'`, never on lens membership, (c) grill-eligible findings are presented one at a time with exactly one recommendation via `skein:grill`'s protocol, (d) the loop blocks until each grill-eligible finding is answered, (e) grill-derived plan edits are prefixed `Decision (grilled):` (self-check on the orchestrator's own output), (f) borderline findings resolve to exactly one lane per the documented tiebreak.
- Copy the identical rubric.md content to `plugins/skein-codex/skills/review-plan/rubric.md` (byte-identical, plain data-file copy — not Codex-specific prose, so it does not need `codex:rescue`). **Land this in the same commit as the `.claude` rubric.md edit** — `check-prompt-parity.sh` fails if a commit lands between the two, so the invariant "the two rubric.md files are byte-identical after every commit on this branch" must hold from the first commit that touches either.
- Delegate the Codex `grill/SKILL.md` and the Codex `review-plan/SKILL.md` Step 6.4 delegation update to `codex:rescue` (per this repo's convention that Codex-mirror `SKILL.md` content is Codex-authored, adapted rather than hand-copied) — brief it with the same protocol/classification/delegation behavior from Phases 1–2, and remind it to preserve `$SKILL_DIR` anchoring and to describe decisions via plain-text prompts (Codex has no `AskUserQuestion`-equivalent widget, per the existing Clarify precedent at `SKILL.md:525-526`).
- `grill` does **not** need adding to `scripts/check-prompt-parity.sh`'s `MANAGED_SKILLS` list — confirmed by reading the script: it skips any skill where neither side has a `rubric.md` (`scripts/check-prompt-parity.sh:18`), and `grill` ships only a `SKILL.md` on each side, no `rubric.md`/`*-prompt.md`.
- Note for both Phase 1 and Phase 2: their `Test command` (`check-prompt-parity.sh`) is a regression guard only — it does not cover `SKILL.md` prose (only `rubric.md` and the GENERIC finding-schema block are script-enforced), so it will pass even if the grill protocol prose is wrong. The manual walkthroughs in Testing Notes are the actual behavioral validators for Phases 1–2; don't read a green parity script as confirmation the grill logic works.

### Phase 4: Version bump, changelog, and skill listings

**Impl files:** `plugins/skein/.claude-plugin/plugin.json`, `plugins/skein-codex/.codex-plugin/plugin.json`, `CHANGELOG.md`, `README.md`
**Test files:** (none)
**Test command:** `bash scripts/check-prompt-parity.sh`
**Validation cmd:** `git diff --stat plugins/skein/.claude-plugin/plugin.json plugins/skein-codex/.codex-plugin/plugin.json`

- Bump both manifests from `0.4.1` to `0.5.0` (new skill + feature, not a patch) — dual bump is mandatory per this repo's release convention.
- Add the entry directly under a new `## [0.5.0] - <date>` heading in `CHANGELOG.md` (not staged under `[Unreleased]` first) — this matches the repo's actual practice: `[0.4.1]` already carries full release content with `[Unreleased]` left empty above it. Describe both the new `skein:grill` skill and the `review-plan` Step 6.4 delegation. Add the corresponding footer compare-link, `[0.5.0]: https://github.com/vr000m/skein/compare/v0.4.1...v0.5.0`. (Note: the existing `[0.4.1]` heading is itself missing a footer compare-link — a pre-existing gap, out of scope for this plan to backfill.)
- Add a `grill` row to the root `README.md` skills table (`README.md:9-20`), matching the existing table's style.
- `docs/dev_plans/README.md` task table already updated (done at plan-creation time, prior commit on this branch) — no further action needed; this satisfies the acceptance criterion below without a separate implementation task.

## Technical Specifications

### Files to Modify
- `plugins/skein/skills/review-plan/SKILL.md` — Step 6.4 Clarify sub-step gains classification + delegation to `skein:grill`.
- `plugins/skein/skills/review-plan/rubric.md` — new "Grill Discipline" section.
- `plugins/skein-codex/skills/review-plan/SKILL.md` — semantically-equivalent Codex mirror update, via `codex:rescue`.
- `plugins/skein-codex/skills/review-plan/rubric.md` — byte-identical copy of the Claude rubric.md addition.
- `plugins/skein/.claude-plugin/plugin.json`, `plugins/skein-codex/.codex-plugin/plugin.json` — version bump `0.4.1` → `0.5.0`.
- `CHANGELOG.md` — new entry.
- `README.md` — new `grill` row in the skills table.

### New Files to Create
- `plugins/skein/skills/grill/SKILL.md` — standalone general-purpose grill interview skill (Claude).
- `plugins/skein-codex/skills/grill/SKILL.md` — Codex mirror of the above, via `codex:rescue`.

### Architecture Decisions
- **Extract the interview protocol into a standalone `skein:grill` skill rather than duplicating it inline in Step 6.4.** The original plan folded the protocol directly into Step 6.4's Clarify sub-step; expanding the scope to a user-invocable standalone skill made duplication a real drift risk (two copies of "one recommendation, blocking, three-way outcome" prose that could diverge). Extracting it once and having Step 6.4 delegate to it is the DRY choice and matches how `/review-plan` already delegates reconciliation to `scripts/reconcile-findings.sh` rather than re-describing merge logic per lens.
- **`skein:grill` is user-invocable and not gated behind `/review-plan`.** It accepts a plan file or freeform input, matching mattpocock/skills' `grilling` skill's actual scope (an interview over *whatever you hand it*), not just review findings.
- **No new CLI flag on `/review-plan`.** Grill-style presentation applies automatically to grill-eligible findings within the existing default-on Step 6.4; `--batch` remains the only opt-out. Considered and rejected a separate `--grill` flag for the same reason as the original plan: it would let a caller skip grilling while still running Step 6.4, undermining the point of narrowing Clarify's behavior for decision-class findings.
- **Classification stays prose judgment, not a script or new category enum**, keyed on `category` (not `lens`) for the exclusion rule — fixed from the original plan's imprecise "codebase-claims findings" phrasing after `/review-plan`'s codebase-claims and architecture lenses both flagged it.
- **`Decision (grilled):` prefix is an orchestrator self-instruction, not a mechanically-enforced contract.** `/review-plan`'s own assumptions lens flagged the original plan's implicit claim that `/dev-plan update` preserves the prefix verbatim as an unverified assumption about a prose-weaving tool. Since Step 6.4, `skein:grill`, and `/dev-plan update` all execute within one continuous orchestrating-agent session (no fresh-context handoff), the fix is to name this as a self-check the orchestrator performs on its own output, not a system property to verify externally.
- **`codex:rescue` is a repo authoring convention, not an invocable command.** Corrected from the original plan's Requirements section, which called it "an invocable skill/agent" — `/review-plan`'s codebase-claims lens caught this against this repo's own convention docs.

### Dependencies
- None (no new runtime dependency; this is a new prose-driven skill plus prose/rubric/version changes to existing markdown-driven skills).

### Integration Seams

| Seam | Writer (task) | Caller (task) | Contract |
|------|---------------|---------------|----------|
| Grill classification → `skein:grill` delegation | Phase 2 (`review-plan/SKILL.md` Clarify sub-step) | Phase 1 (`grill/SKILL.md` interview protocol) | Grill-eligible findings must resolve to exactly one of {act-on, waive} before Route runs; the interview protocol itself lives in Phase 1's skill, Phase 2 only classifies and hands off |
| `skein:grill` → `/dev-plan update` | Phase 1 (`grill/SKILL.md`, when target is a plan file) | `/dev-plan update` (existing skill) | Resolved decisions land above the marker in Technical Specifications, prefixed `Decision (grilled):`; write-then-hash ordering (flush before Step 6.5/Step 7) applies whenever the target plan is under active `/review-plan` |
| Rubric parity | Phase 3 (`.claude` rubric.md edit) | `scripts/check-prompt-parity.sh` | `.codex` rubric.md must be byte-identical after Phase 3 lands in the same commit as the `.claude` edit, or the parity check fails the build |
| Codex mirror semantic parity | Phase 3 (`codex:rescue` delegation, both `grill` and `review-plan`) | Human/PR reviewer | Codex mirrors must produce equivalent behavior using `$SKILL_DIR` anchoring and plain-text elicitation; not asserted byte-identical by any script (only the GENERIC finding-schema block and rubric.md are script-enforced), so this seam is reviewed manually |

## Testing Notes

### Test Approach
- [ ] `scripts/check-prompt-parity.sh` passes (rubric.md byte-identity, GENERIC block unaffected)
- [ ] Existing `tests/reconciliation/` and `tests/auto-fix/` suites pass unchanged (regression check — this plan does not touch the reconciler, renderer, or auto-fix appliers)
- [ ] `tests/parity/test_skill_md_presence.py` passes for the new `grill` skill pair (both `plugins/skein/skills/grill/SKILL.md` and `plugins/skein-codex/skills/grill/SKILL.md` must exist)
- [ ] Manual walkthrough, standalone `skein:grill`: invoke directly against a synthetic plan file seeded with a mix of fact/decision content; confirm facts are never asked about, decisions are presented one at a time with a single recommendation each, and all three outcomes (accept / propose alternative / waive) work — accept and propose-alternative both route to `/dev-plan update` with the `Decision (grilled):` prefix actually present in the resulting plan text (not just that `/dev-plan update` was called), waive routes to `### Review Waivers`
- [ ] Manual walkthrough, `/review-plan` delegation: run `/review-plan` against a synthetic plan seeded with a mix of finding types (one `codebase-claims`/`Nonexistent Reference`, one `architecture` finding about a component boundary, one `assumptions` finding about a third-party rate limit); confirm the fact finding is never grill-presented and the two decision findings are handled via `skein:grill`'s protocol
- [ ] Write-then-hash check: after a grill-eligible finding is accepted via Step 6.4, confirm the Step 7 marker hash reflects the post-grill-update above-marker bytes and `/conduct` accepts the plan without a false-drift rejection
- [ ] Codex-mirror manual review: confirm `plugins/skein-codex/skills/grill/SKILL.md` and the Codex `review-plan/SKILL.md` delegation update produce equivalent behavior using `$SKILL_DIR` anchoring and plain-text three-way prompts (no `AskUserQuestion` reference leaks into the Codex mirror)

### Test Results
- [ ] All existing tests pass
- [ ] Manual verification complete

### Edge Cases Tested
- [ ] A finding that plausibly spans two topics (e.g. architecture + testing gap) — confirm the documented tiebreak picks exactly one lane, no double-presentation
- [ ] All selected findings are standard (none grill-eligible) — confirm Clarify behaves exactly as it does today, no regression
- [ ] All selected findings are grill-eligible — confirm strict serial pacing (no batching, no early Route)
- [ ] `--batch` still skips Step 6.4 entirely, including grill classification and delegation
- [ ] `skein:grill` invoked on freeform conversational input (no backing plan file) — confirm decisions are summarized in-conversation rather than silently dropped, and `/dev-plan create` is offered
- [ ] `skein:grill` invoked against a plan whose review marker is already written — confirm it does not silently reopen the contract without explicit acknowledgement

## Acceptance Criteria

- `skein:grill` exists, is user-invocable standalone, and works against both a plan file and freeform conversational input.
- Grill-eligible findings in `/review-plan` Step 6.4 are delegated to `skein:grill`'s protocol — one at a time, one recommendation each, blocking until answered — with no duplicated interview-protocol prose between the two skills.
- The grill-eligible exclusion is keyed on `category == 'Nonexistent Reference'`, not lens membership; `Nonexistent Reference` findings are never grill-presented.
- Borderline findings resolve to exactly one lane per the documented tiebreak.
- Standard findings keep today's 2–3-option Clarify behavior, unmodified.
- `--batch` still skips Step 6.4 entirely — no new flag introduced.
- `rubric.md` is byte-identical across `.claude`/`.codex` mirrors and passes `scripts/check-prompt-parity.sh`.
- Both `.codex` mirrors (`grill`, `review-plan`) have semantically-equivalent behavior, edited via `codex:rescue`, described accurately in this plan as a repo authoring convention rather than an invocable command.
- Both plugin manifests bumped in lockstep; `CHANGELOG.md` and root `README.md` skills table updated.
- `docs/dev_plans/README.md` task table updated (done at plan-creation time).
- Code reviewed and approved
- Tests passing (parity script + `test_skill_md_presence.py` + existing regression suites)
- Documentation updated

<!-- reviewed: YYYY-MM-DD @ <hash> -->
<!-- /review-plan writes the marker line above. Everything below is the workspace: edits here do NOT invalidate the marker. -->

## Progress

- [ ] Phase 1: Create standalone `skein:grill` skill (Claude)
- [ ] Phase 2: Wire `/review-plan` Step 6.4 to delegate to `skein:grill`
- [ ] Phase 3: Rubric criteria + Codex mirrors (both skills)
- [ ] Phase 4: Version bump, changelog, and skill listings

## Findings

- Original single-phase scope (fold grill protocol directly into `/review-plan` Step 6.4) was reviewed via `/review-plan --auto-fix=trivial` on 2026-07-11: 16 findings (0 Critical, 9 Important, 7 Minor), 0 auto-fixable (all judgment-level, no mechanical `auto_fix` blocks emitted). Key findings: `codex:rescue` mischaracterized as an invocable skill (codebase-claims, Important); grill-eligible exclusion keyed on lens instead of category (architecture, Important); no tiebreak rule for borderline findings (spec-and-testing, Important); `Decision (grilled):` verbatim-preservation assumption unverified (assumptions, Important); three Testing Gaps (write-then-hash, override path, Codex-mirror equivalence — spec-and-testing, Important); Phase-atomicity and Claude-only-widget-in-universal-wording issues (Minor). Scope subsequently expanded (this revision) to extract the interview protocol into a standalone `skein:grill` skill rather than duplicating it in Step 6.4 — this addresses the architecture lens's duplication-risk framing directly and folds fixes for all 9 Important findings into the revised plan text above. Re-review via `/review-plan` recommended before implementation begins, given the scope change.

## Issues & Solutions

(none yet)

## Final Results

(fill when complete)
