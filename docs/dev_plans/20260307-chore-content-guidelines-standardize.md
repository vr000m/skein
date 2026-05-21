# Standardize Content Guidelines in Skills Repo

| Field | Value |
|-------|-------|
| **Status** | Complete (PR [#5](https://github.com/vr000m/skills.md/pull/5) merged 2026-03-07) |
| Assignee | Codex |
| Priority | High |
| Branch | `codex/content-guidelines-standardize` |
| Created | 2026-03-07 |
| Updated | 2026-03-07 |

## Objective

Make this repo the canonical home for `content-guidelines.md`, add anti-LLM authenticity rules to the drafting and review workflow, and mirror the updated skill assets into the global Codex and Claude skill directories.

## Context

The repo previously treated content guidelines as externally sourced, with script support for local and remote overrides. That made the authority model harder to reason about and kept the anti-LLM guidance split between the draft skill, the review skill, and the `varunsingh.net` repo. This change consolidates the content guidance here, strengthens the drafting constraints, and makes review enforce the same authenticity rules.

## Requirements

- `content-guidelines.md` must be canonical in this repo.
- `.codex` and `.claude` copies of `content-guidelines.md` must stay in sync.
- `content-draft` must include explicit anti-LLM authenticity constraints and a final de-LLM pass.
- `content-review` must review against those authenticity constraints, not just style and structure.
- Sync/promotion/bootstrap/check scripts must stop using `CONTENT_GUIDELINES_LOCAL` and `CONTENT_GUIDELINES_URL`.
- Repo documentation must describe the new authority model clearly.
- Updated `content-draft` and `content-review` skills must be promoted to the global Codex and Claude skill folders.

## Implementation Checklist

### Phase 1: Canonical Content Guidance

- [x] Add anti-LLM authenticity rules to `.codex/skills/content-review/references/content-guidelines.md`
- [x] Mirror the same guideline file to `.claude/skills/content-review/references/content-guidelines.md`
- [x] Add checklist items that enforce concrete openers, anchors, trade-offs, and rough-edge disclosure

### Phase 2: Skill Updates

- [x] Update `.codex/skills/content-draft/SKILL.md` with hard authenticity constraints and a de-LLM pass
- [x] Update `.claude/skills/content-draft/SKILL.md` with the same drafting rules
- [x] Update `.codex/skills/content-review/SKILL.md` so review covers AI-signalling phrases, abstraction-only prose, concrete anchors, trade-offs, and failure notes
- [x] Update `.claude/skills/content-review/SKILL.md` with the same review expectations

### Phase 3: Authority Model and Docs

- [x] Update sync scripts to treat the repo guideline file as canonical
- [x] Remove local/remote content-guideline fetch logic from scripts
- [x] Update `.env.example` to reflect repo-canonical guidelines
- [x] Update `README.md` authority model and workflow notes
- [x] Add a dedicated dev plan for this work and update the dev-plan index

### Phase 4: Validation and Promotion

- [x] Run `bash -n scripts/*.sh`
- [x] Run `shellcheck scripts/*.sh`
- [x] Run `shfmt -d scripts/*.sh`
- [x] Run `./scripts/promote-skills.sh --yes` with `MANAGED_SKILLS='content-draft content-review'`
- [x] Run `./scripts/check-sync.sh`

## Technical Specifications

### Files Modified

| File | Change |
|------|--------|
| `.codex/skills/content-draft/SKILL.md` | Add anti-LLM drafting constraints and de-LLM pass |
| `.claude/skills/content-draft/SKILL.md` | Mirror draft skill updates |
| `.codex/skills/content-review/SKILL.md` | Expand review scope to enforce authenticity signals |
| `.claude/skills/content-review/SKILL.md` | Mirror review skill updates |
| `.codex/skills/content-review/references/content-guidelines.md` | Canonical guideline file with anti-LLM rules |
| `.claude/skills/content-review/references/content-guidelines.md` | Mirror canonical guideline file |
| `scripts/sync-skills.sh` | Exclude `references/` dir for content-review during sync; restore repo Claude copy from canonical codex source |
| `scripts/promote-skills.sh` | Copy canonical `references/` dir to both global targets |
| `scripts/bootstrap-skills.sh` | Copy canonical `references/` dir to global with `--force` guard |
| `scripts/check-sync.sh` | Validate all `references/` files across repo/global; require `content-guidelines.md` and `writing-style-rules.md` |
| `.env.example` | Remove external guideline-source configuration |
| `README.md` | Slim to human essentials, link to AGENTS.md |
| `AGENTS.md` | New root-level operational reference for both agents (updated across multiple commits) |
| `docs/dev_plans/README.md` | Add this work item to completed tasks |

### Authority Decision

- Canonical source: `.codex/skills/content-review/references/` (entire directory)
- Repo mirror: `.claude/skills/content-review/references/content-guidelines.md`
- Global mirrors:
  - `~/.codex/skills/content-review/references/content-guidelines.md`
  - `~/.claude/skills/content-review/references/content-guidelines.md`

### Anti-LLM Rules Added

- Concrete-first openers
- Evidence density per major section
- Required trade-off disclosure
- Required failure/adjustment disclosure
- Ban on common AI-signalling template phrases
- Removal of assistant-meta residue
- Mandatory final de-LLM pass before output

## Testing Notes

Executed:

- `bash -n scripts/*.sh` (pass)
- `shellcheck scripts/*.sh` (pass)
- `shfmt -d scripts/*.sh` (pass)
- `MANAGED_SKILLS='content-draft content-review' ./scripts/promote-skills.sh --yes` (pass)
- `./scripts/check-sync.sh` (pass)

## Issues & Solutions

- Issue: `check-sync` failed before promotion because the global skill folders still contained the older draft/review skill copies.
- Solution: Promote only `content-draft` and `content-review` to global, then re-run `check-sync`.

- Issue: The repo had no dedicated dev plan for this standardization work, which made later review less precise.
- Solution: Add this plan file and update `docs/dev_plans/README.md`.

- Issue: `promote-skills.sh` and `bootstrap-skills.sh` copied each repo guideline copy to its own global target, allowing drift if the Claude copy was hand-edited.
- Solution: Copy from the single canonical source (codex) to both global targets.

- Issue: `sync-skills.sh` rsync `--exclude` only covered `content-guidelines.md`, leaving `writing-style-rules.md` vulnerable to deletion if missing from global.
- Solution: Exclude the entire `references/` directory for content-review during sync.

- Issue: `bootstrap-skills.sh` overwrote pre-existing global `content-review/references/` without respecting `--force`.
- Solution: Add non-destructive guard — skip if global references already have content unless `--force` is used.

## Acceptance Criteria

- [x] Drafting rules explicitly discourage generic AI-sounding output
- [x] Review rules can detect and flag those same authenticity failures
- [x] Repo docs describe this repo as the guideline authority
- [x] Scripts no longer depend on external content-guideline sources
- [x] Global Codex and Claude skill folders received the updated skill copies
- [x] Validation commands completed successfully
- [x] A dedicated dev plan exists for downstream review

### Phase 5: Docs Deduplication

- [x] Add root `AGENTS.md` with project-specific operational context (commands, architecture, authority model, gotchas)
- [x] Slim `README.md` to human essentials (intro, skills table, setup) and link to `AGENTS.md`
- [x] Remove duplicated authority model, workflow, conflict policy, and commands sections from `README.md`

### Phase 6: Review Fixes

- [x] Fix guideline promotion drift: `promote-skills.sh` and `bootstrap-skills.sh` now copy from canonical codex source to both global targets
- [x] Add explicit cross-reference to full anti-LLM rule set in `content-draft/SKILL.md`
- [x] Update `AGENTS.md` gotcha to reflect repo-canonical model (not old `.env` priority chain)
- [x] Harden `sync-skills.sh` to exclude entire `references/` directory for content-review (prevents accidental deletion of `writing-style-rules.md`)
- [x] Code review passed
- [x] Security review passed (no vulnerabilities)

### Phase 7: Bootstrap Reference Sync Safety (Codex fix)

- [x] `bootstrap-skills.sh` respects `--force` for `content-review/references/` (skips if global already has content unless `--force`)
- [x] `check-sync.sh` explicitly requires `content-guidelines.md` and `writing-style-rules.md` via `REQUIRED_REFERENCE_FILES` array
- [x] `AGENTS.md` gotcha updated: `.env` is optional, not required

### Phase 8: update-docs Skill Improvement

- [x] Add "Stale descriptions" check to dev plan audit in `.claude/skills/update-docs/SKILL.md`
- [x] Mirror the same change to `.codex/skills/update-docs/SKILL.md`

## Final Results

This repo now owns the content-guideline authority. The draft and review skills both enforce anti-LLM authenticity constraints, the sync tooling mirrors the canonical guideline file outward instead of pulling it in from elsewhere, and the updated skill copies have already been promoted to the global Codex and Claude skill folders.

Root `AGENTS.md` is now the single source of operational details for both Claude Code and Codex CLI. `README.md` focuses on human onboarding and links to `AGENTS.md` for the rest.
