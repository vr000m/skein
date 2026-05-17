# Codex Mirror Backlog

Purpose: track known Claude/Codex skill drift after a Claude-side change lands before the Codex analogue is adapted. Use this file when parity is intentionally deferred so the debt is visible beyond a transient handoff note.

## How to Add Entries

When a Claude skill change has no Codex equivalent yet, append an entry with:

- Date and source PR/commit.
- Claude files changed.
- Codex files needing analogous updates.
- Whether the required result is byte-identical parity or Codex-native adaptation.
- Gating checks the Codex maintainer must clear.

Do not list ordinary harness-specific wording as drift. `SKILL.md` files may legitimately differ where Claude uses Agent/subagent wording and Codex uses `spawn_agent`, Codex model names, or Codex state-file names. Rubrics that declare parity must remain byte-identical.

## Current State

As of 2026-05-17, PR #23 (`feature/review-auto-fix-tier`) lockstep-mirrors a fresh batch of Claude+Codex edits. Pending verification on merge to main.

- Source PR: #23 (`feature/review-auto-fix-tier`), pre-merge HEAD `b259021`.
- Claude files changed: `.claude/skills/deep-review/SKILL.md`, `.claude/skills/deep-review/rubric.md`, `.claude/skills/review-plan/SKILL.md`, `.claude/skills/review-plan/rubric.md`, plus shared infra under `scripts/auto-fix-allowlist.json`, `scripts/lib/auto-fix-common.sh`, and the auto-fix pipeline scripts.
- Codex files mirrored in the same PR: `.codex/skills/deep-review/SKILL.md`, `.codex/skills/deep-review/rubric.md`, `.codex/skills/review-plan/SKILL.md`, `.codex/skills/review-plan/rubric.md`.
- Required result: byte-identical parity for rubrics and the auto-fix allowlist; harness-specific wording allowed in SKILL.md (Agent/subagent vs `spawn_agent`).
- Envelope schema bumped 1 → 2 in `scripts/reconcile-findings.sh` and `scripts/render-reconciled-report.sh`; TSV intra-record separator changed `\t` → `\x1f` (commit `b259021`).
- Known follow-up flagged by `tests/parity/check-mirror-handoff.sh`: one mixed Claude/Codex Phase 3 commit on this branch — not a parity break, but a handoff-hygiene note. Confirm clean post-merge.
- Gating checks (must be green post-merge):
  - `just check-prompt-parity`
  - `just check-trunk-snippet-parity`
  - `tests/parity/test-allowlist-byte-identity.sh`
  - `tests/parity/test-prompt-parity-extended.sh`
  - `tests/parity/check-mirror-handoff.sh`

Previous reconciled state (for history):

- 2026-05-07 — PR #16 (`feature/skill-improvements-from-usage-report`), merge `222644a`. Adapted Codex files: `.codex/skills/deep-review/{SKILL.md,rubric.md}`, `.codex/skills/dev-plan/{SKILL.md,rubric.md}`, `.codex/skills/update-docs/SKILL.md`. Codex follow-up: `72ac72b`.

No open Codex mirror backlog entries are known at this point, pending the post-merge gating-check run for PR #23.
