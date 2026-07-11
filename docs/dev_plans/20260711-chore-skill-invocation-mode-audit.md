# Task: Skill Invocation-Mode Audit — model-invoked vs. user-invoked classification

**Status**: Not Started
**Component**: meta
**Assigned to**: Claude
**Priority**: Low
**Branch**: chore/skill-invocation-mode-audit
**Created**: 2026-07-11
**Completed**: (pending)

## Objective

Classify each of skein's 13 skills as **command-only** (invoked exclusively via explicit `/skill-name`, never by natural language) or **natural-language-triggered** (a user plausibly reaches it by describing intent, or another skill relies on the harness auto-selecting it), and mark the command-only ones `disable-model-invocation: true` so their `description:` front-matter stops contributing to per-turn context load. Applies to both `plugins/skein/skills/*/SKILL.md` (Claude) and `plugins/skein-codex/skills/*/SKILL.md` (Codex), if the Codex harness supports an equivalent mechanism (open question — see Phase 0).

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
3. **Does the Codex CLI harness even read a `disable-model-invocation`-equivalent field?** This key has zero occurrences in either mirror today (confirmed via repo-wide grep). skein's Codex mirror already diverges from Claude on other harness-specific mechanics (`$SKILL_DIR` vs `${CLAUDE_PLUGIN_ROOT}`, per prior memory `feedback_harness_divergent_path_anchors`) — front-matter support is not guaranteed to be identical. If Codex has no equivalent, the two mirrors will *intentionally* diverge on this front-matter key, which must be documented as a deliberate difference, not treated as parity drift. If Codex support cannot be evidenced either way, record it as "unresolved, treated as unsupported by default" — that counts as satisfying the acceptance criterion; it does not block Phase 1.

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
- Grep the Codex CLI's own skill-loading documentation/source (or ask via the `claude-code-guide`/Codex-equivalent research path) for whether a front-matter key suppresses autonomous invocation the same way. Record the answer (supported / not supported / no equivalent concept) plainly; if genuinely unresolvable, record "unresolved, treated as unsupported by default" — that satisfies the acceptance criterion.
- Update this plan's Context section with the confirmed answers (chaining map, chaining-survival result, context-load result, Codex-support result) before starting Phase 1 — do not carry the "ambiguous, unverified" hedge into the classification phase.

### Phase 1: Classify all 13 skills

**Impl files:** none (produces a decision table added to this plan)
**Test files:** none
**Test command:** n/a

- For each of the 13 skills, decide `model-invoked` (stays as-is) or `user-invoked` (`disable-model-invocation: true`) by checking **both** axes from Context: Axis 1 (does Phase 0's chaining map show any skill invoking this one by `/name`/`skein:name`? If yes → hard-stays model-invoked, no further test needed) and Axis 2 (does this skill's own `description` carry a content/keyword trigger — an RFC mention, a "draft/review this" intent phrase — that plausibly fires independent of chaining? If yes → stays model-invoked; if genuinely no such trigger exists → candidate for user-invoked).
- A skill is only a real user-invoked candidate if it clears **both** axes: nothing chains into it, AND its own description has no independent content-based trigger likely to fire in normal use.
- Record the table (skill, classification, Axis-1 reason, Axis-2 reason) in this plan before touching any SKILL.md. Each reason must cite either a concrete chaining-map edge (or its absence) or an actual quoted phrase from the skill's own `description:` — not a restatement of "narrow scope = safe."

### Phase 2: Apply front-matter changes to both mirrors

**Impl files:** `plugins/skein/skills/<skill>/SKILL.md` and `plugins/skein-codex/skills/<skill>/SKILL.md` for each skill classified user-invoked in Phase 1 (subject to Phase 0's Codex-support finding)
**Test files:** none — `scripts/check-prompt-parity.sh` does not inspect SKILL.md front-matter (confirmed: it checks `rubric.md`/`*-prompt.md`/schema-block parity only), so it cannot serve as this phase's verification
**Test command:** `rg -n 'disable-model-invocation' plugins/skein/skills/<skill>/SKILL.md plugins/skein-codex/skills/<skill>/SKILL.md` per edited skill, to directly confirm front-matter state on both mirrors matches Phase 1's decision (or the documented Codex divergence)

- Add `disable-model-invocation: true` to each user-invoked skill's Claude SKILL.md front-matter. Per writing-great-skills' mechanics note, trim the `description:` to a human-facing one-liner once it no longer needs to carry autonomous-trigger phrasing (the trigger-phrase clauses like "Use when the user says…" become dead weight once the harness can't act on them autonomously) — but keep this trim conservative: only strip clauses that exclusively serve autonomous triggering, not identity or usage-hint content a human skimming the skill list still needs. Print a before/after diff of each trimmed `description:` for review — confirm it still reads as a standalone human-facing line.
- Apply the equivalent to the Codex mirror if Phase 0 found support; otherwise, add a one-line comment or plan note explaining the intentional divergence (do not fabricate a Codex field that doesn't exist).
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
- Phase 0's three open questions (chaining survival on an actually-chained skill, whether context load genuinely drops, Codex support) have concrete, evidenced answers recorded in this plan — a genuinely unresolvable one may be recorded as "unresolved, treated as unsupported by default," but not silently skipped.
- Every one of the 13 skills has an explicit classification addressing both Axis 1 (chaining) and Axis 2 (independent content-trigger), with a stated reason for each — not a restatement of a pre-narrowed candidate list.
- No skill relied upon for autonomous cross-skill chaining (confirmed via the Phase 0 map — this explicitly includes `review-gauntlet`, chained into by `conduct`/`fan-out`) is marked user-invoked.
- Both mirrors reflect the decision — either matching front-matter or a documented, deliberate divergence.
- Phase 2's front-matter change is verified by direct `rg` diff per skill (not by `scripts/check-prompt-parity.sh`, which doesn't cover front-matter).
- The skills architecture doc reflects the new classification so it doesn't silently rot on the next skill addition.
