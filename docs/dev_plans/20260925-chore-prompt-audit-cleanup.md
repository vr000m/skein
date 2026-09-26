# Task: prompt-audit cleanup (Claude-side skill text)

**Status**: Complete — shipped in v0.8.3 (PR #46)
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

## Codex pair-edit (second commit, via codex:rescue)

- `release` description (parity-enforced frontmatter; keeps the phrase `/release audit scans tags, GitHub releases, and CHANGELOG versions` that `test_release_skill_contract.py` pins), `fan-out/agent-prompt.md` (three edits; mirrors differ by design in the test-writer block), `conduct/reviewer-prompt.md` (byte-identical), and Codex `deep-review` L534.

## Out of scope

- `*-prompt.md` edits (`fan-out/agent-prompt.md`, `conduct/reviewer-prompt.md`): `scripts/check-prompt-parity.sh` enforces byte-identity with the Codex mirror, so these need a `codex:rescue` pair-edit. Deferred.
- `content-draft` / `content-review` banned-phrase list: rejected — the skill exists to enforce anti-LLM style; the list is its purpose, not cruft.
- Codex analogues of the `deep-review` edits (`skein-codex/.../deep-review/SKILL.md:534`): via `codex:rescue`, separate change.
- Flag-only audit items (model-pin duplication, effort-claim verification, `ci-parity-prompt.md` orphan check).

## Verification

- `just ci` green (parity + description-shape tests).
- `git diff --stat` touches only the five Claude-side files plus this plan and CHANGELOG.

- Follow-up commit `9aefdf6`: `review-gauntlet` L225 incident SHAs dropped (Claude-only; its description and UNVERIFIED line stay — `test-gauntlet-skill-shape.sh` pins them).

## Progress

- [x] Edits applied
- [x] `just ci` green
