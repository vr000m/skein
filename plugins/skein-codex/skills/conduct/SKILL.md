---
name: conduct
description: Walks a reviewed dev-plan phase by phase and delegates each phase's implementation, testing, and fix loop to clean-context subagents. Main Codex stays in a conductor role so context does not exhaust during multi-phase execution. Use when the user says "step through plan", "walk phases", "delegate phase implementation", "conduct plan", "run the plan", or invokes this skill directly with a dev-plan path.
argument-hint: "[path/to/plan.md] [--resume] [--status] [--pause-phase] [--abort-run] [--test-cmd CMD] [--test-timeout SECS] [--max-iterations N] [--autonomous] [--max-phases N] [--run-ci-parity] [--ci-cmd CMD] [--skip-ci-parity]"
---

# Conduct: Phased Delegation for Linear Implementation

Walk a reviewed dev-plan phase by phase. For each phase, spawn clean-context subagents (implementer + test-writer, and optionally a lightweight reviewer) to do the work. The conductor — main Codex running this skill — only reads structured JSON reports, routes failures through a bounded fix loop, commits at phase boundaries, and either hands back to the user between phases or continues through the remaining phases when `--autonomous` is set.

Subagent prompt templates live alongside this file:

- `implementer-prompt.md`
- `test-writer-prompt.md`
- `reviewer-prompt.md`
- `ci-parity-prompt.md`

Helper modules for preflight and state handling:

- `parser.py` — phase-heading regex, `Test command:` / `Validation cmd:` regexes, phase-overlap check.
- `marker.py` — review-marker regex, contract/workspace split, hash compute, staleness check.
- `lock.py` — `fcntl.flock` advisory lock with atomic-`mkdir` fallback and 1-hour stale-break.
- `schema.py` — last-fenced-block extraction + role-specific report validation (raises `SchemaError`). Stdlib only.
- `runner.py` — test-command subprocess wrapper with portable wall-clock timeout via a dedicated subprocess session plus explicit process-group termination. Returns `TestResult(returncode, output, timed_out, duration_seconds)`.
- `progress.py` — fix-loop progress signatures. It probes `git diff --cached --stat -w` once per process and falls back to sorted `--name-only` canonicalisation with a one-shot warning if local git rejects that flag combination.
- `ci_parity.py` — local CI entrypoint detection for the end-of-plan parity gate. Detection priority: `just ci`, `make ci`, `npm run ci`, `cargo test --all`; workflow files are intentionally not detected.

Deterministic tests under `tests/` (run via `uvx pytest plugins/skein-codex/skills/conduct/tests/ -v && bash plugins/skein-codex/skills/conduct/tests/test_skill_spawn_grep.sh`).

These helpers are a pure-Python library — there is no CLI entry point. Main Codex orchestrates the per-phase loop turn-by-turn per this SKILL.md: it calls helpers (preflight, phase parse, state read/write, pause/abort) for the pure-function steps, and invokes `spawn_agent`, `wait_agent`, and `close_agent` directly for each subagent lifecycle. Each worker must be spawned with `fork_context=false` so the filled template is the worker's entire context.

## Delegation Pattern

Delegation depth from this skill is exactly 1: conduct → workers. Workers never spawn further subagents. This skill is invoked directly by the user as a top-level skill, OR inside a Codex session spawned by `/fan-out` that re-baselines depth at the process boundary. It is never invoked as a worker subagent.

Subagents are spawned via `spawn_agent` with `fork_context=false`. Shared workspace — worktree isolation is the user's concern at the outer layer. Clean context comes from explicitly not forking the parent conversation, not from filesystem separation.

Codex-native role routing:
- Implementer: inherit the harness-selected model; request `reasoning_effort=medium` when supported. This is mechanical implementation of a reviewed phase.
- Test-writer: inherit the harness-selected model; request `reasoning_effort=medium` when supported. This is mechanical test authoring against the phase contract.
- Optional reviewer: inherit the harness-selected model; request `reasoning_effort=high` when supported. Code review is judgment work, so the advisory reviewer gets the review tier.

Do not use literal model names or a literal `reasoning:` field in these dispatches. Express the tier as the `reasoning_effort` request supported by the current Codex runtime, and always keep `fork_context=false`.

## Delegation Availability

Codex `/conduct` does **not** silently degrade into inline main-session implementation when delegated workers are unavailable. If the current runtime lacks `spawn_agent`, `wait_agent`, or `close_agent`, hard-stop with this message and do no phase work:

```text
Delegated subagents unavailable in this Codex runtime; the conduct skill requires spawn_agent, wait_agent, and close_agent support.
```

The user can then rerun `/conduct` in a Codex session with agent delegation support or execute the phase manually.

## Invocation

```
conduct <plan-path>
conduct --resume <plan-path>
conduct --status <plan-path>
conduct --pause-phase <plan-path>
conduct --abort-run <plan-path>
conduct --autonomous <plan-path>
```

### CLI flags

| Flag | Purpose |
|------|---------|
| `--resume` | Resume after a handback. Reads state, picks up at the next unfinished phase. |
| `--status` | Print the state file contents and exit. No git ops. |
| `--pause-phase` | `git stash push -u -m "conduct-pause-phase-<N>"`, record the created stash in state, mark phase as user-paused, exit. `--resume` restores that recorded stash before continuing. |
| `--abort-run` | Delete the state file for this plan once the state lock is free. If another `/conduct` run is active, exit non-destructively and tell the user to retry. No git ops, no stash. |
| `--test-cmd CMD` | Override the phase's `Test command:` slot and any repo default. |
| `--test-timeout SECS` | Wall-clock cap on the test-runner subprocess. Default 300. |
| `--max-iterations N` | Legacy fix-loop cap. Default 3. Preserves pre-autonomous behaviour. |
| `--max-iterations-ceiling N` | Progress-runway hard cap. Default 8. Blocks with `max_iterations_ceiling exceeded`. |
| `--stall-threshold N` | Consecutive matching-signature count that blocks with `stall_threshold exceeded`. Default 2. |
| `--no-progress-detection` | Disable stall blocking. Signatures remain inspectable in state. |
| `--autonomous` | Walk every unfinished phase in one conductor invocation under one state-lock acquisition. Hard-stops still hand back. Default off preserves one phase per `--resume`. |
| `--max-phases N` | Cap total completed phases during the run. Blocks with `max_phases ceiling hit (N)` when the completed-phase count reaches `N`. Unset resolves to `len(parsed_phases) + 1`, so a healthy full run does not hit the cap. |
| `--run-ci-parity` | Enable the end-of-plan CI-parity gate explicitly. Implied by `--autonomous`. |
| `--ci-cmd CMD` | Override CI entrypoint detection for the parity gate. |
| `--skip-ci-parity` | Short-circuit the parity gate. From `awaiting_ci_parity`, marks complete and preserves request/result files on disk. |

## Preflight

Before any phase runs, validate:

### 1. Plan path resolution

- If an argument is provided, use it.
- Else scan `docs/dev_plans/` for the most recently modified `.md` and use that.
- If no plan is found, tell the user and exit.

### 2. Review marker check

The plan MUST contain a marker line written by `/review-plan` after user acceptance:

```
<!-- reviewed: YYYY-MM-DD @ <sha1> -->
```

The marker acts as a **contract / workspace divider**. Everything above the marker is the immutable contract (objective, requirements, phase blocks, technical specs). Everything below is workspace — `## Progress` (per-phase completion), `## Findings` (durable notes), and similar. The hash covers the contract only, so editing the workspace during a run does NOT invalidate the marker.

- Match against regex `^<!-- reviewed: \d{4}-\d{2}-\d{2} @ [0-9a-f]{40} -->\s*$`. The last unfenced, column-zero match wins; marker-shaped text inside fenced code blocks or indented prose is ignored.
- The template-placeholder line `<!-- reviewed: YYYY-MM-DD @ <hash> -->` does **not** count as a real marker — a plan that still carries the placeholder is treated as unmarked and rejected. (`/review-plan` consumes the placeholder as the divider on first review and replaces it with the dated marker.)
- Recompute the plan's content hash: take the plan with the marker line and everything after it stripped, pipe to `git hash-object --stdin`. Compare to the SHA recorded in the marker. The strip is byte-faithful: the bytes above the marker line are hashed verbatim, including any blank line immediately above the marker and the original line endings (LF or CRLF); do not trim trailing blanks or normalize line endings before hashing, or a plan with a blank line before its marker (the common markdown style) would hash differently from what `/review-plan` wrote and report false staleness.
- If marker absent → hard-stop with: `Run: /review-plan <plan-path>` and exit.
- If hash mismatches (stale marker):
  - **Initial run** (no `--resume`): hard-stop with the same message. A stale marker before the first phase means the plan drifted between `/review-plan` and `/conduct`; re-review.
  - **`--resume`**: rewrite the marker in place with today's date and the new hash, log `conduct: review marker auto-refreshed on resume (was <iso> @ <old12>, now @ <new12>)` to stderr, and proceed. By construction workspace edits below the marker do not affect the hash, so a stale marker on resume always means a phase legitimately amended the contract section above the marker — refreshing preserves the divider invariant without forcing a re-review mid-run. State's `plan_content_hash` is resynced to the new value on the same load.

### 3. Optional pre-commit health check

Preflight does **not** automatically execute repo-defined lint entrypoints. If the caller explicitly supplies a lint/preflight check, run it and hard-stop on failure with: `Tree has pre-existing lint/hook failures; fix them before running this skill`.

### 4. State file load

`<repo-root>/.conduct/state-codex-<plan-stem>-<digest>.json`, where repo-root comes from `git rev-parse --show-toplevel` and `digest` is `sha1(repo-relative plan path)[:12]`. The matching lock is `<state-file>.lock`.

Older shared names (`state-<plan-stem>-<digest>.json` and `state-<plan-stem>.json`) are bootstrap-only/read-only. Codex may copy static plan metadata from them when creating its own runtime-specific state, but it must not write them and must not treat their completed phases as Codex-completed mirror work.

- If present and `--resume`: load only when `state.plan_path` still matches the current reviewed plan. Migrate/validate the stored state shape first, run the review-marker preflight, parse the phase list, and verify every stored `completed_phases[*].label/title` still matches the parsed phase prefix. Only after that prefix check may a refreshed marker resync `state.plan_content_hash`. On match, restore any recorded paused stash, continue from `phase_index`, and refresh `state.resume_base_sha = git rev-parse HEAD` so the rogue-commit check (Step 8) treats any user commits made during handback as the new phase baseline rather than as subagent commits.
- If present and the stored plan path/hash do not match the current reviewed plan after resume preflight resync: hard-stop and tell the user to `--abort-run` before starting over.
- If present without `--resume`: warn, print state summary, suggest `--resume` or `--abort-run`, exit without entering the phase loop.
- If absent: initialise with `plan_content_hash = compute_plan_hash(plan)`, `base_sha = git rev-parse HEAD`, `phase_index = 0`, `current_phase_title = ""`, `last_summary = ""`, `iteration_count = 0`, `stall_signatures = []`, `stall_count = 0`, `autonomous = false`, `plan_id = sha1(abs(plan_path))[:12]`, `state_author = "codex"`, `schema_version = 2`, `status = "running"`.

Acquire an advisory lock on the runtime-specific state lock before any write (see `lock.py` shipped with this skill).

### 5. Phase parsing

Parse phases from the `## Implementation Checklist` section with regex:

```
^###\s+Phase\s+(\S+?)\s*[:—–]\s*(.+?)\s*(\([^)]*\))?\s*$
```

Captures the phase label (e.g. `3` or `3a`) and title; strips trailing parenthesised annotations. The label/title separator may be a colon (`:`), em-dash (`—`), or en-dash (`–`) — LLM-authored plans often default to em-dash, so the parser tolerates all three rather than forcing a manual rewrite. Record each phase's 0-based document position (used as `phase_position` in reports) and verbatim label (used as `phase_label`).

Phase completion is sourced from the `## Progress` section below the marker. Each entry has the form `- [ ] Phase <label>: <title>` (or `- [x] ...` when done). The conductor reads this section to skip phases that have already finished. Old-format plans without a Progress section fall back to in-body checkbox state for backward compatibility.

If every unfinished phase omits every contract slot (`Impl files:`, `Test files:`, `Test command:`, `Validation cmd:`), continue in degraded mode but queue a one-shot warning for the first handback: the user should see that they lost parallel spawn and explicit test/validation wiring.

## Per-Phase Workflow

For each unfinished phase, execute steps 1–9. Acquire the state-file lock before any state mutation.

**On entering a new phase**: reset `state.iteration_count = 0` and persist before Step 1. The fix-loop cap is per-phase, not per-run; without this reset, phase N starts already counting iterations spent on phase N−1 and the cap fires prematurely.

### Step 1 — Parse phase contract

From the phase block, extract:

- `**Impl files:**` — comma-separated paths, globs allowed.
- `**Test files:**` — comma-separated paths, globs allowed.
- `` **Test command:** `<cmd>` `` — parsed with `^\*\*Test command:\*\*\s+\x60([^\x60]+)\x60\s*$`; first match wins; additional matches emit a warning.
- `` **Validation cmd:** `<cmd>` `` — optional, parsed with `^\*\*Validation cmd:\*\*\s+\x60([^\x60]+)\x60\s*$`; first match wins; additional matches emit a warning.
- `**Goal:**` — optional. A 1-2 line design-intent/invariant statement for the phase, sitting in the phase contract block alongside the slots above (above the review marker; editing it invalidates the marker like any other contract edit). Separator may be `:`, `—`, or `–`, matching the phase-heading tolerance. Captured verbatim (including embedded newlines for a 2-line goal) as `{{PHASE_GOAL}}`'s source text. Before inserting it into either worker prompt, escape every literal `</untrusted-content>` as `<\/untrusted-content>`; the templates wrap the escaped value in a warned, data-only `<untrusted-content>` block. Absent slot -> `{{PHASE_GOAL}}` substitutes to the empty string everywhere it is used (Step 3), preserving the byte-identical no-goal prompt form.

Any slot may be absent; see Fallbacks below.

### Step 2 — Parallel vs sequential decision

- If `Impl files:` and `Test files:` resolve to disjoint paths → parallel spawn.
- If they overlap (same file, or one is a subpath of the other) → sequential (implementer first, then test-writer).
- If either slot is missing → sequential (safe default).

Log the decision in the phase summary: `Spawn strategy: parallel` or `Spawn strategy: sequential (reason: file overlap | missing slot)`.

### Step 3 — Fill and spawn subagent prompts

Read `implementer-prompt.md`, extract the fenced ` ``` ` Template block, substitute placeholders:

| Placeholder | Value | JSON type concern |
|-------------|-------|-------------------|
| `{{PLAN_PATH}}` | absolute path | string |
| `{{PHASE_INDEX}}` | phase's 0-based position | substitute bare int (no quotes) |
| `{{PHASE_LABEL}}` | verbatim heading label | substitute JSON-escaped string |
| `{{PHASE_TITLE}}` | verbatim heading title | string (appears in prose, not JSON) |
| `{{PHASE_GOAL}}` | formatted design-intent directive built from the phase's `**Goal:**` slot, else empty string | string (appears in prose, not JSON) |
| `{{ITERATION}}` | current fix-loop iteration | substitute bare int (no quotes) |
| `{{BASE_SHA}}` | `git rev-parse HEAD` at phase start | string |
| `{{PRIOR_DIFF}}` | staged diff from previous attempt, else empty | string |
| `{{TEST_FAILURES}}` | redacted failure summary from the test runner or pre-commit hook, else empty | string |

`{{PHASE_GOAL}}` is substituted the same way on every implementer/test-writer spawn: first attempt (iteration 0) AND every fix-loop respawn (Step 6), since it is re-read from the same phase contract block on each respawn - it is not carried over from a prior iteration's prompt. When the phase's `**Goal:**` slot is present, substitute the warned data-block directive described in `implementer-prompt.md` / `test-writer-prompt.md`, after escaping its closing marker; when absent, substitute the empty string so the sentence the placeholder is appended to renders byte-identical to a plan with no `**Goal:**` slot.

Same pattern for `test-writer-prompt.md` (placeholders: plan path, phase index, phase label, phase title, phase goal, base sha, existing-tests summary) and `reviewer-prompt.md` (plan path, phase index, phase label, phase title, diff).

Spawn via `spawn_agent` with the filled template as the worker's full `message`, `fork_context=false`, and a worker-oriented agent type. Request `reasoning_effort=medium` for both the implementer and test-writer when supported. In parallel mode, spawn implementer and test-writer back-to-back, then use `wait_agent` to await whichever completes first until both have returned final output. After each worker reaches a terminal status, call `close_agent` to clean it up.

### Step 4 — Await both, parse reports

Each subagent returns a final fenced ` ```json ` block. Parse rules:

- **Anchor on the LAST fenced `json` block** in the output, not the first. The plan or prompt body may contain schema examples; only the terminal block is the report.
- Validate via `schema.parse_report(text, expected_role)` — this performs the last-block extraction, JSON parse, and role-specific schema check. Required top-level keys: `role`, `phase_position`, `phase_label`, `iteration` for impl/test roles, plus role-specific fields (`findings` for reviewer; `files_changed`/`summary` for implementer; `test_files_added`/`test_commands`/`coverage_summary` for test-writer; for ci-parity: `schema_version`, `plan_id`, `request_written_at_unix`, `status` — `"passed"` or `"failed"` — and `command_run`). For implementer and test-writer the `flags` object is also validated by key: implementer must emit `blocked` (bool), `test_contract_mismatch` (bool), `needs_test_coverage` (list); test-writer must emit `blocked` (bool) and `needs_impl_clarification` (string or null). Reviewer and ci-parity do not emit `flags`. Extra keys (top-level or inside `flags`) are allowed so prompts can evolve without breaking older conductors.
- If `parse_report` raises `SchemaError` → set `state.status = "schema_error"`, record which subagent failed, the error message, and the raw output tail in state, handback to the user. Do NOT respawn. A clean-context respawn cannot consume "your last output was malformed" because the fresh subagent has no memory of the prior attempt.
- If a worker report sets `flags.blocked = true`, or a test-writer reports `needs_impl_clarification`, persist `state.status = "blocked"` with the worker's explanation and hand back immediately. Do not run tests or commit staged changes after an explicit worker blocker.

### Step 5 — Run tests

Resolve the test command in order:

1. `--test-cmd` CLI flag.
2. Phase's `**Test command:**` line.
3. Repo default: `package.json` `scripts.test`, `pyproject.toml` `[tool.pytest.ini_options]`, or `Makefile` `test` target.
4. None available → emit warning, skip tests, still run Step 5b if a `Validation cmd:` is present, then proceed to Step 8 (commit boundary).

Run the resolved command via `runner.run_tests(cmd, timeout=<secs>)` (`--test-timeout`, default 300). The runner starts the test command in its own subprocess session and, on timeout, terminates the full process group so behaviour is identical on Linux and macOS without depending on GNU coreutils `timeout`. On timeout the runner kills the process group, sets `timed_out = True`, and the conductor treats the result as a fix-loop failure with the killed-by-timeout note appended to the captured output.

On non-zero exit → Step 6. On zero exit → Step 5b (if a validation command is present), else Step 7.

### Step 5b — Optional validation command

If the phase declares a `**Validation cmd:**` slot, run it via the same `runner.run_tests` subprocess wrapper after tests pass. If Step 5 skipped tests because no test command was available, still run validation before the boundary commit. Semantics differ from Step 5 in two ways:

1. **No fix loop on failure.** A non-zero exit or timeout sets `state.status = "awaiting_user"` with `state.blocker = "Phase <label> validation failed"`, persists the blocker state, and hands back with the last 2000 bytes of validation output as the diagnostic. Validation failures do not append a completed-phase entry and do not create a third `commit_sha: null` state branch.
2. **Same trust boundary as Test command.** The plan author chose this shell command. Review it with the same care as `Test command:` before you run `/conduct`.

On zero exit, append `"validation passed"` to the phase warnings and continue to Step 7.

### Step 6 — Fix loop (stall-aware dual cap)

No classifier. On any failure (test failure OR pre-commit hook failure at the boundary commit in Step 8):

- Compute `progress.iteration_signature(failing_tests, staged_diff_stat)` before incrementing. Test failures use sorted pytest `FAILED <nodeid>` lines. Hook failures use sorted pre-commit hook ids such as `ruff` or `ruff-format`; parse failure falls back to `[]`.
- `staged_diff_stat` comes from `progress.compute_staged_diff_stat(repo_root)`, using `git diff --cached --stat -w` when available and sorted `git diff --cached --name-only` otherwise. The probe decision is sticky for the Python process.
- `_check_iteration_bound(state, opts, signature)` is the single source of truth for `state.iteration_count += 1`. The three fix-loop entry points call it after the failure is observable: `_run_phase` test failure, `_commit_phase` hook failure, and `_retry_after_hook_failure` test failure after hook retry.
- Helper block priority: `stall_threshold exceeded`, then `max_iterations_ceiling exceeded`, then `max_iterations exceeded (legacy)`.
- Persist state immediately after the helper returns (crash recovery; stall counters survive `--resume`).
- Else capture `git diff --cached` into `{{PRIOR_DIFF}}`. Normally then run `git reset` (mixed, no `--hard`) to clear the staging area so the respawned implementer starts from a clean index with the prior diff visible only inside its prompt.
- Respawn the implementer with `{{ITERATION}}` = new count, `{{PRIOR_DIFF}}` = the captured diff, `{{TEST_FAILURES}}` = a redacted failure summary (or pre-commit hook summary, if the failure came from the boundary commit). Use `spawn_agent` with `fork_context=false`, then `wait_agent` and `close_agent` for the lifecycle; request `reasoning_effort=medium` when supported.
- Exception: if the previous implementer report set `flags.test_contract_mismatch: true`, respawn the **test-writer** instead on this iteration and keep the previously staged implementation diff in the index so the follow-up commit can still include the original implementation work plus the newly staged tests. Reset the flag handling for the iteration after that (respawn implementer again unless the next report flips the flag again). Use the same `fork_context=false` lifecycle and `reasoning_effort=medium` request.

### Step 7 — Optional mid-phase reviewer (one-shot)

Trigger conditions: staged diff > 200 lines, OR > 3 files touched, OR phase tagged high-risk in the plan's Review Focus section. If triggered, spawn one reviewer subagent using `reviewer-prompt.md` with `{{DIFF}}` = staged diff. Use `spawn_agent` with `fork_context=false`, request `reasoning_effort=high` when supported, then `wait_agent` and `close_agent` for the lifecycle. Log findings into the phase summary. Never loop the reviewer. Findings do not block phase completion — the conductor is advisory here, not gating.

### Step 8 — Phase-boundary commit

After tests pass (or were skipped with warning):

1. **Rogue-commit check.** Compare `git rev-parse HEAD` to the phase-start baseline: `state.resume_base_sha` if this run started from `--resume`, otherwise `state.base_sha` (for phase 1) or the last completed phase's `commit_sha`. If HEAD advanced beyond the baseline _during this phase's subagent work_, a subagent committed despite the prompt directive. Do NOT stack another commit. Record `rogue_commit_sha` in the phase summary, set `state.status = "awaiting_user"` with a warning, handback. (User commits made during a previous handback are absorbed into `resume_base_sha` at preflight, so they do not trip this check.)
2. Otherwise run `git commit -m "conduct: phase <label> — <phase title>"`. Commit author = current git user (no impersonation).
3. If the pre-commit hook fails, first check whether the hook modified files in-place (formatters like black, ruff --fix, prettier). Only auto-restage when every modified tracked file is already in the original staged pathset for this phase; in that case, run `git add -u -- <staged-paths...>` and retry the commit **once** in-place with the same message. If the retry succeeds, append the warning `pre-commit hook modified files; re-staged and retrying` to the phase warnings and continue at step 4 as a normal success. If the hook modified tracked files outside the original staged pathset, hand back to the user instead of auto-staging unrelated edits. If the retry fails, or if the hook did not modify files, route the hook output back into Step 6 as a fix-loop iteration. Do NOT use `--no-verify`.
4. On success, record the new `HEAD` SHA in `state.completed_phases[*].commit_sha`. This field is immutable once written. If the user lands follow-up commits during handback, or the automated review-gauntlet auto-chain below lands one or more fix commits after the terminal phase boundary, the next `--resume` absorbs them into `resume_base_sha`; it does not rewrite the prior phase's `commit_sha`.

Pre-commit hook scope: `scripts/check-prompt-parity.sh` is invoked from `justfile` recipes only, not from `.pre-commit-config.yaml` or the hook chain. Codex mirror work can therefore land while shared prompt-parity assets are handled in their separate boundary. Contributors invoking `just check-prompt-parity` during a lagging-mirror window can pass `CONDUCT_LAGGING_MIRROR_OK="<skill>/<prompt-file>"` to get a green exit with a stderr annotation.

### Step 9 — Phase Transition

Step 9 has two branches: the ordinary success transition and hard-stop handback. The ordinary branch is mode-aware; hard-stops hand back regardless of `--autonomous`.

#### Step 9a — Successful Phase Boundary

After a phase boundary commit completes:

1. **Legacy mode (no `--autonomous`)**: print the structured phase summary and literal next-command line, set `state.status = "awaiting_user"`, persist state, release the lock, and exit. This preserves one phase per resume invocation.
2. **Autonomous mode (`--autonomous`)**: persist the completed phase, keep the state lock held, skip the handback summary, and continue the explicit phase loop with the next unfinished phase. A clean autonomous run acquires the state lock once for the whole phase walk.

The conductor checks `--max-phases` after each successful boundary by reading the post-commit `len(state.completed_phases)`. If the count reaches the cap, set `state.status = "blocked"` with blocker `max_phases ceiling hit (N)`, persist, release the lock, and hand back.

#### Step 9b — Hard-Stop Handback

Hard-stops include:

- Rogue commit.
- Worker schema error.
- Worker-reported blocker.
- Validation command failure.
- Stall-threshold hit.
- `max_iterations_ceiling` hit.
- Legacy `max_iterations` hit.
- `max_phases` cap hit.

On any hard-stop:

1. Print a structured phase summary:
   - Phase label and title
   - Files changed
   - Spawn strategy (parallel | sequential)
   - Test result (passed | skipped-with-warning | n/a)
   - Iterations used
   - Mid-phase reviewer findings if any
   - Any warnings (rogue commit, missing test command, skipped tests)
2. Print the literal next command, on its own line:
   ```
   Run: /conduct --resume <plan-path>
   ```
3. Set `state.status = "awaiting_user"` or the terminal hard-stop status (`blocked` / `schema_error`), persist, release lock, exit the skill.

No keyword heuristic watches for "proceed" — the user copies the printed command when ready.

## CI Parity Gate

After the final phase boundary commit, the conductor can dispatch a one-shot CI-parity gate that runs the repo's local CI entrypoint against the working tree. The gate fires only when `conduct()` would otherwise return `status=complete`; it never runs after an intermediate phase. The persisted `ci_parity_dispatched` flag prevents re-dispatch after a result is consumed.

### Activation

- `--autonomous` implies the gate.
- `--run-ci-parity` enables the gate on legacy one-phase-per-resume runs.
- `--skip-ci-parity` marks the run complete with a skip summary. If state is already `awaiting_ci_parity`, it preserves the existing `ci_parity_request` and any result file on disk.

### Detection Priority

Detection is local-only:

1. `just ci` from a `justfile` or `Justfile` with a `ci` recipe.
2. `make ci` from a `Makefile` with a `ci:` target.
3. `npm run ci` from a `package.json` with a `"ci"` script.
4. `cargo test --all` when `Cargo.toml` exists at repo root.

`--ci-cmd CMD` overrides detection. Workflow files under `.github/workflows/` are intentionally not detected because running them locally requires extra tooling and ambiguous environment setup. If no entrypoint is detected and no override is provided, conduct blocks with `ci-parity entrypoint not detected; pass --ci-cmd or --skip-ci-parity`.

### Main-Runtime Dispatch Protocol

Conduct does not call runtime tools from inside `conductor.py`. At end of plan, `_dispatch_ci_parity_if_eligible` sets `state["status"] = "awaiting_ci_parity"`, writes `ci_parity_request`, `ci_parity_request_written_at`, and `ci_parity_missing_resume_count`, persists state, then returns `ConductResult(status="awaiting_ci_parity", next_action="dispatch_ci_parity", request=<dict>)`.

The main Codex runtime orchestrator executes `request["ci_cmd"]` directly from `request["repo_root"]`, captures the numeric exit code, duration, and combined output, derives `status` from the exit code (`0` → `passed`, non-zero/timeout/error → `failed`), then writes the JSON result to `<repo-root>/.conduct/ci-parity-result-<plan-id>.json` by calling `_write_ci_parity_result(path, payload_text)`. An LLM worker may summarize already-captured output, but it must not be the authority for pass/fail. The write adapter validates the target as a direct child of `.conduct/`, then delegates to `_atomic_write_result_file`, which uses `mkstemp`, `fsync`, and `os.replace`. `_safe_write_text` is reserved for state files; it must not be used for CI-parity result persistence because a partial result write would be read as malformed JSON on resume.

### Five-Sub-Case Resume Preflight

When state is `awaiting_ci_parity`, resume checks the result file:

1. Present, regular non-symlink file, valid, `plan_id` matches, `request_written_at_unix` matches, `command_run` matches the requested `ci_cmd`, and mtime from the same opened file descriptor is not older than `ci_parity_request_written_at`: consume via `_consume_ci_parity_result`; `passed` becomes `complete`, `failed` becomes `ci_failed`; move the file to `ci-parity-result-<plan-id>.consumed-<unix>.json`.
2. Present but stale by mtime, mismatched `plan_id`, mismatched `request_written_at_unix`, or mismatched `command_run`: ignore it, reset `ci_parity_missing_resume_count`, and re-emit `awaiting_ci_parity` with the same request.
3. Present but unreadable, symlink/non-regular, over the size cap, malformed, or schema-invalid: set `schema_error` with blocker `ci-parity result file malformed/unreadable at <path>` and preserve the file.
4. Active file absent but a matching `.consumed-<unix>.json` has the same `plan_id`, `request_written_at_unix`, and `command_run`: recover by calling `_consume_ci_parity_result` on the consumed file and skip the move.
5. Active file absent and no matching consumed file exists: increment `ci_parity_missing_resume_count`; after 3 consecutive absent observations, block with `ci-parity result file missing after 3 resume attempts; pass --skip-ci-parity to abandon gate`.

The missing counter resets to 0 on any non-absent outcome: consume, stale-ignore, malformed, or consumed-file recovery. A non-`--resume` invocation against `awaiting_ci_parity` hard-fails with `state shows awaiting_ci_parity; use --resume to consume the ci-parity result or --skip-ci-parity to abandon the gate`.

### Test/Production Parity

Tests may inject `opts.ci_parity_spawn`, which returns CI-parity JSON synchronously. Production uses the result-file handoff from direct main-runtime command execution. Both paths parse `schema.parse_report(..., "ci-parity")`, validate the report against the conductor request, and call `_consume_ci_parity_result`, so the state mutation path is shared.

## Review Gauntlet Auto-Chain

After the CI-parity gate resolves (or is skipped/not activated), at the point where conduct would otherwise set `status = complete`, read the plan's `**Review Gates:**` header field (values `none | quick | full`, default `none`) and decide whether to auto-chain `review-gauntlet`.

### Activation

- **Strictly opt-in.** Absent field or `none`: no `review-gauntlet` invocation, no additional dispatch, and no change to `status`.
- **`quick` -> invoke `review-gauntlet --plan <this plan>` scoped to Codex gate 1 only**, a single native code-review pass with no convergence loop.
- **`full` -> invoke `review-gauntlet --plan <this plan>` through the Codex gate matrix**, with native supported gates run and unsupported/gated slots reported explicitly as `deferred` or `skipped`; do not claim Claude command parity for missing `/security-review` or `/codex:adversarial-review` commands.

### Trigger point

- This is a single-exit hook, same shape as the CI-parity gate: it fires only on the healthy path where `conduct()` would otherwise return `status=complete` - after the CI-parity gate has passed, been skipped (`--skip-ci-parity`), or was never activated. It never fires on an intermediate `--resume`.
- It does not fire on any hard-stop path or on `ci_failed`. If the CI-parity gate reports `failed`, `status` stays `ci_failed` and conduct hands back per the normal rules; `review-gauntlet` is not consulted.

### Dispatch

- `review-gauntlet` is a conductor in its own right. Its supported review gates run at its own top level, in its own context, and only its fixer batch uses a clean-context Codex subagent. Conduct therefore invokes `review-gauntlet` directly as a top-level skill, the same way a human operator would run it. This is not a `spawn_agent` worker from Step 3/Step 7, and it is not routed through the CI-parity result-file dispatch protocol.
- Codex's delegation-availability hard stop still applies. If the current runtime lacks `spawn_agent`, `wait_agent`, or `close_agent`, do not inline the gauntlet or its fixer in the main session; hard-stop with the delegation-unavailable message above and hand back.
- If `review-gauntlet` itself hands back a non-clean terminal state (`success_with_quarantine`, loop cap, or non-convergence/design-conflict halt), conduct surfaces that as its own handback: `status = "awaiting_user"` with blocker text from the gauntlet terminal report. A non-clean gauntlet outcome is never silently folded into `complete`.

### Commit ownership at the terminal seam

`review-gauntlet` runs strictly after the final phase's boundary commit, which has already frozen that phase's `commit_sha` as immutable. If the gauntlet applies fixes, it lands them as one or more commits on the working branch over the course of its loop — never a follow-up PR.

- conduct treats those commits exactly as any other follow-up commits landed during handback: the next `--resume` preflight refreshes `state.resume_base_sha = git rev-parse HEAD`, folding the gauntlet's commits into the new baseline for the rogue-commit check.
- conduct does not rewrite any completed phase's frozen `commit_sha` to account for the gauntlet's commits, and does not treat the gauntlet's commits as rogue. The rogue-commit check only fires on HEAD movement observed during a phase's subagent work; the gauntlet runs after the last phase boundary, outside every phase's subagent window.

## Fallbacks

- Missing `Impl files:` / `Test files:` → sequential spawn (Step 2).
- Missing `Test command:`, no repo default, no `--test-cmd` → warn, skip tests for the phase, flag in handback summary (Step 5).
- Missing every contract slot across every unfinished phase → continue, but emit the degraded-mode warning on the first handback (phase parsing + Step 9).
- Missing Testing Notes entirely → same as above; phase completes on implementer-only success with the skip flag.
- Delegated subagents unavailable → hard-stop with the explicit delegation-unavailable message above. Do not inline the phase in the main session.
- Plan has zero unfinished phases → dispatch the CI-parity gate if `--run-ci-parity`, `--autonomous`, or `--skip-ci-parity` applies; otherwise print `All phases complete` and exit.

## State File

Path: `<repo-root>/.conduct/state-codex-<plan-stem>-<digest>.json`, where `digest` is `sha1(repo-relative plan path)[:12]`. `.conduct/` is git-ignored. Renaming a plan changes both the stem and the digest, and conduct does not discover or atomically migrate the old state file. Do not auto-resume a renamed plan from old state: abort/close the old run before starting a new run. Never reuse the old `plan_id` or CI-parity request/result bindings; start the new run with a fresh state namespace and fresh CI-parity request/result.

Schema:

```json
{
  "schema_version": 2,
  "plan_path": "docs/dev_plans/20260422-feature-conduct-skill.md",
  "plan_content_hash": "<sha1 of plan with marker stripped>",
  "base_sha": "<git sha before phase 1>",
  "resume_base_sha": "<git sha at the start of this --resume invocation; absent on first run>",
  "phase_index": 3,
  "current_phase_title": "...",
  "completed_phases": [
    { "index": 1, "label": "1", "title": "...", "commit_sha": "...", "tests": "passed", "iterations": 1 }
  ],
  "last_summary": "...",
  "iteration_count": 0,
  "stall_signatures": [],
  "stall_count": 0,
  "autonomous": false,
  "plan_id": "<sha1(abs(plan_path))[:12]>",
  "state_author": "codex",
  "ci_parity_request": null,
  "ci_parity_request_written_at": null,
  "ci_parity_result": null,
  "ci_parity_dispatched": false,
  "ci_parity_missing_resume_count": 0,
  "status": "awaiting_user | running | paused | blocked | schema_error | complete | awaiting_ci_parity | ci_failed",
  "blocker": null,
  "paused_stash_rev": "<stash commit sha recorded by --pause-phase, or null>"
}
```

Unknown fields are ignored by the current algorithm and preserved on write. Codex writes `schema_version = 2`.

Loader compatibility:

- Missing `schema_version` is treated as `1`.
- Known versions `1` and `2` load normally and are rewritten as the current Codex schema on the next save.
- Unknown integer versions `>=1` load the known subset, preserve unknown fields for round-trip, and emit one one-shot warning: `state file written by newer schema_version=<n>; reading known fields only`.
- `incompatible_with_pre_vN: true` or any positive integer hard-fails with `state file requires a newer conduct loader (incompatible_with_pre_vN=<value>); upgrade the conduct skill or remove the state file to start fresh`. `false` and `0` pass.

Progress fields:

- `stall_signatures` stores the last two fix-loop signatures.
- `stall_count` counts consecutive matching signatures for the current phase.
- `autonomous` records whether autonomous mode was requested. Once a state file records `true`, later resumes preserve that fact even if the immediate invocation omits `--autonomous`; the current invocation flag still controls whether the process continues past the next successful boundary.
- `plan_id` uses `sha1(abs(plan_path))[:12]` for future cross-runtime handoffs and is intentionally distinct from the state-file digest.
- `state_author` is `"codex"` for Codex-owned runtime state.
- `ci_parity_request` stores `{plan_path, base_sha, head_sha, ci_entrypoint_kind, ci_cmd, repo_root, plan_id, request_written_at_unix}` for an in-flight gate.
- `ci_parity_request_written_at` is the dispatch timestamp used for result-file stale checks.
- `ci_parity_result` stores the parsed CI-parity report after consume.
- `ci_parity_dispatched` suppresses duplicate gate dispatch after consume or skip.
- `ci_parity_missing_resume_count` counts consecutive absent-result resume observations and resets on any non-absent outcome.

Helpers cited by the state contract: `_check_iteration_bound`, `_dispatch_ci_parity_if_eligible`, `_consume_ci_parity_result`, `_write_ci_parity_result`, `_atomic_write_result_file`, and `_compute_cross_runtime_plan_id`.

Forward-compat contract: future `schema_version` values must add only optional fields or fields with safe defaults for older readers. Required-semantics additions must set `incompatible_with_pre_vN: true`, which older loaders hard-fail. Runtime ownership is represented by the runtime-specific state filename plus `state_author`, not by `schema_version`.

### Locking

- Primary: `lock.py` acquires `fcntl.flock` on `<state-file>.lock` fd.
- Fallback if Python is unavailable: atomic `mkdir <state-file>.lockdir`.
- Flock-backed lockfiles are never broken by age alone. For the fallback `mkdir` lockdir path, stale lockdirs older than 1 hour are broken only when the recorded pid is missing or dead.
- `flock(1)` is NOT used — unavailable by default on macOS.
- Two `/conduct` invocations on the same plan in the same worktree race on the same lock. Sibling worktrees resolve to distinct repo-roots via `git rev-parse --show-toplevel` and therefore distinct state files.

## Trust Boundary

**The plan's `Test command:` and `Validation cmd:` slots are executed as shell commands** (via `runner.run_tests` with `shell=True`). Running `/conduct` on a plan is therefore equivalent in trust to running `make test`, `npm test`, or `cargo test` on a branch you checked out — the plan author chooses what gets executed.

Treat a dev plan received from someone else (a teammate's branch, an external PR, a forwarded file) the same way you'd treat a `Makefile` or `package.json` from that source: read it before running. Preflight validates the review marker to confirm the plan hasn't drifted since it was reviewed, but the marker is a content hash, not a cryptographic signature of the reviewer — it does not attest that anyone trustworthy approved the command.

If you need a stronger guarantee, review the phase `Test command:` and `Validation cmd:` lines before running `/conduct`, or override with `--test-cmd <your-own-cmd>` to ignore the test slot entirely.

## Known Limitations

- **No hard worker wall-clock timeout.** `wait_agent` lets the conductor stop waiting, but it does not provide a portable kill-on-timeout primitive for delegated workers. Mitigated by the fix-loop cap plus explicit iteration counts in prompts. Test-runner timeout is real because the test command is a subprocess.
- **Rogue commits are detected, not prevented.** Subagents are instructed to stage only; a subagent that runs `git commit` anyway is caught by the HEAD-comparison check in Step 8, flagged in state, and handed back to the user rather than auto-corrected.
- **Schema errors do not retry.** A subagent that emits malformed JSON triggers `schema_error` status and immediate handback. The user decides whether to adjust the prompt template or re-invoke.

## Integration Points

- **Plan format**: `/dev-plan` owns the template. Phases need `**Impl files:**`, `**Test files:**`, and `` **Test command:** `<cmd>` `` slots in the contract section above the marker; `**Validation cmd:**` is optional for post-test checks that should hand back on failure. Per-phase progress lives in a `## Progress` section below the marker.
- **Review marker**: `/review-plan` writes the marker line after user acceptance. The marker divides the plan into immutable contract (above, hashed) and editable workspace (below, not hashed). This skill consumes the marker as the readiness signal.
- **Fan-out**: a `/fan-out`-spawned Codex session may invoke `/conduct` as its top-level skill; `/conduct` itself does not fan out.
