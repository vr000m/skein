# Task: Trivial-tier auto-fix for /deep-review and /review-plan

**Status**: In Progress - Codex follow-up pending
**Assigned to**: tbd
**Priority**: Medium
**Branch**: feature/review-auto-fix-tier
**Created**: 2026-05-15
**Last revised**: 2026-05-16 (Claude conduct phases 1-4 landed; Phase 5 contract refined after second `/review-plan` pass — preconditions, linearisation, kind-gate fixtures, marker-refresh check, strict-line-anchor contract decision)
**Completed**: Pending Codex follow-up

## Objective

Add an opt-in `--auto-fix=trivial` tier to `/deep-review` (code review) and `/review-plan` (dev-plan review) that applies a hard-coded allowlist of mechanical, semantics-preserving fixes — leaving everything else advisory. The trigger is a structural `auto_fix` block emitted by the lens; LLM self-classification of "uncontroversial" is explicitly NOT a trigger.

## Context

Two `/review` cycles on PR #22 hit the same pattern: a lens flags a fix that looks trivial (e.g., `lstrip().startswith("lint:")` → column-zero `startswith`), the human reviewer agrees, and we hand-apply the edit. Repeating that loop for every plan/PR is the friction point. But naive auto-application risks compounding misreadings — twice on PR #22 the "obvious" finding turned out to require human context (codex's intentional `schema_version` design; the `_safe_read_state_text` callers).

The recommendation that came out of that review (see horizon note for self-healing review pipelines): narrow, structural allowlist rather than LLM-driven "uncontroversial" classification. The lens must produce a machine-checkable `auto_fix: {kind, before, after, scope}` block whose `kind` is one of a fixed set; the applier rejects anything outside that set or anything whose scope touches a load-bearing section.

The user added an extra constraint for `/review-plan`: plan auto-fixes are limited to **code clarifications or trivial design** — never Requirements, Acceptance Criteria, Files-to-Modify, phase boundaries, schema decisions, or cross-runtime contracts. Those remain advisory, surfaced with `accept / reject / discuss` choices regardless of lens confidence.

Both skills currently produce JSON-Lines findings (`{lens, severity, category, file, line, summary, evidence, suggestion}`) consumed by `scripts/reconcile-findings.sh` with `ENVELOPE_SCHEMA_VERSION=1`; the renderer at `scripts/render-reconciled-report.sh` enforces `EXPECTED_SCHEMA_VERSION=1` in lockstep. Adding `auto_fix` to the finding shape forces a schema bump (v1 → v2) handled by both scripts. The bump is in lockstep per the existing GENERIC FINDING SCHEMA block precedent — the project's policy is "explicit version on shape change," not "additive within version."

Current implementation state: Claude completed the original phases 1-4 and its post-implementation review. Codex has reviewed the resulting branch but has not completed its own conduct pass. The Codex review found implementation defects that affect the shared scripts and byte-identical Claude/Codex skill mirrors, so Claude's landed implementation is not final until Phase 5 below is fixed and verified. Do not treat the Claude conduct state or `Conducted-By: claude` phase commits as Codex completion.

## Requirements

- **Default-off, opt-in.** `--auto-fix=trivial` enables the tier; absence of the flag leaves both skills behaving exactly as today.
- **Structural trigger only.** A finding is eligible iff the lens emitted an `auto_fix: {kind, before, after, scope}` block AND `kind` is in the per-skill allowlist. No textual / heuristic classification.
- **Allowlists are hard-coded** and live in `scripts/auto-fix-allowlist.json` (single source of truth), sourced by the pre-render audit and appliers, and asserted byte-identical against both `.claude` and `.codex` SKILL.md documentation by `check-prompt-parity.sh`. Lens may *propose* `kind`; audit/applier *gates* `kind`. Unknown `kind` → drop to surfaced, never applied.
- **`/deep-review` allowlist (`auto_fix.kind`):**
  - `docstring_typo` — replace inside `"""..."""` / `# ...` / `// ...` only.
  - `unused_import` — single import line deletion.
  - `unused_var` — single declaration deletion when the lens confirms zero non-test reads. Applier re-verifies via `git grep` before applying; mismatch → drop to surfaced.
  - `mechanical_replace` — single-line literal `before`/`after` pair, applied at the cited `file:line`. Multi-line is NOT eligible (applier rejects if `before` contains `\n`).
  - `import_sort` — lint-clean reordering on a single file; no semantic change.
- **`dead_branch` is intentionally NOT in the v1 allowlist.** Dropping unreachable code requires verification the lens cannot reliably provide (a lying or mistaken `evidence.unreachable: true` could swallow a load-bearing fallback). Add back behind a static-analysis gate in a future revision if the data shows the kind is high-value.
- **`/review-plan` allowlist (`auto_fix.kind`):**
  - `symbol_rename` — propagate a referenced helper rename through plan prose (e.g., `_compute_plan_id` → `_compute_cross_runtime_plan_id`).
  - `path_rename` — propagate a moved file path through plan prose.
  - `line_anchor_refresh` — update `path:line` anchors that drift after a non-structural edit.
  - `marker_refresh` — rewrite the `<!-- reviewed: YYYY-MM-DD @ <hash> -->` marker only at the normal review acceptance boundary (`yes` / `waive`), after applied edits and any remaining findings are accepted or waived.
  - `prose_typo` — single-line typo/grammar correction in plan prose.
  - `prose_clarify` — single-line wording clarification only. Multi-line, multi-paragraph, and multi-occurrence edits are advisory in v1.
- **Scope-forbid list (NEVER auto-applied) for `/review-plan`:** any edit whose full span resolves under `## Requirements`, `## Acceptance Criteria`, `### Files to Modify`, `### New Files to Create`, `### Architecture Decisions`, `### Integration Seams`, or any `### Phase N:` heading. Scope detection is structural (heading hierarchy), not heuristic. A `prose_clarify` whose `auto_fix.scope` lands inside one of those sections is dropped to surfaced.
- **`auto_fix.scope` field is typed per skill and requires explicit skill context.** `/deep-review`: `scope ∈ {file, function, block}` — informs the applier's drift-check window but is not used for gating. `/review-plan`: `scope = "<path>:<start-line>[-<end-line>]"` and the span must be single-line for v1. `scripts/reconcile-findings.sh --skill deep-review|review-plan` validates the per-skill type; malformed → see envelope rejection rule below.
- **Malformed `auto_fix` block → reject envelope.** If the v2 reconciler receives an `auto_fix` block missing required keys (`kind`, `before`, `after`, `scope`) or with non-string values, it exits non-zero with a structural error (same principle as `schema_version` mismatch). Lens-emission bugs surface loudly, not silently demote to advisory.
- **Tests-must-pass gate** (`/deep-review` only): the code applier requires an explicit test command (`--test-cmd` or `AUTO_FIX_TEST_CMD`) and runs it exactly once per applied fix (no retry). Failure restores the touched file(s) from saved blobs without touching `HEAD`, re-surfaces the finding as advisory, and records `status: test_failed` with the test output truncated to the last 2000 bytes. Flakes are the user's problem; gate is single-shot to avoid masking a real regression behind a retry loop.
- **Marker invariant** (`/review-plan` only): auto-applied plan edits must not publish a real `/conduct` review marker before the normal review acceptance step. The applier stages or commits the prose edits and records `marker_pending`; after the user accepts or waives remaining findings, the normal Step 6 marker write refreshes `<!-- reviewed: YYYY-MM-DD @ <hash> -->`. Lens-emitted `marker_refresh` blocks before acceptance are no-ops.
- **`marker_refresh` edge cases.** If the accepted plan has no marker line at all (fresh plan), Step 6 writes a new marker matching `dev-plan/template.md` placement (after Acceptance Criteria) rather than raising. If the marker hash computation itself fails (corrupt plan, malformed UTF-8), the applier exits with `status: marker_failed`, rolls back any prose edits applied during the batch, and re-surfaces all findings as advisory.
- **One commit per fix.** Each applied auto-fix lands as its own commit with subject `auto-fix(<skill>): <kind> at <file>:<line>` and trailer `Auto-Fixed-By: <skill>`. Multiple commits in a single run are sequential, not squashed.
- **Rollback manifest.** Each run writes `.deep-review/auto-fix-<unix>.json` (for `/deep-review`) or `.review-plan/auto-fix-<unix>.json` (for `/review-plan`) listing `{kind, file, line, commit_sha, before_sha, status}` per applied fix. `git revert <range>` undoes the batch; the manifest documents the range.
- **Dry-run by default when surfacing.** Without `--auto-fix=trivial`, a pre-render audit step annotates the envelope with `auto_fix_status: "would_apply"` for each finding **that would pass the allowlist AND scope-forbid gates if `--auto-fix=trivial` were set**. The renderer stays pure envelope-to-markdown and only displays `[AUTO-FIXABLE]` for precomputed `would_apply` statuses. Findings carrying `auto_fix` blocks that fail allowlist (`rejected_kind`) or scope-forbid (`rejected_scope`) are NOT annotated, so the annotation accurately previews apply-tier behaviour.
- **Cross-runtime parity.** Allowlist source-of-truth (`scripts/auto-fix-allowlist.json`), applier logic (`scripts/apply-auto-fix-code.sh`, `scripts/apply-auto-fix-plan.sh`, `scripts/lib/auto-fix-common.sh`), schema (GENERIC FINDING SCHEMA block in all four SKILL.md mirrors), and trailer convention must be byte-identical between `.claude/skills/<skill>/` and `.codex/skills/<skill>/`. `scripts/check-prompt-parity.sh` already covers `rubric.md` byte-identity through `scripts/check-prompt-parity.sh:91`; Phase 1 extends it to cover the new schema fragment and the allowlist JSON across both harnesses so every phase boundary can prove Codex did not lag Claude.

## Review Focus

- **Allowlist tightness.** A finding leaking out as "applicable" when it shouldn't be is the failure mode that erodes trust in the whole tier. Reviewers should pressure-test each `kind` against realistic adversarial findings: can `mechanical_replace` be smuggled past as a `before`/`after` that quietly changes behaviour (e.g., `if x:` → `if not x:` is a valid single-line literal pair)? Can `unused_var` slip through when a test file reads the variable? The `mechanical_replace-reject-semantic-flip.jsonl` and `unused_var-reject-test-file-read.jsonl` fixtures must exercise these.
- **Scope-forbid detection for `/review-plan`.** Structural heading-hierarchy parse must not be defeatable by an indented sub-heading, a horizontal rule between a forbidden heading and the target line, a fenced code block masquerading as a heading, or a two-digit phase number. Verify with the malformed/unusual plan fixtures in Phase 3.
- **Schema bump compatibility.** v1 JSONL findings and v1 rendered envelopes may still exist in saved review artifacts, but `.deep-review/latest-*.json` run-state files are a separate schema and are not reconciler input. v2 reconciler must continue to read v1-style JSONL findings without `auto_fix` info (drop to surfaced), while the v2 renderer/appliers consume v2 envelopes and stale v1 renderers reject v2 envelopes loudly rather than silently miss `auto_fix` data. Malformed v2 findings (e.g., `auto_fix` with missing `scope`) must be rejected with a clear error — see the malformed-block rule above.
- **Test-gate correctness.** A single-shot, no-retry test command is the contract; the gate must not silently retry on flake. The `test-deep-review-test-gate-single-invocation.sh` fixture asserts the gate invokes the command exactly once via a counter wrapper.
- **Trailer convention.** `Auto-Fixed-By: <skill>` must NOT collide with `Conducted-By: <runtime>` parsing in `tests/parity/check-mirror-handoff.sh:51`. The handoff gate matches `Conducted-By:` explicitly (case-sensitive) and ignores anything else. The Phase 2 regression test covers (a) single `Auto-Fixed-By:` trailer, (b) both trailers on one commit, (c) lowercase `auto-fixed-by:`.
- **Mirror parity discipline.** Per repo precedent (CLAUDE-side authority on shared SKILL prose), drift between `.claude` and `.codex` lens prompts has bitten before. The new `auto_fix` block must be in the byte-identical GENERIC FINDING SCHEMA region, not the lens-specific prose. `rubric.md` edits in Phase 2 and Phase 3 pair `.claude` + `.codex` in the same phase commit so `check-prompt-parity.sh` stays green at every phase boundary.
- **Marker failure mode.** The existing per-harness `conduct/marker.py` remains the promoted runtime hash authority. `/review-plan` marker refresh must match that authority exactly: no marker present writes a fresh marker at acceptance, corrupt UTF-8 exits `marker_failed`, and plan auto-fix prose edits never make `/conduct` eligible before user acceptance. The `marker_refresh-missing-marker.jsonl` and `marker_refresh-corrupt-plan.jsonl` fixtures cover these.

## Implementation Checklist

The Implementation Checklist is part of the **immutable contract** above the review marker.

### Phase 1: Shared schema + reconciler + parity + pre-render audit

**Impl files:** `scripts/reconcile-findings.sh, scripts/render-reconciled-report.sh, scripts/audit-auto-fix-eligibility.sh, scripts/auto-fix-allowlist.json, scripts/check-prompt-parity.sh, .claude/skills/deep-review/SKILL.md, .claude/skills/review-plan/SKILL.md, .codex/skills/deep-review/SKILL.md, .codex/skills/review-plan/SKILL.md`
**Test files:** `tests/reconciliation/test-renderer.sh, tests/reconciliation/test-reconciler-unit.sh, tests/reconciliation/run-fixtures.sh, tests/reconciliation/fixtures/auto-fix-v2-*.jsonl, tests/reconciliation/fixtures/auto-fix-v2-malformed-*.jsonl, tests/parity/test-allowlist-byte-identity.sh`
**Test command:** `just reconciliation-tests && bash scripts/check-prompt-parity.sh && bash tests/parity/test-allowlist-byte-identity.sh`

- Bump `ENVELOPE_SCHEMA_VERSION` in `scripts/reconcile-findings.sh` from `1` to `2`; bump `EXPECTED_SCHEMA_VERSION` in `scripts/render-reconciled-report.sh:43` from `1` to `2` in the same commit (lockstep rule per existing GENERIC block doc).
- Extend the finding JSONL shape with an optional `auto_fix: {kind: str, before: str, after: str, scope: str}` field. v2 reconciler passes it through unchanged when well-formed; rejects input when present-but-malformed (missing key, non-string value).
- Add `--skill deep-review|review-plan` to `scripts/reconcile-findings.sh`; validation of `auto_fix.scope` and allowlist compatibility keys off this explicit context.
- v2 reconciler reading v1-style JSONL findings MUST upgrade them in-flight (treat `auto_fix` as absent → finding surfaced, not applied). Fixture `auto-fix-v2-reads-v1-jsonl.jsonl`.
- Current v2 renderer reading a stale v1 envelope MUST exit non-zero with `schema mismatch: got 1, expected 2`. Add a separate historical-v1-renderer fixture only if preserving old renderer binaries becomes an explicit support target.
- v2 reconciler reading v2 JSONL with malformed `auto_fix` MUST exit non-zero with `auto_fix block malformed: <reason>`. Fixtures: `auto-fix-v2-malformed-missing-scope.jsonl`, `auto-fix-v2-malformed-nonstring-before.jsonl`.
- Create `scripts/auto-fix-allowlist.json` as the single source of truth for allowlist enums. Shape: `{"deep-review": [...kinds...], "review-plan": [...kinds...]}`. Used by both the pre-render audit and appliers; cited verbatim in both `.claude` and `.codex` SKILL.md docs so `check-prompt-parity.sh` can assert byte-identity.
- Update both skills' GENERIC FINDING SCHEMA AND MERGE blocks (the byte-identical block enforced by `check-prompt-parity.sh:237-274`) to document the new field, the per-skill `scope` typing, and the malformed-rejection rule. Mirror to both `.claude` and `.codex` copies; verify with `bash scripts/check-prompt-parity.sh`.
- Extend `scripts/check-prompt-parity.sh` in this phase to verify the allowlist arrays are cited verbatim in all four SKILL.md mirrors. This keeps Codex and Claude in sync at the first phase boundary where the contract exists.
- Create `scripts/audit-auto-fix-eligibility.sh`: takes `--skill deep-review|review-plan`, a v2 reconciled envelope, and optional `--plan <path>` for review-plan scope checks; emits the same envelope with `auto_fix_status` set to `would_apply`, `rejected_kind`, `rejected_scope`, `drift`, or another explicit non-apply status. `scripts/render-reconciled-report.sh` remains a pure envelope renderer and only displays `[AUTO-FIXABLE]` for `auto_fix_status: "would_apply"`.

### Phase 2: `/deep-review` auto-fix applier + handoff regression test

**Impl files:** `scripts/apply-auto-fix-code.sh, scripts/lib/auto-fix-common.sh, .claude/skills/deep-review/SKILL.md, .claude/skills/deep-review/rubric.md, .codex/skills/deep-review/SKILL.md, .codex/skills/deep-review/rubric.md`
**Test files:** `tests/auto-fix/test-deep-review-allowlist.sh, tests/auto-fix/test-deep-review-test-gate.sh, tests/auto-fix/test-deep-review-test-gate-single-invocation.sh, tests/auto-fix/test-deep-review-test-command-required.sh, tests/auto-fix/test-deep-review-failed-fix-preserves-head.sh, tests/parity/test-handoff-ignores-auto-fix.sh, tests/auto-fix/fixtures/<kind>-{accept,reject,reject-multiline,reject-semantic-flip,reject-test-file-read}.jsonl`
**Test command:** `bash tests/auto-fix/test-deep-review-allowlist.sh && bash tests/auto-fix/test-deep-review-test-gate.sh && bash tests/auto-fix/test-deep-review-test-gate-single-invocation.sh && bash tests/auto-fix/test-deep-review-test-command-required.sh && bash tests/auto-fix/test-deep-review-failed-fix-preserves-head.sh && bash tests/parity/test-handoff-ignores-auto-fix.sh`
**Validation cmd:** `cd /tmp && bash -c 'mkdir -p auto-fix-smoke && cd auto-fix-smoke && git init -q && git commit --allow-empty -m init -q && echo "from os import path" > a.py && git add a.py && git commit -q -m a && printf "{\"schema_version\":2,\"findings\":[{\"lens\":\"logic\",\"severity\":\"Minor\",\"category\":\"unused\",\"file\":\"a.py\",\"line\":1,\"summary\":\"unused import\",\"auto_fix\":{\"kind\":\"unused_import\",\"before\":\"from os import path\\n\",\"after\":\"\",\"scope\":\"file\"},\"auto_fix_status\":\"would_apply\"}]}" > findings.json && bash $REPO/scripts/apply-auto-fix-code.sh --test-cmd true findings.json'`

- Create `scripts/lib/auto-fix-common.sh`: shared bash helpers (manifest writer, drift-check `before`-vs-file byte-match, allowlist loader from `auto-fix-allowlist.json`, blob-based restore helpers, commit + trailer composition). Sourced by both appliers (Phase 2 and Phase 3 entry scripts). Preserve the repo's jq-optional pattern where practical; any jq-only helper must fail with a clear setup error and the dependency docs must be updated in the same phase.
- Create `scripts/apply-auto-fix-code.sh`: the `/deep-review` entry point. Takes `--test-cmd <cmd>` (or `AUTO_FIX_TEST_CMD`) plus `<findings-envelope.json>`. Reads `schema_version` (must be 2). Iterates findings carrying `auto_fix_status: "would_apply"`. For each: load allowlist key `deep-review`; reject unknown `kind` (`status: rejected_kind`); assert `before` matches `file:line` byte-for-byte (drift → `status: drift`); for `unused_var`, re-verify via `git grep -c "<var>"` excluding test files (mismatch → `status: rejected_revar`); for `mechanical_replace`, reject if `before` contains `\n` (multi-line → `status: rejected_multiline`); save pre-apply blobs for every touched path; rewrite `before` → `after`; stage the file; run the test command exactly once (no retry); on pass → commit with subject `auto-fix(deep-review): <kind> at <file>:<line>` and `--trailer "Auto-Fixed-By: deep-review"`; on fail → restore the touched paths from saved blobs, unstage those paths, leave `HEAD` unchanged, and append `status: test_failed`.
- Adversarial fixtures (Phase 2): `mechanical_replace-reject-semantic-flip.jsonl` (`if x:` → `if not x:`; documents the smuggling tradeoff: applier byte-matches but doesn't semantic-check, so this fixture asserts the applier *applies* and the test-gate catches), `mechanical_replace-reject-multiline.jsonl` (multi-line `before` → rejected pre-apply), `unused_var-reject-test-file-read.jsonl` (test file reads the var → applier's re-verification catches before apply), `docstring_typo-{accept,reject-outside-docstring}.jsonl`, `unused_import-{accept,reject-still-referenced}.jsonl`, `import_sort-{accept,reject-semantic-change}.jsonl`.
- `tests/auto-fix/test-deep-review-test-gate-single-invocation.sh`: wraps the test command in a counter-incrementing shim; assert counter == 1 per applied fix. Closes Review Focus "single-shot, no retry" item.
- `tests/auto-fix/test-deep-review-test-command-required.sh`: invokes the applier without `--test-cmd` / `AUTO_FIX_TEST_CMD` and asserts a clear non-zero error before any edit.
- `tests/auto-fix/test-deep-review-failed-fix-preserves-head.sh`: starts from a repo with a real prior commit, forces a test failure, and asserts `HEAD` still points to the prior commit while the touched file is restored.
- `tests/parity/test-handoff-ignores-auto-fix.sh`: covers (a) commit with only `Auto-Fixed-By:` trailer → ignored by handoff gate, (b) commit with both `Auto-Fixed-By:` + `Conducted-By:` trailers → matched as `Conducted-By:`, (c) commit with lowercase `auto-fixed-by:` → ignored (handoff is case-sensitive). Lives in Phase 2 because Phase 2 introduces the trailer.
- Wire `--auto-fix=trivial` into `/deep-review` SKILL.md Step 5 (after reconciliation, before user-facing report). Mirror the wiring + the rubric edit in `.codex/skills/deep-review/SKILL.md` and `.codex/skills/deep-review/rubric.md` in the same phase commit so `scripts/check-prompt-parity.sh` (which enforces `rubric.md` byte-identity per lines 60-89) stays green at the Phase 2 boundary.
- Update `.claude/skills/deep-review/rubric.md` AND `.codex/skills/deep-review/rubric.md` to add a criterion: "lens emitted `auto_fix` block whenever a finding matches the allowlist shape; absent `auto_fix` on a clearly mechanical finding is a quality issue."

### Phase 3: `/review-plan` auto-fix applier with scope-forbid + .gitignore

**Impl files:** `scripts/apply-auto-fix-plan.sh, scripts/plan-scope-detect.sh, .claude/skills/review-plan/SKILL.md, .claude/skills/review-plan/rubric.md, .codex/skills/review-plan/SKILL.md, .codex/skills/review-plan/rubric.md, .gitignore`
**Test files:** `tests/auto-fix/test-review-plan-allowlist.sh, tests/auto-fix/test-review-plan-scope-forbid.sh, tests/auto-fix/test-review-plan-marker-refresh.sh, tests/auto-fix/test-review-plan-marker-edge-cases.sh, tests/auto-fix/test-review-plan-conduct-preflight.sh, tests/auto-fix/fixtures/plan-<kind>-{accept,reject}.md, tests/auto-fix/fixtures/plan-<kind>-{accept,reject}.jsonl, tests/auto-fix/fixtures/plan-scope-evasion-{indented,horizontal-rule,fenced,two-digit-phase}.md, tests/auto-fix/fixtures/marker_refresh-{missing-marker,corrupt-plan,lens-emitted-noop}.jsonl`
**Test command:** `bash tests/auto-fix/test-review-plan-allowlist.sh && bash tests/auto-fix/test-review-plan-scope-forbid.sh && bash tests/auto-fix/test-review-plan-marker-refresh.sh && bash tests/auto-fix/test-review-plan-marker-edge-cases.sh && bash tests/auto-fix/test-review-plan-conduct-preflight.sh && (cd .codex/skills/conduct && uv run --with pytest python -m pytest tests/test_marker.py tests/test_preflight.py -q) && (cd .claude/skills/conduct && uv run --with pytest python -m pytest tests/test_marker.py tests/test_preflight.py -q)`

- Keep `compute_plan_hash` inside `.claude/skills/conduct/marker.py` and `.codex/skills/conduct/marker.py`; do not make promoted conduct depend on repo-root `scripts/`. `scripts/apply-auto-fix-plan.sh` must either reuse the same documented algorithm locally or call a helper that lives under the promoted review-plan skill tree. Parity is proven with shared marker tests, not by introducing a repo-root dependency into global conduct.
- Create `scripts/plan-scope-detect.sh` (bash + awk): takes `<plan-file> <line>`, returns the deepest enclosing column-zero heading (e.g., `## Requirements`, `### Phase 2: foo`). Skips fenced code blocks when resolving the enclosing heading. Used by the applier to enforce the scope-forbid list.
- Create `scripts/apply-auto-fix-plan.sh`: the `/review-plan` entry point. Same shape as the code applier but: (1) loads allowlist key `review-plan` from `auto-fix-allowlist.json`; (2) calls `plan-scope-detect.sh` for each fix and drops if the full span resolves under `{## Requirements, ## Acceptance Criteria, ### Files to Modify, ### New Files to Create, ### Architecture Decisions, ### Integration Seams}` OR matches `^### Phase \d+:` (covers any digit count); (3) no test gate before commit (plans are markdown); (4) records `marker_pending` and does not write a real review marker until the normal review-plan `yes` / `waive` marker step. Lens-emitted `marker_refresh` blocks within the batch are no-ops.
- Adversarial fixtures (Phase 3): `plan-scope-evasion-indented.md` (` ## Requirements` with leading whitespace), `plan-scope-evasion-horizontal-rule.md` (`---` between forbidden heading and target line — assert detector still resolves to the forbidden heading), `plan-scope-evasion-fenced.md` (`` ```## Requirements `` inside a fenced block — assert detector does NOT treat as a heading), `plan-scope-evasion-two-digit-phase.md` (`### Phase 10:` — assert detector matches the regex), and the standard `<kind>-{accept,reject}.jsonl` set per allowlist `kind`.
- Edge-case fixtures (Phase 3): `marker_refresh-missing-marker.jsonl` (accepted plan has no marker line → Step 6 writes fresh marker at template position), `marker_refresh-corrupt-plan.jsonl` (malformed UTF-8 in plan → applier exits `marker_failed`, rolls back batch), `marker_refresh-lens-emitted-noop.jsonl` (lens emits a `marker_refresh` block AND a `prose_typo`; assert no real marker is written until acceptance, satisfying AC #6).
- `tests/auto-fix/test-review-plan-conduct-preflight.sh`: applies a plan auto-fix, performs the normal accepted marker write, then verifies Codex `run_preflight` accepts the plan and `marker_is_stale(plan) is False`.
- Update every review-plan auto-edit contract surface in `.claude/skills/review-plan/SKILL.md` and `.codex/skills/review-plan/SKILL.md`, not only Step 6. Required surfaces include the overview, discussion section, constraints, auto-fix wiring, and marker procedure. Update `.claude/skills/review-plan/rubric.md` AND `.codex/skills/review-plan/rubric.md` to add the lens-emission criterion (mirror of Phase 2's deep-review rubric line).
- Add `.review-plan/` to `.gitignore` in this phase (the phase that first creates the directory).

### Phase 4: Final repo-local parity and post-merge promotion instructions

**Impl files:** `scripts/check-prompt-parity.sh, docs/dev_plans/20260515-feature-review-auto-fix-tier.md`
**Test files:** `tests/parity/test-prompt-parity-extended.sh`
**Test command:** `bash scripts/check-prompt-parity.sh && bash tests/parity/test-prompt-parity-extended.sh && bash tests/parity/check-mirror-handoff.sh && just check-sync`
**Validation cmd:** `just reconciliation-tests && just lint-scripts && git diff --check`

- Verify the Phase 1 parity extension still covers the new `auto_fix` schema fragment, allowlist JSON citations, rubric parity, `*-prompt.md` parity, and the four SKILL.md generic blocks across both `.claude` and `.codex`.
- `tests/parity/test-prompt-parity-extended.sh`: assert a Codex-only auto-fix wiring drift fails the parity gate, so Codex cannot silently lag Claude.
- Do not run `scripts/promote-skills.sh --yes` as a feature-branch validation step. Add the post-merge rollout instruction to Final Results instead: after merge and final approval, run `MANAGED_SKILLS="deep-review review-plan" scripts/promote-skills.sh --yes && just check-sync` from a clean main checkout.

### Phase 5: Codex review follow-up hardening

**Impl files:** `scripts/plan-scope-detect.sh, scripts/audit-auto-fix-eligibility.sh, scripts/apply-auto-fix-plan.sh, scripts/apply-auto-fix-code.sh, .claude/skills/deep-review/SKILL.md, .codex/skills/deep-review/SKILL.md, .claude/skills/review-plan/SKILL.md, .codex/skills/review-plan/SKILL.md, docs/dev_plans/20260515-feature-review-auto-fix-tier.md`
**Test files:** `tests/auto-fix/test-review-plan-scope-forbid.sh, tests/auto-fix/test-review-plan-allowlist.sh, tests/auto-fix/test-review-plan-binding.sh, tests/auto-fix/test-deep-review-allowlist.sh, tests/auto-fix/test-deep-review-kind-gates.sh, tests/auto-fix/test-deep-review-clean-index-guard.sh, tests/auto-fix/test-deep-review-failed-fix-preserves-head.sh, tests/auto-fix/test-plan-scope-detect-mode-isolation.sh, tests/auto-fix/test-marker-refresh-post-phase5.sh, tests/parity/test-auto-fix-orchestration-contract.sh, tests/reconciliation/test-renderer-v1-rejects-v2.sh, tests/reconciliation/test-renderer.sh, tests/reconciliation/fixtures/*, tests/auto-fix/fixtures/docstring_typo-{accept,reject-code-edit}.jsonl, tests/auto-fix/fixtures/import_sort-{accept,reject-symbol-change}.jsonl, tests/auto-fix/fixtures/unused_import-{accept,reject-still-referenced}.jsonl, tests/auto-fix/fixtures/plan-scope-evasion-parent-heading.md, tests/reconciliation/fixtures/render-reconciled-report-v1.sh`
**Test command:** `bash tests/auto-fix/test-review-plan-scope-forbid.sh && bash tests/auto-fix/test-review-plan-allowlist.sh && bash tests/auto-fix/test-review-plan-binding.sh && bash tests/auto-fix/test-deep-review-allowlist.sh && bash tests/auto-fix/test-deep-review-kind-gates.sh && bash tests/auto-fix/test-deep-review-clean-index-guard.sh && bash tests/auto-fix/test-deep-review-failed-fix-preserves-head.sh && bash tests/auto-fix/test-plan-scope-detect-mode-isolation.sh && bash tests/auto-fix/test-marker-refresh-post-phase5.sh && bash tests/parity/test-auto-fix-orchestration-contract.sh && bash tests/reconciliation/test-renderer-v1-rejects-v2.sh && bash scripts/check-prompt-parity.sh && just reconciliation-tests`
**Validation cmd:** `just lint-scripts && git diff --check`

**Preconditions (must hold before Codex `/conduct` starts Phase 5):**

- **P1. Fresh accepted marker.** Phase 5 changes the immutable contract above the marker, so the existing marker is stale. Codex `/review-plan` against this updated plan must complete and the user must accept (or waive) findings; the accepted-marker write lands as a commit on `feature/review-auto-fix-tier` before any Phase 5 implementation commit. The marker hash MUST equal `git hash-object --stdin` of the contract section above the new marker line (this invariant is enforced by `test-marker-refresh-post-phase5.sh` in item 8).
- **P2. Fresh Codex conduct state file.** The existing `.conduct/state-20260515-feature-review-auto-fix-tier-398d56c7132a.json` is Claude-owned (`state_author: "claude"`) and Phase 5 conduct MUST NOT mutate or count it. Codex `/conduct` for Phase 5 starts a fresh state file with `state_author: "codex"`; the Claude state file is preserved untouched as historical record. Conduct preflight MUST select the Codex-authored state file when `Conducted-By: codex` is the active runtime.

**Work items (linearised; each numbered item lands as one commit unless the item explicitly bundles paired edits):**

1. **Hierarchy-aware scope-forbid.** Extend `scripts/plan-scope-detect.sh` with a new `--stack <plan-file> <line>` mode whose output schema is: enclosing column-zero headings, outermost-first, one heading per line, terminating newline, no trailing blank line; empty stdout (exit 0) for `unknown`. The existing two-argument deepest-heading mode is preserved byte-for-byte. Auditor (`scripts/audit-auto-fix-eligibility.sh`) and applier (`scripts/apply-auto-fix-plan.sh`) switch to stack mode and reject if ANY heading in the stack matches the forbid list — in the same commit as the script change so no caller ever references an unsupported mode. Add `tests/auto-fix/test-plan-scope-detect-mode-isolation.sh` asserting two-arg-mode output is byte-identical pre/post change against a fixture set. Add fixture `tests/auto-fix/fixtures/plan-scope-evasion-parent-heading.md` (a `## Requirements` containing `### Detail` with the target line inside `### Detail`); the new regression in `test-review-plan-scope-forbid.sh` runs both `audit-auto-fix-eligibility.sh --skill review-plan --plan <fixture>` (asserts `rejected_scope`) and `apply-auto-fix-plan.sh --plan <fixture> <envelope>` (asserts no commit, manifest `status: rejected_scope`).

2. **Strict line-anchored `--plan` binding (v2 contract change — atomic commit).** Add `--plan <reviewed-plan>` to `scripts/apply-auto-fix-plan.sh`. The applier MUST enforce, in this single commit, all three invariants:
   - **Triple path equality.** `finding.file`, `auto_fix.scope` path, and the reviewed `--plan` path must all resolve to the same in-repo file; mismatch → `status: rejected_path`, no commit.
   - **Strict cited-line byte-match.** `auto_fix.before` is matched only at the exact `auto_fix.scope` line in the file. The v1 "find unique match anywhere in file" fallback is removed; a `before` that appears elsewhere in the file but NOT at the cited line → `status: rejected_drift`. See Architecture Decisions: "Strict line-anchored apply for review-plan."
   - **Paired SKILL.md updates.** `.claude/skills/review-plan/SKILL.md` and `.codex/skills/review-plan/SKILL.md` invocations are updated to pass `--plan` in the same commit so orchestration never references a flag the script does not accept.
   The script change, both SKILL.md edits, AND `tests/auto-fix/test-review-plan-binding.sh` (item 3) land together to avoid any intermediate broken state.

3. **Binding regression test** (bundled into item 2's commit). `tests/auto-fix/test-review-plan-binding.sh` covers four distinct cases, each asserting no commit is created and the manifest records the named non-apply status:
   - `finding.file != auto_fix.scope.path` → `rejected_path`.
   - `auto_fix.scope.path != --plan` → `rejected_path`.
   - **Duplicate-before / non-cited-unique-match:** the plan contains `auto_fix.before` text both at cited line N and at non-cited line N+10; with v1 unique-match-anywhere this would have edited N+10. v2 strict line-anchor → `rejected_drift` (no edit at any line). This case specifically proves the removal of the v1 find-anywhere-in-file behaviour.
   - **Cited-line drift:** `auto_fix.before` text moved within the file (e.g., a preceding insertion shifted lines) so the cited line no longer byte-matches; the same text still exists at a different unique line. v2 → `rejected_drift`. Distinct from existing Phase 2 drift coverage where `before` does not match anywhere.

4. **Audit-before-render orchestration contract (atomic across four SKILL.md mirrors).** Insert an explicit audit step between reconciliation and rendering in `.claude/skills/deep-review/SKILL.md`, `.codex/skills/deep-review/SKILL.md`, `.claude/skills/review-plan/SKILL.md`, and `.codex/skills/review-plan/SKILL.md`. The exact invocation strings (the parity test asserts on these):
   - deep-review SKILL.md: `scripts/audit-auto-fix-eligibility.sh --skill deep-review <envelope>`
   - review-plan SKILL.md: `scripts/audit-auto-fix-eligibility.sh --skill review-plan --plan <reviewed-plan> <envelope>`
   Without `--auto-fix=trivial` the audit still runs as a dry-run preview so `[AUTO-FIXABLE]` only appears from computed `auto_fix_status: "would_apply"`. Wrap the new audit-invocation lines inside the byte-identical region already enforced by `scripts/check-prompt-parity.sh` so drift fails the parity gate, not a separate substring grep. Add `tests/parity/test-auto-fix-orchestration-contract.sh` asserting for each of the four SKILL.md mirrors: (a) the expected invocation string is present (regex anchored on the script name AND the `--skill` arg AND, for review-plan, the `--plan` arg), and (b) the audit step appears textually before the render step. Land the four SKILL.md edits + the parity test in a single commit so `check-prompt-parity.sh` and the new orchestration test are both green at the phase boundary.

5. **Code applier clean-index guard.** Harden `scripts/apply-auto-fix-code.sh` to reject when the working tree or index is dirty before any edit (mirror the plan applier's clean-tree guard). Add `tests/auto-fix/test-deep-review-clean-index-guard.sh` with three explicit states; each case asserts non-zero exit before edits, no `auto-fix(deep-review)` commit, and pre-existing index/tree state preserved exactly:
   - **Unstaged tracked change** on the auto-fix target file.
   - **Unrelated staged file** in the index (different file from the auto-fix target).
   - **Mixed dirty:** staged change on file A + unstaged change on file B + untracked file C; applier exits non-zero; staged change on A remains staged with its original content, unstaged change on B remains unstaged, untracked file C remains untracked.

6. **Kind-specific gate tightening with named adversarial fixtures.** Tighten `docstring_typo`, `import_sort`, and `unused_import` gates in `scripts/apply-auto-fix-code.sh`. Add `tests/auto-fix/test-deep-review-kind-gates.sh` driving the gates against named fixtures (each named in the Test files list above):
   - `docstring_typo-accept.jsonl` (edit inside `"""..."""` or comment) and `docstring_typo-reject-code-edit.jsonl` (`auto_fix.scope` resolves to code outside any docstring/comment → `rejected_kind_scope`).
   - `import_sort-accept.jsonl` (pure reorder) and `import_sort-reject-symbol-change.jsonl` (`before`/`after` symbol sets differ — i.e., a symbol is added or removed → `rejected_semantic_change`).
   - `unused_import-accept.jsonl` and `unused_import-reject-still-referenced.jsonl` (applier's re-verification `git grep` finds a non-comment reference outside the import line → `rejected_revar`).
   `unused_var` contract is **decided**: the applier blocks deletion if `git grep -c <var>` (scanning ALL tracked files including `tests/`) returns non-zero. `unused_var-reject-test-file-read.jsonl` exercises a variable read only from `tests/` and asserts `status: rejected_revar`. The fixture name and the plan claim both stay; the regression is to make the applier's grep scan match this contract.

7. **Stale v1-renderer compatibility fixture.** Snapshot `scripts/render-reconciled-report.sh` at the pre-Phase-1 v1 commit into `tests/reconciliation/fixtures/render-reconciled-report-v1.sh` (read-only fixture). Add `tests/reconciliation/test-renderer-v1-rejects-v2.sh` asserting the v1 renderer exits non-zero with the message `schema mismatch: got 2, expected 1` when fed any v2 envelope from `tests/reconciliation/fixtures/auto-fix-v2-*.jsonl`. AC #12 wording is unchanged; the new fixture closes the gap between the AC claim and the implemented test.

8. **Marker-refresh-after-Phase-5 automated check.** Add `tests/auto-fix/test-marker-refresh-post-phase5.sh` that locates the last column-zero marker line in `docs/dev_plans/20260515-feature-review-auto-fix-tier.md` matching `^<!-- reviewed: \d{4}-\d{2}-\d{2} @ [0-9a-f]{40} -->\s*$`, recomputes `git hash-object --stdin` over everything above that marker line, and asserts the recomputed hash equals the hash embedded in the marker. The test is invoked in the Phase 5 Test command above so phase completion cannot be marked done with a stale marker. The same test also satisfies P1's invariant when re-run after the post-impl review pass in item 10.

9. **Stale factual claim refresh.** Fix the `ENVELOPE_SCHEMA_VERSION` line anchor and any other line-anchored claims in this plan that drifted during Phases 1-4. Doc-only commit; safe to interleave with items 1, 10, or 11.

10. **Post-impl review gates (defines Phase 5 completion).** After items 1-9 land:
    - (a) Run Codex `/review-plan` against this plan again; reconcile any new findings; write a fresh accepted marker.
    - (b) Run Claude `/review-plan` as the final cross-runtime gate (required because Phase 5 touches both `.claude/skills/...` and `.codex/skills/...`).
    - (c) If either review returns Critical / Important findings, fix them on this same branch and repeat (a) and (b) until both reviews are clean.
    **Phase 5 is complete ONLY when all of these hold simultaneously:** both post-impl reviews return zero Critical / Important findings (or applied fixes re-pass both reviews), `test-marker-refresh-post-phase5.sh` is green against the latest accepted marker, and every gate in the Phase 5 Test command + Validation cmd is green.

## Technical Specifications

### Files to Modify

- `scripts/reconcile-findings.sh` — bump `ENVELOPE_SCHEMA_VERSION` 1→2; add `--skill deep-review|review-plan`; pass-through well-formed `auto_fix` on findings; reject malformed `auto_fix` (missing key, non-string value, malformed per-skill scope).
- `scripts/render-reconciled-report.sh:43` — bump `EXPECTED_SCHEMA_VERSION` 1→2; display `[AUTO-FIXABLE]` only for findings already annotated with `auto_fix_status: "would_apply"`. Keep rendering pure envelope-to-markdown.
- `scripts/audit-auto-fix-eligibility.sh` — pre-render and pre-apply eligibility audit. Computes `auto_fix_status` from the allowlist, drift checks, and review-plan scope-forbid checks before the renderer or appliers run.
- `.claude/skills/deep-review/SKILL.md` — document `--auto-fix=trivial` flag, the `auto_fix` block in the GENERIC FINDING SCHEMA section, the per-skill `scope` typing, the allowlist (cite `auto-fix-allowlist.json` deep-review array verbatim), and the rejection rules. Mirror block is byte-identical with `.codex/`.
- `.claude/skills/deep-review/rubric.md` — add lens-emission criterion.
- `.claude/skills/review-plan/SKILL.md` — same shape; cite `auto-fix-allowlist.json` review-plan array verbatim; document scope-forbid invariant and marker edge cases.
- `.claude/skills/review-plan/rubric.md` — add lens-emission criterion.
- `.codex/skills/deep-review/SKILL.md`, `.codex/skills/deep-review/rubric.md`, `.codex/skills/review-plan/SKILL.md`, `.codex/skills/review-plan/rubric.md` — byte-identical mirrors, edited in the same phase commit as their `.claude` counterparts.
- `.claude/skills/conduct/marker.py`, `.codex/skills/conduct/marker.py` — no repo-root helper dependency. Keep the promoted runtime hash implementation self-contained; add tests proving review-plan marker writes still match both harnesses.
- `scripts/check-prompt-parity.sh` — extend in Phase 1 to cover allowlist JSON ↔ SKILL.md byte-identity and Codex-specific auto-fix wiring surfaces.
- Phase 5 hardening files listed above — update shared scripts and both `.claude` / `.codex` skill mirrors together because the defects affect the shared implementation, not only Codex documentation.
- `.gitignore` — add `.review-plan/`.

### New Files to Create

- `scripts/auto-fix-allowlist.json` — single source of truth for per-skill allowlist enums. Shape: `{"deep-review": ["docstring_typo", "unused_import", "unused_var", "mechanical_replace", "import_sort"], "review-plan": ["symbol_rename", "path_rename", "line_anchor_refresh", "marker_refresh", "prose_typo", "prose_clarify"]}`.
- `scripts/audit-auto-fix-eligibility.sh` — dry-run eligibility audit. Bash + awk; jq optional unless dependency docs are updated.
- `scripts/apply-auto-fix-code.sh` — `/deep-review` applier entry point. Bash + awk; jq optional unless dependency docs are updated.
- `scripts/apply-auto-fix-plan.sh` — `/review-plan` applier entry point. Bash + awk; jq optional unless dependency docs are updated.
- `scripts/lib/auto-fix-common.sh` — shared bash helpers (manifest writer, drift-check, allowlist loader, commit + trailer composition).
- `scripts/plan-scope-detect.sh` — bash + awk; resolves `file:line` → enclosing heading hierarchy. Skips fenced code blocks.
- `tests/auto-fix/` — new test directory:
  - `test-deep-review-allowlist.sh`, `test-deep-review-test-gate.sh`, `test-deep-review-test-gate-single-invocation.sh`
  - `test-review-plan-allowlist.sh`, `test-review-plan-scope-forbid.sh`, `test-review-plan-marker-refresh.sh`, `test-review-plan-marker-edge-cases.sh`
  - `fixtures/` per Phase 2 and Phase 3 fixture lists above.
- `tests/parity/test-handoff-ignores-auto-fix.sh` — lives in Phase 2 (introduced with the trailer).
- `tests/parity/test-allowlist-byte-identity.sh` — Phase 4.

### Architecture Decisions

- **Structural marker only.** The lens emits `auto_fix: {kind, before, after, scope}`; the applier gates `kind`. LLM self-classification is never the trigger. Rationale: failure mode from PR #22 was twice that the "obvious" finding required human context. Hard-coded allowlist + before/after byte-match defeats most adversarial smuggling.
- **`dead_branch` deliberately excluded from v1 allowlist.** Unreachability is a property the lens cannot reliably self-tag without static analysis; trusting `evidence.unreachable: true` opens a load-bearing-fallback-swallow hole that the v1 design refuses to take. Re-add behind a static-analysis gate in a future revision if the data shows the kind is high-value.
- **Schema v2 over additive v1.** Adding `auto_fix` triggers the lockstep bump even though it is an optional field, matching the existing GENERIC block's "bump on shape change" precedent and the project's policy of explicit version boundaries over silent additive evolution. The breakage risk (v1 renderer hard-rejects v2 envelopes) is accepted because no v1 renderer ships after v2 lands; the only consumers are obsolete rendered envelopes and developers running stale CI containers, both of which are acceptable hard-fail surfaces. `.deep-review/latest-*.json` run state is separate and is not part of this migration unless implementation discovers an actual state-file shape change.
- **One commit per successful fix, no squash.** Each successful `auto-fix(...)` commit is independently revertable. The manifest documents the range; `git revert <a>..<b>` is the supported rollback for already-committed successful fixes. Failed pre-commit fixes restore touched paths from saved blobs and never run `git revert HEAD`, so user commits are not at risk.
- **Two appliers + shared lib, not one dispatching script.** `apply-auto-fix-code.sh` and `apply-auto-fix-plan.sh` are separate entry points sharing `scripts/lib/auto-fix-common.sh` for manifest + drift-check + allowlist loading. The two skills' gating logic is disjoint (test-gate vs scope-forbid + marker-refresh); a single dispatcher would obscure that invariant. Matches the existing `reconcile-findings.sh` / `render-reconciled-report.sh` separation pattern.
- **Promoted runtime stays self-contained.** Do not make `.claude/skills/conduct/marker.py` or `.codex/skills/conduct/marker.py` call repo-root `scripts/` helpers, because `promote-skills` copies skill directories to global locations without the repo scripts tree. Hash parity is enforced by tests and documented algorithm, not by a global skill depending on a local checkout.
- **Applier is bash, not Python.** Both review skills are markdown-only today; adding a Python dependency would change their footprint. The applier is git + awk with jq kept optional unless dependency docs are updated. (Note: `marker.py` continues to exist in `conduct/` because the conductor uses it; the applier must match its hash semantics without importing or shelling into the conduct runtime.)
- **Trailer is `Auto-Fixed-By: <skill>`, not `Auto-Fixed-By: <runtime>`.** Distinct from `Conducted-By: <runtime>` so the handoff gate (`tests/parity/check-mirror-handoff.sh`) does not have to be taught about a new trailer key — it matches `Conducted-By:` explicitly (case-sensitive) and ignores anything else.
- **`/review-plan` test-gate is the marker invariant at acceptance, not premature `/conduct` readiness.** Plans are markdown; the analogue of "tests pass" is "after the user accepts or waives remaining findings, the contract section's hash is valid and `/conduct` preflight accepts it." Auto-applied prose edits before acceptance record `marker_pending` and do not publish a real marker.
- **Scope-forbid is structural, not heuristic.** Heading-hierarchy parse via `plan-scope-detect.sh` (skips fenced code blocks). A `prose_clarify` inside `## Requirements` is dropped regardless of how innocuous the wording change reads.
- **`auto_fix.scope` is typed per skill.** Deep-review uses `{file, function, block}` (informational, not a gate). Review-plan uses `<path>:<start-line>[-<end-line>]`; v1 applies only single-line spans, and the applier recomputes the enclosing heading via `plan-scope-detect.sh`.
- **Allowlist as SoT JSON, cited verbatim in SKILL.md.** Reduces drift surface from 6 files (4 SKILL.md + 1 applier + 1 parity check) to 1 (the JSON). `check-prompt-parity.sh` asserts byte-identity between JSON arrays and SKILL.md prose.
- **Malformed `auto_fix` blocks fail loudly.** Same principle as schema_version mismatch — a malformed structural marker is a lens-emission bug and surfacing it loudly is more useful than silently demoting findings to advisory.
- **Tests-must-pass is explicit, single-shot, and no retry.** The code applier does not guess a repo test command. The caller must pass `--test-cmd` or `AUTO_FIX_TEST_CMD`; retry would mask real regressions and complicate the rollback path.
- **Strict line-anchored apply for review-plan (v2 contract, Phase 5).** `scripts/apply-auto-fix-plan.sh` matches `auto_fix.before` only at the exact `auto_fix.scope` line. The v1 "find unique `before` match anywhere in the file" fallback is removed in Phase 5. Rationale: under v1, a typo in `scope` line could silently land an edit at a different line; making `scope` authoritative forces the lens to emit accurate line anchors and turns drift into a clean `rejected_drift` failure. Paired with triple path equality (`finding.file == auto_fix.scope.path == --plan`), the applier cannot edit a different file or a different line than the one under review. The `Phase 5: Codex review follow-up hardening` item 3 binding test enforces both invariants.
- **`unused_var` deletion blocks on any tracked reference, including tests (Phase 5 decision).** `scripts/apply-auto-fix-code.sh`'s re-verification scans ALL tracked files via `git grep -c <var>`; non-zero count → `status: rejected_revar`, no commit. Test-only reads do NOT permit deletion. Rationale: test files document behaviour; deleting a variable that tests read is a behaviour change masquerading as cleanup, exactly the failure mode v1 refuses to take. `unused_var-reject-test-file-read.jsonl` is the regression.

### Dependencies

- No new dependencies. Existing required tools stay bash, git, and awk. `jq` may be used when present for safer JSON parsing, but any jq-only path must either include an awk fallback or update README/setup requirements in the same phase.

### Integration Seams

| Seam | Writer (task) | Caller (task) | Contract |
|------|---------------|---------------|----------|
| `auto_fix` field on finding | lens prompt (Phase 1 SKILL.md edits) | reconciler (Phase 1), pre-render audit (Phase 1), appliers (Phases 2 & 3) | Field is optional. When present: `kind`, `before`, `after`, `scope` all required strings; `kind` from per-skill allowlist; `before`/`after` byte-precise; `scope` typed per skill (`{file, function, block}` for deep-review, `<path>:<start-line>[-<end-line>]` for review-plan). Malformed → reconciler rejects input. |
| Reconciler envelope v2 | `scripts/reconcile-findings.sh --skill ...` (Phase 1) | `scripts/audit-auto-fix-eligibility.sh` (Phase 1), `scripts/render-reconciled-report.sh` (Phase 1), `scripts/apply-auto-fix-{code,plan}.sh` (Phases 2 & 3) | `schema_version: 2`; presence of `auto_fix` on finding is only a proposal. The audit step adds `auto_fix_status`. Renderer displays `[AUTO-FIXABLE]` from that status; appliers consume only `would_apply` findings. |
| `auto-fix-allowlist.json` | `scripts/auto-fix-allowlist.json` (Phase 1) | `scripts/audit-auto-fix-eligibility.sh` (Phase 1), `scripts/lib/auto-fix-common.sh` (Phase 2), SKILL.md prose (Phases 1-3), `check-prompt-parity.sh` (Phase 1) | Per-skill enum; unknown `kind` → `status: rejected_kind` in manifest. SKILL.md cites the JSON arrays verbatim in both harnesses; parity check enforces byte-identity. |
| Manifest file | `scripts/apply-auto-fix-{code,plan}.sh` via `scripts/lib/auto-fix-common.sh` (Phases 2 & 3) | user (manual rollback) | JSON shape `[{kind, file, line, commit_sha, before_sha, status}]` written to `.deep-review/auto-fix-<unix>.json` or `.review-plan/auto-fix-<unix>.json`. `git revert <first_sha>..<last_sha>` undoes the batch. |
| Test command | caller / skill orchestration (Phase 2 SKILL.md wiring) | `scripts/apply-auto-fix-code.sh` (Phase 2) | Explicit `--test-cmd` or `AUTO_FIX_TEST_CMD`; missing command fails before edits. Invoked exactly once per applied code fix. |
| `Auto-Fixed-By:` trailer | `scripts/lib/auto-fix-common.sh` (Phases 2 & 3) | `tests/parity/check-mirror-handoff.sh` (Phase 2 test asserts ignore) | Commit trailer; distinct key from `Conducted-By:`. Handoff gate matches only case-sensitive `Conducted-By:` per existing line 51. |
| Plan scope detection | `scripts/plan-scope-detect.sh` (Phase 3; stack mode added in Phase 5) | `scripts/audit-auto-fix-eligibility.sh`, `scripts/apply-auto-fix-plan.sh` | Existing two-argument input `<plan-file> <line>` returns `<deepest-enclosing-heading>` for backward compatibility (byte-identical pre/post Phase 5, asserted by `test-plan-scope-detect-mode-isolation.sh`). Phase 5 adds `--stack <plan-file> <line>` whose output schema is: enclosing column-zero headings, outermost-first, one heading per line, terminating newline, no trailing blank; empty stdout (exit 0) for `unknown`. Auditor and applier use stack mode and reject if any heading in the stack matches the forbid list. Both modes skip fenced code blocks. |
| Review-plan applier binding | `scripts/apply-auto-fix-plan.sh --plan <reviewed-plan>` (Phase 5) | `.claude/skills/review-plan/SKILL.md`, `.codex/skills/review-plan/SKILL.md` | Applier requires triple path equality: `finding.file`, `auto_fix.scope` path, and the `--plan` argument must all resolve to the same in-repo file; mismatch → `status: rejected_path`. `auto_fix.before` is byte-matched only at the exact `auto_fix.scope` line; v1 unique-match-anywhere is removed (any drift → `status: rejected_drift`). SKILL.md invocations and the script signature land in one commit; binding regression in `tests/auto-fix/test-review-plan-binding.sh`. |
| Marker hash | per-harness `conduct/marker.py` algorithm and review-plan marker writer (Phase 3) | `scripts/apply-auto-fix-plan.sh` acceptance path; `/conduct` preflight; `tests/auto-fix/test-marker-refresh-post-phase5.sh` (Phase 5) | Hash is `git hash-object --stdin` over content above the real marker. Missing marker → Step 6 writes fresh marker per template; corrupt plan → exits `marker_failed`, applier rolls back batch edits. No real marker is written before user acceptance/waiver. Phase 5 adds a post-impl regression that recomputes the hash from this plan's contract section and asserts it equals the embedded marker hash, preventing Phase 5 completion against a stale marker. |

## Testing Notes

### Test Approach

- [x] Unit tests for `scripts/apply-auto-fix-code.sh` allowlist enforcement (each `kind` accept/reject case)
- [x] Adversarial fixtures for `/deep-review` smuggling: semantic-flip `mechanical_replace`, multi-line `mechanical_replace`, test-file-read `unused_var`
- [x] Unit test for `/deep-review` test-gate rollback
- [x] Unit test proving failed `/deep-review` auto-fix restores touched files and preserves `HEAD`
- [x] Unit test requiring explicit `/deep-review` test command before edits
- [x] Counter-wrapper test asserting test-gate runs the command exactly once
- [x] Trailer-collision tests: single trailer, both trailers, lowercase variant
- [x] Unit tests for `scripts/apply-auto-fix-plan.sh` allowlist enforcement
- [x] Adversarial fixtures for scope-forbid evasion: indented heading, horizontal rule, fenced pseudo-heading, two-digit phase
- [x] Marker-refresh edge cases: missing marker, corrupt plan, lens-emitted no-op
- [x] Codex conduct preflight regression after accepted review-plan auto-fix marker refresh
- [x] Schema v1↔v2 compat: v2 reads v1, v1 rejects v2, v2 rejects malformed `auto_fix`
- [x] Parity test for `auto_fix` schema block byte-identity across all four SKILL.md mirrors
- [x] Parity test for `auto-fix-allowlist.json` ↔ SKILL.md byte-identity
- [x] Manual smoke (`/deep-review`): synthetic `unused_import` finding → commit lands + manifest correct
- [x] Manual smoke (`/review-plan`): `symbol_rename` in prose vs in `## Requirements` → only prose one applies; marker refreshes

### Test Results

- [x] All existing reconciliation tests pass after schema bump
- [x] New auto-fix tests pass
- [x] All parity tests green at every phase boundary (not just end-of-Phase-4)
- [x] Manual smoke verified on both skills

### Edge Cases Tested

- [x] Lens emits `auto_fix` with `kind` outside allowlist → dropped to surfaced, manifest records `rejected_kind`
- [x] Lens emits `auto_fix` whose `before` does NOT match the file at the cited line → drift; dropped, manifest records `drift`
- [x] Test-gate failure during `/deep-review` apply → touched files restored from saved blobs, `HEAD` unchanged, manifest records `test_failed`, finding re-surfaced as advisory
- [x] Test-gate invoked exactly once per fix (no retry)
- [x] Adversarial: `mechanical_replace` with semantic-flipping single-line `before`/`after` (e.g., `if x:` → `if not x:`) → applier applies, test-gate catches (or doesn't — fixture documents the tradeoff)
- [x] Adversarial: multi-line `mechanical_replace` `before` → rejected pre-apply (`status: rejected_multiline`)
- [x] Adversarial: `unused_var` claimed unused, but test file reads it → applier's re-verification catches (`status: rejected_revar`)
- [x] `/review-plan` `prose_clarify` whose scope lands in `### Phase 2: foo` → dropped, manifest records `rejected_scope`
- [x] `/review-plan` scope-forbid evasion: indented heading, horizontal rule, fenced pseudo-heading, two-digit phase → all correctly resolved (forbidden heading still matched; fenced ignored)
- [x] `marker_refresh` on plan with no marker → writes fresh marker at template position
- [x] `marker_refresh` on corrupt plan → exits `marker_failed`, rolls back batch
- [x] `marker_refresh` lens emission + `prose_typo` lens emission in same batch → only end-of-batch refresh runs
- [x] v1-style JSONL findings passed to v2 reconciler → upgrade in-flight, no `auto_fix` applied
- [x] v2 envelope passed to v1 renderer → reject with clear error
- [x] v2 envelope with malformed `auto_fix` (missing `scope`, non-string `before`) → reconciler exits non-zero with clear error
- [x] Multiple fixes in a single batch, last one fails the test-gate → only the failing one rolls back; preceding successes are kept
- [x] Plan with a malformed heading (e.g., `##Heading` no space) → scope detector returns "unknown", applier drops the fix conservatively
- [x] Commit with both `Auto-Fixed-By:` and `Conducted-By:` trailers → handoff gate matches as `Conducted-By:`
- [x] Commit with lowercase `auto-fixed-by:` trailer → ignored by handoff gate (case-sensitive)

## Acceptance Criteria

1. `/deep-review --auto-fix=trivial` on a branch with a synthetic `unused_import` finding lands exactly one commit with subject `auto-fix(deep-review): unused_import at <file>:<line>` and trailer `Auto-Fixed-By: deep-review`; manifest at `.deep-review/auto-fix-<unix>.json` records `{status: applied, commit_sha, before_sha}`.
2. `/deep-review --auto-fix=trivial` with a finding whose `kind` is outside the allowlist (e.g., `refactor_method`, or `dead_branch` which is intentionally excluded from v1) leaves the working tree unchanged; manifest records `status: rejected_kind`; the finding still appears in the surfaced report.
3. `/deep-review --auto-fix=trivial` without `--test-cmd` / `AUTO_FIX_TEST_CMD` exits before edits with a clear error.
4. `/deep-review --auto-fix=trivial` whose applied fix breaks the supplied test command restores touched files from saved blobs, leaves `HEAD` unchanged, and re-surfaces the finding; manifest records `status: test_failed` with the test command output captured under `evidence`. The test command is invoked exactly once (no retry) per applied fix — verified by `test-deep-review-test-gate-single-invocation.sh`.
5. `/review-plan --auto-fix=trivial` with a `prose_typo` whose `auto_fix.scope` resolves to ordinary prose applies the edit, records `marker_pending`, and does not make `/conduct` eligible until the normal `yes` / `waive` marker write. After acceptance, the new marker hash matches `git hash-object --stdin` of the post-edit contract section and Codex conduct preflight passes.
6. `/review-plan --auto-fix=trivial` with a `symbol_rename` whose `auto_fix.scope` resolves to `## Requirements` is dropped; manifest records `status: rejected_scope`; finding re-surfaces as advisory.
7. `/review-plan --auto-fix=trivial` with a `marker_refresh` lens emission AND a `prose_typo` lens emission applies the typo, leaves marker refresh pending, and writes the real marker exactly once only after acceptance — verified by `marker_refresh-lens-emitted-noop.jsonl`.
8. `/review-plan --auto-fix=trivial` on an accepted plan with no existing marker writes a fresh marker; on a plan with corrupt UTF-8 exits `marker_failed` and rolls back any prose edits applied during the batch.
9. Without `--auto-fix=trivial`, both skills behave identically to today (no edits applied) but the rendered report shows `[AUTO-FIXABLE]` annotations next to every finding with precomputed `auto_fix_status: "would_apply"` (allowlist + scope-forbid gates run in dry-run; `rejected_kind` and `rejected_scope` findings are NOT annotated).
10. `bash scripts/check-prompt-parity.sh` is green at the end of every phase: the new `auto_fix` schema block is byte-identical across `.claude/skills/deep-review/SKILL.md`, `.codex/skills/deep-review/SKILL.md`, `.claude/skills/review-plan/SKILL.md`, `.codex/skills/review-plan/SKILL.md`; both pairs of `rubric.md` are byte-identical; `scripts/auto-fix-allowlist.json` arrays are cited verbatim in both `.claude` and `.codex` SKILL.md files; Codex-specific auto-fix wiring cannot drift from Claude-equivalent behavior.
11. `bash tests/parity/test-handoff-ignores-auto-fix.sh` is green: commits with `Auto-Fixed-By:` trailers (alone, with `Conducted-By:`, or lowercase) interact correctly with `check-mirror-handoff.sh` (ignored / matched / ignored respectively).
12. `bash tests/reconciliation/test-renderer.sh` is green against v2 envelopes; `bash tests/reconciliation/test-renderer-v1-rejects-v2.sh` is green (proves the snapshotted v1 renderer at `tests/reconciliation/fixtures/render-reconciled-report-v1.sh` exits non-zero with `schema mismatch: got 2, expected 1` for every v2 fixture); v1-style JSONL findings still parse (upgrade in-flight); v2 JSONL findings with malformed `auto_fix` are rejected with clear error.
13. Code reviewed and approved.
14. Tests passing.

### Manual Acceptance (not automatable)

- SKILL.md, rubric.md, `auto-fix-allowlist.json`, this plan's Final Results, and any relevant CHANGELOG entry are reviewed for accuracy and consistency.

<!-- reviewed: 2026-05-16 @ ea9b946f854a6dc75b5c84eaf5524d284a18b1f7 -->
<!-- /review-plan writes the marker line above. Everything below is the workspace: edits here do NOT invalidate the marker. -->

## Progress

- [x] Phase 1: Shared schema + reconciler + parity + pre-render audit (Claude-conducted)
- [x] Phase 2: /deep-review auto-fix applier + handoff regression test (Claude-conducted)
- [x] Phase 3: /review-plan auto-fix applier with scope-forbid + .gitignore (Claude-conducted)
- [x] Phase 4: Final repo-local parity and post-merge promotion instructions (Claude-conducted)
- [ ] Phase 5: Codex review follow-up hardening

## Findings

- (append findings here as work proceeds)

## Issues & Solutions

### Pre-implementation review (2026-05-15)

`/review-plan` returned 1 Critical, 8 Important, 11 Minor findings. All applied:

- **Critical** — original marker-helper extraction idea was later superseded by the 2026-05-16 Codex review: promoted conduct runtimes stay self-contained, and marker parity is proven by shared tests rather than by `marker.py` calling a repo-root helper.
- **Important** — applier split into `apply-auto-fix-code.sh` + `apply-auto-fix-plan.sh` + shared `scripts/lib/auto-fix-common.sh`. Schema bump kept at v1→v2 (user-confirmed: lockstep precedent over additive). Codex rubric edits paired with their producing phase (Phase 2 / Phase 3), eliminating the `check-prompt-parity.sh` boundary breakage. Allowlist adversarial fixtures (`mechanical_replace-reject-semantic-flip`, `-reject-multiline`, `unused_var-reject-test-file-read`) and scope-forbid evasion fixtures (indented heading, horizontal rule, fenced pseudo-heading, two-digit phase) enumerated explicitly. AC #6 backed by `marker_refresh-lens-emitted-noop.jsonl`.
- **Minor** — `auto_fix.scope` typed per skill (deep-review `{file, function, block}`; review-plan `<path>:<line>`). Allowlist enums extracted to `scripts/auto-fix-allowlist.json` SoT, cited verbatim in SKILL.md and asserted byte-identical by `check-prompt-parity.sh`. `[AUTO-FIXABLE]` annotation rules clarified (dry-run = full audit minus commit; `rejected_kind`/`rejected_scope` not annotated). `dead_branch` dropped from v1 allowlist (user-confirmed: lens self-tagging is the failure mode). Malformed `auto_fix` → reconciler rejects envelope (user-confirmed: fail loudly). Test-gate single-invocation backed by a counter wrapper. Trailer-collision test expanded to mixed + lowercase variants. Marker edge cases (missing, corrupt) covered. AC #13 moved to a Manual Acceptance subsection. Handoff regression test moved to Phase 2. `.gitignore` `.review-plan/` addition moved to Phase 3.

### Codex review-plan pass (2026-05-16)

`/review-plan` from Codex's perspective returned 5 Critical and 11 Important findings across architecture, sequencing, spec/testing, and codebase-claims lenses. Applied to the plan:

- **Critical** — `/review-plan` auto-fix no longer writes a real `/conduct` marker before `yes` / `waive`; failed `/deep-review` fixes restore touched blobs without `git revert HEAD`; the test command is explicit (`--test-cmd` / `AUTO_FIX_TEST_CMD`); `[AUTO-FIXABLE]` eligibility moved out of the pure renderer into `scripts/audit-auto-fix-eligibility.sh`; promoted conduct no longer depends on repo-root `scripts/lib/marker-hash.sh`.
- **Important** — Phase 1 now introduces allowlist/SKILL parity checks for both `.claude` and `.codex`; `scripts/reconcile-findings.sh` gets explicit `--skill deep-review|review-plan`; review-plan scope is span-aware and v1 applies only single-line spans; Phase 3 includes Codex and Claude conduct marker/preflight validation; feature-branch validation no longer runs destructive `promote-skills --yes`; schema compatibility now distinguishes JSONL findings/envelopes from `.deep-review/latest-*.json` run state.
- **Minor/factual** — refreshed stale parity/line-anchor claims (`check-prompt-parity.sh:60-91`, Codex marker lines), kept `jq` optional unless setup docs change, and expanded Codex review-plan documentation work beyond Step 6 so the overview/discussion/constraints surfaces cannot contradict auto-fix behavior.

### Codex post-Claude review (2026-05-16)

Codex reviewed Claude's completed branch state and found that Codex has not completed the plan yet. The original Phase 1-4 commits are Claude-owned (`Conducted-By: claude`) and the only conduct state for this plan is `state_author: "claude"`. The plan therefore now includes Phase 5 for Codex follow-up rather than treating Claude completion as Codex completion.

Issues that must be fixed before final completion:

- **Critical** — `/review-plan` scope-forbid is not hierarchy-aware; targets under forbidden parents can be allowed when the nearest child heading is not itself forbidden. This affects the shared plan applier/auditor and therefore Claude's implementation too.
- **Important** — `/review-plan` auto-fix path and line binding is too loose: the applier writes the file named in `auto_fix.scope`, while the auditor may validate a different `--plan`, and the applier searches globally for `before` instead of applying at the cited line. This affects Claude and Codex because the applier script is shared.
- **Important** — both Claude and Codex SKILL.md workflows need an explicit audit step between reconciliation and rendering; otherwise `[AUTO-FIXABLE]` can depend on an unstated manual step.
- **Important** — `/deep-review` code applier lacks the plan applier's clean-index guard and can sweep unrelated staged files into an auto-fix commit. This affects Claude and Codex because `scripts/apply-auto-fix-code.sh` is shared.
- **Important** — `/deep-review` kind-specific gates and adversarial tests are incomplete for `docstring_typo`, `import_sort`, `unused_import`, and the claimed `unused_var` test-file-read scenario.
- **Minor/factual** — update stale plan claims around renderer compatibility fixtures and line anchors, or add the missing fixtures/tests.

### Codex Phase 5 review-plan pass (2026-05-16)

`/review-plan` from Codex's perspective found that Phase 5 targets the right defects but needed stronger sequencing and test contracts. Applied to the plan:

- **Critical** — Codex `/review-plan` and marker refresh must happen before Codex `/conduct` can start Phase 5, because Phase 5 changed the immutable contract above the marker. Phase 5 also touches both harness mirrors, so Claude `/review-plan` remains a required final gate before completion.
- **Important** — Phase 5 now defines the concrete `scripts/apply-auto-fix-plan.sh --plan <reviewed-plan> <annotated-envelope.json>` API, `plan-scope-detect.sh --stack`, targeted path/line binding tests, audit-before-render SKILL.md contract tests, and a clean-index guard regression for the code applier.
- **Minor/factual** — stale `ENVELOPE_SCHEMA_VERSION` line anchors and the missing `auto-fix-v1-rejects-v2.jsonl` claim were corrected to match the current implementation/testing contract.

### Claude Phase 5 second review-plan pass (2026-05-16)

`/review-plan` re-run on the updated Phase 5 contract returned 6 Critical, 9 Important, 6 Minor findings. All applied:

- **Critical (architecture)** — `--plan` binding is now explicitly documented as a v2 contract change (Architecture Decision: "Strict line-anchored apply for review-plan") rather than disguised as hardening. Lens emission must produce accurate `auto_fix.scope` line; applier removes the v1 unique-match-anywhere-in-file fallback; drift becomes `rejected_drift`.
- **Critical (sequencing)** — Phase 5 now has an explicit Preconditions subsection (P1 fresh accepted marker, P2 fresh Codex conduct state file) separated from work items, with `feature/review-auto-fix-tier` commit order spelled out: accepted-marker commit lands before any Phase 5 impl commit.
- **Critical (sequencing)** — orchestration audit step + four SKILL.md edits + parity test land in one atomic commit; audit invocation lines wrapped inside the byte-identical region already enforced by `check-prompt-parity.sh` so drift fails the parity gate, not the substring gate.
- **Critical (spec/testing)** — kind-specific gates each get named accept/reject fixtures (`docstring_typo-{accept,reject-code-edit}.jsonl`, `import_sort-{accept,reject-symbol-change}.jsonl`, `unused_import-{accept,reject-still-referenced}.jsonl`) enumerated in the Phase 5 Test files list. New `test-deep-review-kind-gates.sh` drives them.
- **Critical (spec/testing)** — `unused_var` test-file-read contract is now decided (Architecture Decision): the applier blocks deletion if `git grep -c <var>` finds any reference, tests included. `unused_var-reject-test-file-read.jsonl` is the asserting regression.
- **Critical (spec/testing)** — v1-renderer compatibility now backed by a snapshotted fixture at `tests/reconciliation/fixtures/render-reconciled-report-v1.sh` and a dedicated test `test-renderer-v1-rejects-v2.sh`; AC #12 wording references the new test.
- **Important** — `plan-scope-detect.sh --stack` output schema specified in Integration Seams and in Phase 5 item 1 (outermost-first, one heading per line, trailing newline, no trailing blank, empty stdout on `unknown`). `test-plan-scope-detect-mode-isolation.sh` proves two-arg mode is byte-identical pre/post change.
- **Important** — Phase 5 work items are numbered 1-10 with explicit atomic-commit groupings; same-file conflicts between items 2/4 (apply-auto-fix-plan + SKILL.md mirrors) are resolved by bundling into a single commit per item rather than splitting Phase 5 into 5a/5b.
- **Important** — `tests/parity/test-auto-fix-orchestration-contract.sh` requirement now enumerates the exact expected invocation strings (`--skill deep-review` for deep-review; `--skill review-plan --plan <reviewed-plan>` for review-plan) and asserts the audit appears textually before the render step.
- **Important** — new Integration Seams row "Review-plan applier binding" documents the triple path equality and strict-line byte-match invariants; cited-line drift case is explicitly distinguished from existing Phase 2 `before`-not-found-anywhere drift in `test-review-plan-binding.sh`.
- **Important** — new `test-marker-refresh-post-phase5.sh` recomputes the contract hash and asserts the embedded marker matches; phase completion cannot be marked done against a stale marker.
- **Minor** — `test-deep-review-clean-index-guard.sh` "mixed dirty state" now spells out the composition (staged A + unstaged B + untracked C with per-path preservation assertions). New fixture name `plan-scope-evasion-parent-heading.md` added to Phase 5 Test files list. Phase 5 item 10 defines the post-impl review ownership and Phase 5 completion criteria explicitly.

## Final Results

### Post-merge promotion

After this PR is merged into `main` and final approval is given, run the
following from a clean `main` checkout to promote the updated `deep-review`
and `review-plan` skills into the user-global skill tree:

```
MANAGED_SKILLS="deep-review review-plan" scripts/promote-skills.sh --yes && just check-sync
```

`scripts/promote-skills.sh` is intentionally NOT run as part of any
feature-branch validation step — it mutates the user-global
`~/.claude/skills/` / `~/.codex/skills/` trees and must only run after
merge with explicit approval. `just check-sync` confirms the promoted
copies match the repo at HEAD.

### Phase completion

- Phase 1 (775fe1a): v2 schema, allowlist JSON, audit script, reconciler + renderer wiring.
- Phase 2 (1a99c83): `scripts/apply-auto-fix-code.sh`, `scripts/lib/auto-fix-common.sh`, deep-review SKILL.md + rubric.md wiring, handoff regression test.
- Phase 3 (1b49fe8): `scripts/apply-auto-fix-plan.sh`, `scripts/plan-scope-detect.sh`, review-plan SKILL.md + rubric.md wiring, `.review-plan/` gitignored.
- Phase 4: Verified `scripts/check-prompt-parity.sh` already covers the full required surface (rubric.md, `*-prompt.md`, GENERIC FINDING SCHEMA AND MERGE block across all four SKILL.md mirrors, `scripts/auto-fix-allowlist.json` ↔ SKILL.md byte-identity citations, and `scripts/reconcile-findings.sh` existence/executable bit). No additional parity extension required; the Phase 1 extension stands.
- Phase 5: Pending Codex follow-up hardening from the post-Claude review. Do not run post-merge promotion until this phase is complete and reviewed.
