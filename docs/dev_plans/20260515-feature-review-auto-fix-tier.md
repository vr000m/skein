# Task: Trivial-tier auto-fix for /deep-review and /review-plan

**Status**: Not Started
**Assigned to**: tbd
**Priority**: Medium
**Branch**: feature/review-auto-fix-tier
**Created**: 2026-05-15
**Last revised**: 2026-05-15 (post-/review-plan: applied all 20 unique findings; see Issues & Solutions § Pre-implementation review)
**Completed**: —

## Objective

Add an opt-in `--auto-fix=trivial` tier to `/deep-review` (code review) and `/review-plan` (dev-plan review) that applies a hard-coded allowlist of mechanical, semantics-preserving fixes — leaving everything else advisory. The trigger is a structural `auto_fix` block emitted by the lens; LLM self-classification of "uncontroversial" is explicitly NOT a trigger.

## Context

Two `/review` cycles on PR #22 hit the same pattern: a lens flags a fix that looks trivial (e.g., `lstrip().startswith("lint:")` → column-zero `startswith`), the human reviewer agrees, and we hand-apply the edit. Repeating that loop for every plan/PR is the friction point. But naive auto-application risks compounding misreadings — twice on PR #22 the "obvious" finding turned out to require human context (codex's intentional `schema_version` design; the `_safe_read_state_text` callers).

The recommendation that came out of that review (see horizon note for self-healing review pipelines): narrow, structural allowlist rather than LLM-driven "uncontroversial" classification. The lens must produce a machine-checkable `auto_fix: {kind, before, after, scope}` block whose `kind` is one of a fixed set; the applier rejects anything outside that set or anything whose scope touches a load-bearing section.

The user added an extra constraint for `/review-plan`: plan auto-fixes are limited to **code clarifications or trivial design** — never Requirements, Acceptance Criteria, Files-to-Modify, phase boundaries, schema decisions, or cross-runtime contracts. Those remain advisory, surfaced with `accept / reject / discuss` choices regardless of lens confidence.

Both skills currently produce JSON-Lines findings (`{lens, severity, category, file, line, summary, evidence, suggestion}`) consumed by `scripts/reconcile-findings.sh` with `ENVELOPE_SCHEMA_VERSION=1`; the renderer at `scripts/render-reconciled-report.sh` enforces `EXPECTED_SCHEMA_VERSION=1` in lockstep. Adding `auto_fix` to the finding shape forces a schema bump (v1 → v2) handled by both scripts. The bump is in lockstep per the existing GENERIC FINDING SCHEMA block precedent — the project's policy is "explicit version on shape change," not "additive within version."

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

- Bump `ENVELOPE_SCHEMA_VERSION` in `scripts/reconcile-findings.sh:77` from `1` to `2`; bump `EXPECTED_SCHEMA_VERSION` in `scripts/render-reconciled-report.sh:43` from `1` to `2` in the same commit (lockstep rule per existing GENERIC block doc).
- Extend the finding JSONL shape with an optional `auto_fix: {kind: str, before: str, after: str, scope: str}` field. v2 reconciler passes it through unchanged when well-formed; rejects input when present-but-malformed (missing key, non-string value).
- Add `--skill deep-review|review-plan` to `scripts/reconcile-findings.sh`; validation of `auto_fix.scope` and allowlist compatibility keys off this explicit context.
- v2 reconciler reading v1-style JSONL findings MUST upgrade them in-flight (treat `auto_fix` as absent → finding surfaced, not applied). Fixture `auto-fix-v2-reads-v1-jsonl.jsonl`.
- v1 renderer reading a v2 envelope MUST exit non-zero with `schema mismatch: got 2, expected 1`. Fixture `auto-fix-v1-rejects-v2.jsonl`.
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

## Technical Specifications

### Files to Modify

- `scripts/reconcile-findings.sh:77` — bump `ENVELOPE_SCHEMA_VERSION` 1→2; add `--skill deep-review|review-plan`; pass-through well-formed `auto_fix` on findings; reject malformed `auto_fix` (missing key, non-string value, malformed per-skill scope).
- `scripts/render-reconciled-report.sh:43` — bump `EXPECTED_SCHEMA_VERSION` 1→2; display `[AUTO-FIXABLE]` only for findings already annotated with `auto_fix_status: "would_apply"`. Keep rendering pure envelope-to-markdown.
- `scripts/audit-auto-fix-eligibility.sh` — pre-render and pre-apply eligibility audit. Computes `auto_fix_status` from the allowlist, drift checks, and review-plan scope-forbid checks before the renderer or appliers run.
- `.claude/skills/deep-review/SKILL.md` — document `--auto-fix=trivial` flag, the `auto_fix` block in the GENERIC FINDING SCHEMA section, the per-skill `scope` typing, the allowlist (cite `auto-fix-allowlist.json` deep-review array verbatim), and the rejection rules. Mirror block is byte-identical with `.codex/`.
- `.claude/skills/deep-review/rubric.md` — add lens-emission criterion.
- `.claude/skills/review-plan/SKILL.md` — same shape; cite `auto-fix-allowlist.json` review-plan array verbatim; document scope-forbid invariant and marker edge cases.
- `.claude/skills/review-plan/rubric.md` — add lens-emission criterion.
- `.codex/skills/deep-review/SKILL.md`, `.codex/skills/deep-review/rubric.md`, `.codex/skills/review-plan/SKILL.md`, `.codex/skills/review-plan/rubric.md` — byte-identical mirrors, edited in the same phase commit as their `.claude` counterparts.
- `.claude/skills/conduct/marker.py`, `.codex/skills/conduct/marker.py` — no repo-root helper dependency. Keep the promoted runtime hash implementation self-contained; add tests proving review-plan marker writes still match both harnesses.
- `scripts/check-prompt-parity.sh` — extend in Phase 1 to cover allowlist JSON ↔ SKILL.md byte-identity and Codex-specific auto-fix wiring surfaces.
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
| Plan scope detection | `scripts/plan-scope-detect.sh` (Phase 3) | `scripts/apply-auto-fix-plan.sh` (Phase 3) | Input `<plan-file> <line>`, output `<deepest-enclosing-heading>`. Caller drops fix if heading matches the forbid list. Skips fenced code blocks. |
| Marker hash | per-harness `conduct/marker.py` algorithm and review-plan marker writer (Phase 3) | `scripts/apply-auto-fix-plan.sh` acceptance path; `/conduct` preflight | Hash is `git hash-object --stdin` over content above the real marker. Missing marker → Step 6 writes fresh marker per template; corrupt plan → exits `marker_failed`, applier rolls back batch edits. No real marker is written before user acceptance/waiver. |

## Testing Notes

### Test Approach

- [ ] Unit tests for `scripts/apply-auto-fix-code.sh` allowlist enforcement (each `kind` accept/reject case)
- [ ] Adversarial fixtures for `/deep-review` smuggling: semantic-flip `mechanical_replace`, multi-line `mechanical_replace`, test-file-read `unused_var`
- [ ] Unit test for `/deep-review` test-gate rollback
- [ ] Unit test proving failed `/deep-review` auto-fix restores touched files and preserves `HEAD`
- [ ] Unit test requiring explicit `/deep-review` test command before edits
- [ ] Counter-wrapper test asserting test-gate runs the command exactly once
- [ ] Trailer-collision tests: single trailer, both trailers, lowercase variant
- [ ] Unit tests for `scripts/apply-auto-fix-plan.sh` allowlist enforcement
- [ ] Adversarial fixtures for scope-forbid evasion: indented heading, horizontal rule, fenced pseudo-heading, two-digit phase
- [ ] Marker-refresh edge cases: missing marker, corrupt plan, lens-emitted no-op
- [ ] Codex conduct preflight regression after accepted review-plan auto-fix marker refresh
- [ ] Schema v1↔v2 compat: v2 reads v1, v1 rejects v2, v2 rejects malformed `auto_fix`
- [ ] Parity test for `auto_fix` schema block byte-identity across all four SKILL.md mirrors
- [ ] Parity test for `auto-fix-allowlist.json` ↔ SKILL.md byte-identity
- [ ] Manual smoke (`/deep-review`): synthetic `unused_import` finding → commit lands + manifest correct
- [ ] Manual smoke (`/review-plan`): `symbol_rename` in prose vs in `## Requirements` → only prose one applies; marker refreshes

### Test Results

- [ ] All existing reconciliation tests pass after schema bump
- [ ] New auto-fix tests pass
- [ ] All parity tests green at every phase boundary (not just end-of-Phase-4)
- [ ] Manual smoke verified on both skills

### Edge Cases Tested

- [ ] Lens emits `auto_fix` with `kind` outside allowlist → dropped to surfaced, manifest records `rejected_kind`
- [ ] Lens emits `auto_fix` whose `before` does NOT match the file at the cited line → drift; dropped, manifest records `drift`
- [ ] Test-gate failure during `/deep-review` apply → touched files restored from saved blobs, `HEAD` unchanged, manifest records `test_failed`, finding re-surfaced as advisory
- [ ] Test-gate invoked exactly once per fix (no retry)
- [ ] Adversarial: `mechanical_replace` with semantic-flipping single-line `before`/`after` (e.g., `if x:` → `if not x:`) → applier applies, test-gate catches (or doesn't — fixture documents the tradeoff)
- [ ] Adversarial: multi-line `mechanical_replace` `before` → rejected pre-apply (`status: rejected_multiline`)
- [ ] Adversarial: `unused_var` claimed unused, but test file reads it → applier's re-verification catches (`status: rejected_revar`)
- [ ] `/review-plan` `prose_clarify` whose scope lands in `### Phase 2: foo` → dropped, manifest records `rejected_scope`
- [ ] `/review-plan` scope-forbid evasion: indented heading, horizontal rule, fenced pseudo-heading, two-digit phase → all correctly resolved (forbidden heading still matched; fenced ignored)
- [ ] `marker_refresh` on plan with no marker → writes fresh marker at template position
- [ ] `marker_refresh` on corrupt plan → exits `marker_failed`, rolls back batch
- [ ] `marker_refresh` lens emission + `prose_typo` lens emission in same batch → only end-of-batch refresh runs
- [ ] v1-style JSONL findings passed to v2 reconciler → upgrade in-flight, no `auto_fix` applied
- [ ] v2 envelope passed to v1 renderer → reject with clear error
- [ ] v2 envelope with malformed `auto_fix` (missing `scope`, non-string `before`) → reconciler exits non-zero with clear error
- [ ] Multiple fixes in a single batch, last one fails the test-gate → only the failing one rolls back; preceding successes are kept
- [ ] Plan with a malformed heading (e.g., `##Heading` no space) → scope detector returns "unknown", applier drops the fix conservatively
- [ ] Commit with both `Auto-Fixed-By:` and `Conducted-By:` trailers → handoff gate matches as `Conducted-By:`
- [ ] Commit with lowercase `auto-fixed-by:` trailer → ignored by handoff gate (case-sensitive)

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
12. `bash tests/reconciliation/test-renderer.sh` is green against v2 envelopes; stale v1 renderers reject v2 envelopes with a clear error; v1-style JSONL findings still parse (upgrade in-flight); v2 JSONL findings with malformed `auto_fix` are rejected with clear error.
13. Code reviewed and approved.
14. Tests passing.

### Manual Acceptance (not automatable)

- SKILL.md, rubric.md, `auto-fix-allowlist.json`, this plan's Final Results, and any relevant CHANGELOG entry are reviewed for accuracy and consistency.

<!-- reviewed: 2026-05-16 @ 47df9ae3f25e0da1229f45faac6fef45bd92a541 -->
<!-- /review-plan writes the marker line above. Everything below is the workspace: edits here do NOT invalidate the marker. -->

## Progress

- [ ] Phase 1: Shared schema + reconciler + parity + pre-render audit
- [ ] Phase 2: /deep-review auto-fix applier + handoff regression test
- [ ] Phase 3: /review-plan auto-fix applier with scope-forbid + .gitignore
- [ ] Phase 4: Final repo-local parity and post-merge promotion instructions

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

## Final Results

(fill on completion)
