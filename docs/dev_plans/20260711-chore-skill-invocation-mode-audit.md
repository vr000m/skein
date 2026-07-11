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

That's ~815 words of always-loaded trigger text, growing every time skein adds a skill (11 → 13 in the last two months). Some of these skills are very plausibly invoked by natural language independent of their slash command — `grill` ("grill me on X"), `review-plan` ("audit plan"), `conduct` ("implement phase 1"), `content-draft`/`content-review` ("draft a TIL") — and should stay model-invoked. Others are narrower and more mechanical, and are candidates for `disable-model-invocation`: `fan-out`, `plan-view`, `spec-compliance`, `rfc-finder`, `review-gauntlet`. This plan does not pre-decide the classification — that's Phase 1's job — but it names the working hypothesis so the audit has a starting point, not a blank slate.

**Two things must be verified before any front-matter is edited, not assumed:**

1. **Does `disable-model-invocation: true` break in-repo cross-skill chaining?** `review-gauntlet`'s SKILL.md instructs itself to run `/review-plan`, `/deep-review`, `/security-review` as literal slash-command text (`plugins/skein/skills/review-gauntlet/SKILL.md:99` and similar). If that mechanism depends on the target skill's description being in the model-invocation pool (rather than the agent just calling the Skill tool by explicit name, which per the Skill tool's own description works for "one the user explicitly typed as `/<name>`" — ambiguous whether an *orchestrating skill's prose* counts the same way), disabling model-invocation on a chained-to skill could silently break `review-gauntlet`. `review-plan` and `deep-review` are excluded from the disable candidate list above for this reason, but it needs empirical confirmation, not just avoidance-by-hypothesis.
2. **Does the Codex CLI harness even read a `disable-model-invocation`-equivalent field?** This key has zero occurrences in either mirror today (confirmed via repo-wide grep). skein's Codex mirror already diverges from Claude on other harness-specific mechanics (`$SKILL_DIR` vs `${CLAUDE_PLUGIN_ROOT}`, per prior memory `feedback_harness_divergent_path_anchors`) — front-matter support is not guaranteed to be identical. If Codex has no equivalent, the two mirrors will *intentionally* diverge on this front-matter key, which must be documented as a deliberate difference, not treated as parity drift.

## Review Focus

- Verify Phase 0's chaining test actually exercises the disable-model-invocation flag on a real skill in a real session (not just a documentation read) before any Phase 1 classification depends on the answer.
- Verify the final classification table's reasoning per skill is concrete (cites a real natural-language phrase or chaining dependency), not a restatement of the working hypothesis above.
- Verify Codex-mirror handling is explicit for every skill: either the equivalent field is applied, or its absence/inapplicability is stated with a reason — no skill silently skipped.
- Verify no skill that other skills chain into (`review-plan`, `deep-review`, `security-review` if present, and any skill referenced by literal `/name` text elsewhere in the plugin) is marked `disable-model-invocation` without Phase 0 confirming that's safe.
- Confirm `scripts/check-prompt-parity.sh` (or equivalent) still passes / is updated if front-matter parity expectations change.

## Implementation Checklist

### Phase 0: Verify the two open questions before classifying anything

**Impl files:** none (research phase — findings recorded in this plan's Context/Requirements)
**Test files:** none
**Test command:** n/a

- Test `disable-model-invocation: true` on one low-stakes skill (e.g. `rfc-finder`) in a scratch/throwaway branch or local session: confirm the harness still invokes it via explicit `/rfc-finder`, confirm it no longer appears available for autonomous natural-language firing, and confirm whether `review-gauntlet`-style literal `/skill-name` text from *within another skill's SKILL.md* still successfully invokes it. Revert the scratch change after observing the result — it is not this phase's real edit.
- Grep the Codex CLI's own skill-loading documentation/source (or ask via the `claude-code-guide`/Codex-equivalent research path) for whether a front-matter key suppresses autonomous invocation the same way. Record the answer (supported / not supported / no equivalent concept) plainly.
- Update this plan's Context section with the confirmed answers before starting Phase 1 — do not carry the "ambiguous, unverified" hedge into the classification phase.

### Phase 1: Classify all 13 skills

**Impl files:** none (produces a decision table added to this plan)
**Test files:** none
**Test command:** n/a

- For each of the 13 skills, decide `model-invoked` (stays as-is) or `user-invoked` (`disable-model-invocation: true`), using the criterion: "would a user plausibly reach this by describing intent in natural language, without knowing or typing the slash command, on a normal day using skein?" A "yes" keeps it model-invoked; a "no" makes it a candidate for user-invoked.
- Cross-check every "no" candidate against Phase 0's chaining findings — if another skill relies on autonomously firing it (not just literal-text-invoking it), it must stay model-invoked regardless of the natural-language test.
- Record the table (skill, classification, one-line reason) in this plan before touching any SKILL.md.

### Phase 2: Apply front-matter changes to both mirrors

**Impl files:** `plugins/skein/skills/<skill>/SKILL.md` and `plugins/skein-codex/skills/<skill>/SKILL.md` for each skill classified user-invoked in Phase 1 (subject to Phase 0's Codex-support finding)
**Test files:** any existing SKILL.md front-matter parity test (e.g. `scripts/check-prompt-parity.sh` if it inspects front-matter)
**Test command:** `scripts/check-prompt-parity.sh` (confirm exact path/invocation before running — verify it exists first)

- Add `disable-model-invocation: true` to each user-invoked skill's Claude SKILL.md front-matter. Per writing-great-skills' mechanics note, trim the `description:` to a human-facing one-liner once it no longer needs to carry autonomous-trigger phrasing (the trigger-phrase clauses like "Use when the user says…" become dead weight once the harness can't act on them autonomously) — but keep this trim conservative: only strip clauses that exclusively serve autonomous triggering, not identity or usage-hint content a human skimming the skill list still needs.
- Apply the equivalent to the Codex mirror if Phase 0 found support; otherwise, add a one-line comment or plan note explaining the intentional divergence (do not fabricate a Codex field that doesn't exist).
- Run the existing parity check script(s) to confirm no unrelated drift was introduced.

### Phase 3: Update docs

**Impl files:** `docs/skills_architecture/20260522-design-claude-skills-architecture.md` (add a row or note on invocation mode per skill, alongside the existing model/reasoning routing table), this plan's own Status field
**Test files:** none
**Test command:** n/a

- Add an "Invocation Mode" column or short section to the skills architecture doc so future skill additions inherit the classification discipline instead of defaulting to model-invoked by habit.
- Flip this plan's Status to Complete and add the PR link once merged, per the repo's existing dev-plan convention.

## Acceptance Criteria

- Phase 0's two open questions have concrete, evidenced answers recorded in this plan (not hypotheses).
- Every one of the 13 skills has an explicit classification with a stated reason.
- No skill relied upon for autonomous cross-skill chaining is marked user-invoked without Phase 0 confirmation that doing so is safe.
- Both mirrors reflect the decision — either matching front-matter or a documented, deliberate divergence.
- The skills architecture doc reflects the new classification so it doesn't silently rot on the next skill addition.
