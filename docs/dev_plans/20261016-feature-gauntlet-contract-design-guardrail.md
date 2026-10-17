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
**Impl files:** `plugins/*/skills/review-gauntlet/lib/resolve-plan.sh, plugins/*/skills/review-gauntlet/lib/write-design-deltas.sh, plugins/*/skills/review-gauntlet/SKILL.md`
**Test files:** `tests/gauntlet/test-design-deltas.sh, tests/parity/test-applier-bundle-parity.sh`
**Test command:** `bash tests/gauntlet/test-design-deltas.sh`
**Goal:** Bytes above the review marker never change, and a sink failure never changes the terminal token.
- Add `design_deltas` to the fixer report, the plan resolver, the writer, and the sanitizer (done, 1403044).

### Phase 3: Verify the Claude mirror
**Impl files:** `plugins/skein/skills/review-gauntlet/SKILL.md`
**Test files:** `tests/gauntlet/test-design-deltas.sh`
**Test command:** `just gauntlet-tests`
**Goal:** The Claude terminal block derives base, head and branch correctly for `--pr`, a branch, and a range.
- Execute the `gh pr view` / `git merge-base` derivation in a scratch repo. Today it has only had a syntax check and shellcheck.
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
- `tests/gauntlet/test-gauntlet-skill-shape.sh`, `tests/parity/test-applier-bundle-parity.sh`, `justfile` - pins, parity registration, recipe wiring.
- `AGENTS.md`, `CHANGELOG.md` - lib list, test list, release notes.

### New Files to Create
- `plugins/{skein,skein-codex}/skills/review-gauntlet/lib/resolve-plan.sh` - plan resolution (explicit, diff-touched, branch slug, never guesses).
- `plugins/{skein,skein-codex}/skills/review-gauntlet/lib/write-design-deltas.sh` - plan or sidecar writer.
- `tests/gauntlet/test-design-deltas.sh` - whole-space and mutation tests.

### Architecture Decisions
- Prompt-level guardrails only, like Guardrails 3, 6 and 7. No ledger change.
- The merge-bar is deferred. It needs a new terminal token and a blocking-vs-minor classification in `convergence-ledger.sh` on both mirrors. Revisit only if a run with Guardrail 8 and deltas still ends in cap or non-converge on minor-only findings.

### Dependencies
- None new.

### Integration Seams

| Seam | Writer (task) | Caller (task) | Contract |
|------|---------------|---------------|----------|
| `design_deltas` in `fixer-report.json` | Fixer (Phase 1 brief) | Terminal sink (Phase 2) | Array of objects, never in `claimed`. A non-array is skipped with a warning. |
| Plan resolution result | `resolve-plan.sh` | `write-design-deltas.sh` | Status is explicit, unique, none or ambiguous. Anything but explicit or unique goes to the sidecar. |

## Testing Notes

### Test Approach
- [x] Shape tests pin Guardrail 8 and the sink on both mirrors.
- [x] Table-driven marker, sidecar, head and sanitization probes, each with a mutation check.
- [x] Executed test of the Claude-side base/head derivation: `tests/gauntlet/test-design-delta-sink-claude.sh` runs the SKILL.md sink fence in scratch repos (implicit branch, `a..b`, `a...b`, `pr:<N>` through a fake `gh`, `gh` failure, unset context, symlinked working file) with mutation checks.

### Test Results
- [x] `just ci` passes except 2 `test_native_gates.py` cyclic-snapshot cases. They fail the same way on clean main and are out of scope, but should be tracked.
- [ ] Final `just ci` after the code-review fixes.

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
- [ ] Phase 3: Verify the Claude mirror
- [ ] Phase 4: Gauntlet and PR

## Findings

## Issues & Solutions

- Codex `resume` runs read-only, so a fix round sent through it changes nothing. Start a fresh write-mode task instead.

## Final Results
