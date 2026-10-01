---
name: skein-review-gauntlet
description: Run Pi-native review gates with visible degraded coverage and isolated fixer workers.
argument-hint: "[--refresh] [--plan <path>]"
---

# Skein Review Gauntlet (Pi)

Invoke with `/skill:skein-review-gauntlet`. This is an opt-in convergence loop;
it never implies Claude, Codex, or security-review availability. The main Pi
session is the top-level orchestrator. It may call the installed deep-review
route, but a fixer is the only child worker and must use the Pi extension's
`skein_worker` tool. A fixer never dispatches another worker or a review lens.

## Capability preflight

Probe each configured gate before the first round and show a status table with
`available`, `unavailable`, `skipped`, or `degraded`. Build a non-secret
fingerprint from the Pi runtime/package revision, gate implementation/version,
and relevant non-secret configuration; never include credentials, prompts, or
model tokens. Use `lib/review_gauntlet.py` and its repository-local,
gitignored capability state. A matching `unavailable` record is reused as a
visible `skipped` outcome naming its stable reason. `--refresh` clears/reprobes
that state.

Only stable absence (`gate_not_installed`, `executable_missing`, or
`skill_not_registered`) may be cached. Do not cache timeout, authentication,
parse, operator-decline, or other process failures. Those are `degraded` for
this run and must be retried on the next run. A corrupt cache is ignored and
replaced only after a fresh stable probe.

If every required gate is unavailable, stop before entering the convergence
loop with `zero_runnable_gates`. This is a visible degraded stop, not approval.
A partial run with skipped or degraded gates is never a clean full-coverage
pass, even when runnable gates return no findings.

## Gate and fixer route

Run only gates whose capability is `available`. Persist one per-run outcome for
every gate, including cached skips. Keep gate envelopes separate and retain
`gate`, `status`, `reason`, findings, and duration. Do not normalize a skipped
or degraded envelope into an approval. The final report must list every gate,
coverage counts, and the exact stop/terminal reason.

Reconcile findings mechanically using the installed Pi review scripts. Do not
accept `auto_fix` blocks in this port. For substantive findings, construct a
`fixer_request()`; pass its returned `prompt` and `role` fields to the Pi
extension's `skein_worker` (the tool accepts only those two fields). The child
returns a validated patch proposal and never writes files. The main session
must inspect the proposal, apply any approved edits, re-read the targets, and
verify the live diff before recording a round. Do not invoke a Claude `Agent`,
Codex `spawn_agent`, `codex`, `gh`, or a nested review skill. Run the
repository's required validation command after approved edits. A worker claim
alone is not evidence that a fix landed.

Record convergence state with `lib/pi_ledger.py` using a repo-local,
mode-0700 guarded ledger. Initialize once per target; resume reads the same
validated target-keyed file, and never overwrites it without an explicit fresh
operation. Append one validated outcome per round, enforce the ten-round cap,
and stop on `zero_runnable`, `degraded`, `partial`, or other terminal states.
The ledger is state only: it does not replace gate reconciliation.

The fixer response must identify each claimed finding, its root cause, the
regression test (or a one-line reason no test applies), and classify the blast
radius as `local` or `structural`. Structural changes restart at gate one;
local changes receive one confirming pass. Preserve skipped coverage as
non-success and never turn it into approval.

## Report contract

Report target/range, selected gates, cached skips, fresh skips, degraded
failures, runnable count, findings, fixer claims, and terminal decision. Use
`clean full coverage` only when every required gate ran successfully and the
full pass has no findings. Otherwise say `partial coverage` or `degraded`.
Never expose credentials or raw worker event streams.
