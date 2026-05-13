# Task: Autonomous phased implementation mode in `/conduct`

**Status**: Not Started
**Assigned to**: Claude
**Priority**: Medium
**Branch**: feature/conduct-autonomous-mode
**Created**: 2026-05-12
**Last revised**: 2026-05-13 (post-/review-plan round 2: ConductResult parity → Phase 1, plan-id reconciliation → Phase 1, Phase 4 reorder + scripted handoff gate, codex loader relax → Phase 1, pre-Phase-3 prompt-parity baseline, plus 11 testing-gap fixes)

## Objective

Extend `/conduct` with an autonomous mode that walks all phases of a reviewed dev-plan without per-phase handback, paired with a progress-aware fix-loop bound and an end-of-plan CI-parity gate. Closes item 2 ("Autonomous Phased Implementation w/ Test Iteration") on the parked horizon list.

## Context

`/conduct` already runs a per-phase fix loop (existing Step 6, bounded by `--max-iterations`, default 3) and routes pre-commit hook failures into the same loop (Step 8.4). What it does not do today:

1. The iteration cap is a flat integer count. A phase making real progress (each iteration produces new staged changes that shrink the failing-test set) can be cut off at iteration 4 even though it would have converged at 5. The cap is also generous enough that a stuck implementer doing identical no-op respawns still burns 3 iterations before handing back.
2. After every phase boundary, Step 9 unconditionally hands back with `Run: /conduct --resume <plan>`. This is the right default for review-heavy work, but blocks unattended overnight runs on long plans where the phases are independent enough that handback adds friction without adding safety.
3. Local `pytest` ≠ what CI actually runs. The phase's `Test command:` slot is the only gate before the boundary commit; a phase can land green locally and red on the matrix the conductor never opened.

This plan addresses all three. Pre-commit hooks already cover lint/typecheck/format via the Step 8.4 hook-failure-into-fix-loop path, so no new `Check cmd:` slot is needed.

The horizon note for this item is in `~/.claude/projects/-Users-vr000m-Code-vr000m-skills-md/memory/project_horizon_followups.md` (item 2). Item 1 — self-healing review pipelines — shipped in PR #20 (marker auto-refresh) and PR #21 (cross-lens reconciliation).

## Requirements

- **Backward compatible by default.** Today's invocation `/conduct <plan>` MUST behave exactly as before this plan: `--max-iterations` default stays at 3, handback after every phase, single boundary commit per phase. New behaviour activates only under explicit opt-in flags.
- **Two-flag iteration bound.** `--max-iterations` keeps its default of 3 and its legacy semantics. New `--max-iterations-ceiling` (default 8) provides the autonomous-mode runway. Stall detection (default on, `--stall-threshold` default 2) sits between them as the early-stop.
- **Stall signature is deterministic and inspectable.** A stall = two consecutive iterations producing identical `(sorted failing test names, diff_stat_hash)` signatures. `diff_stat_hash` is SHA-1 over canonicalised `git diff --cached --stat -w` output. The `-w` flag combination is probed once at module-import time of `progress.py`; if rejected, the module pins file-list-only canonicalisation (`git diff --cached --name-only | sort`) for the lifetime of the process and emits a one-shot stderr warning. Signature persisted to state so `--resume` mid-loop resumes the stall detector without a false reset.
- **`_check_iteration_bound` owns the increment, with explicit pre-implementation audit.** The new helper `_check_iteration_bound(state, opts, signature) -> Optional[ConductResult]` is the single source of truth for `iteration_count += 1`. Each of the three current call sites (grep `conductor.py` for `_check_iteration_bound` invocations: `_run_phase` test-failure branch, `_run_phase` hook-failure branch, `_retry_after_hook_failure`) removes its own `+= 1`. **Pre-implementation step (Phase 1, first task)**: record the current increment position at each site (before-vs-after failure-signature observability) and document any cycle shift introduced by centralising the increment. The `helper-is-single-increment-source-three-sites` test asserts that `iteration_count` at the bound-check point matches today's `iteration_count` at the equivalent return point on each of the three paths (structural invariant, not just "advanced by 1").
- **Loader tolerance for unknown `schema_version` with bounded forward-compat contract.** The loader treats absent as 1, `1` as v1, `2` as v2. For unknown values ≥1 it reads the known subset, emits one-shot warning `state file written by newer schema_version=<n>; reading known fields only`, and proceeds. **Forward-compat contract**: future schema versions MUST add only optional fields or fields with documented safe defaults for older readers; required-semantics fields require an explicit `incompatible_with_pre_vN: true` marker. The older loader hard-fails on `incompatible_with_pre_vN: true` (or any positive int) regardless of `schema_version`, with error message `state file requires a newer conduct loader (incompatible_with_pre_vN=<value>); upgrade /conduct or remove the state file to start fresh`. "Known subset" is defined as the literal v2 field list at this commit. Tests confirm warning fires exactly once per process (`unknown-schema-version-warning-suppressed-on-second-load-same-process`); a fresh `--resume` invocation re-fires it (`unknown-schema-version-warning-refires-after-resume`); `incompatible-with-pre-vn-loader-hard-fails` confirms the hard-fail path.
- **Auto-advance is opt-in via `--autonomous`.** When set, the conductor walks all phases in a single Python process via an explicit phase loop. Hard-stops still hand back: rogue commit, schema error, validation-cmd failure, stall ceiling, hard-iteration-ceiling, max-phases-cap, and (new) `awaiting_ci_parity` blocked on missing/malformed/stale result file.
- **`--max-phases N` safety cap.** Default: `len(parsed_phases) + 1`. Startup validator warns if `stall_threshold >= max_iterations`; an explicit run test (`stall-threshold-greater-than-max-iterations-legacy-dominates`) asserts the legacy cap fires with the correct blocker reason under that misconfiguration.
- **End-of-plan CI-parity gate is main-runtime-orchestrated with a hardened state-machine protocol.** Conduct does not directly call the runtime worker tool (`Agent` on Claude, `spawn_agent` / `wait_agent` / `close_agent` on Codex). When the gate dispatches, conduct:
  1. Sets `state["status"] = "awaiting_ci_parity"`, `state["ci_parity_request"] = {plan_path, base_sha, head_sha, ci_entrypoint_kind, ci_cmd, repo_root, plan_id, request_written_at_unix}`, persists state.
  2. Releases the lock and returns `ConductResult(status="awaiting_ci_parity", next_action="dispatch_ci_parity", request=<dict>)`.
  3. Conduct itself ensures `.conduct/` exists on the `awaiting_ci_parity` return path (idempotent `mkdir -p`-style; internal helper, not part of the cross-runtime contract). SKILL.md instructs the main runtime orchestrator to: dispatch the ci-parity worker with the harness-native mechanism and `ci-parity-prompt.md`, capture the worker's final JSON, **atomically** write it to `<repo-root>/.conduct/ci-parity-result-<plan-id>.json` via tmp file + `os.rename` (see the `_safe_write_text` helper in conductor.py — grep for the symbol — for the pattern), then re-invoke `/conduct --resume <plan>`.
  4. Conduct's preflight on the re-invocation handles four sub-cases for the result file:
     - **Present and valid AND `request_written_at_unix` field matches `state["ci_parity_request"]["request_written_at_unix"]`** → consume; on `passed` set status `complete`; on `failed` set status `ci_failed` and handback with blocker.
     - **Present but stale** (mtime/timestamp older than `state["ci_parity_request_written_at"]`, OR `plan_id` in the file disagrees) → ignore the file, re-emit `awaiting_ci_parity` with the same request (idempotent re-dispatch).
     - **Present but malformed** (JSON parse fail OR schema validation fail) → handback with status `schema_error` and blocker `ci-parity result file malformed at <path>`. File is preserved (not deleted) for inspection.
     - **Absent while status is `awaiting_ci_parity`** → re-emit `awaiting_ci_parity` with the same request. After 3 consecutive missing-file `--resume` invocations (counter `state["ci_parity_missing_resume_count"]`) handback with blocker `ci-parity result file missing after 3 resume attempts; pass --skip-ci-parity to abandon gate`.
  5. On successful consume, the result file is moved (not deleted) to `<repo-root>/.conduct/ci-parity-result-<plan-id>.consumed-<unix>.json` so post-mortem inspection survives.
  6. `--skip-ci-parity` escape hatch: when present, conduct sets status `complete` immediately with `state["last_summary"]` noting the skip; the request and any result file remain on disk.

  Single-exit precondition: gate fires only when conduct() would otherwise return `status=complete` — never on intermediate `--resume`. Detection priority (workflows dropped): `just ci` → `make ci` → `npm run ci` → `cargo test --all`. `--ci-cmd CMD` overrides detection.
- **`plan-id` derivation is shared with state-file naming.** `plan-id = sha1(rel(plan_path, repo_root).encode()).hexdigest()[:12]` — matching the existing `_state_path` convention in `.claude/skills/conduct/conductor.py` (grep for `_state_path`). Stored in `state["plan_id"]` on first state write so the main runtime orchestrator reads it from state, not by re-computing. State-file naming (`.conduct/state-<basename>-<plan-id>.json`) reuses the same derivation; the plan reuses the existing conduct convention rather than inventing a new one. Phase 1's pre-implementation step verifies and adopts this derivation as canonical (see Phase 1 pre-impl step).
- **Lock-release contention during `awaiting_ci_parity`.** Between the lock release at step (2) above and the orchestrator's `--resume`, another `/conduct` invocation could acquire the lock. Defined behaviour: a `/conduct --resume <plan>` invocation observing `status=awaiting_ci_parity` follows the four-sub-case preflight (present/stale/malformed/absent) above. A `/conduct <plan>` invocation without `--resume` against this state hard-fails preflight with `state shows awaiting_ci_parity; use --resume to consume the ci-parity result or --skip-ci-parity to abandon the gate`. A separate `/conduct --resume <other-plan>` with a different plan_id is unaffected (different state file, different lock). Test: `ci-parity-resume-during-awaiting-without-result-file` covers the same-plan re-resume case.
- **Codex remapping contract.** Claude-side work is the reference behaviour, not a verbatim file-copy requirement. Codex implements the same user-facing flags, state schema, marker semantics, report JSON, progress/stall semantics, CI-parity result protocol, and acceptance tests using Codex-native orchestration and existing Codex safety behaviour. `SKILL.md` and prompts should be contract-equivalent; exact text parity is required only for harness-neutral prompt/report contracts, not for runtime-dispatch prose.
- **Mirror responsibility** between `.claude/skills/conduct/` and `.codex/skills/conduct/` is the **runtime's own responsibility**: a claude-driven `/conduct` only lands `.claude/` changes; the codex-driven `/conduct` lands `.codex/` changes (in a separate run, against the same plan). Each runtime produces a single commit per phase boundary covering only its own mirror. The two-runtime mirror chain converges before Phase 4's parity checks run (see Phase 4 handoff gate).
- **`scripts/check-prompt-parity.sh` MUST be extended to check `*-prompt.md` parity** AND must not be invoked from any pre-commit hooks chain. Pre-implementation step (Phase 3, first task): grep `.pre-commit-config.yaml` and other hook configurations to confirm absence; if present, exempt the impl commit or refactor the hook to run only at the mirror-commit boundary. A new acceptance test `phase-3-impl-commit-lands-with-hooks-enabled-in-intermediate-state` confirms the impl commit succeeds with hooks on even though mirror is still lagging.
- **State schema evolution is forward-compatible.** Phases 1 and 2 write state with `schema_version: 1` plus tolerated extras (`stall_signatures`, `stall_count`, `autonomous`, `plan_id`). Phase 3 — the phase that adds the final v2 fields (`ci_parity_result`, `ci_parity_request`, `ci_parity_request_written_at`, `ci_parity_dispatched`, `ci_parity_missing_resume_count`) — bumps `schema_version: 2`.

## Review Focus

- **Progress detector false-negative risk.** Cases (a)–(f) including `--stat -w` fallback (sticky after one-time probe; one-shot warning). `progress.compute_staged_diff_stat` separately unit-tested (independent of probe) with synthetic whitespace-only and content edits.
- **Stall detector survives `--resume`.** Reset only on `state.get("current_phase_title") != phase.title`.
- **Single iteration-bound helper across all three call sites; helper owns the increment; pre-implementation audit recorded.** All three call sites (`_run_phase` test-failure branch, `_run_phase` hook-failure branch, `_retry_after_hook_failure` hook retry — grep for `_check_iteration_bound` in `conductor.py`) are uniformly wired and tested.
- **Intermediate-mirror-lag is plan-scope expected behaviour.** Between each runtime's per-phase commits there is a window where the other runtime's mirror has not yet landed. `just check-sync` and `just check-prompt-parity` are never invoked from pre-commit hooks (verified in Phase 3 pre-impl step), so the lag never blocks per-phase commits. Phase 4 handoff gate verifies convergence before parity/sync checks run.
- **Stall counter semantics are exact**, not approximate. With `--stall-threshold 2`: helper call 1 → count=1 stall=0; call 2 (matching signature) → count=2 stall=1; call 3 (matching) → count=3 stall=2 → blocks. Test `stall-blocks-at-threshold` asserts `iteration_count == 3` AND `stall_count == 2` at the block point, with blocker reason `stall_threshold exceeded`. The phrase "2 stalled iterations" in prose means 2 matches (i.e. 3 helper calls).
- **Hook-retry path `failing_tests` semantics.** `_retry_after_hook_failure` passes `failing_tests = sorted(failing_hook_ids)` extracted from hook output (typically `["ruff", "ruff-format"]`); falls back to `[]` when parsing fails — diff-stat then carries the signal alone. Tested with two real hook output samples.
- **Auto-advance + rogue-commit interaction.** Rogue commit in phase N of an autonomous run hands back at phase N; no advance to N+1.
- **CI-parity gate is single-exit, main-runtime-orchestrated, and crash-recoverable.** Result file is atomically written; preflight handles the four sub-cases (present-valid / present-stale / present-malformed / absent); `--skip-ci-parity` escape hatch exists. `plan-id` derivation matches state-file naming convention. Tests cover all four sub-cases plus the lock-release contention case.
- **CI-parity test/production path parity.** `ci_parity_spawn` injection seam exists for tests; the gate's consume-result code is the same Python branch whether the spawner is injected (test path) or the result file is read at re-invocation (production path). Test `ci-parity-injection-and-result-file-paths-share-consume-code` asserts identical state mutations across both paths.
- **No workflow files under `.github/workflows/` in this repo, and workflows are dropped from detection priority.**
- **Phase 1 bootstrap is a concrete checklist**, not a paragraph. Conducting agent runs an explicit step-by-step procedure (see Phase 1's "Bootstrap procedure" sub-section) so an autonomous Claude orchestrator does not invent detail.
- **`tests/parity/` directory does not exist today** — Phase 3 creates it. `LockAcquisitionCounter` test fixture does not exist today — Phase 2 introduces it.
- **State schema version bump.** Deferred to Phase 3; forward-compat rule lands in Phase 1.
- **Codex mirror is contract-equivalent and harness-native.** Shared prompt/report contracts remain parity-checked where they are harness-neutral; dispatch prose and orchestration details are remapped to Codex internals.

## Implementation Checklist

### Phase 1 — Progress-aware iteration bound + single helper + forward-compat loader

**Impl files:** `.claude/skills/conduct/conductor.py, .claude/skills/conduct/progress.py, .claude/skills/conduct/SKILL.md`
**Mirror files (codex-driven run, separate commit):** `.codex/skills/conduct/conductor.py, .codex/skills/conduct/progress.py, .codex/skills/conduct/SKILL.md`
**Test files:** `.claude/skills/conduct/tests/test_progress_detector.py, .claude/skills/conduct/tests/test_conductor_harness.py, .claude/skills/conduct/tests/test_diff_stat_canonicalisation.py`
**Test command:** `uvx pytest .claude/skills/conduct/tests/ -v`

**Pre-implementation step (first task):**
- **Verify `_state_path` uses `sha1(rel_to_repo_root)[:12]` and adopt that derivation as canonical `plan_id`.** Confirm by grep on `.claude/skills/conduct/conductor.py` for `_state_path`; the Requirements bullet on `plan-id` derivation has been updated to the rel-path form to match.
- **Audit existing `.conduct/state-*.json` files on the branch (and any test fixtures) for the `incompatible_with_pre_vN` field.** If any are found, document them or migrate to remove — they would hard-fail the new loader. Add a representative pre-Phase-1 fixture to the test suite (see `pre-phase-1-state-files-load-cleanly-under-new-loader`).
- Record the current `iteration_count += 1` position at each of the three call sites (`_run_phase` test-failure branch, `_run_phase` hook-failure branch inside `_run_phase`, `_retry_after_hook_failure` hook-retry — grep `conductor.py` for `iteration_count` writes) — specifically, whether the increment fires before or after the failure signature is observable to the conductor. Document this in the SKILL.md "Step 6" rewrite and use it to define the helper-on-entry increment position so no cycle shift is introduced.

**Tasks:**

- Add `.claude/skills/conduct/progress.py` (stdlib-only). Module-level probe at import: run `git diff --cached --stat -w 2>/dev/null` against an empty staging area; on non-zero exit or "unknown option" stderr, set `_USE_STAT_W = False` and emit one-shot warning. Decision sticky for process lifetime.
- Pure function `iteration_signature(failing_tests: list[str], staged_diff_stat: str) -> str` returns SHA-1 hex of `json.dumps({"tests": sorted(failing_tests), "diff_stat_hash": sha1(staged_diff_stat)}, sort_keys=True)`.
- Helper `compute_staged_diff_stat(repo_root) -> str` runs the canonical command (uses `_USE_STAT_W` to choose). Independently unit-testable (see `test_diff_stat_canonicalisation.py`).
- Extend state schema with `stall_signatures: list[str]` (rolling ≤2), `stall_count: int` (default 0), `plan_id: str` (`sha1(rel(plan_path, repo_root))[:12]`, matching the existing `_state_path` convention; computed once on first state write).
- Phase-1 state keeps `schema_version: 1`. Loader supplies safe defaults for new keys. Loader rule for unknown `schema_version`: value ≥1 and not in {absent, 1, 2} → read known subset, emit one-shot warning `state file written by newer schema_version=<n>; reading known fields only`. The warning is suppressed for the rest of the process (idempotent within the same Python process); re-fires on a fresh `--resume`. "Known subset" defined as: every field literally listed in this plan's state schema additions (Phase 1: stall_signatures, stall_count, autonomous, plan_id; Phase 3: ci_parity_*). Forward-compat contract documented in SKILL.md: future versions only add optional fields with safe defaults; required-semantics fields require an `incompatible_with_pre_vN: true` marker.
- **Loader hard-fails on `incompatible_with_pre_vN: true` (or any positive int) regardless of `schema_version`**, with error message `state file requires a newer conduct loader (incompatible_with_pre_vN=<value>); upgrade /conduct or remove the state file to start fresh`. This is the enforcement teeth behind the forward-compat marker; without it the marker is documentation only. Test: `incompatible-with-pre-vn-loader-hard-fails`.
- Add `_check_iteration_bound(state, opts, signature) -> Optional[ConductResult]` helper. Behaviour (helper owns the increment):
  1. `state["iteration_count"] += 1` (single source of truth).
  2. Push `signature` onto `state["stall_signatures"]` (truncate to length 2, oldest first).
  3. If new entry matches previous entry: `stall_count += 1`; else: `stall_count = 0`.
  4. Return blocked `("stall_threshold exceeded", ...)` if `state["stall_count"] >= opts.stall_threshold`.
  5. Return blocked `("max_iterations_ceiling exceeded", ...)` if `state["iteration_count"] > opts.max_iterations_ceiling`.
  6. Return blocked `("max_iterations exceeded (legacy)", ...)` if `state["iteration_count"] > opts.max_iterations`.
  7. Otherwise return None.
- Wire `_check_iteration_bound` into all three call sites. Each call site REMOVES its current `state["iteration_count"] += 1` line. Each computes its signature (`iteration_signature(failing_tests, compute_staged_diff_stat(...))`) and passes it to the helper. The hook-retry call site (in `_retry_after_hook_failure`) passes `failing_tests = sorted(failing_hook_ids)`; falls back to `[]` if parsing fails.
- `ConductOptions` (grep for `class ConductOptions` in conductor.py): keep `max_iterations: int = 3` (legacy). Add `max_iterations_ceiling: int = 8`, `stall_threshold: int = 2`, `no_progress_detection: bool = False`. Startup validator: if `stall_threshold >= max_iterations` AND `no_progress_detection is False`, emit warning.
- Phase-start reset for stall fields in `_run_phase` (grep for the `current_phase_title` guard): guard reset behind `state.get("current_phase_title") != phase.title` (absent treated as different). Reset trio (stall_signatures, stall_count, iteration_count) fires only on new-phase entry.
- **Codex-driven Phase 1 mirror commit adds `next_action: Optional[str] = None` and `request: Optional[dict] = None` to its `ConductResult`-equivalent dataclass.** Claude-side already landed these fields in commit `eb65eba`; the codex-side mirror lands them in Phase 1 so the two `ConductResult` shapes stay aligned from Phase 1 onward. Defaults are `None` until Phase 3 dispatches the ci-parity gate, so semantics are unchanged at Phases 1–2.
- **Codex-driven Phase 1 mirror also relaxes its loader to the tolerant-loader contract.** Today `.codex/skills/conduct/conductor.py` (around the `parse_report` / loader region — grep for `schema_version must be an int`) raises on absent/non-int `schema_version`. Update to match Claude: absent treated as 1; unknown ≥1 reads known subset with one-shot warning; `incompatible_with_pre_vN: true` hard-fails. Add a parity test that loads an absent-`schema_version` state file successfully on both runtimes.
- Step 8 retains today's 5-step flow unchanged: (1) rogue-commit check, (2) no-op branch, (3) impl commit, (4) hook retry, (5) record `commit_sha`. Each runtime lands a single commit per phase covering only its own mirror; the cross-runtime mirror handoff is verified in Phase 4 (see Phase 4 handoff gate).
- Update SKILL.md: Step 6 rewrite (stall-aware dual cap with helper-owns-increment invariant); State File section adds `stall_signatures`, `stall_count`, `autonomous`, `plan_id`, unknown-schema_version forward-compat contract, `incompatible_with_pre_vN` hard-fail rule; Step 4 preflight section adds "custom `--lint-check` overrides MUST NOT invoke `just check-sync` or `just check-prompt-parity`".
- **Bootstrap procedure for Phase 1's own boundary** (manual; the conducting agent — human or main runtime orchestrator — runs this verbatim on the claude-driven side):
  1. Stage exactly: `.claude/skills/conduct/conductor.py`, `.claude/skills/conduct/progress.py`, `.claude/skills/conduct/SKILL.md`, `.claude/skills/conduct/tests/test_progress_detector.py`, `.claude/skills/conduct/tests/test_conductor_harness.py`, `.claude/skills/conduct/tests/test_diff_stat_canonicalisation.py`.
  2. Commit: `git commit -m "conduct(phase 1): progress-aware iteration bound + single helper + forward-compat loader"`.
  3. The codex mirror lands separately when codex-driven `/conduct` runs against this same plan. `scripts/sync-skills.sh` is **NOT** invoked here — it syncs global → repo (refreshes repo from `~/.claude/skills/` and `~/.codex/skills/`), which is the wrong direction for landing a Phase 1 boundary, and it would clobber the just-staged working tree.
  4. `just check-sync` will report drift between `.claude/skills/conduct/` and global until `scripts/promote-skills.sh` runs in Phase 4 — that is expected during phased implementation and does not block boundary commits.

**Tests in `test_progress_detector.py`:**
- 5 signature cases (a)–(e) on `iteration_signature` pure function.
- `iteration-signature-stat-w-fallback` (case f): monkeypatch the probe to raise `CalledProcessError` with "unknown option" stderr; assert `_USE_STAT_W is False`; assert subsequent `compute_staged_diff_stat` calls use `--name-only | sort`; assert warning emitted exactly once.

**Tests in `test_diff_stat_canonicalisation.py` (new file):**
- `compute-staged-diff-stat-w-mode-whitespace-collapses` — `_USE_STAT_W=True` over a synthetic repo with both whitespace-only and content edits; assert whitespace-only edits collapse to identical output.
- `compute-staged-diff-stat-fallback-mode-deterministic-sort` — `_USE_STAT_W=False`; assert output is sorted file list independent of git's stat output ordering.

**Tests in `test_conductor_harness.py`:**
- `stall-blocks-at-threshold` — `--stall-threshold 2`; 2 matching signatures after the first; assert `iteration_count == 3 AND stall_count == 2` at block; blocker reason `stall_threshold exceeded`.
- `progress-resets-counter` — stall → progress → stall: counter resets, only 1 stall counted.
- `hard-ceiling-blocks-at-9` — every iteration shows new signature; ceiling fires at iteration_count == 9 with reason `max_iterations_ceiling exceeded`.
- `stall-survives-resume` — write state mid-stall (1 signature persisted); `--resume`; hit identical signature; assert block at threshold. **Additionally assert** that immediately after the resume, when `state["current_phase_title"]` matches the resumed phase's title, `state["stall_signatures"]` and `state["stall_count"]` are byte-equal to their pre-resume values (no false reset).
- `pre-commit-hook-stall-fires-bound` — hook-retry path; two real hook output samples (e.g. ruff stderr); assert `failing_tests` extracted as `["ruff"]`; signature matches; stall fires via helper; `iteration_count` advances exactly once. **Garbled-output variant**: a third hook-output sample is unparseable; assert `failing_tests == []` and that the signature is driven by `diff_stat_hash` alone.
- `helper-is-single-increment-source-three-sites` — explicit structural-invariant assertion across all three call sites (`_run_phase` test-failure branch, `_run_phase` hook-failure branch, `_retry_after_hook_failure`): for each path, after `_check_iteration_bound` returns None, `iteration_count` is exactly +1 from the pre-call value AND equals what today's code would have produced at the equivalent return point (recorded in the pre-implementation audit).
- `stall-signatures-truncate-to-length-2-across-many-iterations` — invoke `_check_iteration_bound` N>3 times with non-matching signatures; assert `len(state["stall_signatures"]) == 2` throughout and that the oldest entry is dropped on each push.
- `pre-phase-1-state-files-load-cleanly-under-new-loader` — load a representative set of pre-Phase-1 state file shapes (absent `schema_version`, explicit `schema_version: 1` without any of the new keys, etc.); assert no false hard-fail under the new loader.
- `legacy-max-iterations-default-3-stalled` — no new flags; flat-3 stalled-phase cap preserved.
- `legacy-max-iterations-default-3-progressing-also-blocks` — no new flags; progressing signatures every iter; assert handback at iter 4 with blocker `max_iterations exceeded (legacy)`.
- `incompatible-with-pre-vn-loader-hard-fails` — write state with `incompatible_with_pre_vN: true` (and separately with `incompatible_with_pre_vN: 2`); assert loader raises with the documented error message; assert this fires regardless of `schema_version`.
- `unknown-schema-version-99-resumes-with-warning` — write state with `schema_version: 99`; resume; assert read succeeds, warning emitted once.
- `unknown-schema-version-warning-suppressed-on-second-load-same-process` — two consecutive loads of an unknown-version state in the same Python process; assert warning fires exactly once.
- `unknown-schema-version-warning-refires-after-resume` — confirm a fresh `--resume` invocation re-fires the warning (new process → re-warn).
- `stall-threshold-greater-than-max-iterations-warns` — invoke with `--stall-threshold 5 --max-iterations 3`; assert startup warning emitted.
- `stall-threshold-greater-than-max-iterations-legacy-dominates` — same misconfiguration plus a stalled phase; assert handback at iter 4 with blocker `max_iterations exceeded (legacy)` (proves legacy cap dominates as documented, not just warned).

**Mirror commit**: handled by codex-driven `/conduct` against this same plan, not by the claude-driven run. The claude-driven boundary is a single commit covering `.claude/skills/conduct/{progress.py,conductor.py,SKILL.md}` plus tests.

### Phase 2 — `--autonomous` flag, explicit phase loop, auto-advance, `LockAcquisitionCounter` test fixture

**Impl files:** `.claude/skills/conduct/conductor.py, .claude/skills/conduct/SKILL.md`
**Mirror files (codex-driven run, separate commit):** `.codex/skills/conduct/conductor.py, .codex/skills/conduct/SKILL.md`
**Test files:** `.claude/skills/conduct/tests/test_autonomous_mode.py, .claude/skills/conduct/tests/test_conductor_harness.py, .claude/skills/conduct/tests/conftest.py (modify, add LockAcquisitionCounter)`
**Test command:** `uvx pytest .claude/skills/conduct/tests/ -v`

- **Introduce `LockAcquisitionCounter` test fixture** in `tests/conftest.py` (new utility, does not exist today per codebase-claims). Counter wraps the lock-acquire path and increments on each successful acquisition; tests assert lock-acquisition count.
- **Refactor `conduct()` to an explicit phase loop** inside the existing `with lock:` block (grep for `with lock:` in `conductor.py`), preserving single-lock-acquisition for autonomous runs in the test-injection path. Production note: the `awaiting_ci_parity` dispatch releases the lock before returning so the main runtime orchestrator can re-invoke `--resume`; that path naturally re-acquires on resume (test-mode injection consumes the result inline without releasing — see AC 2a/2b for the split invariant):
  ```python
  while True:
      if len(state["completed_phases"]) >= opts.max_phases:
          return _handback(state, opts, blocker=f"max_phases ceiling hit ({opts.max_phases})")
      idx = len(state["completed_phases"])
      if idx >= len(phases):
          break  # all phases done; fall through to ci-parity gate (Phase 3)
      phase = phases[idx]
      result = _run_phase(opts, state, phase)
      # _run_phase returns ONLY after the boundary commit completes (or routes to Step 6 fix-loop, or hands back).
      # The append to state["completed_phases"] happens inside _run_phase after the boundary commit (or the no-op equivalent).
      if result.status != "running":
          return result
      if not opts.autonomous:
          return _handback(state, opts, kind="phase_success")
      # autonomous: persist progress, continue to next iteration
  ```
- `_run_phase` invariant: returns only after the boundary commit completes (or Step 6 fix-loop is exhausted, or a hard-stop fires). The append to `state["completed_phases"]` happens after the boundary commit in `_run_phase`. Therefore `max_phases` check at top of each loop iteration reads a post-commit count.
- Add `autonomous: bool = False`, `max_phases: Optional[int] = None` to `ConductOptions`. `max_phases=None` resolves to `len(parsed_phases) + 1`.
- `_handback()` unchanged.
- Hard-stop paths (handback regardless of `--autonomous`): rogue commit, schema error, validation-cmd failure, stall-threshold hit, max-iterations-ceiling hit, max-phases cap hit, `awaiting_ci_parity` with missing-result-after-3-resumes (Phase 3 wires this).
- Update SKILL.md Step 9: split into 9a (phase success transition, autonomous-aware) and 9b (hard-stop handback). Document single-lock-acquisition property under autonomous mode.

**Tests in `test_autonomous_mode.py`:**
- `autonomous-3-phase-success` — 3-phase fixture; single invocation. **Test-injection path**: `ci_parity_spawn` is injected, gate consumes inline without releasing the lock; `LockAcquisitionCounter == 1`. **Production-equivalent path** (separate test variant or assertion): when the gate dispatches via the result-file protocol, lock is released before `awaiting_ci_parity` and re-acquired on `--resume` consume → `LockAcquisitionCounter == 2`. Both paths end with 3 completed phases and the gate firing exactly once.
- `autonomous-rogue-commit-handback-at-phase-2` — rogue commit in phase 2; assert phase 1 complete, phase 2 has `commit_sha: null` and `rogue_commit_sha` set, status `awaiting_user`, no phase 3.
- `autonomous-schema-error-handback-at-phase-1` — malformed JSON in phase 1; handback, no phase 2.
- `autonomous-validation-cmd-failure-handback-at-phase-2` — phase 2 validation cmd non-zero exit; handback, no phase 3.
- `autonomous-ci-parity-not-fired-after-intermediate-phase` — gate stub not invoked between phases 1, 2; only after final.
- `max-phases-cap-4-phase-fixture-cap-2` — 4-phase plan with `--max-phases 2` → handback after phase 2 with blocker `max_phases ceiling hit (2)`.
- `max-phases-cap-respects-post-commit-count` — boundary case: `--max-phases 2`, 3-phase fixture; assert phase 3 never enters `_run_phase` (the loop's max_phases check fires on the post-commit count immediately after phase 2 completes).
- **Regression** in `test_conductor_harness.py`: `legacy-no-flags-handback-per-phase` — no flags; `LockAcquisitionCounter == N` for N phases (one lock acquisition per `--resume`); byte-for-byte handback message preserved.

**Mirror commit**: handled by codex-driven `/conduct` against this same plan. Claude-driven boundary commits for this phase land `.claude/skills/conduct/{conductor.py,SKILL.md}` and tests in a single commit.

### Phase 3 — End-of-plan CI-parity gate + schema bump + mandatory parity-script extension + `tests/parity/` directory

**Impl files:** `.claude/skills/conduct/conductor.py, .claude/skills/conduct/ci_parity.py, .claude/skills/conduct/ci-parity-prompt.md, .claude/skills/conduct/schema.py, .claude/skills/conduct/SKILL.md, scripts/check-prompt-parity.sh`
**Mirror files (codex-driven run, separate commit):** `.codex/skills/conduct/conductor.py, .codex/skills/conduct/ci_parity.py, .codex/skills/conduct/ci-parity-prompt.md, .codex/skills/conduct/schema.py, .codex/skills/conduct/SKILL.md`
**New directory:** `tests/parity/` (parent `tests/` exists; the `parity/` subdir does NOT exist today per codebase-claims and is created in this phase).
**Test files:** `.claude/skills/conduct/tests/test_ci_parity.py, .claude/skills/conduct/tests/test_schema_migration.py, .claude/skills/conduct/tests/test_conductor_harness.py, tests/parity/test-prompt-parity-extended.sh`
**Test command:** `uvx pytest .claude/skills/conduct/tests/ -v && bash tests/parity/test-prompt-parity-extended.sh`

**Pre-implementation step (first task):**
- Verify `scripts/check-prompt-parity.sh` is NOT invoked from `.pre-commit-config.yaml` or any other hook chain. If it is, either exempt the impl commit (via SKIP env var pattern) OR refactor the hook to run only at mirror-commit boundary. Document the result in the SKILL.md "Step 8" section. This unblocks the Phase 3 impl commit landing while mirrors lag.
- Plan-id reconciliation: Phase 1 has already canonicalised the derivation as `sha1(rel(plan_path, repo_root))[:12]`; no work required here.
- **Diff every existing `*-prompt.md` pair** between `.claude/skills/<skill>/` and `.codex/skills/<skill>/` across all `MANAGED_SKILLS` (e.g. `implementer-prompt.md`, `reviewer-prompt.md`, `test-writer-prompt.md`). Reconcile any pre-existing drift in a SEPARATE commit (or commits, per-skill) BEFORE the Phase 3 impl commit extends `scripts/check-prompt-parity.sh`. Otherwise the script extension will fail immediately on unrelated legacy drift.

**Tasks:**

- **`ConductResult` already carries the `next_action` / `request` fields on both runtimes from Phase 1** (claude-side landed in commit `eb65eba`; codex-side landed in the Phase 1 codex-driven mirror commit). Phase 3 simply dispatches them by setting non-None values on the `awaiting_ci_parity` return.
- Add `.claude/skills/conduct/ci_parity.py` (stdlib-only) with `detect_ci_entrypoint(repo_root: Path) -> tuple[str, str] | None`. Priority: `just ci` → `make ci` → `npm run ci` → `cargo test --all`. Returns `(kind, cmd)` or `None`.
- Add `--run-ci-parity`, `--ci-cmd CMD`, and `--skip-ci-parity` flags to `ConductOptions`. `--run-ci-parity` is implied by `--autonomous`. `--ci-cmd` overrides detection. `--skip-ci-parity` short-circuits the gate to status `complete` with a "skipped" summary entry.
- **Define a test-only dispatch seam.** `CIParitySpawnRequest(plan_path, base_sha, head_sha, ci_entrypoint_kind, ci_cmd, repo_root, plan_id, request_written_at_unix)`. `ci_parity_spawn: Optional[Callable[[CIParitySpawnRequest], str]]` on `ConductOptions`. Production: `None`. Tests: scripted spawners.
- **Production dispatch is main-runtime-orchestrated** (per Requirements). Conduct on dispatch:
  - Computes `plan_id` (reusing the existing convention identified in pre-implementation).
  - Persists `state["ci_parity_request"]`, `state["ci_parity_request_written_at"] = time.time()`.
  - Initialises `state["ci_parity_missing_resume_count"] = 0`.
  - Sets `status = "awaiting_ci_parity"`.
  - Returns `ConductResult(status="awaiting_ci_parity", next_action="dispatch_ci_parity", request=<dict>)`.
- **Preflight handling at re-invocation** in `awaiting_ci_parity` status (four sub-cases enumerated in Requirements above):
  - Compute `result_path = <repo-root>/.conduct/ci-parity-result-<plan-id>.json`.
  - If file present AND `json.loads` succeeds AND schema passes AND `request_written_at_unix` matches state → `consume-result` step: on `passed` set status `complete`, append summary; on `failed` set status `ci_failed`, persist `ci_parity_result`, set blocker, handback. Move file to `.consumed-<unix>.json`.
  - If file present but mtime older than state's `ci_parity_request_written_at` OR `plan_id` field disagrees → ignore, re-emit `awaiting_ci_parity` with same request.
  - If file present but malformed → status `schema_error`, blocker `ci-parity result file malformed at <path>`, file preserved for inspection.
  - If file absent → `state["ci_parity_missing_resume_count"] += 1`; if ≥3 → handback with blocker `ci-parity result file missing after 3 resume attempts; pass --skip-ci-parity to abandon gate`; else re-emit `awaiting_ci_parity`.
- **Lock-release contention.** Preflight on `/conduct <plan>` (without `--resume`) against `awaiting_ci_parity` state hard-fails with `state shows awaiting_ci_parity; use --resume to consume or --skip-ci-parity to abandon`. A `/conduct --resume <plan>` from a parallel process follows the four-sub-case flow above (idempotent).
- `_dispatch_ci_parity_if_eligible(state, opts) -> ConductResult` helper. Called from BOTH exit points:
  - Autonomous phase loop: after `while` exits.
  - Legacy non-autonomous: at the top of `conduct()` when `len(state["completed_phases"]) >= len(phases)` AND `not state.get("ci_parity_dispatched")`, before the "All phases complete" early return.
  Logic: if `opts.skip_ci_parity`, set complete with skip summary, return. Else if `opts.autonomous or opts.run_ci_parity`, detect entrypoint or use `opts.ci_cmd`. Entrypoint resolvable: if `opts.ci_parity_spawn` is set (test mode), call synchronously and run consume-result inline; else (production) follow the main-runtime turn protocol per above. No entrypoint and no override → warning + complete.
- **Test/production code-path sharing**: the consume-result code (state mutations, summary append, status setting) is factored into a single function `_consume_ci_parity_result(state, opts, ci_parity_report)` that both the test-injection path (called synchronously after the scripted spawner returns) and the production result-file path (called by preflight on re-invocation) call. Test `ci-parity-injection-and-result-file-paths-share-consume-code` asserts byte-identical state mutations across the two paths.
- Create `.claude/skills/conduct/ci-parity-prompt.md` with placeholders `{{PLAN_PATH}}, {{BASE_SHA}}, {{HEAD_SHA}}, {{CI_ENTRYPOINT_KIND}}, {{CI_CMD}}, {{REPO_ROOT}}, {{PLAN_ID}}`. Subagent contract: execute the entrypoint; return final fenced JSON `{role: "ci-parity", schema_version: 1, plan_id: "<plan-id>", request_written_at_unix: <number>, status: "passed" | "failed", duration_seconds, command_run, last_2000_bytes_of_output, summary}`. The `plan_id` and `request_written_at_unix` echoed back enable the stale-result-file detection.
- Extend `schema.py` `parse_report` to accept `"ci-parity"` role. Required: `role, schema_version, plan_id, request_written_at_unix, status, command_run`. Optional: `duration_seconds, last_2000_bytes_of_output, summary`. Mismatched `plan_id` or `request_written_at_unix` in the parsed report causes the stale-file path.
- **Schema version bump.** Phase 3 introduces `ci_parity_result, ci_parity_request, ci_parity_request_written_at, ci_parity_dispatched, ci_parity_missing_resume_count`. First state write under Phase 3 emits `schema_version: 2`. Forward-compat rule from Phase 1 still applies.
- **Update SKILL.md**: new top-level section "## CI Parity Gate" between "Per-Phase Workflow" and "Fallbacks". Document detection priority (workflows dropped), `--ci-cmd` override, `--skip-ci-parity` escape, single-exit precondition, workflow-less skip, four-sub-case result-file handling, lock-release contention behaviour, and the main-runtime dispatch protocol. Conduct itself ensures `.conduct/` exists on the dispatch path; the main runtime orchestrator only needs to atomically write the result file to a known path. Also document: result-file atomic-write requirement (see the `_safe_write_text` helper in conductor.py — grep for the symbol — for the pattern).
- **Extend `scripts/check-prompt-parity.sh`.** Currently checks only `rubric.md`. After this phase: for each skill in `MANAGED_SKILLS`, additionally diff every `*-prompt.md` file between `.claude/skills/<skill>/` and `.codex/skills/<skill>/`. Dispatch-idiom exception in SKILL.md does NOT apply to prompt files.
- **Create `tests/parity/` directory** (does not exist today). Add `tests/parity/test-prompt-parity-extended.sh`.

**Tests in `test_ci_parity.py`:**
- `detect-priority-just-over-make` — synthetic tmpdir with both `justfile` containing `ci:` recipe AND `Makefile` `ci:` target; `just ci` wins.
- `detect-priority-make-over-npm` — synthetic tmpdir with both `Makefile ci:` target and `npm run ci` script in `package.json`; `make ci` wins.
- `detect-priority-npm-over-cargo` — synthetic tmpdir with both `npm run ci` script and `Cargo.toml`; `npm run ci` wins.
- `detect-returns-none-on-empty-repo` — none of the markers; returns None.
- `ci-cmd-override-bypasses-detection` — Makefile present + `--ci-cmd "echo custom"`; custom wins.
- `ci-cmd-override-with-autonomous-3-phase` — override fires at end-of-autonomous-loop (cross-product test).
- `ci-cmd-override-with-run-ci-parity-only` — override fires at legacy single-exit (cross-product test).
- `ci-parity-pass-sets-complete` — scripted spawner returns `passed`; status `complete`, summary appended.
- `ci-parity-fail-sets-ci_failed-and-handback` — scripted spawner returns `failed`; status `ci_failed`, `ci_parity_result` persisted, handback.
- `ci-parity-skip-workflow-less` — no entrypoint, no override; warning, status `complete`.
- `ci-parity-skip-ci-parity-flag-shortcuts-gate` — `--skip-ci-parity` set; gate skipped, status `complete` with skip-summary.
- `ci-parity-skip-ci-parity-during-awaiting-preserves-artifacts` — set up state in `awaiting_ci_parity` with a request file on disk; invoke `--resume --skip-ci-parity`; assert the request file and any existing result file remain on disk (not deleted, not moved) and status transitions to `complete` with the skip summary.
- `ci-parity-standalone-no-autonomous` — `--run-ci-parity` only; multi-phase; gate fires only on final `--resume`.
- `ci-parity-single-exit-no-fire-on-intermediate-resume-without-autonomous` — explicit assertion: gate NOT dispatched after phase 1; IS dispatched after final phase.
- `ci-parity-single-exit-fires-once-with-autonomous` — scripted spawner counter asserts gate invoked exactly once at end-of-loop.
- `ci-parity-injection-and-result-file-paths-share-consume-code` — run the same scripted scenario via (a) injected spawner, (b) result-file production path; assert byte-identical state mutations.
- **Result-file robustness tests** (the four sub-cases):
  - `ci-parity-result-file-present-and-valid-consumes` — happy path; result file with matching `plan_id` and `request_written_at_unix`; consume succeeds; file moved to `.consumed-*.json`.
  - `ci-parity-stale-result-file-rejected` — result file with mismatched `plan_id`; preflight ignores, re-emits `awaiting_ci_parity`.
  - `ci-parity-stale-by-timestamp-result-file-rejected` — result file mtime older than `state["ci_parity_request_written_at"]`; preflight ignores, re-emits.
  - `ci-parity-stale-by-request-written-at-mismatch` — result file is well-formed and current by mtime, but its `request_written_at_unix` field does not equal `state["ci_parity_request"]["request_written_at_unix"]`; preflight treats as stale, re-emits `awaiting_ci_parity`.
  - `ci-parity-malformed-result-file-handback` — corrupted JSON; status `schema_error`, file preserved.
  - `ci-parity-missing-result-file-at-resume-counter-increments` — `awaiting_ci_parity` state, no file; `ci_parity_missing_resume_count` increments; after 3 → handback with documented blocker.
  - `ci-parity-resume-during-awaiting-without-result-file` — same-plan `--resume` from a second process; observes `awaiting_ci_parity`, no result file; re-emits same request (idempotent).
  - `ci-parity-non-resume-against-awaiting-hard-fails` — `/conduct <plan>` without `--resume` against `awaiting_ci_parity` state; preflight hard-fails with documented message.
  - `ci-parity-atomic-write-survives-tmp-cleanup` — simulate partial-write by writing tmp file then killing before rename; assert preflight sees absent (not corrupt) and re-emits `awaiting_ci_parity`.

**Tests in `test_schema_migration.py`:**
- `absent-schema-version-resumes-cleanly` — no `schema_version` key; resume; defaults populate; next save emits `schema_version: 2`.
- `explicit-schema-version-1-resumes-cleanly` — explicit `schema_version: 1`; resume; defaults populate; next save emits `schema_version: 2`.
- `v2-state-file-roundtrip` — full v2 state; read; all fields present.
- `unknown-schema-version-99-resumes-with-warning` — `schema_version: 99`; resume succeeds reading known subset; warning emitted once.

**Tests in `tests/parity/test-prompt-parity-extended.sh`:**
- `mirror-commit-required-after-impl` — synthetic git history with impl-only commit (no mirror); run extended script; assert non-zero exit citing missing mirror.
- `prompt-divergence-detected` — copy a prompt file with a single-character change in the mirror; run extended script; assert non-zero exit naming the divergent file.
- `ci-parity-prompt-included` — deliberate divergence in `ci-parity-prompt.md`; assert script fails (proves the new prompt is in scope).
- `phase-3-impl-commit-lands-with-hooks-enabled-in-intermediate-state` — replay the Phase-3 impl commit on a fixture branch with pre-commit hooks enabled; assert the commit lands cleanly even though mirrors are intermediate.
- `check-prompt-parity-exits-with-documented-expected-drift-in-mid-handoff` — fixture replicates the intermediate state where the claude-side Phase 3 commit has landed (claude has `ci-parity-prompt.md`) but the codex-side mirror has not (codex lacks the file). Run `scripts/check-prompt-parity.sh`; assert it exits non-zero AND its output identifies the drift as "expected lagging-mirror drift" (e.g. lists `ci-parity-prompt.md` as a known in-flight mirror) rather than a generic failure. The handoff gate documented for Phase 4 (`tests/parity/check-mirror-handoff.sh`) is what unblocks the script to expect clean parity.

**Mirror commit**: handled by codex-driven `/conduct` against this same plan. The extended `scripts/check-prompt-parity.sh` lands in the claude-side commit and will report parity drift until the codex-side mirror commit lands — that is expected during phased implementation and is verified end-to-end in Phase 4.

### Phase 4 — Acceptance and promote

**Impl files:** (none — verification phase)
**Test files:** `tests/parity/check-mirror-handoff.sh` (new scripted handoff gate; see below)
**Test command:** `bash tests/parity/check-mirror-handoff.sh && just check-prompt-parity && uvx pytest .claude/skills/conduct/tests/ -v && (cd .codex/skills/conduct && uv run --with pytest python -m pytest tests/ -q) && bash tests/parity/test-prompt-parity-extended.sh && scripts/promote-skills.sh && just check-sync`

**Handoff gate (must pass before any check/test below runs):** Block until both the claude-side and codex-side mirror commits have landed on the branch. The scripted gate `tests/parity/check-mirror-handoff.sh` parses `git log` and asserts that, for every phase `N ∈ {1, 2, 3}`, there exists at least one `conduct(phase N): ...` commit from each runtime (claude-driven and codex-driven), or an equivalent boundary commit from each runtime touching the corresponding `.claude/skills/conduct/` and `.codex/skills/conduct/` paths. The parity and sync checks below assume both runtimes have completed their phase work; running them earlier will spuriously fail on the lagging-mirror state — the scripted gate makes this concrete and CI-checkable rather than a manual paragraph.

- Verify mirror handoff by running `bash tests/parity/check-mirror-handoff.sh` first (script exits non-zero with a clear diagnostic if either runtime's phase commits are missing).
- Run `just check-prompt-parity`, the full Claude conduct test suite, the Codex conduct suite from a clean checkout, and `bash tests/parity/test-prompt-parity-extended.sh`. (Note: `just check-sync` is intentionally NOT first — it will report drift between repo and globals until `scripts/promote-skills.sh` runs.)
- **Pre-promote diff check.** Before `scripts/promote-skills.sh`, diff repo `.claude/skills/conduct/` vs global `~/.claude/skills/conduct/` and repo `.codex/skills/conduct/` vs global `~/.codex/skills/conduct/`. If either global has hand-edits not in repo, surface and confirm intent before promoting (which uses `rsync --delete`).
- Promote via `scripts/promote-skills.sh`.
- Run `just check-sync` as the final post-promote verification.
- **Codex test-equivalents manifest.** Add `tests/parity/codex-test-equivalents.txt` enumerating which Claude conduct tests must have Codex equivalents (one test name per line, grouped by area: progress-detector, autonomous-mode, ci-parity, schema-migration). `tests/parity/check-mirror-handoff.sh` asserts that the codex test count for the enumerated areas matches the claude test count (or that each named Claude test has a corresponding `_codex_equivalent` marker in the manifest).
- Update `docs/dev_plans/README.md` task table.
- Open the PR.

## Technical Specifications

### Files to modify

- `.claude/skills/conduct/SKILL.md` — Step 6 rewrite (stall-aware dual cap, helper-owns-increment invariant); Step 9 split; new "CI Parity Gate" section (detection priority, override, escape hatch, single-exit, four-sub-case result-file handling, lock-release contention, atomic-write protocol; conduct itself ensures `.conduct/` exists on dispatch — the orchestrator only writes the result file); State File section (v1/v2 schemas, unknown-≥1 forward-compat contract, `incompatible_with_pre_vN` hard-fail rule, plan_id derivation, Phase 1 known subset `{stall_signatures, stall_count, autonomous, plan_id}`); preflight section note about custom `--lint-check`; pre-commit-hook exemption note for impl commit during Phase 3.
- `.claude/skills/conduct/conductor.py` — `ConductOptions` extension; `ConductResult` already carries `next_action: Optional[str] = None` and `request: Optional[dict] = None` from commit `eb65eba` (Phase 1 codex mirror lands the codex-side equivalent); `_check_iteration_bound` helper (owns increment); centralised wiring at three call sites; explicit phase loop in `conduct()`; loader hard-fail on `incompatible_with_pre_vN`; `_dispatch_ci_parity_if_eligible` helper called from both exit points; `_consume_ci_parity_result` helper (shared by test and production paths); preflight branch for `awaiting_ci_parity` status (four sub-cases); `--skip-ci-parity` short-circuit; phase-start reset guard inside `_run_phase` (grep for the `current_phase_title` guard); `_handback` unchanged; `_persist_state` schema_version field; new dataclass `CIParitySpawnRequest`; `plan_id` derivation matches the existing `_state_path` `sha1(rel_to_repo_root)[:12]` convention. `_ensure_safe_conduct_dir` remains internal to conductor.py (used on the `awaiting_ci_parity` dispatch path) and is intentionally NOT part of the cross-runtime contract.
- `.claude/skills/conduct/progress.py` — new module, `iteration_signature` pure function, `compute_staged_diff_stat` helper (independently testable), module-import-time `--stat -w` probe with sticky fallback, stdlib-only.
- `.claude/skills/conduct/ci_parity.py` — new module, `detect_ci_entrypoint` function (workflows dropped), stdlib-only.
- `.claude/skills/conduct/ci-parity-prompt.md` — new subagent prompt.
- `.claude/skills/conduct/schema.py` — extend `parse_report` to accept `"ci-parity"` role.
- `.claude/skills/conduct/tests/conftest.py` — modify to add `LockAcquisitionCounter` test fixture (does not exist today).
- `scripts/check-prompt-parity.sh` — verified to check only `rubric.md` today; Phase 3 extends to also diff `*-prompt.md` across mirrors. Pre-implementation step verifies absence from pre-commit hook chain.
- `tests/parity/` — new directory (does not exist today); contains `test-prompt-parity-extended.sh`.
- `.codex/skills/conduct/*` — Codex-native remap of the same behavioural contract: same flags, state fields, report schema, progress/stall semantics, CI-parity handoff protocol, and tests; Codex dispatch, handback, resume/path-safety, and documentation wording remain harness-native.

### Integration seams

- **`progress.iteration_signature` pure function.** SHA-1 over canonical JSON. Stdlib only.
- **`progress.compute_staged_diff_stat` + module-level `_USE_STAT_W` probe.** Probe once at import; sticky; one-shot warning. Independently unit-testable.
- **`ci_parity.detect_ci_entrypoint` pure function.** Filesystem marker reads. Returns None for no-match.
- **`_check_iteration_bound` helper.** Single source of truth for `iteration_count += 1` AND the dual-cap-plus-stall check. Invoked from three call sites.
- **`_dispatch_ci_parity_if_eligible` helper.** Single source of truth for gate semantics, called from both autonomous post-loop and legacy non-autonomous complete branches.
- **`_consume_ci_parity_result` helper.** Single function shared by test-injection path (synchronous spawner) and production result-file path (preflight on re-invocation). Guarantees byte-identical state mutations across the two paths.
- **Per-phase subagent dispatch seam (unchanged).** `opts.spawn: Callable[[SpawnRequest], str]`.
- **CI-parity test-only dispatch seam.** `opts.ci_parity_spawn: Optional[Callable[[CIParitySpawnRequest], str]]`. None in production.
- **CI-parity result handoff file.** `<repo-root>/.conduct/ci-parity-result-<plan-id>.json`. Atomic write via tmp file + `os.rename` (see the `_safe_write_text` helper in conductor.py — grep for the symbol — for the pattern). Consumed file moved to `.consumed-<unix>.json` (not deleted). Conduct itself ensures `.conduct/` exists on the dispatch path; the orchestrator only writes the result file.
- **`plan-id` derivation.** `sha1(rel(plan_path, repo_root).encode()).hexdigest()[:12]`. Matches the existing `_state_path` convention (verified and adopted in Phase 1 pre-implementation step).
- **State schema versioning.** Loader treats absent as 1. Phases 1–2 write v1 with tolerated extras (`stall_signatures`, `stall_count`, `autonomous`, `plan_id`). Phase 3 writes v2. Unknown ≥1 reads known subset with one-shot warning. Forward-compat contract: future versions add only optional or safely-defaulted fields; required-semantics fields require an `incompatible_with_pre_vN: true` marker, which the loader hard-fails on (Phase 1 enforcement).
- **Codex mirror remap.** Codex changes preserve the shared contract while using Codex internals. Harness-neutral prompts remain parity-checked by the extended `just check-prompt-parity`; runtime-specific prose and dispatch code are reviewed as deliberate differences.

### Architecture decisions

- **Stall detection lives in the conductor.** Implementer is clean-context; conductor verifies progress structurally.
- **`_check_iteration_bound` owns the increment.** Pre-implementation audit records current increment positions; helper position chosen to preserve current semantics on all three paths.
- **Two flags + stall threshold.** `--max-iterations` default 3 preserves legacy; `--max-iterations-ceiling` default 8 provides autonomous runway; `--stall-threshold` default 2 sits between.
- **Schema bump deferred to Phase 3.** Phases 1–2 write v1 with tolerated extras. Unknown-≥1 forward-compat rule lands in Phase 1 with explicit contract.
- **Explicit phase loop under `--autonomous`.** Today's one-phase-per-call preserved when `opts.autonomous=False`.
- **Production CI-parity dispatch is main-runtime-orchestrated.** Conduct returns `ConductResult(status="awaiting_ci_parity", ...)`; the orchestrating runtime runs the worker, atomically writes result file, re-invokes `--resume`. Preflight handles four sub-cases (present-valid, stale, malformed, absent).
- **`_consume_ci_parity_result` is shared by test and production paths.** Eliminates drift risk between the two code paths.
- **Lock-release contention is defined behaviour.** Same-plan re-resume during `awaiting_ci_parity` follows the four-sub-case flow (idempotent); non-resume against this state hard-fails preflight.
- **Single-exit gate via shared `_dispatch_ci_parity_if_eligible` helper.** Same semantics regardless of how the plan was walked.
- **Workflows dropped from detection.** Not locally executable without `act`; soft-dep fall-through would be confusing.
- **Mirror responsibility is per-runtime.** Each runtime lands a single commit per phase boundary covering only its own mirror. Cross-runtime convergence is verified in Phase 4 via the handoff gate.
- **`scripts/check-prompt-parity.sh` extension is mandatory.** Codebase-claims verified it currently checks only `rubric.md`. Pre-commit-hook absence verified in Phase 3 pre-implementation step.
- **`plan-id` reuses existing state-file convention.** Avoids inventing a new derivation; reconciliation step verifies and adopts.

### Dependency versions

- Python 3.12.7 (system `python3`); stdlib-only across all new modules.
- `pytest` is the test runner; unpinned.
- `uv` 0.9.18; test invocation via `uvx pytest`.
- `just` 1.x; recipes `check-sync`, `check-prompt-parity` confirmed.
- `git` 2.54.0; supports `--stat -w`. Fallback exercised by `iteration-signature-stat-w-fallback` test.

## Testing Notes

Unit + integration + parity-script. New test directory `tests/parity/` created in Phase 3 (parent `tests/` exists). New test fixture `LockAcquisitionCounter` introduced in Phase 2 (does not exist today). Four-sub-case ci-parity result-file robustness tests cover crash recovery, malformed input, stale/mismatched plan_id, missing-with-retry-and-handback. `_consume_ci_parity_result` shared path asserted byte-identical across test and production. Forward-compat warning semantics asserted once-per-process and re-fire-after-resume; `incompatible_with_pre_vN` hard-fail asserted by `incompatible-with-pre-vn-loader-hard-fails`. `compute_staged_diff_stat` independently unit-tested (whitespace collapse on primary path, deterministic sort on fallback). `helper-is-single-increment-source-three-sites` proves the structural-invariant at all three call sites against the pre-implementation audit.

The repo has no workflow files under `.github/workflows/`; `ci-parity-skip-workflow-less` exercises the empty-detection case on a tmpdir fixture.

## Issues & Solutions

*(to be filled during implementation)*

## Acceptance Criteria

1. `/conduct <plan>` (no flags) is byte-identical in handback message and final state schema to today. Legacy default `--max-iterations 3` blocks both stalled (`legacy-max-iterations-default-3-stalled`) AND progressing (`legacy-max-iterations-default-3-progressing-also-blocks`) phases at iter 4.
2. **AC 2a (test-injection path)**: `/conduct --autonomous <plan>` walks a 3-phase fixture in a single invocation under exactly one lock acquisition when `ci_parity_spawn` is injected — `LockAcquisitionCounter == 1`. **AC 2b (production code-path)**: under the production result-file path, conduct releases the lock before returning `awaiting_ci_parity` and re-acquires on `--resume` consume, so `LockAcquisitionCounter == 2` and the gate still fires exactly once at end. Both variants end with 3 completed phases.
3. Stall detector blocks a stuck implementer at 2 matching signatures (3 helper calls; `iteration_count == 3`, `stall_count == 2`, blocker `stall_threshold exceeded`) even with `--max-iterations-ceiling 8`.
4. Hard ceiling `--max-iterations-ceiling 8` blocks continuously-progressing phase at `iteration_count == 9` with reason `max_iterations_ceiling exceeded`.
5. `_check_iteration_bound` is the only call site for `iteration_count += 1`. `helper-is-single-increment-source-three-sites` asserts the structural invariant at all three sites (`_run_phase` test-failure branch, `_run_phase` hook-failure branch, `_retry_after_hook_failure`) against the pre-implementation audit.
6. Rogue commit, validation-cmd failure, and schema error hand back in autonomous mode after the appropriate fix-loop routing.
7. ci-parity gate detects `Makefile ci:`, runs it, reports `passed`/`failed`. `--ci-cmd` override tested independently and in cross-product with `--autonomous`.
8. ci-parity gate skips with warning on workflow-less, target-less repo; status `complete` (not `ci_failed`).
9. ci-parity gate fires only at end-of-plan: `ci-parity-single-exit-no-fire-on-intermediate-resume-without-autonomous`, `ci-parity-single-exit-fires-once-with-autonomous`, `autonomous-ci-parity-not-fired-after-intermediate-phase` all pass.
10. ci-parity production dispatch is main-runtime-orchestrated with four-sub-case preflight: `ci-parity-result-file-present-and-valid-consumes`, `ci-parity-stale-result-file-rejected`, `ci-parity-stale-by-timestamp-result-file-rejected`, `ci-parity-malformed-result-file-handback`, `ci-parity-missing-result-file-at-resume-counter-increments` all pass. Result file is atomically written; consumed file moved to `.consumed-<unix>.json`.
11. Test/production code-path parity: `ci-parity-injection-and-result-file-paths-share-consume-code` asserts byte-identical state mutations across `_consume_ci_parity_result` invocations from both paths.
12. Lock-release contention: `ci-parity-resume-during-awaiting-without-result-file` (idempotent re-emit) and `ci-parity-non-resume-against-awaiting-hard-fails` (preflight hard-fail) both pass.
13. `--skip-ci-parity` escape hatch tested by `ci-parity-skip-ci-parity-flag-shortcuts-gate`.
14. State migration: `absent-schema-version-resumes-cleanly`, `explicit-schema-version-1-resumes-cleanly`, `v2-state-file-roundtrip`, `unknown-schema-version-99-resumes-with-warning`, `unknown-schema-version-warning-suppressed-on-second-load-same-process`, `unknown-schema-version-warning-refires-after-resume`, `incompatible-with-pre-vn-loader-hard-fails` all pass.
15. Stall history survives `--resume` mid-fix-loop (`stall-survives-resume`).
16. `just check-sync` (post-promote) and the extended `just check-prompt-parity` (now covering `*-prompt.md` for every managed skill) green after both runtime mirrors have landed. Phase 4's `tests/parity/check-mirror-handoff.sh` is the scripted gate enforcing convergence: it parses `git log` for `conduct(phase N): ...` commits from each runtime for every phase `N ∈ {1, 2, 3}` and exits non-zero if any are missing. The impl commit before each mirror commit deliberately leaves mirrors lagging; preflight is verified NOT to call `check-sync` and `phase-3-impl-commit-lands-with-hooks-enabled-in-intermediate-state` confirms the Phase-3 impl commit lands with hooks on even in the lagging-mirror state. Codex mirror acceptance also requires `(cd .codex/skills/conduct && uv run --with pytest python -m pytest tests/ -q)` to pass after the Codex-native remap.
17. `scripts/check-prompt-parity.sh` extension is verified by `tests/parity/test-prompt-parity-extended.sh`: `mirror-commit-required-after-impl`, `prompt-divergence-detected`, `ci-parity-prompt-included` all fail before the script update and pass after.
18. `compute_staged_diff_stat` independently unit-tested: `compute-staged-diff-stat-w-mode-whitespace-collapses` and `compute-staged-diff-stat-fallback-mode-deterministic-sort`. `max-phases-cap-respects-post-commit-count` confirms the loop's max_phases check reads a post-commit count.
19. Startup validator: `stall-threshold-greater-than-max-iterations-warns` (warning fires) AND `stall-threshold-greater-than-max-iterations-legacy-dominates` (legacy cap actually fires under the misconfiguration with the correct blocker).
20. **(manual doc-review gate)**: SKILL.md documents all new flags (`--autonomous`, `--max-iterations-ceiling`, `--stall-threshold`, `--no-progress-detection`, `--max-phases`, `--run-ci-parity`, `--ci-cmd`, `--skip-ci-parity`), state fields (`stall_signatures`, `stall_count`, `autonomous`, `plan_id`, `ci_parity_request`, `ci_parity_request_written_at`, `ci_parity_result`, `ci_parity_dispatched`, `ci_parity_missing_resume_count`, `schema_version`), helpers (`_check_iteration_bound`, `_dispatch_ci_parity_if_eligible`, `_consume_ci_parity_result`), the four-sub-case result-file protocol, the forward-compat contract, and bootstrap notes. A grep-based presence check can be added later if a CI-checkable variant is wanted.
21. **(manual review-skill runs)**: `/deep-review`, `/review`, `/security-review` clean on the final PR.

## Final Results

*(to be filled on completion)*
<!-- reviewed: 2026-05-13 @ ee5c0823f1fef3a9ec1290dccea98381ecb9ab8e -->
