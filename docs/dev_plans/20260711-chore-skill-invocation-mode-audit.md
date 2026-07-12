# Task: Skill Invocation-Mode Audit — model-invoked vs. user-invoked classification

**Status**: Not Started
**Component**: meta
**Assigned to**: Claude
**Priority**: Low
**Branch**: chore/skill-invocation-mode-audit
**Created**: 2026-07-11
**Completed**: (pending)

## Objective

Classify each of skein's 13 skills as **command-only** (invoked exclusively via explicit `/skill-name`, never by natural language) or **natural-language-triggered** (a user plausibly reaches it by describing intent, or another skill relies on the harness auto-selecting it), and mark the command-only ones `disable-model-invocation: true` so their `description:` front-matter stops contributing to per-turn context load. This is a **Claude-only** front-matter change (`plugins/skein/skills/*/SKILL.md`) — a Codex-side research pass confirmed the Codex CLI (`plugins/skein-codex/skills/*/SKILL.md`) has no equivalent opt-out mechanism, so the Codex mirror instead gets a documented-divergence comment on affected skills (see Context item 3).

## Context

Reviewing github.com/mattpocock/skills' `productivity/writing-great-skills` (a reference skill for authoring skills well) surfaced its invocation-mode distinction: a **model-invoked** skill keeps its `description` loaded in context every turn so the harness can fire it autonomously, paying **context load** continuously; a **user-invoked** skill (`disable-model-invocation: true`) is reachable only by the user typing its name, paying zero context load but requiring the user to remember it exists.

Skein currently has 13 skills, all model-invoked, none using `disable-model-invocation`. A word count of each `description:` field:

| Skill | Words | Skill | Words |
|---|---|---|---|
| conduct | 62 | grill | 89 |
| content-draft | 69 | plan-view | 69 |
| content-review | 59 | review-gauntlet | 55 |
| deep-review | 47 | review-plan | 78 |
| dev-plan | 74 | rfc-finder | 62 |
| fan-out | 43 | spec-compliance | 57 |
| update-docs | 51 | | |

That's ~815 words of always-loaded trigger text, growing every time skein adds a skill (11 → 13 in the last two months).

**Classification runs on two independent axes, not one.** A skill must stay model-invoked if *either* is true:

- **Axis 1 — chained-into.** Another skill's SKILL.md invokes it by literal `/name` or `skein:name` text (e.g. `conduct`/`fan-out` → `review-gauntlet`). Disabling breaks that caller regardless of whether a human ever types the command.
- **Axis 2 — independently content-triggered.** The skill's own `description` fires on content the user didn't have to name the skill to produce — e.g. `rfc-finder`'s description lists implicit keyword triggers ("RFC", "IETF", "WebRTC", "QUIC" per `docs/skills_architecture/20260522-design-claude-skills-architecture.md`'s Trigger Phrases section), so it plausibly fires whenever a plan or conversation mentions an RFC, independent of any other skill chaining into it. `content-draft`/`content-review` sit in the same gray area: their triggers ("draft a TIL", "polish this post") are the user describing intent, not literally naming the skill, and don't depend on chaining either.

Axis 1 is a hard exclusion (chaining is a correctness question — get it wrong and another skill silently breaks). Axis 2 is a judgment call per skill (does this skill's own keyword/intent trigger actually fire often enough in practice to matter) — Phase 1 must reason about it explicitly per skill rather than defaulting to "narrow scope = safe to disable." **This plan does not pre-decide the classification** — that's Phase 1's job, and no skill is presumed disable-eligible in Context; the candidate list from the original draft (`fan-out`, `plan-view`, `spec-compliance`, `rfc-finder`, `review-gauntlet`) is retracted here because `review-gauntlet` fails Axis 1 (see below) and `rfc-finder` plausibly fails Axis 2 — Phase 1 starts from the two-axis test, not from a pre-narrowed list.

**Three things must be verified before any front-matter is edited, not assumed:**

1. **Does `disable-model-invocation: true` break in-repo cross-skill chaining (Axis 1)?** `review-gauntlet`'s SKILL.md invokes `/code-review` (line 93), `skein:deep-review` (line 98), and `/security-review` (line 99) as literal text — not `/review-plan`/`/deep-review` as an earlier draft of this plan incorrectly stated. More importantly, `review-gauntlet` is itself a chained-*into* target: `conduct` (`conduct/SKILL.md:364`) and `fan-out` (`fan-out/SKILL.md:242`) autonomously invoke `review-gauntlet --plan <path>` as literal prose. `review-gauntlet` is therefore **excluded from any disable candidacy**, the same as `review-plan`/`deep-review` — it fails Axis 1, not a candidate needing Phase 0 confirmation. Whether an *orchestrating skill's prose* invocation of a *disabled* target still resolves (per the Skill tool's own description, which only guarantees "one the user explicitly typed as `/<name>`") remains genuinely ambiguous and needs empirical confirmation against a skill that actually is chained into — not against an untouched-by-anyone skill.
2. **Does `disable-model-invocation: true` actually reduce per-turn context load, or only gate autonomous firing (the load-bearing premise of this whole plan)?** The stated rationale — that disabling removes the `description` from what's loaded each turn — is itself an unverified claim about harness internals; this repo has no visibility into how the loader actually decides context inclusion. Phase 0 must check this directly, not just confirm that autonomous firing stops.
3. **Does the Codex CLI harness even read a `disable-model-invocation`-equivalent field? — Resolved by a Codex-side research pass (codex-rescue), 2026-07-12.** No. Codex's own skill docs (`https://learn.chatgpt.com/docs/build-skills`) specify only `name` and `description` in `SKILL.md` front-matter; the local Codex CLI binary (0.144.1) has no matching field or source string. Codex's own docs (`https://learn.chatgpt.com/docs/customization/overview`) also confirm Codex CLI **does** have autonomous natural-language skill selection analogous to Claude Code's model-invoked skills — so this is not a case where the whole distinction is moot on Codex; it's a case where Codex has the same problem (autonomous firing pays context load) but **no documented opt-out**. Consequence for Phase 2: `disable-model-invocation: true` is a **Claude-only** front-matter addition. The Codex mirror cannot be given an equivalent — every skill classified user-invoked under the Claude axis stays autonomously invocable on the Codex side regardless, and Phase 2 must record this as a **permanent, harness-imposed divergence** (not a documented-but-symmetric choice, and not "unresolved") in each edited skill's Codex `SKILL.md`, e.g. a one-line comment noting Codex has no equivalent suppression mechanism as of this writing.
   - **Chaining-map correction from the same research pass**: `plugins/skein-codex/skills/review-plan/SKILL.md:529` explicitly annotates its `skein:grill` reference as "not a skill activation" — exclude that specific edge from the Codex-side chaining map. This is a Codex-mirror implementation detail (grill's logic may be inlined differently there); it does not by itself tell us whether the Claude-side `review-plan` → `skein:grill` delegation (AGENTS.md's Skill Workflow step 2: "delegated inline to `skein:grill`") is a real Axis-1 edge on the Claude mirror — Phase 0's chaining-map task (below) must check the Claude mirror's actual invocation mechanism independently, not assume the Codex annotation transfers.
   - `conduct`/`fan-out` → `review-gauntlet` is confirmed as a genuine dependency on both mirrors (`review-gauntlet/SKILL.md:25` calls it an "auto-chain" caller) — reinforces this plan's existing exclusion of `review-gauntlet` from disable candidacy.

## Review Focus

- Verify Phase 0's chaining test is run against a skill that is *actually* chained into by another skill's prose (e.g. `fan-out` or `plan-view`), not a skill nothing chains into — a passing test against an untouched skill proves nothing about chaining survival.
- Verify Phase 0 separately confirms the context-load-reduction premise itself (not only that autonomous firing stops), since that's the plan's entire cost justification.
- Verify the final classification table's reasoning per skill is concrete and addresses **both** axes explicitly (cites a real chaining edge for Axis 1, and a real description trigger phrase — or its absence — for Axis 2), not a restatement of a pre-narrowed candidate list.
- Verify Codex-mirror handling is explicit for every skill: either the equivalent field is applied, or its absence/inapplicability is stated with a reason — no skill silently skipped.
- Verify no skill that other skills chain into (`review-plan`, `deep-review`, `review-gauntlet`, `security-review` if present, and any skill referenced by literal `/name` or `skein:name` text elsewhere in the plugin) is marked `disable-model-invocation`.
- Verify the chaining-inventory step (Phase 0) actually enumerates every inbound `/name`/`skein:name` reference across both mirrors before Phase 1 classifies anything — not reconstructed ad hoc per skill.
- Confirm `scripts/check-prompt-parity.sh` does not currently inspect SKILL.md front-matter (it checks `rubric.md`/`*-prompt.md`/schema-block parity only) and that Phase 2's actual verification step is a direct front-matter diff, not a claim that this script covers it. Also confirm whether `scripts/check-prompt-parity.sh`'s `MANAGED_SKILLS` default (currently 12 skills) is reconciled with the real 13-skill set or the gap is explicitly documented.

## Implementation Checklist

### Phase 0: Build the chaining map, then verify the three open questions before classifying anything

**Impl files:** none (research phase — findings recorded in this plan's Context/Requirements)
**Test files:** none
**Test command:** n/a

- **Build the inbound-chaining map first.** Grep every `plugins/skein/skills/*/SKILL.md` and `plugins/skein-codex/skills/*/SKILL.md` body for literal `/name` or `skein:name` references to other skills (e.g. `rg -n '(/|skein:)(conduct|content-draft|content-review|deep-review|dev-plan|fan-out|grill|plan-view|review-gauntlet|review-plan|rfc-finder|spec-compliance|update-docs)\b' plugins/*/skills/*/SKILL.md`). Record the resulting edge list (caller → callee) in this plan's Context section. This is the Axis 1 input for Phase 1 — known edges already include `conduct`/`fan-out` → `review-gauntlet`, `review-gauntlet` → `/code-review`/`skein:deep-review`/`/security-review`, `review-plan` → `skein:grill`, `dev-plan`/`update-docs` → `plan-view`, and `conduct`/`dev-plan`/`review-plan`/`review-gauntlet` → `fan-out`.
- **Chaining-survival test (Axis 1).** Pick a skill that the map above shows *is* chained into (e.g. `plan-view`, since `dev-plan`/`update-docs` invoke it) — not an untouched skill — and in a throwaway branch or worktree distinct from `chore/skill-invocation-mode-audit`, set `disable-model-invocation: true` on it. Confirm: (a) explicit `/plan-view` still works, (b) it no longer appears available for autonomous natural-language firing, (c) whether the literal `/plan-view`-style text inside `dev-plan`'s/`update-docs`' own SKILL.md prose still successfully invokes it. Revert the scratch change after observing the result — it is not this phase's real edit.
- **Context-load test (the plan's core premise).** Independently confirm that disabling actually removes the skill's `description` from per-turn context, not merely that autonomous firing stops — this is a distinct question from (a)/(b)/(c) above. Any low-stakes skill (e.g. `rfc-finder`) is fine as the subject for this specific check, since it doesn't depend on chaining. If this cannot be directly observed, say so plainly rather than carrying the assumption forward unverified.
- ~~Grep the Codex CLI's own skill-loading documentation/source for whether a front-matter key suppresses autonomous invocation the same way.~~ **Done** (Context item 3): confirmed no such field exists, and confirmed Codex CLI does have autonomous natural-language selection (so the problem is real there, just unfixable via front-matter today). Phase 1/2 must treat this as resolved, not a pending question.
- Cross-check the Codex-side chaining-map correction (Context item 3, the `review-plan` → `skein:grill` Codex-only annotation) against the **Claude** mirror's actual `review-plan` → `skein:grill` mechanism before finalizing the Claude-side chaining map — the two mirrors may legitimately differ here.
- Update this plan's Context section with the confirmed chaining-map and chaining-survival/context-load results before starting Phase 1 — the Codex-support hedge is already resolved (item 3 above) and must not be re-litigated.

### Phase 1: Classify all 13 skills

**Impl files:** none (produces a decision table added to this plan)
**Test files:** none
**Test command:** n/a

- For each of the 13 skills, decide `model-invoked` (stays as-is) or `user-invoked` (`disable-model-invocation: true`) by checking **both** axes from Context: Axis 1 (does Phase 0's chaining map show any skill invoking this one by `/name`/`skein:name`? If yes → hard-stays model-invoked, no further test needed) and Axis 2 (does this skill's own `description` carry a content/keyword trigger — an RFC mention, a "draft/review this" intent phrase — that plausibly fires independent of chaining? If yes → stays model-invoked; if genuinely no such trigger exists → candidate for user-invoked).
- A skill is only a real user-invoked candidate if it clears **both** axes: nothing chains into it, AND its own description has no independent content-based trigger likely to fire in normal use.
- Record the table (skill, classification, Axis-1 reason, Axis-2 reason) in this plan before touching any SKILL.md. Each reason must cite either a concrete chaining-map edge (or its absence) or an actual quoted phrase from the skill's own `description:` — not a restatement of "narrow scope = safe."

### Phase 2: Apply front-matter changes to both mirrors

**Impl files:** `plugins/skein/skills/<skill>/SKILL.md` for each skill classified user-invoked in Phase 1 (`disable-model-invocation: true` is Claude-only — Codex has no equivalent field, confirmed by Phase 0's research pass); `plugins/skein-codex/skills/<skill>/SKILL.md` for the same skills gets a one-line comment documenting the permanent divergence instead
**Test files:** none — `scripts/check-prompt-parity.sh` does not inspect SKILL.md front-matter (confirmed: it checks `rubric.md`/`*-prompt.md`/schema-block parity only), so it cannot serve as this phase's verification
**Test command:** `rg -n 'disable-model-invocation' plugins/skein/skills/<skill>/SKILL.md plugins/skein-codex/skills/<skill>/SKILL.md` per edited skill, to directly confirm front-matter state on both mirrors matches Phase 1's decision (or the documented Codex divergence)

- Add `disable-model-invocation: true` to each user-invoked skill's Claude SKILL.md front-matter. Per writing-great-skills' mechanics note, trim the `description:` to a human-facing one-liner once it no longer needs to carry autonomous-trigger phrasing (the trigger-phrase clauses like "Use when the user says…" become dead weight once the harness can't act on them autonomously) — but keep this trim conservative: only strip clauses that exclusively serve autonomous triggering, not identity or usage-hint content a human skimming the skill list still needs. Print a before/after diff of each trimmed `description:` for review — confirm it still reads as a standalone human-facing line.
- Do **not** add `disable-model-invocation` (or any invented equivalent) to the Codex mirror — Phase 0 confirmed no such field exists there, and Codex CLI autonomously matches descriptions with no opt-out. Instead, add a one-line comment to each affected Codex `SKILL.md` documenting that this skill is user-invoked-only on Claude but remains autonomously invocable on Codex as a harness limitation, not an oversight.
- Note that `scripts/check-prompt-parity.sh`'s `MANAGED_SKILLS` default currently lists only 12 skills (omits `review-gauntlet`) — since `review-gauntlet` is excluded from disabling (Axis 1, Context), this gap doesn't block this plan, but record it as a known tooling gap rather than silently ignoring it.
- Run the existing parity check script(s) to confirm no unrelated drift was introduced to `rubric.md`/`*-prompt.md` (its actual scope) — this is a supplementary check, not the front-matter verification (that's the `rg` command above).

### Phase 3: Update docs

**Impl files:** `docs/skills_architecture/20260522-design-claude-skills-architecture.md` (add a row or note on invocation mode per skill, alongside the existing model/reasoning routing table), this plan's own Status field
**Test files:** none
**Test command:** n/a

- Add an "Invocation Mode" column or short section to the skills architecture doc so future skill additions inherit the classification discipline instead of defaulting to model-invoked by habit.
- Flip this plan's Status to Complete and add the PR link once merged, per the repo's existing dev-plan convention.

## Acceptance Criteria

- The inbound-chaining map (Phase 0) enumerates every `/name`/`skein:name` reference across both mirrors and is recorded in this plan before Phase 1 runs.
- Phase 0's chaining-survival and context-load-reduction questions have concrete, evidenced answers recorded in this plan. Codex support is already resolved (confirmed unsupported, with autonomous firing confirmed present regardless — see Context item 3) and must not be re-opened as pending.
- Every one of the 13 skills has an explicit classification addressing both Axis 1 (chaining) and Axis 2 (independent content-trigger), with a stated reason for each — not a restatement of a pre-narrowed candidate list.
- No skill relied upon for autonomous cross-skill chaining (confirmed via the Phase 0 map — this explicitly includes `review-gauntlet`, chained into by `conduct`/`fan-out`) is marked user-invoked.
- Claude mirror gets `disable-model-invocation: true` on each user-invoked skill; the Codex mirror gets a documented-divergence comment on the same skills (never a fabricated Codex field) — this is the expected, permanent shape of "both mirrors reflect the decision" for this plan.
- Phase 2's front-matter change is verified by direct `rg` diff per skill (not by `scripts/check-prompt-parity.sh`, which doesn't cover front-matter).
- The skills architecture doc reflects the new classification so it doesn't silently rot on the next skill addition.

<!-- reviewed: 2026-07-12 @ d932bfa7eb9e96a6fcc1302f6a833e1cc0a93e3f -->

## Progress

## Findings
