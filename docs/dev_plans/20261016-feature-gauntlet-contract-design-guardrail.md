# Task: review-gauntlet ripple-effect handling (contract guardrail, design deltas)

**Status**: In Progress
**Component**: review-skills
**Assigned to**: Claude (Claude mirror, shared files); Codex (Codex mirror, via `codex:rescue`)
**Priority**: Medium
**Branch**: feature/gauntlet-contract-design-guardrail
**Created**: 2026-10-16
**Review Gates**: full

## Objective

Stop `review-gauntlet` fixers from patching only the reported cell. Make them design the whole contract first, and record net-new design decisions instead of absorbing them silently.

## Context

On a downstream PR, three gauntlet runs (20+ rounds) kept finding the next rough edge of the last fix. Two chains: a reader tightened while its writer still emitted rejected data, and one cell of a state matrix fixed per round. Guardrails 3, 6 and 7 did not catch it, because a test for the reported case passes while the contract stays one-sided. Plan facts were checked in-session, so no separate Explore pass was run.

Decisions (grilled 2026-10-16):
- The fixer resolves in-contract ripple effects itself and logs each as a design delta. It escalates via Guardrail 1 only when a delta contradicts or expands the plan's stated intent.
- Deltas are written even without `--plan`. The plan is the one diff-touched plan, narrowed by branch slug. Otherwise the deltas go to `.gauntlet/design-deltas-<target>.md`. The sink never guesses.
- The merge-bar (stop on "no blocking findings") is deferred.
- Follow-up grill (2026-10-16): the writer's marker match is conduct's strict form (date + 40-hex, no awk intervals), so a placeholder-only plan gets the sidecar. A Guardrail 8 fix that lacks its test stays in the tree, is not counted as applied, and the conductor (not the fixer) decides scope. The delta sink sits outside the report-step anchors. The two `test_native_gates.py` failures are tracked in #56 and stay out of this PR.

## Requirements

- Guardrail 8 pins an invariant, both contract sides, and the state space before any edit. It requires a whole-space test and a mutation check. The conductor treats a fix without them as not applied.
- A "seam still moving" tripwire swaps the next point fix for a contract-level redesign brief.
- The terminal sink never changes the terminal token, never edits above the single review marker, and treats delta text as untrusted.
- Both mirrors stay aligned. Codex half first, Claude aligned in the same change. The two new `lib/` scripts are byte-identical.

## Implementation Checklist

### Phase 1: Guardrail 8 and seam tripwire
**Impl files:** `plugins/skein-codex/skills/review-gauntlet/SKILL.md, plugins/skein/skills/review-gauntlet/SKILL.md`
**Test files:** `tests/gauntlet/test-gauntlet-skill-shape.sh`
**Test command:** `bash tests/gauntlet/test-gauntlet-skill-shape.sh`
**Goal:** A fix for a contract finding is not "applied" without a stated invariant, both sides, a state space, a whole-space test and a mutation check.
- Add Guardrail 8, the Guardrail 4 conductor check, and the seam tripwire (done, 54b9ef1).

### Phase 2: Design-delta log and terminal sink
**Impl files:** `plugins/*/skills/review-gauntlet/lib/resolve-plan.sh, plugins/*/skills/review-gauntlet/lib/write-design-deltas.sh, plugins/*/skills/review-gauntlet/lib/convergence-ledger.sh, plugins/*/skills/review-gauntlet/SKILL.md`
**Test files:** `tests/gauntlet/test-design-deltas.sh, tests/gauntlet/test-design-delta-sink-{codex,claude}.sh, tests/gauntlet/test-convergence-ledger.sh, tests/parity/test-applier-bundle-parity.sh`
**Test command:** `bash tests/gauntlet/test-design-deltas.sh`
**Goal:** Bytes above the review marker never change, and a sink failure never changes the terminal token.
- Add `design_deltas` to the fixer report, the plan resolver, the writer, and the sanitizer (done, 1403044).

### Phase 3: Verify the Claude mirror
**Impl files:** `plugins/skein/skills/review-gauntlet/SKILL.md`
**Test files:** `tests/gauntlet/test-design-deltas.sh`
**Test command:** `just gauntlet-tests`
**Goal:** The Claude terminal block derives base, head and branch correctly for `--pr`, a branch, and a range.
- Execute the `gh pr view` / `git merge-base` derivation in a scratch repo (done: `tests/gauntlet/test-design-delta-sink-claude.sh`).
- Tighten the writer's marker match, reword the Guardrail 4 disposition, move the Claude sink out of the report anchors (done, grill follow-up).
- Run a second fresh-thread Codex review of the final fix round.
- Apply the `/code-review xhigh --fix` results, then run `just ci`.

### Phase 4: Gauntlet and PR
**Impl files:** `docs/dev_plans/20261016-feature-gauntlet-contract-design-guardrail.md`
**Test files:** `none`
**Test command:** `just ci`
- Run `skein:review-gauntlet` on the branch, as a dogfood of Guardrail 8 and the sink. Then run `/update-docs`.
- Push the branch and open a PR. Merge with a regular merge, never squash.

## Technical Specifications

### Files to Modify
- `plugins/skein/skills/review-gauntlet/SKILL.md`, `plugins/skein-codex/skills/review-gauntlet/SKILL.md` - Guardrail 8, tripwire, fixer schema, terminal sink.
- `tests/gauntlet/test-gauntlet-skill-shape.sh`, `tests/gauntlet/test-design-delta-sink-{codex,claude}.sh`, `tests/gauntlet/test-convergence-ledger.sh`, `tests/parity/test-applier-bundle-parity.sh`, `justfile` - pins, executed sink coverage, stable-run coverage, parity registration, recipe wiring.
- `AGENTS.md`, `CHANGELOG.md`, `README.md`, `docs/dev_plans/README.md` - lib list, test list, release notes, review-gauntlet row, plan index row.

### New Files to Create
- `plugins/{skein,skein-codex}/skills/review-gauntlet/lib/resolve-plan.sh` - plan resolution (explicit, diff-touched, branch slug, never guesses).
- `plugins/{skein,skein-codex}/skills/review-gauntlet/lib/write-design-deltas.sh` - plan or sidecar writer.
- `tests/gauntlet/test-design-deltas.sh` - whole-space and mutation tests.
- `tests/gauntlet/test-design-delta-sink-{codex,claude}.sh` - executes each harness's terminal sink fence in scratch repositories.

### Architecture Decisions
- Prompt-level contract guardrails remain the enforcement mechanism, like Guardrails 3, 6 and 7.
- Correction (2026-10-16): the terminal sink needs a ledger-owned opaque `run_id`; hashing the mutable ledger made the same run acquire a new section identity after every appended round. Fresh-ledger initialization atomically persists the immutable reviewed base/head/branch scope so even a first-ever sink call after interruption cannot follow a moved target. Legacy ledgers derive an append-stable fallback from their target, limits and first round.
- The merge-bar is deferred. It needs a new terminal token and a blocking-vs-minor classification in `convergence-ledger.sh` on both mirrors. Revisit only if a run with Guardrail 8 and deltas still ends in cap or non-converge on minor-only findings.

### Dependencies
- None new.

### Integration Seams

| Seam | Writer (task) | Caller (task) | Contract |
|------|---------------|---------------|----------|
| `design_deltas` in `fixer-report.json` | Fixer (Phase 1 brief) | Terminal sink (Phase 2) | Array of objects, never in `claimed`. A non-array is skipped with a warning. |
| Plan resolution result | `resolve-plan.sh` | `write-design-deltas.sh` | Status is explicit, unique, none or ambiguous. Anything but explicit or unique goes to the sidecar. |
| Ledger run identity and reviewed scope | `convergence-ledger.sh --init` | Resumed terminal sink | `run_id` is stable across appends and fresh on forced init; persisted base/head/branch are reused for that run. |

## Testing Notes

### Test Approach
- [x] Shape tests pin Guardrail 8 and the sink on both mirrors.
- [x] Table-driven marker, sidecar, head and sanitization probes, each with a mutation check.
- [x] Executed test of the Claude-side base/head derivation: `tests/gauntlet/test-design-delta-sink-claude.sh` runs the SKILL.md sink fence in scratch repos (implicit branch, `a..b`, `a...b`, `pr:<N>` through a fake `gh`, `gh` failure, unset context, symlinked working file) with mutation checks.
- [x] Executed Codex resume test proves appended rounds retain one section identity, persisted scope keeps the original reviewed head after the branch moves, and symlinked fixer reports are refused. Writer tests also refuse symlinked resolution and delta inputs.

### Test Results
- [x] `just ci` passes except 2 `test_native_gates.py` cyclic-snapshot cases. They fail the same way on clean main and are out of scope and tracked in #56 (open).
- [x] Review-fix coverage passes: Codex sink 43/43, Claude sink 61/61, writer/resolver 275/275, convergence ledger 231/231, skill shape 388/388, lib parity 179/179, timeout 168/168, plus prompt parity, sync, script lint and plugin tests.
- [ ] Final `just ci` after the grill follow-up fixes. Known baseline: only the 2 tests in #56 fail.

## Acceptance Criteria

- Guardrail 8, the tripwire and the sink are present and pinned on both mirrors.
- A plan with two review markers receives deltas in the sidecar and its bytes are unchanged.
- Claude-side base/head derivation is exercised by an executed test.
- `just ci` is green apart from the 2 known pre-existing failures.
- Reviews converged and docs updated.

<!-- reviewed: YYYY-MM-DD @ <hash> -->
<!-- /review-plan writes the marker line above. Everything below is the workspace: edits here do NOT invalidate the marker. -->

## Progress

- [x] Phase 1: Guardrail 8 and seam tripwire (54b9ef1)
- [x] Phase 2: Design-delta log and terminal sink (1403044)
- [ ] Phase 3: Verify the Claude mirror (done: code-review fixes 6db9ffc, grill follow-up 29833ac, fresh-thread Codex review; open: final `just ci` after the gauntlet fixes)
- [ ] Phase 4: Gauntlet and PR (gauntlet rounds 1-4 fixed in aaebcff, 11e4a9e, 4ac7844 and 636322c; round 5 fixes in 9eff970 and e65e854; round 6 fixes in d39e244; round 7 fixes in 5632142; round 8 fixes in 7cd71dd (writer/marker.py seam closed by delegating the marker choice to marker.py via python3 -I); round 9 fixes in e899fd1; round 10 (the cap) found 12 more and its fixes landed in eb7bd15; at the operator's direction a verification round 11 ran beyond the cap and found 7 rows (5 distinct: absent tripwire file, dropped-delta reporting, predictable authority temp names, stale Claude cleanup text, docs); its fixes landed in 0026033 and get no further gauntlet round, so the independent Codex-native gauntlet is the remaining check, then re-run until convergence; review-gauntlet ledger under .gauntlet/)

## Findings

## Issues & Solutions

- Quick mode exists only in the Codex mirror (the Claude mirror's `Review Gates` is `none | full`), so only the Codex sink has `design_delta_quick_round`; quick sections use their own run id (`codex-<ledger-id>-quick-<12-hex digest of the persisted quick fixer report>`) so different quick runs never replace each other and an identical rerun is idempotent. This is a sanctioned mirror asymmetry.
- Codex `resume` runs read-only, so a fix round sent through it changes nothing. Start a fresh write-mode task instead.
- Review correction (2026-10-16): mutable-ledger hashing duplicated design-delta sections, resume lost reviewed scope, and three input reads bypassed the state-path guard. The sink now uses ledger-owned identity plus persisted scope and guards every state-derived read.

## Final Results
