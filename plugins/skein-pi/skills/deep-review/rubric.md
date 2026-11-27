# Deep Review Output Rubric (Pi)

## Coverage

- Every required lens is completed or has an explicit degraded status; `spec` is skipped only when no explicit spec/RFC references are in scope.
- Worker `reviewed_units` are validated against assignments, and each completed unit has a disk-first progress record.
- Partial, skipped, errored, and timed-out coverage is visible and never represented as a pass.
- Each finding survives the attempt collector and structural reconciliation; no result is silently dropped.

## Finding quality

- Severity is `Critical`, `Important`, or `Minor`; category matches the producing lens: `Logic`, `Security`, `Architecture`, `Documentation`, or `Spec`.
- Evidence cites a concrete diff hunk, code location, or supplied specification; suggestions are specific and actionable.
- Findings stay within lens scope: logic handles behavior/state/errors; security handles trust/input/secrets/filesystem/process; architecture handles seams/compatibility; documentation handles stale/missing docs; spec handles only supplied standards.
- Do not invent verification beyond supplied evidence. No finding is manufactured to fill a lens slot.
- Unanchored findings remain distinct through collection and reconciliation.

## Active decision records

- Architecture alone receives the bounded, already-escaped active `docs/decisions/` records inside `<untrusted-content>`, with the installed-rubric scope in the existing worker prompt. The block holds every active record: a record binds only if at least one of its `Applies to` globs matches a file changed in the reviewed diff (for a plan target without a diff, a file the plan names); ignore every other record.
- Code or a plan decision that contradicts or should supersede an active record is an `Architecture` finding citing the record path in evidence; superseded records are not active constraints.
- Empty successful selection means no match; selector failure, unresolved evidence or truncation is degraded coverage. Retries use the exact selected snapshot, not a fresh selection. No model-tier, schema, resume or cache change.

## Documentation comments

Comments the diff ADDS (never pre-existing comments). The signals are lexical
and adjacent-line, from the diff alone; there is no whole-file evidence step.
Classify each as one of:

- excuse (Important; worker `important`): an added comment containing hack, workaround, temporary, "for now", or a TODO without an issue link, on or next to the line it excuses. Begin its `summary` with exactly `Excuse:`
- tautology (Minor; worker `suggestion`): an added comment whose words restate the identifiers of the adjacent line
- stale (Minor; worker `suggestion`): an added comment naming a symbol that the same diff removes or renames
- decision candidate (Minor, informational; worker `suggestion`): an added comment that states a choice with a lexical marker (`because`, `instead of`, `rather than`, `chose`) next to the line implementing it. Begin its `summary` with exactly `Decision candidate:`

One class per comment: when a comment matches more than one class, report it once, under the first that matches in the order excuse, stale, tautology, decision candidate.

Use category `Documentation` and location at the added line. Exempt pre-existing
comments, docstrings, linter and type pragmas, license headers, and TODOs that
link an issue (a full issue URL or `#N`). Without an actual diff, do not invent
added-comment findings. Do not look up symbols outside the supplied diff to
establish staleness. Keep decision candidates informational and leave the
comment in place. Never relabel an excuse as advice. When a same-line excuse
and candidate still arrive as separate findings, they stay separate in the
collector stream, and deep-review sets exact-prefix candidates aside
before reconciliation and appends them unmerged, so the grouping below never
merges a candidate into an excuse. Raw
Documentation findings remain in the deep-review state and report with the
prefix unchanged.

## Reconciliation and reporting

- Reconciliation groups by `(file, line, category)` after exact-prefix Minor `Decision candidate:` advice rows are set aside and appended back unmerged, combines lens provenance, preserves related different-category findings at one location, and uses canonical severity/category/file/line order.
- The report gives a one-line overall assessment, reconciler counts, severity-grouped findings, and residual coverage status.
- Critical/Important findings include evidence and a concrete suggestion. Minor findings may be compact unless verbose rendering was requested.
- The report always names `.deep-review/latest-pi.json`; a clean result requires no findings and complete required lens coverage.

## Pi capability boundary

- This port reviews the current worktree diff or one repository-local development plan only; PR-number/URL and `--continue` modes are not supported.
- Workers have no tools and cannot dispatch another worker. The main session prepares bounded, untrusted review material and owns all writes.
- Automated `auto_fix` proposals and application are unsupported. Recommendations are advisory; the skill makes no code or plan edits and never writes a review marker.
