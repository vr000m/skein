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

### 2026-08-24 — no new exemptions from `review-skills-resilience` (Phases 1-4)

Source: `docs/dev_plans/20260823-feature-review-skills-resilience.md`, Phase 5 backlog review (R10, narrowed). Checked every canonical script and both mirrors' `SKILL.md` for `review-gauntlet`, `deep-review`, and `review-plan` (`git diff --stat d06f82e..HEAD -- plugins/skein-codex/ plugins/skein/`): every canonical script added in Phases 1-4 (`lens-budget.sh`, `finding-key.sh`, `persist-lens-result.sh`, `collect-lens-results.sh`, `scripts/lib/persist-common.sh`) and every `lib/` file (`gate-bounded.sh`, `run-gate.sh`, `convergence-ledger.sh`) landed identically bundled into both `plugins/skein/skills/*` and `plugins/skein-codex/skills/*`; both `SKILL.md` files were edited in the same commit per phase (Codex prose adapted to `"$SKILL_DIR"` idiom and Codex sequential-mode wording, never transliterated). No behaviour introduced by this plan is harness-inexpressible on Codex — the one Codex-specific difference (sequential lens execution skips the one-respawn step, since there is no concurrent spawn to respawn) is a design decision recorded in the plan's Findings, not a capability gap, and needs no shape-test exemption. **No new backlog entries required; no shape-test assertion exempted.**

### 2026-07-12 — `plan-view` invocation-mode divergence (permanent, harness-imposed — not deferred drift)

Source: PR #16 (`chore/skill-invocation-mode-audit`), plus a same-day follow-up commit on `chore/skill-invocation-audit-followups`. Plan: `docs/dev_plans/20260711-chore-skill-invocation-mode-audit.md`.

- **Claude file changed:** `plugins/skein/skills/plan-view/SKILL.md` — added `disable-model-invocation: true` to front-matter. `description:` left untouched.
- **Codex file changed:** `plugins/skein-codex/skills/plan-view/SKILL.md` — no field added (Codex CLI 0.144.1 has no discoverable front-matter equivalent that suppresses autonomous natural-language invocation, per the plan's Phase 0 research pass). Instead carries a one-line HTML comment, placed after front-matter close and before the first heading, documenting the divergence and pointing back to the plan.
- **Required result: permanent Codex-native adaptation, not byte-identical parity, and not resolvable by a future Codex-side change** — this is a harness capability gap (Codex plausibly has the same autonomous-firing context-load problem as Claude, but no documented opt-out exists today), unlike the other entries in this file which track *deferred* work expected to eventually reconcile. `plan-view` stays autonomously invocable on Codex indefinitely; only the Claude mirror can suppress it.
- Gating check cleared: `rg -n 'disable-model-invocation' plugins/skein/skills/plan-view/SKILL.md plugins/skein-codex/skills/plan-view/SKILL.md` shows the flag on the Claude side only, and the divergence comment on the Codex side. `just check-prompt-parity` passes (front-matter is out of that script's scope by design; verified directly via the `rg` command instead).
- No other skill of the 13 audited was classified user-invoked, so this is a single-skill, single-entry divergence — see the plan's Phase 1 classification table for why the other 12 stayed model-invoked.

### 2026-07-04 — R6 Claude gate CONFIRMED, topology flipped live (Claude only; Codex still gated)

Supersedes the "Claude-track fallback" entry below for the Claude side. The R6
nested-spawn gate was re-run in the user's own shell (the harness auto-mode classifier
blocks a `--dangerously-skip-permissions` subprocess from inside the agent session).

- **Result: CONFIRMED.** A `claude -p --dangerously-skip-permissions` worker
  (CLAUDECODE unset) spawned a nested Task subagent that honored a **per-call model** —
  the child ran on `claude-haiku-4-5` (proven by `result.modelUsage` billing haiku
  tokens, not a mere request echo). Effort has **no per-call Task argument**, so a
  nested subagent inherits the worker session's effort; `fan-out.sh` runs the worker at
  `--effort medium`, so the test-writer lands sonnet/medium (model per-call, effort
  inherited). Repeatable via `plugins/skein/skills/fan-out/tests/check-r6-gate.sh`.
- **Claude side flipped live:** `agent-prompt.md` Phase 2 now spawns the separate
  clean-context test-writer as the active path; `fan-out/SKILL.md` marks it live.
- **Codex side unchanged — still GATED.** The Codex `codex exec` nested-`spawn_agent`
  gate is still unconfirmed (`Operation not permitted`), so the Codex worker keeps the
  single-context fallback. **Claude-live / Codex-gated is a sanctioned per-harness
  status divergence, not drift.** `check-prompt-parity.sh` excises the now-divergent
  Phase-2 test directive span (with census anchor floors in `test-spawn-tiers.sh`);
  the anti-cheat rule + tier remain census-guarded. When the Codex gate is later
  confirmed, mirror the flip and remove this asymmetry note.

### 2026-07-04 — `feature/explicit-model-effort-policy` (in progress, not drift)

Tracking the model/effort annotation rollout from `docs/dev_plans/20260704-chore-model-effort-explicit-spawns.md`. Logged here proactively, before the Codex-track phase lands, so the upcoming per-mirror annotation-idiom split reads as sanctioned rather than an unplanned parity gap.

- Source: branch `feature/explicit-model-effort-policy` (Phase 1 of the plan; Claude-track Phases 2–4 and Codex-track Phase 5 follow).
- Claude files changed (Phase 1): `AGENTS.md` (new Model/Effort Policy subsection), `README.md` (pointer to the policy), this file.
- Codex files needing analogous updates: none yet at Phase 1 (docs only). Phases 2–4 add `model:`/`effort:` annotations across `plugins/skein/skills/*/SKILL.md`; Phase 5 (authored via `codex:rescue`, after Phases 2–4 land) adds the semantically-equivalent `reasoning_effort=high|medium|low` prose hints across `plugins/skein-codex/skills/*/SKILL.md`.
- Required result: **Codex-native adaptation, not byte-identical parity.** Per R4 of the plan, the Claude `model:`+`effort:` idiom and the Codex "inherit harness model, request `reasoning_effort=X`" prose idiom are a sanctioned divergence (same tier intent per spawn, different knobs) — not drift to reconcile away.
- Gating checks the Codex maintainer must clear once Phase 5 lands: `just check-prompt-parity`, `just parity-tests`, and the new cross-skill tier census `tests/parity/test-spawn-tiers.sh` (added in Phase 3) extended with Codex `reasoning_effort` expectations.

### 2026-07-04 — R6 nested-spawn gate unconfirmed (Claude-track fallback, not drift)

Phase 4 of `docs/dev_plans/20260704-chore-model-effort-explicit-spawns.md` ran the
required live gate for R6 (whether a `claude -p --dangerously-skip-permissions`
worker subprocess can spawn a nested `Agent` test-writer subagent honoring its own
`model:`/`effort:` tier) and could **not confirm** it in this environment: the
skip-permissions subprocess was blocked by harness permission policy before a
nested spawn could even be attempted. This is a harness-behavior gate, not a code
defect — see the plan's Claude-Specific Section ("Assumption to verify… Claude-track
fallback if the gate fails").

- Fallback taken, per the plan's documented Claude-track fallback: (a) the fan-out
  worker keeps its existing single-context Test phase (`agent-prompt.md` Phase 2) —
  it authors and runs its own tests, but now explicitly to the same slice contract a
  separate test-writer would have used; (b) this entry logs the limitation; (c) the
  R6 seeded-divergence acceptance criterion is satisfied via a **direct-mode**
  runner rather than an end-to-end nested-spawn run.
- What still landed regardless of the gate: the R6 contract definition (the
  `{{TECHNICAL_SPECIFICATIONS}}` injection at `fan-out/SKILL.md:106-109` now embeds
  Integration Seams rows with a per-row Writer designation); the anti-cheat rule in
  `agent-prompt.md` Phase 4 (contract wins on impl-vs-test divergence — worker may
  not weaken assertions); `fan-out/test-writer-prompt.md` as a contract artifact
  documenting the intended separate-subagent design; and a deterministic seeded-
  divergence fixture + `plugins/skein/skills/fan-out/tests/run-seeded-divergence.sh`
  that drives the R6 contract-divergence mechanism directly against two fixture
  implementations (proving a contract test fails on a divergent impl and passes on
  a conformant one), exit 0 confirmed locally.
- What is deferred: the separate-subagent test-writer topology itself (documented
  as gated in `fan-out/SKILL.md` "R6: clean-context test-writer graft" section and
  `agent-prompt.md` Phase 2's inline comment) — reactivate it once a `claude -p`
  nested-`Agent` spawn honoring its tier is confirmed in this environment.
- Required result: **logged limitation, not mirrored end-to-end topology**, per the
  plan's fallback clause. No Codex-side action is owed by this entry; Phase 5
  (Codex track) inherits the same gate question independently for `codex -p`
  worker delegation and logs its own divergence if needed.
- Gating checks cleared: `bash plugins/skein/skills/fan-out/tests/run-seeded-divergence.sh` (exit 0, direct mode) and `bash tests/parity/test-spawn-tiers.sh` (14 passed, 0 failed, including the new test-writer tier assertion).

### 2026-07-04 — R6 nested-spawn gate unconfirmed (Codex-track divergence, not drift)

Phase 5 of `docs/dev_plans/20260704-chore-model-effort-explicit-spawns.md`
attempted the symmetric Codex gate without unsafe bypass flags: whether a
non-interactive `codex exec` worker can spawn a nested `spawn_agent` test-writer
subagent with `fork_context=false` and a `reasoning_effort=medium` request. The
gate could **not confirm** this topology in this environment. The checked CLI does
not advertise a first-class `--effort` flag, and the safe non-interactive probe
failed before nested tools could be exercised:
`failed to initialize in-process app-server client: Operation not permitted`.

- Fallback taken, per the plan's symmetric Codex fallback: (a) the fan-out worker
  keeps its existing single-context Test phase (`agent-prompt.md` Phase 2) — it
  authors and runs its own tests, but now explicitly to the same slice contract a
  separate test-writer would have used; (b) this entry logs the limitation; (c) the
  R6 seeded-divergence acceptance criterion is satisfied via a **direct-mode**
  runner rather than an end-to-end nested-spawn run.
- What still landed regardless of the gate: the R6 contract definition (the
  `{{TECHNICAL_SPECIFICATIONS}}` injection at `fan-out/SKILL.md:106-109` now embeds
  Integration Seams rows with a per-row Writer designation); the anti-cheat rule in
  `agent-prompt.md` Phase 4 (contract wins on impl-vs-test divergence — worker may
  not weaken assertions); `fan-out/test-writer-prompt.md` as a Codex contract
  artifact documenting the intended `spawn_agent`/`fork_context=false` design; and
  a deterministic seeded-divergence fixture +
  `plugins/skein-codex/skills/fan-out/tests/run-seeded-divergence.sh` that drives
  the R6 contract-divergence mechanism directly against two fixture implementations
  (proving a contract test fails on a divergent impl and passes on a conformant one).
- What is deferred: the separate-subagent Codex test-writer topology itself
  (documented as gated in `fan-out/SKILL.md` "R6: clean-context test-writer graft"
  section and `agent-prompt.md` Phase 2's inline comment) — reactivate it once a
  non-interactive Codex worker can initialize delegation and spawn a nested
  `spawn_agent` worker honoring `fork_context=false` and `reasoning_effort=medium`.
- Required result: **logged limitation, not mirrored end-to-end topology**, per the
  plan's fallback clause. This is a harness-behavior gate, not a semantic mirror
  drift item.
- Gating checks to clear after Phase 5: `bash plugins/skein-codex/skills/fan-out/tests/run-seeded-divergence.sh` (direct mode) and `bash tests/parity/test-spawn-tiers.sh` (Claude + Codex census).
- **Reactivation probe:** `bash plugins/skein-codex/skills/fan-out/tests/check-r6-gate-codex.sh` — the runnable symmetric analogue of the Claude gate. Run it from a permitted shell (externally sandboxed, or `FANOUT_PERMS_FLAG=--dangerously-bypass-approvals-and-sandbox`). Under the nested `codex-companion` launch context it hits the `Operation not permitted` app-server init block (exit 2). Run fresh from a plain shell, see the finding below.

#### 2026-07-05 — probe exercised: topology RUNS, but tier is unverifiable via `codex exec --json` (CLI 0.142.5)

Running the reactivation probe from a plain shell (not nested inside a codex session) got **past** the `Operation not permitted` block: the worker spawned a real nested child and returned `NESTED_SPAWN_WORKED`. The `codex exec --json` stream contains genuine inter-agent thread activity — `collab_tool_call` items with `tool: spawn_agent`/`wait`/`close_agent`, distinct `sender_thread_id` and `receiver_thread_ids`, and `agents_states` keyed by the child thread id — i.e. the **nested-spawn topology actually works in this environment**. The earlier `Operation not permitted` was an artifact of the nested launch context, not a fundamental block.

- **But the tier cannot be confirmed.** `codex exec --json` (CLI 0.142.5) exposes **no per-child billing and no `reasoning_effort` echo** anywhere in the stream — token usage appears only at `turn.completed` (whole-session aggregate), never attributed to the spawned child, and no field records the child's effort. So the probe's billing-evidence acceptance model (borrowed by analogy from Claude's `result.modelUsage`, which *does* attribute per-model billing) is **structurally unsatisfiable** on this CLI. The `reasoning_effort=medium` half of the R6 contract is unverifiable from Codex output.
- **Probe behavior (as of this commit):** exit 0 (confirm) is reserved for a future CLI that emits per-child billed usage at the requested effort — it cannot fire on 0.142.5. The observed "spawn ran + success sentinel fired, but no per-child billing/effort" case reports **INCONCLUSIVE (exit 2)**, *not* exit 1 — the topology did not fail, the tier just cannot be measured. Exit 1 is reserved for a `NESTED_SPAWN_FAILED` report or no real spawn evidence (echoed text is never acceptance).
- **Status unchanged: Codex R6 stays gated.** The topology plausibly works, but (a) the tier is unverifiable and (b) availability is launch-context-dependent (blocked when nested). Reactivating the separate-subagent Codex topology still requires a Codex CLI that exposes per-child usage so the tier can be confirmed the way the Claude gate confirms it.

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

- 2026-06-21 — `feature/plan-call-flow-and-interactive-review` (call-flow-diagrams-mermaid-review-loop). Codex mirrors landed **in lockstep on the same branch — no deferred drift**. `plugins/skein-codex/skills/plan-view/{generate.py,template.html,plan-template.html,tests/test_parser.py}` and `plugins/skein-codex/skills/dev-plan/template.md` are mechanical byte-mirrors (Phases 1–2); `plugins/skein-codex/skills/dev-plan/SKILL.md` and `plugins/skein-codex/skills/review-plan/SKILL.md` were Codex-native **adaptations via `codex:rescue`** (Phases 2–4: `spawn_agent`/`reasoning_effort` idioms, plain-text elicitation in place of the AskUserQuestion picker). The `GENERIC FINDING SCHEMA AND MERGE` block and bundled `scripts/` subtree stay byte-identical. Gates green: `just check-prompt-parity`, `just check-sync`, `bash tests/parity/test-prompt-parity-extended.sh` (`13 passed, 0 failed`).
- 2026-05-19 — PR #25 (`chore/codex-skill-model-routing`), merge `03364a2`. Codex-originated model-routing cleanup, not deferred Claude→Codex drift. Changed 8 active `.codex/skills/*/SKILL.md` files plus the mirrored `.claude/skills/review-plan/SKILL.md` parity-prose line. No rubric or `scripts/auto-fix-allowlist.json` parity obligation arose. Gates green: `bash tests/parity/test-allowlist-byte-identity.sh` (`8 passed, 0 failed`), `just check-prompt-parity`, `bash tests/parity/test-prompt-parity-extended.sh` (`13 passed, 0 failed`), and `just check-sync` after `scripts/promote-skills.sh --yes`. `bash tests/parity/check-mirror-handoff.sh` remained non-zero only for the pre-existing PR #23-era `1b49fe8` handoff-hygiene note.
- 2026-05-07 — PR #16 (`feature/skill-improvements-from-usage-report`), merge `222644a`. Adapted Codex files: `.codex/skills/deep-review/{SKILL.md,rubric.md}`, `.codex/skills/dev-plan/{SKILL.md,rubric.md}`, `.codex/skills/update-docs/SKILL.md`. Codex follow-up: `72ac72b`.

No required Codex mirror backlog entries are known at this point. The optional A3/A5 follow-ups are now **resolved** (landed 2026-05-24 in `feature/bundle-auto-fix-appliers`; see the dated entry above).
