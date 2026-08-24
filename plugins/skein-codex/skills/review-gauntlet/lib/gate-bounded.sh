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
#   gate_run_bounded <budget-seconds> <envelope-out> <tool-out> -- <cmd...>
#     Runs <cmd...> synchronously with its stdout captured into <tool-out>
#     (stderr into <tool-out>.stderr), enforced against a <budget-seconds>
#     wall-clock budget via process-group kill: GNU/Homebrew
#     `timeout --kill-after` when on PATH (it puts the child in its own
#     process group by default, so the kill signal reaches every
#     descendant), else `gtimeout` (Homebrew's non-default-names alias),
#     else a python3 `os.setsid` + `killpg` shim — this host has neither
#     `setsid(1)` nor a PATH-guaranteed GNU `timeout`. A belt-and-braces
#     `pkill -f 'codex exec review'` sweep runs on expiry only, scoped to
#     the gate's own invocation pattern, in case a descendant escaped the
#     process group via its own setsid/setpgid (R1 ASSUMPTION, unverified
#     beyond this fallback).
#
#     Writes <envelope-out> on EVERY exit path — this is the load-bearing
#     contract: `run-gate.sh normalize` reads ONLY the envelope, never
#     <tool-out> directly, so a half-written or truncated <tool-out> can
#     never be mistaken for a clean pass.
#       - expiry: <tool-out> (and its .stderr sibling) is removed; envelope
#         is {"status":"skipped","notes":"DEGRADED: timeout after <budget>s",
#         "findings":[],"gate":null,"duration_s":<measured>,
#         "degraded_reason":"DEGRADED: timeout after <budget>s"}. `<budget>`
#         (not the measured duration) is embedded in the note text so two
#         runs against the same budget produce a structurally identical
#         envelope modulo `duration_s` itself.
#       - any other exit, <tool-out> holds valid JSON: envelope is that
#         JSON's own object, with {"duration_s":<measured>,
#         "degraded_reason":null} merged in — a tool-reported
#         "approve"/"needs-attention"/"error" status passes through
#         unchanged.
#       - any other exit, <tool-out> missing/empty/invalid JSON (the tool
#         crashed mid-write inside budget): envelope is
#         {"status":"error","notes":"...","findings":[],"gate":null,
#         "duration_s":<measured>,"degraded_reason":null} — never a
#         clean-looking envelope.
#
#     Always returns 0 on a completed run (envelope written) — the
#     envelope's `.status` is the failure signal callers read, via
#     `run-gate.sh normalize`'s exit code, never this function's own return
#     value. Returns 2 only for a usage error (bad arguments) before any
#     command ran.
#
# Dependencies: bash + jq + (GNU/Homebrew `timeout` or `gtimeout`, else
# python3 as the setsid-shim fallback).

gate_run_bounded() {
	if [[ $# -lt 5 ]]; then
		echo "gate_run_bounded: usage: gate_run_bounded <seconds> <envelope-out> <tool-out> -- <cmd...>" >&2
		return 2
	fi
	local seconds="$1" envelope_out="$2" tool_out="$3"
	if [[ "$4" != "--" ]]; then
		echo "gate_run_bounded: expected -- as the 4th argument before <cmd...>" >&2
		return 2
	fi
	shift 4
	if [[ $# -eq 0 ]]; then
		echo "gate_run_bounded: missing <cmd...>" >&2
		return 2
	fi
	if ! command -v jq >/dev/null 2>&1; then
		echo "gate_run_bounded: jq is required" >&2
		return 2
	fi

	rm -f "$tool_out" "${tool_out}.stderr" "$envelope_out"

	local start_ts end_ts duration_s exit_code=0
	start_ts="$(date +%s)"

	if command -v timeout >/dev/null 2>&1; then
		timeout --kill-after=10s "${seconds}s" "$@" >"$tool_out" 2>"${tool_out}.stderr" || exit_code=$?
	elif command -v gtimeout >/dev/null 2>&1; then
		gtimeout --kill-after=10s "${seconds}s" "$@" >"$tool_out" 2>"${tool_out}.stderr" || exit_code=$?
	else
		if ! command -v python3 >/dev/null 2>&1; then
			echo "gate_run_bounded: none of timeout, gtimeout, or python3 is available" >&2
			return 2
		fi
		python3 - "$seconds" "$@" >"$tool_out" 2>"${tool_out}.stderr" <<'PYSHIM' || exit_code=$?
import os
import signal
import subprocess
import sys
import time

budget = float(sys.argv[1])
cmd = sys.argv[2:]

# New session + process group (setsid(1) is absent on this host, so this
# is done in-process) so killpg below reaches every descendant, not just
# the immediate child.
proc = subprocess.Popen(cmd, preexec_fn=os.setsid)
try:
    proc.wait(timeout=budget)
    sys.exit(proc.returncode)
except subprocess.TimeoutExpired:
    try:
        pgid = os.getpgid(proc.pid)
        os.killpg(pgid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    # Grace window for a well-behaved child to exit on SIGTERM; poll
    # instead of a blind sleep so an already-dead group does not add
    # unnecessary wall-clock time on top of the budget.
    grace_deadline = time.monotonic() + 2
    while time.monotonic() < grace_deadline:
        try:
            proc.wait(timeout=0.1)
            break
        except subprocess.TimeoutExpired:
            continue
    else:
        try:
            pgid = os.getpgid(proc.pid)
            os.killpg(pgid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
    sys.exit(124)
PYSHIM
	fi

	end_ts="$(date +%s)"
	duration_s=$((end_ts - start_ts))

	if [[ "$exit_code" -eq 124 ]]; then
		rm -f "$tool_out" "${tool_out}.stderr"
		# Belt-and-braces sweep for a descendant that escaped the process
		# group via its own setsid/setpgid — scoped to the gate's own
		# invocation pattern, never a blanket process kill.
		pkill -f 'codex exec review' >/dev/null 2>&1 || true
		local reason="DEGRADED: timeout after ${seconds}s"
		jq -n \
			--arg reason "$reason" \
			--argjson duration_s "$duration_s" \
			'{status: "skipped", notes: $reason, findings: [], gate: null, duration_s: $duration_s, degraded_reason: $reason}' \
			>"$envelope_out"
		return 0
	fi

	if [[ -s "$tool_out" ]] && jq -e . >/dev/null 2>&1 <"$tool_out"; then
		jq --argjson duration_s "$duration_s" \
			'. + {duration_s: $duration_s, degraded_reason: null}' \
			"$tool_out" >"$envelope_out"
	else
		jq -n \
			--argjson duration_s "$duration_s" \
			'{status: "error", notes: "gate command exited without valid JSON tool-out", findings: [], gate: null, duration_s: $duration_s, degraded_reason: null}' \
			>"$envelope_out"
	fi
	return 0
}
