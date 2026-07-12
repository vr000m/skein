# Task: Skill Invocation-Mode Audit — model-invoked vs. user-invoked classification

**Status**: Complete
**Component**: meta
**Assigned to**: Claude
**Priority**: Low
**Branch**: chore/skill-invocation-mode-audit
**Created**: 2026-07-11
**Completed**: 2026-07-12 (PR link pending — add once merged)

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
3. **Does the Codex CLI harness even read a `disable-model-invocation`-equivalent field? — Resolved by a Codex-side research pass (codex-rescue), 2026-07-12, to the limits of what's discoverable.** No documented or discoverable opt-out as of Codex CLI 0.144.1: Codex's own skill docs (`https://learn.chatgpt.com/docs/build-skills`) specify only `name` and `description` in `SKILL.md` front-matter, and a string search of the local Codex CLI binary (0.144.1) found no matching field or source string — evidence against the field existing, not proof it can't. Codex's own docs (`https://learn.chatgpt.com/docs/customization/overview`) describe Codex CLI as having autonomous natural-language skill selection; we assume this is analogous to Claude Code's model-invoked skills, though the two mechanisms haven't been directly compared — so this is not a case where the whole distinction is moot on Codex; it's a case where Codex plausibly has the same problem (autonomous firing pays context load) but **no documented opt-out**. Consequence for Phase 2: `disable-model-invocation: true` is a **Claude-only** front-matter addition. The Codex mirror cannot be given a documented equivalent — every skill classified user-invoked under the Claude axis stays autonomously invocable on the Codex side regardless, and Phase 2 must record this as a **permanent, harness-imposed divergence** (not a documented-but-symmetric choice, and not "unresolved") in each edited skill's Codex `SKILL.md`, e.g. a one-line comment noting Codex has no documented equivalent suppression mechanism as of this writing.
   - **Chaining-map correction from the same research pass**: `plugins/skein-codex/skills/review-plan/SKILL.md:529` explicitly annotates its `skein:grill` reference as "not a skill activation" — exclude that specific edge from the Codex-side chaining map. This is a Codex-mirror implementation detail (grill's logic may be inlined differently there); it does not by itself tell us whether the Claude-side `review-plan` → `skein:grill` delegation (AGENTS.md's Skill Workflow step 2: "delegated inline to `skein:grill`") is a real Axis-1 edge on the Claude mirror — Phase 0's chaining-map task (below) must check the Claude mirror's actual invocation mechanism independently, not assume the Codex annotation transfers.
   - `conduct`/`fan-out` → `review-gauntlet` is confirmed as a genuine dependency on both mirrors (`review-gauntlet/SKILL.md:25` calls it an "auto-chain" caller) — reinforces this plan's existing exclusion of `review-gauntlet` from disable candidacy.

4. **Phase 0 findings — chaining map, chaining-survival test, context-load test. Recorded 2026-07-12.**

   **Inbound-chaining map (manually verified, not just grepped).** A raw `rg` pass over both mirrors for `/name`/`skein:name`/bare-backticked-name references produced ~30 hits per mirror, but most were descriptive cross-references (shared file-format or workflow mentions), not real skill activations. Reading each hit's source context narrowed this to the **real** Axis-1 edges below — cases where a skill's own procedure autonomously/programmatically invokes another named skill as a mandatory step, not merely suggests it to the user:

   | Caller | Callee | Mechanism | Evidence |
   |---|---|---|---|
   | `conduct` | `review-gauntlet` | Auto-chain at terminal seam (opt-in via plan's `**Review Gates:**` field) | `plugins/skein/skills/conduct/SKILL.md:359-375`; codex mirror `SKILL.md:341-356` |
   | `fan-out` | `review-gauntlet` | Same auto-chain mechanism, post-merge | `plugins/skein/skills/fan-out/SKILL.md:235-247`; codex mirror `SKILL.md:231-243` |
   | `review-gauntlet` | `deep-review` | Invokes `skein:deep-review` directly at its own top level (also `/code-review`, `/security-review`, both built-in commands, not skein skills) | `plugins/skein/skills/review-gauntlet/SKILL.md:83-98`; codex mirror `SKILL.md:83-104` |
   | `review-plan` | `dev-plan` | Step 6.4's routing loop calls `/dev-plan update` as a mandatory action for every acted-on finding | `plugins/skein/skills/review-plan/SKILL.md:533,536,543` (both mirrors, equivalent lines) |
   | `grill` | `dev-plan` | Standalone-invocation Step 4 calls `/dev-plan update` to persist accept/override outcomes | `plugins/skein/skills/grill/SKILL.md:84`; codex mirror `SKILL.md:82` |

   **Probable-hard edge, not fully confirmed:** `fan-out` → `conduct` — `fan-out/SKILL.md:15`: "A fan-out-spawned Claude subprocess may invoke `/conduct` as its top-level skill." This is a scripted subprocess boundary (`fan-out.sh`), not literal same-session prose, so it wasn't verified with the same rigor as the table above — flagged for Phase 1 to treat as hard unless it can positively rule this out.

   **Soft/suggested edges** — the caller *offers* the callee as a next-step option to the user rather than autonomously executing it; since firing only happens after the user accepts (a user-initiated invocation at that point), these do **not** create a hard Axis-1 dependency:
   - `content-draft` → `content-review`: Phase 6 "Offer Next Steps" menu, option 2 ("Run /content-review") — `content-draft/SKILL.md:158`.
   - `spec-compliance` → `rfc-finder`: error-recovery suggestion ("Offer to use `rfc-finder`") — `spec-compliance/SKILL.md:175` (Claude) / `:171` (Codex).

   **Corrected: `review-plan` → `grill` is NOT a real Axis-1 edge.** Both mirrors explicitly annotate this reference as non-activation. Claude mirror, `review-plan/SKILL.md:530`: "This is an inline prose reference, not a skill activation and not a subagent spawn... § Interview Mechanics is the sole authoritative definition of that pacing/recommendation/outcome protocol; it is not restated here." This matches the Codex mirror's `SKILL.md:529` annotation. **The Phase 0 cross-check task is resolved — the two mirrors do not diverge here.** Both treat grill's SKILL.md as a shared prose module read inline in the same session, not a true skill-to-skill activation. This clears `grill` on Axis 1 (Axis 2 still pending, Phase 1).

   **Corrected: the plan's own worked example was wrong.** This plan originally cited `plan-view` as "chained into by `dev-plan`/`update-docs`" as the subject for the chaining-survival test. That doesn't hold: every `dev-plan`/`update-docs` reference to `plan-view` (`dev-plan/SKILL.md:57,191`; `update-docs/SKILL.md:88,105`) describes shared grouping/rendering behavior (component grouping keys, Mermaid rendering) — none invoke `/plan-view` as a skill activation. `plan-view` has **zero** real inbound Axis-1 edges on either mirror. The chaining-survival test below was run against `dev-plan` instead (a confirmed real callee via `review-plan`/`grill` above).

   **`deep-review`'s "spec compliance" is an inline lens, not a call to the standalone `spec-compliance` skill**, on both mirrors — each has its own self-contained lens prompt (`deep-review/SKILL.md:264-291` Claude; lens table `SKILL.md:92-97` Codex). The standalone `spec-compliance` skill therefore has **zero** real inbound Axis-1 edges on either mirror.

   **Chained-into (hard Axis-1 exclusion, must stay model-invoked):** `review-gauntlet`, `deep-review`, `dev-plan`, and (unconfirmed-but-probable) `conduct`. `review-plan` was already excluded on separate grounds (its marker is the readiness gate every `conduct`/`fan-out` run depends on) and is independently confirmed here as itself a caller into `dev-plan`.

   **Chaining-survival test (Axis 1).** Run in a throwaway worktree (`/tmp/conduct-phase0-scratch`, branch `scratch/phase0-chaining-test`, both deleted after observation — the main working tree was never touched). Set `disable-model-invocation: true` on `dev-plan`'s Claude `SKILL.md` (substituting for the plan's incorrect `plan-view` suggestion, corrected above). A live empirical fire was **not attempted** — see "Why this can't be empirically fired" below — findings instead come from official Claude Code documentation, retrieved via the `claude-code-guide` agent:
   - **(a) Explicit `/dev-plan` still works** — confirmed by docs: "You can invoke the skill directly by typing `/skill-name` and it executes fully," regardless of `disable-model-invocation`.
   - **(b) No longer offered for autonomous NL firing** — confirmed by docs: the skill is excluded from what Claude can autonomously select (frontmatter table: "Claude can invoke: No").
   - **(c) Whether literal `/dev-plan update` text inside `review-plan`'s/`grill`'s own prose still succeeds once `dev-plan` is disabled — likely NO, but this is a high-confidence inference from documentation, not an empirical observation.** Line 42 set the bar at "needs empirical confirmation" for this exact question; that bar was not cleared. The only source is a general sentence about *default autonomous invocation* — "By default, Claude can invoke any skill that doesn't have `disable-model-invocation: true` set" — which does not specifically address the case of literal `/name` text embedded in another skill's own prose instructions. Treat (c) as the plan's working assumption, not a confirmed mechanism, until empirically verified.

   **This is Phase 0's single most important open question, and it stays open — no later phase closes it.** If (c) is correct, every hard Axis-1 edge in the table above would genuinely break if its callee were marked user-invoked. But the confidence here rests on doc-inference, not observation, and no empirical gate was ever built to verify it (Phase 2 disabled only `plan-view`, which has zero hard Axis-1 inbound edges, so (c) was never exercised in practice). This is why `review-gauntlet`, `deep-review`, `dev-plan` (and probably `conduct`) must stay model-invoked: the conservative reading of an unverified assumption, not a confirmed mechanism. Any future plan proposing to disable a *chained-into* skill must empirically verify (c) first — it cannot inherit this plan's untested assumption.

   **Why this can't be empirically fired from within this session** (both reasons independently confirmed, not merely asserted):
   1. **This session's live skill instance loads from the installed plugin cache, not this repo.** `conduct`'s own invocation header states its base directory as `/Users/vr000m/.claude/plugins/cache/skein/skein/0.4.1/skills/conduct`; that cache's `plugin.json` reports `"version": "0.4.1"`, while this repo's `plugins/skein/.claude-plugin/plugin.json` is at `"version": "0.5.0"` — the two have already diverged. The cache only updates on a release/reinstall cycle, so editing `plugins/skein/skills/*/SKILL.md` in this repo — on a real branch, not just the scratch worktree used here — has **zero live effect** on the currently-running session.
   2. Spinning up a second, nested live Claude Code session to empirically observe autonomous-firing behavior is outside this session's tool surface, and would in any case require pointing a fresh install at a mutated plugin cache — risking the shared cache this very run depends on.

   **Context-load test.** Confirmed via the `claude-code-guide` agent against official docs (`https://code.claude.com/docs/en/skills.md`, "Control who invokes a skill" section, frontmatter reference table): `disable-model-invocation: true` **does** remove the skill's `description` from per-turn context — the docs state the description is "not in context" when set, versus "Description always in context" by default. This is the plan's core cost-justification premise, and **it holds**: disabling a skill genuinely reduces per-turn token load, not merely gates autonomous firing. Confidence: high — directly stated in official documentation, not inferred from indirect behavior.

   **Codex support** — already resolved in Context item 3, not re-opened here.

## Review Focus

- Verify Phase 0's chaining test is run against a skill that is *actually* chained into by another skill's prose (e.g. `fan-out` or `plan-view`), not a skill nothing chains into — a passing test against an untouched skill proves nothing about chaining survival.
- Verify Phase 0 separately confirms the context-load-reduction premise itself (not only that autonomous firing stops), since that's the plan's entire cost justification.
- Verify the final classification table's reasoning per skill is concrete and addresses **both** axes explicitly (cites a real chaining edge for Axis 1, and a real description trigger phrase — or its absence — for Axis 2), not a restatement of a pre-narrowed candidate list.
- Verify Codex-mirror handling is explicit for every skill: either the equivalent field is applied, or its absence/inapplicability is stated with a reason — no skill silently skipped.
- Verify no skill that other skills chain into (`review-plan`, `deep-review`, `review-gauntlet`, `security-review` if present, and any skill referenced by literal `/name` or `skein:name` text elsewhere in the plugin) is marked `disable-model-invocation`.
- Verify the chaining-inventory step (Phase 0) actually enumerates every inbound `/name`/`skein:name` reference across both mirrors before Phase 1 classifies anything — not reconstructed ad hoc per skill.
- Confirm `scripts/check-prompt-parity.sh` does not currently inspect SKILL.md front-matter (it checks `rubric.md`/`*-prompt.md`/schema-block parity only) and that Phase 2's actual verification step is a direct front-matter diff, not a claim that this script covers it. Also confirm whether `scripts/check-prompt-parity.sh`'s `MANAGED_SKILLS` default (currently 12 skills) is reconciled with the real 13-skill set or the gap is explicitly documented.

5. **Phase 1 findings — classification of all 13 skills. Recorded 2026-07-12.**

   Calibration bar for Axis 2 (per Context item 4's gold-standard example): does the skill's own `Use when...` clause describe genuine user intent that plausibly arises in normal conversation *independent of already knowing the skill/command name* — the way `rfc-finder`'s "RFC", "IETF", "WebRTC", "QUIC" keywords do — or is the trigger phrase itself command-name-adjacent (only said by someone who already knows the specific tool exists)?

   | Skill | Classification | Axis 1 (chaining) | Axis 2 (content trigger) |
   |---|---|---|---|
   | `conduct` | **model-invoked** | Hard-excluded — probable callee of `fan-out` ("fan-out-spawned Claude subprocess may invoke `/conduct` as its top-level skill", `fan-out/SKILL.md:15`) | not evaluated (Axis 1 alone decides) |
   | `dev-plan` | **model-invoked** | Hard-excluded — confirmed callee of `review-plan` (Step 6.4's `/dev-plan update` calls) and `grill` (standalone Step 4's `/dev-plan update` calls) | not evaluated |
   | `review-plan` | **model-invoked** | Hard-excluded — `conduct`'s marker precondition depends on it; independently confirmed as a caller into `dev-plan` | not evaluated |
   | `review-gauntlet` | **model-invoked** | Hard-excluded — confirmed callee of `conduct` and `fan-out` (auto-chain at terminal seam) | not evaluated |
   | `deep-review` | **model-invoked** | Hard-excluded — confirmed callee of `review-gauntlet` (`skein:deep-review` invoked directly at its own top level) | not evaluated |
   | `content-draft` | **model-invoked** | Clear — zero inbound edges found on either mirror | Fires: `"write up what we just did"`, `"summarise this session as a TIL"` describe genuine session-recap intent a user expresses without naming the skill |
   | `content-review` | **model-invoked** | Clear (Axis 1) — only a soft/suggested inbound edge from `content-draft`'s own next-step menu, not a hard dependency | Fires: `"proofread my content"`, `"check my TIL"` are natural asks independent of skill awareness |
   | `fan-out` | **model-invoked** | Clear — no skill invokes it as a hard dependency (all references are descriptive workflow guidance, e.g. `dev-plan/SKILL.md:91`, `review-plan/SKILL.md:37`) | Fires: `"parallelize this"` is a plausible spontaneous phrase from a technical user unaware of the specific skill name |
   | `grill` | **model-invoked** | Clear — `review-plan`'s reference is explicitly annotated "not a skill activation" on both mirrors (Context item 4); no other inbound edges | Fires: `"stress-test this plan"`, `"interview me on this design"` are natural technical idioms |
   | `rfc-finder` | **model-invoked** | Clear (Axis 1) — only a soft/suggested inbound edge from `spec-compliance`'s error-recovery path, not a hard dependency | Fires strongly (gold-standard case): protocol/RFC keywords ("RFC", "IETF", "WebRTC", "QUIC", etc.) arise routinely in technical conversation with zero skill awareness required |
   | `spec-compliance` | **model-invoked** | Clear — `deep-review`'s "spec compliance" is its own inline lens, not a call to this skill, on both mirrors; zero real inbound edges | Fires strongly: `"does this implement RFC X"`, `"check against W3C"` are natural compliance-review asks, same character as `rfc-finder`'s trigger |
   | `update-docs` | **model-invoked** | Clear — `dev-plan`/`plan-view` references are descriptive (component-grouping key), not invocations | Fires: `"update docs"` is a common developer phrase, plus a situational timing trigger ("after finishing implementation work, before creating or merging a PR") worth keeping autonomous |
   | `plan-view` | **user-invoked** (`disable-model-invocation: true`) | Clear — corrected from this plan's own wrong worked example; `dev-plan`/`update-docs` references are descriptive (grouping/rendering behavior only), not invocations; zero real inbound edges on either mirror | Does not fire: `"render dev plans"`, `"render plan dashboard"`, `"asks for a visual index of dev_plans/"` are command-name-adjacent phrasing — a user who says this already knows a specific reporting tool exists, unlike the natural-intent triggers above |

   **Result: 1 of 13 skills clears both axes** — `plan-view`. This is a smaller yield than the plan's original (retracted) 5-skill candidate list, because rigorous per-skill Axis 2 reasoning shows most of skein's skills already carry genuine natural-language intent triggers in their descriptions (that's how their authors wrote them), not just a bare `/name` fallback. `fan-out`, `rfc-finder`, and `spec-compliance` — all on the original candidate list — are cleared on Axis 1 but held to model-invoked by Axis 2: `rfc-finder`/`spec-compliance` are the plan's own gold-standard case for a content-trigger that must survive, and `fan-out`'s "parallelize this" is judged to plausibly fire independent of skill awareness.

## Implementation Checklist

### Phase 0: Build the chaining map, then verify the three open questions before classifying anything

**Impl files:** none (research phase — findings recorded in this plan's Context/Requirements)
**Test files:** none
**Test command:** n/a

- **Build the inbound-chaining map first.** Grep every `plugins/skein/skills/*/SKILL.md` and `plugins/skein-codex/skills/*/SKILL.md` body for literal `/name` or `skein:name` references to other skills (e.g. `rg -n '(/|skein:)(conduct|content-draft|content-review|deep-review|dev-plan|fan-out|grill|plan-view|review-gauntlet|review-plan|rfc-finder|spec-compliance|update-docs)\b' plugins/*/skills/*/SKILL.md`). Record the resulting edge list (caller → callee) in this plan's Context section. This is the Axis 1 input for Phase 1. **Corrected (2026-07-12, per recorded findings):** the seed edge list below was wrong on two counts — `dev-plan`/`update-docs` → `plan-view` is not a real edge (Context item 4 confirms `plan-view` has zero real inbound Axis-1 edges on either mirror; the `dev-plan`/`update-docs` references describe shared grouping/rendering behavior, not skill activation), and the claimed `conduct`/`dev-plan`/`review-plan`/`review-gauntlet` → `fan-out` edges do not appear in the verified chaining table (Context item 4) either — every inbound `/fan-out` reference found (`dev-plan/SKILL.md:58,91,198`, `review-plan/SKILL.md:37`, `conduct/SKILL.md:34,487`) is a soft, user-facing suggestion, not a hard autonomous invocation, so `fan-out` clears Axis 1. The real known edges are: `conduct`/`fan-out` → `review-gauntlet`, `review-gauntlet` → `/code-review`/`skein:deep-review`/`/security-review`, `review-plan` → `dev-plan`, and `grill` → `dev-plan`.
- **Chaining-survival test (Axis 1).** Pick a skill that the map above shows *is* chained into (e.g. `dev-plan`, since `review-plan`/`grill` invoke it via `/dev-plan update`) — not an untouched skill — and in a throwaway branch or worktree distinct from `chore/skill-invocation-mode-audit`, set `disable-model-invocation: true` on it. Confirm: (a) explicit `/dev-plan` still works, (b) it no longer appears available for autonomous natural-language firing, (c) whether the literal `/dev-plan update`-style text inside `review-plan`'s/`grill`'s own SKILL.md prose still successfully invokes it. Revert the scratch change after observing the result — it is not this phase's real edit.
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

- Add `disable-model-invocation: true` to each user-invoked skill's Claude SKILL.md front-matter. Do **not** trim the `description:` field — Phase 0's own context-load finding (line 85) already established that the flag alone removes `description` from per-turn context, so a trim buys zero additional context-load savings while adding an ungated content divergence against the Codex mirror (which must keep its full trigger-phrase description) and degrading human skim-discoverability in the `/`-menu, the one path by which a user-invoked skill is still reached. Leave the description text untouched; the flag is the only change.
- Do **not** add `disable-model-invocation` (or any invented equivalent) to the Codex mirror — Phase 0 confirmed no such field exists there, and Codex CLI autonomously matches descriptions with no opt-out. Instead, add a one-line comment to each affected Codex `SKILL.md` documenting that this skill is user-invoked-only on Claude but remains autonomously invocable on Codex as a harness limitation, not an oversight. Place it as a human-visible HTML comment in the file body (immediately after the front-matter close, before the first heading) — this comment is the only artifact recording the divergence on the Codex side, so it must not be buried inside the front-matter YAML where a re-serializer or a quick skim would miss it.
- Note that `scripts/check-prompt-parity.sh`'s `MANAGED_SKILLS` default currently lists only 12 skills (omits `review-gauntlet`) — since `review-gauntlet` is excluded from disabling (Axis 1, Context), this gap doesn't block this plan, but record it as a known tooling gap rather than silently ignoring it.
- Run the existing parity check script(s) to confirm no unrelated drift was introduced to `rubric.md`/`*-prompt.md` (its actual scope) — this is a supplementary check, not the front-matter verification (that's the `rg` command above).

### Phase 3: Update docs

**Impl files:** `docs/skills_architecture/20260522-design-claude-skills-architecture.md` (add a row or note on invocation mode per skill, alongside the existing model/reasoning routing table), this plan's own Status field
**Test files:** none
**Test command:** n/a

- Add an "Invocation Mode" column or short section to the skills architecture doc so future skill additions inherit the classification discipline instead of defaulting to model-invoked by habit.
- Flip this plan's Status to Complete and add the PR link once merged, per the repo's existing dev-plan convention.

## Acceptance Criteria

- The inbound-chaining map (Phase 0) enumerates every **hard** `/name`/`skein:name` chaining edge across both mirrors (the raw ~30-hits-per-mirror grep pass is dismissed in bulk as descriptive cross-references — see Context item 4 — rather than itemized one by one) and is recorded in this plan before Phase 1 runs.
- Phase 0's chaining-survival and context-load-reduction questions have concrete, evidenced answers recorded in this plan. Codex support is already resolved (confirmed unsupported, with autonomous firing confirmed present regardless — see Context item 3) and must not be re-opened as pending.
- Every one of the 13 skills has an explicit classification addressing both Axis 1 (chaining) and Axis 2 (independent content-trigger), with a stated reason for each — not a restatement of a pre-narrowed candidate list.
- No skill relied upon for autonomous cross-skill chaining (confirmed via the Phase 0 map — this explicitly includes `review-gauntlet`, chained into by `conduct`/`fan-out`) is marked user-invoked.
- Claude mirror gets `disable-model-invocation: true` on each user-invoked skill; the Codex mirror gets a documented-divergence comment on the same skills (never a fabricated Codex field) — this is the expected, permanent shape of "both mirrors reflect the decision" for this plan.
- Phase 2's front-matter change is verified by direct `rg` diff per skill (not by `scripts/check-prompt-parity.sh`, which doesn't cover front-matter).
- The skills architecture doc reflects the new classification so it doesn't silently rot on the next skill addition.

<!-- reviewed: 2026-07-12 @ 613def3dcf3a6d16d450374c19752ede75aade4f -->

## Progress

- [x] Phase 0: Build the chaining map, then verify the three open questions before classifying anything
- [x] Phase 1: Classify all 13 skills
- [x] Phase 2: Apply front-matter changes to both mirrors
- [x] Phase 3: Update docs

## Findings

### Phase 3 (2026-07-12)

Updated `docs/skills_architecture/20260522-design-claude-skills-architecture.md`:
- Added an **Invocation Mode** column to the Skill Catalogue table, and added the two skills missing from that table entirely (`grill`, `review-gauntlet`) — the catalogue was stale at 11 rows for a 13-skill plugin before this edit, which would have undermined this plan's own goal of "future skill additions inherit the classification discipline."
- Added a new **## Invocation Mode** section (after Trigger Phrases, before Failure Modes) documenting the mechanism, the two-axis classification discipline for new skills, and today's result (1 of 13 disabled).
- Flipped this plan's Status to Complete, set Completed to 2026-07-12; PR link left as a placeholder pending merge.

**Open item flagged, now resolved (2026-07-12 post-merge correction, commit 33f076f):** Context item 4 (line 79) originally forward-referenced "Phase 2 (below) adds a concrete gate to close this gap before disabling further skills" — but Phase 2, as actually executed, applied `disable-model-invocation: true` to `plan-view` and did not add any empirical verification gate. That sentence has since been rewritten in place: Context item 4 now states plainly that the (c) question stays open, no later phase closes it, and any future plan proposing to disable a *chained-into* skill must empirically verify (c) itself rather than inherit this plan's untested assumption. This doesn't affect the current scope (`plan-view` has zero confirmed hard Axis-1 inbound edges, so (c) was never exercised in practice) — it only removes a stale promise that no longer matched what Phase 2 actually did.

### Phase 0 (2026-07-12)

Research phase, no code changes. Full findings recorded in Context item 4 above (per this phase's own instruction — findings belong in Context/Requirements, not here). Summary: verified inbound-chaining map is much smaller than the raw grep suggested (5 confirmed hard edges + 1 probable + 2 soft, out of ~30 raw hits); corrected two errors in the plan's own drafting (`plan-view` isn't actually chained into by anyone; `review-plan`→`grill` is explicitly not a skill activation on either mirror); confirmed via official docs that `disable-model-invocation` removes per-turn context load (this part is doc-confirmed fact). Separately, and with lower confidence, the same docs were read as implying `disable-model-invocation` blocks all Claude-initiated invocation paths, not just autonomous NL firing — meaning literal-text chaining edges would break like autonomous ones (item (c) above). That second claim is a high-confidence *inference*, not an observed result: no chained-into skill was ever actually disabled to test it, and Phase 2's real edit (`plan-view`, zero hard inbound edges) never exercised it either. Treat context-load removal as confirmed and literal-text chaining-break as an unverified working assumption — see item (c), lines 77–79. Empirical live-fire testing was ruled out with evidence (this session's plugin loads from an installed cache pinned at v0.4.1, decoupled from this repo's v0.5.0).

### Phase 1 (2026-07-12)

Research/decision phase, no code changes. Full classification table recorded in Context item 5 above. Summary: only 1 of 13 skills (`plan-view`) clears both axes for `disable-model-invocation`. `conduct`, `dev-plan`, `review-plan`, `review-gauntlet`, `deep-review` are hard-excluded on Axis 1. The remaining 7 (`content-draft`, `content-review`, `fan-out`, `grill`, `rfc-finder`, `spec-compliance`, `update-docs`) clear Axis 1 but are held to model-invoked by genuine Axis 2 content triggers, judged against the plan's own `rfc-finder` gold-standard calibration. This is a smaller yield than the plan's originally retracted 5-skill candidate list — a rigorous per-skill pass finds most of skein's skill descriptions already carry natural-language intent triggers, not just a bare command fallback.

### Phase 2 (2026-07-12)

Applied front-matter changes to both mirrors for the single user-invoked skill (`plan-view`):
- **Claude** (`plugins/skein/skills/plan-view/SKILL.md`): added `disable-model-invocation: true`. **Correction (2026-07-12, `/review-plan` finding):** an earlier pass of this phase also trimmed the trailing `Use when the user says…` clause from `description:`, reasoning it was now-dead autonomous-trigger phrasing. Review caught that this was scope creep with no payoff: Phase 0's own context-load finding (line 85) already shows the flag alone removes `description` from per-turn context, so the trim saved nothing while creating an ungated Claude/Codex description-content divergence and degrading `/`-menu skim-discoverability. The trim was reverted; `description:` is now byte-identical to its pre-Phase-2 text, and `disable-model-invocation: true` is the only change on the Claude mirror.
- **Codex** (`plugins/skein-codex/skills/plan-view/SKILL.md`): no front-matter field added (none exists); added a one-line HTML comment documenting the permanent divergence, pointing back to this plan. Description left untouched — Codex still needs the trigger phrasing since it has no suppression mechanism.
- Verified via `rg -n 'disable-model-invocation' plugins/skein/skills/plan-view/SKILL.md plugins/skein-codex/skills/plan-view/SKILL.md`: Claude mirror shows the field, Codex mirror shows the divergence comment (not the field) — see command output above.
- Ran `scripts/check-prompt-parity.sh` as a supplementary check (not the front-matter verification): passed, no unrelated drift.
- Confirmed the known tooling gap noted in Review Focus: `scripts/check-prompt-parity.sh`'s `MANAGED_SKILLS` default lists exactly 12 skills, omitting `review-gauntlet` (`conduct content-draft content-review deep-review dev-plan fan-out grill plan-view review-plan rfc-finder spec-compliance update-docs`). Since `review-gauntlet` is excluded from disabling (Axis 1), this doesn't block this plan — recorded here per the plan's own instruction, not silently ignored.
