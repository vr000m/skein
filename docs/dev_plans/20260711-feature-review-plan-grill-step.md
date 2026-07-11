# Task: Standalone `skein:grill` skill + grill-mode decision interview for `/review-plan` Step 6.4

**Status**: Complete
**Component**: review-skills
**Assigned to**: Claude
**Priority**: Medium
**Branch**: feature/review-plan-grill-step
**Created**: 2026-07-11
**Completed**: 2026-07-11
**Review Gates**: none

## Objective

Ship a new general-purpose, user-invocable `skein:grill` skill that runs a relentless, one-question-at-a-time interview (grill-style, inspired by [mattpocock/skills](https://github.com/mattpocock/skills)' `grilling` skill) over any plan, design, or freeform idea the user hands it — proposing one recommended resolution per question, waiting for an answer before advancing, and splitting facts (verified from the codebase) from decisions (must go to the human). Then wire `/review-plan`'s existing Step 6.4 (Interactive Triage-and-Clarify Elicitation Loop) to **delegate to this same skill's Interview Mechanics protocol** — as an inline prose reference within the same orchestrating-agent session, not a skill activation or harness-specific subagent spawn (`Agent` on Claude, `spawn_agent` on Codex; see Architecture & Call Flow) — for the subset of findings that are genuine open decisions — architecture/component boundaries, third-party integration contracts, security, rate-limiting — instead of re-implementing the interview protocol a second time inline.

## Context

`skein:review-plan` already runs five parallel lens agents (architecture, sequencing, spec-and-testing, assumptions, codebase-claims) and, since Step 6.4 shipped, already elicits the user's triage/clarify decisions interactively and records them back into the plan via `/dev-plan update` (`plugins/skein/skills/review-plan/SKILL.md:518-541`).

The trigger for this plan was a conversation about mattpocock/skills' `grilling` skill (`skills/productivity/grilling/SKILL.md`), which — per the upstream description as discussed, not verified against its source since neither the file nor its behavior is present in this codebase — reportedly runs a relentless one-question-at-a-time interview over a plan, proposing a recommended answer for each question and refusing to proceed until the user has answered, explicitly splitting **facts** (look up yourself) from **decisions** (must go to the human). `skein:grill` is a freshly authored skill inspired by this description; correctness of this plan does not hinge on the upstream skill matching it exactly. The original scope of this plan was to fold that protocol into Step 6.4's Clarify sub-step only. Two things changed that:

1. **Two gaps in Step 6.4's Clarify sub-step, as originally identified**: (a) no topic/decision filter — every finding the user selects in Triage gets the same 2–3-option treatment regardless of whether it's a mechanical fact or a genuine judgment call; (b) no single-recommendation, serial-wait protocol — Clarify offers undifferentiated options rather than one recommendation with blocking pacing.
2. **The grill interview protocol is independently useful outside `review-plan` entirely** — a user may want to stress-test a plan or a freeform idea *before* a plan even exists, or outside the review-plan flow altogether. Gating the interview behind "you first ran `/review-plan` and it produced findings" is unnecessarily narrow.

**Revised architecture (see Architecture Decisions):** rather than duplicating the one-question/one-recommendation interaction pattern in two places, this plan extracts it into a standalone `skein:grill` skill and has `/review-plan` Step 6.4 **call it** for the findings it classifies as grill-eligible. `skein:grill` owns the interview mechanics (serial pacing, single recommendation, fact/decision split, accept/override/waive outcomes); `review-plan` owns finding classification and where resolved decisions get recorded (`/dev-plan update`, above the marker). This is a cleaner split of responsibility than the original single-phase plan, and it means the interview protocol has exactly one authoritative definition instead of two copies that could drift.

## Requirements

### `skein:grill` (new, standalone skill)

- `grill/SKILL.md` is structured as two explicitly-anchored sections: **§ Interview Mechanics** (fact/decision split, one recommendation per decision, strict serial pacing, three-way accept/override/waive outcome — the reusable part, referenced inline by `/review-plan` Step 6.4) and **§ Target Acquisition & Persistence** (standalone-only: target parsing, plan-file vs freeform routing, `/dev-plan update` calls, the marker-refusal check). Step 6.4 references only § Interview Mechanics; it never re-runs § Target Acquisition & Persistence, since Step 6.4 already knows its target (the plan under active review) and its persistence route (`/dev-plan update`, Route sub-step).
- User-invocable directly (`/grill`, or natural-language "grill me on X") — not gated behind having run `/review-plan` first, and not auto-triggered by other skills without an explicit call.
- Accepts either: a file path (most commonly a `docs/dev_plans/*.md` plan, but any markdown/text file), or an inline freeform description of a plan/design/idea typed directly in the conversation.
- Splits the interview's questions into two kinds: **facts** (verifiable from the codebase — look them up directly, never ask) and **decisions** (genuine judgment calls with no single correct answer — must go to the human).
- For each decision, proposes exactly **one recommended resolution**, then presents a fixed three-way choice (Claude: `AskUserQuestion` picker; Codex: equivalent plain-text three-way prompt, per the existing Clarify sub-step's harness-divergence precedent at `SKILL.md:521-527`) — **accept** the recommendation, **propose an alternative** (a follow-up free-text prompt captures the override, mirroring Clarify's existing free-text path for "no clear options"), or **waive**. Blocks on each answer before advancing to the next decision — strictly serial, no batching.
- When the target is a `docs/dev_plans/*.md` plan file, accepted/overridden decisions are recorded via `/dev-plan update` (above the marker, in Technical Specifications); when the target is freeform conversational input with no backing plan file, resolved decisions are summarized back in the conversation, with an offer to run `/dev-plan create` if the user wants them persisted.
- Does not run against a plan whose review marker `/review-plan` has already written (below-marker workspace edits are fine per the usual marker rules — this constraint is about not silently reopening a contract that's already been accepted); it can be re-run before the marker exists, same as `/review-plan`'s Step 6.4.

### `/review-plan` Step 6.4 (revised scope, unchanged goal)

- Findings are classified during Clarify (not Triage — Triage's free-form selection stays unchanged) as **grill-eligible** (open decision: architecture/component-boundary, third-party integration, security, rate-limiting topics) vs **standard** (everything else). The exclusion is a structural predicate on `category`, not on lens membership: any finding whose `category == 'Nonexistent Reference'` is always standard, regardless of which lens(es) contributed to a merged finding — `category` and `lens` are not 1:1 after reconciliation (a merged finding can carry `Lenses: [architecture, codebase-claims]` while its category is `Nonexistent Reference`).
- A finding that plausibly spans two topics (e.g. both "architecture" and "testing gap") is presented **once**, under a deterministic tiebreak: grill-eligible topics (architecture/component-boundary, third-party integration, security, rate-limiting) win over standard topics; if a finding spans two grill-eligible topics, present it once under a fixed topic-priority order — **architecture/component-boundary > third-party integration > security > rate-limiting** — applied directly to the topic(s) the finding covers. (This is a topic-priority tiebreak, not a `category`-order tiebreak: a reconciled finding carries exactly one `category`, which cannot itself disambiguate between two topics, so ordering categories was never a workable mechanism.)
- Grill-eligible findings are handed to `skein:grill`'s interview mechanics (one at a time, one recommendation each, blocking) instead of Step 6.4 re-implementing that pacing inline. Standard findings keep today's 2–3-option Clarify behavior, unchanged.
- Resolved grill decisions are recorded via the existing `/dev-plan update` route, prefixed `Decision (grilled): <what to change and why>` in the prose handed to `/dev-plan update`. This prefix is an **authoring instruction to the orchestrating agent** (the same agent runs Step 6.4, invokes `skein:grill`'s protocol, and calls `/dev-plan update` in one continuous session — there is no fresh-context handoff that could drop it), not a claim that some other tool mechanically parses or preserves it; the rubric's gradeable check for it is a self-check on the orchestrator's own output, the same trust model the rest of Step 6.4 already uses.
- `--batch` continues to skip Step 6.4 entirely, including grill classification and delegation — unchanged escape hatch, no new flag introduced.
- The classification logic stays main-agent prose judgment, consistent with the rest of Step 6.4 ("no shell script is involved" — `SKILL.md:520`). No new script, no new category enum value (the existing `{Assumption, Constraint, Ambiguity, Risk, Sequencing, Missing Task, Testing Gap, Nonexistent Reference}` enum is untouched).

### Shared / cross-cutting

- `review-plan/rubric.md` gains gradeable criteria for Step 6.4's delegation to `skein:grill`, kept byte-identical between `.claude` and `.codex` mirrors (enforced by `scripts/check-prompt-parity.sh`). Standalone `skein:grill` behavior stays covered by the manual walkthroughs in Testing Notes unless this plan deliberately adds a separate `grill/rubric.md`; if a grill rubric is added, `grill` must also be added to the managed-skill parity lists in Phase 3.
- Both new skill's mirrors (`plugins/skein/skills/grill/SKILL.md` and `plugins/skein-codex/skills/grill/SKILL.md`) and `review-plan`'s Codex mirror are edited: Claude versions directly, Codex versions through the repo's `codex:rescue` authoring route. Per this repo's own convention docs (`docs/dev_plans/20260707-feature-conduct-phase-goal-field.md:48`), `codex:rescue` is the repo's **route/convention** for Codex-native adaptation and review — it is not a separate CLI command the implementation invokes programmatically; it names how the Codex-mirror work gets authored, not a mechanism the plan calls at runtime.
- Both plugin manifests (`plugins/skein/.claude-plugin/plugin.json`, `plugins/skein-codex/.codex-plugin/plugin.json`) are version-bumped together, and `CHANGELOG.md` gets a new entry.
- The root `README.md` skills table and `docs/dev_plans/README.md` task table both get updated — the latter was already updated when this plan was created (see git history on this branch); the former needs a new `grill` row.

## Review Focus

- Lens-scope discipline: the classification criteria for "grill-eligible" must stay a narrow, named topic list (architecture/component boundaries, third-party integration, security, rate-limiting) — not an open-ended "anything judgment-y."
- The grill-eligible exclusion for `Nonexistent Reference` findings is keyed on `category`, not on `lens` — a finding reconciled from multiple lenses is not 1:1 with a single lens.
- The borderline-classification tiebreak (grill-eligible wins over standard; fixed topic-priority tiebreak among grill-eligible topics) must be concrete enough that "picks one lane" is a testable, gradeable outcome, not a vibe.
- Write-then-hash ordering invariant (`SKILL.md:534-539`): `skein:grill`'s `/dev-plan update` calls (whether invoked standalone or via Step 6.4 delegation) must complete and flush to disk before Step 6.5/Step 7 run when the target is a plan under active `/review-plan` — this plan must not introduce a new writer that races that invariant.
- `codex:rescue` must be described accurately as a repo authoring convention, not an invocable command — do not reintroduce the "invocable skill/agent" framing corrected in this plan's own `/review-plan` pass.
- `scripts/check-prompt-parity.sh` must pass after the `review-plan/rubric.md` edit (byte-identity across `.claude`/`.codex`) and after the new `grill` skill pair exists. Even if `grill` ships only `SKILL.md`, add it to the repo-default managed-skill lists (`scripts/check-prompt-parity.sh` and `tests/parity/test_skill_md_presence.py`) so the presence gate covers both mirrors; `check-prompt-parity.sh` will skip rubric/prompt comparisons for `grill` while it has neither file type.
- Both the new `skein:grill` skill and Step 6.4's delegation to it need actual test coverage beyond a single "override path was exercised once" walkthrough — see Testing Notes for the specific gaps this plan must close (write-then-hash post-grill, override outcome, Codex-mirror equivalence).

## Architecture & Call Flow

This plan touches 3+ independently-executing components (the `review-plan` orchestrator — itself spawning five lens subagents — the new `grill` skill, `/dev-plan update`, and the marker tooling), so the call-flow is made explicit here rather than left implicit in the Integration Seams table.

**Grill-eligible finding path (delegated, inline reference — no skill activation):**
```
main review-plan orchestrating agent
  └─ Step 6.4 Triage (unchanged, free-form selection)
       └─ Step 6.4 Clarify: classify each selected finding
            ├─ standard finding → existing 2–3-option Clarify prose (unchanged)
            └─ grill-eligible finding → follow grill/SKILL.md § Interview Mechanics
                 inline, in the same session (NOT a skill activation or
                 harness subagent spawn: Agent on Claude / spawn_agent on Codex):
                 propose one recommendation → AskUserQuestion (Claude) /
                 plain-text three-way prompt (Codex) → accept / propose
                 alternative / waive, blocking before advancing
       └─ Route: act-on → `/dev-plan update` (this loop's writer #1, prefixed
            `Decision (grilled): ...`) | waive → `### Review Waivers`
  └─ Step 6.5 (--auto-fix=trivial only, unaffected by grill)
  └─ Step 7: write-review-marker.py hashes post-update above-marker bytes
```

**Standalone `/grill` path (direct user invocation, independent of `/review-plan`):**
```
user invokes /grill <target>
  └─ target = docs/dev_plans/*.md file?
       ├─ yes, marker already written → § Target Acquisition & Persistence
       │    refuses, requires explicit acknowledgement
       ├─ yes, no marker yet → § Interview Mechanics → resolved decisions →
       │    § Target Acquisition & Persistence calls `/dev-plan update` (a
       │    fresh, standalone call — not "this loop's", since no active
       │    `/review-plan` Step 6.4 loop exists)
       └─ no (freeform conversational input) → § Interview Mechanics →
            resolved decisions summarized in conversation, § Target
            Acquisition & Persistence offers `/dev-plan create`
```

Both paths execute `grill/SKILL.md` § Interview Mechanics identically; only § Target Acquisition & Persistence (target parsing, plan-file-vs-freeform routing, the marker-refusal check, and which `/dev-plan update` call context applies) differs, and that section is exercised only by the standalone path — Step 6.4's delegated path never calls it, since Step 6.4 already knows its target (the plan under active review) and persistence route (`/dev-plan update`, Route sub-step).

## Implementation Checklist

### Phase 1: Create standalone `skein:grill` skill (Claude)

**Impl files:** `plugins/skein/skills/grill/SKILL.md`
**Test files:** (none — this is a new prose-driven skill with no script; see Testing Notes)
**Test command:** `bash scripts/check-prompt-parity.sh`
**Goal:** The interview protocol (fact/decision split, one recommendation per decision, strict serial pacing, three-way accept/override/waive outcome, plan-file vs freeform-target persistence) has exactly one authoritative definition, reusable by both direct user invocation and Step 6.4's delegation.

- Author `plugins/skein/skills/grill/SKILL.md` with two explicitly-anchored sections (§ Interview Mechanics, § Target Acquisition & Persistence per Requirements). § Interview Mechanics: accepts a target already resolved by the caller, classifies each candidate topic as fact vs decision, and for each decision proposes one recommendation via `AskUserQuestion` (three options: accept / propose alternative / waive), blocking until answered before advancing.
- § Target Acquisition & Persistence (standalone `/grill` invocation only): when target is a `docs/dev_plans/*.md` file, route accepted/overridden decisions through `/dev-plan update`, prefixed `Decision (grilled): <what to change and why>`; when target is freeform, summarize resolved decisions in conversation and offer `/dev-plan create` if the user wants persistence.
- § Target Acquisition & Persistence: refuse to run against a plan whose review marker is already written without the user explicitly acknowledging they're reopening reviewed content (same posture Step 6.4 already takes toward the marker).

### Phase 2: Wire `/review-plan` Step 6.4 to delegate to `skein:grill`

**Impl files:** `plugins/skein/skills/review-plan/SKILL.md`
**Test files:** (none — Step 6.4 is prose-driven with no existing script/test coverage; see Testing Notes)
**Test command:** `bash scripts/check-prompt-parity.sh`
**Goal:** Grill-eligible classification is a narrow, named-topic filter keyed on `category` (never `Nonexistent Reference`, regardless of which lens(es) contributed); grill-eligible findings are handed to `skein:grill`'s interview protocol rather than re-implemented inline, with a deterministic single-lane tiebreak for borderline findings.

- In Step 6.4's Clarify sub-step (`SKILL.md:527`), insert the classification pass described in Requirements (category-keyed exclusion, fixed topic-priority tiebreak for borderline findings).
- For grill-eligible findings: reference `skein:grill`'s § Interview Mechanics inline (one at a time, one recommendation, blocking) — the same orchestrating agent follows that section's prose directly, in-session; it does not activate `grill` as a separate top-level skill call or spawn a subagent (see Architecture & Call Flow, and the Architecture Decision on inline reference vs skill activation). Link to `skein:grill`'s SKILL.md § Interview Mechanics as the authoritative definition, not a duplicate copy — and add the non-duplication manual check to Testing Notes.
- For standard findings: unchanged 2–3-option Clarify behavior.
- Route sub-step (`SKILL.md:528-531`): grill-derived "act on" decisions call `/dev-plan update` with the prose summary prefixed `Decision (grilled): <what to change and why>` (per Requirements, this is an orchestrator self-instruction, not a mechanically-enforced guarantee); grill-derived waivers go to `### Review Waivers` exactly like existing waivers.
- The write-then-hash ordering invariant text (`SKILL.md:534-539`) already covers `skein:grill`'s `/dev-plan update` calls: because Step 6.4 references grill's § Interview Mechanics inline rather than activating it as a separate skill (per the Architecture Decision above), grill-derived writes execute as part of "this loop's `/dev-plan update`" — they are writer #1, not a new fourth writer. Add one clarifying sentence to `SKILL.md:534-539` making this explicit, and add the write-then-hash Testing Note (below) rather than relying on an eyeball re-read alone.

**Divergence window (intentional, gate-safe):** between Phase 1/2 landing and Phase 3 landing, the Claude mirrors (`grill` + `review-plan` Step 6.4) and Codex mirrors are semantically divergent — the Codex side hasn't gained the new behavior yet. This is safe: `check-prompt-parity.sh` does not enforce `SKILL.md` byte-identity (only `rubric.md` and the GENERIC finding-schema block), so no gate breaks mid-window. It is not safe to *ship* in this state — Phase 3 must land in the same PR as Phases 1–2, not deferred to a follow-up.

### Phase 3: Rubric criteria + Codex mirrors (both skills)

**Impl files:** `plugins/skein/skills/review-plan/rubric.md`, `plugins/skein-codex/skills/review-plan/rubric.md`, `plugins/skein-codex/skills/review-plan/SKILL.md`, `plugins/skein-codex/skills/grill/SKILL.md`, `scripts/check-prompt-parity.sh`, `tests/parity/test_skill_md_presence.py`
**Test files:** `tests/parity/test_skill_md_presence.py`
**Test command:** `bash scripts/check-prompt-parity.sh && uv run --with pytest python -m pytest tests/parity/test_skill_md_presence.py -q`
**Goal:** `review-plan/rubric.md` stays byte-identical across mirrors; the new `grill` skill is registered in the managed-skill presence/parity inventory; both Codex mirrors (`grill` and `review-plan`'s Step 6.4 delegation) gain semantically equivalent behavior in Codex-appropriate wording, using `$SKILL_DIR` only for real bundled-path anchors and the harness's plain-text elicitation idiom instead of `AskUserQuestion`.

- Add a "Grill Discipline" section to `plugins/skein/skills/review-plan/rubric.md` with gradeable criteria: (a) grill-eligible findings are limited to the named topic list, (b) exclusion is keyed on `category == 'Nonexistent Reference'`, never on lens membership, (c) grill-eligible findings are presented one at a time with exactly one recommendation via `skein:grill`'s protocol, (d) the loop blocks until each grill-eligible finding is answered, (e) grill-derived plan edits are prefixed `Decision (grilled):` (self-check on the orchestrator's own output), (f) borderline findings resolve to exactly one lane per the documented tiebreak.
- Copy the identical rubric.md content to `plugins/skein-codex/skills/review-plan/rubric.md` (byte-identical, plain data-file copy — not Codex-specific prose, so it does not require the `codex:rescue` authoring route). **Land this in the same commit as the `.claude` rubric.md edit** — `check-prompt-parity.sh` fails whenever it is invoked (CI, a local run, or a `skein:conduct` phase-test) at a working-tree/tip state where only one side has the edit; it is not a per-commit git-history check, but landing the pair in one commit guarantees no intermediate working-tree state can trip it.
- Author the Codex `grill/SKILL.md` and the Codex `review-plan/SKILL.md` Step 6.4 update through the repo's `codex:rescue` authoring route (Codex-native adaptation rather than a hand-copy; this is not a command to invoke) — give that authoring pass the same protocol/classification/delegation behavior from Phases 1–2, and preserve existing `$SKILL_DIR` anchors in `review-plan/SKILL.md`. Do not invent a `$SKILL_DIR` path in `grill/SKILL.md` unless Phase 3 adds a bundled resource or script for that skill; the planned single-file grill mirror should just use plain-text prompts for decisions (Codex has no `AskUserQuestion`-equivalent widget, per the existing Clarify precedent at `SKILL.md:525-526`).
- **Ordering within this phase**: author both Codex mirrors first — confirm `plugins/skein-codex/skills/grill/SKILL.md` exists on disk after the `codex:rescue` authoring pass — before registering `grill` in `tests/parity/test_skill_md_presence.py`'s `MANAGED_SKILLS`. That presence test is the only gate that requires the Codex mirror to exist (`scripts/check-prompt-parity.sh` never checks `SKILL.md` presence, only `rubric.md`/`*-prompt.md`), so registering `grill` there before the file exists fails the test at that tip.
- Add `grill` to `scripts/check-prompt-parity.sh`'s default `MANAGED_SKILLS` list and to `tests/parity/test_skill_md_presence.py`'s hard-coded `MANAGED_SKILLS` list. **Note the two lists are already asymmetric** (the script's default list omits `review-gauntlet`; the pytest list includes it, despite the pytest list's own comment claiming it mirrors the script) — treat this as two independent registrations, not one mirrored list. The script's rubric loop will still skip `grill` while neither mirror has `rubric.md` (`scripts/check-prompt-parity.sh:18-20`), and the prompt loop will skip it while neither mirror has `*-prompt.md`, but the presence test must include the new user-invocable skill so a missing Codex mirror fails deterministically.
- Note for both Phase 1 and Phase 2: their `Test command` (`check-prompt-parity.sh`) is a regression guard only — it does not cover `SKILL.md` prose (only `rubric.md` and the GENERIC finding-schema block are script-enforced), so it will pass even if the grill protocol prose is wrong. The manual walkthroughs in Testing Notes are the actual behavioral validators for Phases 1–2; don't read a green parity script as confirmation the grill logic works.

### Phase 4: Version bump, changelog, and skill listings

**Impl files:** `plugins/skein/.claude-plugin/plugin.json`, `plugins/skein-codex/.codex-plugin/plugin.json`, `CHANGELOG.md`, `README.md`
**Test files:** (none)
**Test command:** `bash scripts/check-prompt-parity.sh`
**Validation cmd:** `jq -r .version plugins/skein/.claude-plugin/plugin.json plugins/skein-codex/.codex-plugin/plugin.json | sort -u | wc -l` — must print `1` (both manifests agree on the version string, not merely that both files changed; `git diff --stat` alone would not catch a lockstep-bump mismatch like the prior v0.2.1 incident)

- Bump both manifests from `0.4.1` to `0.5.0` (new skill + feature, not a patch) — dual bump is mandatory per this repo's release convention.
- Add the entry directly under a new `## [0.5.0] - <date>` heading in `CHANGELOG.md` (not staged under `[Unreleased]` first) — this matches the repo's actual practice: `[0.4.1]` already carries full release content with `[Unreleased]` left empty above it. Describe both the new `skein:grill` skill and the `review-plan` Step 6.4 delegation. Add the corresponding footer compare-link, `[0.5.0]: https://github.com/vr000m/skein/compare/v0.4.1...v0.5.0`. (Note: the existing `[0.4.1]` heading is itself missing a footer compare-link — a pre-existing gap, out of scope for this plan to backfill.)
- Add a `grill` row to the root `README.md` skills table (`README.md:9-20`), matching the existing table's style.
- `docs/dev_plans/README.md` task table already updated (done at plan-creation time, prior commit on this branch) — no further action needed; this satisfies the acceptance criterion below without a separate implementation task.

## Technical Specifications

### Files to Modify
- `plugins/skein/skills/review-plan/SKILL.md` — Step 6.4 Clarify sub-step gains classification + delegation to `skein:grill`.
- `plugins/skein/skills/review-plan/rubric.md` — new "Grill Discipline" section.
- `plugins/skein-codex/skills/review-plan/SKILL.md` — semantically-equivalent Codex mirror update, authored through the `codex:rescue` route.
- `plugins/skein-codex/skills/review-plan/rubric.md` — byte-identical copy of the Claude rubric.md addition.
- `plugins/skein/.claude-plugin/plugin.json`, `plugins/skein-codex/.codex-plugin/plugin.json` — version bump `0.4.1` → `0.5.0`.
- `CHANGELOG.md` — new entry.
- `README.md` — new `grill` row in the skills table.

### New Files to Create
- `plugins/skein/skills/grill/SKILL.md` — standalone general-purpose grill interview skill (Claude).
- `plugins/skein-codex/skills/grill/SKILL.md` — Codex mirror of the above, authored through the `codex:rescue` route.

### Architecture Decisions
- **Extract the interview protocol into a standalone `skein:grill` skill rather than duplicating it inline in Step 6.4.** The original plan folded the protocol directly into Step 6.4's Clarify sub-step; expanding the scope to a user-invocable standalone skill made duplication a real drift risk (two copies of "one recommendation, blocking, three-way outcome" prose that could diverge). Extracting it once and having Step 6.4 reference it inline is the DRY choice — loosely analogous to how `/review-plan` delegates reconciliation to `scripts/reconcile-findings.sh` rather than re-describing merge logic per lens, though the analogy is partial: the script is a deterministic executable enforced byte-identical by `check-prompt-parity.sh`, while a prose cross-reference to `grill/SKILL.md` § Interview Mechanics has no equivalent parity-gate enforcement. The single-copy discipline here rests on convention and manual review (the non-duplication Testing Note below), not an automated gate.
- **Step 6.4 delegates to `skein:grill` via an inline prose reference to its § Interview Mechanics, not a skill activation or harness-specific subagent spawn (`Agent` / `spawn_agent`).** The main orchestrating agent running Step 6.4 reads and follows `grill/SKILL.md` § Interview Mechanics directly in its existing session; on Codex this deliberately does not create a clean-context `spawn_agent` worker, so the active finding set and Route state remain in the main session that already drives Step 6.4's plain-text prompts (`plugins/skein-codex/skills/review-plan/SKILL.md:519,525-529`). It never runs grill's § Target Acquisition & Persistence (target parsing, plan-file-vs-freeform routing, marker-refusal check), which is standalone-only and inapplicable mid-Step-6.4 (Step 6.4 already knows its target and persistence route). This keeps grill-derived `/dev-plan update` writes inside "this loop's `/dev-plan update`" for the write-then-hash invariant — see Architecture & Call Flow.
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
| Grill classification → `skein:grill` delegation | Phase 2 (`review-plan/SKILL.md` Clarify sub-step) | Phase 1 (`grill/SKILL.md` § Interview Mechanics) | Grill-eligible findings must resolve to exactly one of {act-on, waive} before Route runs; the interview protocol itself lives in Phase 1's skill's § Interview Mechanics, Phase 2 only classifies and follows that section inline (no skill activation or spawn) |
| `skein:grill` → `/dev-plan update` | Phase 1 (`grill/SKILL.md`, when target is a plan file) | `/dev-plan update` (existing skill) | Resolved decisions land above the marker in Technical Specifications, prefixed `Decision (grilled):`; write-then-hash ordering (flush before Step 6.5/Step 7) applies whenever the target plan is under active `/review-plan` |
| Rubric parity | Phase 3 (`.claude` rubric.md edit) | `scripts/check-prompt-parity.sh` | `.codex` rubric.md must be byte-identical after Phase 3 lands in the same commit as the `.claude` edit, or the parity check fails the build |
| Codex mirror semantic parity | Phase 3 (`codex:rescue` authoring route for both `grill` and `review-plan`) | Human/PR reviewer | Codex mirrors must produce equivalent behavior using main-session plain-text elicitation: the grill-delegation instructions must not tell Codex to invoke Claude's `AskUserQuestion` API, activate a separate skill, or use a `spawn_agent` handoff for Step 6.4's grill path. Explanatory comparisons may still name `AskUserQuestion` when documenting the harness divergence. Preserve `$SKILL_DIR` only where bundled-path anchors already exist or are newly justified; semantic parity is not asserted byte-identical by any script (only the GENERIC finding-schema block and rubric.md are script-enforced), so this seam is reviewed manually |

## Testing Notes

### Test Approach
- [ ] `scripts/check-prompt-parity.sh` passes (rubric.md byte-identity, GENERIC block unaffected)
- [ ] Existing `tests/reconciliation/`, `tests/auto-fix/`, and `tests/plugin/` suites pass unchanged (regression check — this plan does not touch the reconciler, renderer, or auto-fix appliers, and only bumps the manifest version field validated by `tests/plugin/test_manifests.sh`)
- [ ] `tests/parity/test_skill_md_presence.py` passes after adding `grill` to its managed-skill list (both `plugins/skein/skills/grill/SKILL.md` and `plugins/skein-codex/skills/grill/SKILL.md` must exist)
- [ ] Manual walkthrough, standalone `skein:grill`: invoke directly against a synthetic plan file seeded with a mix of fact/decision content; confirm facts are never asked about, decisions are presented one at a time with a single recommendation each, and all three outcomes (accept / propose alternative / waive) work — accept and propose-alternative both route to `/dev-plan update` with the `Decision (grilled):` prefix actually present in the resulting plan text (not just that `/dev-plan update` was called); waive is conversational-only for standalone `/grill` and must NOT appear under `### Review Waivers` — that subheading is written only by `/review-plan` Step 6.4's Route sub-step, which standalone `/grill` never runs
- [ ] Manual walkthrough, standalone `skein:grill` against a non-plan file: invoke `/grill README.md` (or another existing file outside `docs/dev_plans/`); confirm the file is never edited and no `/dev-plan update` call is made for any outcome — all `accept`/`override`/`waive` outcomes are summarized in conversation only
- [ ] Manual walkthrough, `/review-plan` delegation: run `/review-plan` against a synthetic plan seeded with a mix of finding types (one `codebase-claims`/`Nonexistent Reference`, one `architecture` finding about a component boundary, one `security` finding about an auth/rate-limit boundary, one `assumptions` finding about a third-party rate limit); confirm the fact finding is never grill-presented and the three decision findings are handled via `skein:grill`'s § Interview Mechanics; have one decision finding take the **accept** branch and one take the **propose-alternative (override)** branch, and confirm both land above the marker via `/dev-plan update` prefixed `Decision (grilled):` — the override path must be exercised inside the *delegated* flow specifically, not only in the standalone walkthrough above
- [ ] Write-then-hash check: after a grill-eligible finding is accepted via Step 6.4, confirm the Step 7 marker hash reflects the post-grill-update above-marker bytes and `/conduct` accepts the plan without a false-drift rejection
- [ ] Non-duplication check (both mirrors): confirm `review-plan/SKILL.md`'s Step 6.4 Clarify sub-step contains no inline restatement of the serial-pacing/one-recommendation/three-way-outcome prose — it only references `grill/SKILL.md` § Interview Mechanics. This is a manual reviewer check since `check-prompt-parity.sh` does not inspect `SKILL.md` prose.
- [ ] Codex-mirror manual review: confirm `plugins/skein-codex/skills/grill/SKILL.md` and the Codex `review-plan/SKILL.md` delegation update produce equivalent behavior using plain-text three-way prompts; reject only grill-delegation prose that instructs Codex to invoke Claude's `AskUserQuestion` API, not explanatory mentions that document why Codex uses ordinary conversational prompts. Preserve `$SKILL_DIR` only for real bundled-path anchors

### Test Results
- [ ] All existing tests pass
- [ ] Manual verification complete

### Edge Cases Tested
- [ ] A finding that plausibly spans one grill-eligible and one standard topic (e.g. architecture + testing gap) — confirm grill-eligible wins over standard, no double-presentation
- [ ] A finding that plausibly spans two grill-eligible topics (e.g. third-party integration + security) — confirm the fixed topic-priority tiebreak (architecture/component-boundary > third-party integration > security > rate-limiting) picks exactly one lane, no double-presentation
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
- Both `.codex` mirrors (`grill`, `review-plan`) have semantically-equivalent behavior, authored through the repo's `codex:rescue` route, described accurately in this plan as a repo authoring convention rather than an invocable command.
- `grill` is added to the repo-default managed-skill inventory in `scripts/check-prompt-parity.sh` and `tests/parity/test_skill_md_presence.py`, so the new skill pair is covered by the presence gate even without a `grill/rubric.md` or `*-prompt.md`.
- Both plugin manifests bumped in lockstep; `CHANGELOG.md` and root `README.md` skills table updated.
- `docs/dev_plans/README.md` task table updated (done at plan-creation time).
- Code reviewed and approved
- Tests passing (parity script + `test_skill_md_presence.py` + existing regression suites)
- Documentation updated

<!-- reviewed: 2026-07-11 @ 668b6aedf3b507e0440e6fddd93bbda7c523d006 -->

<!-- /review-plan writes the marker line above. Everything below is the workspace: edits here do NOT invalidate the marker. -->

## Progress

- [x] Phase 1: Create standalone `skein:grill` skill (Claude)
- [x] Phase 2: Wire `/review-plan` Step 6.4 to delegate to `skein:grill`
- [x] Phase 3: Rubric criteria + Codex mirrors (both skills)
- [x] Phase 4: Version bump, changelog, and skill listings

## Findings

- Original single-phase scope (fold grill protocol directly into `/review-plan` Step 6.4) was reviewed via `/review-plan --auto-fix=trivial` on 2026-07-11: 16 findings (0 Critical, 9 Important, 7 Minor), 0 auto-fixable (all judgment-level, no mechanical `auto_fix` blocks emitted). Key findings: `codex:rescue` mischaracterized as an invocable skill (codebase-claims, Important); grill-eligible exclusion keyed on lens instead of category (architecture, Important); no tiebreak rule for borderline findings (spec-and-testing, Important); `Decision (grilled):` verbatim-preservation assumption unverified (assumptions, Important); three Testing Gaps (write-then-hash, override path, Codex-mirror equivalence — spec-and-testing, Important); Phase-atomicity and Claude-only-widget-in-universal-wording issues (Minor). Scope subsequently expanded (this revision) to extract the interview protocol into a standalone `skein:grill` skill rather than duplicating it in Step 6.4 — this addresses the architecture lens's duplication-risk framing directly and folds fixes for all 9 Important findings into the revised plan text above. Re-review via `/review-plan` recommended before implementation begins, given the scope change.
- Second `/review-plan` pass on 2026-07-11 (post-extraction revision, no `--auto-fix`): raw=17, merged=1, unique=15, related=3, dropped=0; 7 Important, 8 Minor, 0 Critical. All 15 findings accepted and fixed directly in the plan text above (user directive: "fix all"): (1) pinned the "delegate to `skein:grill`" mechanism to an inline prose reference to `grill/SKILL.md` § Interview Mechanics, never a skill activation/`Agent` spawn, via a new Architecture Decision and a two-section split of `grill/SKILL.md` (§ Interview Mechanics vs § Target Acquisition & Persistence); (2) replaced the broken category-enum tiebreak with a fixed topic-priority order (architecture/component-boundary > third-party integration > security > rate-limiting); (3) added a `## Architecture & Call Flow` section covering both the delegated and standalone paths; (4) tied the write-then-hash invariant explicitly to the inline-reference resolution (grill's writes are loop-writer #1, not a new writer); (5) added explicit Phase 3 intra-phase ordering (Codex mirror before pytest `MANAGED_SKILLS` registration) and noted the pre-existing `MANAGED_SKILLS` list asymmetry; (6) closed three Testing Gaps (security-topic + override-in-delegation-path walkthrough, grill-vs-grill tiebreak edge case, non-duplication manual check); (7) reworded the overstated "fails if a commit lands between" claim and the DRY/`reconcile-findings.sh` analogy to accurately describe convention-enforced vs gate-enforced guarantees; (8) tightened the Phase 4 validation command to an actual version-equality assertion instead of `git diff --stat`; (9) added `tests/plugin/` to the Phase 4 regression checklist; (10) hedged the external `mattpocock/skills` behavioral claim as unverified inspiration. The one Minor codebase-claims finding (pre-existing `[0.4.1]` CHANGELOG compare-link gap) required no action — already correctly scoped out by the plan. Codex-mirror-related fixes (Phase 3 framing, Architecture & Call Flow's standalone/Codex path, `codex:rescue` usage) were additionally reviewed by `codex:rescue` per user request; see below for its disposition.
- `codex:rescue` pass on 2026-07-11 against the post-fix plan text: 5 fixes applied directly to the plan document, verified against `AGENTS.md:44-47` and `plugins/skein-codex/skills/review-plan/SKILL.md:519,525-529`. (1) Added explicit Claude `Agent` / Codex `spawn_agent` terminology to the Objective and the inline-reference Architecture Decision, clarifying that Codex's own session model does not spawn a clean-context worker for grill's § Interview Mechanics — the main session that already drives Step 6.4's plain-text prompts consumes it inline. (2) Confirmed Phase 3's mirror-before-`MANAGED_SKILLS` ordering was already correct and reworded remaining `codex:rescue` mentions to consistently read as an authoring route, not an invocable command. (3) Tightened the Integration Seams "Codex mirror semantic parity" row to require main-session plain-text elicitation (no `AskUserQuestion`, skill activation, or `spawn_agent` handoff) and to scope `$SKILL_DIR` preservation to justified bundled paths. `git diff --check` passed; the marker line, placeholder note, and everything below were left untouched.

## Issues & Solutions

(none yet)

## Final Results

### Summary

`skein:grill` is implemented in both plugins (`plugins/skein`, `plugins/skein-codex`): a standalone, user-invocable relentless fact/decision interview skill, structured into § Interview Mechanics (reusable protocol) and § Target Acquisition & Persistence (standalone-only target parsing, marker-refusal check, persistence routing). `/review-plan` Step 6.4 delegates grill-eligible findings (category-keyed, `Nonexistent Reference` always excluded, fixed topic-priority tiebreak) to this protocol inline, in-session. Both `rubric.md` mirrors gained a byte-identical "Grill Discipline" section. Four rounds of review-gauntlet/manual fixes closed cross-reference drift, a marker refresh, a premature status flip, and (round 4) an undefined non-plan-file target branch plus a contradictory standalone-waive test line.

### Outcomes

- All 4 phases (Claude skill, Step 6.4 wiring, rubric/Codex mirrors, version bump + docs) shipped and merged via [PR #15](https://github.com/vr000m/skein/pull/15) (commit `701f996`, fast-forward merge to `main`).
- Released as `v0.5.0` (tag `v0.5.0`, GitHub release published).
- Automated tests passing: `scripts/check-prompt-parity.sh`, `tests/parity/test_skill_md_presence.py` (13/13), `tests/plugin/test_manifests.sh`.
- Round-4 diff (post-gauntlet-convergence manual fixes) passed a targeted `/code-review` (2 finder angles: line-by-line prose/logic scan, cross-mirror parity check) with zero findings.
- **Not exercised**: the interactive manual walkthroughs listed under Testing Notes (standalone `/grill` against a synthetic plan and against a non-plan file, `/review-plan` Step 6.4 delegation with a seeded finding mix, the write-then-hash check, and the borderline-topic tiebreak cases) were not run this session — the installed plugin cache predated this branch's `grill` skill, so it couldn't be invoked live before merge. These remain open follow-up verification once the released `v0.5.0` plugin is installed.
