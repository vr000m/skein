# Task: prompt-audit cleanup, Codex mirror — dated prompting patterns across skein skill prompts

**Status**: Not Started
**Component**: meta
**Assigned to**: unassigned
**Priority**: Low
**Branch**: `chore/prompt-audit-cleanup` (created in Phase 0, not yet existing)
**Created**: 2026-09-03
**Completed**:
**Review Gates**: none

## Objective

Land the high- and medium-confidence findings of a fresh `/claude-api prompt-audit` over every shipped skein skill prompt (both mirrors) and the project `.claude/CLAUDE.md`, keeping every machine anchor that a parity script or test greps for byte-exact, and hand the global-file findings to the sync-computer repo as a follow-up.

## Context

**Companion plan.** This is the Codex half of a two-file plan. `docs/dev_plans/20260903-prompt-audit-claude.md` is the Claude half; it runs after every phase here is ticked, and its `L` phases align to the text Codex landed here. The review gauntlet runs once, from the Claude plan.

**Provenance.** An earlier version of this plan was reconstructed from a compacted transcript of a 2026-09-02 audit run and carried 38 findings. On 2026-09-03 the audit was re-run cleanly in four scopes (A: conduct/deep-review/dev-plan/review-plan; B: fan-out/review-gauntlet/release; C: content-draft/content-review/spec-compliance/plan-view/rfc-finder/grill/update-docs; D: the two CLAUDE.md files) with exact before/after text and out-of-band guard greps. The fresh run is the sole finding source here. Old findings not reproduced by the fresh run are dropped: old #4 (conduct `anymore`, line 364 now reads as the `full`-only rule with no migration phrasing) and old #36 (global "Reuse prior reads" bullets, judged working context). Old #38 (project Review Workflow lacks the global's first bullet) is resolved as a decision (AD-6), not a finding.

**Methodology.** The `claude-api` skill's `shared/prompt-audit.md` (bundled with Claude Code; invoke `/claude-api prompt-audit` to load it — the on-disk path is version-specific). Three of its rules govern every hunk below:

1. Context is never cruft. Audience, environment facts, tool contracts and the *reasons* behind a constraint stay even when a grep pattern matches; only the dated wrapper (dates, retired model names, incident IDs, "now"/"the old X" framing) goes.
2. A removal is complete only when everything that references the removed text goes too: a test assertion, a normalizer regex, a doc pointer. A prompt fixed while its guard still greps the old string is a broken build, not a cleanup.
3. Rewrites beat bare deletions wherever the instruction has a live purpose: re-express it in present tense rather than dropping the concern.

**Dominant pattern.** Leaked internal rule IDs (`R1`, `R3`, `R6`, `R7`, `C1`, `C2` — dev-plan review-round labels) and history narratives (dated gate results, incident reports, "before this skill existed"). Baseline `rg -n '\b[RC][0-9]\b' plugins/skein plugins/skein-codex --glob '*.md'` = 29 lines on 2026-09-03.

**Ownership.** `~/.claude/CLAUDE.md` is owned by the sync-computer repo (`AGENTS.md:103`, `:165`) and is not modified here. The project `.claude/CLAUDE.md` is the source of truth for skein workflow rules in this plan.

## Requirements

- Every hunk in the apply set lands in both mirrors where a twin exists: a Codex commit then a Claude commit per mirror pair, with parity green after the Claude commit.
- Harness ownership (AD-8): Claude implements only Claude-mirror (`plugins/skein/`) and project `.claude/CLAUDE.md` hunks. Every Codex-mirror hunk (`plugins/skein-codex/`), the Codex delegation-idiom set (AD-4), and any change that alters behaviour Codex derives from `AGENTS.md` is handed to Codex via `codex:rescue` for review and implementation; Claude does not apply those hunks itself.
- Every literal a script or test greps for survives byte-exact, or the guard is edited in the same hunk and commit (see the guard map).
- `just check-prompt-parity`, `just check-sync`, `just parity-tests`, `just gauntlet-tests`, `just lens-tests` and `just plugin-tests` are green after every mirror pair and at the end.
- No flag-only item is applied without a recorded user decision (see the flag-only decisions section of the Claude plan).
- Nothing outside this repo is edited; global-file hunks are handed off verbatim.

## Audit Findings

Legend. **Conf** High/Med. **Guard** = script/test that greps the touched text (`none` = grepped `scripts/`, `tests/`, `justfile`, `plugins/*/skills/*/scripts/`, zero hits). **GENERIC** = inside a `<!-- BEGIN/END GENERIC -->` block (all findings: no; the only blocks are deep-review 591–619, review-plan 116–729, dev-plan 110–170, and no hunk falls inside one). **Mirror** = which mirrors change. After text is verbatim. Before text is verbatim when quoted inline; a paragraph-length Before is identified by line and its opening/closing words and must be re-diffed against live text at the start of the phase that applies it.

### `conduct/SKILL.md` (Claude + Codex)

- **A-F2** Claude :208 — High, rewrite, guard none, Claude only. Before: the sentence `**Pre-implementation audit (Phase 1)**: today's three increments … equivalent return point.` After: `Each of the three call sites invokes the helper only after the failure signature is observable to the conductor, so \`iteration_count\` at the bound-check point reflects the failure that triggered it.` (next sentence, naming `helper-is-single-increment-source-three-sites`, unchanged).
- **L1** Claude :237 — High, rewrite, guard `tests/parity/test-spawn-tiers.sh:295` pins `opus/high:` total = 6 (kept). Before: `<!-- opus/high: it reviews code, so it earns the review tier under the two-tier policy (R1) even though it is only advisory -->` After: `<!-- opus/high: it reviews code, so it earns the review tier under the two-tier policy (AGENTS.md Model/Effort Policy) even though it is only advisory -->`.
- **L2** Codex :41 — High, rewrite, guard `test-spawn-tiers.sh:270` asserts `R3 why: code review is judgment work` → change the assertion to `code review is judgment work, so the advisory reviewer gets the review tier` in the same commit. Before: `… when supported. R3 why: code review is judgment work, so the advisory reviewer gets the review tier.` After: `… when supported. Code review is judgment work, so the advisory reviewer gets the review tier.`
- **A-F8a** Claude :252 `(Phase 4)`, :254 (see A-F13), :267, :279 `(Phase 3)`, :359 `(the Phase 3 marker; …)`, :393 `(Phase 5)`, :434 `Phase 3 bumps Claude-side to \`2\``, :436; Codex :250 (see A-F13), :378 `(Phase 5)` — High, remove the tag, guard none. Two sites are rewrites: Claude :267 Before `The CI-parity gate (Phase 3) introduces a result-file path that releases the lock and re-enters on resume, producing \`lock_acquisitions == 2\` for the production gate flow — but Phase 2 itself does not exercise that path.` After `The CI-parity gate's result-file path releases the lock and re-enters on resume, producing \`lock_acquisitions == 2\` for the production gate flow.`; Claude :436 Before `### Fields introduced for the CI-parity gate (Phase 3, schema_version 2)` After `### Fields introduced for the CI-parity gate (schema_version 2)`. For :434 rewrite `Phases 1-2 (Claude-side) write 1; Phase 3 bumps Claude-side to \`2\`` as `Claude-side writes \`2\`` (re-diff against live text first; the schema_version value is the operative fact). Elsewhere delete the parenthetical only.
- **A-F9** Claude :229 — Med, rewrite, guard none. Before `- **\`test_contract_mismatch\` exception** is unchanged: if the previous implementer report set` After `- **\`test_contract_mismatch\` exception**: if the previous implementer report set`.
- **A-F10a** Claude :363 remove ` Current behavior is byte-unchanged on every plan that does not explicitly opt in.`; Codex :345 remove ` Current behavior is unchanged for every plan that does not explicitly opt in.` — Med, guard none (the `byte-unchanged` hits in `tests/auto-fix/test-review-plan-marker-write.sh` are that test's own text).
- **A-F13** Claude :254 + Codex :250 — Med, rewrite, guard `scripts/check-prompt-parity.sh:120` reads env var `CONDUCT_LAGGING_MIRROR_OK` (name kept). Claude After: `**Pre-commit hook scope.** \`scripts/check-prompt-parity.sh\` is invoked only from \`justfile\` recipes, never from \`.pre-commit-config.yaml\` or any other hook chain, so a boundary commit lands cleanly with hooks enabled even while one mirror's assets lag the other. Contributors invoking \`just check-prompt-parity\` during a lagging-mirror window can pass \`CONDUCT_LAGGING_MIRROR_OK="<skill>/<prompt-file>"\` to get a green exit with a stderr annotation.` Codex After: `Pre-commit hook scope: \`scripts/check-prompt-parity.sh\` is invoked from \`justfile\` recipes only, not from \`.pre-commit-config.yaml\` or the hook chain. Codex mirror work can therefore land while shared prompt-parity assets are handled in their separate boundary.`

### `deep-review/SKILL.md` (Claude + Codex)

- **A-F3** Claude :38 + Codex :377 — High, rewrite, guard none. Before `- **Status enum is now the superset** \`completed | partial | timed_out | errored | skipped\` (absent key = missing),` After `- **Status enum** is \`completed | partial | timed_out | errored | skipped\` (absent key = missing),`.
- **A-F4** Claude :51; Codex :298-300 (and review-plan below) — High, rewrite, guard none. Claude After: `\`collect-lens-results.sh\` also emits \`missing\`, and \`persist-deep-review-state.sh\` persists it verbatim; stated as a complement, any status added to the enum later is covered without editing this rule.` Codex After (two lines): `The collector also emits \`missing\`, and any status added to the enum later` / `is covered without editing this rule — which an enumerated list would not be.` Before in each case is the sentence naming `the old … allowlist` / `under the old … list … never ran.`
- **A-F5** Claude :122 — High, rewrite, guard none. After: `Concurrent-worktree detection happens inline in §1a (single \`git worktree list\` call there) — do not split it across a section boundary, or the informational line is silently dropped when §1a is reordered or skipped.`
- **A-F8b** Claude :37, :173, :635; Codex :117, :287, :376 — High, guard none. Claude :37 After: `- **Disk-first lens results.** Each checkpoint is \`collect-lens-results.sh\` (reads the per-lens attempt files under \`.deep-review/lenses/<run-id>/\`) piped into \`persist-deep-review-state.sh --from-collector\` (derives \`.lenses\` from the collector's shape) — a single derivation path. Never assemble a per-lens object by hand.` :635 `(recovering them is the point of Phase 2's disk-first design)` → `(recovering them is the point of the disk-first design)`. Codex :117 `(Phase 2, disk-first streamed lens results)` → `(disk-first streamed lens results)`. Others: delete ` (Phase 2)`.
- **L3** Claude :79 — High, rewrite, guard none. `per the two-tier policy (\`AGENTS.md\` Model/Effort Policy, R1):` → `per the two-tier policy (\`AGENTS.md\` Model/Effort Policy):`.
- **A-F11 + L4** Claude :433 — Med, rewrite, guard `test-spawn-tiers.sh:295` (`opus/high:` kept). After: `<!-- opus/high: code review is judgment work under the two-tier policy, same tier as the other review lenses; see AGENTS.md Model/Effort Policy -->`.
- **A-F12a** Claude :181 — Med, remove ` The respawn-exactly-once-per-invocation cap is unchanged.`, guard none.
- **Trunk snippet** (`scripts/check-trunk-snippet-parity.sh`) is anchored on `BASE=$(git symbolic-ref …` content, untouched by every hunk above.

### `dev-plan/SKILL.md` (Claude + Codex)

- **A-F6** Claude :230 + Codex :235 — High, rewrite, guard none. `so their cost is unchanged from before this skill grew an Explore step.` → `so they cost nothing beyond the main agent's own turn.`
- **A-F10b** Claude :58 `Absent or \`none\` is a strict no-op — current behavior unchanged.` → `Absent or \`none\` is a strict no-op.`; Claude :62 + Codex :62 `Absent \`**Goal:**\` is a no-op: the phase behaves exactly as it does today.` → `Absent \`**Goal:**\` is a no-op: the phase runs with no design-intent directive injected.` (Codex uses an ASCII hyphen where Claude uses an em dash; match each file's bytes). Med, guard none.
- **L5** Claude :100 — High, rewrite, guard none. `\`AGENTS.md\` Model/Effort Policy R1)` → `\`AGENTS.md\` Model/Effort Policy)`. The `<!-- sonnet/medium: … -->` comment on the same line is untouched.

### `review-plan/SKILL.md` + `rubric.md` (Claude + Codex)

- **A-F1 + L6** Claude :31 — High, rewrite, guard none (`fable/high:` is not in this paragraph). Two edits in one hunk: `(\`AGENTS.md\` Model/Effort Policy, R1)` → `(\`AGENTS.md\` Model/Effort Policy)`; and the three sentences from `The five Fable calls dispatch at` through `without changing the prose here.` → `The five Fable calls dispatch at \`model: fable\` first, with an automatic retry at \`model: opus\` for any single lens or pass whose dispatch errors out on a usage-limit/quota condition. The fallback trigger (below) reacts to the actual quota-error text, not to any assumption about which plan is active, so no plan-detection logic is needed here.` (the existing sentence beginning `The fallback trigger itself (below) is plan-agnostic` is subsumed — delete it; keep `Report which lenses …`).
- **L7** Codex :42 — High, rewrite, guard none. `This matches the R1 review-tier framing now used by deep-review's architecture lens:` → `This matches the review-tier framing of deep-review's architecture lens (\`AGENTS.md\` Model/Effort Policy):`.
- **A-F4** Claude :107 + Codex :114-116 — same Codex-form After as deep-review above.
- **A-F8c** Claude :56, :89 delete ` (Phase 2)`; Claude :612 same rewrite as deep-review :635; Codex :83, :149 delete ` (Phase 2)` — High, guard none.
- **A-F12b** Claude :97 remove ` The respawn-exactly-once-per-invocation cap is unchanged.`; Codex :102 remove the whole line — Med, guard none.
- **A-F7** `rubric.md:85` both mirrors — High, rewrite, guard `scripts/check-prompt-parity.sh:61-88` byte-diffs `rubric.md` across mirrors → same commit, identical bytes. `- Marker write/validate logic is unchanged: hash-above-marker, idempotent rewrite, placeholder validation` → `- Marker write/validate logic holds: hash-above-marker, idempotent rewrite, placeholder validation`.

### `fan-out/{SKILL.md,agent-prompt.md,test-writer-prompt.md}` (Claude + Codex) — see AD-2

- **B-06** Claude SKILL :17 `### R6: clean-context test-writer graft (live on Claude)` → `### Clean-context test-writer graft`; Codex SKILL :17 `### R6: clean-context test-writer graft (intended design, gated)` → `### Clean-context test-writer graft (gated on this harness)`; both `test-writer-prompt.md:1` `# Fan-Out Test-Writer Subagent Prompt Template (R6 contract)` → `# Fan-Out Test-Writer Subagent Prompt Template` — High, guard: line 1 of test-writer-prompt.md is outside every excised span, so byte-parity-checked → same commit both mirrors.
- **B-07** Claude SKILL :21 — High, rewrite, guard none (test :366 asserts `model: sonnet, effort: medium` against agent-prompt.md, not here). Before: the paragraph `**This topology is CONFIRMED LIVE … this manual gate.` After: `The Task tool has **no per-call \`effort\` argument**, so the test-writer's \`model: sonnet\` is set per-call while its \`effort: medium\` is *inherited* from the worker's \`--effort medium\` session. The contract mechanism — a contract-derived test catching a divergent implementation — is guarded in CI by \`plugins/skein/skills/fan-out/tests/run-seeded-divergence.sh\`. The nested-spawn topology itself is checked by \`plugins/skein/skills/fan-out/tests/check-r6-gate.sh\`, a manual skip-permissions gate deliberately kept out of \`just parity-tests\`; re-run it if nested spawning ever appears to stop honoring a per-call model.`
- **B-11** Codex SKILL :21 — High, rewrite, guard `test-spawn-tiers.sh:274` matches `reasoning_effort=medium.*fork_context=false` on line 19, which is untouched. Before: `**This topology is currently GATED, not active.** The Phase-5 live gate … which Test-phase mode is active.` After: `On this harness the separate-subagent topology is not available: a non-interactive \`codex exec\` worker cannot be shown to initialize the app-server client and spawn a nested \`spawn_agent\` test-writer without unsafe bypass flags. The worker therefore keeps a single-context Test phase — it writes and runs its own tests, but tests to the same slice contract — and the anti-cheat rule below applies in full. Full \`/conduct\` per slice remains available opt-in for genuinely multi-phase slices (see below), regardless of which Test-phase mode is active.`
- **L8** Claude SKILL :119 + Codex SKILL :115 `(R6 contract source)` → `(the slice-contract source)`; Codex SKILL :241 `the gated R6 nested test-writer topology` → `the gated nested test-writer topology` — High, guard none.
- **B-08** Claude `agent-prompt.md:67-79` — High, rewrite (not remove; AD-2), guard `scripts/check-prompt-parity.sh:178` excises the block only when it opens `<!--\nR6 status:`. After (the whole block, opener kept):
  ```
  <!--
  R6 status: the separate clean-context test-writer topology is live on the Claude
  harness. A `claude -p --dangerously-skip-permissions` worker (CLAUDECODE unset,
  exactly as fan-out.sh launches it) can spawn a nested Task subagent that honors a
  per-call model; re-check with plugins/skein/skills/fan-out/tests/check-r6-gate.sh.
  Caveat carried into the active directive below: the Task tool has NO per-call effort
  argument, so the test-writer's effort is inherited from this worker's session (which
  fan-out.sh runs at `--effort medium`), while its model IS set per-call.
  -->
  ```
- **L9** Claude `agent-prompt.md:92` `(Nested-spawn topology confirmed on Claude — see the R6 status note above.)` → `(Nested spawning is supported on this harness — see the status note above.)` — High, guard: inside the Phase-2 directive span the normalizer excises, so Claude-only is parity-safe; confirm with `just check-prompt-parity`.
- **B-09** Codex `agent-prompt.md:67-82` — High, rewrite (AD-2), guard `check-prompt-parity.sh:178` opener `INTENDED DESIGN (currently GATED, not active):` and `test-spawn-tiers.sh:276` asserts `reasoning_effort=medium` in this file (only occurrence is inside this block) — both kept. After:
  ```
  <!--
  INTENDED DESIGN (currently GATED, not active): when your slice has an applicable
  test framework, spawn a separate clean-context test-writer subagent with
  `fork_context=false` and request `reasoning_effort=medium` (mechanical test
  authoring against an already-defined contract, not judgment work). The test-writer
  receives ONLY the slice contract — `{{TASK_DESCRIPTION}}` plus the Writer-designated
  Integration Seams rows injected via `{{TECHNICAL_SPECIFICATIONS}}` — and never the
  implementer's diff. That topology needs nested `spawn_agent` support from a
  non-interactive Codex worker, which this harness does not provide. The ACTIVE PATH
  below is single-context authoring: you write and run your own tests, but you author
  them to the same contract a separate test-writer would have used.
  -->
  ```
- **B-10** both `test-writer-prompt.md` status notes — High, rewrite (AD-2), guard `check-prompt-parity.sh:183` sed range from `**Status note (read first):**` to `^Filled by the fan-out worker` (both anchors kept; the latter is also pinned by `test-spawn-tiers.sh:387`), and `test-spawn-tiers.sh:278` asserts `reasoning_effort=medium` in the Codex file (kept). Claude :3-9 After: `**Status note (read first):** on this harness the fan-out worker spawns a separate clean-context test-writer subagent with \`model: sonnet\`; effort is inherited from the worker's \`--effort medium\` session because the Task tool has no per-call effort argument. The test-writer never sees the implementer's diff.` Codex :3-15 After: `**Status note (read first):** on this harness the worker consumes this contract single-context: it authors tests to the contract inside its own Phase 2 (see \`agent-prompt.md\`) rather than spawning a separate subagent, and it follows the anti-cheat rule in \`agent-prompt.md\` Phase 4 as if the two contexts were genuinely separate. The template below is the separate-subagent form, ready to use verbatim where nested \`spawn_agent\` with \`fork_context=false\` and \`reasoning_effort=medium\` is available.` The Codex sentence `Filled by the fan-out worker before spawning the test-writer (once the nested-spawn\ngate is confirmed). …` at :17-19 stays byte-exact (normalizer rewrites it literally).
- **B-20** both `agent-prompt.md:29` — Med, rewrite, guard: byte-parity-checked span → same commit. `IMPORTANT: Only modify files relevant to your task. Do not touch files outside your scope.` → `Modify only files relevant to your task. Other agents are working in parallel worktrees, and every branch merges back into the same base.`

### `review-gauntlet/SKILL.md` (Claude; Codex only for B-01)

- **B-01** Claude :124 + Codex :130 — High, rewrite, guard `tests/gauntlet/test-gauntlet-skill-shape.sh:418-441` (`assert_r2_forbidden_flags_xor_for` requires each mirror to carry exactly one of the literal `Forbidden flags:` or an `UNVERIFIED` marker plus `budget` plus `(sole|only) defen[cs]e`; this sentence is the only source of that marker in either mirror, so a bare delete fails both assertions). Replace the sentence `**Flag combination: UNVERIFIED.** The 2026-08-23 insights report's … the sole defence against a repeat.` with, byte-identical in both mirrors: `**Flag combination: UNVERIFIED.** The gate has hung for 90+ minutes with no recoverable cause (the available record carries narrative only, never the exact CLI argv); the wall-clock budget above is the sole defence against a repeat.` Per AD-5 the wording is cause-neutral. Keeps the dated narrative out and the XOR guard satisfied without touching the test. Codex has no R7/C1/C2 text; this is its only hunk.
- **B-02** :274 remove the paragraph `These bundled scripts and the convergence-decision helper are built in a later phase … once they exist.` — High, guard none (all scripts exist under `lib/` and `scripts/`).
- **B-03** :240 `This is an accepted prose seam (R7), not a script-enforced contract, now extended from just \`duration_s\` to the full envelope shape including \`gate\` identity.` → `This is an accepted prose seam, not a script-enforced contract: the full envelope shape, \`gate\` identity included, is stamped by hand for gates 2/3.` — High, guard none.
- **B-04** :234 `and R7's accepted prose seam below` → `and in the prose seam noted below` — High.
- **B-05** :97 `(and C1's key-file wiring)` → `, and the key-file wiring,` (full: `this is what makes the status-row block below, and the key-file wiring, reference variables that actually exist, rather than only the gate-1 pair`); :241 `(C1/C2 wiring — the orchestrator, never the fixer, computes keys)` → `(the orchestrator, never the fixer, computes keys)` — High.
- **B-19** :175 `specifically the phase's \`**Goal:**\` field (added by the sibling \`conduct\` phase-goal-field work) when the plan has reached that phase` → `specifically the phase's \`**Goal:**\` field when the plan has reached that phase` — Med.

### `release/SKILL.md` (Claude; Codex line = Claude line + 1)

Guard for all: `scripts/check-prompt-parity.sh:271-296` compares the two files after normalization and pins `RELEASE_*` exact lines (:287-296); none of the hunks below touch a pinned line, but every hunk lands in both mirrors (Codex commit, then Claude commit) before parity is asserted.

- **B-12** :89 — Med, rewrite. Before: `An earlier revision ran a forced tag fetch … both served without it:` (two sentences). After: `A forced tag fetch here would silently move **every** local tag that also exists on origin (not just the target \`vX.Y.Z\`) to match origin's position — an unannounced mutation during a read/preflight phase, one that fires immediately and can destroy an operator's intentional local tag divergence even on a run that then aborts for an unrelated reason (an ambiguous \`gh release view\` failure in Step 3.1, say). No fetch is needed, because the only two things one would serve are both served without it:`
- **B-13** :89 later `— the stronger guarantee the earlier no-pruning rule was reaching for, since a fetch that never runs can neither prune a local-only tag nor force-move a diverged one.` → `— a fetch that never runs can neither prune a local-only tag nor force-move a diverged one.` — Med.
- **B-14** :229 `**do not** run a forced tag fetch here: Step 2's pre-confirmation path no longer fetches local tags: a force-fetch silently overwrites` → `**do not** run a forced tag fetch here, and note that Step 2's pre-confirmation path does not fetch local tags either. A force-fetch silently overwrites` — Med.
- **B-15** :10 `This is the single owner of skein's release-note shape — before this skill existed, … (see \`docs/dev_plans/20260712-feature-release-skill.md\`).` → `This is the single owner of skein's release-note shape: hand-typed \`gh release create --notes "..."\` calls drift into inconsistent shapes across releases, so every release goes through here.` — Med.
- **B-16** :221 remove ` — this is the workflow that manually found skein's own three-shapes drift and its missing \`v0.5.1\` release, folded into the skill instead of repeated by hand.` (sentence ends at `one named version.`) — Med.
- **B-17** :262 `If it is absent, this is a genuine \`missing-tag\`: (Skein's own \`v0.5.1\` before this session's first fix.) Fixable` → `If it is absent, this is a genuine \`missing-tag\`. Fixable` — Med.
- **B-18** :300 `This skill's own canonical format was established … chooses to add a summary:` → `An illustrative release in the canonical shape, shown without a \`## What's New\` paragraph. An ordinary re-sync preserves that absence unless the user explicitly chooses to add a summary:` — Med.

### `spec-compliance` (Claude + Codex)

- **C-F1 + C-F16** Codex SKILL :45 — High, rewrite, guard `test-spawn-tiers.sh:268` asserts `R3 why: normative spec compliance is judgment work` → change to `Mapping normative spec requirements onto code is judgment work` in the same commit; `:219` pins exactly one `reasoning_effort=high` (kept). After: `Use \`spawn_agent\` with the harness-selected model and \`reasoning_effort=high\` to run the following self-contained prompt (fill in \`{{PLACEHOLDERS}}\`). Mapping normative spec requirements onto code is judgment work, not a lookup, so it warrants the high tier. If \`spawn_agent\` is unavailable, run the same prompt contract in the main context.`
- **C-F4** Claude :165-171 + Codex :161-167 remove the `### What NOT to Do` section (heading, blank, five bullets) — Med, guard none; positives survive at `### Report Rules`, :31, :77, :107.
- **C-F6** Claude :154 After `Present the compliance report to the user as-is. Before presenting, verify it against [rubric.md](rubric.md), which covers spec resolution, requirement extraction, per-requirement classification, report structure, and scope discipline.`; Codex :150 After `Before presenting the compliance report to the user, verify it against [rubric.md](rubric.md).`; `rubric.md:3` both mirrors `Gradeable criteria for evaluating a completed compliance report. Doubles as a Managed Agents outcome rubric and a local self-check before presenting the report to the user.` → `Criteria for evaluating a completed compliance report. Use it as a self-check before presenting the report to the user.` — Med, guard `check-prompt-parity.sh:61-88` byte-diffs `rubric.md` → same commit.

### Codex delegation idiom (AD-4) — `content-draft:42,46`, `content-review:46,54`, `rfc-finder:29,33`, `update-docs:27,29`, `spec-compliance:37` (Codex mirror only)

- **C-F16** — Med, rewrite, guard `test-spawn-tiers.sh:233,235,237,239` pin one `reasoning_effort=low` per file (`:219` high for spec-compliance) — every After keeps exactly one. Canonical pair (rfc-finder): `:29` → `These steps involve multiple web lookups against Datatracker and RFC Editor. Delegate them to a subagent to keep the main context lean. If \`spawn_agent\` is unavailable in the current runtime, run the same steps in the main context.`; `:33` → `Use \`spawn_agent\` with the harness-selected model and \`reasoning_effort=low\` to run the following self-contained prompt (fill in \`{{PLACEHOLDERS}}\`). If \`spawn_agent\` is unavailable, run the same prompt contract in the main context.` Apply the same shape to the other files, preserving each file's subject, tool name and effort tier. Description-only for the eight non-canonical sites: write each against live text when the phase applies it.

### `rfc-finder`, `grill`, `plan-view`, `update-docs` (Claude + Codex unless noted)

- **C-F5** rfc-finder :103-108 both mirrors remove `### What NOT to Do` (heading, blank, four bullets) — Med, guard none; positives at :36 (subagent prompt: do not reproduce RFC substance), :60, :68, :74 stay.
- **C-F11** grill :11 both mirrors remove `This skill is inspired by mattpocock/skills' \`grilling\` skill, … not a port.` plus following blank — Med.
- **C-F12** grill Claude :44-46 — Med, rewrite: replace the three-line two-harness choice with `2. Present a fixed three-way choice for that recommendation: \`AskUserQuestion\` with exactly three options — **accept**, **propose an alternative**, **waive**.` Codex :44 already carries only its own branch. Guard none; grill has no wholesale parity.
- **C-F13** grill Claude :75 / Codex :73 → `Below-marker workspace edits (\`## Progress\`, \`## Findings\`) are always fine and never trigger this check; only above-marker contract content is guarded.` — Med.
- **C-F2 + C-F7** plan-view Claude :207-213 / Codex :208-214 remove the `## What's deferred to v2` section (heading, blank, five bullets incl. the struck-through `.plan-view.yml` line, trailing blank) — High for the struck line, Med for the section, guard none.
- **C-F3** plan-view Codex :7 comment: drop ` as of 2026-07-12's skill-invocation-mode audit` and ` as of this writing` (After: `<!-- invocation-mode divergence: this skill is user-invoked-only on the Claude mirror (disable-model-invocation: true). Codex CLI has no equivalent front-matter suppression, so it remains autonomously invocable here — a harness limitation, not an oversight. See docs/dev_plans/20260711-chore-skill-invocation-mode-audit.md. -->`) — High, guard: `RELEASE_CODEX_INVOCATION_DIVERGENCE` pins only the *release* file's comment; plan-view is unguarded.
- **C-F8** plan-view Claude :219 / Codex :220 → `- **\`/update-docs\`** — keeps READMEs/CHANGELOGs in sync with code.` — Med.
- **C-F9** plan-view :66/:67 drop ` (e.g. the rich cross-links added here)`; :140/:141 `and it back-fills rich pages generated before back-links existed.` → `and it adds the breadcrumb to any rich page on disk that lacks one.` — Med.
- **C-F14** plan-view `parser.md:117` both mirrors drop `v1 used a koda-specific \`COMPONENT_PATTERNS\` slug matcher; it was removed before shipping. ` from the parenthetical — Med, guard none (`parser.md` not parity-checked; apply identically anyway).
- **C-F17** plan-view :201/:202 `~51 plans render in well under a second.` → `a whole corpus renders in well under a second.` (joined with `; `); :49/:50 `# inline-only; this dir is empty in v1` → `# inline-only; this dir is currently unused` (keep column alignment) — Med.
- **C-F10** update-docs :150-185 both mirrors remove the `#### Sibling-plan audit — worked example` block through the closing fence of the commit-preamble example — Med, guard: `check-trunk-snippet-parity.sh` extracts :259-263 by content anchor, unaffected.

### Project `.claude/CLAUDE.md` (skein-owned)

Guard for all: `tests/plugin/test-claude-md-hygiene.sh:53-57` asserts the H2 headings `## Testing`, `## Facts vs Inference`, `## Security & Diff Reviews`; no hunk touches a heading.

- **D-F05** :29 `- Run \`/update-docs\`, \`/review\`, \`/security-review\`, and \`/deep-review\` before merging.` → two lines: `- When the skein plugin is available, run \`skein:review-gauntlet\` (or set a dev-plan's **Review Gates:** field) rather than hand-running the gates. Otherwise hand-run \`/code-review\`, \`/security-review\`, and \`/deep-review\` before merging.` / `- Once reviews have converged, run \`/update-docs\` — review-gauntlet does not do this itself, it only chains the review gates.` — High (`/review` resolves nowhere; AD-6).
- **D-F01** :18 — High, rewrite: drop `Reason: two consecutive fixes in one session (2026-07-12, … after the fact.`; insert after `those other call sites depend on` the parenthetical ` (pay special attention to encode/decode, escape/unescape, serialize/deserialize pairs — the reverse side is often built the same naive way and breaks in reverse)`; append `A fix that satisfies the reported line can silently break a second call site on the same mechanism, and the second break surfaces only in a later review round.`
- **D-X** (old #38, AD-6) insert as the first `## Review Workflow` bullet: `- **When a review returns findings, don't patch reactively in the same pass.** Think through each reported issue first — root cause, not just the symptom. Where the fix is more than mechanical, delegate it as a sequence of clean-context subagents — architect, implement, test, verify against the original finding — rather than writing the diff inline. Reason: fixes written inline immediately after reading a finding tend to be shallow patches on the reported symptom; splitting architect/fix/test/verify across subagents forces the root-cause step instead of skipping straight to a diff.` — decision, user may decline.
- **D-F02** :118 remove ` Reason: 2026-08-23 insights report, full suite > 2-minute foreground timeout, had to be re-run in background.` — High.
- **D-F03** :121 remove ` Reason: 2026-08-23 insights report, a PyPI manual-approval gate was wrongly concluded gone from run duration alone; two files had to be corrected.` — High.
- **D-F04** :131 remove ` Stale memories caused real friction (e.g., trusting a 32-day-old roadmap; assuming v0.0.18 was tagged when it wasn't).` — High (line becomes identical to global :154).
- **D-F08** :124 ` Reason: 2026-08-23 insights report, 3 security-review sessions were interrupted mid-exploration before any finding was delivered.` → ` A review held to the end delivers nothing at all if the session is interrupted mid-exploration.` — Med (the reason is kept; only the date and tally go).
- **D-F09** :6 `do not hand-run the old \`git tag\` + \`gh release create\` procedure.` → `do not hand-run \`git tag\` + \`gh release create\`.` — Med.
- **D-F16** :94-101 replace the `**3. Decision rule — inline vs delegate:**` table with the paragraph `**3. Decision rule — inline vs delegate.** Run it inline when the narrowed output is small and I will act on the detail myself. Delegate when the raw output would be large or spread across files and I only need the conclusion. Two carve-outs are not obvious from that rule: verbose-but-single-purpose output (build, test, deploy logs) stays inline behind a filter pipe unless all I want is a verdict, and anything I will re-reference later in the session stays inline, because delegating discards the detail.` — Med, most declinable hunk; take last. The global half is in Follow-ups; until it lands the two files' wording differs while the rule does not.

Flag-only findings (not in the apply set) live in the Claude plan. If the user accepts one that touches `plugins/skein-codex/`, it comes back here as an extra phase per AD-8.

## Implementation Checklist

Runtime: Codex-driven `/conduct` only. Companion plan: `docs/dev_plans/20260903-prompt-audit-claude.md` runs after every phase here is ticked. Every phase below touches `plugins/skein-codex/` files (plus the two `tests/parity/test-spawn-tiers.sh` assertions that pin Codex-mirror text) and nothing the Claude plan touches. Branch creation is not a phase — `chore/prompt-audit-cleanup` already exists.

**Lag window.** Between a Codex phase and its Claude twin the mirrors diverge on purpose, so `just check-prompt-parity` is red: the rubric byte-diff (`check-prompt-parity.sh:61-88`) and the fan-out prompt normalizer span comparison (`:173-184`) both fail while only one half has landed. Codex phases therefore run `bash tests/parity/test-spawn-tiers.sh`, which pins the spawn-tier strings and does not compare mirrors. Each mirror pair is two boundary commits, Codex then Claude; parity is green after the Claude commit.
### Phase 0: Baseline counts
**Impl files:** docs/dev_plans/20260903-prompt-audit-codex.md
**Test files:** none
**Test command:** `just check-prompt-parity && just check-sync && just parity-tests && just gauntlet-tests && just lens-tests && just plugin-tests`
**Goal:** Record in `## Findings` the ID-sweep baseline (`rg -n '\b[RC][0-9]\b' plugins/skein plugins/skein-codex --glob '*.md' | wc -l`, expected 29) and that all six recipes are green before any hunk lands.

### Phase C1: Codex conduct
**Impl files:** plugins/skein-codex/skills/conduct/SKILL.md
**Test files:** tests/parity/test-spawn-tiers.sh
**Test command:** `bash tests/parity/test-spawn-tiers.sh`
**Goal:** Runtime: codex. Re-verify each Before against live text first; adapt if drifted. Hunks: L2 (with the `:270` assertion rewritten in this phase), A-F8a Codex sites, A-F10a Codex, A-F13 Codex. Keep anchors per AD-1/AD-2.

### Phase C2: Codex deep-review
**Impl files:** plugins/skein-codex/skills/deep-review/SKILL.md
**Test command:** `bash tests/parity/test-spawn-tiers.sh`
**Goal:** Runtime: codex. Re-verify each Before against live text first; adapt if drifted. Hunks: A-F3, A-F4, A-F8b. Keep anchors per AD-1/AD-2.

### Phase C3: Codex dev-plan
**Impl files:** plugins/skein-codex/skills/dev-plan/SKILL.md
**Test command:** `bash tests/parity/test-spawn-tiers.sh`
**Goal:** Runtime: codex. Re-verify each Before against live text first; adapt if drifted. Hunks: A-F6, A-F10b. Keep anchors per AD-1/AD-2.

### Phase C4: Codex review-plan
**Impl files:** plugins/skein-codex/skills/review-plan/SKILL.md, plugins/skein-codex/skills/review-plan/rubric.md
**Test command:** `bash tests/parity/test-spawn-tiers.sh`
**Goal:** Runtime: codex. Re-verify each Before against live text first; adapt if drifted. Hunks: L7, A-F4, A-F8c, A-F12b, A-F7 (`rubric.md` Codex half). Keep anchors per AD-1/AD-2; `rubric.md` byte parity stays red until L4.

### Phase C5: Codex fan-out
**Impl files:** plugins/skein-codex/skills/fan-out/SKILL.md, plugins/skein-codex/skills/fan-out/agent-prompt.md, plugins/skein-codex/skills/fan-out/test-writer-prompt.md
**Test command:** `bash tests/parity/test-spawn-tiers.sh`
**Goal:** Runtime: codex. Re-verify each Before against live text first; adapt if drifted. Hunks: B-06 Codex, B-11, L8 Codex, B-09, B-10 Codex, B-20 Codex. Keep anchors per AD-1/AD-2 — the `INTENDED DESIGN (currently GATED, not active):` opener, `**Status note (read first):**`, `Filled by the fan-out worker`, and one `reasoning_effort=medium` per Codex prompt file all stay byte-exact.

### Phase C6: Codex review-gauntlet
**Impl files:** plugins/skein-codex/skills/review-gauntlet/SKILL.md
**Test command:** `bash tests/parity/test-spawn-tiers.sh && just gauntlet-tests`
**Goal:** Runtime: codex. Re-verify the Before against live text first; adapt if drifted. Hunks: B-01 Codex half only. Keep anchors per AD-1/AD-2 — the XOR guard requires this mirror to keep exactly one of the two `Forbidden flags` literals.

### Phase C7: Codex release
**Impl files:** plugins/skein-codex/skills/release/SKILL.md
**Test command:** `bash tests/parity/test-spawn-tiers.sh`
**Goal:** Runtime: codex. Re-verify each Before against live text first; adapt if drifted (Codex line = Claude line + 1). Hunks: B-12, B-13, B-14, B-15, B-16, B-17, B-18. Keep anchors per AD-1/AD-2 — every `RELEASE_*` pinned line stays untouched.

### Phase C8: Codex spec-compliance
**Impl files:** plugins/skein-codex/skills/spec-compliance/SKILL.md, plugins/skein-codex/skills/spec-compliance/rubric.md
**Test files:** tests/parity/test-spawn-tiers.sh
**Test command:** `bash tests/parity/test-spawn-tiers.sh`
**Goal:** Runtime: codex. Re-verify each Before against live text first; adapt if drifted. Hunks: C-F1 + the C-F16 site at SKILL `:45` (with the `:268` assertion rewritten in this phase), C-F4 Codex, C-F6 Codex and `rubric.md` Codex half. Keep anchors per AD-1/AD-2.

### Phase C9: Codex delegation idiom
**Impl files:** plugins/skein-codex/skills/content-draft/SKILL.md, plugins/skein-codex/skills/content-review/SKILL.md, plugins/skein-codex/skills/rfc-finder/SKILL.md, plugins/skein-codex/skills/update-docs/SKILL.md, plugins/skein-codex/skills/spec-compliance/SKILL.md
**Test command:** `bash tests/parity/test-spawn-tiers.sh`
**Goal:** Runtime: codex. Re-verify each Before against live text first; adapt if drifted. Hunks: C-F16 at all ten sites in one phase per AD-4 — all or none. Keep anchors per AD-1/AD-2 — the per-file `reasoning_effort=*` count is unchanged. No Claude twin.

### Phase C10: Codex misc skills
**Impl files:** plugins/skein-codex/skills/rfc-finder/SKILL.md, plugins/skein-codex/skills/grill/SKILL.md, plugins/skein-codex/skills/plan-view/SKILL.md, plugins/skein-codex/skills/plan-view/parser.md, plugins/skein-codex/skills/update-docs/SKILL.md
**Test command:** `bash tests/parity/test-spawn-tiers.sh`
**Goal:** Runtime: codex. Re-verify each Before against live text first; adapt if drifted. Hunks: C-F5, C-F11, C-F13 Codex, C-F2 + C-F7, C-F3, C-F8, C-F9, C-F14, C-F17, C-F10. Keep anchors per AD-1/AD-2 — the update-docs trunk-snippet extraction anchors stay.

## Technical Specifications

### Files to Modify

- `plugins/skein-codex/skills/{conduct,deep-review,dev-plan,review-plan,fan-out,release,review-gauntlet,spec-compliance,content-draft,content-review,rfc-finder,update-docs,grill,plan-view}/SKILL.md` — the Codex halves of the hunks above.
- `plugins/skein-codex/skills/fan-out/agent-prompt.md`, `…/fan-out/test-writer-prompt.md` — B-09, B-10, B-20.
- `plugins/skein-codex/skills/review-plan/rubric.md` — A-F7. `plugins/skein-codex/skills/spec-compliance/rubric.md` — C-F6. `plugins/skein-codex/skills/plan-view/parser.md` — C-F14.
- `tests/parity/test-spawn-tiers.sh` — the `:268` and `:270` pinned strings (C-F1, L2), rewritten in the same phase as the prose they pin.
- Not modified here: everything under `plugins/skein/`, `.claude/CLAUDE.md`, `AGENTS.md`, `~/.claude/CLAUDE.md`, `scripts/check-sync.sh`, `scripts/check-prompt-parity.sh`, `scripts/check-trunk-snippet-parity.sh`, `tests/plugin/test-claude-md-hygiene.sh`.

### New Files to Create

- none

### Architecture Decisions

- **AD-1 Machine anchors are kept verbatim by default.** Where a finding's clean fix would change a string a script or test greps for, the guard edit (script/test file and line) is part of the same hunk and commit, and that file is in Files to Modify. No guard edit is left implied. Old invariant = new invariant for every anchor not listed as edited.
- **AD-2 R6 apparatus: rewrite prose, keep anchors.** The audit calls the whole apparatus a fossil. This pass removes the dates (`2026-07-04`), the retired model name (`claude-haiku-4-5`), and the CONFIRMED/GATED narratives, but keeps byte-exact: the openers `R6 status:` and `INTENDED DESIGN (currently GATED, not active):` (normalizer alternation at `check-prompt-parity.sh:178`), `**Status note (read first):**` and `Filled by the fan-out worker` (sed range :183 and `test-spawn-tiers.sh:387`), `reasoning_effort=medium` in the two Codex prompt files (`:276`, `:278`), the Codex `Filled by the fan-out worker before spawning the test-writer (once the nested-spawn\ngate is confirmed).` sentence (literal substitution at :178), and `### Phase 5` / the two `If … test framework` anchors (:381-386). Two-sided invariant: old = the Claude block is excised because its first line matches `R6 status:` and the Codex block because it matches `INTENDED DESIGN (…)`; new = the same, because both openers are unchanged. Full removal is Phase 6, off by default.
- **AD-3 Uniform fix shape for ID leaks.** State the rule content in prose in the same sentence and drop the bare ID. `AGENTS.md` Model/Effort Policy is a live section and stays as the pointer; `R1`/`R3` do not appear in that section, so the suffix is an undefined ID and goes. Never add an HTML why-comment to a Codex SKILL.md (the Codex idiom is inline prose); where `test-spawn-tiers.sh` pins an `R3 why:` string, its assertion moves to the new prose in the same commit. This overrides audit-A's "keep R1/R3" non-finding.
- **AD-4 The Codex "if delegation is available and explicitly allowed" idiom is a hedge, not a permission gate.** No config key, env var or probe defines "explicitly allowed" (grep-verified). All ten occurrences across five files are rewritten in one commit, or none; effort-annotation counts per file are preserved.
- **AD-5 Cause-neutral wording where the cause is unknown.** The review-gauntlet hang paragraph is removed rather than restated with a cause; if any restatement is wanted it says the gate has hung with no recoverable cause and the wall-clock budget is the sole defence. No flag combination is asserted anywhere.
- **AD-6 Project CLAUDE.md aligns to the global file's workflow wording.** Line 29 is replaced by the global's review-gauntlet + `/update-docs`-after-convergence bullets (D-F05), and the global's first Review Workflow bullet is added to the project file in its de-hedged form (D-X). The project file remains the source of truth for skein-specific rules (the `skein:release` bullet stays). The user may override D-X.
- **AD-7 `/update-docs` runs after the review gates converge**, matching the rule D-F05 installs.
- **AD-8 Harness ownership split.** `AGENTS.md` and the Codex mirror are Codex/ChatGPT's surface; Claude must not change material behaviour of the other harness. Per mirror pair: (1) Claude hands Codex the Codex-side hunk list (before/after text, guard hits, the AD-1 anchor rule) via `codex:rescue` with a review-and-implement mandate — Codex may modify or decline a hunk, and its decision is recorded in `## Findings`; (2) a second fresh-thread `codex:rescue` call self-reviews what Codex landed; (3) Claude applies the Claude-mirror twin aligned to the text Codex actually landed (not to the plan's proposed text if they differ); (4) each half is its own boundary commit — the Codex commit from its `/conduct` phase, then the Claude commit from the twin phase — and the mirror-comparing gates pass only after the Claude commit. Guards that pin Codex strings (`tests/parity/test-spawn-tiers.sh:268`, `:270`, `:276`, `:278`) are updated by Codex in step (1), in the same working-tree change. Findings with no Claude twin (L7, C-F16 Codex-only sites, B-01 Codex half wording) are Codex-only tasks. The deferred R6 apparatus removal touches Codex prompt files and the normalizer that reads them, so it is Codex-led end to end if ever taken.

### Dependencies

- `just`, `rg`, `perl` (used by the normalizer), `bash` ≥ 4 for the parity tests. No new dependencies.

### Integration Seams

| Seam | Writer (task) | Caller (task) | Contract |
|------|---------------|---------------|----------|
| fan-out prompt normalizer | fan-out hunks (B-08, B-09, B-10, L9, B-20) | `scripts/check-prompt-parity.sh:173-184` via `just check-prompt-parity` | Openers, sed anchors and the Codex `Filled by …` sentence byte-exact; non-excised spans identical across mirrors |
| spawn-tier census | L1, L2, A-F11, C-F1, C-F16, B-09, B-10, B-11 | `tests/parity/test-spawn-tiers.sh` via `just parity-tests` | `opus/high:` total 6; `fable/high:` total 5; one `reasoning_effort=*` per Codex file; `:268`/`:270` strings updated with the prose |
| rubric / prompt byte parity | A-F7, C-F6, B-06 (test-writer-prompt :1), B-20, A-F15 if taken | `check-prompt-parity.sh:61-120` | identical bytes in both mirrors, same commit |
| release normalized parity | B-12–B-18 | `check-prompt-parity.sh:271-296` | `RELEASE_*` pinned lines untouched; both mirrors edited together |
| CLAUDE.md hygiene | D-* hunks | `tests/plugin/test-claude-md-hygiene.sh:53-57` | H2 headings `## Testing`, `## Facts vs Inference`, `## Security & Diff Reviews` present |
| trunk-snippet parity | A-F* deep-review, C-F10 update-docs | `scripts/check-trunk-snippet-parity.sh` | `BASE=$(git symbolic-ref …` five-line block unchanged |
| sync check | every mirror pair | `scripts/check-sync.sh` via `just check-sync` | mirror trees agree on the files it compares |

## Architecture & Call Flow

Guard map — for every file touched, which script/test reads it and which literal it depends on.

| File | Guard | Literal / rule depended on | Status after this plan |
|---|---|---|---|
| `fan-out/agent-prompt.md` (both) | `check-prompt-parity.sh:178,181-183`; `test-spawn-tiers.sh:276,366,376,381-386` | `R6 status:` / `INTENDED DESIGN (currently GATED, not active):` openers; `^If your task has an applicable test framework`, `^If no relevant test framework exists`, `^### Phase 5`; `reasoning_effort=medium` (Codex); `model: sonnet, effort: medium` (Claude); `contract wins` | all kept |
| `fan-out/test-writer-prompt.md` (both) | `check-prompt-parity.sh:178,183`; `test-spawn-tiers.sh:278,387` | `**Status note (read first):**`, `^Filled by the fan-out worker`, Codex `(once the nested-spawn\ngate is confirmed).` sentence, `reasoning_effort=medium` (Codex); line 1 byte-parity | all kept |
| `fan-out/SKILL.md` (Codex) | `test-spawn-tiers.sh:274,280` | `reasoning_effort=medium.*fork_context=false` (line 19), `Codex does not pin model names` | kept (line 19 untouched) |
| `conduct/SKILL.md` (Claude) | `test-spawn-tiers.sh:295` | `opus/high:` count contributes 1 | kept |
| `conduct/SKILL.md` (Codex) | `test-spawn-tiers.sh:270` | `R3 why: code review is judgment work` | **assertion rewritten** (L2) |
| `deep-review/SKILL.md` (Claude) | `test-spawn-tiers.sh:295,323`; `check-trunk-snippet-parity.sh` | `opus/high:` ×4, `effort: high` ×4, trunk snippet | kept |
| `spec-compliance/SKILL.md` (Codex) | `test-spawn-tiers.sh:219,268` | one `reasoning_effort=high`; `R3 why: normative spec compliance is judgment work` | count kept; **assertion rewritten** (C-F1) |
| `{content-draft,content-review,rfc-finder,update-docs}/SKILL.md` (Codex) | `test-spawn-tiers.sh:233-239` | one `reasoning_effort=low` each | kept |
| `review-plan/rubric.md`, `spec-compliance/rubric.md` | `check-prompt-parity.sh:61-88` | byte-identical across mirrors | kept (same commit) |
| `release/SKILL.md` (both) | `check-prompt-parity.sh:271-296`; `test-prompt-parity-extended.sh:158` | `RELEASE_*` exact lines incl. the Codex invocation-divergence comment | kept (B-24 not applied) |
| `update-docs/SKILL.md` (both) | `check-trunk-snippet-parity.sh` | `BASE=$(git symbolic-ref …` block | kept |
| `.claude/CLAUDE.md` | `test-claude-md-hygiene.sh:53-57` | three H2 headings | kept |
| `review-gauntlet/SKILL.md` (both) | `tests/gauntlet/test-gauntlet-skill-shape.sh:418-441` via `just gauntlet-tests` | XOR: `Forbidden flags:` or UNVERIFIED+budget+sole-defence marker (B-01 keeps the marker) | kept |
| `dev-plan`, `grill`, `plan-view`, `parser.md` | none found | — | — |

```mermaid
graph LR
    E["prompt hunk (SKILL.md / *-prompt.md / rubric.md)"] -->|"same commit"| G["guard edit (test-spawn-tiers.sh :268 :270)"]
    E --> P["just check-prompt-parity"]
    E --> S["just check-sync"]
    G --> T["just parity-tests"]
    E --> T
    C[".claude/CLAUDE.md hunk"] --> H["tests/plugin/test-claude-md-hygiene.sh"]
    T --> R["skein:review-gauntlet"]
    P --> R
    H --> R
    R --> U["/update-docs"]
```

```mermaid
sequenceDiagram
    participant I as Implementer
    participant M as Mirror pair
    participant J as just recipes
    participant RG as review-gauntlet
    I->>M: apply hunk (+ guard edit if listed)
    I->>J: check-prompt-parity, check-sync, parity-tests
    J-->>I: green / drift report
    I->>I: commit with "kept:" line
    I->>RG: Phase F gates
    RG-->>I: converged
    I->>I: /update-docs
```

| Step | Trigger | Enters context | Cleared/persisted | Turn boundary |
|------|---------|----------------|-------------------|---------------|
| 1 | per-phase re-verify | live file text at cited lines | notes persist under `## Findings` | per file |
| 2 | C/L phase hunk | before/after text, guard line | commit | per mirror pair |
| 3 | Phase F gates | recipe output, sweep residue | `## Findings` baseline vs final | end of plan |

## Testing Notes

### Test Approach

- [ ] `bash tests/parity/test-spawn-tiers.sh` — after every phase here. This is the only gate the Codex phases run: it pins the spawn-tier strings and does not compare mirrors, so it stays green through the lag window.
- [ ] `just gauntlet-tests` — additionally in phase C6 (runs `tests/gauntlet/test-gauntlet-skill-shape.sh`, the only path to the B-01 XOR guard).
- [ ] Phase 0 only: `just check-prompt-parity && just check-sync && just parity-tests && just gauntlet-tests && just lens-tests && just plugin-tests`, all green, plus the ID-sweep baseline of 29.
- [ ] Expected red during the lag window, not a failure: `just check-prompt-parity` and anything that wraps it, because only the Codex half of each pair has landed. The ID sweep, the phase-tag check and the dry runs are the Claude plan's phase F.

### Test Results

- [ ] Phase 0 baseline green, residue 29 recorded.
- [ ] `test-spawn-tiers.sh` green after each of C1…C10.

### Edge Cases Tested

- [ ] Rewriting a pinned string without rewriting its assertion in the same phase fails `test-spawn-tiers.sh` (`:268`, `:270`) — the failure is the guard working.
- [ ] Dropping a normalizer opener or an excision anchor fails `test-spawn-tiers.sh:381-388`.

## Acceptance Criteria

- Every Codex-side hunk in the apply set is applied in `plugins/skein-codex/`, one boundary commit per phase.
- `tests/parity/test-spawn-tiers.sh:268` and `:270` assert the new prose and pass; no other pinned string or count changed.
- `bash tests/parity/test-spawn-tiers.sh` exits 0 after every phase; `just gauntlet-tests` exits 0 after C6.
- Every anchor listed in AD-1 and AD-2 is byte-unchanged, or its guard was edited in the same phase.
- Each commit body carries one "kept:" line per hunk naming where the operative clause survives.
- Nothing under `plugins/skein/`, `.claude/CLAUDE.md`, `AGENTS.md` or `~/.claude/CLAUDE.md` is in the diff.
- All phases are ticked in `## Progress`, so the Claude plan may start.

## Review Gates

`none` — the gauntlet runs once, from the companion Claude plan, after its phase F.

<!-- reviewed: 2026-09-03 @ d153d36f54b83c6a9608c998c4e1de75eb0a78cd -->

<!-- /review-plan writes the marker line above. Everything below is the workspace: edits here do NOT invalidate the marker. -->

## Progress

- [x] Phase 0: Baseline counts
- [x] Phase C1: Codex conduct
- [x] Phase C2: Codex deep-review
- [x] Phase C3: Codex dev-plan
- [x] Phase C4: Codex review-plan
- [x] Phase C5: Codex fan-out
- [x] Phase C6: Codex review-gauntlet
- [x] Phase C7: Codex release
- [x] Phase C8: Codex spec-compliance
- [x] Phase C9: Codex delegation idiom
- [x] Phase C10: Codex misc skills

## Findings

- **Phase 0 baseline (2026-09-03):** `rg -n '\b[RC][0-9]\b' plugins/skein plugins/skein-codex --glob '*.md' | wc -l` returned **29** before any prompt-audit hunk landed.
- **Phase 0 validation (2026-09-03):** All six required recipes passed: `just check-prompt-parity`, `just check-sync`, `just parity-tests`, `just gauntlet-tests`, `just lens-tests`, and `just plugin-tests`. The command used `PYTEST_ADDOPTS='-p no:cacheprovider'` because pytest's ignored `.pytest_cache/` directory is otherwise counted by the manifest guard as a fifteenth skill entry.

## Issues & Solutions

### Issue 1: [Brief description]
- **Problem**:
- **Solution**:
- **Files affected**:

## Final Results

### Summary

### Outcomes

### Learnings

### Follow-up Work
