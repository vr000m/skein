# Task: Align local skills with Managed Agents conventions

**Status**: Paused — initial alignment landed in PR [#10](https://github.com/vr000m/skills.md/pull/10) (merged 2026-04-14); broader work paused, no concrete follow-up beyond applying learnings ad-hoc to existing skills.
**Branch**: feature/managed-agents-alignment
**Created**: 2026-04-14
**Updated**: 2026-05-22

## Objective

Bring the local skill library into alignment with the Claude Managed Agents platform conventions so the same SKILL.md files could later be uploaded as custom skills with no structural rework, while also improving local Claude Code skill selection today.

## Context

The Managed Agents platform documents explicit conventions for custom skills: third-person descriptions, SKILL.md body under 500 lines, progressive disclosure with one-level-deep references, and optional rubrics for outcome-graded sessions. Most of these are useful locally regardless of whether we ever push skills to the platform — Claude Code uses the same frontmatter format for skill discovery, and the same token-budget pressures apply.

Separate tidy-up: the `deep-review` Phase 1 "Confirm Cost" gate asks for user confirmation before spawning lenses. In practice this has never been declined, and the user can always Ctrl+C mid-execution, so the gate is pure friction.

## Requirements

- Descriptions use third-person voice and include both what + when
- All SKILL.md bodies stay under 500 lines
- `deep-review` and `spec-compliance` ship with a rubric.md capturing gradeable criteria
- `deep-review` no longer blocks on confirmation before spawning lenses
- Multi-agent delegation pattern is documented explicitly in the two skills that use it
- Changes propagate to `~/.claude/skills/` via `just promote-skills`

## Review Focus

- Description format compliance (third person, trigger terms, <1024 chars)
- Rubric files use gradeable criteria ("The X contains Y") not vague language
- No behavioral regression in deep-review's lens dispatch

## Implementation Checklist

### Phase 1: Description audit
- [x] Rewrite `dev-plan` description to third person
- [x] Rewrite `fan-out` description to third person
- [x] Rewrite `review-plan` description to third person
- [x] Rewrite `rfc-finder` description to third person
- [x] Rewrite `spec-compliance` description to third person
- [x] Rewrite `update-docs` description to third person
- [x] Restructure `content-draft` to lead with what it does
- [x] Restructure `content-review` to lead with what it does
- [x] Leave `deep-review` description as-is (already compliant)

### Phase 2: Line-count verification
- [x] Confirm all SKILL.md under 500 lines (max observed: deep-review at 351)

### Phase 3: Rubric files
- [x] Create `.claude/skills/deep-review/rubric.md`
- [x] Create `.claude/skills/spec-compliance/rubric.md`
- [x] Reference rubrics from SKILL.md bodies

### Phase 4: Multi-agent pattern documentation
- [x] Add short "Delegation pattern" note to `deep-review/SKILL.md`
- [x] Add equivalent note to `review-plan/SKILL.md`
- [x] Document delegation depth in `fan-out/SKILL.md` (added during review-fix pass)

### Phase 5: Remove confirmation gate
- [x] Drop "Phase 1: Confirm Cost" from `deep-review/SKILL.md`
- [x] Replace with a single-line status announcement (no wait)

### Phase 6: Propagate and commit
- [x] `just promote-skills` to sync to `~/.claude/skills/`
- [x] `just check-sync` to verify
- [ ] Commit and open PR

## Technical Specifications

### Files to Modify

- `.claude/skills/content-draft/SKILL.md` - description rewrite
- `.claude/skills/content-review/SKILL.md` - description rewrite
- `.claude/skills/dev-plan/SKILL.md` - description rewrite
- `.claude/skills/fan-out/SKILL.md` - description rewrite
- `.claude/skills/review-plan/SKILL.md` - description rewrite + delegation note
- `.claude/skills/rfc-finder/SKILL.md` - description rewrite
- `.claude/skills/spec-compliance/SKILL.md` - description rewrite + rubric reference
- `.claude/skills/update-docs/SKILL.md` - description rewrite
- `.claude/skills/deep-review/SKILL.md` - remove Confirm Cost phase + rubric reference + delegation note

### New Files to Create

- `.claude/skills/deep-review/rubric.md` - gradeable criteria for the 5 lenses
- `.claude/skills/spec-compliance/rubric.md` - gradeable criteria for compliance reports

### Architecture Decisions

- **Keep SKILL.md format unchanged.** The existing format is already compatible with Managed Agents custom skills. No new fields or structural changes.
- **Rubrics are reference files, not inline content.** Keeps SKILL.md bodies short and makes rubrics reusable as Managed Agents outcome rubrics without duplication.
- **No upload-skills.sh yet.** Per discussion, the upload script is the one step that's Managed-Agents-only. Deferred until the user actually adopts the platform.

## Acceptance Criteria

- [x] All 9 skill descriptions are third-person
- [x] All 9 SKILL.md bodies under 500 lines
- [x] Rubric files exist and are referenced from SKILL.md
- [x] deep-review no longer prompts for confirmation before spawning lenses
- [x] `just check-sync` passes after `just promote-skills`
- [ ] PR opened against main

## Final Results

### Codex Adversarial Review (2026-04-14)

Run via `/codex:adversarial-review` against the working tree. Verdict: needs-attention. Two findings, both dismissed after discussion:

- **[high] Codex skill tree stale** — Dismissed. The `.codex/skills/` mirror is maintained by the Codex CLI in its own review pass, per the `no-codex-edits` workflow. Out of scope for this Claude-side change. (Subsequently confirmed: Codex CLI mirrored the changes in commits `906f946` and `ea71ce2`.)
- **[medium] deep-review auto-spawns on possibly-wrong target** — Dismissed. The removed gate was the *post-resolution* "Confirm Cost" prompt, which sat after target/scope were already determined and offered no further decision. Codex's reasoning about implicit targets applies to an earlier phase that does not exist in this skill (input resolution is deterministic), so adding a gate there would not match the user's mental model. The friction-free path is intentional.

### Deep Review (2026-04-14)

Run via `/deep-review only .claude changes` against the branch diff. Logic, Security, and Documentation lenses returned clean. Spec lens skipped (no specs in Review Focus). Architecture lens surfaced 2 minor findings, both fixed in commit `72d8687`:

- **[Architecture/minor] content-draft and content-review descriptions lack /command trigger phrase** — Fixed. Added `"/content-draft"` and `"/content-review"` to the respective descriptions for routing parity with all other skills.
- **[Architecture/minor] Delegation Pattern note added to deep-review and review-plan but not fan-out** — Fixed. Added a "Delegation Depth" section to `fan-out/SKILL.md` documenting the one-level constraint (spawned agents must not start a new fan-out tier).

### Summary

Local skills now align with Managed Agents conventions (third-person descriptions, rubric files, explicit delegation pattern notes, slash-command trigger parity). The same SKILL.md files could be uploaded as custom skills with no structural rework. deep-review runs friction-free after target resolution. Adversarial and multi-lens reviews ran clean after the two fixes.
