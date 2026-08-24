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
#     SIGKILLed. Expiry is inferred from that alphabet plus measured wall
#     clock (see the `expired` predicate below), not from a single
#     sentinel exit code — a killed child can never exit 0, so a
#     legitimately successful run that happens to finish exactly at the
#     budget boundary is never misclassified.
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
#         `.status`: envelope is that JSON's own object, with
#         {"duration_s":<measured>,"degraded_reason":null} merged in — a
#         tool-reported "approve"/"needs-attention"/"error" status passes
#         through unchanged. This is exactly `run-gate.sh normalize`'s own
#         precondition (`.status // empty`, else exit 2), so a value that
#         would fail normalize never reaches it: valid-but-non-object JSON
#         (e.g. `[1,2]`), an object with no `.status`, and an object whose
#         `.status` is `null`/non-string all fall through to the error
#         envelope below instead of passing through as a zero-byte or
#         unreadable envelope. When `--gate <name>` is supplied, `.gate` is
#         overwritten with `<name>` even on this clean path, superseding
#         whatever the tool itself reported.
#       - any other exit, <tool-out> missing/empty/not a JSON object with a
#         string `.status` (the tool crashed mid-write inside budget, or
#         emitted a shape normalize can't read): envelope is
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
# only from the expiry branch of gate_run_bounded, never elsewhere. Three
# independent guards make a wrong kill structurally impossible:
#   - <pgid> must be numeric and > 1 (never "my group", never init);
#   - <pgid> must differ from this shell's own process group (the exact
#     hazard a background job inherits the caller's pgid);
#   - this shell's own pid is filtered out of whatever `pgrep -g` returns.
# If the recorded pgid is empty, not a real group leader (e.g. `timeout`
# were ever run with `--foreground`, or a non-GNU `timeout` failed to
# create a group), or the group is already gone, this is a silent no-op —
# it degrades to silence, never to a wrong kill.
_gate_sweep_pgid() {
	local pgid="$1" self_pgid survivors
	[[ "$pgid" =~ ^[0-9]+$ ]] || return 0
	((pgid > 1)) || return 0
	self_pgid="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')"
	[[ -n "$self_pgid" && "$pgid" == "$self_pgid" ]] && return 0
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

	local pgid_file
	pgid_file="$(mktemp)"

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
			rm -f "$pgid_file"
			echo "gate_run_bounded: none of timeout, gtimeout, or python3 is available" >&2
			return 2
		fi
		python3 - "$pgid_file" "$seconds" "$kill_after_s" "$@" >"$tool_out" 2>"${tool_out}.stderr" <<'PYSHIM' || exit_code=$?
import os
import signal
import subprocess
import sys
import time

pgid_file = sys.argv[1]
budget = float(sys.argv[2])
kill_after = float(sys.argv[3])
cmd = sys.argv[4:]

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

	# Expiry predicate. `expired` iff the command exited non-zero AND
	# either the runner reported the canonical timeout code, or the
	# measured wall clock reached the budget (which is what 137 from
	# `timeout --kill-after` always means when it isn't the exit-code
	# check above, and what any future runner's signal-death code would
	# mean too). A killed child can never exit 0, so the `exit_code -ne 0`
	# guard costs nothing on the expiry side while protecting a
	# legitimately successful run that happens to finish exactly at the
	# budget boundary (integer `date +%s` truncation) from being
	# misclassified. 137 is deliberately not in the literal-code set: it
	# is also what an in-budget OOM kill of the child looks like, and the
	# duration clause below correctly classifies that as `error`, not
	# expiry.
	local expired=0
	if [[ "$exit_code" -ne 0 ]] && { [[ "$exit_code" -eq 124 ]] || [[ "$duration_s" -ge "$seconds" ]]; }; then
		expired=1
	fi

	if [[ "$expired" -eq 1 ]]; then
		rm -f "$tool_out" "${tool_out}.stderr"
		local pgid=""
		[[ -s "$pgid_file" ]] && pgid="$(cat "$pgid_file")"
		_gate_sweep_pgid "$pgid"
		rm -f "$pgid_file"
		local reason="DEGRADED: timeout after ${seconds}s"
		jq -n \
			--arg reason "$reason" \
			--argjson duration_s "$duration_s" \
			--arg gate_name "$gate_name" \
			'{status: "skipped", notes: $reason, findings: [], gate: (if ($gate_name | length) > 0 then $gate_name else null end), duration_s: $duration_s, degraded_reason: $reason}' \
			>"$envelope_out"
		return 0
	fi

	rm -f "$pgid_file"

	if [[ -s "$tool_out" ]] && jq -e 'type == "object" and (.status | type) == "string"' \
		>/dev/null 2>&1 <"$tool_out"; then
		jq --argjson duration_s "$duration_s" \
			--arg gate_name "$gate_name" \
			'. + {duration_s: $duration_s, degraded_reason: null} + (if ($gate_name | length) > 0 then {gate: $gate_name} else {} end)' \
			"$tool_out" >"$envelope_out"
	else
		jq -n \
			--argjson duration_s "$duration_s" \
			--arg gate_name "$gate_name" \
			'{status: "error", notes: "gate command exited without a valid JSON object tool-out (expected an object with a string .status)", findings: [], gate: (if ($gate_name | length) > 0 then $gate_name else null end), duration_s: $duration_s, degraded_reason: null}' \
			>"$envelope_out"
	fi
	return 0
}
