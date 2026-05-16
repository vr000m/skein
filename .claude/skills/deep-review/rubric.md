# Deep Review Output Rubric

Gradeable criteria for evaluating a completed deep-review report. Doubles as a Managed Agents outcome rubric (text mode) and a local self-check before presenting findings to the user.

## Coverage

- Every enabled lens produced findings or an explicit "no issues" statement
- The Spec lens ran iff the dev-plan `## Review Focus` section listed RFCs or specs (skip is justified otherwise)
- Lenses that timed out or errored are reported as `timed_out` / `errored`, not silently dropped
- Findings are reconciled across lenses per the Reconciliation section below — same `(file, line, category)` signature merges, same `(file, line)` different category emits a Related findings cross-reference (no collapse)

## Finding Quality

- Each finding has all five fields: Severity, Category, Location (file:line), Evidence, Suggestion
- Severity is one of Critical / Important / Minor — no other values
- Category matches the lens that produced it (Logic, Security, Spec, Architecture, Documentation)
- Evidence cites concrete code, diff hunk, or spec section — not a paraphrase
- Suggestion is a specific, actionable change — not "consider improving X"

## Suppression Discipline

- Suppression is sourced from the merge-base `AGENTS.md ## Review Checklist`, not the current branch
- Suppressed findings name the specific file/symbol/pattern matched, not just the category
- Findings are not generalised beyond what the checklist actually states

## Scope Discipline

- Each lens stays inside its scope (Logic doesn't flag style; Security doesn't flag docs)
- The Spec lens does not invent specs beyond what `## Review Focus` lists
- No finding is manufactured to fill a slot — clean lenses say so explicitly

## Output Structure

- Report is grouped by severity (Critical → Important → Minor)
- One-line overall summary at the top
- Skipped or timed-out lenses are called out under "Residual Risks"
- Markdown is well-formed and renders cleanly

## Reconciliation

- Report includes a `Lenses:` field on every finding (sorted alphabetically, deduplicated); merged findings cite ≥2 lenses
- No two findings share an identical `(file, line, category)` signature in the same severity tier — a duplicate signature means the merge step did not run or its output was lost
- Reconciliation step receives only lens return strings (JSON-Lines via `scripts/reconcile-findings.sh`); no parent conversation context is passed to it

## Auto-Fix Lens Emission

- Lens emitted an `auto_fix` block whenever a finding matches the allowlist shape — `kind ∈ {docstring_typo, unused_import, unused_var, mechanical_replace, import_sort}` with single-line `before`/`after` and `scope ∈ {file, function, block}`
- Absent `auto_fix` on a clearly mechanical finding is a lens-quality issue, not a safety feature — the audit step (`scripts/audit-auto-fix-eligibility.sh`) and applier (`scripts/apply-auto-fix-code.sh`) are the gate, not lens self-restraint
- `auto_fix.before` is byte-precise to the file:line under review; the lens did not paraphrase, normalise whitespace, or strip a trailing newline

## Continuation Safety

- If `--continue` was used and stored `head_commit == HEAD`, only `errored`/`timed_out` lenses were re-run; completed lens findings were reused
- If `--continue` was used and `HEAD` advanced past the stored `head_commit` (incremental re-review), all lenses re-ran over the new range only and the report uses the continuation format with the `(continuation)` header, an explicit "Range reviewed this run" line, and prior findings listed separately under "Prior findings ... — verify these are addressed"
- If stored `head_commit` is not an ancestor of `HEAD` (force-push, rebase) or `review_focus_hash` changed, the run fell back to `--full` with a warning
- Stored state in the per-harness `.deep-review/latest-*.json` file matches the schema version

## Dispatch Preflight

- Pre-dispatch banner prints resolved range and worktree identity; trunk-vs-trunk halt fires before any state-file write; `--continue` resume mode shows stored range with `(resume)` tag.
