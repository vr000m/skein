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
- **Allowlists are hard-coded** and live in `scripts/auto-fix-allowlist.json` (single source of truth), sourced by the appliers and asserted byte-identical against the SKILL.md documentation by `check-prompt-parity.sh`. Lens may *propose* `kind`; applier *gates* `kind`. Unknown `kind` → drop to surfaced, never applied.
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
  - `marker_refresh` — rewrite the `<!-- reviewed: YYYY-MM-DD @ <hash> -->` marker after applied edits.
  - `prose_typo` — single-line typo/grammar correction in plan prose.
  - `prose_clarify` — single-paragraph wording clarification.
- **Scope-forbid list (NEVER auto-applied) for `/review-plan`:** any edit whose scope resolves under `## Requirements`, `## Acceptance Criteria`, `### Files to Modify`, `### New Files to Create`, `### Architecture Decisions`, `### Integration Seams`, or any `### Phase N:` heading. Scope detection is structural (heading hierarchy), not heuristic. A `prose_clarify` whose `auto_fix.scope` lands inside one of those sections is dropped to surfaced.
- **`auto_fix.scope` field is typed per skill.** `/deep-review`: `scope ∈ {file, function, block}` — informs the applier's drift-check window but is not used for gating. `/review-plan`: `scope = "<path>:<line>"` (the same `path:line` already on the finding; redundant by construction, kept for cross-skill schema uniformity). Reconciler validates the per-skill type; malformed → see envelope rejection rule below.
- **Malformed `auto_fix` block → reject envelope.** If a v2 envelope carries an `auto_fix` block missing required keys (`kind`, `before`, `after`, `scope`) or with non-string values, the v2 reconciler exits non-zero with a structural error (same principle as `schema_version` mismatch). Lens-emission bugs surface loudly, not silently demote to advisory.
- **Tests-must-pass gate** (`/deep-review` only): after each applied fix, run the repo's default test command exactly once (no retry). Failure → `git revert` the auto-fix commit and re-surface the finding as advisory; manifest records `status: test_failed` with the test output truncated to the last 2000 bytes. Flakes are the user's problem; gate is single-shot to avoid masking a real regression behind a retry loop.
- **Marker invariant** (`/review-plan` only): after any auto-applied edit to plan prose, refresh the `<!-- reviewed: YYYY-MM-DD @ <hash> -->` marker so the contract section's hash remains valid. This is itself a `marker_refresh` auto-fix, always applied last in the batch. Lens-emitted `marker_refresh` blocks during the batch are no-ops (would be overwritten by the end-of-batch refresh anyway).
- **`marker_refresh` edge cases.** If the plan has no marker line at all (fresh plan), the applier writes a new marker matching `dev-plan/template.md` placement (after Acceptance Criteria) rather than raising. If the marker hash computation itself fails (corrupt plan, malformed UTF-8), the applier exits with `status: marker_failed`, rolls back any prose edits applied during the batch, and re-surfaces all findings as advisory.
- **One commit per fix.** Each applied auto-fix lands as its own commit with subject `auto-fix(<skill>): <kind> at <file>:<line>` and trailer `Auto-Fixed-By: <skill>`. Multiple commits in a single run are sequential, not squashed.
- **Rollback manifest.** Each run writes `.deep-review/auto-fix-<unix>.json` (for `/deep-review`) or `.review-plan/auto-fix-<unix>.json` (for `/review-plan`) listing `{kind, file, line, commit_sha, before_sha, status}` per applied fix. `git revert <range>` undoes the batch; the manifest documents the range.
- **Dry-run by default when surfacing.** Without `--auto-fix=trivial`, the reconciler renders an `[AUTO-FIXABLE]` annotation next to each finding **that would pass the allowlist AND scope-forbid gates if `--auto-fix=trivial` were set** — i.e., the dry-run runs the full applier audit minus the commit step. Findings carrying `auto_fix` blocks that fail allowlist (`rejected_kind`) or scope-forbid (`rejected_scope`) are NOT annotated, so the annotation accurately previews apply-tier behaviour.
- **Cross-runtime parity.** Allowlist source-of-truth (`scripts/auto-fix-allowlist.json`), applier logic (`scripts/apply-auto-fix-code.sh`, `scripts/apply-auto-fix-plan.sh`, `scripts/lib/auto-fix-common.sh`, `scripts/lib/marker-hash.sh`), schema (GENERIC FINDING SCHEMA block in all four SKILL.md mirrors), and trailer convention must be byte-identical between `.claude/skills/<skill>/` and `.codex/skills/<skill>/`. The existing `scripts/check-prompt-parity.sh` already covers `rubric.md` byte-identity per `scripts/check-prompt-parity.sh:60-89`; Phase 4 extends it to also cover the new schema fragment and the allowlist JSON.

## Review Focus

- **Allowlist tightness.** A finding leaking out as "applicable" when it shouldn't be is the failure mode that erodes trust in the whole tier. Reviewers should pressure-test each `kind` against realistic adversarial findings: can `mechanical_replace` be smuggled past as a `before`/`after` that quietly changes behaviour (e.g., `if x:` → `if not x:` is a valid single-line literal pair)? Can `unused_var` slip through when a test file reads the variable? The `mechanical_replace-reject-semantic-flip.jsonl` and `unused_var-reject-test-file-read.jsonl` fixtures must exercise these.
- **Scope-forbid detection for `/review-plan`.** Structural heading-hierarchy parse must not be defeatable by an indented sub-heading, a horizontal rule between a forbidden heading and the target line, a fenced code block masquerading as a heading, or a two-digit phase number. Verify with the malformed/unusual plan fixtures in Phase 3.
- **Schema bump compatibility.** v1 reconciler envelopes still exist in old `.deep-review/latest-claude.json` files. v2 reconciler must read v1 envelopes without auto-fix info (drop to surfaced) and v1 renderer must reject v2 envelopes loudly rather than silently miss `auto_fix` data. Malformed v2 envelopes (e.g., `auto_fix` with missing `scope`) must be rejected with a clear error — see the envelope-rejection rule above.
- **Test-gate correctness.** A single-shot, no-retry test command is the contract; the gate must not silently retry on flake. The `test-deep-review-test-gate-single-invocation.sh` fixture asserts the gate invokes the command exactly once via a counter wrapper.
- **Trailer convention.** `Auto-Fixed-By: <skill>` must NOT collide with `Conducted-By: <runtime>` parsing in `tests/parity/check-mirror-handoff.sh:51`. The handoff gate matches `Conducted-By:` explicitly (case-sensitive) and ignores anything else. The Phase 2 regression test covers (a) single `Auto-Fixed-By:` trailer, (b) both trailers on one commit, (c) lowercase `auto-fixed-by:`.
- **Mirror parity discipline.** Per repo precedent (CLAUDE-side authority on shared SKILL prose), drift between `.claude` and `.codex` lens prompts has bitten before. The new `auto_fix` block must be in the byte-identical GENERIC FINDING SCHEMA region, not the lens-specific prose. `rubric.md` edits in Phase 2 and Phase 3 pair `.claude` + `.codex` in the same phase commit so `check-prompt-parity.sh` stays green at every phase boundary.
- **Marker failure mode.** `scripts/lib/marker-hash.sh` must handle: no marker present (write fresh marker, do not raise), corrupt UTF-8 (exit `marker_failed`, roll back batch). The `marker_refresh-missing-marker.jsonl` and `marker_refresh-corrupt-plan.jsonl` fixtures cover these.

## Implementation Checklist

The Implementation Checklist is part of the **immutable contract** above the review marker.

### Phase 1: Shared schema + reconciler + renderer

**Impl files:** `scripts/reconcile-findings.sh, scripts/render-reconciled-report.sh, scripts/auto-fix-allowlist.json, .claude/skills/deep-review/SKILL.md, .claude/skills/review-plan/SKILL.md, .codex/skills/deep-review/SKILL.md, .codex/skills/review-plan/SKILL.md`
**Test files:** `tests/reconciliation/test-renderer.sh, tests/reconciliation/test-reconciler-unit.sh, tests/reconciliation/run-fixtures.sh, tests/reconciliation/fixtures/auto-fix-v2-*.jsonl, tests/reconciliation/fixtures/auto-fix-v2-malformed-*.jsonl`
**Test command:** `just reconciliation-tests`

- Bump `ENVELOPE_SCHEMA_VERSION` in `scripts/reconcile-findings.sh:77` from `1` to `2`; bump `EXPECTED_SCHEMA_VERSION` in `scripts/render-reconciled-report.sh:43` from `1` to `2` in the same commit (lockstep rule per existing GENERIC block doc).
- Extend the finding JSON shape with an optional `auto_fix: {kind: str, before: str, after: str, scope: str}` field. v2 reconciler passes it through unchanged when well-formed; rejects the envelope when present-but-malformed (missing key, non-string value).
- v2 reconciler reading a v1 envelope MUST upgrade it in-flight (treat `auto_fix` as absent → finding surfaced, not applied). Fixture `auto-fix-v2-reads-v1-envelope.jsonl`.
- v1 renderer reading a v2 envelope MUST exit non-zero with `schema mismatch: got 2, expected 1`. Fixture `auto-fix-v1-rejects-v2.jsonl`.
- v2 reconciler reading a v2 envelope with malformed `auto_fix` MUST exit non-zero with `auto_fix block malformed: <reason>`. Fixtures: `auto-fix-v2-malformed-missing-scope.jsonl`, `auto-fix-v2-malformed-nonstring-before.jsonl`.
- Create `scripts/auto-fix-allowlist.json` as the single source of truth for allowlist enums. Shape: `{"deep-review": [...kinds...], "review-plan": [...kinds...]}`. Used by both appliers; cited verbatim in both SKILL.md docs so `check-prompt-parity.sh` can assert byte-identity.
- Update both skills' GENERIC FINDING SCHEMA AND MERGE blocks (the byte-identical block enforced by `check-prompt-parity.sh:237-274`) to document the new field, the per-skill `scope` typing, and the malformed-rejection rule. Mirror to both `.claude` and `.codex` copies; verify with `bash scripts/check-prompt-parity.sh`.
- Add `[AUTO-FIXABLE]` annotation prefix in the renderer's output for findings carrying a valid `auto_fix` block AND passing the allowlist + scope-forbid gates (dry-run = full audit minus commit). Annotation is for human audit only; the applier reads the reconciler envelope directly, not the rendered output.

### Phase 2: `/deep-review` auto-fix applier + handoff regression test

**Impl files:** `scripts/apply-auto-fix-code.sh, scripts/lib/auto-fix-common.sh, .claude/skills/deep-review/SKILL.md, .claude/skills/deep-review/rubric.md, .codex/skills/deep-review/SKILL.md, .codex/skills/deep-review/rubric.md`
**Test files:** `tests/auto-fix/test-deep-review-allowlist.sh, tests/auto-fix/test-deep-review-test-gate.sh, tests/auto-fix/test-deep-review-test-gate-single-invocation.sh, tests/parity/test-handoff-ignores-auto-fix.sh, tests/auto-fix/fixtures/<kind>-{accept,reject,reject-multiline,reject-semantic-flip,reject-test-file-read}.jsonl`
**Test command:** `bash tests/auto-fix/test-deep-review-allowlist.sh && bash tests/auto-fix/test-deep-review-test-gate.sh && bash tests/auto-fix/test-deep-review-test-gate-single-invocation.sh && bash tests/parity/test-handoff-ignores-auto-fix.sh`
**Validation cmd:** `cd /tmp && bash -c 'mkdir -p auto-fix-smoke && cd auto-fix-smoke && git init -q && git commit --allow-empty -m init -q && echo "from os import path" > a.py && git add a.py && git commit -q -m a && printf "{\"schema_version\":2,\"findings\":[{\"lens\":\"logic\",\"severity\":\"Minor\",\"category\":\"unused\",\"file\":\"a.py\",\"line\":1,\"summary\":\"unused import\",\"auto_fix\":{\"kind\":\"unused_import\",\"before\":\"from os import path\\n\",\"after\":\"\",\"scope\":\"file\"}}]}" > findings.json && bash $REPO/scripts/apply-auto-fix-code.sh findings.json'`

- Create `scripts/lib/auto-fix-common.sh`: shared bash helpers (manifest writer, drift-check `before`-vs-file byte-match, allowlist loader from `auto-fix-allowlist.json` via jq, commit + trailer composition). Sourced by both appliers (Phase 2 and Phase 3 entry scripts).
- Create `scripts/apply-auto-fix-code.sh`: the `/deep-review` entry point. Takes `<findings-envelope.json>`. Reads `schema_version` (must be 2). Iterates findings carrying `auto_fix`. For each: load allowlist from `scripts/auto-fix-allowlist.json` (key `deep-review`); reject unknown `kind` (`status: rejected_kind`); assert `before` matches `file:line` byte-for-byte (drift → `status: drift`); for `unused_var`, re-verify via `git grep -c "<var>"` excluding test files (mismatch → `status: rejected_revar`); for `mechanical_replace`, reject if `before` contains `\n` (multi-line → `status: rejected_multiline`); rewrite `before` → `after`; stage the file; run the test command once (no retry); on pass → commit with subject `auto-fix(deep-review): <kind> at <file>:<line>` and `--trailer "Auto-Fixed-By: deep-review"`; on fail → `git revert HEAD --no-edit` and append `status: test_failed`.
- Adversarial fixtures (Phase 2): `mechanical_replace-reject-semantic-flip.jsonl` (`if x:` → `if not x:`; documents the smuggling tradeoff: applier byte-matches but doesn't semantic-check, so this fixture asserts the applier *applies* and the test-gate catches), `mechanical_replace-reject-multiline.jsonl` (multi-line `before` → rejected pre-apply), `unused_var-reject-test-file-read.jsonl` (test file reads the var → applier's re-verification catches before apply), `docstring_typo-{accept,reject-outside-docstring}.jsonl`, `unused_import-{accept,reject-still-referenced}.jsonl`, `import_sort-{accept,reject-semantic-change}.jsonl`.
- `tests/auto-fix/test-deep-review-test-gate-single-invocation.sh`: wraps the test command in a counter-incrementing shim; assert counter == 1 per applied fix. Closes Review Focus "single-shot, no retry" item.
- `tests/parity/test-handoff-ignores-auto-fix.sh`: covers (a) commit with only `Auto-Fixed-By:` trailer → ignored by handoff gate, (b) commit with both `Auto-Fixed-By:` + `Conducted-By:` trailers → matched as `Conducted-By:`, (c) commit with lowercase `auto-fixed-by:` → ignored (handoff is case-sensitive). Lives in Phase 2 because Phase 2 introduces the trailer.
- Wire `--auto-fix=trivial` into `/deep-review` SKILL.md Step 5 (after reconciliation, before user-facing report). Mirror the wiring + the rubric edit in `.codex/skills/deep-review/SKILL.md` and `.codex/skills/deep-review/rubric.md` in the same phase commit so `scripts/check-prompt-parity.sh` (which enforces `rubric.md` byte-identity per lines 60-89) stays green at the Phase 2 boundary.
- Update `.claude/skills/deep-review/rubric.md` AND `.codex/skills/deep-review/rubric.md` to add a criterion: "lens emitted `auto_fix` block whenever a finding matches the allowlist shape; absent `auto_fix` on a clearly mechanical finding is a quality issue."

### Phase 3: `/review-plan` auto-fix applier with scope-forbid + .gitignore

**Impl files:** `scripts/apply-auto-fix-plan.sh, scripts/plan-scope-detect.sh, scripts/lib/marker-hash.sh, .claude/skills/review-plan/SKILL.md, .claude/skills/review-plan/rubric.md, .codex/skills/review-plan/SKILL.md, .codex/skills/review-plan/rubric.md, .gitignore`
**Test files:** `tests/auto-fix/test-review-plan-allowlist.sh, tests/auto-fix/test-review-plan-scope-forbid.sh, tests/auto-fix/test-review-plan-marker-refresh.sh, tests/auto-fix/test-review-plan-marker-edge-cases.sh, tests/auto-fix/fixtures/plan-<kind>-{accept,reject}.md, tests/auto-fix/fixtures/plan-<kind>-{accept,reject}.jsonl, tests/auto-fix/fixtures/plan-scope-evasion-{indented,horizontal-rule,fenced,two-digit-phase}.md, tests/auto-fix/fixtures/marker_refresh-{missing-marker,corrupt-plan,lens-emitted-noop}.jsonl`
**Test command:** `bash tests/auto-fix/test-review-plan-allowlist.sh && bash tests/auto-fix/test-review-plan-scope-forbid.sh && bash tests/auto-fix/test-review-plan-marker-refresh.sh && bash tests/auto-fix/test-review-plan-marker-edge-cases.sh`

- Create `scripts/lib/marker-hash.sh`: a thin bash helper that reads a plan file, splits at the last column-zero marker line (real-marker regex OR placeholder regex per `review-plan/SKILL.md:431`), and emits `git hash-object --stdin` of the content above the marker. Used by both `scripts/apply-auto-fix-plan.sh` and (refactor) `.claude/skills/conduct/marker.py` / `.codex/skills/conduct/marker.py` — both invoke the bash helper instead of `marker.py` duplicating the hash logic, eliminating the layering-inversion concern. The refactor of `marker.py` to call the bash helper is part of this phase.
- Create `scripts/plan-scope-detect.sh` (bash + awk): takes `<plan-file> <line>`, returns the deepest enclosing column-zero heading (e.g., `## Requirements`, `### Phase 2: foo`). Skips fenced code blocks when resolving the enclosing heading. Used by the applier to enforce the scope-forbid list.
- Create `scripts/apply-auto-fix-plan.sh`: the `/review-plan` entry point. Same shape as the code applier but: (1) loads allowlist key `review-plan` from `auto-fix-allowlist.json`; (2) calls `plan-scope-detect.sh` for each fix and drops if resolved heading is in `{## Requirements, ## Acceptance Criteria, ### Files to Modify, ### New Files to Create, ### Architecture Decisions, ### Integration Seams}` OR matches `^### Phase \d+:` (covers any digit count); (3) no test gate (plans are markdown; `check-prompt-parity` is the analogue); (4) after all eligible fixes apply, runs a final unconditional `marker_refresh` via `scripts/lib/marker-hash.sh`. Lens-emitted `marker_refresh` blocks within the batch are no-ops.
- Adversarial fixtures (Phase 3): `plan-scope-evasion-indented.md` (` ## Requirements` with leading whitespace), `plan-scope-evasion-horizontal-rule.md` (`---` between forbidden heading and target line — assert detector still resolves to the forbidden heading), `plan-scope-evasion-fenced.md` (`` ```## Requirements `` inside a fenced block — assert detector does NOT treat as a heading), `plan-scope-evasion-two-digit-phase.md` (`### Phase 10:` — assert detector matches the regex), and the standard `<kind>-{accept,reject}.jsonl` set per allowlist `kind`.
- Edge-case fixtures (Phase 3): `marker_refresh-missing-marker.jsonl` (plan has no marker line → applier writes fresh marker at template position), `marker_refresh-corrupt-plan.jsonl` (malformed UTF-8 in plan → applier exits `marker_failed`, rolls back batch), `marker_refresh-lens-emitted-noop.jsonl` (lens emits a `marker_refresh` block AND a `prose_typo`; assert only the end-of-batch refresh runs, satisfying AC #6).
- Update `.claude/skills/review-plan/SKILL.md` Step 6 wording to incorporate `--auto-fix=trivial`; mirror in `.codex/skills/review-plan/SKILL.md` in the same phase commit. Update `.claude/skills/review-plan/rubric.md` AND `.codex/skills/review-plan/rubric.md` to add the lens-emission criterion (mirror of Phase 2's deep-review rubric line).
- Add `.review-plan/` to `.gitignore` in this phase (the phase that first creates the directory).

### Phase 4: Parity-script extension + promote

**Impl files:** `scripts/check-prompt-parity.sh, scripts/check-prompt-parity-allowlist.sh (or inline extension)`
**Test files:** `tests/parity/test-prompt-parity-extended.sh, tests/parity/test-allowlist-byte-identity.sh`
**Test command:** `bash scripts/check-prompt-parity.sh && bash tests/parity/test-prompt-parity-extended.sh && bash tests/parity/test-allowlist-byte-identity.sh && bash tests/parity/check-mirror-handoff.sh`
**Validation cmd:** `MANAGED_SKILLS="deep-review review-plan" scripts/promote-skills.sh --yes && just check-sync`

- Extend `scripts/check-prompt-parity.sh` (around line 270) to additionally verify (a) the new `auto_fix` schema fragment is byte-identical across the four SKILL.md GENERIC blocks (it's already inside the GENERIC FINDING SCHEMA AND MERGE region enforced by lines 237-274, so this is a no-op in practice — assert it with a fixture rather than a code change), (b) `scripts/auto-fix-allowlist.json` exists, parses as valid JSON, and its `deep-review` / `review-plan` arrays are cited verbatim in both `.claude/skills/<skill>/SKILL.md` files (drift between SoT JSON and SKILL.md prose fails parity).
- The existing `check-prompt-parity.sh:60-89` already covers `rubric.md` byte-identity for all four mirror copies. Phase 2 and Phase 3 pair their `rubric.md` edits across `.claude` + `.codex` in the same phase commit, so this requires no Phase 4 change.
- `tests/parity/test-allowlist-byte-identity.sh`: rewrite `auto-fix-allowlist.json`'s arrays, run `check-prompt-parity.sh`, assert failure with a clear `allowlist drift between auto-fix-allowlist.json and <SKILL.md>` message.
- Apply post-merge: `MANAGED_SKILLS="deep-review review-plan" scripts/promote-skills.sh --yes`. The validation cmd performs this on a clean working tree as the Phase 4 final gate.

## Technical Specifications

### Files to Modify

- `scripts/reconcile-findings.sh:77` — bump `ENVELOPE_SCHEMA_VERSION` 1→2; pass-through well-formed `auto_fix` on findings; reject envelopes carrying malformed `auto_fix` (missing key, non-string value).
- `scripts/render-reconciled-report.sh:43` — bump `EXPECTED_SCHEMA_VERSION` 1→2; add `[AUTO-FIXABLE]` annotation in the rendered output for findings that pass allowlist + scope-forbid gates (dry-run = full audit minus commit).
- `.claude/skills/deep-review/SKILL.md` — document `--auto-fix=trivial` flag, the `auto_fix` block in the GENERIC FINDING SCHEMA section, the per-skill `scope` typing, the allowlist (cite `auto-fix-allowlist.json` deep-review array verbatim), and the rejection rules. Mirror block is byte-identical with `.codex/`.
- `.claude/skills/deep-review/rubric.md` — add lens-emission criterion.
- `.claude/skills/review-plan/SKILL.md` — same shape; cite `auto-fix-allowlist.json` review-plan array verbatim; document scope-forbid invariant and marker edge cases.
- `.claude/skills/review-plan/rubric.md` — add lens-emission criterion.
- `.codex/skills/deep-review/SKILL.md`, `.codex/skills/deep-review/rubric.md`, `.codex/skills/review-plan/SKILL.md`, `.codex/skills/review-plan/rubric.md` — byte-identical mirrors, edited in the same phase commit as their `.claude` counterparts.
- `.claude/skills/conduct/marker.py`, `.codex/skills/conduct/marker.py` — refactor `compute_plan_hash` to invoke `scripts/lib/marker-hash.sh` instead of duplicating the hash logic. Eliminates the layering inversion.
- `scripts/check-prompt-parity.sh` — extend to cover allowlist JSON ↔ SKILL.md byte-identity.
- `.gitignore` — add `.review-plan/`.

### New Files to Create

- `scripts/auto-fix-allowlist.json` — single source of truth for per-skill allowlist enums. Shape: `{"deep-review": ["docstring_typo", "unused_import", "unused_var", "mechanical_replace", "import_sort"], "review-plan": ["symbol_rename", "path_rename", "line_anchor_refresh", "marker_refresh", "prose_typo", "prose_clarify"]}`.
- `scripts/apply-auto-fix-code.sh` — `/deep-review` applier entry point. Bash + jq.
- `scripts/apply-auto-fix-plan.sh` — `/review-plan` applier entry point. Bash + jq + awk.
- `scripts/lib/auto-fix-common.sh` — shared bash helpers (manifest writer, drift-check, allowlist loader, commit + trailer composition).
- `scripts/lib/marker-hash.sh` — `git hash-object --stdin` over content above the marker; replaces the Python-based hash in `marker.py`. Used by both the applier and the conductor.
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
- **Schema v2 over additive v1.** Adding `auto_fix` triggers the lockstep bump even though it is an optional field, matching the existing GENERIC block's "bump on shape change" precedent and the project's policy of explicit version boundaries over silent additive evolution. The breakage risk (v1 renderer hard-rejects v2 envelopes) is accepted because no v1 renderer ships after v2 lands; the only consumers are obsolete cache files and developers running stale CI containers, both of which are acceptable hard-fail surfaces.
- **One commit per fix, no squash.** Each `auto-fix(...)` commit is independently revertable. The manifest documents the range; `git revert <a>..<b>` is the supported rollback. Sequential commits keep blame surface coherent.
- **Two appliers + shared lib, not one dispatching script.** `apply-auto-fix-code.sh` and `apply-auto-fix-plan.sh` are separate entry points sharing `scripts/lib/auto-fix-common.sh` for manifest + drift-check + allowlist loading. The two skills' gating logic is disjoint (test-gate vs scope-forbid + marker-refresh); a single dispatcher would obscure that invariant. Matches the existing `reconcile-findings.sh` / `render-reconciled-report.sh` separation pattern.
- **`marker.py` calls into `scripts/lib/marker-hash.sh`, not the reverse.** Eliminates the layering inversion (`scripts/` reaching into `.claude/skills/conduct/`) and removes the Python dep from the applier surface. Both runtime mirrors (`.claude/` and `.codex/`) refactor their `marker.py` to invoke the bash helper; the conductor's hash semantics are unchanged. AC #4 already names `git hash-object --stdin` as the canonical operation.
- **Applier is bash, not Python.** Both review skills are markdown-only today; adding a Python dependency would change their footprint. The applier is git + jq + awk; portable, no new tooling. (Note: `marker.py` continues to exist in `conduct/` because the conductor uses it; the applier reaches the same hash logic via the shared bash helper, not via Python.)
- **Trailer is `Auto-Fixed-By: <skill>`, not `Auto-Fixed-By: <runtime>`.** Distinct from `Conducted-By: <runtime>` so the handoff gate (`tests/parity/check-mirror-handoff.sh`) does not have to be taught about a new trailer key — it matches `Conducted-By:` explicitly (case-sensitive) and ignores anything else.
- **`/review-plan` test-gate is the marker invariant, not the test suite.** Plans are markdown; the analogue of "tests pass" is "the contract section's hash is still valid after edits." The mandatory final `marker_refresh` makes this trivially true. Failure of the hash computation itself (corrupt plan) rolls back all batch edits.
- **Scope-forbid is structural, not heuristic.** Heading-hierarchy parse via `plan-scope-detect.sh` (skips fenced code blocks). A `prose_clarify` inside `## Requirements` is dropped regardless of how innocuous the wording change reads.
- **`auto_fix.scope` is typed per skill.** Deep-review uses `{file, function, block}` (informational, not a gate). Review-plan uses `<path>:<line>` (redundant with finding's `file:line`, kept for schema symmetry; applier recomputes the enclosing heading via `plan-scope-detect.sh`).
- **Allowlist as SoT JSON, cited verbatim in SKILL.md.** Reduces drift surface from 6 files (4 SKILL.md + 1 applier + 1 parity check) to 1 (the JSON). `check-prompt-parity.sh` asserts byte-identity between JSON arrays and SKILL.md prose.
- **Malformed `auto_fix` blocks fail loudly.** Same principle as schema_version mismatch — a malformed structural marker is a lens-emission bug and surfacing it loudly is more useful than silently demoting findings to advisory.
- **Tests-must-pass is single-shot, no retry.** Flake handling is the user's problem. Retry would mask real regressions and complicate the rollback path.

### Dependencies

- No new dependencies. Existing: bash, git, jq, awk.

### Integration Seams

| Seam | Writer (task) | Caller (task) | Contract |
|------|---------------|---------------|----------|
| `auto_fix` field on finding | lens prompt (Phase 1 SKILL.md edits) | reconciler (Phase 1), appliers (Phases 2 & 3) | Field is optional. When present: `kind`, `before`, `after`, `scope` all required strings; `kind` from per-skill allowlist; `before`/`after` byte-precise; `scope` typed per skill (`{file, function, block}` for deep-review, `<path>:<line>` for review-plan). Malformed → reconciler rejects envelope. |
| Reconciler envelope v2 | `scripts/reconcile-findings.sh` (Phase 1) | `scripts/render-reconciled-report.sh` (Phase 1), `scripts/apply-auto-fix-{code,plan}.sh` (Phases 2 & 3) | `schema_version: 2`; presence of `auto_fix` on finding signals eligibility. Renderer surfaces `[AUTO-FIXABLE]` annotation (human audit only); appliers consume the envelope JSON directly for the apply path. |
| `auto-fix-allowlist.json` | `scripts/auto-fix-allowlist.json` (Phase 1) | `scripts/lib/auto-fix-common.sh` (Phase 2), SKILL.md prose (Phases 1-3), `check-prompt-parity.sh` (Phase 4) | Per-skill enum; unknown `kind` → `status: rejected_kind` in manifest. SKILL.md cites the JSON arrays verbatim; parity check enforces byte-identity. |
| Manifest file | `scripts/apply-auto-fix-{code,plan}.sh` via `scripts/lib/auto-fix-common.sh` (Phases 2 & 3) | user (manual rollback) | JSON shape `[{kind, file, line, commit_sha, before_sha, status}]` written to `.deep-review/auto-fix-<unix>.json` or `.review-plan/auto-fix-<unix>.json`. `git revert <first_sha>..<last_sha>` undoes the batch. |
| `Auto-Fixed-By:` trailer | `scripts/lib/auto-fix-common.sh` (Phases 2 & 3) | `tests/parity/check-mirror-handoff.sh` (Phase 2 test asserts ignore) | Commit trailer; distinct key from `Conducted-By:`. Handoff gate matches only case-sensitive `Conducted-By:` per existing line 51. |
| Plan scope detection | `scripts/plan-scope-detect.sh` (Phase 3) | `scripts/apply-auto-fix-plan.sh` (Phase 3) | Input `<plan-file> <line>`, output `<deepest-enclosing-heading>`. Caller drops fix if heading matches the forbid list. Skips fenced code blocks. |
| Marker hash | `scripts/lib/marker-hash.sh` (Phase 3) | `scripts/apply-auto-fix-plan.sh` (Phase 3) end-of-batch refresh; `marker.py` in `.claude/skills/conduct/` and `.codex/skills/conduct/` (Phase 3 refactor) | Input plan file; output `git hash-object --stdin` of content above the marker. Missing marker → writes fresh marker per template; corrupt plan → exits `marker_failed`, applier rolls back batch edits. |

## Testing Notes

### Test Approach

- [ ] Unit tests for `scripts/apply-auto-fix-code.sh` allowlist enforcement (each `kind` accept/reject case)
- [ ] Adversarial fixtures for `/deep-review` smuggling: semantic-flip `mechanical_replace`, multi-line `mechanical_replace`, test-file-read `unused_var`
- [ ] Unit test for `/deep-review` test-gate rollback
- [ ] Counter-wrapper test asserting test-gate runs the command exactly once
- [ ] Trailer-collision tests: single trailer, both trailers, lowercase variant
- [ ] Unit tests for `scripts/apply-auto-fix-plan.sh` allowlist enforcement
- [ ] Adversarial fixtures for scope-forbid evasion: indented heading, horizontal rule, fenced pseudo-heading, two-digit phase
- [ ] Marker-refresh edge cases: missing marker, corrupt plan, lens-emitted no-op
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
- [ ] Test-gate failure during `/deep-review` apply → revert, manifest records `test_failed`, finding re-surfaced as advisory
- [ ] Test-gate invoked exactly once per fix (no retry)
- [ ] Adversarial: `mechanical_replace` with semantic-flipping single-line `before`/`after` (e.g., `if x:` → `if not x:`) → applier applies, test-gate catches (or doesn't — fixture documents the tradeoff)
- [ ] Adversarial: multi-line `mechanical_replace` `before` → rejected pre-apply (`status: rejected_multiline`)
- [ ] Adversarial: `unused_var` claimed unused, but test file reads it → applier's re-verification catches (`status: rejected_revar`)
- [ ] `/review-plan` `prose_clarify` whose scope lands in `### Phase 2: foo` → dropped, manifest records `rejected_scope`
- [ ] `/review-plan` scope-forbid evasion: indented heading, horizontal rule, fenced pseudo-heading, two-digit phase → all correctly resolved (forbidden heading still matched; fenced ignored)
- [ ] `marker_refresh` on plan with no marker → writes fresh marker at template position
- [ ] `marker_refresh` on corrupt plan → exits `marker_failed`, rolls back batch
- [ ] `marker_refresh` lens emission + `prose_typo` lens emission in same batch → only end-of-batch refresh runs
- [ ] v1 envelope passed to v2 reconciler → upgrade in-flight, no `auto_fix` applied
- [ ] v2 envelope passed to v1 renderer → reject with clear error
- [ ] v2 envelope with malformed `auto_fix` (missing `scope`, non-string `before`) → reconciler exits non-zero with clear error
- [ ] Multiple fixes in a single batch, last one fails the test-gate → only the failing one rolls back; preceding successes are kept
- [ ] Plan with a malformed heading (e.g., `##Heading` no space) → scope detector returns "unknown", applier drops the fix conservatively
- [ ] Commit with both `Auto-Fixed-By:` and `Conducted-By:` trailers → handoff gate matches as `Conducted-By:`
- [ ] Commit with lowercase `auto-fixed-by:` trailer → ignored by handoff gate (case-sensitive)

## Acceptance Criteria

1. `/deep-review --auto-fix=trivial` on a branch with a synthetic `unused_import` finding lands exactly one commit with subject `auto-fix(deep-review): unused_import at <file>:<line>` and trailer `Auto-Fixed-By: deep-review`; manifest at `.deep-review/auto-fix-<unix>.json` records `{status: applied, commit_sha, before_sha}`.
2. `/deep-review --auto-fix=trivial` with a finding whose `kind` is outside the allowlist (e.g., `refactor_method`, or `dead_branch` which is intentionally excluded from v1) leaves the working tree unchanged; manifest records `status: rejected_kind`; the finding still appears in the surfaced report.
3. `/deep-review --auto-fix=trivial` whose applied fix breaks the canonical test command auto-reverts via `git revert` and re-surfaces the finding; manifest records `status: test_failed` with the test command output captured under `evidence`. The test command is invoked exactly once (no retry) per applied fix — verified by `test-deep-review-test-gate-single-invocation.sh`.
4. `/review-plan --auto-fix=trivial` with a `prose_typo` whose `auto_fix.scope` resolves to ordinary prose applies the edit AND refreshes the `<!-- reviewed: ... @ <hash> -->` marker; the new hash matches `git hash-object --stdin` of the post-edit contract section.
5. `/review-plan --auto-fix=trivial` with a `symbol_rename` whose `auto_fix.scope` resolves to `## Requirements` is dropped; manifest records `status: rejected_scope`; finding re-surfaces as advisory.
6. `/review-plan --auto-fix=trivial` with a `marker_refresh` lens emission AND a `prose_typo` lens emission applies the typo, then refreshes the marker exactly once at end-of-batch (the lens-emitted `marker_refresh` is a no-op) — verified by `marker_refresh-lens-emitted-noop.jsonl`.
7. `/review-plan --auto-fix=trivial` on a plan with no existing marker writes a fresh marker; on a plan with corrupt UTF-8 exits `marker_failed` and rolls back any prose edits applied during the batch.
8. Without `--auto-fix=trivial`, both skills behave identically to today (no edits applied) but the rendered report shows `[AUTO-FIXABLE]` annotations next to every finding that **would have been applied** (allowlist + scope-forbid gates run in dry-run; `rejected_kind` and `rejected_scope` findings are NOT annotated).
9. `bash scripts/check-prompt-parity.sh` is green at the end of every phase: the new `auto_fix` schema block is byte-identical across `.claude/skills/deep-review/SKILL.md`, `.codex/skills/deep-review/SKILL.md`, `.claude/skills/review-plan/SKILL.md`, `.codex/skills/review-plan/SKILL.md`; both pairs of `rubric.md` are byte-identical; `scripts/auto-fix-allowlist.json` arrays are cited verbatim in both `.claude/skills/<skill>/SKILL.md` files.
10. `bash tests/parity/test-handoff-ignores-auto-fix.sh` is green: commits with `Auto-Fixed-By:` trailers (alone, with `Conducted-By:`, or lowercase) interact correctly with `check-mirror-handoff.sh` (ignored / matched / ignored respectively).
11. `bash tests/reconciliation/test-renderer.sh` is green against v2 envelopes; v2 rejects v2-as-v1 attempts; v1 envelopes still parse (upgrade in-flight); v2 envelopes with malformed `auto_fix` rejected with clear error.
12. Code reviewed and approved.
13. Tests passing.

### Manual Acceptance (not automatable)

- SKILL.md, rubric.md, `auto-fix-allowlist.json`, this plan's Final Results, and any relevant CHANGELOG entry are reviewed for accuracy and consistency.

<!-- reviewed: 2026-05-15 @ de81711dfd584abddd92a5022787b20151e82cc3 -->
<!-- /review-plan writes the marker line above. Everything below is the workspace: edits here do NOT invalidate the marker. -->

## Progress

- [ ] Phase 1: Shared schema + reconciler + renderer
- [ ] Phase 2: /deep-review auto-fix applier + handoff regression test
- [ ] Phase 3: /review-plan auto-fix applier with scope-forbid + .gitignore
- [ ] Phase 4: Parity-script extension + promote

## Findings

- (append findings here as work proceeds)

## Issues & Solutions

### Pre-implementation review (2026-05-15)

`/review-plan` returned 1 Critical, 8 Important, 11 Minor findings. All applied:

- **Critical** — `compute_marker_hash` → `compute_plan_hash` rename was avoided entirely by extracting `scripts/lib/marker-hash.sh` (`git hash-object`–based bash helper); `marker.py` now calls the helper, eliminating both the typo and the layering inversion.
- **Important** — applier split into `apply-auto-fix-code.sh` + `apply-auto-fix-plan.sh` + shared `scripts/lib/auto-fix-common.sh`. Schema bump kept at v1→v2 (user-confirmed: lockstep precedent over additive). Codex rubric edits paired with their producing phase (Phase 2 / Phase 3), eliminating the `check-prompt-parity.sh` boundary breakage. Allowlist adversarial fixtures (`mechanical_replace-reject-semantic-flip`, `-reject-multiline`, `unused_var-reject-test-file-read`) and scope-forbid evasion fixtures (indented heading, horizontal rule, fenced pseudo-heading, two-digit phase) enumerated explicitly. AC #6 backed by `marker_refresh-lens-emitted-noop.jsonl`.
- **Minor** — `auto_fix.scope` typed per skill (deep-review `{file, function, block}`; review-plan `<path>:<line>`). Allowlist enums extracted to `scripts/auto-fix-allowlist.json` SoT, cited verbatim in SKILL.md and asserted byte-identical by `check-prompt-parity.sh`. `[AUTO-FIXABLE]` annotation rules clarified (dry-run = full audit minus commit; `rejected_kind`/`rejected_scope` not annotated). `dead_branch` dropped from v1 allowlist (user-confirmed: lens self-tagging is the failure mode). Malformed `auto_fix` → reconciler rejects envelope (user-confirmed: fail loudly). Test-gate single-invocation backed by a counter wrapper. Trailer-collision test expanded to mixed + lowercase variants. Marker edge cases (missing, corrupt) covered. AC #13 moved to a Manual Acceptance subsection. Handoff regression test moved to Phase 2. `.gitignore` `.review-plan/` addition moved to Phase 3.

## Final Results

(fill on completion)
