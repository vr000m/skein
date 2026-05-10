# Task: Cross-lens finding reconciliation in `deep-review` and `review-plan`

**Status**: Complete
**Assigned to**: Claude
**Priority**: Medium
**Branch**: feature/cross-lens-reconciliation
**Created**: 2026-05-08
**Completed**: 2026-05-10

## Objective

Add a reconciliation pass to `deep-review` and `review-plan` that dedupes and merges findings produced by parallel lens subagents before surfacing them to the user, suppressing the false-positive amplification that currently occurs when 2-3 lenses flag the same underlying issue.

## Context

`deep-review` and `review-plan` are multi-lens review skills. Each fans out to several fresh-context lens subagents (logic, security, architecture, spec-and-testing, codebase-claims, etc.) that each return findings. Today those findings are concatenated and surfaced raw — there is no step that recognises when two lenses have flagged the same underlying issue from different angles, so the user sees the same problem 2-3 times in a single review report.

This is the last NOT FIXED badge from the 2026-05-04 usage-report skill-improvements work and item 1(b) on the parked horizon list (`project_horizon_followups.md`). Item 1(a) — `conduct` marker auto-refresh on `--resume` — shipped in PR #20 on 2026-05-08.

## Requirements

- Reconciliation runs **after** all lens subagents return and **before** the consolidated report is surfaced to the user.
- Reconciliation MUST preserve every distinct issue — dedup, never drop. When two findings are merged, the merged finding cites every source lens.
- Reconciliation MUST be deterministic given identical lens output (no LLM coin-flips that change the report under re-run). Output ordering MUST also be canonical so that lens-arrival order does not perturb the report.
- Mirror parity between `.claude/skills/{deep-review,review-plan}/` and `.codex/skills/{deep-review,review-plan}/` is mandatory and lands phase-by-phase, not at the end — every phase boundary commit MUST keep `just check-prompt-parity` green.
- The reconciliation step MUST be auditable: the surfaced report indicates which findings were merged and which were unique, so the user can verify reconciliation behaviour without re-running lenses.
- Reconciliation logic has a single source of truth: a standalone script (`scripts/reconcile-findings.sh`) that both SKILL.md files reference via an embedded snippet validated by a snippet-parity check.

## Review Focus

- **Suppression-vs-loss invariant.** The single highest-risk failure mode is silently dropping a real finding because reconciliation mistook it for a duplicate. Reviewers should specifically verify the merge rule: same `file:line + category` → merge with all source lenses cited; same `file:line` but different category → surface as a "related findings" callout, NOT merged; same category but different `file:line` → kept fully separate.
- **Determinism (merge step) and canonical ordering.** Determinism is scoped to the merge step — lens summaries are LLM-produced and not deterministic end-to-end. Within scope: identical lens input → byte-identical reconciled output, including under shuffled lens-arrival order (output sort key: severity → category → file → line → sorted lenses list).
- **Audit trail in the surfaced report.** Every reconciled finding shows its provenance via a `Lenses:` field. Single-source findings show `Lenses: [<one>]` (the field is always populated, never omitted). Merged findings show all source lenses sorted alphabetically.
- **Codex mirror parity** for the SKILL.md / rubric.md edits — landed in the same phase as Claude-side edits, byte-identical, gated by `just check-prompt-parity`. The deferred-mirror pattern from PRs #16/#20 is NOT used here — every phase boundary keeps both trees in sync.
- **No regression in fresh-context isolation.** Reconciliation runs in the parent orchestrator on returned lens strings; no subagent receives parent conversation context. Verified by a rubric self-check criterion.

## Implementation Checklist

### Phase 1: Standalone reconciler + GENERIC block + extended parity script

**Impl files:** `scripts/reconcile-findings.sh, scripts/check-prompt-parity.sh, .claude/skills/review-plan/SKILL.md, .claude/skills/deep-review/SKILL.md, .claude/skills/review-plan/rubric.md, .claude/skills/deep-review/rubric.md, .codex/skills/review-plan/SKILL.md, .codex/skills/deep-review/SKILL.md, .codex/skills/review-plan/rubric.md, .codex/skills/deep-review/rubric.md`
**Test files:** `tests/reconciliation/test-reconciler-unit.sh`
**Test command:** `just check-prompt-parity && just check-trunk-snippet-parity && bash tests/reconciliation/test-reconciler-unit.sh`

- Create `scripts/reconcile-findings.sh` — the single source of truth for reconciliation logic. Reads JSON-Lines findings on stdin (`{lens, severity, category, file, line, summary, evidence, suggestion}`), emits a canonical reconciled JSON report on stdout. Merge rule: group by `(file, line, category)`; merged findings concatenate sorted-unique `lenses`; same-`(file,line)`-different-category groups emit a `related: [...]` cross-reference list rather than merging. Output sort: severity → category → file → line → sorted lenses. Empty input → emits `{raw: 0, merged: 0, unique: 0, findings: [], related: []}` with the summary block populated.
- Promote review-plan's existing `<!-- BEGIN GENERIC FINDING SCHEMA AND MERGE -->` block (currently at lines **320-329**) into the new structured schema: documents the `(file, line, category)` signature, the `Lenses:` provenance field, the canonical sort order, and the related-findings callout rule. Embed a literal command snippet (e.g., `cat findings.jsonl | scripts/reconcile-findings.sh`) so the SKILL.md prose and the script have a verifiable single point of contact.
- Add the byte-identical GENERIC block to `.claude/skills/deep-review/SKILL.md`, replacing the existing prose dedup section ("### 3. Deduplicate Findings" at lines **378-382**). The replacement preserves the section heading and adds the structured contract.
- Update both `.claude/skills/{deep-review,review-plan}/rubric.md` files with new self-check criteria: (a) "report includes `Lenses:` field on every finding (sorted, deduped); merged findings cite ≥2 lenses", (b) "no two findings share an identical `(file, line, category)` signature in the same severity tier", (c) "reconciliation step receives only lens return strings; no parent conversation context is passed to it" (covers Review Focus #5).
- Mirror all four `.claude/.../{SKILL,rubric}.md` edits byte-identically into `.codex/skills/{deep-review,review-plan}/`. Both trees move together at this phase boundary.
- Extend `scripts/check-prompt-parity.sh` to also extract and diff the `<!-- BEGIN/END GENERIC FINDING SCHEMA AND MERGE -->` block content across `.claude/skills/{deep-review,review-plan}/SKILL.md` and `.codex/skills/{deep-review,review-plan}/SKILL.md`. Modelled on `scripts/check-trunk-snippet-parity.sh`'s extraction approach.
- Add `tests/reconciliation/test-reconciler-unit.sh` — feeds the script a small set of inline JSON-Lines fixtures (single finding pass-through, two-lens merge, same-file-different-category related-callout, empty input) and asserts the canonical output. Verifies the contract semantically, not just byte parity.

### Phase 2: Update report templates to surface provenance

**Impl files:** `.claude/skills/deep-review/SKILL.md, .claude/skills/review-plan/SKILL.md, .codex/skills/deep-review/SKILL.md, .codex/skills/review-plan/SKILL.md`
**Test files:** `tests/reconciliation/fixtures/*.jsonl, tests/reconciliation/expected/*.md, tests/reconciliation/run-fixtures.sh`
**Test command:** `just check-prompt-parity && bash tests/reconciliation/run-fixtures.sh`

- Add `Lenses:` field to the deep-review report template (currently SKILL.md lines **399-417**, no source attribution). Single-source findings render `Lenses: [logic]`; merged findings render `Lenses: [logic, security]` (alphabetically sorted, deduped).
- Extend review-plan report template (currently SKILL.md lines **340-358**) so the existing `[Lens] / [Category]` prefix becomes a `Lenses:` list field that handles ≥1 source lens uniformly.
- Both templates show a `Reconciliation:` summary line at the top of the report: `raw=N merged=M unique=U related=R`. Empty-input case still renders the line with all zeros.
- Both templates add a "Related findings" subsection underneath each merged finding when same-`(file,line)`-different-category cross-references exist. The callout cites both severity tiers and both categories.
- Mirror byte-identically into `.codex/skills/{deep-review,review-plan}/SKILL.md` in the same phase.
- Create the `tests/` parent directory and `tests/reconciliation/{fixtures,expected}/` subdirectories. Note: `tests/` does not exist in the repo today — Phase 2 establishes it.
- Create `tests/reconciliation/run-fixtures.sh` — shell harness that pipes each `fixtures/*.jsonl` file through `scripts/reconcile-findings.sh` and diffs against `expected/*.md` (the expected file is the rendered template). Fixtures cover the eight edge cases enumerated in the Testing Notes.

### Phase 3: Wire reconciliation step into orchestrator prose

**Impl files:** `.claude/skills/deep-review/SKILL.md, .claude/skills/review-plan/SKILL.md, .codex/skills/deep-review/SKILL.md, .codex/skills/review-plan/SKILL.md`
**Test files:** `tests/reconciliation/run-fixtures.sh, tests/reconciliation/test-determinism.sh`
**Test command:** `just check-prompt-parity && bash tests/reconciliation/run-fixtures.sh && bash tests/reconciliation/test-determinism.sh`

- In `.claude/skills/deep-review/SKILL.md` (fan-out at lines **157-163**, dedup section now at the GENERIC block from Phase 1): insert an explicit "Step 3.5: Reconcile findings" between lens return and report emission. The step (a) collects lens output as JSON-Lines, (b) pipes through `scripts/reconcile-findings.sh`, (c) renders into the report template, (d) emits the `Reconciliation:` summary line. The step explicitly forbids any LLM call inside the reconciliation pass — matching is structural on `(file, line, category)` only.
- Mirror in `.claude/skills/review-plan/SKILL.md`: replace the one-sentence collapse rule with the explicit reconciliation walkthrough referencing the GENERIC schema block.
- Mirror byte-identically into `.codex/skills/{deep-review,review-plan}/SKILL.md` in the same phase.
- Add `tests/reconciliation/test-determinism.sh` — runs each fixture twice with shuffled lens-arrival order and asserts byte-identical output. Covers the canonical-ordering invariant from Review Focus #2.

### Phase 4: Final acceptance + promote

**Impl files:** (none — verification phase)
**Test files:** (none — runs existing scripts)
**Test command:** `just check-sync && just reconciliation-tests`

- Run the full local test suite once. All Phase 1-3 edits should already keep parity green at every prior boundary; this phase is the consolidated check.
- Run `just promote-skills` as the final acceptance step **after merge to main** (separate post-merge action, NOT a commit on this branch). Document the post-merge step in the PR description.
- Run `/update-docs`, `/review`, `/security-review`, and `/deep-review` on this PR before merge — addressed in Acceptance Criteria below.

## Technical Specifications

### Files to Modify

- `.claude/skills/deep-review/SKILL.md` — Phase 1 replaces the existing prose dedup section ("### 3. Deduplicate Findings" at lines **378-382**) with the byte-identical GENERIC block; Phase 2 adds `Lenses:` field and `Reconciliation:` summary line to the report template at lines **399-417**; Phase 3 inserts "Step 3.5: Reconcile findings" between fan-out (lines **157-163**) and report emission.
- `.claude/skills/review-plan/SKILL.md` — Phase 1 upgrades the existing GENERIC merge block at lines **320-329** to the new structured schema (line range corrected from prior plan draft); Phase 2 extends the report template at lines **340-358** to render `Lenses:` as a list field; Phase 3 replaces the one-sentence collapse rule with the explicit reconciliation walkthrough.
- `.claude/skills/deep-review/rubric.md` — Phase 1 adds three reconciliation self-check criteria (Lenses field, signature uniqueness, fresh-context isolation).
- `.claude/skills/review-plan/rubric.md` — same as above.
- `.codex/skills/{deep-review,review-plan}/{SKILL.md,rubric.md}` — byte-identical mirror of Claude-side edits, landed in the same phase as the Claude edit. Gated by `just check-prompt-parity`.
- `scripts/check-prompt-parity.sh` — Phase 1 extends the script to extract+diff `<!-- BEGIN/END GENERIC FINDING SCHEMA AND MERGE -->` block content across `.claude/` and `.codex/` SKILL.md files for both deep-review and review-plan. Modelled on `scripts/check-trunk-snippet-parity.sh`'s extraction approach.

### New Files to Create

- `scripts/reconcile-findings.sh` — Phase 1. Single source of truth for reconciliation logic. Stdin: JSON-Lines findings. Stdout: canonical reconciled JSON report. Uses `jq` if present, falls back to `awk`/`sort`/`uniq` otherwise (no new dependencies). Emits `{summary: {raw, merged, unique, related}, findings: [...], related: [...]}`.
- `tests/reconciliation/test-reconciler-unit.sh` — Phase 1. Inline JSON-Lines fixtures + `diff` against expected canonical output. Covers single pass-through, two-lens merge, related-callout, empty input.
- `tests/reconciliation/fixtures/*.jsonl` — Phase 2. Per-edge-case fixture files. Filenames are descriptive (e.g., `two-lens-merge.jsonl`, `near-miss-different-category.jsonl`, `single-source.jsonl`, `empty.jsonl`, `shuffled-order.jsonl`, `near-miss-same-category-different-line.jsonl`).
- `tests/reconciliation/expected/*.md` — Phase 2. Rendered template output for each fixture.
- `tests/reconciliation/run-fixtures.sh` — Phase 2. Loops over `fixtures/*.jsonl`, pipes each through `scripts/reconcile-findings.sh`, renders via the documented template, diffs against `expected/*.md`.
- `tests/reconciliation/test-determinism.sh` — Phase 3. Runs each fixture twice with `shuf`-shuffled lens-arrival order and asserts byte-identical output.
- Note: `tests/` parent directory does not exist in the repo today — Phase 2 creates it as part of this work.

### Architecture Decisions

- **Signature is `(file, line, category)` only — no free-text summary component.** Same `(file, line)` with different categories produces a "related findings" cross-reference, not a merge. This eliminates the under-merge risk that a free-text 8-word summary would have introduced (lenses run in fresh context with no shared vocabulary, so summaries paraphrase the same defect differently and would never byte-match).
- **Reconciliation logic lives in `scripts/reconcile-findings.sh`, the single source of truth.** Both SKILL.md files embed a literal command snippet (e.g., `cat findings.jsonl | scripts/reconcile-findings.sh`) and reference the script by path. The extended `check-prompt-parity.sh` ensures both SKILLs cite the script identically. The harness invokes the script directly rather than re-implementing the merge rules in shell — no two sources of truth.
- **Determinism is scoped to the merge step.** Lens summaries are LLM-produced and not deterministic end-to-end. Within scope: identical lens-output strings in any order → byte-identical reconciled report (canonical sort: severity → category → file → line → sorted lenses). The plan does NOT promise end-to-end determinism (same diff → same report) because that would require temperature/seed plumbing the structural-matching design avoids.
- **Provenance via `Lenses:` field, always populated.** A single-lens finding shows `Lenses: [logic]`; a merged finding shows `Lenses: [logic, security]`. Uniform render — no special-case "this was merged" badge. The reconciliation step ALWAYS injects the field, even for single-source findings, so the audit-trail invariant is verifiable on every output.
- **Reconciliation summary line at report top.** `Reconciliation: raw=N merged=M unique=U related=R`. Additive header — existing severity sections unchanged, so any human reader of the existing report format keeps working. No programmatic consumers identified for the existing report format (the `~/.claude/usage-data/report.html` is generated separately and does not parse skill output).
- **Codex parity moves phase-by-phase, not deferred.** The deferred-mirror pattern from PRs #16/#20 is NOT used. Each phase boundary commit keeps `just check-prompt-parity` green. Rationale: PR #20 (the conduct marker fix) demonstrated that consolidating Codex mirror at the end produces predictable rebase pain when intermediate phases ship; phase-by-phase mirror is cheaper.
- **Extended `check-prompt-parity.sh` covers SKILL.md GENERIC blocks.** Closes the gap that the previous version only diffed `rubric.md`. Modelled on the trunk-snippet parity script's HTML-comment-marker extraction approach.

### Dependencies

None new. Existing tooling: `bash`, `jq` (preferred — already installed on dev machines via Homebrew), `awk`, `sort`, `uniq`, `diff`, `shuf`, `rsync`, `just`. The script gracefully degrades to `awk`/`sort` if `jq` is unavailable.

### Integration Seams

| Seam | Writer (task) | Caller (task) | Contract |
|------|---------------|---------------|----------|
| `scripts/reconcile-findings.sh` (single source of truth) | Phase 1 | Phase 2 harness, Phase 3 orchestrator step | Stdin: JSON-Lines `{lens, severity, category, file, line, summary, evidence, suggestion}`. Stdout: canonical JSON `{summary: {raw, merged, unique, related}, findings: [...], related: [...]}`. Sort: severity → category → file → line → sorted lenses. |
| GENERIC block content | Phase 1 (introduce in deep-review; upgrade in review-plan) | Phase 1 extended `check-prompt-parity.sh` | Byte-identical block content across `.claude/skills/{deep-review,review-plan}/SKILL.md` and `.codex/skills/{deep-review,review-plan}/SKILL.md`. Block is delimited by stable HTML-comment markers. |
| `Reconciliation:` summary line | Phase 2 (report template) | Phase 3 (orchestrator) | Top of report: `Reconciliation: raw=N merged=M unique=U related=R`. Counts derived from script output's `summary` block. Always rendered, even for empty input (all zeros). |
| Codex mirror parity at phase boundaries | Each phase | Next phase's `just check-prompt-parity` precondition | Every phase boundary commit must pass `just check-prompt-parity && just check-trunk-snippet-parity`. |

## Testing Notes

### Test Approach

- [x] Unit: `tests/reconciliation/test-reconciler-unit.sh` runs inline fixtures against `scripts/reconcile-findings.sh` directly. Covers single pass-through, two-lens merge, related-callout, empty input.
- [x] Integration: `tests/reconciliation/run-fixtures.sh` pipes per-edge-case fixtures through the script and diffs rendered output against `expected/*.md`.
- [x] Determinism: `tests/reconciliation/test-determinism.sh` shuffles lens-arrival order with `shuf` and asserts byte-identical output across 5 shuffles per fixture.
- [x] Parity: `just check-prompt-parity` (extended to cover SKILL.md GENERIC blocks) gates every phase boundary commit. `just check-trunk-snippet-parity` continues to gate the unrelated trunk snippet.
- [x] End-to-end: run `/deep-review` against a known feature branch (this branch itself, after Phase 3 lands), capture report, verify it shows merged findings with `Lenses:` provenance and a populated `Reconciliation:` line.
- [x] Renderer: `tests/reconciliation/test-renderer.sh` pipes each fixture envelope through `scripts/render-reconciled-report.sh` and diffs against `expected/<name>.rendered.md` goldens; asserts the `dropped=D` iff invariant and byte-identical `jq`/awk fallback rendering.

### Test Results

- [x] All existing tests pass
- [x] New tests added and passing
- [x] Manual verification complete

### Edge Cases Tested

- [x] Single finding from a single lens — passes through unchanged with `Lenses: [<one>]` injected (audit-trail invariant on single-source case).
- [x] Two findings on same `(file, line, category)` from two lenses → merged with `Lenses: [a, b]` sorted alphabetically.
- [x] Three lenses flag same `(file, line, category)` → merged into one with all three cited.
- [x] Same `(file, line)` but different categories → kept separate; emit "Related findings" cross-reference between them.
- [x] Same category but different `(file, line)` → kept fully separate, no cross-reference.
- [x] Lens returns empty findings — does not break reconciliation; `Reconciliation: raw=0 merged=0 unique=0 related=0` line still renders.
- [x] Lens-arrival order shuffled — output is byte-identical (canonical sort).
- [x] Mixed severities at same `(file, line, category)` — merge picks highest severity; lower-severity lens still cited in `Lenses:`.
- [x] Malformed JSON-Lines input — non-JSON lines counted as `summary.dropped`, stderr warning emitted, `dropped=D` surfaced in rendered Reconciliation line iff D > 0.

## Acceptance Criteria

- Reconciliation step runs after all lens subagents return in both `deep-review` and `review-plan`, invoking `scripts/reconcile-findings.sh`.
- Reconciled report shows `Lenses:` provenance on every finding (always populated, sorted, deduped).
- Determinism check passes: identical lens input under shuffled order → byte-identical reconciled output across 5 shuffles per fixture.
- Suppression-vs-loss invariant verified: every fixture finding either appears in the reconciled output or is cited in a merged finding's `Lenses:` list. No fixture finding silently dropped.
- `just check-prompt-parity && just check-trunk-snippet-parity` passes at every phase boundary commit on this branch.
- Codex mirror is byte-identical to Claude side after every phase (verified by extended `check-prompt-parity.sh`).
- Manual verification: locate the cross-lens reconciliation row in `~/.claude/usage-data/report.html` (search: `grep -nE 'cross.?lens|reconcil' ~/.claude/usage-data/report.html`). Flip to FIXED with this PR's merge-commit citation. If the report.html schema has changed and no matching row exists, document the deviation in `## Findings` before merge — this is a manual-verification step, not an automated gate.
- `/review-plan`, `/review`, `/security-review`, and `/deep-review` run on this PR before merge with all findings addressed.
- `just promote-skills` run as a separate post-merge action (after merge to main, not on this branch).

<!-- reviewed: 2026-05-09 @ ce1f2fc85716252807c70cf99eb6fe3c81e892c1 -->
<!-- /review-plan writes the marker line above. Everything below is the workspace: edits here do NOT invalidate the marker. -->

## Progress

- [x] Phase 1: Standalone reconciler + GENERIC block + extended parity script
- [x] Phase 2: Update report templates to surface provenance
- [x] Phase 3: Wire reconciliation step into orchestrator prose
- [x] Phase 4: Final acceptance + promote

## Findings

- **Phase 2 reviewer (advisory, 2026-05-09):** `tests/reconciliation/expected/*.md` files currently contain raw reconciler JSON output rather than rendered markdown reports. The test-writer deferred template rendering to Phase 3 since the rendering procedure lives in the orchestrator prose that Phase 3 wires in. Phase 3 should either update `expected/*.md` to be rendered markdown after wiring the orchestrator step, or update `run-fixtures.sh` to render before diffing. Tracking as a Phase 3 follow-up rather than a Phase 2 fix loop.
- **Phase 2 reviewer (advisory, 2026-05-09):** `mixed-severity` merge currently keeps only the highest-severity lens's `summary`/`evidence`/`suggestion` text; lower-severity lens content is dropped beyond the `Lenses:` citation. The GENERIC block does not document a rule for concatenating per-lens evidence on merge. Phase 3 should either codify "highest-severity row wins; rest cited via Lenses only" in the GENERIC block, or extend the merge to preserve per-lens evidence.

## Issues & Solutions
- **Phase 3 reviewer (Important Scope, 2026-05-09)** — *resolved 2026-05-10*: GENERIC FINDING SCHEMA AND MERGE block now documents the mixed-severity text-preservation rule (highest-severity row's summary/evidence/suggestion wins; other lenses cited via `Lenses:` only). Clause added to the GENERIC block in all four SKILL.md files; parity check still passes byte-identically.
- **Phase 3 reviewer (Minor Clarity, 2026-05-09)** — *accepted 2026-05-10*: rendered report template (Reconciliation line, Lenses field, Related findings subsection) has no automated test coverage — the harness validates JSON, not the rendered markdown. Gap accepted explicitly (see Final Results > Follow-up Work); a renderer in `run-fixtures.sh` is its own piece of work.
- **Phase 3 reviewer (Minor Clarity, 2026-05-09)** — *resolved 2026-05-10*: `.claude/skills/deep-review/SKILL.md` now has a forward pointer to Step 3.5 at the end of Section 2 (Spawn Fresh-Context Subagents). The Codex mirror already had the equivalent inline note in its numbered fan-out step (line ~236).
- **Phase 3 test-writer adjustment (2026-05-09):** `test-determinism.sh` originally hard-required `shuf`/`gshuf` (GNU coreutils). Conductor edited the harness inline to add a portable awk+sort fallback so the test runs on stock macOS without `brew install coreutils` (which was denied by user policy). Determinism semantics preserved: 5 distinct shuffles per fixture, all asserted byte-identical and matching expected canonical output.

## Final Results

### Summary

Shipped cross-lens finding reconciliation across `deep-review` and `review-plan` in four phases. Phase 1 introduced the standalone reconciler script (`scripts/reconcile-findings.sh`) as the single source of truth, promoted the GENERIC FINDING SCHEMA AND MERGE block into a structured contract embedded byte-identically in four SKILL.md files, and extended `check-prompt-parity.sh` to gate that block. Phase 2 added the `Lenses:` provenance field, `Reconciliation:` summary line, and `Related findings` subsection to both report templates, and stood up the `tests/reconciliation/` harness with eight per-edge-case fixtures. Phase 3 wired the explicit "Step 3.5: Reconcile findings" step into the orchestrator prose for both skills (Claude + Codex mirrors) and added the determinism harness. Phase 4 ran the consolidated test suite and addressed three Phase 3 reviewer follow-ups plus a deep-review pass.

### Outcomes

- `scripts/reconcile-findings.sh` — single source of truth for the merge rule, canonical sort, related-callouts, and the `summary.{raw, merged, unique, related, dropped}` envelope. Uses `jq` when available; falls back to a hand-written awk parser that handles `\"`, `\\`, `\n`, `\t` escape sequences.
- GENERIC FINDING SCHEMA AND MERGE block — byte-identical across `.claude/skills/{deep-review,review-plan}/SKILL.md` and the two Codex mirrors. Documents the signature, severity tie-break, mixed-severity text-preservation rule, `Lenses:` provenance, canonical sort, empty-input shape, and the literal pipe-through-script command.
- Report templates — both skills render `Reconciliation: raw=N merged=M unique=U related=R`, the always-populated `Lenses:` field, and the `Related findings` subsection.
- Orchestrator wiring — explicit "Step 3.5: Reconcile findings" prose in Claude `deep-review` (+ forward pointer from fan-out), Claude `review-plan`, and both Codex mirrors. The step explicitly forbids LLM calls; matching is structural only.
- Parity infrastructure — `scripts/check-prompt-parity.sh` extended to extract+diff the GENERIC block across the four SKILL.md files, assert `scripts/reconcile-findings.sh` is present and executable, and parse `.env` without `eval`. The 4-way GENERIC duplication is documented in-file as an accepted trade-off.
- Test coverage — 8 fixtures + run-fixtures.sh, test-determinism.sh (5 shuffles per fixture, awk+sort fallback for stock macOS), and test-reconciler-unit.sh covering single pass-through / two-lens merge / related-callout / empty input.

### Learnings

- Promoting the merge rule into a parity-checked block embedded in SKILL.md prose (rather than a transcluded shared file) is cheap to enforce and survives the Claude/Codex split cleanly. The 4-way duplication overhead is small because the parity script catches drift immediately.
- Determinism is a first-class invariant for review tooling: shuffling lens-arrival order across 5 permutations per fixture caught one tie-break ambiguity early. Without that harness the bug would have surfaced as flaky reports.
- The awk fallback parser took two iterations: the original greedy regex `[^"]*` truncated on escaped quotes inside lens evidence. The replacement walks the string honouring `\\` and `\"` so escapes round-trip safely.
- Counting `merged` by distinct lenses per signature (not raw rows) avoids over-counting when a single lens emits the same finding twice — that case is single-source noise, not cross-lens reconciliation.

### Follow-up Work

- **Renderer test coverage** — *resolved 2026-05-10*: added `scripts/render-reconciled-report.sh` as a deterministic reference renderer (jq path + awk fallback, both byte-identical), `tests/reconciliation/test-renderer.sh` to diff each fixture's rendered output against `expected/<name>.rendered.md` goldens, and `dropped-input` plus `escaped-delimiters` fixtures exercising parse-failure handling and string delimiters/backslashes. The renderer harness also compares `jq` and awk fallback output byte-for-byte when `jq` is installed.
- **`summary.dropped` end-to-end visibility** — *resolved 2026-05-10*: the report template's `**Reconciliation**:` line now includes `dropped=D` whenever `summary.dropped > 0` (omitted when zero, to keep the common case terse). Threaded through all four SKILL.md mirrors (`.claude/{deep-review,review-plan}` + `.codex/{deep-review,review-plan}`); the renderer enforces the conditional and `test-renderer.sh` asserts the iff invariant.
- **The three Phase 3 reviewer items** above (mixed-severity text-preservation clause, deep-review forward pointer, renderer-coverage gap) are now addressed in this commit.
