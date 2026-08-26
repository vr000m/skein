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
# It sources exactly ONE sibling, lib/state-path-guard.sh, resolved through
# this file's own directory. Earlier revisions said "sources nothing by
# contract"; the reason was gauntlet-common.sh's harness-divergent plugin-root
# anchor, which state-path-guard.sh does not have — it is harness-neutral and
# parity-enforced, exactly like this file. Round 6 (F1/F2/F3): the alternative
# to sourcing it was a THIRD hand-rolled copy of the tree's containment
# policy, and the weaker copy round 5 wrote here is precisely how a symlinked
# `.gauntlet/` came to be refused by the ledger and followed by the gate.
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
#     paths hand bash the same fact through the same channel. R11/F20: what
#     is recorded there is a pgid only when the launched process is verified
#     (at record time) to LEAD its group — the python3 shim by construction
#     (it calls os.setsid), the `timeout`/`gtimeout` arms by an explicit
#     `ps -o pgid=` probe — a BOUNDED POLL, not a single sample, because
#     `timeout` calls setpgid(0,0) only after its exec and so is not yet a
#     leader at the instant `$!` becomes known. When it does not lead one,
#     within that deadline, the sidecar is left
#     empty and a `.pid` sidecar carries the single pid instead, which expiry
#     TERM/KILLs directly (`_gate_kill_single_pid`); see that block's comment
#     for why this is not the round-3 sweep-time check returning. The sweep
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
#     <budget-seconds> below 1) before any command ran.
#
#     ON rc=2, NO COMMAND RAN AND NO ENVELOPE WAS WRITTEN — so a caller
#     must never read <envelope-out> after rc=2. Do not treat whatever is
#     at that path as this round's result; treat rc=2 itself as the result.
#     Whether that path was emptied depends on WHICH usage error fired, and
#     that is precisely why the return code, not the file, is the signal:
#
#       - A POSITIONAL-SHAPE error (too few arguments, a missing `--`
#         separator, an empty <cmd...>, a <budget-seconds> below 1) returns
#         2 having touched NOTHING. At those lines `$2`/`$3` are not yet
#         known to be <envelope-out>/<tool-out> — with the arguments
#         shifted, `$3` is a command word — so a stale artefact is left in
#         place rather than a guessed path being deleted.
#
#       - A PRECONDITION error taken after the shape checks (no jq, no
#         bounding mechanism) returns 2 with <envelope-out> and <tool-out>
#         already removed, because by then those locals are validated.
#
#     This inverts the round-3 contract, which removed <envelope-out> and
#     <tool-out> before most `return 2` paths so a caller ignoring the
#     return value could not misread a stale envelope as fresh. That
#     removal ran at the TOP of the function, where `$2`/`$3` have not yet
#     been established to BE those paths — with the arguments shifted, `$3`
#     is a command word, and the unlink deleted it. Removing a guessed path
#     is a worse failure than leaving a stale one for a caller that is
#     already ignoring its return code. Round 4 does not drop the removal;
#     it MOVES it down to the first line at which the paths are known —
#     immediately after the positional-shape checks — so every later exit
#     still gets it. It is best-effort (`|| :`), so an unremovable path
#     neither becomes a usage error nor aborts the caller under
#     `set -euo pipefail`.
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
#
# R11/F20 — WHAT IS RECORDED, AND WHY THAT IS NOT THE OLD RULE COMING BACK.
#
# Everything above assumes the number in <pgid-file> is a process-GROUP id.
# It was written unconditionally as `$!`, which is a pid. That is only also a
# pgid when the bounding process made itself a group leader: GNU/Homebrew
# `timeout(1)` calls setpgid(0,0) on itself, so `$! == its pgid`. A
# `timeout` that does NOT (a busybox/shim/wrapper `timeout` earlier on PATH)
# leaves `$!` an ordinary group member, and the sweep then interprets a pid
# as a pgid — normally a harmless no-op, because `pgrep -g <non-leader-pid>`
# is empty, but a wrong kill whenever that number happens to match an
# unrelated LIVE group.
#
# So leadership is now PROBED AT RECORD TIME (`_gate_record_gate_pid`, below)
# — as a bounded poll, since setpgid(0,0) happens after `timeout`'s exec and
# a probe fired at `$!` can beat it; see that function's comment — and the
# two cases are recorded distinguishably:
#   - leader     -> <pgid-file> holds the pgid; expiry sweeps the group.
#   - non-leader -> <pgid-file> is left EMPTY and <pgid-file>.pid holds the
#                   single pid; expiry falls back to a plain TERM/KILL on it.
# An unreadable/empty probe is treated as NOT-a-leader: fail closed to the
# single-pid path, which can never signal a process the gate did not start.
#
# This is NOT the round-3 "recorded leader still leads it" check being
# reinstated. That check ran at SWEEP time — after `wait` had already reaped
# `timeout` — so on the primary path it was false on every single expiry and
# no signal ever went out. This one runs at RECORD time, while the process is
# still alive and its pgid is still observable, and it decides which KIND of
# kill to use rather than whether to kill at all. Neither path can become a
# universal no-op. Do not "simplify" it back into the sweep.
# The one sibling this file sources (see the header). Resolved through this
# file's own directory, so it works in both plugin mirrors with no
# harness-specific anchor substitution.
# shellcheck source=plugins/skein/skills/review-gauntlet/lib/state-path-guard.sh disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/state-path-guard.sh"

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

# _gate_record_gate_pid <gate-pid> <pgid-file> — R11/F20. Called immediately
# after `local gate_pid=$!`, while the process is still alive, from the
# `timeout` and `gtimeout` arms ONLY. The python3 shim arm does not call it:
# that shim calls os.setsid() itself and writes its own genuine pgid, so
# probing it would be re-deriving a fact the shim already knows.
#
# `ps -o pgid= -p <pid>` is POSIX and behaves identically on macOS and Linux;
# both pad the column, hence the `tr -d ' '` — the same idiom _gate_sweep_pgid
# already uses for `$$`. `|| true` for the same reason it does: this is a
# pipeline under the caller's `set -euo pipefail`, and a `ps` EPERM must
# degrade to the fail-closed single-pid path, not abort the gate before it has
# even run.
#
# WHY THE PROBE IS A BOUNDED POLL AND NOT A SINGLE `ps`.
#
# `$!` is known at FORK time; `timeout(1)` calls setpgid(0,0) only after bash
# has exec'd it, i.e. strictly LATER. A single probe fired immediately after
# `$!` therefore races the exec: it can legitimately observe the child still
# carrying the PARENT shell's pgid, before `timeout` has made itself a leader.
# That is not a non-setpgid `timeout`, it is a not-yet-setpgid one — but the
# old one-shot probe could not tell them apart and recorded the weaker
# single-pid fallback, under which a `trap "" TERM` grandchild survives
# expiry. Measured at roughly 1 run in 4 by an interleaved 20-run A/B of
# tests/gauntlet/test-gate-timeout.sh's process-group sweep cases.
#
# So the probe re-samples until one of three things is true:
#   - pgid == pid            -> leader, record the pgid (the common case,
#                               normally on the first or second sample);
#   - the process is gone    -> nothing more will ever be observable; take
#     (empty probe)             the fail-closed single-pid path immediately,
#                               exactly as before. An EPERM `ps` is
#                               indistinguishable from "gone" and lands here
#                               too, which is the same fail-closed choice the
#                               one-shot probe made;
#   - the deadline elapses   -> a genuinely non-setpgid `timeout` (busybox,
#     (~500ms)                  shim, wrapper) never becomes a leader, so the
#                               single-pid sidecar path is the correct and
#                               final answer for it.
#
# 500ms is ~4 orders of magnitude above a fork+exec and still invisible next
# to any gate budget; only the genuinely-non-setpgid path ever pays it in
# full. `sleep 0.025` is fractional-capable on both macOS and GNU coreutils;
# if some PATH `sleep` rejects it, the fallback `sleep 1` already overshoots
# the deadline, so that single sample ends the poll — degrading to the old
# one-shot-plus-one behaviour rather than looping for 20 seconds.
_gate_record_gate_pid() {
	local gate_pid="$1" pgid_file="$2" gate_pgid _i
	for _i in {1..20}; do
		gate_pgid="$(ps -o pgid= -p "$gate_pid" 2>/dev/null | tr -d ' ' || true)"
		# Gone (or unprobeable): no later sample can say more. Fail closed.
		[[ -n "$gate_pgid" ]] || break
		if [[ "$gate_pgid" == "$gate_pid" ]]; then
			# True group leader: the recorded number really is a pgid and
			# the group sweep is sound.
			printf '%s' "$gate_pid" >"$pgid_file"
			: >"${pgid_file}.pid"
			return 0
		fi
		((_i < 20)) || break
		# Still a plain group member — either pre-exec (retry wins) or a
		# `timeout` that never calls setpgid (deadline wins).
		sleep 0.025 2>/dev/null || {
			sleep 1
			break
		}
	done
	# Not a leader within the deadline (or unprobeable). Record NOTHING as a
	# pgid — an empty <pgid-file> makes _gate_sweep_pgid's `[[ -n ]]` guard a
	# no-op by construction — and keep the single pid in a sidecar instead.
	: >"$pgid_file"
	printf '%s' "$gate_pid" >"${pgid_file}.pid"
}

# _gate_kill_single_pid <pid> — the non-leader fallback: TERM, a 5s polled
# grace, then KILL, aimed at exactly one pid. Deliberately narrower than
# _gate_sweep_pgid: with no group to enumerate there is nothing to escalate
# to, so a `trap "" TERM` grandchild of a non-setpgid `timeout` survives. That
# is strictly better than the alternative it replaces (treating the pid as a
# pgid and signalling whatever unrelated group happens to bear that number),
# and it is the honest limit of what is knowable without setpgid.
_gate_kill_single_pid() {
	local pid="$1" _i
	[[ "$pid" =~ ^[0-9]+$ ]] || return 0
	((pid > 1)) || return 0
	[[ "$pid" != "$$" ]] || return 0
	kill -0 "$pid" 2>/dev/null || return 0
	kill -TERM "$pid" 2>/dev/null || true
	for _i in 1 2 3 4 5; do
		kill -0 "$pid" 2>/dev/null || return 0
		sleep 1
	done
	kill -KILL "$pid" 2>/dev/null || true
}

# gate_assert_no_symlink <path> -> 0 safe, 1 with a diagnostic on stderr.
#
# A ONE-LINE WRAPPER over the skill's single state-path guard (round 6,
# F1/F2/F3). Round 5 added a guard here as a SELF-CONTAINED copy — leaf plus
# immediate parent, no `..` rejection — because this file "sources nothing by
# contract". That copy was strictly weaker than the walk convergence-ledger.sh
# was already running over the SAME `.gauntlet/` tree: a symlink at
# `.gauntlet/` itself (the grandparent of every path the gauntlet composes,
# `SKILL.md`: `gate_out_dir="$run_dir/round-$round_n"`) was refused by the
# ledger and FOLLOWED here, so the envelope, the tool output and its stderr
# were written outside the repo. One tree must have one containment policy, so
# the policy now lives once, in lib/state-path-guard.sh, and both callers are
# wrappers.
#
# The "sources nothing" sentence in this file's header is AMENDED, not
# silently broken: its reason was the harness-divergent plugin-root anchor in
# gauntlet-common.sh, and state-path-guard.sh has no anchor to resolve — it is
# reached through this file's own directory, the same mechanism run-gate.sh
# and convergence-ledger.sh already use.
#
# The wrapper NAME stays, because it is what the three call sites in
# gate_run_bounded and the structural placement assertion in
# tests/gauntlet/test-gate-timeout.sh both refer to.
gate_assert_no_symlink() {
	gauntlet_assert_no_symlink "$1" gate_run_bounded
}

# _gate_scratch_cleanup — removes the private scratch DIRECTORY holding
# gate_run_bounded's pgid/state/rc files. Reads `$_GATE_SCRATCH_DIR`, which is
# set (and `local`-scoped) inside gate_run_bounded's scratch subshell, so this
# is dynamically scoped by design and is a no-op anywhere else. Never fails:
# it runs both as an EXIT trap handler and as an explicit pre-exit call under
# the caller's `set -euo pipefail`, and a cleanup that can abort the shell is
# worse than one that silently leaves a file behind.
_gate_scratch_cleanup() {
	[[ -n "${_GATE_SCRATCH_DIR:-}" ]] || return 0
	rm -rf -- "$_GATE_SCRATCH_DIR" 2>/dev/null || :
	return 0
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

	shift 4
	if [[ $# -eq 0 ]]; then
		echo "gate_run_bounded: missing <cmd...>" >&2
		return 2
	fi
	if ! [[ "$seconds" =~ ^[0-9]+$ ]] || ((10#$seconds < 1)); then
		echo "gate_run_bounded: <seconds> must be a positive integer (>= 1); got '$seconds'" >&2
		return 2
	fi

	# Symlink guard on the three paths this function writes. It sits HERE --
	# after the positional-shape checks, so `$2`/`$3` are KNOWN to be
	# <envelope-out>/<tool-out> and it is not guarding a guess (the F16
	# lesson), and before the stale-artefact unlink below, so it precedes the
	# first filesystem effect of any kind. A refusal is a USAGE error: the
	# caller handed an unusable path, and rc=2 composes with the header's
	# contract that on rc=2 no envelope was written and <envelope-out> was
	# not touched. `${tool_out}.stderr` shares $tool_out's parent, so only
	# its own leaf needs a separate test.
	if ! gate_assert_no_symlink "$envelope_out" ||
		! gate_assert_no_symlink "$tool_out" ||
		! gate_assert_no_symlink "${tool_out}.stderr"; then
		return 2
	fi

	# Stale-artefact unlink. It sits immediately below the POSITIONAL-SHAPE
	# checks -- `$#`, the `--` separator, a non-empty <cmd...>, and a
	# positive integer budget -- and above every remaining check and the
	# first command launch. That position is the whole fix, and it is chosen
	# by one question: at this line, are `$2`/`$3` KNOWN to be
	# <envelope-out>/<tool-out>? Above the shape checks they are not; below
	# them they are. Round 3 hoisted this to the top of the function to buy
	# "no stale envelope on a usage error"; round 4 found two defects in that
	# hoist:
	#
	#   F16 — at the top of the function `$2`/`$3` are not yet KNOWN to be
	#     <envelope-out>/<tool-out>. With the arguments shifted (say
	#     `gate_run_bounded 900 -- my-gate.sh`) `$3` is a COMMAND WORD, and
	#     the hoisted `rm -f` deleted it. The unlink was operating on a guess.
	#
	#   F8 — `rm -f "$3" "${3}.stderr"` was the last command of a `then`
	#     list, so under the caller's documented `set -euo pipefail` a failing
	#     unlink (an unremovable path, e.g. a directory) aborted the CALLER
	#     outright: the exact opposite of the "best-effort" this comment and
	#     the header both promise. Both lines are now explicitly `|| :`.
	#
	# What round 3 was protecting is kept: every `return 2` that FOLLOWS the
	# shape checks -- a missing jq, no bounding mechanism -- still leaves no
	# stale envelope behind, because the unlink has already run on validated
	# locals. What changes is the handful of exits ABOVE it, where the
	# function cannot yet name the paths: those now return 2 having touched
	# nothing at all, and the header tells the caller not to read
	# <envelope-out> on rc=2 rather than handing it an emptied path.
	rm -f "$envelope_out" 2>/dev/null || :
	rm -f "$tool_out" "${tool_out}.stderr" 2>/dev/null || :

	if ! command -v jq >/dev/null 2>&1; then
		echo "gate_run_bounded: jq is required" >&2
		return 2
	fi
	# Bounding mechanism, checked HERE rather than on the shim branch below.
	# Exactly equivalent (the branch check could only fire when neither
	# `timeout` nor `gtimeout` exists), but hoisting it keeps every remaining
	# `return 2` a precondition failure taken before any temp file is
	# created, so no exit path can leave a half-built run behind.
	if ! command -v timeout >/dev/null 2>&1 &&
		! command -v gtimeout >/dev/null 2>&1 &&
		! command -v python3 >/dev/null 2>&1; then
		echo "gate_run_bounded: none of timeout, gtimeout, or python3 is available" >&2
		return 2
	fi

	# Shared grace window between SIGTERM and SIGKILL escalation, used by
	# both the GNU/Homebrew `timeout` path (`--kill-after`) and the
	# python3 shim path — same promise, same timing, both paths.
	local kill_after_s=10

	# --- SCRATCH REGION (R12/F15) --------------------------------------
	# Everything from here to the closing `)` runs in a SUBSHELL whose only
	# job is to make the three scratch files disappear on EVERY exit path,
	# including an abort.
	#
	# The bug: pgid_file/state_file/rc_file (plus the `${pgid_file}.pid`
	# sidecar) were four separate `mktemp` files removed only by the two
	# explicit `rm -f` lines on the success and expiry paths. Any abort
	# between creation and those lines leaked all four into $TMPDIR
	# permanently — and there IS such a path: the caller runs under the
	# documented `set -euo pipefail`, so a failing redirection on the final
	# `jq -n ... >"$envelope_out"` (an unwritable <envelope-out> parent)
	# kills the shell right there.
	#
	# Why not a RETURN trap: a RETURN trap does NOT fire when `set -e`
	# aborts the shell — verified on this host — so it covers exactly the
	# paths that were already covered and none of the ones that leaked.
	#
	# Why not an EXIT trap in this frame: gate_run_bounded is a LIBRARY
	# function. Installing an EXIT trap here would clobber whatever EXIT
	# trap the sourcing script already has (run-gate.sh and the ledger both
	# use one for their own temp files), and "read `trap -p EXIT` and append
	# to it" is string-splicing another script's shell code — fragile in
	# exactly the way this file is meant not to be.
	#
	# Why a subshell is safe here, checked against the three things it could
	# have broken:
	#   - `$!` / `wait`: the background `timeout`/`gtimeout` job is started
	#     INSIDE this subshell, so it is the subshell's own child. `$!` and
	#     `wait "$gate_pid"` refer to it exactly as before.
	#   - pgid recording: bash does not put a non-interactive `( )` in a new
	#     process group, and `$$` inside a subshell still expands to the
	#     PARENT shell's pid — so _gate_record_gate_pid's leadership probe
	#     and _gate_sweep_pgid's `self_pgid` / `grep -vx "$$"` self-guards
	#     compare the same numbers they did before.
	#   - the return contract: the subshell is the function's last command,
	#     so the function's status IS the subshell's. The two success paths
	#     therefore say `exit 0` rather than `return 0`; every `return 2`
	#     precondition path sits ABOVE this region and is untouched.
	# An EXIT trap set inside `( )` is local to the subshell and fires on
	# its abort, so it never touches the caller's own EXIT trap.
	#
	# _gate_scratch_cleanup is ALSO called explicitly before each `exit 0`
	# (belt and braces; `rm -rf` is idempotent, so the trap re-running on an
	# already-removed dir is a no-op).
	(
		_GATE_SCRATCH_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gate-bounded.XXXXXX")"
		trap '_gate_scratch_cleanup' EXIT
		local pgid_file state_file rc_file
		pgid_file="$_GATE_SCRATCH_DIR/pgid"
		# The runner's OWN record of why the run ended. Only the python3 shim's
		# TimeoutExpired path writes to it; everything else leaves it empty.
		state_file="$_GATE_SCRATCH_DIR/state"
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
		rc_file="$_GATE_SCRATCH_DIR/rc"

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
			# R11/F20: probe leadership HERE, while $gate_pid is still alive.
			# A `timeout` that does not setpgid leaves $! an ordinary group
			# member, and recording it as a pgid is a wrong-kill hazard.
			_gate_record_gate_pid "$gate_pid" "$pgid_file"
			wait "$gate_pid" || exit_code=$?
		elif command -v gtimeout >/dev/null 2>&1; then
			gtimeout --kill-after="${kill_after_s}s" "${seconds}s" "${bounded_cmd[@]}" >"$tool_out" 2>"${tool_out}.stderr" &
			local gate_pid=$!
			_gate_record_gate_pid "$gate_pid" "$pgid_file"
			wait "$gate_pid" || exit_code=$?
		else
			# python3 is guaranteed present here: the precondition block above
			# already refused when none of timeout/gtimeout/python3 exists, and
			# this branch is only reached when neither of the first two does.
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
			# R11/F20: a NON-EMPTY pgid file means the record-time probe
			# confirmed a true group leader (or the python3 shim wrote its own
			# setsid pgid) -- sweep the group. An EMPTY one means the bounding
			# process was not a leader, so the only sound target is the single
			# pid in the sidecar.
			local pgid="" gate_pid_recorded=""
			[[ -s "$pgid_file" ]] && pgid="$(cat "$pgid_file")"
			[[ -s "${pgid_file}.pid" ]] && gate_pid_recorded="$(cat "${pgid_file}.pid")"
			if [[ -n "$pgid" ]]; then
				_gate_sweep_pgid "$pgid"
			else
				_gate_kill_single_pid "$gate_pid_recorded"
			fi
			_gate_scratch_cleanup
			local reason="DEGRADED: timeout after ${seconds}s"
			jq -n \
				--arg reason "$reason" \
				--argjson duration_s "$duration_s" \
				--arg gate_name "$gate_name" \
				'{status: "skipped", notes: $reason, findings: [], gate: (if ($gate_name | length) > 0 then $gate_name else null end), duration_s: $duration_s, degraded_reason: $reason}' \
				>"$envelope_out"
			exit 0
		fi

		_gate_scratch_cleanup

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
		exit 0
	)
}
