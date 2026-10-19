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
- Independent-review grill (2026-10-18): quick-mode ledger identity is scope-keyed. The same base/head/branch reuses one generation; a moved head selects a new generation; a legacy pre-scope ledger is atomically bound once. Full/resume ledger identity remains target-keyed and immutable.

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
- `plugins/{skein,skein-codex}/skills/review-gauntlet/lib/convergence-ledger.sh` - run identity, reviewed scope, `--bind-review-scope`, owned run-dir state.
- `AGENTS.md`, `CHANGELOG.md`, `README.md`, `docs/dev_plans/README.md` - lib list, test list, release notes, review-gauntlet row, plan index row.

### New Files to Create
- `plugins/{skein,skein-codex}/skills/review-gauntlet/lib/resolve-plan.sh` - plan resolution (explicit, diff-touched, branch slug, never guesses).
- `plugins/{skein,skein-codex}/skills/review-gauntlet/lib/write-design-deltas.sh` - plan or sidecar writer.
- `tests/gauntlet/test-design-deltas.sh` - whole-space and mutation tests.
- `tests/gauntlet/test-design-delta-sink-{codex,claude}.sh` - executes each harness's terminal sink fence in scratch repositories.
- `tests/gauntlet/test-design-delta-sink-state-contract.sh` - sink state contract (run identity, scope, generation) across both mirrors.
- `tests/gauntlet/test-pr-base-merge-base.sh` - PR review base is the merge base, checked against an advanced base branch.

### Architecture Decisions
- Prompt-level contract guardrails remain the enforcement mechanism, like Guardrails 3, 6 and 7.
- Correction (2026-10-16): the terminal sink needs a ledger-owned opaque `run_id`; hashing the mutable ledger made the same run acquire a new section identity after every appended round. Fresh-ledger initialization atomically persists the immutable reviewed base/head/branch scope so even a first-ever sink call after interruption cannot follow a moved target. Legacy ledgers derive an append-stable fallback from their target, limits and first round.
- Correction (2026-10-18): Codex quick mode must not reuse a target-keyed ledger after its own fixes move `HEAD`. It derives a generation from the canonical target plus the complete immutable review scope. `convergence-ledger.sh --bind-review-scope` may migrate a pre-scope ledger only when explicit provenance proves quick ownership; an indistinguishable legacy full/quick ledger fails closed.
- Correction (2026-10-19): non-empty deltas are never lost silently. `write-design-deltas.sh` returns `sink:"dropped"` plus a reason through one `emit_dropped` helper (exit 0) on every failure path; `none` is reserved for zero deltas. Private temps come from `create_private_temp` (mktemp, trap-cleaned), and plan writes go through `plan_snapshot`, which parses a private snapshot and byte-compares the live plan before `mv`. The sink prints `Design deltas: unknown — <reason>` when the delta count cannot be established.
- Correction (2026-10-19): the reviewed base is the merge base, not the base-branch tip. For PR, bare-branch and three-dot targets the base OID passed to `resolve-plan.sh`, the sink and `review_scope.base_oid` is `git merge-base`; two-dot targets keep their literal left endpoint. For a PR, `baseRefOid` is only the base-branch tip, so the sink merge-bases it with `headRefOid` and leaves the base empty (sidecar) when an object is absent locally or merge-base fails. `resolve-plan.sh` diffs `base..head`.
- The merge-bar is deferred. It needs a new terminal token and a blocking-vs-minor classification in `convergence-ledger.sh` on both mirrors. Revisit only if a run with Guardrail 8 and deltas still ends in cap or non-converge on minor-only findings.

### Dependencies
- None new.

### Integration Seams

| Seam | Writer (task) | Caller (task) | Contract |
|------|---------------|---------------|----------|
| `design_deltas` in `fixer-report.json` | Fixer (Phase 1 brief) | Terminal sink (Phase 2) | Array of objects, never in `claimed`. A missing report is known-empty; an existing non-regular, malformed, unreadable, or non-array report makes collection unknown. |
| Plan resolution result | `resolve-plan.sh` | `write-design-deltas.sh` | Status is explicit, unique, none or ambiguous. Anything but explicit or unique goes to the sidecar. |
| Ledger run identity and reviewed scope | `convergence-ledger.sh --init` | Resumed terminal sink | `run_id` is stable across appends and fresh on forced init; persisted base/head/branch are reused for that run. |
| Codex quick generation | `prepare_quick_design_delta_state` | `convergence-ledger.sh` | Exact scope reuses one ledger; moved scope selects another; only provably quick-owned legacy state may bind once. |
| Full auto-chain generation | `prepare_auto_chain_full_state` | `convergence-ledger.sh` | Exact scope may reuse interrupted or terminal state; moved scope selects a new generation without changing standalone target identity. |

## Testing Notes

### Test Approach
- [x] Shape tests pin Guardrail 8 and the sink on both mirrors.
- [x] Table-driven marker, sidecar, head and sanitization probes, each with a mutation check.
- [x] Executed test of the Claude-side base/head derivation: `tests/gauntlet/test-design-delta-sink-claude.sh` runs the SKILL.md sink fence in scratch repos (implicit branch, `a..b`, `a...b`, `pr:<N>` through a fake `gh`, `gh` failure, unset context, symlinked working file) with mutation checks.
- [x] Executed Codex resume test proves appended rounds retain one section identity, persisted scope keeps the original reviewed head after the branch moves, and symlinked fixer reports are refused. Writer tests also refuse symlinked resolution and delta inputs.
- [x] Executed full/quick state tables distinguish missing fixer reports from existing directory/FIFO reports. Quick tests cover same-scope reuse, moved-head selection, proven legacy ownership, and terminal/nonterminal full-ledger collision refusal. Full auto-chain tests cover moved scope from interrupted and terminal ledgers in both harnesses.

### Test Results
- [x] The results below were the intermediate pre-round-12 snapshot. They are retained as historical evidence, not the final verification for the hardlink, ledger-provenance, auto-chain-scope, and tracked-cleanup redesign.
- [x] `just ci` passes except 2 `test_native_gates.py` cyclic-snapshot cases. They fail the same way on clean main and are out of scope and tracked in #56 (open).
- [x] Independent-review fix coverage passes: Codex sink 56/56, Claude sink 65/65, writer/resolver 285/285, convergence ledger 236/236, skill shape 395/395 and lib parity 179/179, including scope-generation, legacy-binding and non-regular report mutations.
- [x] Round-12 final focused verification (2026-10-18): writer/resolver 285/285, Codex sink 54/54, Claude sink 62/62, skill shape 402/402, convergence-ledger pass, parity pass, lens 178/178, reconciliation pass, plugin pass, and the four pytest groups 216/216, 69/69, 251/251 and 68/68. The cached offline pytest runner also passed native gates 56/56. The required final `just ci` result is recorded below only after that run completes.
- [x] Post-round-11 verification (2026-10-19): writer/resolver 284/284, Codex sink 54/54, Claude sink 62/62, state-contract 10/10, pr-base-merge-base 8/8, convergence-ledger 238/238, skill shape 405/405, lib parity 179/179, lint-scripts and `git diff --check` clean. `just ci` still stops only at the 2 known `test_native_gates.py` cyclic-snapshot cases (#56, open); the remaining recipes pass.

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
- [x] Phase 3: Verify the Claude mirror (code-review fixes 6db9ffc, grill follow-up 29833ac, fresh-thread Codex review, and independent Codex contract fixes verified across both mirrors)
- [ ] Phase 4: Gauntlet and PR (gauntlet rounds 1-4 fixed in aaebcff, 11e4a9e, 4ac7844 and 636322c; round 5 fixes in 9eff970 and e65e854; round 6 fixes in d39e244; round 7 fixes in 5632142; round 8 fixes in 7cd71dd (writer/marker.py seam closed by delegating the marker choice to marker.py via python3 -I); round 9 fixes in e899fd1; round 10 (the cap) found 12 more and its fixes landed in eb7bd15; at the operator's direction a verification round 11 ran beyond the cap and found 7 rows (5 distinct: absent tripwire file, dropped-delta reporting, predictable authority temp names, stale Claude cleanup text, docs); its fixes landed in 0026033 and get no further gauntlet round (post-round-11 code-review and Codex-review fixes: b316a2c, ab3359f, c33935c, a12cdaf, 30266ae, 5b1e3f5, ea3d2a2, and the PR merge-base regression fix 0fdb8d2 with test e62154a), so the independent Codex-native gauntlet is the remaining check, then re-run until convergence; review-gauntlet ledger under .gauntlet/)

## Findings

## Issues & Solutions

- Quick mode exists only in the Codex mirror (the Claude mirror's `Review Gates` is `none | full`), so only the Codex sink has `design_delta_quick_round`; quick sections use their own run id (`codex-<ledger-id>-quick-<12-hex digest of the persisted quick fixer report>`) so different quick runs never replace each other and an identical rerun is idempotent. This is a sanctioned mirror asymmetry.
- Independent-review correction (2026-10-18): quick ledgers are generation-keyed by the full immutable review scope. Re-running at the same scope remains idempotent; a moved head selects a fresh generation. A target-keyed legacy ledger migrates only with explicit quick provenance; otherwise quick mode refuses it.
- Codex `resume` runs read-only, so a fix round sent through it changes nothing. Start a fresh write-mode task instead.
- Review correction (2026-10-16): mutable-ledger hashing duplicated design-delta sections, resume lost reviewed scope, and three input reads bypassed the state-path guard. The sink now uses ledger-owned identity plus persisted scope and guards every state-derived read.
- Round-12 correction (2026-10-18): sink and writer scratch outputs now use exclusive random, single-link inodes and atomic final publication. Quick migration requires explicit quick ownership, auto-chain selects a new full generation when immutable scope moves, and init cleanup refuses force-tracked owned files. This supersedes the earlier predictable scratch-path, scope-only legacy adoption, and target-only auto-chain decisions.

## Final Results

- Round 12 replaced every sink/writer scratch write with an exclusive random single-link temporary-file contract plus atomic publication, separated quick/full legacy ownership, made auto-chain scope-aware, and made fresh cleanup preserve tracked writer-owned names.
- The complete hardlink state space is executed for both terminal-sink mirrors and the shared writer, including tracked and external aliases; deliberate mutations remove each single-link, scope-comparison, provenance, and tracked-cleanup enforcement and are caught by the focused suites.
- Final local verification used the repository's cached offline pytest environment: `parity-tests`, `lens-tests`, `reconciliation-tests`, `plugin-tests`, `pytest-tests`, native gates (56/56), and all focused round-12 suites passed. The background `just ci` attempt exposed only new ShellCheck/shfmt findings in the changed files; those were corrected and `just lint-scripts` then passed. A post-commit conductor run owns the uninterrupted aggregate CI confirmation.
