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
#     EXACTLY TWO usage errors are exempt, and only because <envelope-out>
#     is not knowable when they are detected: `--gate` given without a
#     <name>, and fewer than two arguments remaining once any `--gate`
#     pair has been consumed. On every other `return 2` path — a missing
#     `--` separator, a missing <cmd...>, a non-positive <budget-seconds>
#     — <envelope-out> and <tool-out> (plus its `.stderr` sibling) are
#     removed BEFORE the check that fails. The unlink is best-effort: an
#     unremovable path does not itself become a usage error.
#
# Dependencies: bash + jq + (GNU/Homebrew `timeout` or `gtimeout`, else
# python3 as the setsid-shim fallback).

# _gate_sweep_pgid <pgid> — TERM then (after a 5s grace, polled) KILL every
# survivor in process group <pgid>, except this shell's own pid. Called
# only from the expiry branch of gate_run_bounded, never elsewhere.
#
# OLD RULE (removed): "signal only a group whose recorded LEADER still leads
# it" — `pgrep -g <pgid>` had to list <pgid> itself. That proved no pgid
# recycling, but at the cost of never signalling on the common path: on the
# primary `timeout(1)` path the recorded pgid IS timeout's own pid, and
# `wait` has already reaped it before the expiry branch runs, so the guard
# failed on EVERY expiry and no SIGKILL ever reached a `trap "" TERM`
# descendant.
#
# NEW RULE: signal only a group with at least ONE LIVE MEMBER. This is
# equally sound against recycling: a pid that is in use as a non-empty
# process group's pgid is not reallocated (Linux pins the `struct pid` via
# PIDTYPE_PGID for as long as the group is non-empty; darwin holds a `pgrp`
# reference), so a non-empty `pgrep -g <pgid>` cannot be a recycled group.
# An empty group is already a no-op via the `[[ -n "$survivors" ]]` return.
#
# The three remaining guards are unchanged:
#   - <pgid> must be numeric and > 1 (never "my group", never init);
#   - <pgid> must differ from this shell's own process group (the exact
#     hazard a background job inherits the caller's pgid);
#   - this shell's own pid is filtered out of whatever `pgrep -g` returns.
#
# If the recorded pgid is empty, the group has no surviving members, or any
# probe command fails, this is a silent no-op — it degrades to silence,
# never to a wrong kill and never to an aborted expiry branch.
#
# RESIDUAL RACE (unchanged in kind, not closable here): between the
# membership probe and the `kill`, the last member could exit and the OS
# could in principle recycle <pgid>. Closing that would need a
# pidfd/process-handle API that portable bash does not have. It is
# documented rather than claimed away.
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

	# Stale-artefact unlink, hoisted to the FIRST point at which the paths
	# are knowable. Every `return 2` below this line therefore leaves no
	# previous round's artefacts behind — the contract the header promises.
	# It used to sit after the `$4 != "--"` check, so three usage errors
	# (`--gate` with no name, fewer than 5 arguments, a missing `--`)
	# returned 2 with a possibly-CLEAN previous-round envelope still at
	# $envelope_out for a caller that ignores the return value to misread as
	# this round's result. The third of those already knew the path.
	#
	# Positional meaning after the `--gate` shift, per the usage line below:
	#   $1 = <seconds>  $2 = <envelope-out>  $3 = <tool-out>
	# `$# -ge 2` is the guard: with fewer arguments than that no path has
	# been supplied and there is nothing to remove. Best-effort by design —
	# an unremovable path is not itself a usage error, and the real write
	# below would fail loudly anyway.
	if [[ $# -ge 2 ]]; then
		rm -f "$2"
		if [[ $# -ge 3 ]]; then
			rm -f "$3" "${3}.stderr"
		fi
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

	# (The stale-artefact unlink used to live here. It is hoisted above the
	# argument checks now — one owner, and every `return 2` that can name a
	# path is covered.)

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

	local pgid_file state_file rc_file
	pgid_file="$(mktemp)"
	# The runner's OWN record of why the run ended. Only the python3 shim's
	# TimeoutExpired path writes to it; everything else leaves it empty.
	state_file="$(mktemp)"
	# The COMMAND's own record that it chose its exit status. Written by the
	# `bash -c` frame below, immediately after the reviewed command returns.
	# A non-empty rc_file proves the command exited on its own; an
	# absent/empty one proves it did not (it was signalled). This replaces
	# the `duration_s >= seconds` INFERENCE for the non-shim paths: `date
	# +%s` is integer-second, so a command exiting on its own at true
	# elapsed 0.7s under a 1s budget measured 1 whenever those 0.7s
	# straddled a second boundary, and had its VALID tool-out deleted and
	# replaced with a degraded `skipped` envelope. Bash 3.2 (the declared
	# floor) has no $EPOCHREALTIME and `date +%s%N` is GNU-only, so the
	# inference is removed rather than sharpened.
	rc_file="$(mktemp)"

	# The reviewed command, wrapped so it records its own $? before exiting
	# with it. The extra frame sits UNDER `timeout`/the shim, so the
	# recorded pgid -- and therefore _gate_sweep_pgid -- is unaffected: the
	# wrapper is a member of the same group, not a new one. `bash -c` starts
	# without `set -e`, so a non-zero command status is captured, not fatal.
	local -a bounded_cmd
	# shellcheck disable=SC2016  # intentional: this is the inner shell's script, not this shell's
	bounded_cmd=(bash -c '
		gate_rc_file="$1"
		shift
		rc=0
		"$@" || rc=$?
		printf "%s" "$rc" >"$gate_rc_file" 2>/dev/null || true
		exit "$rc"
	' _ "$rc_file" "$@")

	local start_ts end_ts duration_s exit_code=0
	start_ts="$(date +%s)"

	if command -v timeout >/dev/null 2>&1; then
		# Backgrounded (not foreground) so `$!` is observable: GNU
		# `timeout` without `--foreground` calls setpgid(0,0) on itself,
		# so its own pid *is* the child process-group id. `wait`
		# propagates its exit status unchanged.
		timeout --kill-after="${kill_after_s}s" "${seconds}s" "${bounded_cmd[@]}" >"$tool_out" 2>"${tool_out}.stderr" &
		local gate_pid=$!
		printf '%s' "$gate_pid" >"$pgid_file"
		wait "$gate_pid" || exit_code=$?
	elif command -v gtimeout >/dev/null 2>&1; then
		gtimeout --kill-after="${kill_after_s}s" "${seconds}s" "${bounded_cmd[@]}" >"$tool_out" 2>"${tool_out}.stderr" &
		local gate_pid=$!
		printf '%s' "$gate_pid" >"$pgid_file"
		wait "$gate_pid" || exit_code=$?
	else
		if ! command -v python3 >/dev/null 2>&1; then
			rm -f "$pgid_file" "$state_file" "$rc_file"
			echo "gate_run_bounded: none of timeout, gtimeout, or python3 is available" >&2
			return 2
		fi
		python3 - "$pgid_file" "$state_file" "$seconds" "$kill_after_s" "${bounded_cmd[@]}" >"$tool_out" 2>"${tool_out}.stderr" <<'PYSHIM' || exit_code=$?
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
# `pgid` stays None only if the child was reaped before we could read its
# group; every later use is guarded on that.
pgid = None
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
    #
    # `escalated` is about the LEADER (it decides the 124/137 exit alphabet
    # and nothing else); `swept` is about the GROUP. They are separate
    # because the leader reaping does NOT mean the group is empty: a
    # `trap "" TERM` descendant survives the SIGTERM above and the `break`
    # below used to leave it running forever. On a leader reap, probe the
    # group with killpg(pgid, 0) and SIGKILL it if anything is still there.
    escalated = False
    swept = False
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
    if not escalated and pgid is not None:
        # Leader reaped inside the grace window. `pgid` was captured while
        # the child was still alive, so it still names the group the child
        # was put in; a signal-0 killpg tells us whether any member outlived
        # the leader.
        try:
            os.killpg(pgid, 0)
            os.killpg(pgid, signal.SIGKILL)
            swept = True
        except (ProcessLookupError, PermissionError, OSError):
            pass
    # Exit alphabet is keyed on the LEADER only, so a sweep does not turn a
    # 124 into a 137: `run-gate.sh` reads the envelope, not this code, and
    # the envelope must not claim the gate had to be force-killed when it
    # did not. `swept` is therefore recorded, not signalled.
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
	local expired=0 runner_state="" self_exited=0
	[[ -s "$state_file" ]] && runner_state="$(cat "$state_file" 2>/dev/null || true)"
	# A11: an rc_file with content is the command saying "I chose this exit
	# status". It outranks the clock: only a command that did NOT exit on
	# its own can have been killed by the budget.
	[[ -s "$rc_file" ]] && self_exited=1
	if [[ "$exit_code" -ne 0 ]] &&
		{ [[ "$runner_state" == "TIMEOUT" ]] ||
			{ [[ "$self_exited" -eq 0 ]] && ((10#$duration_s >= 10#$seconds)); }; }; then
		expired=1
	fi

	if [[ "$expired" -eq 1 ]]; then
		rm -f "$tool_out" "${tool_out}.stderr"
		local pgid=""
		[[ -s "$pgid_file" ]] && pgid="$(cat "$pgid_file")"
		_gate_sweep_pgid "$pgid"
		rm -f "$pgid_file" "$state_file" "$rc_file"
		local reason="DEGRADED: timeout after ${seconds}s"
		jq -n \
			--arg reason "$reason" \
			--argjson duration_s "$duration_s" \
			--arg gate_name "$gate_name" \
			'{status: "skipped", notes: $reason, findings: [], gate: (if ($gate_name | length) > 0 then $gate_name else null end), duration_s: $duration_s, degraded_reason: $reason}' \
			>"$envelope_out"
		return 0
	fi

	rm -f "$pgid_file" "$state_file" "$rc_file"

	# G3: `.findings` must be a real array, not merely present-and-ignorable.
	# `run-gate.sh normalize` reads `.findings[]?`; the `?` swallows a
	# null/non-array field, so a malformed gate used to report as clean.
	#
	# A12: --slurp on BOTH the gate and the pass-through. Without it, `jq -e`
	# applies the filter to each top-level document independently and its
	# exit status reflects only the LAST one, while the pass-through MAPS
	# over all of them -- so a gate printing two envelopes had TWO stamped
	# objects written into the envelope file. The invariant "the envelope
	# holds one JSON object" was always the contract; it is now enforced,
	# and a multi-document tool-out falls to the `error` envelope below.
	if [[ -s "$tool_out" ]] && jq -e -s 'length == 1 and (.[0] | type == "object") and ((.[0].status | type) == "string") and ((.[0].findings | type) == "array")' \
		>/dev/null 2>&1 <"$tool_out"; then
		jq -s --argjson duration_s "$duration_s" \
			--arg gate_name "$gate_name" \
			'.[0] + {duration_s: $duration_s, degraded_reason: null} + (if ($gate_name | length) > 0 then {gate: $gate_name} else {} end)' \
			"$tool_out" >"$envelope_out"
	else
		jq -n \
			--argjson duration_s "$duration_s" \
			--arg gate_name "$gate_name" \
			'{status: "error", notes: "gate command exited without a valid JSON object tool-out (expected an object with a string .status and an array .findings), or emitted more than one JSON document", findings: [], gate: (if ($gate_name | length) > 0 then $gate_name else null end), duration_s: $duration_s, degraded_reason: null}' \
			>"$envelope_out"
	fi
	return 0
}
