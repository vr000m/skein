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

## Reconciliation and reporting

- Reconciliation groups by `(file, line, category)`, combines lens provenance, preserves related different-category findings at one location, and uses canonical severity/category/file/line order.
- The report gives a one-line overall assessment, reconciler counts, severity-grouped findings, and residual coverage status.
- Critical/Important findings include evidence and a concrete suggestion. Minor findings may be compact unless verbose rendering was requested.
- The report always names `.deep-review/latest-pi.json`; a clean result requires no findings and complete required lens coverage.

## Pi capability boundary

- This port reviews the current worktree diff or one repository-local development plan only; PR-number/URL and `--continue` modes are not supported.
- Workers have no tools and cannot dispatch another worker. The main session prepares bounded, untrusted review material and owns all writes.
- Automated `auto_fix` proposals and application are unsupported. Recommendations are advisory; the skill makes no code or plan edits and never writes a review marker.
