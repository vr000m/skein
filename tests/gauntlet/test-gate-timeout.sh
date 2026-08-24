#!/usr/bin/env bash
# test-gate-timeout.sh — Phase 1 acceptance for the harness-neutral
# `gate_run_bounded` helper (plugins/skein/skills/review-gauntlet/lib/gate-bounded.sh)
# and its interplay with the existing `run-gate.sh normalize` non-clean-status
# path. Plan: docs/dev_plans/20260823-feature-review-skills-resilience.md,
# Phase 1, R1 + Testing Notes + Review Focus ("Timeout interplay").
#
# Design intent under test (Phase 1 Goal): a hung external gate costs at most
# its budget, enforced in shell (never Claude-side), never blocks the round,
# and is visibly `skipped`/DEGRADED — never silently clean; budgets are one
# formula, bundled, overridable in seconds.
#
# Covers:
#   1. Expiry: a tool that writes a valid tool-out then hangs past budget is
#      killed; tool-out is removed; the envelope is `skipped`/DEGRADED with
#      duration_s stamped; `run-gate.sh normalize` on the envelope exits 4.
#      Asserted on BOTH the GNU-timeout path and the shim path, with a
#      cross-path envelope-parity check (finding 1 / finding 6).
#   2. Crash-with-garbage: a tool that exits 0 but leaves invalid JSON in
#      tool-out yields a `status: "error"` envelope (never a clean-looking
#      one) — the envelope path is the ONLY thing `normalize` ever reads.
#      Asserted on BOTH paths with parity (finding 6).
#   3. Non-object valid JSON (e.g. `[1,2]`) and object-without-usable-status
#      (`{"findings":[]}`, `{"status":null,...}`) must NOT produce a
#      zero-byte envelope — they fall through to the status:"error" envelope,
#      on both paths, with parity (finding 2).
#   4. Process-group kill: a SIGTERM-ignoring child is dead after expiry, and
#      the envelope is skipped/DEGRADED on BOTH paths with parity
#      (finding 1's primary regression test).
#   5. Sweep scoping: an unrelated decoy process whose command line matches
#      the old `codex exec review` pattern, but which lives outside the
#      gate's process group, survives the expiry sweep (finding 3).
#   6. Budget validation: `gate_run_bounded` rejects a non-positive/
#      non-numeric budget with rc=2 and no envelope left behind — even when
#      a stale envelope already existed at that path (finding 4b/4c).
#   7. Shim parity: with `timeout` hidden from PATH (this host's actual
#      state per plan Dependencies — `timeout` is Homebrew coreutils only),
#      the python3 os.setsid fallback produces an equivalent envelope, twice
#      in a row (determinism).
#   8. Success path: exit 0 + valid JSON well within budget -> clean
#      envelope, tool-out retained, duration_s stamped.
#
# Interface assumed (from the plan's R1 + Phase 1 checklist prose):
#   gate_run_bounded <budget-seconds> <envelope-out> <tool-out> -- <cmd...>
#   The wrapper captures <cmd...>'s stdout into <tool-out> itself (this is
#   the only reading of the spec that makes "invalid JSON tool-out" possible
#   from a stub that merely prints truncated text — the stub does not know
#   its own tool-out path). If the real interface instead has the invoked
#   command write <tool-out> itself (passed as an argument), the stub
#   scripts below will need a one-line rework to accept and write to that
#   path explicitly; the assertions on envelope shape and process-death are
#   interface-agnostic.
#
# Exit codes: 0 all assertions pass, 1 any assertion fails.

set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
SKILL_LIB="$ROOT_DIR/plugins/skein/skills/review-gauntlet/lib"
GATE_BOUNDED="$SKILL_LIB/gate-bounded.sh"
RUN_GATE="$SKILL_LIB/run-gate.sh"
export CLAUDE_PLUGIN_ROOT="$ROOT_DIR/plugins/skein"

pass_count=0
fail_count=0
pass() {
	echo "PASS: $1"
	pass_count=$((pass_count + 1))
}
fail() {
	echo "FAIL: $1"
	fail_count=$((fail_count + 1))
}
assert_eq() {
	local actual="$1" expected="$2" label="$3"
	if [[ "$actual" == "$expected" ]]; then
		pass "$label"
	else
		fail "$label (expected '$expected', got '$actual')"
	fi
}

if [[ ! -f "$GATE_BOUNDED" ]]; then
	fail "gate-bounded.sh missing: $GATE_BOUNDED"
	echo ""
	echo "Results: $pass_count passed, $fail_count failed"
	exit 1
fi
if [[ ! -x "$RUN_GATE" ]]; then
	fail "run-gate.sh missing or not executable: $RUN_GATE"
	echo ""
	echo "Results: $pass_count passed, $fail_count failed"
	exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
	fail "jq is required to run this test"
	echo ""
	echo "Results: $pass_count passed, $fail_count failed"
	exit 1
fi

WORKDIR="$(mktemp -d)"
DECOY_PID=""
cleanup() {
	if [[ -n "$DECOY_PID" ]]; then
		kill -KILL "$DECOY_PID" 2>/dev/null || true
	fi
	rm -rf "$WORKDIR"
}
trap cleanup EXIT

# A small runner so `gate_run_bounded` can be exercised under an arbitrary
# restricted PATH (for the shim-fallback cases) without quoting the sourced
# function call through `bash -c`.
RUNNER="$WORKDIR/run-bounded.sh"
cat >"$RUNNER" <<EOF
#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=/dev/null
. "$GATE_BOUNDED"
gate_run_bounded "\$@"
EOF
chmod +x "$RUNNER"

# PATH with GNU/Homebrew \`timeout\` (and \`gtimeout\`) hidden — this matches
# the plan's stated host facts (timeout is Homebrew coreutils only; no
# \`setsid(1)\`), so this is the "shim" fallback path.
HIDDEN_TIMEOUT_PATH="/usr/bin:/bin:/sbin"
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
	if PATH="$HIDDEN_TIMEOUT_PATH" command -v timeout >/dev/null 2>&1 ||
		PATH="$HIDDEN_TIMEOUT_PATH" command -v gtimeout >/dev/null 2>&1; then
		fail "test setup: \`timeout\`/\`gtimeout\` still resolvable under $HIDDEN_TIMEOUT_PATH — cannot exercise the shim path on this host"
	else
		pass "test setup: \`timeout\`/\`gtimeout\` successfully hidden from PATH ($HIDDEN_TIMEOUT_PATH) for shim-path cases"
	fi
else
	pass "test setup: no GNU timeout present at all — every case below already exercises the shim path"
fi

# --- Cross-path envelope-parity helper ------------------------------------
# Runs the same stub under the real PATH (GNU-timeout path) and under
# HIDDEN_TIMEOUT_PATH (shim path), asserting the two envelopes are
# structurally identical modulo duration_s. This is the "run twice with
# timeout hidden from PATH -> identical envelope" criterion read as
# *equivalence* rather than *repeatability* (finding 6's root cause).

assert_envelope_parity() {
	local env_gnu="$1" env_shim="$2" label="$3"
	if [[ ! -f "$env_gnu" || ! -f "$env_shim" ]]; then
		fail "$label: GNU-timeout and shim paths produce identical envelopes (modulo duration_s) — one or both envelopes missing (gnu=$([[ -f "$env_gnu" ]] && echo present || echo missing), shim=$([[ -f "$env_shim" ]] && echo present || echo missing))"
		return
	fi
	local shape_gnu shape_shim
	shape_gnu="$(jq -S 'del(.duration_s)' "$env_gnu" 2>/dev/null || echo "PARSE_ERROR")"
	shape_shim="$(jq -S 'del(.duration_s)' "$env_shim" 2>/dev/null || echo "PARSE_ERROR")"
	assert_eq "$shape_gnu" "$shape_shim" "$label: GNU-timeout and shim paths produce identical envelopes (modulo duration_s)"
}

# --- Case 1: expiry — tool writes valid JSON then hangs past budget -------
# Kill-after grace window is unified at 10s (kill_after_s) on both paths, so
# the child-death poll and elapsed bounds below are sized for that.

run_expiry_case() {
	local label="$1" test_path="$2"
	local stub="$WORKDIR/stub-expire-$label.sh"
	local envelope="$WORKDIR/envelope-expire-$label.json"
	local toolout="$WORKDIR/toolout-expire-$label.json"

	cat >"$stub" <<'STUB'
#!/usr/bin/env bash
echo '{"status":"ok","findings":[]}'
sleep 5
STUB
	chmod +x "$stub"
	rm -f "$envelope" "$toolout"

	local start end elapsed rc=0
	start="$(date +%s)"
	PATH="$test_path" "$RUNNER" 2 "$envelope" "$toolout" -- "$stub" >/dev/null 2>&1 || rc=$?
	end="$(date +%s)"
	elapsed=$((end - start))

	if [[ "$elapsed" -le 25 ]]; then
		pass "$label: gate_run_bounded returns well under the natural 5s sleep (elapsed=${elapsed}s), proving the kill fired rather than waiting it out"
	else
		fail "$label: gate_run_bounded took ${elapsed}s — looks like it waited for the stub instead of killing it at the 2s budget"
	fi

	if [[ -f "$envelope" ]]; then
		pass "$label: envelope written on expiry"
	else
		fail "$label: no envelope written on expiry: $envelope"
		return
	fi

	if [[ -f "$toolout" ]]; then
		fail "$label: tool-out was NOT removed on expiry (must be removed so normalize never reads a half-written clean-looking file)"
	else
		pass "$label: tool-out removed on expiry"
	fi

	assert_eq "$(jq -r '.status' "$envelope")" "skipped" "$label: envelope status is 'skipped' on expiry"

	local notes
	notes="$(jq -r '.notes // empty' "$envelope")"
	if [[ "$notes" == DEGRADED:* ]]; then
		pass "$label: envelope notes starts with 'DEGRADED:'"
	else
		fail "$label: envelope notes does not start with 'DEGRADED:' (got '$notes')"
	fi

	local duration_s
	duration_s="$(jq -r '.duration_s // empty' "$envelope")"
	if [[ -n "$duration_s" && "$duration_s" != "null" ]]; then
		pass "$label: envelope carries a populated duration_s ($duration_s)"
	else
		fail "$label: envelope duration_s missing/null"
	fi

	local normalize_rc=0
	"$RUN_GATE" normalize --gate codex-review --autofix-cache "$WORKDIR/cache-$label.jsonl" "$envelope" >/dev/null 2>&1 || normalize_rc=$?
	assert_eq "$normalize_rc" "4" "$label: run-gate.sh normalize on the DEGRADED envelope exits 4 (non-clean-pass signal)"
}

env_expire_gnu="$WORKDIR/envelope-expire-gnu-timeout.json"
env_expire_shim="$WORKDIR/envelope-expire-shim.json"
run_expiry_case "gnu-timeout" "$PATH"
run_expiry_case "shim" "$HIDDEN_TIMEOUT_PATH"
assert_envelope_parity "$env_expire_gnu" "$env_expire_shim" "expiry case"

# --- Case: shim determinism — run twice, structurally identical envelope --

env1="$WORKDIR/envelope-shim-repeat-1.json"
tool1="$WORKDIR/toolout-shim-repeat-1.json"
env2="$WORKDIR/envelope-shim-repeat-2.json"
tool2="$WORKDIR/toolout-shim-repeat-2.json"
stub_repeat="$WORKDIR/stub-repeat.sh"
cat >"$stub_repeat" <<'STUB'
#!/usr/bin/env bash
echo '{"status":"ok","findings":[]}'
sleep 5
STUB
chmod +x "$stub_repeat"

PATH="$HIDDEN_TIMEOUT_PATH" "$RUNNER" 2 "$env1" "$tool1" -- "$stub_repeat" >/dev/null 2>&1 || true
PATH="$HIDDEN_TIMEOUT_PATH" "$RUNNER" 2 "$env2" "$tool2" -- "$stub_repeat" >/dev/null 2>&1 || true

if [[ -f "$env1" && -f "$env2" ]]; then
	shape1="$(jq -S 'del(.duration_s)' "$env1" 2>/dev/null || echo "PARSE_ERROR")"
	shape2="$(jq -S 'del(.duration_s)' "$env2" 2>/dev/null || echo "PARSE_ERROR")"
	assert_eq "$shape1" "$shape2" "shim path: two back-to-back expiry runs produce structurally identical envelopes (modulo duration_s)"
else
	fail "shim path: one or both repeat-run envelopes missing (env1=$([[ -f "$env1" ]] && echo present || echo missing), env2=$([[ -f "$env2" ]] && echo present || echo missing))"
fi

# --- Case 2: crash-with-garbage — exit 0, invalid JSON in tool-out --------

run_invalid_json_case() {
	local label="$1" test_path="$2"
	local stub="$WORKDIR/stub-invalid-$label.sh"
	local envelope="$WORKDIR/envelope-invalid-$label.json"
	local toolout="$WORKDIR/toolout-invalid-$label.json"

	cat >"$stub" <<'STUB'
#!/usr/bin/env bash
printf '{"status":"ok","findings":['
STUB
	chmod +x "$stub"
	rm -f "$envelope" "$toolout"

	PATH="$test_path" "$RUNNER" 30 "$envelope" "$toolout" -- "$stub" >/dev/null 2>&1 || true

	if [[ ! -f "$envelope" ]]; then
		fail "$label: no envelope written for the invalid-JSON tool-out case"
		return
	fi

	assert_eq "$(jq -r '.status' "$envelope")" "error" \
		"$label: exit 0 with invalid-JSON tool-out yields status='error' (never a clean-looking envelope)"

	local normalize_rc=0
	"$RUN_GATE" normalize --gate codex-review --autofix-cache "$WORKDIR/cache-invalid-$label.jsonl" "$envelope" >/dev/null 2>&1 || normalize_rc=$?
	assert_eq "$normalize_rc" "4" "$label: run-gate.sh normalize on the error envelope exits 4"
}

env_invalid_gnu="$WORKDIR/envelope-invalid-default-path.json"
env_invalid_shim="$WORKDIR/envelope-invalid-shim.json"
run_invalid_json_case "default-path" "$PATH"
run_invalid_json_case "shim" "$HIDDEN_TIMEOUT_PATH"
assert_envelope_parity "$env_invalid_gnu" "$env_invalid_shim" "invalid-JSON case"

# --- Case: non-object valid JSON — must not zero-byte the envelope --------
# [1,2] is valid JSON but not an object; the old `jq -e .` gate let it
# through to `. + {duration_s...}`, which fails on a non-object and leaves
# a zero-byte envelope (finding 2's direct regression).

run_non_object_json_case() {
	local label="$1" test_path="$2"
	local stub="$WORKDIR/stub-non-object-$label.sh"
	local envelope="$WORKDIR/envelope-non-object-$label.json"
	local toolout="$WORKDIR/toolout-non-object-$label.json"

	cat >"$stub" <<'STUB'
#!/usr/bin/env bash
printf '[1,2]'
STUB
	chmod +x "$stub"
	rm -f "$envelope" "$toolout"

	PATH="$test_path" "$RUNNER" 30 "$envelope" "$toolout" -- "$stub" >/dev/null 2>&1 || true

	if [[ -s "$envelope" ]]; then
		pass "$label: non-object valid JSON ([1,2]) tool-out does NOT leave a zero-byte envelope"
	else
		fail "$label: non-object valid JSON ([1,2]) tool-out left a missing or zero-byte envelope: $envelope"
		return
	fi

	assert_eq "$(jq -r '.status' "$envelope")" "error" \
		"$label: non-object valid JSON tool-out yields status='error'"

	local normalize_rc=0
	"$RUN_GATE" normalize --gate codex-review --autofix-cache "$WORKDIR/cache-non-object-$label.jsonl" "$envelope" >/dev/null 2>&1 || normalize_rc=$?
	assert_eq "$normalize_rc" "4" "$label: run-gate.sh normalize on the non-object-JSON error envelope exits 4"
}

env_non_object_gnu="$WORKDIR/envelope-non-object-gnu-timeout.json"
env_non_object_shim="$WORKDIR/envelope-non-object-shim.json"
run_non_object_json_case "gnu-timeout" "$PATH"
run_non_object_json_case "shim" "$HIDDEN_TIMEOUT_PATH"
assert_envelope_parity "$env_non_object_gnu" "$env_non_object_shim" "non-object-JSON case"

# --- Case: object without a usable .status ---------------------------------
# {"findings":[]} and {"status":null,...} are objects but have no usable
# string .status — must also fall through to the status:"error" envelope
# (guards the `(.status|type)=="string"` predicate specifically).

run_no_status_case() {
	local label="$1" test_path="$2" payload="$3"
	local stub="$WORKDIR/stub-no-status-$label.sh"
	local envelope="$WORKDIR/envelope-no-status-$label.json"
	local toolout="$WORKDIR/toolout-no-status-$label.json"

	cat >"$stub" <<STUB
#!/usr/bin/env bash
printf '%s' '$payload'
STUB
	chmod +x "$stub"
	rm -f "$envelope" "$toolout"

	PATH="$test_path" "$RUNNER" 30 "$envelope" "$toolout" -- "$stub" >/dev/null 2>&1 || true

	if [[ -s "$envelope" ]]; then
		pass "$label: object tool-out with no usable .status does NOT leave a zero-byte envelope"
	else
		fail "$label: object tool-out with no usable .status left a missing or zero-byte envelope: $envelope"
		return
	fi

	assert_eq "$(jq -r '.status' "$envelope")" "error" \
		"$label: object tool-out with no usable .status yields status='error'"

	local normalize_rc=0
	"$RUN_GATE" normalize --gate codex-review --autofix-cache "$WORKDIR/cache-no-status-$label.jsonl" "$envelope" >/dev/null 2>&1 || normalize_rc=$?
	assert_eq "$normalize_rc" "4" "$label: run-gate.sh normalize on the no-status error envelope exits 4"
}

env_no_status_gnu="$WORKDIR/envelope-no-status-gnu-timeout-no-status-key.json"
env_no_status_shim="$WORKDIR/envelope-no-status-shim-no-status-key.json"
run_no_status_case "gnu-timeout-no-status-key" "$PATH" '{"findings":[]}'
run_no_status_case "shim-no-status-key" "$HIDDEN_TIMEOUT_PATH" '{"findings":[]}'
assert_envelope_parity "$env_no_status_gnu" "$env_no_status_shim" "no-status-key object case"

env_null_status_gnu="$WORKDIR/envelope-no-status-gnu-timeout-null-status.json"
env_null_status_shim="$WORKDIR/envelope-no-status-shim-null-status.json"
run_no_status_case "gnu-timeout-null-status" "$PATH" '{"status":null,"findings":[]}'
run_no_status_case "shim-null-status" "$HIDDEN_TIMEOUT_PATH" '{"status":null,"findings":[]}'
assert_envelope_parity "$env_null_status_gnu" "$env_null_status_shim" "null-status object case"

# --- Case 3: process-group kill — SIGTERM-ignoring child dies with parent -
# Also the primary regression test for finding 1: on the GNU-timeout path
# `timeout --kill-after` escalates to SIGKILL (exit 137) for exactly this
# stub, which the old `exit_code -eq 124` predicate misread as a clean pass.

run_sigterm_ignoring_case() {
	local label="$1" test_path="$2"
	local stub="$WORKDIR/stub-sigterm-$label.sh"
	local envelope="$WORKDIR/envelope-sigterm-$label.json"
	local toolout="$WORKDIR/toolout-sigterm-$label.json"
	local pidfile="$WORKDIR/child-pid-$label.txt"
	rm -f "$pidfile" "$envelope" "$toolout"

	cat >"$stub" <<STUB
#!/usr/bin/env bash
trap '' TERM
echo '{"status":"ok","findings":[]}'
( trap '' TERM; sleep 30 ) &
echo \$! >"$pidfile"
wait
STUB
	chmod +x "$stub"

	PATH="$test_path" "$RUNNER" 2 "$envelope" "$toolout" -- "$stub" "$pidfile" >/dev/null 2>&1 || true

	if [[ ! -s "$pidfile" ]]; then
		fail "$label: SIGTERM-ignoring child never recorded its pid — stub setup failed, cannot assert on process death"
		return
	fi
	local child_pid
	child_pid="$(cat "$pidfile")"

	# Poll: gate_run_bounded is documented synchronous, so the child should
	# already be dead by the time it returns; allow a grace window sized for
	# the unified 10s kill_after_s escalation.
	local alive=1 i
	for i in $(seq 1 20); do
		if ! kill -0 "$child_pid" 2>/dev/null; then
			alive=0
			break
		fi
		sleep 1
	done

	if [[ "$alive" -eq 0 ]]; then
		pass "$label: SIGTERM-ignoring child (pid $child_pid) is dead after budget expiry (process-group kill escalated past the ignored TERM)"
	else
		fail "$label: SIGTERM-ignoring child (pid $child_pid) is STILL ALIVE after budget expiry + grace window"
	fi

	if [[ ! -f "$envelope" ]]; then
		fail "$label: no envelope written for the SIGTERM-ignoring case"
		return
	fi

	assert_eq "$(jq -r '.status' "$envelope")" "skipped" \
		"$label: SIGTERM-ignoring stub yields status='skipped' (not silently 'approve' from a misread 137 exit)"

	local notes
	notes="$(jq -r '.notes // empty' "$envelope")"
	if [[ "$notes" == DEGRADED:* ]]; then
		pass "$label: SIGTERM-ignoring stub envelope notes starts with 'DEGRADED:'"
	else
		fail "$label: SIGTERM-ignoring stub envelope notes does not start with 'DEGRADED:' (got '$notes')"
	fi

	local degraded_reason
	degraded_reason="$(jq -r '.degraded_reason // empty' "$envelope")"
	if [[ -n "$degraded_reason" && "$degraded_reason" != "null" ]]; then
		pass "$label: SIGTERM-ignoring stub envelope carries a non-null degraded_reason"
	else
		fail "$label: SIGTERM-ignoring stub envelope degraded_reason missing/null"
	fi

	if [[ -f "$toolout" ]]; then
		fail "$label: SIGTERM-ignoring stub tool-out was NOT removed"
	else
		pass "$label: SIGTERM-ignoring stub tool-out removed"
	fi

	local normalize_rc=0
	"$RUN_GATE" normalize --gate codex-review --autofix-cache "$WORKDIR/cache-sigterm-$label.jsonl" "$envelope" >/dev/null 2>&1 || normalize_rc=$?
	assert_eq "$normalize_rc" "4" "$label: run-gate.sh normalize on the SIGTERM-ignoring DEGRADED envelope exits 4"
}

env_sigterm_gnu="$WORKDIR/envelope-sigterm-gnu-timeout.json"
env_sigterm_shim="$WORKDIR/envelope-sigterm-shim.json"
run_sigterm_ignoring_case "gnu-timeout" "$PATH"
run_sigterm_ignoring_case "shim" "$HIDDEN_TIMEOUT_PATH"
assert_envelope_parity "$env_sigterm_gnu" "$env_sigterm_shim" "SIGTERM-ignoring case"

# --- Case: sweep scoping — decoy outside the gate's process group survives
# (finding 3). Under the old host-wide `pkill -f 'codex exec review'` this
# decoy would be killed; under the pgid-scoped sweep it must survive.

run_sweep_scoping_case() {
	local label="$1" test_path="$2"
	local stub="$WORKDIR/stub-sweep-$label.sh"
	local envelope="$WORKDIR/envelope-sweep-$label.json"
	local toolout="$WORKDIR/toolout-sweep-$label.json"

	cat >"$stub" <<'STUB'
#!/usr/bin/env bash
trap '' TERM
echo '{"status":"ok","findings":[]}'
sleep 30
STUB
	chmod +x "$stub"
	rm -f "$envelope" "$toolout"

	PATH="$test_path" "$RUNNER" 2 "$envelope" "$toolout" -- "$stub" >/dev/null 2>&1 || true

	if [[ -n "$DECOY_PID" ]] && kill -0 "$DECOY_PID" 2>/dev/null; then
		pass "$label: sweep did not kill the decoy 'codex exec review'-named process outside the gate's process group"
	else
		fail "$label: decoy process (pid $DECOY_PID) is gone — expiry sweep killed something outside its own process group"
	fi
}

# Decoy lives in its own subshell/process group (backgrounded from this
# script's top-level shell, not from inside $RUNNER's process group) and
# carries the old pattern-match string in its argv0.
bash -c 'exec -a "codex exec review --decoy" sleep 60' &
DECOY_PID=$!
sleep 0.2 # let the decoy actually start before the expiry case below.

run_sweep_scoping_case "gnu-timeout" "$PATH"
if [[ -n "$DECOY_PID" ]] && kill -0 "$DECOY_PID" 2>/dev/null; then
	run_sweep_scoping_case "shim" "$HIDDEN_TIMEOUT_PATH"
else
	fail "sweep-scoping (shim): decoy was already gone before the shim-path case ran — cannot exercise this case"
fi

if [[ -n "$DECOY_PID" ]]; then
	kill -KILL "$DECOY_PID" 2>/dev/null || true
	wait "$DECOY_PID" 2>/dev/null || true
	DECOY_PID=""
fi

# --- Case: budget validation — non-positive/non-numeric budget -----------
# finding 4b/4c: gate_run_bounded must return 2 before launching anything,
# and must not leave a stale envelope behind from a previous round.

run_bad_budget_case() {
	local label="$1" budget="$2"
	local envelope="$WORKDIR/envelope-bad-budget-$label.json"
	local toolout="$WORKDIR/toolout-bad-budget-$label.json"
	local marker="$WORKDIR/marker-bad-budget-$label.txt"
	local stub="$WORKDIR/stub-bad-budget-$label.sh"
	rm -f "$envelope" "$toolout" "$marker"

	cat >"$stub" <<STUB
#!/usr/bin/env bash
touch "$marker"
echo '{"status":"ok","findings":[]}'
STUB
	chmod +x "$stub"

	# Pre-existing (stale) envelope from a "previous round" at this path.
	echo '{"status":"approve","findings":[],"duration_s":1,"degraded_reason":null}' >"$envelope"

	local rc=0
	"$RUNNER" "$budget" "$envelope" "$toolout" -- "$stub" >/dev/null 2>&1 || rc=$?

	assert_eq "$rc" "2" "budget='$budget': gate_run_bounded returns 2 for a non-positive/non-numeric budget"

	if [[ ! -e "$envelope" ]]; then
		pass "budget='$budget': stale pre-existing envelope was removed, no new envelope written"
	else
		fail "budget='$budget': envelope still present after a rejected budget (expected removed): $(cat "$envelope" 2>/dev/null)"
	fi

	if [[ ! -e "$marker" ]]; then
		pass "budget='$budget': stub never ran (marker file absent)"
	else
		fail "budget='$budget': stub ran despite the budget being rejected (marker file present)"
	fi
}

run_bad_budget_case "zero" "0"
run_bad_budget_case "negative" "-1"
run_bad_budget_case "non-numeric" "abc"

# --- Case 5: success path — exit 0, valid JSON, well within budget --------

run_success_case() {
	local label="$1" test_path="$2"
	local stub="$WORKDIR/stub-success-$label.sh"
	local envelope="$WORKDIR/envelope-success-$label.json"
	local toolout="$WORKDIR/toolout-success-$label.json"

	cat >"$stub" <<'STUB'
#!/usr/bin/env bash
echo '{"status":"approve","findings":[]}'
STUB
	chmod +x "$stub"
	rm -f "$envelope" "$toolout"

	local rc=0
	PATH="$test_path" "$RUNNER" 30 "$envelope" "$toolout" -- "$stub" >/dev/null 2>&1 || rc=$?

	if [[ ! -f "$envelope" ]]; then
		fail "$label: no envelope written on the success path"
		return
	fi

	assert_eq "$(jq -r '.status' "$envelope")" "approve" \
		"$label: success-path envelope propagates the tool's own status (approve)"

	local duration_s
	duration_s="$(jq -r '.duration_s // empty' "$envelope")"
	if [[ -n "$duration_s" && "$duration_s" != "null" ]]; then
		pass "$label: success-path envelope carries a populated duration_s"
	else
		fail "$label: success-path envelope duration_s missing/null"
	fi

	local degraded
	degraded="$(jq -r '.notes // empty' "$envelope")"
	if [[ "$degraded" != DEGRADED:* ]]; then
		pass "$label: success-path envelope notes is not DEGRADED-prefixed"
	else
		fail "$label: success-path envelope wrongly carries a DEGRADED note"
	fi

	local normalize_rc=0
	"$RUN_GATE" normalize --gate codex-review --autofix-cache "$WORKDIR/cache-success-$label.jsonl" "$envelope" >/dev/null 2>&1 || normalize_rc=$?
	assert_eq "$normalize_rc" "0" "$label: run-gate.sh normalize on a clean success envelope exits 0"
}

run_success_case "default-path" "$PATH"

echo ""
echo "Results: $pass_count passed, $fail_count failed"
[[ "$fail_count" -eq 0 ]]
