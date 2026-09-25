# Task: prompt-audit cleanup (Claude-side skill text)

**Status**: In Progress
**Component**: meta
**Assigned to**: Claude
**Priority**: Low
**Branch**: chore/prompt-audit-cleanup
**Created**: 2026-09-25
**Review Gates**: none

## Objective

Apply the Medium-confidence findings of the 2026-09-25 `/claude-api prompt-audit` of `plugins/skein/skills/**` (target Fable 5.1 / Opus 5.5) that are safe to land Claude-side only.

## Scope (Claude-only; no parity impact)

Frontmatter `description:` rewrites (trigger-case enumeration, behaviour text in routing field):
- `conduct`, `grill`, `dev-plan` in `plugins/skein/skills/*/SKILL.md`. Codex descriptions are Codex-tuned and intentionally left alone.

`deep-review/SKILL.md`:
- L704: replace "do not lobby it back in" with the stated reason (verified against `20260515-feature-review-auto-fix-tier.md:40`).
- L91: remove the unverified Managed Agents `callable_agents` analogy.

## Out of scope

- `release` description: `check-prompt-parity.sh` compares release's normalized SKILL.md frontmatter byte-for-byte with Codex (found when `just ci` failed). Needs a `codex:rescue` pair-edit.
- `*-prompt.md` edits (`fan-out/agent-prompt.md`, `conduct/reviewer-prompt.md`): `scripts/check-prompt-parity.sh` enforces byte-identity with the Codex mirror, so these need a `codex:rescue` pair-edit. Deferred.
- `content-draft` / `content-review` banned-phrase list: rejected — the skill exists to enforce anti-LLM style; the list is its purpose, not cruft.
- Codex analogues of the `deep-review` edits (`skein-codex/.../deep-review/SKILL.md:534`): via `codex:rescue`, separate change.
- Flag-only audit items (model-pin duplication, effort-claim verification, `ci-parity-prompt.md` orphan check).

## Verification

- `just ci` green (parity + description-shape tests).
- `git diff --stat` touches only the five Claude-side files plus this plan and CHANGELOG.

## Progress

- [ ] Edits applied
- [ ] `just ci` green
