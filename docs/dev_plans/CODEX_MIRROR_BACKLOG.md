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

### 2026-05-23 — `feature/bundle-auto-fix-appliers` (Codex one-shot completed)

Claude-side bundling of the auto-fix pipeline landed first; the `.codex` analogue has now landed in the same branch. This entry is retained as handoff history, not open drift.

- Source: branch `feature/bundle-auto-fix-appliers` (Claude commits `eff1727` bundling + `.claude` bundled scripts, `e42ed64` `.claude` SKILL.md anchoring + no-fallback test, `086f6f1` check-sync/sync-skills round-trip authority).
- Claude files changed: `.claude/skills/{deep-review,review-plan}/SKILL.md` (operative auto-fix invocations anchored at `"$SKILL_DIR"/scripts/…` + "Resolving the bundled pipeline" subsection + hard-fail-on-missing-bundle rule); generated `.claude/skills/{deep-review,review-plan}/scripts/**`; shared infra `scripts/bundle-appliers.sh`, `scripts/check-sync.sh`, `scripts/sync-skills.sh`, `justfile`, `tests/parity/test-applier-bundle-parity.sh`, `tests/parity/test-no-manual-apply-fallback.sh`, `AGENTS.md`.
- Codex one-shot result:
  1. **Phase 0 (Codex runtime preflight)** — current Codex Desktop shell env exposes `CODEX_CI`, `CODEX_INTERNAL_ORIGINATOR_OVERRIDE`, `CODEX_SANDBOX`, `CODEX_SHELL`, and `CODEX_THREAD_ID`, but no `CODEX_HOME` and no loaded-skill base-path variable. The installed-skill idiom is therefore `$HOME/.codex/skills/<skill>/scripts/`; repo-local `.codex/skills/<skill>/scripts/` remains dev/parity-only.
  2. `.codex/skills/deep-review/SKILL.md`, `.codex/skills/review-plan/SKILL.md` now bind `CODEX_SKILL_DIR="$HOME/.codex/skills/<skill>"`, anchor every operative pipeline invocation (reconcile/audit/apply) through `"$CODEX_SKILL_DIR"/scripts/...`, and carry the "Resolving the bundled pipeline" subsection + hard-fail rule. Harness-native path is the **sanctioned divergence**; everything else stays in parity.
  3. `tests/parity/test-no-manual-apply-fallback.sh` now treats all four mirrors as anchored, with `SKILL_DIR` for Claude and `CODEX_SKILL_DIR` for Codex.
  4. `.codex/skills/{deep-review,review-plan}/scripts/**` were already committed mechanically (byte-identical to canonical via `bundle-appliers.sh`) and are re-verified by `just parity-tests`.
- Required result: Codex-native path resolution (sanctioned divergence); bundled `scripts/` subtree + allowlist stay byte-identical to canonical. The orchestration-contract test uses substring matching, so it already passes for the bare `.codex` form and will keep passing after a prefix anchor.
- Gating checks cleared by the Codex maintainer: `just parity-tests` (bundle + allowlist + orchestration + no-fallback), then `just promote-skills && just check-sync` green.
- Optional follow-ups surfaced by `/deep-review` — **both DONE 2026-05-24** in this branch in one four-mirror pass (the `.codex` side was already present, so they no longer needed a separate `.codex` pass): (a) **A3 (commit `02822b5`)** — added the inline, mirror-neutral `# documentation only` note above the bare `scripts/reconcile-findings.sh` example inside the GENERIC FINDING SCHEMA block, applied identically to all four SKILL.md copies so the block stays byte-identical across the four mirrors (cross-mirror equality enforced by `tests/parity/test-prompt-parity-extended.sh`); (b) **A5 (commit `23bb40d`)** — removed `render-reconciled-report.sh` from the bundle map after confirming it is never invoked by an anchored `"$SKILL_DIR"/scripts/…` call and no other bundled script calls it; it stays in canonical `scripts/` as the reference renderer (prose-cited, exercised by `tests/reconciliation/test-renderer.sh`). `scripts/lib/bundle-map.sh` is single-sourced (consumed by the bundler, the parity test, and check-sync) and now carries a rationale comment so render is not re-added; invariant after A5 is **bundled ⇔ operative**.

---

As of 2026-05-17, PR #23 (`feature/review-auto-fix-tier`) is **merged** at `f2d80ce` and lockstep-mirrors a fresh batch of Claude+Codex edits. Re-verified parity-clean on `main` post-merge; post-merge `scripts/promote-skills.sh --yes && just check-sync` ran green.

- Source PR: #23 (`feature/review-auto-fix-tier`), merge commit `f2d80ce`. Pre-merge HEAD was `282dded` (the final test-alignment commit `282dded` followed security-review hardening `f9fc142`; earlier verification at `f770663` re-confirmed at `282dded`).
- Claude files changed: `.claude/skills/deep-review/SKILL.md`, `.claude/skills/deep-review/rubric.md`, `.claude/skills/review-plan/SKILL.md`, `.claude/skills/review-plan/rubric.md`, plus shared infra under `scripts/auto-fix-allowlist.json`, `scripts/lib/auto-fix-common.sh`, and the auto-fix pipeline scripts.
- Codex files mirrored in the same PR: `.codex/skills/deep-review/SKILL.md`, `.codex/skills/deep-review/rubric.md`, `.codex/skills/review-plan/SKILL.md`, `.codex/skills/review-plan/rubric.md`.
- Required result: byte-identical parity for rubrics and the auto-fix allowlist; harness-specific wording allowed in SKILL.md (Agent/subagent vs `spawn_agent`).
- Envelope schema bumped 1 → 2 in `scripts/reconcile-findings.sh` and `scripts/render-reconciled-report.sh`; TSV intra-record separator changed `\t` → `\x1f` (commit `b259021`).
- Known follow-up flagged by `tests/parity/check-mirror-handoff.sh`: one mixed Claude/Codex Phase 3 commit (`1b49fe8`) on this branch — not a parity break, but a handoff-hygiene note. No further `.codex/` adaptation is owed for PR #23.
- Gating checks re-verified on `main` post-merge (2026-05-17):
  - PASS — `bash tests/parity/test-allowlist-byte-identity.sh` (`8 passed, 0 failed`).
  - PASS — `just check-prompt-parity` (`check-prompt-parity passed`).
  - PASS — `bash tests/parity/test-prompt-parity-extended.sh` (`13 passed, 0 failed`).
  - PASS — `just check-sync` after `scripts/promote-skills.sh --yes`.
  - KNOWN WARNING — `bash tests/parity/check-mirror-handoff.sh` reports only the existing mixed Phase 3 mirror commit (`1b49fe8`) and missing separate Phase 3 Claude boundary; this is tracked as handoff hygiene, not a Codex mirror backlog item.

Previous reconciled state (for history):

- 2026-05-19 — PR #25 (`chore/codex-skill-model-routing`), merge `03364a2`. Codex-originated model-routing cleanup, not deferred Claude→Codex drift. Changed 8 active `.codex/skills/*/SKILL.md` files plus the mirrored `.claude/skills/review-plan/SKILL.md` parity-prose line. No rubric or `scripts/auto-fix-allowlist.json` parity obligation arose. Gates green: `bash tests/parity/test-allowlist-byte-identity.sh` (`8 passed, 0 failed`), `just check-prompt-parity`, `bash tests/parity/test-prompt-parity-extended.sh` (`13 passed, 0 failed`), and `just check-sync` after `scripts/promote-skills.sh --yes`. `bash tests/parity/check-mirror-handoff.sh` remained non-zero only for the pre-existing PR #23-era `1b49fe8` handoff-hygiene note.
- 2026-05-07 — PR #16 (`feature/skill-improvements-from-usage-report`), merge `222644a`. Adapted Codex files: `.codex/skills/deep-review/{SKILL.md,rubric.md}`, `.codex/skills/dev-plan/{SKILL.md,rubric.md}`, `.codex/skills/update-docs/SKILL.md`. Codex follow-up: `72ac72b`.

No required Codex mirror backlog entries are known at this point. The optional A3/A5 follow-ups are now **resolved** (landed 2026-05-24 in `feature/bundle-auto-fix-appliers`; see the dated entry above).
