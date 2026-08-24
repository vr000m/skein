# Task: Review-skill resilience — bounded gates, durable lens state, regression guard, hygiene

**Status**: Not Started
**Component**: review-skills
**Assigned to**: Claude (conduct) + Codex mirror via `codex:rescue`
**Priority**: High
**Branch**: feature/review-skills-resilience
**Created**: 2026-08-23
**Completed**:
**Review Gates**: full

## Objective

Make `review-gauntlet`, `deep-review`, and `review-plan` tolerate fallible infrastructure (hung Codex CLI, silent lens subagents) without stalling a round, add a regression-loop stop condition to the gauntlet, and codify four hygiene rules surfaced by the 2026-08-23 Claude Code insights report.

## Context

Source: Claude Code insights report, 2026-08-23 (`file:///Users/vr000m/.claude/usage-data/report-2026-08-23-163953.html`), covering 16 sessions 2026-08-15→23 (5 review-gauntlet sessions). Observed regressions/friction:

- **Codex gate hangs**: `codex exec review` ran 25+, 44+, and 90+ minutes against an ~11.5-minute baseline; the insights report *attributes* the 90-minute case to an incompatible flag combination — attribution UNVERIFIED (identity AND causation), to be confirmed from transcripts in Phase 1. No timeout, no fallback — operator had to drop the gate mid-gauntlet by hand.
- **Silent lenses**: gauntlet lens subagents "never returned content through the mailbox"; the report attributes this to an Agent tool spawn cap (existence and causal role UNVERIFIED — the run-2 dogfood saw all six agents go idle without cap pressure), forcing respawns and manual review. Same failure class as the open memory item *review-plan lens agent no-return* (2/5 lenses — assumptions, codebase-claims — went silent in a live dogfood run; root cause never chased).
- **Regression loops**: a later review round had to catch a regression introduced by an earlier fix round; fixes applied in one place when the pattern appeared in several.
- **Security reviews interrupted**: 3 sessions killed mid-exploration before any finding was delivered.
- **Inferred state**: PyPI manual-approval gate wrongly concluded gone from workflow run duration; two files had to be corrected.
- **ruff hook stripped `# noqa`**: `~/.claude/hooks/format-on-edit.sh:18` runs `ruff check --fix`. ASSUMPTION (unreproduced): the stripping is RUF100, which only fires when a project selects it — Phase 4 must reproduce before fixing.
- **Foreground test timeout**: full suite exceeded the 2-minute foreground Bash timeout and had to be re-run in background.

What already exists (verified by Explore, 2026-08-23): `lib/convergence-ledger.sh` already implements cap (`CAP=10`, line 56), K=2 non-convergence stall, structural-restart, and excludes `error/skipped/deferred` from clean passes (`SKILL.md:214`); it consumes **tallies only** (`--count/--structural/--local/--quarantine`, no finding identity). Both `deep-review` and `review-plan` persist state via bundled scripts but **only from the orchestrator after a lens returns** — a lens that never returns leaves nothing on disk. No `timeout`/background wrapping exists for the Codex gate. Shared scripts are **bundle-generated**: canonical source is `scripts/` (+ `scripts/lib/`), placed into `plugins/*/skills/<skill>/scripts/` by `scripts/bundle-appliers.sh` per `scripts/lib/bundle-map.sh` (`BUNDLE_SHARED`, `bundle_extra_for`); `scripts/check-sync.sh` flags any unmapped bundled file as drift; `tests/parity/test-applier-bundle-parity.sh` enforces byte-identity, with gauntlet `lib/` covered by `GAUNTLET_LIB_PARITY_FILES=(run-gate.sh convergence-ledger.sh)`. Host facts: `flock(1)` is absent on this macOS; `timeout` is Homebrew coreutils only.

## Requirements

- R1. Codex gate in `review-gauntlet` is wrapped in a wall-clock budget from `lens-budget.sh --kind codex` (20m floor, 45m cap; `--gate-timeout <seconds>` override). Enforcement is **shell-only** via `gate_run_bounded`, synchronous, killing the whole process group; Claude-side `run_in_background` + Monitor is an optional UX layer, non-load-bearing and Claude-only. On expiry the gate is recorded as `status: skipped`, `notes: "DEGRADED: timeout after <N>s"`, written to a path distinct from the tool's own output file — the round continues. `gate_run_bounded` writes the envelope on **every** exit, not only expiry: on exit 0 it jq-wraps the tool-out and stamps `duration_s`; a tool-out that is not valid JSON (tool crashed mid-write inside budget) yields a `status: "error"` envelope, never a clean-looking one; `run-gate.sh normalize` only ever reads the envelope path. ASSUMPTION (process-group escape): codex descendants remain in the process group `timeout`/the shim creates — a descendant calling setsid/setpgid would escape both kill paths; dogfood verifies with `pgrep -f 'codex exec'` for orphans after a real bounded run, and the expiry path adds a belt-and-braces `pkill -f 'codex exec review'` scoped to the gate's own invocation pattern.
- R2. The flag combination that produced the 90+ minute hang is identified (from the insights facets / session transcripts) and explicitly forbidden in the gate invocation prose, Claude and Codex mirrors. If unrecoverable, record UNVERIFIED and document the budget as the only defence. Acceptance: both mirrors carry either a `Forbidden flags:` line naming the combo or an `UNVERIFIED` marker naming the budget as sole defence; `test-gauntlet-skill-shape.sh` accepts exactly one of the two forms.
- R3. Lens subagents in `deep-review` and `review-plan` stream typed JSON lines to a per-attempt file **as they go** (ASSUMPTION: a subagent reliably shells out to `persist-lens-result.sh` per unit without permission prompts — dogfood must verify progress lines land at distinct mtimes and that the script path is permission-allow-listed): `{"type":"start","run_id":..,"units":[...]}` first; `{"type":"progress","unit":..}` after each unit; `{"type":"finding",...}` immediately on discovery; `{"type":"done","status":"completed|errored|skipped"}` last (`skipped` is emitted by the **orchestrator** on a deliberately-skipped lens's behalf — e.g. deep-review's spec lens with no Review Focus — the lens stays in `--expected` so `.lenses` stays complete and `--continue` does not re-run it). Path: `<skill-state-dir>/lenses/<run-id>/<lens>.<attempt>.jsonl` (`.deep-review/` or `.review-plan/`). **One writer per file** — no `flock`, no cross-writer atomicity assumption; the collector tolerates a truncated trailing line. The disk file is the source of truth; the Agent return value is a fallback only.
- R4. Orchestrator applies a per-lens budget from `lens-budget.sh`. `collect-lens-results.sh` reads all attempts for the run-id and reports per lens `{status, reviewed, assigned, unreviewed[], findings[]}` (merged across attempts, deduped by the **reconciler's `(file, line, category)` signature** — explicitly NOT the R5 regression key). The status enum is the superset `completed|partial|timed_out|errored|skipped` (absent key = missing) — the collector emits exactly this enum, `.lenses` persists it, and `--continue` re-runs `timed_out|errored|partial|absent` (`skipped` is terminal). A `--continue` re-run writes to the **next free attempt number** (attempt 3+, monotonic) under the same run-id — one writer per file is preserved because every attempt gets a fresh file; the "one respawn" rule is scoped **per orchestrator invocation**, not per run-id lifetime. Return-value precedence: if the Agent returned a parseable result but disk has no `done` line, the orchestrator writes the `done`+`finding` lines itself on the lens's behalf (attempt stays 1) and skips respawn — disk remains source of truth, returned work is salvaged. Otherwise a lens with no `done` after the budget is respawned **once** as attempt 2, scoped to `unreviewed`; a second failure is persisted as `timed_out` with coverage. The **orchestrator owns the assigned-units list** and passes it via `collect-lens-results.sh --expected <lens:units,...>`; for a `missing` lens, `unreviewed` := the full assigned list. ASSUMPTION (budget-wake): the orchestrator can observe budget expiry while lenses still run — Phase 2 starts with a spike (one deliberately silent stub lens) proving budget-triggered collect+respawn fires in a live session before the 10 lens prompts are written; the mechanism (Monitor vs Bash loop) is recorded in `## Findings`. `persist-deep-review-state.sh` **derives** its `.lenses` object from collector output via a new `--from-collector` flag (orchestrator pipes `collect-lens-results.sh` stdout into persist stdin; persist maps the collector's per-lens shape to `.lenses`; the positional `lenses.json` input is retained **test-only**, marked so in the script header — deep-review only, see the asymmetric-seam decision). Deep-review SKILL.md's incremental per-lens checkpoint prose is **rewired in the same phase**: each checkpoint becomes "run `collect-lens-results.sh` → `persist --from-collector`", keeping the incremental cadence on a single derivation path (no second writer on `.lenses`); `persist-review-state.sh` is untouched and the review-plan orchestrator reads collector output directly for its errored/timed_out report list. Codex sequential-fallback mode: the orchestrator emits the typed lines itself; `collect-lens-results.sh` still runs (only respawn is skipped) so both mirrors share one derivation path.
- R4a. Budgets scale with task size. `lens-budget.sh --files N --lines L [--sections S] --kind lens|plan-lens|codex` (bundled `BUNDLE_SHARED` script): lens = `max(5m, 2m + 45s×files + 10s×(lines/100))` cap 30m; plan-lens = `max(5m, 2m + 20s×sections)` cap 30m; codex = `max(20m, 2×lens)` cap 45m. Output in seconds. Coefficients are untuned guesses (Codex ~0.5m/file from the 11.5m baseline). Computed budget printed in the range banner.
- R5. Gauntlet gains a **regression** stop condition implemented in `convergence-ledger.sh`. Identity: a ledger-owned **regression key** `sha1(file|category|normalised summary)` (lowercase, whitespace-collapsed — **no digit-stripping**, so findings differing only in a number stay distinct; bias to precision), computed by bundled `finding-key.sh` — explicitly **distinct** from the reconciler's line-anchored `(file, line, category)` dedup key. Ledger gains `--present-keys <file>` per round and `--claimed-keys <file>`; the **ledger itself** promotes a claimed key into cumulative `fixed_keys` iff it is absent from the next `pass_type: full` pass's `present_keys`, and computes `regression = present_keys ∩ fixed_keys` internally — the orchestrator passes only what it observes (present, claimed), never a fixed set. The `regression` decision slots **after success, before cap** in the priority chain. A present key ∈ fixed set → terminal `regression`, and it fires on **both pass types** (full AND confirm — a reappearance is a reappearance) while promotion stays full-pass-only. Quarantined/deferred keys never promote. `fixed_keys` persist across structural restarts. `--last-decision` never mutates or recomputes promotions — it reads persisted `fixed_keys` as-of-last-append, so a peek always agrees with the decision the append printed. Ledgers lacking the fields default to empty (no `--resume` break). Fixer output contract becomes a schema: `{claimed:[key...]}`.
- R6. *(dropped 2026-08-23 — grilled: deep-review has no lens-selection flag and confirm-subset counts would pollute the running-minimum; a clean confirm pass is already followed by a full pass.)*
- R7. Every round ends with a gate-status table (gate, status, duration_s, findings, degraded_reason). Rows are **emitted by `run-gate.sh status-row`** from the gate envelope (unit-testable); SKILL.md only says where to print them. Accepted prose seam: `duration_s` for gates 2/3 is stamped into the envelope by the orchestrator from its wall clock (gate 1's comes from `gate_run_bounded`); a missing stamp renders `-`.
- R8. Hygiene rules added to `.claude/CLAUDE.md` (repo) directly; the global `~/.claude/CLAUDE.md` change is **routed through the skills.md repo** (which owns that file — never edited from skein; the upstreaming is a manual step recorded in `## Findings`): background the full test suite; never infer CI/approval state from indirect signals (cite `gh run view`/`gh api`); security/diff reviews post scope summary first, ≤3 orienting calls, stream findings severity-first.
- R9. `format-on-edit.sh` stops stripping `# noqa`. Phase 4 first **reproduces** in a scratch dir with `ruff.toml` selecting `RUF100`, then applies `--ignore RUF100` and re-probes (hook reads `tool_input.file_path` from stdin JSON — probe must pipe JSON, not pass argv).
- R10. Claude and Codex mirrors updated for every skill change. Scripts: edit **canonical `scripts/` once**, register in `bundle-map.sh`, regenerate with `scripts/bundle-appliers.sh`; byte-identity enforced by `just parity-tests && just check-sync`. Gauntlet `lib/` additions are added to `GAUNTLET_LIB_PARITY_FILES`. SKILL.md prose is semantically aligned, not byte-identical; Codex SKILL.md edits go through `codex:rescue` then a fresh-thread self-review, **in the same phase as the Claude edit** (shape tests assert on both mirrors). Deferral of a Codex-side item is allowed ONLY for behaviour the Codex harness cannot express (e.g. Monitor/Agent-tool-specific mechanics); each such item is exempted from the both-mirror shape assertions and recorded in `docs/dev_plans/CODEX_MIRROR_BACKLOG.md` **in the same phase as the exemption lands** (Phase 5 only reviews/finalizes the backlog). Exemption wiring: shape tests read exemption IDs from `CODEX_MIRROR_BACKLOG.md` (each entry names the exempted assertion), so an exemption is itself checkable.
- R11. Every shell change is covered by a test **wired into a phase Test/Validation cmd** — the enforceable invariant is no-prose-only behaviour, not the directory; `tests/gauntlet/` and new `tests/lenses/` are the default homes for new gauntlet/lens tests (Phase 2/4 legitimately place tests under `tests/reconciliation/` and `tests/plugin/`). Prose-only items (R2 forbidden-flag note, R8) get grep shape assertions.

## Review Focus

- `convergence-ledger.sh` decision table: adding `regression` and the key flags must not change any existing decision for inputs without the flags (golden-test current outputs first, including `--resume` on a pre-change ledger).
- Regression key vs dedup key are **different by design**; the test must show a reappearing finding on a shifted line still matches, and a same-category different-summary finding does not.
- Disk-first lens results: collector must handle a truncated trailing line, a stale run-id directory, and attempt-2 merging without duplicate findings.
- Timeout interplay: a killed Codex gate must not leave a half-written output that `run-gate.sh normalize` parses as clean — envelope path ≠ tool output path; process-group kill; test with a stub that forks a SIGTERM-ignoring child.
- Mirror/bundle discipline: canonical `scripts/` + `bundle-map.sh` + `bundle-appliers.sh`; `just check-sync` green at every phase commit.
- The forbidden flag combo (R2) must be verified from transcripts (identity AND causation), or explicitly marked UNVERIFIED with the budget documented as sole defence — never shipped as an unconfirmed fact.

## Implementation Checklist

### Phase 1: Bounded Codex gate + size-scaled budgets

**Impl files:** `scripts/lens-budget.sh, scripts/lib/bundle-map.sh, plugins/skein/skills/review-gauntlet/lib/gate-bounded.sh, plugins/skein/skills/review-gauntlet/lib/run-gate.sh, plugins/skein-codex/skills/review-gauntlet/lib/gate-bounded.sh, plugins/skein-codex/skills/review-gauntlet/lib/run-gate.sh, plugins/skein/skills/review-gauntlet/SKILL.md, plugins/skein-codex/skills/review-gauntlet/SKILL.md, tests/parity/test-applier-bundle-parity.sh, justfile`
**Test files:** `tests/gauntlet/test-gate-timeout.sh, tests/gauntlet/test-lens-budget.sh, tests/gauntlet/test-gauntlet-skill-shape.sh`
**Test command:** `bash tests/gauntlet/test-gate-timeout.sh && bash tests/gauntlet/test-lens-budget.sh && bash tests/gauntlet/test-gauntlet-skill-shape.sh`
**Validation cmd:** `just parity-tests && just check-sync && just gauntlet-tests`
**Goal:** A hung external gate costs at most its budget, enforced in shell, never blocks the round, and is visibly `skipped`/DEGRADED — never silently clean; budgets are one formula, bundled, overridable in seconds.

- `scripts/lens-budget.sh` (canonical; register via `bundle_extra_for review-gauntlet` in this phase — promoted to `BUNDLE_SHARED` in Phase 2 when deep-review/review-plan start invoking it, keeping bundled==operative at every phase commit); tests: lens floor/cap, plan-lens sections, codex 20m floor / 45m cap, codex mid-range scaling (`2×lens` between floor and cap, e.g. lens 15m → codex 30m), `--lines`, override beats computed.
- `gate_run_bounded <seconds> <envelope-out> <tool-out> -- <cmd...>` in a NEW harness-neutral `lib/gate-bounded.sh` (both mirrors; sources `gauntlet-common.sh` where needed — `gauntlet-common.sh` itself is NOT touched and NOT added to parity, it legitimately diverges per harness): GNU `timeout --kill-after` when available (it signals its own process group), else a `python3 os.setsid`+exec shim creating a real process group for the kill loop (`setsid(1)` is absent on this host); on expiry remove `<tool-out>`, write DEGRADED envelope to `<envelope-out>` stamping `duration_s` and `degraded_reason`, and `pkill -f 'codex exec review'` (scoped to the gate's invocation pattern) as a belt-and-braces sweep for group-escaping descendants. `gate_run_bounded` writes the envelope on **every** exit: exit 0 → jq-wrap tool-out + stamp `duration_s`; invalid-JSON tool-out → `status: "error"` envelope; `normalize` only ever reads the envelope path. Every envelope carries optional `duration_s` (number|null) and `degraded_reason` (string|null). Add `gate-bounded.sh` to `GAUNTLET_LIB_PARITY_FILES`.
- `run-gate.sh normalize` treats the DEGRADED envelope as `skipped` (exit 4 path); `duration_s`/`degraded_reason` surface via a stderr note alongside the existing non-clean-status report (normalize's stdout stays per-finding JSONL; status-row reads the envelope directly).
- SKILL.md gate 1 (both mirrors, same phase): invoke through the helper; budget from `lens-budget.sh --kind codex`; Monitor noted as Claude-only advisory.
- R2 forbidden flag combo: first action is a 5-minute probe of the facets schema (does it preserve exact CLI invocations?); then recover identity AND causation from facets/transcripts; document or mark UNVERIFIED in `## Findings`.
- Tests: stub writes a valid `{"status":"ok","findings":[]}` tool-out then sleeps 5s with 2s budget → `skipped`, tool-out removed, `run-gate.sh normalize` on the envelope exits 4 with `notes` starting `DEGRADED:`, `duration_s` populated; stub exits 0 with truncated/invalid JSON tool-out → `status: "error"` envelope, `normalize` exits 4 (never clean); stub forking a SIGTERM-ignoring child → child dead after expiry (both timeout and shim paths); run twice with `timeout` hidden from PATH → identical envelope. New tests registered in the `justfile` `gauntlet-tests` recipe; `just gauntlet-tests` added to the Validation cmd.

### Phase 2: Disk-first streamed lens results (deep-review + review-plan)

**Impl files:** `scripts/persist-lens-result.sh, scripts/collect-lens-results.sh, scripts/lib/persist-common.sh, scripts/persist-deep-review-state.sh, scripts/lib/bundle-map.sh, plugins/skein/skills/deep-review/SKILL.md, plugins/skein/skills/review-plan/SKILL.md, plugins/skein-codex/skills/deep-review/SKILL.md, plugins/skein-codex/skills/review-plan/SKILL.md, justfile`
**Test files:** `tests/lenses/test-persist-lens-result.sh, tests/lenses/test-lens-collect.sh, tests/lenses/test-derived-lenses-state.sh, tests/lenses/test-lens-skill-shape.sh, tests/reconciliation/test-deep-review-state.sh, tests/reconciliation/test-review-plan-state.sh` (test-review-plan-state.sh unchanged — regression gate only, since `persist-review-state.sh` is not modified)
**Test command:** `bash tests/lenses/test-persist-lens-result.sh && bash tests/lenses/test-lens-collect.sh && bash tests/lenses/test-derived-lenses-state.sh && bash tests/lenses/test-lens-skill-shape.sh`
**Validation cmd:** `just parity-tests && just check-sync && just reconciliation-tests`
**Goal:** A lens's coverage and findings are on disk as it works, in one-writer-per-file attempt files under the skill's own state dir keyed by run-id; a silent lens is detectable, respawned exactly once on its unreviewed units, and `--continue` still has one source of truth.

- **Spike first (budget-wake ASSUMPTION):** before writing the 10 lens prompts, spawn one deliberately silent stub lens and prove budget-triggered collect+respawn fires in a live session; record the mechanism (Monitor vs Bash loop) in `## Findings`.
- `scripts/persist-lens-result.sh --root <repo-root> --skill --run-id --lens --attempt --type start|progress|finding|done [...]` → appends to `<state-dir>/lenses/<run-id>/<lens>.<attempt>.jsonl` (`--root` explicit, never cwd-derived). Register in `bundle_extra_for` for deep-review and review-plan; promote `lens-budget.sh` to `BUNDLE_SHARED`; regenerate.
- `scripts/collect-lens-results.sh --skill --run-id --expected <lens:units,...>` → per-lens status/coverage/unreviewed/findings merged across attempts, emitting the superset enum (`completed|partial|timed_out|errored|skipped`, absent = missing); ignores truncated trailing line; unknown run-id dir → all `missing` with `unreviewed` = full assigned list from `--expected`.
- `persist-deep-review-state.sh`: new `--from-collector` flag — orchestrator pipes `collect-lens-results.sh` stdout into persist stdin; persist maps the collector shape to `.lenses` (single writer of the summary); existing positional `lenses.json` input retained **test-only** (marked so in the script header) so current tests keep passing. Deep-review SKILL.md's incremental per-lens checkpoint prose rewired in this phase: each checkpoint = collect → `persist --from-collector` (incremental cadence kept, one derivation path). `persist-review-state.sh` NOT modified — the review-plan orchestrator reads collector output directly for its errored/timed_out report list.
- Lens prompts (5 + 5) + respawn variant (`units` := `unreviewed`, `--attempt 2`), each with a fixed preamble carrying: resolved absolute path of `persist-lens-result.sh` (orchestrator substitutes `${CLAUDE_PLUGIN_ROOT}`/`$SKILL_DIR` before spawning), absolute repo root, run-id, lens name, attempt. Budget per lens from `lens-budget.sh`, printed in banner; orchestrator reads disk first; a parseable Agent return with no `done` is written to disk by the orchestrator (attempt 1, no respawn); Codex sequential mode: orchestrator emits the lines, collector still runs, no respawn. Both mirrors' SKILL.md in this phase; new shape test `tests/lenses/test-lens-skill-shape.sh` asserts both mirrors reference `persist-lens-result.sh --type start`, `--attempt 2`, `collect-lens-results.sh`, `lens-budget.sh`, the `--continue` re-run clause (`timed_out|errored|partial|absent`), and the Codex sequential-mode clause.
- Tests (collector): done → completed; done `status:"errored"` → `errored`; orchestrator-written done `status:"skipped"` → `skipped` (and excluded from the `--continue` re-run set); start+2/5 progress → `partial 2/5`, unreviewed list of 3; attempt-2 merge → no duplicate findings; attempt-3 file (continue) merges like any attempt; attempt-1 partial + attempt-2 partial/missing → `timed_out` with merged coverage; returned-but-no-done → orchestrator-written done, no respawn; stale run-id → missing; missing dir with `--expected` units → `unreviewed` = full list; truncated last line → ignored.
- Tests (persist writer side): two sequential calls append two lines (append, never truncate); `--root` respected from a different cwd; missing required flag or unknown `--type` → non-zero exit, no file written. Derived-state test asserts the `--continue` re-run set derived from `.lenses`. New `justfile` `lens-tests` recipe runs them all.
- Dogfood `/review-plan` on this plan: commit Phase 2, **restart the `claude` process** (skill-registry cache is process-scoped), run the dogfood, then re-verify the plan marker/hash before conduct resumes Phase 3. Record in `## Findings` whether the previously silent lenses left disk records, whether per-unit progress lines landed at distinct mtimes, whether respawn succeeded, and whether a spawn cap was observed **at all** (existence, causal role, and value are all UNVERIFIED).

### Phase 3: Regression-loop stop + gate-status rows

**Impl files:** `scripts/finding-key.sh, scripts/lib/bundle-map.sh, plugins/skein/skills/review-gauntlet/lib/convergence-ledger.sh, plugins/skein/skills/review-gauntlet/lib/run-gate.sh, plugins/skein-codex/skills/review-gauntlet/lib/convergence-ledger.sh, plugins/skein-codex/skills/review-gauntlet/lib/run-gate.sh, plugins/skein/skills/review-gauntlet/SKILL.md, plugins/skein-codex/skills/review-gauntlet/SKILL.md, justfile`
**Test files:** `tests/gauntlet/test-convergence-ledger.sh, tests/gauntlet/test-regression-stop.sh, tests/gauntlet/test-finding-key.sh, tests/gauntlet/test-status-row.sh`
**Test command:** `bash tests/gauntlet/test-convergence-ledger.sh && bash tests/gauntlet/test-regression-stop.sh && bash tests/gauntlet/test-finding-key.sh && bash tests/gauntlet/test-status-row.sh && bash tests/gauntlet/test-gauntlet-skill-shape.sh`
**Validation cmd:** `just parity-tests && just check-sync && just gauntlet-tests && just lens-tests`
**Goal:** Existing ledger decisions are byte-for-byte unchanged when the key flags are absent; a reappearing fixed finding (even on a shifted line) terminates with `regression`; status rows are script-emitted.

- Golden-test current ledger outputs + `--resume` on a pre-change ledger before touching it.
- `scripts/finding-key.sh` (registered via `bundle_extra_for review-gauntlet`, NOT `BUNDLE_SHARED` — gauntlet-only, bundled==operative): regression key from a finding JSON; normalisation is lowercase + whitespace-collapse only (no digit-stripping); tests: shifted-line match, different-summary non-match, two same-file same-category findings differing only in a number → distinct keys.
- Ledger: `--present-keys`, `--claimed-keys`; per-round `present_keys`, cumulative `fixed_keys` promoted **by the ledger** (claimed ∧ absent from next full pass's present_keys; survive structural restart); decision `regression` = present ∩ fixed, slotted after success and before cap; missing fields default empty. Negative tests: claimed-but-still-present key never enters `fixed_keys` nor later fires `regression`; key present only in a `pass_type: confirm` pass never promotes; a deferred key never promotes (alongside the quarantined case); a fixed key reappearing in a `confirm` pass DOES fire `regression`; `--last-decision` on a `regression` ledger exits terminal; golden: append decision == subsequent `--last-decision` token on a regression ledger (no re-promotion on peek); malformed/missing `--claimed-keys` file → defined behaviour (error or empty), not a crash; one test per higher-priority decision rule.
- SKILL.md (both mirrors): fixer output schema `{claimed:[key...]}`; the ledger owns claimed→fixed promotion (orchestrator passes only present/claimed); stop condition 5 documented; R6 removed. Shape test greps `{claimed:` in both mirrors.
- `run-gate.sh status-row <envelope>` → one table row (`-` for null `duration_s`/`degraded_reason`; orchestrator stamps `duration_s` for gates 2/3 from its wall clock — accepted prose seam per R7); SKILL.md prints rows before the ledger decision; shape test asserts column names in both mirrors; test-status-row.sh asserts populated `duration_s` and empty `degraded_reason` on a clean envelope AND the DEGRADED envelope case (status `skipped`, `degraded_reason` populated, findings `-`/0). New tests registered in `justfile` `gauntlet-tests`.
- Dogfood: commit Phase 3, **restart the `claude` process** (skill-registry cache is process-scoped), run `/review-gauntlet` on this branch, then re-verify the plan marker/hash before conduct resumes Phase 4.

### Phase 4: Hygiene — CLAUDE.md rules + ruff hook

**Impl files:** `.claude/CLAUDE.md, /Users/vr000m/.claude/hooks/format-on-edit.sh` (global `~/.claude/CLAUDE.md` is NOT edited from skein — owned by the skills.md repo; the global change is upstreamed there as a manual step recorded in `## Findings`)
**Test files:** `tests/plugin/test-claude-md-hygiene.sh`
**Test command:** `bash tests/plugin/test-claude-md-hygiene.sh`
**Validation cmd:** `bash tests/plugin/noqa-probe.sh`
**Goal:** The four insights-report hygiene failures each have a written rule or a mechanical guard; the `# noqa` stripping is reproduced before it is fixed, and the fix is proven by the same probe.

- `tests/plugin/noqa-probe.sh`: scratch dir with `ruff.toml` `select=["RUF100"]` + file with unused `# noqa`; pipe `{"tool_input":{"file_path":...}}` into the hook via `HOOK_PATH` env var (explicit SKIP when unset/absent); exit 1 if `noqa` gone. Run against the unmodified hook first and record the reproduction (or its absence) in `## Findings` — also record which project config triggered the original stripping (or that it could not be identified), distinguishing mechanism-reproduced from incident-explained (the probe reproduces by construction since it selects RUF100 itself).
- `format-on-edit.sh:18`: `ruff check --fix --ignore RUF100`.
- Repo `.claude/CLAUDE.md`: `## Testing`, `## Facts vs Inference`, `## Security & Diff Reviews`; the same three sections are drafted for the global file but **upstreamed via the skills.md repo** (owner of `~/.claude/CLAUDE.md`), recorded in `## Findings` as a manual step. Test asserts headings — repo file unconditionally, global via `GLOBAL_CLAUDE_MD` env var with explicit SKIP when unset/absent (the SKIP path is the norm until the skills.md sync lands).

### Phase 5: Docs, manifests, backlog

**Impl files:** `CHANGELOG.md, AGENTS.md, docs/dev_plans/README.md, plugins/skein/.claude-plugin/plugin.json, plugins/skein-codex/.codex-plugin/plugin.json, docs/dev_plans/CODEX_MIRROR_BACKLOG.md`
**Test files:** `tests/parity/test-applier-bundle-parity.sh, tests/plugin/test_manifests.sh`
**Test command:** `just parity-tests && just check-sync && bash tests/plugin/test_manifests.sh`
**Validation cmd:** `just gauntlet-tests && just lens-tests`
**Goal:** Docs reflect the shipped contracts; both manifests bumped (version consistency asserted by test_manifests.sh); any deferred Codex-side item recorded.

- Bump both manifests (0.6.0); changelog; AGENTS.md gotchas (bundle discipline for new scripts, one-writer-per-file lens state).
- Update `docs/dev_plans/CODEX_MIRROR_BACKLOG.md` only for items the Codex harness cannot express (per narrowed R10); each entry names the exempted shape assertion.

## Technical Specifications

### Files to Modify
- `scripts/lib/bundle-map.sh` — Phase 1: `lens-budget.sh` via `bundle_extra_for review-gauntlet`; Phase 2: promote `lens-budget.sh` to `BUNDLE_SHARED`, add `persist-lens-result.sh`, `collect-lens-results.sh` to `bundle_extra_for` deep-review/review-plan; Phase 3: `finding-key.sh` via `bundle_extra_for review-gauntlet` (bundled==operative at every phase commit).
- `scripts/lib/persist-common.sh` (canonical; bundled to both skills) — append-line helper.
- `scripts/persist-deep-review-state.sh` — new `--from-collector` flag (collector stdout piped to persist stdin; persist maps the shape; positional `lenses.json` input retained test-only). `scripts/persist-review-state.sh` is NOT modified — no `.lenses` object, no `--continue` consumer; the review-plan orchestrator reads collector output directly.
- `justfile` — new `lens-tests` recipe; new tests added to `gauntlet-tests` and plugin recipes.
- `plugins/skein{,-codex}/skills/review-gauntlet/lib/run-gate.sh` — DEGRADED envelope → `skipped`; `status-row` subcommand; `duration_s`/`degraded_reason` surfaced via stderr note (stdout stays per-finding JSONL).
- `plugins/skein{,-codex}/skills/review-gauntlet/lib/convergence-ledger.sh` — `--present-keys`/`--claimed-keys`, ledger-owned promotion to `fixed_keys` (full passes only), `regression` decision after success / before cap, fires on full AND confirm passes; `--last-decision` reads persisted state, never re-promotes.
- `plugins/skein{,-codex}/skills/review-gauntlet/SKILL.md` — gate 1 invocation; stop condition 5; R6 removed; fixer schema; status rows.
- `plugins/skein{,-codex}/skills/deep-review/SKILL.md`, `.../review-plan/SKILL.md` — streamed lens protocol, budgets, collect/respawn, derived `.lenses` via `--from-collector` (deep-review's incremental-checkpoint prose rewired to collect→persist), Codex sequential mode.
- `tests/parity/test-applier-bundle-parity.sh` — `GAUNTLET_LIB_PARITY_FILES` += `gate-bounded.sh` (`gauntlet-common.sh` stays excluded — it legitimately diverges per harness).
- `.claude/CLAUDE.md`, `~/.claude/hooks/format-on-edit.sh:18` (global `~/.claude/CLAUDE.md` upstreamed via skills.md, not edited here).

### New Files to Create
- `scripts/lens-budget.sh`, `scripts/finding-key.sh`, `scripts/persist-lens-result.sh`, `scripts/collect-lens-results.sh` (canonical; bundled copies generated, never hand-edited)
- `plugins/skein{,-codex}/skills/review-gauntlet/lib/gate-bounded.sh` (harness-neutral, in `GAUNTLET_LIB_PARITY_FILES`)
- `tests/gauntlet/test-gate-timeout.sh`, `test-lens-budget.sh`, `test-regression-stop.sh`, `test-finding-key.sh`, `test-status-row.sh`
- `tests/lenses/test-persist-lens-result.sh`, `test-lens-collect.sh`, `test-derived-lenses-state.sh`, `test-lens-skill-shape.sh`
- `tests/plugin/test-claude-md-hygiene.sh`, `tests/plugin/noqa-probe.sh`

### Architecture Decisions
- **Timeout in shell, not prose**; process-group kill; envelope path ≠ tool output path.
- **Decision (grilled): `gate_run_bounded` lives in a new harness-neutral `lib/gate-bounded.sh`** added to `GAUNTLET_LIB_PARITY_FILES`; `gauntlet-common.sh` stays out of byte-parity (it legitimately diverges per harness). Process group via GNU `timeout` when present, else `python3 os.setsid`+exec shim (`setsid(1)` absent on this host).
- **Decision (grilled): lens status enum is the superset** `completed|partial|timed_out|errored|skipped` (absent = missing), emitted by the collector and persisted verbatim; a parseable Agent return with no `done` on disk is written to disk by the orchestrator (attempt 1, no respawn); the orchestrator owns assigned-units and supplies them via `--expected`; budget-wake is a named ASSUMPTION verified by a Phase 2 spike.
- **Decision (grilled): asymmetric state seam** — only deep-review derives `.lenses` (it has the `--continue` consumer); `persist-review-state.sh` untouched; Codex sequential mode still runs the collector (only respawn skipped).
- **Decision (grilled): ledger-owned claimed→fixed promotion** — `--claimed-keys` replaces `--fixed-keys`; the ledger promotes and computes `present ∩ fixed`; `regression` slots after success, before cap; key normalisation drops digit-stripping.
- **Decision (grilled): R10 narrowed** — Codex-side deferral only for harness-inexpressible behaviour, exempted from shape assertions, recorded in `docs/dev_plans/CODEX_MIRROR_BACKLOG.md` in the same phase as the exemption; shape tests read exemption IDs from the backlog file.
- **Decision (grilled): `--continue` writes attempt 3+** — the attempt counter continues monotonically at the next free number under the same run-id; one-writer-per-file holds (fresh file per attempt); the one-respawn rule is scoped per orchestrator invocation, so `timed_out` stays in the `--continue` re-run set without contradiction.
- **Decision (grilled): orchestrator-emitted `skipped`** — done enum is `completed|errored|skipped`; the orchestrator writes the done line for a deliberately-skipped lens, which stays in `--expected`; `skipped` is terminal for `--continue`.
- **Decision (grilled): gate envelope on every exit** — `gate_run_bounded` always writes the envelope (success = jq-wrapped tool-out + `duration_s`; invalid-JSON tool-out = `status: "error"`); `normalize` reads only the envelope path, closing the half-written-output hole.
- **Decision (grilled): `--from-collector` persist seam** — collector stdout piped to persist stdin; persist maps the shape; deep-review's incremental checkpoints rewired to collect→persist (single derivation path, cadence kept); positional input test-only.
- **Decision (grilled): process-group escape named** — codex-descendants-stay-in-group is an ASSUMPTION; dogfood `pgrep -f 'codex exec'` orphan check plus scoped `pkill -f 'codex exec review'` fallback in the expiry path.
- **Decision (grilled): global CLAUDE.md routed through skills.md** — skein edits only the repo `.claude/CLAUDE.md`; the global change is upstreamed to its owning repo (manual step, recorded in `## Findings`).
- **Decision (grilled): regression fires on both pass types** — `present ∩ fixed` terminates on full AND confirm passes; promotion stays full-pass-only; `--last-decision` never re-promotes.
- **Lens writes, orchestrator reads**; one writer per file (attempt-suffixed) removes every locking/atomicity assumption; run-id directory removes stale reads; derived `.lenses` keeps `--continue` on one source of truth.
- **Size-scaled budgets, one formula**, bundled via `BUNDLE_SHARED` — no cross-skill `lib/` sourcing.
- **Decision (grilled): drop R6** — deep-review has no lens-selection flag; confirm-subset counts would pollute the running-minimum; a clean confirm pass is already followed by a full pass.
- **Decision (grilled): ledger-owned regression key** `sha1(file|category|normalised summary)`, distinct from the line-anchored dedup key; a missed regression degrades to today's cap behaviour, while a false positive would halt a healthy run — so bias to precision.
- **Decision (grilled): lens state under each skill's existing state dir** (`.deep-review/lenses/<run-id>/`, `.review-plan/lenses/<run-id>/`) — no fourth state dir, no `.gitignore` change.
- **One respawn, not backoff loops.**
- **Extend `convergence-ledger.sh`, don't add a second engine.**
- **`--ignore RUF100` over dropping `--fix`**, contingent on Phase 4 reproduction.
- Deferred: unified findings ledger; CI watchdog; issue-swarm.

### Dependencies
- Ambient: `bash`, `jq`, `python3`, `sha1sum`/`shasum`; `timeout` optional (Homebrew coreutils) with `python3 os.setsid` shim fallback; **no `flock`, no `setsid`** on this host. No manifests in repo.

### Integration Seams

| Seam | Writer | Caller | Contract |
|------|--------|--------|----------|
| Gate envelope (all exits) | `gate_run_bounded` (`lib/gate-bounded.sh`) | `run-gate.sh normalize` | envelope written on EVERY exit (success = jq-wrapped tool-out + `duration_s`; invalid-JSON tool-out = `status: "error"`; expiry = `status: skipped`, `notes` starts `DEGRADED:`, exit 4, tool-out removed); envelope at separate path; normalize reads only the envelope; every envelope carries optional `duration_s`/`degraded_reason` |
| Lens attempt file | lens subagent via `persist-lens-result.sh --root` | `collect-lens-results.sh` | `<state-dir>/lenses/<run-id>/<lens>.<attempt>.jsonl`; one writer per attempt file; attempts monotonic (`--continue` = next free number); typed lines `start/progress/finding/done` (done enum `completed|errored|skipped`, `skipped` orchestrator-emitted); cross-attempt dedup by reconciler `(file, line, category)` signature; status enum `completed|partial|timed_out|errored|skipped` (absent = missing); returned-but-no-done → orchestrator writes done (attempt 1) |
| Assigned units | orchestrator | `collect-lens-results.sh --expected <lens:units,...>` | orchestrator owns the list; missing lens ⇒ `unreviewed` = full assigned list |
| Derived lens summary | `persist-deep-review-state.sh --from-collector` (collector stdout on stdin; positional input test-only) | deep-review `--continue` | `.lenses` object; disk attempt files are the source; incremental checkpoints = collect→persist; review-plan orchestrator reads collector output directly (no `.lenses`) |
| Regression key | `finding-key.sh` | orchestrator → ledger `--present-keys/--claimed-keys` | `sha1(file|category|normalised summary)`, lowercase + whitespace-collapse only; never the reconciler's key |
| Fixer output | fixer subagent | orchestrator → ledger | `{claimed:[key...]}`; ledger promotes claimed→fixed after next full pass; quarantined/deferred excluded |
| Lens budget | `lens-budget.sh` | all three orchestrators | seconds; floors 5m lens / 5m plan-lens / 20m codex; caps 30m / 30m / 45m |
| Status row | `run-gate.sh status-row` | gauntlet round loop | columns gate, status, duration_s, findings, degraded_reason |

## Architecture & Call Flow

Component graph:

```mermaid
graph LR
    G["review-gauntlet orchestrator"] -->|"gate_run_bounded (lens-budget codex)"| CX["codex exec review"]
    G -->|"invokes top-level"| DR["deep-review orchestrator"]
    DR -->|"Agent x5 (+1 respawn)"| L["lens subagents"]
    L -->|"persist-lens-result.sh (streamed)"| D[".deep-review/lenses/run-id/lens.attempt.jsonl"]
    DR -->|"collect-lens-results.sh"| D
    DR -->|"derive .lenses"| ST[".deep-review/latest-*.json"]
    G -->|"finding-key.sh → present/claimed keys"| CL["convergence-ledger.sh"]
    G -->|"status-row"| RG["run-gate.sh"]
    RP["review-plan orchestrator"] -->|"Agent x5 (+1 respawn)"| L
    RP -->|"collect (reads directly, no .lenses)"| D2[".review-plan/lenses/run-id/"]
```

Trigger order (one gauntlet round):

```mermaid
sequenceDiagram
    participant G as gauntlet
    participant CX as codex CLI
    participant DR as deep-review
    participant L as lens agents
    participant D as state-dir/lenses/run-id
    participant CL as ledger
    G->>CX: gate_run_bounded (budget s, process group)
    CX-->>G: envelope or DEGRADED skipped
    G->>DR: invoke (top-level)
    DR->>L: spawn 5 lenses (attempt 1)
    L->>D: start / progress / finding lines during review; done before return
    DR->>D: collect after budget; respawn partial/missing once (attempt 2, unreviewed units)
    DR->>DR: derive .lenses summary
    DR-->>G: findings
    G->>CL: tallies + present-keys + claimed-keys (ledger promotes fixed after full pass)
    CL-->>G: continue | confirm | regression | cap | ...
    G-->>G: print status rows
```

Context lifecycle:

| Step | Trigger | Enters context | Cleared/persisted | Turn boundary |
|------|---------|----------------|-------------------|---------------|
| 1 | gate 1 | Codex envelope (or DEGRADED) | envelope file | budget expires or tool exits |
| 2 | lens spawn | prompt + diff/plan + units, no parent history | typed lines streamed to attempt file | lens completes or budget expires |
| 3 | collect | JSON summary of disk state only | attempt-2 file for respawn; derived `.lenses` | after ≤1 respawn |
| 4 | ledger | tallies + keys | ledger state file | decision printed |

## Testing Notes

### Test Approach
- [ ] Shell unit tests per phase (stub `codex` incl. SIGTERM-ignoring child; stub lenses writing/not writing; ledger goldens incl. `--resume`)
- [ ] `just parity-tests && just check-sync` at every phase commit
- [ ] Dogfood: `/review-plan` on this plan after Phase 2; `/review-gauntlet` on this branch after Phase 3 (both preceded by commit + `claude` process restart — skill-registry cache is process-scoped)
- [ ] `tests/plugin/noqa-probe.sh` before and after the hook change

### Test Results
- [ ] All existing tests pass
- [ ] New tests added and passing
- [ ] Dogfood runs recorded in `## Findings`

### Edge Cases Tested
- [ ] `timeout` absent → PID-group fallback, identical envelope
- [ ] Tool child ignores SIGTERM → still dead after expiry; envelope intact
- [ ] Lens killed mid-write → truncated last line dropped; `partial` with coverage
- [ ] Attempt-2 merge → no duplicate findings
- [ ] Stale run-id directory → `missing`, not `completed`
- [ ] Regression key: shifted line still matches; two findings differing only in a number stay distinct; quarantined key never `regression`; key survives structural restart
- [ ] Claimed-but-still-present key never promotes to fixed; confirm-pass presence never promotes; deferred key never promotes; fixed key reappearing in a confirm pass fires `regression`; `--last-decision` on `regression` exits terminal and agrees with the appended decision (no re-promotion on peek)
- [ ] Gate success path: exit 0 with valid tool-out → clean envelope with `duration_s`; exit 0 with truncated/invalid JSON → `status: "error"` envelope, never clean
- [ ] Collector emits `errored` (done status errored) and `skipped` (orchestrator-emitted done); `skipped` excluded from `--continue` re-run set; attempt-3 continue file merges cleanly
- [ ] Returned-but-no-done → orchestrator writes done, no respawn; attempt-1 partial + attempt-2 partial/missing → `timed_out` with merged coverage
- [ ] Pre-change ledger with `--resume` → unchanged decision

## Acceptance Criteria

- Stub `codex` writing a valid tool-out then sleeping 5s with a 2s budget → gate `skipped`/DEGRADED, tool-out removed, `normalize` exits 4, `duration_s` stamped, child process dead (timeout and shim paths). Stub exiting 0 with invalid JSON → `status: "error"` envelope, `normalize` exits 4.
- Lens stub writing `done` → completed; `done` status errored → `errored`; orchestrator-emitted `skipped` → terminal for `--continue`; `start`+2/5 `progress` → `partial 2/5`, respawned once on 3 units, merged without duplicates; nothing twice → `timed_out`; parseable return with no `done` → salvaged, no respawn.
- Ledger goldens unchanged without key flags; `regression` fires on a reappearing fixed key on a shifted line (full or confirm pass), and only then (never from claimed-but-still-present keys; promotion never from confirm-pass or deferred/quarantined keys); `--last-decision` agrees with the appended decision.
- `run-gate.sh status-row` emits the five columns; shape tests (gauntlet + lens SKILL.md) pass on both mirrors; R2 acceptance: `Forbidden flags:` line or `UNVERIFIED` marker, exactly one form.
- `lens-budget.sh`: `--files 122` → 30m cap; `--files 3` → 5m floor; `--kind codex` → 20m floor / 45m cap; override wins.
- `noqa-probe.sh` fails on the old hook (or reproduction recorded as not reproducible) and passes on the new one.
- Repo `.claude/CLAUDE.md` carries the three new sections (global upstreamed via skills.md, recorded in `## Findings`); `just parity-tests && just check-sync` green; both manifests bumped (test_manifests.sh); Codex mirrors aligned per phase.
- Code reviewed and approved; tests passing; docs updated.

<!-- reviewed: 2026-08-24 @ e168c2e1ba049f5ee6f86c0a551f852725f0e004 -->

<!-- /review-plan writes the marker line above. Everything below is the workspace: edits here do NOT invalidate the marker. -->

## Progress

- [x] Phase 1: Bounded Codex gate + size-scaled budgets
- [x] Phase 2: Disk-first streamed lens results
- [x] Phase 3: Regression-loop stop + gate-status rows
- [x] Phase 4: Hygiene — CLAUDE.md rules + ruff hook
- [ ] Phase 5: Docs, manifests, backlog

## Status

| Date | Update |
|------|--------|
| 2026-08-23 | Plan created from insights report; branch `feature/review-skills-resilience`. |
| 2026-08-23 | Added R4a: budgets scale with diff size via `lens-budget.sh`; coefficients are untuned guesses to revisit after dogfood. |
| 2026-08-23 | `/review-plan` run 1: 36 findings (5 Critical, 21 Important, 10 Minor), 8 contradictions. All addressed; three grilled decisions: drop R6; ledger-owned regression key; lens state under per-skill state dirs with attempt files. |
| 2026-08-23 | User confirmed Architecture & Call Flow; lens file made append-only with typed `start/progress/finding/done` lines so partial coverage is observable and respawn is scoped to unreviewed units. |
| 2026-08-24 | `/review-plan` run 2: 35 raw findings reconciled to 34 (5 lenses + contradiction pass; 2 Critical, 19 Important, 13 Minor; 6 contradictions). All 34 accepted; five grilled decisions applied: gate-bounded.sh (not gauntlet-common.sh) in parity; superset lens enum + return salvage + orchestrator-owned units + budget-wake spike; asymmetric state seam (review-plan persist untouched, Codex mode keeps collector); ledger-owned claimed→fixed, regression after success/before cap, no digit-stripping; R10 narrowed for harness-inexpressible deferrals. |
| 2026-08-24 | `/review-plan` run 3: 32 raw findings reconciled to 31 (0 Critical, 16 Important, 15 Minor; 4 contradictions; codebase-claims clean 89/89). All 31 accepted; eleven grilled decisions applied: --continue writes attempt 3+ (one-respawn per invocation); orchestrator-emitted `skipped` done status; gate envelope on every exit (invalid JSON never clean); --from-collector persist seam + checkpoint rewire; process-group-escape ASSUMPTION + pgrep/pkill; global CLAUDE.md routed via skills.md; regression fires on both pass types; Phase 1/3 Validation cmds carry gauntlet-tests; R11 scoped to the wired-test invariant; Review Focus softened to verified-or-UNVERIFIED (identity AND causation); backlog entries land in-phase with shape-test exemption IDs read from the backlog. Note: this run itself hit the silent-lens failure mode again — codebase-claims and the contradiction pass both went idle without delivering and needed a mailbox nudge; further evidence for R3/R4. |

## Findings

- **Phase 4 noqa reproduction (2026-08-24)**: `tests/plugin/noqa-probe.sh` run against the UNMODIFIED `~/.claude/hooks/format-on-edit.sh` (pristine copy): `STRIPPED: # noqa removed by hook run (ruff 0.16.4)`, exit 1 — mechanism-reproduced (RUF100 selected → `ruff check --fix` deletes the unused `# noqa`). The original incident's project config was NOT identified (incident-explained only by construction: the probe selects RUF100 itself). After `--ignore RUF100` on line 18: `SURVIVED`, exit 0 by the same probe. Deviation: probe defaults `HOOK_PATH` to `$HOME/.claude/hooks/format-on-edit.sh` when unset so the plan's bare Validation cmd is non-vacuous; explicit SKIP only when that is absent too.
- **Phase 4 manual upstream step (pending)**: global `~/.claude/CLAUDE.md` is owned by the skills.md repo — the three sections (`## Testing`, `## Facts vs Inference`, `## Security & Diff Reviews`, same text as repo `.claude/CLAUDE.md`) must be added there and synced; until then `test-claude-md-hygiene.sh` SKIPs the global check. The hook edit lives outside the repo (not committed) — also upstream to skills.md.

- **Phase 3 post-review fix (2026-08-24)**: 9 findings (Opus 1 Critical + 5, Codex 3) addressed via architect→fix(+codex:rescue)→test→verify chain; all VERIFIED FIXED end-to-end. Headline: same-round claimed→fixed promotion was unreachable in the real round ordering — restored the plan's deferred semantics (`pending_claims` recorded after evaluation, promoted only by a later COMPLETE full pass: pass_type==full ∧ unresolved==0 ∧ present_supplied); the three vacuous-promotion paths (same-round, degraded gate, absent --present-keys) are independently blocked. finding-key digest now length-prefixed (file verbatim, category folded) — key scheme changed pre-release, no migration needed. Deliberate deviation: fixer `{claimed:[...]}` carries finding OBJECTS (orchestrator derives keys via finding-key.sh), narrowing R5's `[key...]` wording. Residual: C1/C2 SKILL.md wiring verified by grep/shape-tests only; the applier-manifest→annotated-envelope jq join is unexercised by CI (runtime-only path) — the Phase 3 gauntlet dogfood should exercise it.

- **Phase 2 dogfood deferred (2026-08-24)**: operator resumed conduct without the claude-process restart the dogfood requires (skill-registry cache is process-scoped). Dogfood of /review-plan disk-first lenses to be run after this conduct session ends, alongside the Phase 3 gauntlet dogfood.

- **Phase 2 post-review fix (2026-08-24)**: 14 findings (10 Opus, 4 Codex-mirror) addressed via architect→fix(+codex:rescue for Codex mirrors)→test→verify chain; 14/14 VERIFIED FIXED (O10's prose gap closed in a follow-up one-liner across all 4 mirrors). Headlines: persist/collect id validation (charset whitelist + root-bounded symlink guard) closes a path-traversal write; collector `--attempts <lens>:<n>` makes a spawned-but-silent attempt report `timed_out` (effective=max(spawned,files)); `--findings-jsonl` normalizer is now the single reconciliation input; per-lens-deadline respawn semantics (D3) replace blanket respawn; comma-bearing units rejected (D1). Known accepted: `--findings-jsonl` emits `line` as a string, reconcile coerces to number — flagged for a future strict consumer.

- **Phase 2 spike (2026-08-24, budget-wake ASSUMPTION → VERIFIED)**: mechanism is a `Bash(run_in_background)` sleep timer, not Monitor. Evidence from live session: (a) a deliberately silent stub lens (Haiku, wrote no files) returned in ~2.5s with no disk record — the orchestrator can detect the empty state dir and owns writing the `done` record for a parseable-return-no-done lens (no respawn, per plan); (b) an independent background `sleep 45` timer re-invoked the orchestrator on expiry while the session idled, proving the orchestrator wakes at budget even when a lens is still pending, and can run collect + respawn at that point. Monitor remains a Claude-only advisory alternative; the timer is harness-portable for the Claude side. Codex sequential mode unaffected (no concurrent spawn there).

- **Phase 1 post-review fix (2026-08-24)**: mid-phase reviewer found 6 issues (1 Critical: exit-137 false-clean). All fixed via architect→fix→test→verify subagent chain and verified empirically. Deviation from contract prose: the R1/Phase-1 `pkill -f 'codex exec review'` belt-and-braces sweep was REPLACED by a pgid-scoped sweep (sidecar pgid file, pgrep -g, guards against pgid 0/1/self) — a host-wide pattern kill can hit concurrent sessions or the orchestrator's own wrapper. Expiry predicate is now measurement-backed: exit!=0 AND (exit==124 OR duration>=budget); shim emits GNU's 124/137 alphabet; budgets <1 rejected (lens-budget exit 2, gate_run_bounded rc 2, no stale envelope).

- 2026-08-23 (source: insights report 2026-08-23): Codex gate 25/44/90+ min vs ~11.5 min baseline; lens mailbox silence + spawn cap; 2/5 review-plan lenses silent (memory item open); 3 security reviews interrupted mid-exploration; PyPI gate wrongly inferred from run duration; ruff hook stripped `# noqa`; full suite > 2-min foreground timeout.
- 2026-08-23 (Explore): convergence cap/K logic already exists in `convergence-ledger.sh` — scope of item (3) narrowed to regression detection + affected-lens confirm + status table.
- 2026-08-23 (verified): `~/.claude/hooks/format-on-edit.sh:18` runs `ruff check --fix` — the `# noqa` stripping mechanism.
- UNVERIFIED: flag attribution for the 90-minute Codex hang — both the exact combination (identity) AND that flags caused the hang at all (causation) — to be recovered from session facets/transcripts in Phase 1; first action is a 5-minute probe of the facets schema.
- 2026-08-24 (dogfood, run 2): all six review subagents (5 lenses + contradiction pass) went idle WITHOUT delivering their reports; each required a follow-up mailbox message before returning findings. Exactly the silent-lens failure mode this plan targets — supports R3/R4's disk-first design and the budget-wake spike.

- 2026-08-24 (dogfood, run 3): silent-lens failure reproduced twice more — codebase-claims lens and the contradiction pass each went idle without delivering their report and required a mailbox nudge before returning findings (both returned complete work on the nudge, i.e. the work was done but never sent).
- TODO (manual, from run 3): upstream the three hygiene sections (`## Testing`, `## Facts vs Inference`, `## Security & Diff Reviews`) to the skills.md repo, which owns `~/.claude/CLAUDE.md` — skein does not edit that file directly.

### Review Waivers

- none (run 1, 2026-08-23)
- none (run 3, 2026-08-24 — all 31 findings addressed, none waived)

## Issues & Solutions

## Final Results
