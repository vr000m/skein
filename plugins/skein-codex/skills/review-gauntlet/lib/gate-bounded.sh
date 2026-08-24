#!/usr/bin/env bash
# gate-bounded.sh — harness-neutral wall-clock budget enforcement for an
# external review gate (Codex CLI today; any future subprocess-based gate
# tomorrow). Lives in review-gauntlet's lib/ dir in BOTH plugin mirrors,
# byte-identical (GAUNTLET_LIB_PARITY_FILES in
# tests/parity/test-applier-bundle-parity.sh) — unlike gauntlet-common.sh,
# which legitimately diverges per harness (it resolves a harness-specific
# plugin-root anchor), this file has no harness-specific anchor to resolve,
# so both copies are the same file and stay that way.
#
# Source this file; it does not run on its own (no top-level side effects).
# Never uses `exit` — only `return` — since it runs inside the caller's
# shell.
#
# Provides:
#   gate_run_bounded [--gate <name>] <budget-seconds> <envelope-out> <tool-out> -- <cmd...>
#     Runs <cmd...> synchronously with its stdout captured into <tool-out>
#     (stderr into <tool-out>.stderr), enforced against a <budget-seconds>
#     wall-clock budget (must be a positive integer, >= 1; see Returns
#     below) via process-group kill: GNU/Homebrew `timeout --kill-after`
#     when on PATH (it puts the child in its own process group by default,
#     so the kill signal reaches every descendant), else `gtimeout`
#     (Homebrew's non-default-names alias), else a python3 `os.setsid` +
#     `killpg` shim — this host has neither `setsid(1)` nor a
#     PATH-guaranteed GNU `timeout`. Both runners share one grace window
#     (`kill_after_s`, 10s) between SIGTERM and SIGKILL escalation, and
#     both report the same exit-code alphabet for the two ways a bounded
#     run can end: 124 if the child exited during the grace window after
#     SIGTERM, 137 if the grace window expired and the group had to be
#     SIGKILLed. Expiry is NOT inferred from that alphabet: an exit code is
#     something the reviewed command itself can choose, and a gate that
#     merely exits 124 inside its budget is a normal completed run whose
#     tool-out must be kept. Expiry comes from the RUNNER's own recorded
#     state instead — the python3 shim writes `TIMEOUT` into a sidecar
#     state file on its `TimeoutExpired` path only — falling back to
#     measured wall clock (`duration_s >= seconds`) for the GNU/Homebrew
#     `timeout` path, where a real timeout always consumed the budget. A
#     killed child can never exit 0, so the `exit_code != 0` guard still
#     protects a legitimately successful run that finishes exactly at the
#     budget boundary (integer `date +%s` truncation) from misclassification.
#
#     On expiry, a pgid-scoped sweep (`_gate_sweep_pgid`, below) TERMs then
#     KILLs any survivor left in the child's own process group — recorded
#     into a sidecar file by whichever runner launched the child, so both
#     paths hand bash the same fact through the same channel. The sweep
#     never touches any process outside that group: a descendant that
#     escaped the group via its own setsid/setpgid is out of scope by
#     construction (R1 ASSUMPTION; the dogfood step's manual `pgrep -f
#     'codex exec'` orphan check is the detection path for that case, not
#     an automatic kill).
#
#     Writes <envelope-out> on EVERY exit path — this is the load-bearing
#     contract: `run-gate.sh normalize` reads ONLY the envelope, never
#     <tool-out> directly, so a half-written or truncated <tool-out> can
#     never be mistaken for a clean pass.
#
#     Optional leading `--gate <name>`: when supplied, `.gate` is set to
#     `<name>` on ALL THREE write paths below, overriding whatever the tool
#     itself may have self-reported in its own JSON — the orchestrator is
#     authoritative on slot identity, since it (not the tool) knows which
#     gate slot this invocation fills, including on the expiry/error paths
#     where the tool never got a chance to self-report at all. When omitted,
#     behaviour is byte-identical to before this flag existed: the clean
#     path passes through whatever `.gate` the tool's own JSON carried (or
#     omits it), and the expiry/error paths stamp `gate: null` same as always.
#       - expiry: <tool-out> (and its .stderr sibling) is removed; envelope
#         is {"status":"skipped","notes":"DEGRADED: timeout after <budget>s",
#         "findings":[],"gate":<name-or-null>,"duration_s":<measured>,
#         "degraded_reason":"DEGRADED: timeout after <budget>s"}. `<budget>`
#         (not the measured duration) is embedded in the note text so two
#         runs against the same budget produce a structurally identical
#         envelope modulo `duration_s` itself.
#       - any other exit, <tool-out> holds a JSON object with a string
#         `.status` AND an array `.findings`: envelope is that JSON's own
#         object, with
#         {"duration_s":<measured>,"degraded_reason":null} merged in — a
#         tool-reported "approve"/"needs-attention"/"error" status passes
#         through unchanged. This is exactly `run-gate.sh normalize`'s own
#         precondition (`.status // empty`, else exit 2), so a value that
#         would fail normalize never reaches it: valid-but-non-object JSON
#         (e.g. `[1,2]`), an object with no `.status`, and an object whose
#         `.status` is `null`/non-string all fall through to the error
#         envelope below instead of passing through as a zero-byte or
#         unreadable envelope. `.findings` must additionally be a real
#         array: `normalize` reads `.findings[]?`, and the `?` silently
#         swallows a null/non-array field, so without this leg a malformed
#         gate reported as CLEAN ("zero findings") rather than as an error.
#         Accepted therefore means: normalize can read `.status` AND "zero
#         findings" means zero findings rather than an unreadable field.
#         When `--gate <name>` is supplied, `.gate` is overwritten with
#         `<name>` even on this clean path, superseding whatever the tool
#         itself reported.
#       - any other exit, <tool-out> missing/empty/not a JSON object with a
#         string `.status` and an array `.findings` (the tool crashed
#         mid-write inside budget, or emitted a shape normalize can't
#         read): envelope is
#         {"status":"error","notes":"...","findings":[],"gate":<name-or-null>,
#         "duration_s":<measured>,"degraded_reason":null} — never a
#         clean-looking envelope. <tool-out> itself is retained on this
#         branch as the only debugging artefact for a mid-write crash.
#
#     Always returns 0 on a completed run (envelope written) — the
#     envelope's `.status` is the failure signal callers read, via
#     `run-gate.sh normalize`'s exit code, never this function's own return
#     value. Returns 2 only for a usage error (bad arguments, including a
#     <budget-seconds> below 1) before any command ran — no envelope is
#     written on this path, and any stale envelope already at
#     <envelope-out> from a previous round is removed first, so a return-2
#     caller that ignores the return value never reads a stale result as
#     fresh.
#
# Dependencies: bash + jq + (GNU/Homebrew `timeout` or `gtimeout`, else
# python3 as the setsid-shim fallback).

# _gate_sweep_pgid <pgid> — TERM then (after a 5s grace, polled) KILL every
# survivor in process group <pgid>, except this shell's own pid. Called
# only from the expiry branch of gate_run_bounded, never elsewhere.
#
# Four independent guards narrow a wrong kill to a residual race that is
# NOT closable in portable shell (see the last paragraph) — the earlier
# claim that a wrong kill is "structurally impossible" over-stated it:
#   - <pgid> must be numeric and > 1 (never "my group", never init);
#   - <pgid> must differ from this shell's own process group (the exact
#     hazard a background job inherits the caller's pgid);
#   - the group LEADER must still be alive and still be the recorded pid —
#     i.e. `pgrep -g <pgid>` must list <pgid> itself. `wait` reaps the
#     timeout/shim child before the expiry branch runs, so without this
#     guard the recorded pgid is a freed pid that the OS may already have
#     reassigned;
#   - this shell's own pid is filtered out of whatever `pgrep -g` returns.
#
# If the recorded pgid is empty, not a real group leader (e.g. `timeout`
# were ever run with `--foreground`, or a non-GNU `timeout` failed to
# create a group), the leader is already gone (the common post-
# `--kill-after` case), or any probe command fails, this is a silent no-op
# — it degrades to silence, never to a wrong kill and never to an aborted
# expiry branch.
#
# RESIDUAL RACE (not closable here): between the leader-liveness probe and
# the `kill`, the OS could in principle recycle <pgid> onto an unrelated
# new group leader. Closing that would need a pidfd/process-handle API that
# portable bash does not have. It is documented rather than claimed away.
_gate_sweep_pgid() {
	local pgid="$1" self_pgid survivors
	[[ "$pgid" =~ ^[0-9]+$ ]] || return 0
	((pgid > 1)) || return 0
	# `|| true`: this is a PIPELINE, and the function runs under the
	# caller's `set -euo pipefail`. A `ps` EPERM (macOS sandbox) would make
	# the assignment non-zero and `set -e` would abort this function — and
	# with it the whole expiry branch, BEFORE the `skipped` envelope was
	# written. The next line already treats an empty value as "unknown,
	# proceed", so this is semantically a no-op that removes the abort.
	self_pgid="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ' || true)"
	[[ -n "$self_pgid" && "$pgid" == "$self_pgid" ]] && return 0
	# Fourth guard: the recorded pid must still BE the live group leader.
	pgrep -g "$pgid" 2>/dev/null | grep -qx "$pgid" || return 0
	survivors="$(pgrep -g "$pgid" 2>/dev/null | grep -vx "$$" || true)"
	[[ -n "$survivors" ]] || return 0
	# shellcheck disable=SC2086
	kill -TERM $survivors 2>/dev/null || true
	local _i
	for _i in 1 2 3 4 5; do
		survivors="$(pgrep -g "$pgid" 2>/dev/null | grep -vx "$$" || true)"
		[[ -n "$survivors" ]] || return 0
		sleep 1
	done
	# shellcheck disable=SC2086
	kill -KILL $survivors 2>/dev/null || true
}

gate_run_bounded() {
	local gate_name=""
	if [[ "${1:-}" == "--gate" ]]; then
		if [[ $# -lt 2 ]]; then
			echo "gate_run_bounded: --gate requires a <name> argument" >&2
			return 2
		fi
		gate_name="$2"
		shift 2
	fi

	if [[ $# -lt 5 ]]; then
		echo "gate_run_bounded: usage: gate_run_bounded [--gate <name>] <seconds> <envelope-out> <tool-out> -- <cmd...>" >&2
		return 2
	fi
	local seconds="$1" envelope_out="$2" tool_out="$3"
	if [[ "$4" != "--" ]]; then
		echo "gate_run_bounded: expected -- as the 4th argument before <cmd...>" >&2
		return 2
	fi

	# Unlink any stale envelope/tool-out from a previous round as soon as
	# the paths are known — every remaining check below can fail and
	# `return 2`, and a return-2 must never leave a previous round's
	# (possibly clean) envelope sitting at $envelope_out for a caller that
	# ignores the return value to misread as this round's result.
	rm -f "$tool_out" "${tool_out}.stderr" "$envelope_out"

	shift 4
	if [[ $# -eq 0 ]]; then
		echo "gate_run_bounded: missing <cmd...>" >&2
		return 2
	fi
	if ! [[ "$seconds" =~ ^[0-9]+$ ]] || ((10#$seconds < 1)); then
		echo "gate_run_bounded: <seconds> must be a positive integer (>= 1); got '$seconds'" >&2
		return 2
	fi
	if ! command -v jq >/dev/null 2>&1; then
		echo "gate_run_bounded: jq is required" >&2
		return 2
	fi

	# Shared grace window between SIGTERM and SIGKILL escalation, used by
	# both the GNU/Homebrew `timeout` path (`--kill-after`) and the
	# python3 shim path — same promise, same timing, both paths.
	local kill_after_s=10

	local pgid_file state_file
	pgid_file="$(mktemp)"
	# The runner's OWN record of why the run ended. Only the python3 shim's
	# TimeoutExpired path writes to it; everything else leaves it empty.
	state_file="$(mktemp)"

	local start_ts end_ts duration_s exit_code=0
	start_ts="$(date +%s)"

	if command -v timeout >/dev/null 2>&1; then
		# Backgrounded (not foreground) so `$!` is observable: GNU
		# `timeout` without `--foreground` calls setpgid(0,0) on itself,
		# so its own pid *is* the child process-group id. `wait`
		# propagates its exit status unchanged.
		timeout --kill-after="${kill_after_s}s" "${seconds}s" "$@" >"$tool_out" 2>"${tool_out}.stderr" &
		local gate_pid=$!
		printf '%s' "$gate_pid" >"$pgid_file"
		wait "$gate_pid" || exit_code=$?
	elif command -v gtimeout >/dev/null 2>&1; then
		gtimeout --kill-after="${kill_after_s}s" "${seconds}s" "$@" >"$tool_out" 2>"${tool_out}.stderr" &
		local gate_pid=$!
		printf '%s' "$gate_pid" >"$pgid_file"
		wait "$gate_pid" || exit_code=$?
	else
		if ! command -v python3 >/dev/null 2>&1; then
			rm -f "$pgid_file" "$state_file"
			echo "gate_run_bounded: none of timeout, gtimeout, or python3 is available" >&2
			return 2
		fi
		python3 - "$pgid_file" "$state_file" "$seconds" "$kill_after_s" "$@" >"$tool_out" 2>"${tool_out}.stderr" <<'PYSHIM' || exit_code=$?
import os
import signal
import subprocess
import sys
import time

pgid_file = sys.argv[1]
state_file = sys.argv[2]
budget = float(sys.argv[3])
kill_after = float(sys.argv[4])
cmd = sys.argv[5:]

# New session + process group (setsid(1) is absent on this host, so this
# is done in-process) so killpg below reaches every descendant, not just
# the immediate child.
proc = subprocess.Popen(cmd, preexec_fn=os.setsid)
try:
    pgid = os.getpgid(proc.pid)
    with open(pgid_file, "w") as f:
        f.write(str(pgid))
except ProcessLookupError:
    pass

try:
    proc.wait(timeout=budget)
    sys.exit(proc.returncode)
except subprocess.TimeoutExpired:
    # The runner's own record that THIS is a budget expiry. bash reads it
    # instead of guessing from an exit code the child could have chosen.
    try:
        with open(state_file, "w") as f:
            f.write("TIMEOUT")
    except OSError:
        pass
    try:
        pgid = os.getpgid(proc.pid)
        os.killpg(pgid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    # Grace window for a well-behaved child to exit on SIGTERM; poll
    # instead of a blind sleep so an already-dead group does not add
    # unnecessary wall-clock time on top of the budget. Mirrors GNU
    # `timeout --kill-after`'s exit-code alphabet: 124 if the child died
    # during the grace window, 137 if the group had to be SIGKILLed.
    escalated = False
    grace_deadline = time.monotonic() + kill_after
    while time.monotonic() < grace_deadline:
        try:
            proc.wait(timeout=0.1)
            break
        except subprocess.TimeoutExpired:
            continue
    else:
        escalated = True
        try:
            pgid = os.getpgid(proc.pid)
            os.killpg(pgid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
    sys.exit(137 if escalated else 124)
PYSHIM
	fi

	end_ts="$(date +%s)"
	duration_s=$((end_ts - start_ts))

	# Expiry predicate. `expired` iff the command exited non-zero AND either
	# the RUNNER recorded a timeout (the python3 shim's TimeoutExpired path
	# is the only writer of `$state_file`) or the measured wall clock
	# reached the budget.
	#
	# The old predicate also treated a bare `exit_code == 124` as expiry.
	# That is wrong: 124 is a value the reviewed command itself can return,
	# so an in-budget gate exiting 124 had its valid tool-out deleted and a
	# degraded `skipped` envelope emitted in place of its real result.
	# Dropping that clause loses nothing on the GNU/Homebrew `timeout` path,
	# where a genuine timeout always satisfies `duration_s >= seconds`; a
	# fast `exit 124` no longer can. Neither is 137 in any literal-code set:
	# it is also what an in-budget OOM kill looks like, and the duration
	# clause correctly classifies that as `error`.
	#
	# `10#` on both operands: `seconds` is only validated as `^[0-9]+$`, so
	# a zero-padded budget like `060` would otherwise be an octal parse
	# error inside `(( ))` (same hazard as lens-budget.sh's).
	local expired=0 runner_state=""
	[[ -s "$state_file" ]] && runner_state="$(cat "$state_file" 2>/dev/null || true)"
	if [[ "$exit_code" -ne 0 ]] && { [[ "$runner_state" == "TIMEOUT" ]] || ((10#$duration_s >= 10#$seconds)); }; then
		expired=1
	fi

	if [[ "$expired" -eq 1 ]]; then
		rm -f "$tool_out" "${tool_out}.stderr"
		local pgid=""
		[[ -s "$pgid_file" ]] && pgid="$(cat "$pgid_file")"
		_gate_sweep_pgid "$pgid"
		rm -f "$pgid_file" "$state_file"
		local reason="DEGRADED: timeout after ${seconds}s"
		jq -n \
			--arg reason "$reason" \
			--argjson duration_s "$duration_s" \
			--arg gate_name "$gate_name" \
			'{status: "skipped", notes: $reason, findings: [], gate: (if ($gate_name | length) > 0 then $gate_name else null end), duration_s: $duration_s, degraded_reason: $reason}' \
			>"$envelope_out"
		return 0
	fi

	rm -f "$pgid_file" "$state_file"

	# G3: `.findings` must be a real array, not merely present-and-ignorable.
	# `run-gate.sh normalize` reads `.findings[]?`; the `?` swallows a
	# null/non-array field, so a malformed gate used to report as clean.
	if [[ -s "$tool_out" ]] && jq -e 'type == "object" and (.status | type) == "string" and (.findings | type) == "array"' \
		>/dev/null 2>&1 <"$tool_out"; then
		jq --argjson duration_s "$duration_s" \
			--arg gate_name "$gate_name" \
			'. + {duration_s: $duration_s, degraded_reason: null} + (if ($gate_name | length) > 0 then {gate: $gate_name} else {} end)' \
			"$tool_out" >"$envelope_out"
	else
		jq -n \
			--argjson duration_s "$duration_s" \
			--arg gate_name "$gate_name" \
			'{status: "error", notes: "gate command exited without a valid JSON object tool-out (expected an object with a string .status and an array .findings)", findings: [], gate: (if ($gate_name | length) > 0 then $gate_name else null end), duration_s: $duration_s, degraded_reason: null}' \
			>"$envelope_out"
	fi
	return 0
}
