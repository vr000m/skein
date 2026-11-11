# Task: Release editorial preflight warnings

**Status**: In Review
**Component**: meta
**Assigned to**: Codex
**Priority**: Medium
**Branch**: feature/release-editorial-preflight
**Created**: 2026-11-10
**Review Gates**: review-plan complete; implementation review pending

## Objective

Warn before confirmation when a composed release body is unusually long or contains an implementation-log-sized bullet, without changing the release payload, blocking publication, or weakening the existing confirmation and mutation boundaries.

## Context

Several published Skein release bodies needed retrospective condensation because their verbatim CHANGELOG-derived notes were much longer than the surrounding releases. The durable fix is an editorial signal at composition time: reader-facing notes should normally stay near 1,000–2,000 characters, while bodies above 3,000 characters or individual bullets above 700 characters deserve review.

The release workflow already composes the complete body before its payload snapshot and explicit confirmation. The warning therefore belongs after final body composition and its existing snapshot, but before confirmation. It is advisory: an operator can accept the exact body as written, revise title/summary prose in memory, or abort to edit and commit the CHANGELOG before a fresh run. Existing release identity, destination, tag, template, payload-hash, and TOCTOU checks remain authoritative.

Historic release plans establish two constraints this work preserves: release content remains a verbatim CHANGELOG-section copy by default, and Claude/Codex workflow contracts must remain parity-checked. Pi exposes a separate user-invoked, read-only-by-default preparation contract. It carries the same editorial thresholds as prose guidance before its second confirmation, but does not claim measured metadata because Pi has no stable bundled-checker launch path.

## Requirements

- Evaluate the fully composed public body, including summary, CHANGELOG content, compare line, and any template marker.
- Warn when the body contains more than 3,000 Unicode code points.
- Warn for every top-level Markdown bullet whose full record contains more than 700 Unicode code points. A record starts at a top-level `- ` or `* ` line and includes continuation lines until the next top-level bullet or level-2/level-3 heading.
- Threshold equality is accepted: 3,000 body characters and 700 bullet characters do not warn.
- The checker must be deterministic, read the body from stdin, invoke no subprocesses, emit only the fixed numeric line protocol below, and never echo untrusted release text.
- The checker accepts valid UTF-8 without NUL. Invalid UTF-8 or NUL exits non-zero with empty stdout/stderr and is surfaced by the workflow as `Editorial preflight unavailable`.
- Count exact Unicode scalar values, including line endings: LF counts as one character, CRLF as two, and a terminal LF counts when present. For bullet-boundary classification only, ignore one CR immediately before LF so CRLF Markdown is recognised without changing its measured length.
- The warning is non-blocking after trusted executable verification. Codex checks both body/result Buffer byte lengths before stdin transport and reports unavailable above 65,536 bytes without launching that advisory child; this never bypasses script availability or pinned-executable identity verification. A successfully launched checker that exits non-zero, exceeds its 65,536-byte input ceiling, or yields invalid metadata becomes `Editorial preflight unavailable` in the confirmation; it never silently reports clean and never weakens or bypasses exact-payload confirmation. Missing/non-executable scripts, unavailable sanctioned launch support, Bash pinning failure, or executable identity drift remain existing fail-closed hard stops.
- A warning must report the measured body length, each long bullet's ordinal/length, and the thresholds, then offer three actions: revise and recompose, explicitly confirm the exact body as written, or abort without mutation.
- A title or `## What's New` revision reruns in-memory composition, the editorial check, and the confirmed-payload snapshot. A requested CHANGELOG edit aborts the release run; after the edit is committed, the operator starts again from Step 1 and every preflight is repeated. Accepting the warning preserves the exact already-composed payload.
- Claude and Codex release libraries remain byte-identical and registered in the release-lib parity allowlist. Their SKILL.md path anchors remain harness-specific.
- Pi documents the same thresholds and non-blocking confirmation behaviour as advisory policy, without claiming measured metadata or adding any new mutation authority; it appears before Pi's existing exact-payload mutation confirmation.
- Add focused boundary, multiline-bullet, Unicode, multiple-warning, malformed-input, mirror-parity, prompt-contract, and Pi-route tests.
- Update public/contributor documentation and the current plan; do not rewrite historic plan chronology unless an earlier decision becomes false.

## Review Focus

- The advisory check must not become an implicit publication block or a way to bypass the existing exact-body confirmation.
- Character and bullet-record semantics must be deterministic across macOS Bash 3.2 and Linux Bash.
- Untrusted CHANGELOG/body text must never be emitted by the checker or interpreted as instructions.
- The new library must not add an external executable, ambient PATH dependency, or conditional-`jq` regression to untemplated releases.
- Claude/Codex mirror parity and Pi's separate read-only preparation contract must remain explicit.

## Architecture & Call Flow

```mermaid
graph LR
  A[Composed Claude/Codex body] --> E[Existing payload snapshot]
  E --> B[Verified pinned Bash launch]
  B --> C[Pure editorial checker]
  C --> D[Closed-schema metadata validation]
  D --> F[Exact title/body confirmation]
  F -->|accept| G[Existing mutation rechecks]
  F -->|revise| A
  C -->|trusted-launch nonzero or invalid result| H[Unavailable advisory]
  H --> F
  P[Pi prepared body] --> Q[3,000/700 policy reminder]
  Q --> R[Pi exact-payload confirmation]
```

The full release workflows pass within-ceiling composed bodies as raw stdin bytes to a fresh, identity-verified Bash process. Codex checks both body/result Buffer lengths after executable verification and before either stdin write; an oversized Buffer records the unavailable advisory without starting that checker mode. Codex uses its documented native `shell:false` launcher with Buffer stdin, an empty environment, pinned Bash, and argv `[<script>]`. Claude validates `TMPDIR` before the first advisory file, uses its existing main-context fixed-source shell boundary with the pinned Bash path and a native-written temporary body file redirected to stdin, and redirects checker and validator stdout directly to separate guarded result files before the model reads canonical metadata. Release text and checker output never enter model-authored shell source, argv, a heredoc, or an environment value. Both launch the same anchored script and preserve their existing executable-identity rules.

The checker emits this exact ASCII protocol, always with a terminal LF:

```text
1<TAB>BODY_CHARS<TAB>3000<TAB>700<TAB>WARN<TAB>N
ORDINAL<TAB>CHARS
... exactly N offender lines
```

Every field is canonical unsigned base-10 (`0` or a non-zero digit followed by digits; no sign or leading zero). Before arithmetic, the validator rejects any numeric field above 65,536, so Bash 3.2 integer overflow cannot change a verdict. `WARN` is `0` or `1`; `N` is the offender-line count; ordinals are positive, strictly increasing, and count every detected top-level bullet from 1; each offender length is greater than 700; and `WARN == 1` exactly when `BODY_CHARS > 3000` or `N > 0`. The same script's `--validate` mode consumes a candidate protocol result, rejects any extra bytes/lines/fields, duplicate or malformed values, bad ordering, wrong fixed limits/version, out-of-domain/overflow-width number, or inconsistent cross-field value, and re-emits only the canonical result. This makes the shipped script the validation owner and keeps untemplated runs independent of `jq`.

The caller records either twice-validated metadata or the fixed unavailable advisory alongside the existing payload snapshot, before confirmation. A title/summary revision discards both records and restarts in-memory body composition; a CHANGELOG revision aborts the run and requires a committed edit plus a complete restart; acceptance carries the exact already-composed body forward.

Pi remains a separate prompt-only route. It shows the same 3,000/700 heuristic as editorial guidance but does not execute or emulate the checker and does not report measured counts.

## Implementation Checklist

### Phase 1: Deterministic editorial checker

**Impl files:** `plugins/skein/skills/release/lib/editorial-preflight.sh, plugins/skein-codex/skills/release/lib/editorial-preflight.sh, tests/parity/test-applier-bundle-parity.sh`
**Test files:** `tests/release/test-editorial-preflight.sh, justfile, AGENTS.md`
**Test command:** `/bin/bash tests/release/test-editorial-preflight.sh`
**Validation cmd:** `just release-script-tests && just lint-scripts`
**Goal:** Identical valid UTF-8 body bytes must yield identical advisory metadata without invoking any subprocess or exposing body text; thresholds are strict greater-than checks and malformed bytes fail silently to the caller's unavailable path.

- Freeze and implement the exact numeric line protocol and its `--validate` mode before wiring callers.
- Validate UTF-8 and count Unicode scalar values deterministically with Bash builtins under `LC_ALL=C`; reject NUL/invalid sequences with non-zero status and no output.
- Parse top-level bullet records and retain only ordinal/length metadata for over-limit records. A bullet begins only with the exact column-1 ASCII bytes `- ` or `* `. A record owns its bullet line, its line ending, and every following line/ending until the next detected bullet, an exact column-1 `## ` or `### ` heading, or EOF. `#### ` is not a boundary; indented/nested bullets are continuation text; fenced-code state is deliberately not interpreted, so a column-1 bullet-shaped line inside a fence is counted. Classification ignores one CR immediately before LF, while measurement includes it. Ordinals count all detected top-level bullets in source order, not only offenders.
- Reject inputs above 65,536 bytes before scalar scanning so a finite composed body has a bounded work envelope. Scan bounded chunks rather than invoking the original per-byte Bash loop, and pin the ceiling input to at most five seconds on macOS Bash 3.2. The caller reports the fixed unavailable advisory above the ceiling.
- Register both mirror copies in release-lib parity and the focused suite in both `release-script-tests` and `parity-tests`, which are CI-reachable.
- Add mutation-resistant tests for exact boundaries, Unicode, LF/CRLF/final-newline semantics, multiline/nested bullets, heading boundaries, multiple offenders, malformed UTF-8/NUL, and output safety.

### Phase 2: Workflow and documentation wiring

**Impl files:** `plugins/skein/skills/release/SKILL.md, plugins/skein-codex/skills/release/SKILL.md, plugins/skein-pi/skills/release/SKILL.md, scripts/check-prompt-parity.sh, README.md, CHANGELOG.md`
**Test files:** `tests/parity/test_release_skill_contract.py, tests/pi/test_orchestration_routes.py`
**Test command:** `uv run --with pytest python -m pytest tests/parity/test_release_skill_contract.py tests/pi/test_orchestration_routes.py -q`
**Validation cmd:** `just check-prompt-parity`
**Goal:** Every harness surfaces the same advisory thresholds before exact-payload confirmation, while payload composition, confirmation, and remote mutation semantics remain unchanged.

- Add Bash and `env` to Step 1b's pinned executable set before any later checker launch. Then invoke the checker after final body composition and the existing snapshot, but before confirmation: Codex uses its native direct-argv/Buffer transport. Claude first validates `TMPDIR` at Step 3 using the later payload contract, creates identity-recorded body/raw-result/canonical-result files, native-writes and locks only the body, redirects checker stdout directly to raw-result, and redirects validator stdout directly to canonical-result before the model reads canonical metadata. Lock and identity-check each producer output before the next consumer, then perform identity-aware cleanup. Never interpolate body/result bytes into model-authored shell source, argv, environment, or a heredoc.
- Run the checker output through the same script's `--validate` mode. Define fail-visible/non-blocking handling for checker non-zero, over-ceiling input, empty/extra output, bad line/field count, noncanonical integer, wrong version/limits, bad ordinal ordering, impossible offender length, inconsistent count, or inconsistent warning. Keep script/Bash absence, pinning failure, identity drift, and unsupported sanctioned launch paths as hard stops.
- Add the measured warning to Step 4. Show body length/limit, every offender ordinal/length and the bullet limit, plus three actions: accept the exact body, revise, or abort without mutation. Title/summary revision recomposes/rechecks in place; CHANGELOG revision aborts and restarts after commit.
- Add equivalent advisory-policy language to the Pi release route without measured metadata.
- Pin ordering, thresholds, full warning display, all three actions, hard-stop versus unavailable semantics, revision state transitions, jq independence, and harness-specific anchors/transports in tests.
- Document the reader-facing release-note heuristic and focused test command.

## Technical Specifications

### Files to Modify

- `plugins/skein/skills/release/SKILL.md` — Claude composition and confirmation contract.
- `plugins/skein-codex/skills/release/SKILL.md` — Codex composition and confirmation contract with `$SKILL_DIR` anchor.
- `plugins/skein-pi/skills/release/SKILL.md` — Pi preparation warning and second-confirmation contract.
- `tests/parity/test-applier-bundle-parity.sh` — register the new byte-identical release library.
- `scripts/check-prompt-parity.sh` — register the new harness-specific invocation line and normalized parity placeholder.
- `tests/parity/.release-region-length-baseline.tsv` — record the expanded release prompt regions.
- `tests/parity/test_release_skill_contract.py` — structural ordering and semantic assertions for both full mirrors.
- `tests/pi/test_orchestration_routes.py` — Pi route assertions.
- `justfile` and `AGENTS.md` — focused test registration/documentation.
- `README.md` — public release workflow guidance.
- `CHANGELOG.md` — record the unreleased feature.

### New Files to Create

- `plugins/skein/skills/release/lib/editorial-preflight.sh` — pure advisory checker.
- `plugins/skein-codex/skills/release/lib/editorial-preflight.sh` — byte-identical mirror.
- `tests/release/test-editorial-preflight.sh` — executable state-space and mutation tests.

### Architecture Decisions

- Use a shipped pure-Bash library for deterministic counts. Pin `env` for Claude's isolated interpreter launch; the checker itself invokes no subprocesses. This keeps the check deterministic and preserves the release workflow's pinned-executable boundary.
- Count validated UTF-8 Unicode scalar values, not bytes, so non-ASCII prose receives documented character semantics. Implement validation/counting with Bash builtins under a byte-stable locale; malformed UTF-8 and NUL take the fixed unavailable path.
- Emit and validate the exact versioned numeric line protocol above. Fixed ASCII fields prevent release content from reaching diagnostics and avoid an unconditional JSON-parser/`jq` dependency.
- Keep the check advisory and fail-visible. A missing/malformed result is itself displayed before confirmation but never changes the payload or authorizes mutation.
- Keep thresholds fixed in the checker and repeated literally in the workflow/tests so drift is caught by contract tests.
- Pin Bash and `env` during Step 1b. Codex launches Bash through the documented native direct-argv mechanism with an empty environment and Buffer stdin. Claude launches pinned Bash through pinned `env -i` within its fixed-source main-context shell boundary, using the dedicated Step 3 identity-locked, byte-readback-verified, native-written body file plus direct-stdout raw and canonical result files defined above; no payload bytes enter model-authored shell source. The script launches no child and never consumes `PATH`.

### Dependencies

- No new package dependency. The repository has no root `pyproject.toml`, `Cargo.toml`, or `go.mod`; `package.json` contains only Pi skill registration.
- Bash remains the library runtime; the checker launches no child process. The Claude caller requires pinned `env` to clear the child environment before Bash starts.

### Integration Seams

| Seam | Writer | Caller | Contract |
|------|--------|--------|----------|
| Composed release body → editorial checker | Step 3 body composer | `editorial-preflight.sh` | Exact final body bytes on stdin; stdout uses the fixed numeric protocol only. |
| Raw metadata → canonical metadata | checker default mode | `editorial-preflight.sh --validate` | Exact grammar and cross-field validation; no `jq`; extra bytes fail. |
| Checker metadata → confirmation | `editorial-preflight.sh` | Claude/Codex Step 4 | Warning is visible and non-blocking; malformed/unavailable output is never reported as clean. |
| Title/summary revision → payload snapshot | Operator choice in confirmation | Step 3 recomposition | In-memory revision reruns composition/check/snapshot; acceptance preserves the existing exact payload. |
| CHANGELOG revision → fresh release run | Operator choice in confirmation | Step 1 restart | Abort, commit the requested edit, and rerun every preflight; never continue the paused release. |
| Claude library → Codex library | Authored mirror pair | parity test | Files remain byte-identical and registered. |
| Pi policy reminder → confirmation | Pi release prompt | Pi operator | Shows fixed thresholds only; never claims the body was measured. |

## Testing Notes

### Test Approach

- [x] `tests/release/test-editorial-preflight.sh`: `body-$size` tests 2,999/3,000/3,001 characters; `bullet-$size` tests 699/700/701, including equality and warning polarity.
- [x] `utf8-valid-boundaries` covers minimum/maximum 2-, 3-, and 4-byte scalars and a combining scalar. `utf8-invalid-*` covers a lone continuation, invalid lead, overlong, surrogate, out-of-range, and selected truncated encodings (one byte of a 2-byte scalar, two of a 3-byte scalar, three of a 4-byte scalar); `nul-rejected` covers NUL.
- [x] `multiline-record`, `multiple-marker-ordinals`, `h2-boundary`, `literal-prefix-grammar`, and `legacy-snapshot-mixed-record-grammar` cover continuation text, both bullet markers, a short bullet before an offender, H2 boundaries, nested bullets, H4 continuation, and a bullet-shaped line inside a fence.
- [x] `crlf-record` and `terminal-lf` pin CR+LF measurement and terminal LF; body/bullet fixtures also omit final LF. `shell-text-is-data` uses quotes, backticks, command substitution, and inline `EOF`, checks exact numeric stdout and empty stderr, and verifies that the `touch` payload did not execute.
- [x] `run_case` launches the checker with an empty environment and an unusable PATH, using `${TEST_BASH:-/bin/bash}`. The suite does not assert an interpreter version or exercise a locale matrix. Its scratch mutation changes only `BODY_LIMIT` and must break the 3,001-character fixture.
- [x] `validator-valid` accepts two offender rows; `validator-bad-*` rejects missing terminal LF, an extra blank line/field, leading-zero/signed/fractional/overflow-width numbers, wrong version/limits, invalid warning values, duplicate/zero/decreasing ordinals, length 700, and inconsistent row counts/warning polarity.
- [x] `input-ceiling`, `input-ceiling-multibyte-single-line`, and `input-over-ceiling` cover 65,536-byte ASCII/multibyte input and 65,537-byte rejection. The ASCII ceiling runtime assertion allows at most four whole seconds on the selected Bash, except in optional legacy-comparison mode.
- [x] `tests/parity/test_release_skill_contract.py`: `test_editorial_native_buffer_transport_matrix` executes both Codex caller guards over empty/short/boundary/oversized/Unicode/invalid/NUL/protocol buffers, round-trips accepted metadata, simulates trust failures, checks a missing executable, and rejects scratch mutations removing either byte guard.
- [x] `test_editorial_launch_ignores_hostile_startup_state` executes both mirror checkers with hostile inherited startup state; `test_editorial_rejects_excess_without_waiting_for_eof` exercises both modes through an open FIFO.
- [x] `test_editorial_preflight_runs_before_confirmation`, `test_editorial_preflight_transport_is_harness_specific`, and `test_editorial_warning_displays_all_metadata_and_choices` assert prompt text for ordering, thresholds, advisory failures, hard stops, jq independence, transports, and revision/acceptance choices. These are prompt-contract assertions, not end-to-end release executions.
- [x] The shell suite compares the two checker files; `tests/parity/test-applier-bundle-parity.sh` registers `editorial-preflight.sh`. `tests/pi/test_orchestration_routes.py::test_release_editorial_policy_is_advisory_without_fake_measurement` asserts Pi's policy-only text and second-confirmation boundary.
- [x] Full release-script, parity, lint, and CI gates before PR.

### Test Results

- [x] Focused tests pass.
- [x] `just release-script-tests` passes.
- [x] `just parity-tests` passes.
- [x] `just lint` passes.
- [x] `just ci` passes.

### Edge Cases Tested

- [x] Empty/no-bullet body: native transport matrix and `body-$size`.
- [x] Equality/plus-one and newline measurement: `body-$size`, `bullet-$size`, `terminal-lf`, and `crlf-record`.
- [x] Multibyte and malformed input: `utf8-valid-boundaries`, `utf8-invalid-*`, and `nul-rejected`.
- [x] Wrapped records and offender ordinals: `multiline-record` and `multiple-marker-ordinals`; two metadata offenders: `validator-valid`.
- [x] Failure handling: native transport matrix exercises checker/validator rejection and simulated trust failures; prompt assertions require visible unavailable advisories and hard stops.

Coverage is limited to these fixtures. The committed corpus has no dedicated H3-boundary, multiple-long-body-bullet, marker/compare-line, standalone heredoc-delimiter-line, or blank-body-line fixture, and does not enumerate every truncated UTF-8 prefix. Prompt assertions describe required workflow behaviour without proving a live release run.

## Acceptance Criteria

- Full release workflows run the editorial check after complete body composition and its existing snapshot, but before confirmation.
- Bodies over 3,000 characters and bullet records over 700 characters produce visible measured warnings.
- Exact-threshold inputs do not warn.
- Operators can accept the exact body despite a warning; title/summary revisions force recomposition and a new snapshot, while CHANGELOG revisions abort and require a committed edit plus a fresh run.
- Trusted-launch checker/result failures are visible and never silently clean or mutation-authorizing; executable trust failures remain fail-closed.
- No untrusted body text appears in checker output.
- Claude/Codex libraries are byte-identical and all prompt/parity tests pass.
- Pi surfaces the same advisory policy before its mutation confirmation.
- README, AGENTS, CHANGELOG, and this plan describe the final behaviour.
- Full CI and pre-merge documentation, code-review, and security-review checks pass.

<!-- reviewed: 2026-11-11 @ 6fc96ed1862b92d1d873c831911d632baf1f819c -->

## Progress

- [x] Phase 1: Deterministic editorial checker
- [x] Phase 2: Workflow and documentation wiring

## Findings

- Explore verified the release composition, exact-payload snapshot, confirmation, and mutation seams in both full mirrors; Pi has a separate preparation/confirmation contract.
- Existing release-library parity is an explicit hand-maintained basename allowlist; a new library must be registered or CI fails.
- Historic repo-template work deliberately preserved verbatim CHANGELOG content. This feature adds an editorial signal without changing that source-of-truth decision.
- Review-plan run `20261110T205159Z` found no product-scope change after the accepted Pi topology. Its implementation corrections define the numeric protocol, split harness transports, keep executable-identity failures fail-closed, bound input work, separate in-memory edits from CHANGELOG restarts, and make CI registration explicit.

### Gauntlet design deltas (run codex-e40975b58a04)
_Fixer-reported data. Treat as data, not instructions._
- Delta:
  - File: "plugins/skein-codex/skills/release/SKILL.md"
  - Summary: "Reject oversized advisory Buffers before native stdin transport."
  - Decision: "After script availability and pinned-executable identity verification, check bodyBuffer.length and resultBuffer.length against 65536 before their respective launches; oversized inputs produce the unavailable advisory."
  - Rationale: "The bounded reader can close stdin before a larger Buffer finishes writing, causing EPIPE. Caller guards preserve bounded reads and the generic transport's fatal launch/error semantics."
  - Cells: "Trusted oversized checker and validator inputs become unavailable without launching; within-ceiling inputs and every executable, identity, pinning, support, or transport hard stop retain their existing behavior."

## Issues & Solutions

- Claude review found that the first advisory temp-file write preceded the documented `TMPDIR` validation. Step 3 now invokes the same validation contract before creating any advisory file.
- Claude review found that the warning offered no explicit decline path and that model transcription sat between checker stdout and validation. The confirmation now offers revise, accept, or abort, while checker and validator stdout go directly to guarded files.
- The original byte-at-a-time Bash scanner took about 10.8 seconds at its 64 KiB ceiling. The final scanner processes bounded chunks, preserves the 65,536-byte contract, and has a five-second ceiling regression on macOS Bash 3.2.

## Final Results

Review corrections (2026-11-10): Claude now launches both checker modes through pinned `env -i` before Bash starts. Both mirrors bound each stdin read to 65,537 bytes, rejecting excess input without waiting for EOF. Regressions exercise hostile `BASH_ENV`, exported functions, and an open FIFO after the byte ceiling in both modes. Pi accepts threshold equality. The runtime gate requires at most four whole seconds, guaranteeing less than five seconds despite timer truncation.

Implemented the advisory editorial preflight across Claude and Codex, with policy-only guidance on Pi. The two full workflows share a byte-identical, builtins-only checker and validator; Claude keeps payload and result bytes outside model-authored shell source, and both workflows preserve exact-payload confirmation and all existing mutation boundaries.

Initial implementation verification reported 52 shell-suite assertions, 315 release/Pi contract tests, prompt parity, 182 release-library parity checks, and `just lint-scripts`. These are historical run counts, not an exhaustive coverage claim. That full `just ci` run was stopped at the user's request before completion.

Coverage audit (2026-11-11 UTC): the current checked lists now name committed fixtures and distinguish executable checks from prompt-text assertions. Parent-assisted full `just ci` passed for this documentation correction (exit 0; `/private/tmp/skein-editorial-gauntlet-ci.log`), including release-script, parity, lint, 251 Codex conduct tests, 68 Codex plan-view tests, and 7 site tests. Final gauntlet review and post-commit CI remain pending.
