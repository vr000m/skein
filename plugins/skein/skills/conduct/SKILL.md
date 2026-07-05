---
name: conduct
description: Walks a reviewed dev-plan phase by phase and delegates each phase's implementation, testing, and fix loop to clean-context subagents. Main Claude stays in a conductor role so context does not exhaust during multi-phase execution. Use when the user says "step through plan", "walk phases", "delegate phase implementation", "conduct plan", "run the plan", or invokes this skill directly with a dev-plan path.
argument-hint: "[path/to/plan.md] [--resume] [--status] [--pause-phase] [--abort-run] [--test-cmd CMD] [--test-timeout SECS] [--max-iterations N] [--max-iterations-ceiling N] [--stall-threshold N] [--no-progress-detection] [--autonomous] [--max-phases N] [--run-ci-parity] [--ci-cmd CMD] [--skip-ci-parity]"
---

# Conduct: Phased Delegation for Linear Implementation

Walk a reviewed dev-plan phase by phase. For each phase, spawn clean-context subagents (implementer + test-writer, and optionally a lightweight reviewer) to do the work. The conductor — main Claude running this skill — only reads structured JSON reports, routes failures through a bounded fix loop, commits at phase boundaries, and hands back to the user between phases.

Subagent prompt templates live alongside this file:

- `implementer-prompt.md`
- `test-writer-prompt.md`
- `reviewer-prompt.md`

Helper modules for preflight and state handling:

- `parser.py` — phase-heading regex, `Test command:` regex, phase-overlap check.
- `marker.py` — review-marker regex, contract/workspace split, hash compute, staleness check.
- `lock.py` — `fcntl.flock` advisory lock with atomic-`mkdir` fallback and 1-hour stale-break.
- `schema.py` — last-fenced-block extraction + role-specific report validation (raises `SchemaError`). Stdlib only.
- `runner.py` — test-command subprocess wrapper with portable wall-clock timeout via `subprocess.run(timeout=...)`. Returns `TestResult(returncode, output, timed_out, duration_seconds)`.
- `progress.py` — fix-loop progress signatures. Probes `git diff --cached --stat -w` once per process and falls back to sorted `--name-only` canonicalisation with a one-shot warning if local git rejects that flag combination. Stdlib only.
- `ci_parity.py` — local CI entrypoint detection for the end-of-plan parity gate. Detection priority: `just ci`, `make ci`, `npm run ci`, `cargo test --all`; workflow files are intentionally not detected (not locally executable). Stdlib only.
- `fileutil.py` — filesystem primitives: `atomic_write_result_file` (crash-safe write via `tempfile.mkstemp` + `os.replace`, used by the ci-parity result-file path), `validate_plan_id` (canonical 12-char lowercase-hex shape check), `ensure_under_directory` (resolved-path containment guard). Stdlib only.

Deterministic tests under `tests/` (run via `uvx pytest .claude/skills/conduct/tests/ -v && bash .claude/skills/conduct/tests/test_skill_spawn_grep.sh`).

These helpers are a pure-Python library — there is no CLI entry point. Main Claude orchestrates the per-phase loop turn-by-turn per this SKILL.md: it calls helpers (preflight, phase parse, state read/write, pause/abort) via `python3 -c ...` in Bash for the pure-function steps, and invokes the `Agent` tool directly for each subagent spawn. The `Agent` spawn loop cannot be driven from Bash because the tool is synchronous within the parent turn.

## Delegation Pattern

Delegation depth from this skill is exactly 1: conduct → workers. Workers never spawn further subagents. This skill is invoked directly by the user as a top-level skill, OR inside a subprocess spawned by `/fan-out` that re-baselines depth at the process boundary. It is never invoked as an `Agent` subagent.

Subagents are spawned via the `Agent` tool with `subagent_type: general-purpose`. Shared workspace — worktree isolation is the user's concern at the outer layer. Clean context comes from the `Agent` tool's default behaviour (no parent conversation history), not from filesystem separation. Tiers per the two-tier policy (`AGENTS.md` Model/Effort Policy): implementer and test-writer are mechanical → `model: sonnet, effort: medium`; the advisory reviewer (Step 7) is judgment work → `model: opus, effort: high`.

## Invocation

```
conduct <plan-path>
conduct --resume <plan-path>
conduct --status <plan-path>
conduct --pause-phase <plan-path>
conduct --abort-run <plan-path>
```

### CLI flags

| Flag | Purpose |
|------|---------|
| `--resume` | Resume after a handback. Reads state, picks up at the next unfinished phase. |
| `--status` | Print the state file contents and exit. No git ops. |
| `--pause-phase` | `git stash push -u -m "conduct-pause-phase-<N>"`, mark phase as user-paused, exit. State lives; `--resume` picks up. |
| `--abort-run` | Delete the state file and any stale lockfile/lockdir for this plan. No git ops, no stash. The more-destructive flag has the more-explicit name. |
| `--test-cmd CMD` | Override the phase's `Test command:` slot and any repo default. |
| `--test-timeout SECS` | Wall-clock cap on the test-runner subprocess. Default 300. |
| `--max-iterations N` | Legacy fix-loop cap. Default 3. Preserves pre-autonomous behaviour. |
| `--max-iterations-ceiling N` | Autonomous-runway hard cap. Default 8. Blocks with `max_iterations_ceiling exceeded` when exceeded. |
| `--stall-threshold N` | Consecutive matching-signature count that blocks the fix loop with `stall_threshold exceeded`. Default 2. With N=2, signature 1 → stall_count=0; signature 2 (matching) → stall_count=1; signature 3 (matching) → stall_count=2 → block. |
| `--no-progress-detection` | Disable stall detection (signatures are still computed for state-file inspection but never counted as stalls). Default off. |
| `--autonomous` | Walk every unfinished phase in a single process under one state-lock acquisition. Hard-stops still hand back (Step 9b). Default off → one phase per `--resume`. |
| `--max-phases N` | Cap on total phases walked in autonomous mode. Hard-stops with blocker `max_phases ceiling hit (N)` when the post-commit completed-phase count reaches `N`. Unset → effectively `len(parsed_phases) + 1` (no cap fires on a healthy run). |
| `--run-ci-parity` | Enable the end-of-plan CI-parity gate explicitly (implied by `--autonomous`). Detects `just ci` → `make ci` → `npm run ci` → `cargo test --all`. Workflows are intentionally dropped from detection. |
| `--ci-cmd CMD` | Override the detected CI entrypoint for the parity gate. Any shell command. Bypasses detection entirely. |
| `--skip-ci-parity` | Short-circuit the parity gate. From a fresh complete state, status transitions straight to `complete` with a skip summary. From `awaiting_ci_parity` state, sets `complete` and preserves the request file + any result file on disk. |

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
- Recompute the plan's content hash: take the plan with the marker line and everything after it stripped, pipe to `git hash-object --stdin`. Compare to the SHA recorded in the marker. The strip is **byte-faithful** — the bytes above the marker line are hashed verbatim, including any blank line immediately above the marker and the original line endings (LF or CRLF). Do **not** trim trailing blanks or normalize line endings before hashing: a plan with a blank line before its marker (the common markdown style) would then hash differently from what `/review-plan` wrote and report a false staleness.
- If marker absent → hard-stop with: `Run: /review-plan <plan-path>` and exit.
- If hash mismatches (stale marker):
  - **Initial run** (no `--resume`): hard-stop with the same message. A stale marker before the first phase means the plan drifted between `/review-plan` and `/conduct`; re-review.
  - **`--resume`**: rewrite the marker in place with today's date and the new hash, log `conduct: review marker auto-refreshed on resume (was <iso> @ <old12>, now @ <new12>)` to stderr, and proceed. By construction workspace edits below the marker do not affect the hash, so a stale marker on resume always means a phase legitimately amended the contract section above the marker — refreshing preserves the divider invariant without forcing a re-review mid-run. State's `plan_content_hash` is resynced to the new value on the same load.

### 3. Pre-commit health check

Run the repo's pre-commit / lint in non-fix mode on the current tree, in this order: `pre-commit run --all-files`, then `make lint`, then `npm run lint`, then `ruff check .`. If none exist, skip. If the check fails → hard-stop with: `Tree has pre-existing lint/hook failures; fix them before running this skill`.

This prevents subagent fix-loops from chasing issues they didn't introduce.

**Custom `--lint-check` overrides MUST NOT invoke `just check-sync` or `just check-prompt-parity`.** Those checks compare repo state against the global authority and are expected to drift mid-implementation (one runtime lands its side before the other); invoking them at preflight would block legitimate phase-boundary commits.

### 4. State file load

`<repo-root>/.conduct/state-<plan-id>.json`, where repo-root comes from `git rev-parse --show-toplevel` and `plan-id` is the plan basename plus a short SHA-1 digest of its repo-relative path (e.g., `state-foo-3a1f9b8c4d2e.json`). The digest disambiguates plans that share a basename across different directories. A pre-digest state file (`state-<basename>.json`) is automatically migrated to the digest-suffixed name on the next load when its recorded `plan_path` matches the active plan.

- If present and `--resume`: load and continue only after `state.plan_path` matches the current plan and every stored `completed_phases[*].label/title` still matches the parsed phase prefix. This prefix check runs before any refreshed marker resyncs `state.plan_content_hash`, so a reviewed structural edit cannot silently skip or repeat completed work. Refresh `state.resume_base_sha = git rev-parse HEAD` so the rogue-commit check (Step 8) treats any user commits made during handback as the new phase baseline rather than as subagent commits.
- If present without `--resume`: warn, print state summary, suggest `--resume` or `--abort-run`, exit.
- If absent: initialise with `base_sha = git rev-parse HEAD`, `phase_index = 0`, `iteration_count = 0`, `status = "running"`.

Acquire an advisory lock on `.conduct/state-<plan-id>.json.lock` before any write (see `lock.py` shipped with this skill).

### 5. Phase parsing

Parse phases from the `## Implementation Checklist` section with regex:

```
^###\s+Phase\s+(\S+?)\s*[:—–]\s*(.+?)\s*(\([^)]*\))?\s*$
```

Captures the phase label (e.g. `3` or `3a`) and title; strips trailing parenthesised annotations. The label/title separator may be a colon (`:`), em-dash (`—`), or en-dash (`–`) — LLM-authored plans often default to em-dash, so the parser tolerates all three rather than forcing a manual rewrite. Record each phase's 0-based document position (used as `phase_position` in reports) and verbatim label (used as `phase_label`).

Phase completion is sourced from the `## Progress` section below the marker. Each entry has the form `- [ ] Phase <label>: <title>` (or `- [x] ...` when done). The conductor reads this section to skip phases that have already finished. Old-format plans without a Progress section fall back to in-body checkbox state for backward compatibility.

## Per-Phase Workflow

For each unfinished phase, execute steps 1–9. Acquire the state-file lock before any state mutation.

**On entering a new phase**: reset `state.iteration_count = 0` and persist before Step 1. The fix-loop cap is per-phase, not per-run; without this reset, phase N starts already counting iterations spent on phase N−1 and the cap fires prematurely.

### Step 1 — Parse phase contract

From the phase block, extract:

- `**Impl files:**` — comma-separated paths, globs allowed.
- `**Test files:**` — comma-separated paths, globs allowed.
- `` **Test command:** `<cmd>` `` — parsed with `^\*\*Test command:\*\*\s+\x60([^\x60]+)\x60\s*$`; first match wins; additional matches emit a warning.
- `` **Validation cmd:** `<cmd>` `` — optional. Runs after tests pass, before the boundary commit. Same shell-trust boundary as `Test command:`. Failure triggers handback (status `awaiting_user`), NOT the fix loop — validation typically exercises live-data or external-service behaviour an implementer cannot auto-repair. See Step 5b below.

Any slot may be absent; see Fallbacks below. If an entire run's unfinished phases declare zero slots, the conductor emits a one-shot warning on the first handback (degraded-mode notice: "fill slots in the plan to enable parallel spawn and real test runs").

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
| `{{ITERATION}}` | current fix-loop iteration | substitute bare int (no quotes) |
| `{{BASE_SHA}}` | `git rev-parse HEAD` at phase start | string |
| `{{PRIOR_DIFF}}` | staged diff from previous attempt, else empty | string |
| `{{TEST_FAILURES}}` | test-runner or pre-commit hook output, else empty | string |

Same pattern for `test-writer-prompt.md` (placeholders: plan path, phase index, phase label, phase title, base sha, existing-tests summary) and `reviewer-prompt.md` (plan path, phase index, phase label, phase title, diff).

Spawn via the `Agent` tool, `subagent_type: general-purpose`, with the filled template as the full prompt. Do not thread parent conversation context. In parallel mode, issue both Agent tool calls in a single message. Both the implementer and the test-writer are mechanical work (executing an already-reviewed plan, not judgment) → `model: sonnet, effort: medium`.

### Step 4 — Await both, parse reports

Each subagent returns a final fenced ` ```json ` block. Parse rules:

- **Anchor on the LAST fenced `json` block** in the output, not the first. The plan or prompt body may contain schema examples; only the terminal block is the report.
- Validate via `schema.parse_report(text, expected_role)` — this performs the last-block extraction, JSON parse, and role-specific schema check. Required top-level keys: `role`, `phase_position`, `phase_label`, `iteration` for impl/test roles, plus role-specific fields (`findings` for reviewer; `files_changed`/`summary` for implementer; `test_files_added`/`test_commands`/`coverage_summary` for test-writer). For implementer and test-writer the `flags` object is also validated by key: implementer must emit `blocked` (bool), `test_contract_mismatch` (bool), `needs_test_coverage` (list); test-writer must emit `blocked` (bool) and `needs_impl_clarification` (string or null). Reviewer does not emit `flags`. Extra keys (top-level or inside `flags`) are allowed so prompts can evolve without breaking older conductors.
- If `parse_report` raises `SchemaError` → set `state.status = "schema_error"`, record which subagent failed, the error message, and the raw output tail in state, handback to the user. Do NOT respawn. A clean-context respawn cannot consume "your last output was malformed" because the fresh subagent has no memory of the prior attempt.

### Step 5 — Run tests

Resolve the test command in order:

1. `--test-cmd` CLI flag.
2. Phase's `**Test command:**` line.
3. Repo default: `package.json` `scripts.test`, `pyproject.toml` `[tool.pytest.ini_options]`, or `Makefile` `test` target.
4. None available → emit warning, skip tests, set `state.last_summary` with the skip flag, proceed directly to Step 8 (commit boundary).

Run the resolved command via `runner.run_tests(cmd, timeout=<secs>)` (`--test-timeout`, default 300). The wall clock is enforced by Python's `subprocess.run(timeout=...)` so behaviour is identical on Linux and macOS without depending on GNU coreutils `timeout`. On timeout the runner kills the process group, sets `timed_out = True`, and the conductor treats the result as a fix-loop failure with the killed-by-timeout note appended to the captured output.

On non-zero exit → Step 6. On zero exit → Step 5b (if a validation command is present), else Step 7.

### Step 5b — Optional validation command

If the phase declares a `**Validation cmd:**` slot, run it via the same `runner.run_tests` subprocess wrapper after tests pass. Semantics differ from Step 5 in two ways:

1. **No fix loop on failure.** A non-zero exit or timeout sets `state.status = "awaiting_user"` with `state.blocker = "Phase <label> validation failed"`, persists the last 2000 bytes of output as the diagnostic, and hands back. The user inspects the output and decides whether to patch the plan, re-invoke with `--resume`, or abort. A failing validation typically means the live-data or external-service behaviour being exercised cannot be fixed by respawning the implementer (e.g. a reprocess-and-diff check against a real database).
2. **No subagent spawn.** Validation is a direct subprocess, not an Agent call. It shares the `Test command:` trust boundary — the plan author is authorising what gets executed.

On zero exit, append `"validation passed"` to the phase warnings and continue to Step 7.

### Step 6 — Fix loop (stall-aware dual cap, helper-owns-increment invariant)

No classifier. On any failure (test failure OR pre-commit hook failure at the boundary commit in Step 8):

- **Single source of truth for the increment.** The conductor's `_check_iteration_bound(state, opts, signature)` helper is the only call site that mutates `state.iteration_count`. All three fix-loop entry points (test-failure path in `_run_phase`, boundary-commit hook-failure path in `_commit_phase`, hook-retry path in `_retry_after_hook_failure`) call the helper after observing the failure signature. **Pre-implementation audit (Phase 1)**: today's three increments all fire AFTER the failure is observable to the conductor (lines 678, 792, 992 in the pre-refactor code); the helper is invoked at that same position so iteration_count at the bound-check point is byte-identical to today's iteration_count at the equivalent return point. This is asserted by `helper-is-single-increment-source-three-sites`.

- **Signature.** `progress.iteration_signature(failing_tests, staged_diff_stat)` returns SHA-1 over canonical JSON of `{"tests": sorted(failing_tests), "diff_stat_hash": sha1(staged_diff_stat)}`. For the test-failure path `failing_tests` is the sorted set of `FAILED <nodeid>` lines parsed from pytest output. For the hook-retry path `failing_tests` is the sorted set of failing hook ids parsed from pre-commit output (e.g. `["ruff", "ruff-format"]`); on parse failure it falls back to `[]` and the diff-stat carries the signal alone. `staged_diff_stat` comes from `progress.compute_staged_diff_stat(repo_root)`, which uses `git diff --cached --stat -w` when the installed git accepts it (probed once at module import) and falls back to `git diff --cached --name-only | sort` otherwise. The probe decision is sticky for the process lifetime; on fallback a one-shot warning is emitted.

- **Helper semantics.** `_check_iteration_bound`:
  1. `state.iteration_count += 1` (single source of truth).
  2. Push the new signature onto `state.stall_signatures` (rolling window, length 2, oldest first).
  3. If new signature equals previous: `state.stall_count += 1`; else: `state.stall_count = 0`.
  4. If `state.stall_count >= opts.stall_threshold` (and progress detection is not disabled): return blocked with `state.blocker = "stall_threshold exceeded"`.
  5. If `state.iteration_count > opts.max_iterations_ceiling`: return blocked with `"max_iterations_ceiling exceeded"`.
  6. If `state.iteration_count > opts.max_iterations`: return blocked with `"max_iterations exceeded (legacy)"`.
  7. Otherwise return `None` (continue the fix loop).

  Block priority is intentional: a stall ("no progress") is a stronger signal than "ran out of attempts", and the legacy cap is checked last so a misconfigured `stall_threshold >= max_iterations` still hands back with the legacy reason (the startup validator emits a warning under that configuration).

- **Persist state immediately** after the helper returns (crash recovery; the stall counters must survive a `--pause-phase` / `--resume` round-trip without false reset).

- **Reset the index before respawn** when the helper returns `None`: capture `git diff --cached` into `{{PRIOR_DIFF}}`, then run `git reset` (mixed, no `--hard`) to clear the staging area. The respawned implementer starts from a clean index with the prior diff visible only inside its prompt — this prevents stale staged content from a failed attempt silently mixing into the next iteration.

- **Respawn** the implementer with `{{ITERATION}}` = new count, `{{PRIOR_DIFF}}` = the captured diff, `{{TEST_FAILURES}}` = full runner output (or hook output, if the failure came from the boundary commit).

- **`test_contract_mismatch` exception** is unchanged: if the previous implementer report set `flags.test_contract_mismatch: true`, respawn the **test-writer** instead on this iteration, same inputs. Reset the flag handling for the iteration after that (respawn implementer again unless the next report flips the flag again).

- **Phase-start reset is guarded.** On entering a new phase, `state.iteration_count`, `state.stall_signatures`, and `state.stall_count` are reset to their initial values ONLY when `state.current_phase_title != phase.title` (absent is treated as different). Without this guard, a mid-phase `--resume` would clobber the persisted counters and let the bound re-start at zero.

### Step 7 — Optional mid-phase reviewer (one-shot)

Trigger conditions: staged diff > 200 lines, OR > 3 files touched, OR phase tagged high-risk in the plan's Review Focus section. If triggered, spawn one reviewer subagent using `reviewer-prompt.md` with `{{DIFF}}` = staged diff.

<!-- opus/high: it reviews code, so it earns the review tier under the two-tier policy (R1) even though it is only advisory -->
`model: opus, effort: high`.

Log findings into the phase summary. Never loop the reviewer. Findings do not block phase completion — the conductor is advisory here, not gating.

### Step 8 — Phase-boundary commit

After tests pass (or were skipped with warning):

1. **Rogue-commit check.** Compare `git rev-parse HEAD` to the phase-start baseline: `state.resume_base_sha` if this run started from `--resume`, otherwise `state.base_sha` (for phase 1) or the last completed phase's `commit_sha` (walking back past any `commit_sha: null` entries — those are rogue-commit records, not real baselines). If HEAD advanced beyond the baseline _during this phase's subagent work_, a subagent committed despite the prompt directive. Do NOT stack another commit. Record `rogue_commit_sha` in the phase entry, set `commit_sha: null`, set `state.status = "awaiting_user"` with a warning, handback.
2. **No-op branch.** If `git diff --cached` is empty (the phase resolved to a diagnostic-only or accepted-behaviour outcome with no code change), skip the commit: record the phase entry with `commit_sha` = current `HEAD` (unchanged), add `no_op: true`, emit warning `no staged changes; skipping commit`, and proceed to Step 9. Do NOT use `--allow-empty`.
3. **Impl commit.** Run `git commit -m "conduct: phase <label> — <phase title>"`. Commit author = current git user (no impersonation).
4. **Hook retry (one-shot formatter retry).** If the pre-commit hook fails, first check whether the hook modified files in-place (formatters like black, ruff --fix, prettier). If `git diff --name-only` is non-empty at this point, run `git add -u` and retry the commit **once** in-place with the same message. If the retry succeeds, append the warning `pre-commit hook modified files; re-staged and retrying` to the phase warnings. If the retry also fails, or if the hook did not modify files, route the hook output back into Step 6 as a fix-loop iteration via `_check_iteration_bound`. Do NOT use `--no-verify`.
5. **Record `commit_sha`.** Capture the new HEAD as the phase's `commit_sha` in `state.completed_phases`. **This field is immutable once written.** If the user lands follow-up commits during handback (for example after `/deep-review`), the `--resume` preflight absorbs them into `resume_base_sha` for the rogue-commit check — it does NOT rewrite the previous phase's `commit_sha`.

**Mirror parity is each runtime's own responsibility.** A claude-driven `/conduct` lands only `.claude/` files. The codex-driven `/conduct` lands `.codex/` in a separate run against the same plan. Repo-level mirror parity is verified at the end (Phase 4) via `just check-prompt-parity` and `just check-sync` once both runtimes have landed their respective sides; it is not gated in-run.

**Pre-commit hook scope.** `scripts/check-prompt-parity.sh` is verified to be invoked only from `justfile` recipes, never from `.pre-commit-config.yaml` or any other hook chain. The Phase 3 impl commit therefore lands cleanly with hooks enabled, even though `.codex/skills/conduct/ci-parity-prompt.md` is intentionally absent until the codex-side mirror commit lands. Contributors invoking `just check-prompt-parity` during the lagging-mirror window can pass `CONDUCT_LAGGING_MIRROR_OK="conduct/ci-parity-prompt.md"` to get a green exit with a stderr annotation.

### Step 9 — Phase transition

Step 9 has two branches. Step 9a is the success transition (continue under autonomous mode, or hand back under legacy mode). Step 9b is the hard-stop handback that fires regardless of `--autonomous`.

#### Step 9a — Phase success transition (autonomous-aware)

After a phase's boundary commit completes:

1. **Legacy mode (no `--autonomous`).** Print a structured phase summary and the literal `Run: /conduct --resume <plan-path>` next-command line; set `state.status = "awaiting_user"`, persist, release lock, exit the skill. One phase per `--resume` invocation.
2. **Autonomous mode (`--autonomous`).** Persist progress (already done inside the boundary-commit helper), do NOT release the lock, do NOT print a handback summary, and continue the conductor's explicit phase loop. The single `with lock:` acquisition spans every phase: a clean autonomous run from phase 1 → N acquires the state lock exactly **once**.

Single-lock-acquisition property. In autonomous mode the conductor walks every unfinished phase inside one `with lock:` block. The `LockAcquisitionCounter` test fixture asserts this: a successful 3-phase autonomous run shows `lock_acquisitions == 1`. Legacy mode acquires the lock once per `--resume`, so an N-phase legacy run shows `lock_acquisitions == N`. The CI-parity gate (Phase 3) introduces a result-file path that releases the lock and re-enters on resume, producing `lock_acquisitions == 2` for the production gate flow — but Phase 2 itself does not exercise that path.

#### Step 9b — Hard-stop handback

Hard-stops hand back regardless of `--autonomous`:

- Rogue commit (subagent ran `git commit`).
- Schema error (subagent JSON did not parse).
- Validation-cmd failure (post-test validation command exited non-zero).
- Stall-threshold hit (same `iteration_signature` N times).
- Max-iterations-ceiling hit (autonomous-runway cap exceeded).
- Max-phases cap hit (`--max-phases` ceiling reached).
- (Phase 3) `awaiting_ci_parity` missing-result-after-3-resumes.

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
3. Set `state.status = "awaiting_user"` (or `"blocked"` / `"schema_error"` per the stop reason), persist, release lock, exit the skill.

No keyword heuristic watches for "proceed" — the user copies the printed command when ready.

## CI Parity Gate

After the final phase boundary commit, the conductor can dispatch a one-shot CI-parity gate that runs the repo's local CI entrypoint against the working tree. This catches drift between "tests pass per phase" and "what the CI matrix actually runs". The gate is **single-exit**: it fires only when `conduct()` would otherwise return `status=complete`, never on an intermediate `--resume`. Re-firing is suppressed by the persisted `ci_parity_dispatched` flag.

### Activation

- Implied on by `--autonomous`.
- Opt-in on legacy runs via `--run-ci-parity`.
- Short-circuited by `--skip-ci-parity` (sets `status=complete` with a skip summary; preserves request file + any on-disk result file).

### Detection priority

The gate resolves the CI command in this order. Workflows under `.github/workflows/` are intentionally NOT in scope — they require external tooling like `act` to run locally and would produce confusing soft-dep fall-through.

1. `just ci` — `justfile` at repo root with a `ci:` recipe.
2. `make ci` — `Makefile` at repo root with a `ci:` target.
3. `npm run ci` — `package.json` with a `"ci"` script entry.
4. `cargo test --all` — `Cargo.toml` at repo root.

`--ci-cmd CMD` overrides detection unconditionally. When detection returns nothing AND no `--ci-cmd` override is set, the gate blocks with `ci-parity entrypoint not detected; pass --ci-cmd or --skip-ci-parity`.

### Main-runtime dispatch protocol

In production the conductor does NOT call runtime tools directly from inside the Python helper. Dispatch is main-runtime-orchestrated through a single result-persistence adapter, in this sequence:

1. The conductor computes `plan_id = sha1(abs(plan_path))[:12]` via `_compute_cross_runtime_plan_id`, sets `state["ci_parity_request"]` (with `plan_id` and a `request_written_at_unix` timestamp), `state["ci_parity_request_written_at"]`, initialises `state["ci_parity_missing_resume_count"] = 0`, sets `state["status"] = "awaiting_ci_parity"`, persists state, releases the lock by exiting `with lock:`, and returns `ConductResult(status="awaiting_ci_parity", next_action="dispatch_ci_parity", request=<dict>)`.
2. The main runtime orchestrator executes `request["ci_cmd"]` directly from `request["repo_root"]`, captures the numeric exit code, duration, and combined output, and derives `status` from the exit code (`0` → `passed`, non-zero/timeout/error → `failed`). An LLM worker may summarize already-captured output, but it must not be the authority for pass/fail.
3. The orchestrator MUST persist the JSON report to `<repo-root>/.conduct/ci-parity-result-<plan-id>.json` via the conductor-owned `_write_ci_parity_result(path, payload_text)` adapter. The adapter writes to a tmp path then `os.replace` (atomic on POSIX). **Do NOT cite `_safe_write_text` here** — that helper uses `O_TRUNC` and is reserved for state-file writes, where a crash mid-write is acceptable. A partial write of the ci-parity result file would surface as `schema_error` and preserve a corrupt file.
4. The orchestrator re-invokes `/conduct` with `--resume <plan>`. Preflight observes `awaiting_ci_parity` and runs the five-sub-case branch below.

Conduct itself ensures `.conduct/` exists on the dispatch path (idempotent `mkdir -p`-style) — orchestrators do not have to.

### Five-sub-case preflight on `--resume`

When state status is `awaiting_ci_parity`, preflight computes `result_path = <repo-root>/.conduct/ci-parity-result-<plan-id>.json` and branches:

1. **Present + regular non-symlink + valid + matches state** (parses, schema OK, `plan_id` matches, `request_written_at_unix` echoed back matches `state["ci_parity_request"]["request_written_at_unix"]`, `command_run` matches the stored `ci_cmd`, mtime from the same opened file descriptor ≥ `state["ci_parity_request_written_at"]`) → call `_consume_ci_parity_result(state, opts, report)`. On `passed`: `status=complete`, append summary. On `failed`: `status=ci_failed`, persist `ci_parity_result`, set blocker, handback. Move the file to `ci-parity-result-<plan-id>.consumed-<unix>.json` for post-mortem.
2. **Present but stale** (any of: `plan_id` disagrees, file mtime older than `ci_parity_request_written_at`, `request_written_at_unix` field mismatches state, `command_run` mismatches state) → ignore the file, re-emit `awaiting_ci_parity` with the same request (idempotent re-dispatch).
3. **Present but unreadable, symlink/non-regular, over the size cap, malformed, or schema-invalid** → `status=schema_error`, blocker `ci-parity result file malformed/unreadable at <path>`, file preserved for inspection.
4. **Absent active file BUT matching `.consumed-<unix>.json` exists** whose `plan_id`, `request_written_at_unix`, and `command_run` match state's request → TOCTOU recovery: another `--resume` consumed the file already. Run `_consume_ci_parity_result` against the consumed file's payload (canonical state mutation); skip the move (the file is already at the consumed name).
5. **Absent** (no consumed match) → `state["ci_parity_missing_resume_count"] += 1`. At ≥3 → handback with blocker `ci-parity result file missing after 3 resume attempts; pass --skip-ci-parity to abandon gate`. Else re-emit `awaiting_ci_parity` with the same request.

**Missing-counter reset rule.** The `ci_parity_missing_resume_count` resets to 0 on *any* non-absent preflight outcome — present-and-consumed (sub-case 1), TOCTOU recovery (sub-case 4), present-but-stale (sub-case 2), or present-but-malformed (sub-case 3). "Consecutive" therefore means "consecutive absent observations, uninterrupted by any other outcome"; a stale-then-absent sequence does not progress toward the 3-strike handback.

### Test/production code-path parity

The same Python function `_consume_ci_parity_result(state, opts, ci_parity_report)` is invoked from both the test-injection path (when `opts.ci_parity_spawn` is set; consume happens inline in the same Python turn, no lock release) and the production result-file path (called by preflight on re-invocation). State mutations are byte-identical across the two paths; this is the invariant behind `ci-parity-injection-and-result-file-paths-share-consume-code`.

Result-file persistence flows through a single adapter `_write_ci_parity_result(path, payload_text)` → `_atomic_write_result_file(path, text)` (tmp-file write + `os.replace`). Orchestrators MUST use this adapter — do NOT call `_safe_write_text` directly on the result-file path.

### Lock-release contention

Between the conductor's lock release at `awaiting_ci_parity` and the orchestrator's `--resume`, another `/conduct` invocation could acquire the lock. Defined behaviour:

- `/conduct` invoked with `--resume <plan>` against `awaiting_ci_parity` state follows the five-sub-case flow (idempotent).
- `/conduct` invoked with `<plan>` (no `--resume`) against `awaiting_ci_parity` state hard-fails preflight with `state shows awaiting_ci_parity; use --resume to consume the ci-parity result or --skip-ci-parity to abandon the gate`.
- A separate `/conduct` invocation with `--resume <other-plan>` and a different `plan_id` is unaffected (different state file, different lock).

## Fallbacks

- Missing `Impl files:` / `Test files:` → sequential spawn (Step 2).
- Missing `Test command:`, no repo default, no `--test-cmd` → warn, skip tests for the phase, flag in handback summary (Step 5).
- Missing Testing Notes entirely → same as above; phase completes on implementer-only success with the skip flag.
- Plan has zero unfinished phases → print `All phases complete` and exit.

## State File

Path: `<repo-root>/.conduct/state-<plan-id>.json`, where `plan-id` is the basename plus a short SHA-1 digest of the repo-relative plan path. `.conduct/` is git-ignored (Phase 5). Pre-digest state files (`state-<basename>.json`) are migrated automatically on the next load when their recorded `plan_path` matches the active plan.

Schema:

```json
{
  "plan_path": "docs/dev_plans/20260422-feature-conduct-skill.md",
  "plan_content_hash": "<sha1 of plan with marker stripped>",
  "base_sha": "<git sha before phase 1>",
  "resume_base_sha": "<git sha at the start of this --resume invocation; absent on first run>",
  "phase_index": 3,
  "current_phase_title": "...",
  "completed_phases": [
    { "index": 1, "label": "1", "title": "...", "commit_sha": "...", "tests": "passed", "iterations": 1 }
  ],
  // Optional per-entry fields (written only when the condition fires):
  //   "no_op": true              — Step 8 no-op branch; commit_sha is the unchanged HEAD.
  //   "rogue_commit_sha": "..."  — subagent committed during phase; commit_sha is null,
  //                                this records what HEAD advanced to.
  //   "diagnostic_finding": "..."— narrative recorded when a phase resolves without code
  //                                change; paired with no_op or a null commit_sha.
  // "commit_sha" is immutable once written; it is NOT updated if the user amends or
  // adds follow-up commits during handback.
  "last_summary": "...",
  "iteration_count": 0,
  "stall_signatures": [],
  "stall_count": 0,
  "plan_id": "<sha1(abs(plan_path))[:12]>",
  "schema_version": 1,
  "status": "awaiting_user | running | paused | blocked | schema_error | complete",
  "blocker": null
}
```

### Fields introduced for progress-aware iteration bound

- **`stall_signatures`** — rolling list of the last 2 fix-loop iteration signatures (`progress.iteration_signature(failing_tests, staged_diff_stat)`). The conductor uses the pair to detect "no progress" (two identical signatures = one stall).
- **`stall_count`** — count of consecutive identical signatures observed in the current phase. Reset to 0 whenever a new signature differs from the previous. Blocks the fix loop with `stall_threshold exceeded` once it reaches `--stall-threshold` (default 2).
- **`autonomous`** — diagnostic-only echo of the `--autonomous` flag, surfaced for state-file readers.
- **`plan_id`** — stable 12-character digest of the absolute plan path (`sha1(abs(plan_path))[:12]`), computed via `_compute_cross_runtime_plan_id`. Computed once on first state write. Distinct from the state-file naming digest (which scopes to the repo-relative path inside a worktree); `plan_id` is filesystem-absolute so a future autonomous main-Claude orchestrator can re-derive it without re-loading state.
- **`state_author`** — `"claude"` or `"codex"`. Diagnostic counterpart to the runtime-specific state filename prefix (`state-claude-…` / `state-codex-…`). The two runtimes MUST NOT share a state file; this field is a readable cross-check independent of `schema_version`.
- **`schema_version`** — serialization-contract marker. Absent is treated as `1`. Phases 1–2 (Claude-side) write `1`; Phase 3 bumps Claude-side to `2` once the `ci_parity_*` fields land. Note: `schema_version` is NOT a runtime-author signal — runtime authorship is carried by `state_author` and the runtime-specific state filename.

### Fields introduced for the CI-parity gate (Phase 3, schema_version 2)

- **`ci_parity_request`** — dict with `{plan_path, base_sha, head_sha, ci_entrypoint_kind, ci_cmd, repo_root, plan_id, request_written_at_unix}`. Written on dispatch; read back by preflight to validate the result file (`plan_id` + `request_written_at_unix` echo).
- **`ci_parity_request_written_at`** — float unix timestamp captured at dispatch. The mtime of the result file MUST be ≥ this value, otherwise the file is classified stale (sub-case 2).
- **`ci_parity_result`** — parsed CI-parity JSON after consume. Persisted on both `passed` (status → `complete`) and `failed` (status → `ci_failed`) outcomes.
- **`ci_parity_dispatched`** — bool flag preventing the gate from re-dispatching across `--resume` invocations after a successful consume. The single-dispatch invariant lives here.
- **`ci_parity_missing_resume_count`** — int counter for the five-sub-case absent path. Resets to 0 on ANY non-absent outcome (consume, TOCTOU recovery, stale-ignore, malformed). Hits handback at 3.

### Helpers cited by this contract

- `_check_iteration_bound` — single source of truth for `iteration_count += 1` and the stall/ceiling/legacy-cap check.
- `_dispatch_ci_parity_if_eligible` — single entry point for the end-of-plan CI-parity gate; called from both the autonomous post-loop and the legacy non-autonomous early-return paths.
- `_consume_ci_parity_result` — shared consume code path; identical state mutations from the test-injection seam and the production result-file path.
- `_write_ci_parity_result(path, payload_text)` — conductor-owned adapter; orchestrators MUST use this for result-file persistence. Delegates to `_atomic_write_result_file`.
- `_atomic_write_result_file(path, text)` — tmp-file write + `os.replace`. Crash-safe-vs-partial-write (preflight reads the file with `json.loads`).
- `_compute_cross_runtime_plan_id(plan_path)` — `sha1(abs(plan_path))[:12]`. Intentionally divergent from `_state_path`'s rel-path digest; the two are documented side-by-side in `conductor.py`.

### Forward-compat contract for `schema_version`

The loader treats `schema_version` values `>=1` and not in the known set (`{absent, 1, 2}`) as a future version: it reads the **known subset** of fields (every field documented in this section literally), emits a one-shot warning `state file written by newer schema_version=<n>; reading known fields only`, and proceeds. The warning is suppressed for the rest of the same Python process (idempotent within process) and re-fires on a fresh `--resume` (new process).

Future schema versions MUST add only optional fields, or fields with documented safe defaults for older readers. Required-semantics fields require an explicit `incompatible_with_pre_vN: true` marker that older loaders hard-fail on — the contract is "older loaders silently degrade to the known subset unless the writer explicitly opts the field into a hard-fail".

### Locking

- Primary: `lock.py` acquires `fcntl.flock` on `<state-file>.lock` fd.
- Fallback if Python is unavailable: atomic `mkdir <state-file>.lockdir`.
- Stale locks older than 1 hour are broken with a warning.
- `flock(1)` is NOT used — unavailable by default on macOS.
- Two `/conduct` invocations on the same plan in the same worktree race on the same lock. Sibling worktrees resolve to distinct repo-roots via `git rev-parse --show-toplevel` and therefore distinct state files.

## Trust Boundary

**The plan's `Test command:` slot is executed as a shell command** (via `runner.run_tests` with `shell=True`). Running `/conduct` on a plan is therefore equivalent in trust to running `make test`, `npm test`, or `cargo test` on a branch you checked out — the plan author chooses what gets executed.

Treat a dev plan received from someone else (a teammate's branch, an external PR, a forwarded file) the same way you'd treat a `Makefile` or `package.json` from that source: read it before running. Preflight validates the review marker to confirm the plan hasn't drifted since it was reviewed, but the marker is a content hash, not a cryptographic signature of the reviewer — it does not attest that anyone trustworthy approved the command.

If you need a stronger guarantee, review the phase `Test command:` lines before running `/conduct`, or override with `--test-cmd <your-own-cmd>` to ignore the plan's slot entirely.

## Known Limitations

- **No agent wall-clock timeout.** The `Agent` tool is synchronous within the parent turn and exposes no PID, so `--agent-timeout` is not enforceable in v1. Mitigated by the fix-loop cap plus explicit iteration counts in prompts. Test-runner timeout is real because the test command is a subprocess.
- **Rogue commits are detected, not prevented.** Subagents are instructed to stage only; a subagent that runs `git commit` anyway is caught by the HEAD-comparison check in Step 8, flagged in state, and handed back to the user rather than auto-corrected.
- **Schema errors do not retry.** A subagent that emits malformed JSON triggers `schema_error` status and immediate handback. The user decides whether to adjust the prompt template or re-invoke.
- **Resume gating is advisory on Claude, enforced on Codex.** Claude loads any existing state file unconditionally; `opts.resume` only refreshes `resume_base_sha`. Codex hard-stops on `state_exists and not --resume`. In practice the orchestrator is expected to pass `--resume` when resuming, but Claude will not refuse if you forget.
- **Clean-context enforcement is instruction-based on Claude.** Codex enforces worker isolation at the harness layer via `fork_context: false` in its SKILL frontmatter. Claude relies on the "Do not thread parent conversation context" instruction being followed by main Claude. Same intended behaviour; weaker enforcement.

## Integration Points

- **Plan format**: `/dev-plan` owns the template. Phases need `**Impl files:**`, `**Test files:**`, and `` **Test command:** `<cmd>` `` slots in the contract section above the marker. Per-phase progress lives in a `## Progress` section below the marker.
- **Review marker**: `/review-plan` writes the marker line after user acceptance. The marker divides the plan into immutable contract (above, hashed) and editable workspace (below, not hashed). This skill consumes the marker as the readiness signal.
- **Fan-out**: a `/fan-out`-spawned Claude subprocess may invoke `/conduct` as its top-level skill; `/conduct` itself does not fan out.
