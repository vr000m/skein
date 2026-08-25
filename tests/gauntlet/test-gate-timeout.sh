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

	# r4 F16/F8 INVERSION: a rejected budget is a USAGE error, and rc=2 now
	# means "no command ran, no envelope was written, and <envelope-out> was
	# not touched -- do not read it". The stale envelope therefore survives
	# UNCHANGED; what the caller must not do is read it. Asserting on its
	# CONTENT (not merely its presence) is the real check: it proves nothing
	# was written over it either.
	if [[ -e "$envelope" ]] && grep -q '"status":"approve"' "$envelope"; then
		pass "budget='$budget': rc=2 left the stale envelope byte-untouched, and wrote no new one"
	else
		fail "budget='$budget': a usage error modified or removed <envelope-out> (present=$([[ -e "$envelope" ]] && echo yes || echo no)): $(cat "$envelope" 2>/dev/null)"
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

# --- Case 6 (F5): optional leading `--gate <name>` stamps `.gate` on the
# envelope on ALL THREE exit paths (clean, error, timeout) -- the
# orchestrator is authoritative on slot identity, overriding whatever the
# tool self-reported (or the null gate-bounded.sh writes on its own error/
# timeout paths). Omitting --gate must remain byte-identical to today
# (already covered by the un-flagged cases above).

run_gate_flag_clean_case() {
	local stub="$WORKDIR/stub-gateflag-clean.sh"
	local envelope="$WORKDIR/envelope-gateflag-clean.json"
	local toolout="$WORKDIR/toolout-gateflag-clean.json"

	cat >"$stub" <<'STUB'
#!/usr/bin/env bash
echo '{"status":"approve","findings":[]}'
STUB
	chmod +x "$stub"
	rm -f "$envelope" "$toolout"

	"$RUNNER" --gate my-clean-gate 30 "$envelope" "$toolout" -- "$stub" >/dev/null 2>&1 || true

	if [[ ! -f "$envelope" ]]; then
		fail "--gate (clean path): no envelope written"
		return
	fi
	assert_eq "$(jq -r '.gate' "$envelope")" "my-clean-gate" \
		"--gate (clean path): stamps .gate = my-clean-gate, overriding the tool's own status"
	assert_eq "$(jq -r '.status' "$envelope")" "approve" \
		"--gate (clean path): .status still passes through the tool's own value unchanged"
}

run_gate_flag_error_case() {
	local stub="$WORKDIR/stub-gateflag-error.sh"
	local envelope="$WORKDIR/envelope-gateflag-error.json"
	local toolout="$WORKDIR/toolout-gateflag-error.json"

	cat >"$stub" <<'STUB'
#!/usr/bin/env bash
printf 'not json at all'
STUB
	chmod +x "$stub"
	rm -f "$envelope" "$toolout"

	"$RUNNER" --gate my-error-gate 30 "$envelope" "$toolout" -- "$stub" >/dev/null 2>&1 || true

	if [[ ! -f "$envelope" ]]; then
		fail "--gate (error path): no envelope written"
		return
	fi
	assert_eq "$(jq -r '.status' "$envelope")" "error" \
		"--gate (error path): invalid tool-out still yields status='error'"
	assert_eq "$(jq -r '.gate' "$envelope")" "my-error-gate" \
		"--gate (error path): stamps .gate = my-error-gate (never the hardcoded null gate-bounded.sh writes without --gate)"
}

run_gate_flag_timeout_case() {
	local stub="$WORKDIR/stub-gateflag-timeout.sh"
	local envelope="$WORKDIR/envelope-gateflag-timeout.json"
	local toolout="$WORKDIR/toolout-gateflag-timeout.json"

	cat >"$stub" <<'STUB'
#!/usr/bin/env bash
echo '{"status":"ok","findings":[]}'
sleep 5
STUB
	chmod +x "$stub"
	rm -f "$envelope" "$toolout"

	"$RUNNER" --gate my-timeout-gate 2 "$envelope" "$toolout" -- "$stub" >/dev/null 2>&1 || true

	if [[ ! -f "$envelope" ]]; then
		fail "--gate (timeout path): no envelope written"
		return
	fi
	assert_eq "$(jq -r '.status' "$envelope")" "skipped" \
		"--gate (timeout path): expiry still yields status='skipped'"
	assert_eq "$(jq -r '.gate' "$envelope")" "my-timeout-gate" \
		"--gate (timeout path): stamps .gate = my-timeout-gate (never the hardcoded null gate-bounded.sh writes without --gate)"
}

run_gate_flag_clean_case
run_gate_flag_error_case
run_gate_flag_timeout_case

# --- Case 7 (G2, finding 5): a bare exit 124 INSIDE budget is not expiry ---
# The old predicate was `exit_code != 0 && (exit_code == 124 || duration >=
# budget)`, so an in-budget command that itself exits 124 was misclassified
# as expired: its perfectly valid tool-out was deleted and a degraded
# `skipped` envelope was emitted. Expiry must come from the runner's own
# recorded state, not from a code the reviewed command can choose.

bare124_case() {
	local label="$1" runpath="$2" envelope="$3" toolout="$4"
	local stub="$WORKDIR/stub-bare124.sh"
	cat >"$stub" <<'EOF'
#!/usr/bin/env bash
printf '{"status":"approve","findings":[]}'
exit 124
EOF
	chmod +x "$stub"

	local rc=0
	PATH="$runpath" "$RUNNER" 60 "$envelope" "$toolout" -- "$stub" || rc=$?
	assert_eq "$rc" "0" "$label: gate_run_bounded returns 0 on a completed (non-expiry) run"
	if [[ ! -s "$envelope" ]]; then
		fail "$label: no envelope written"
		return
	fi
	assert_eq "$(jq -r '.status' "$envelope")" "approve" \
		"$label: an in-budget exit 124 with valid tool-out passes through as 'approve', not 'skipped'"
	assert_eq "$(jq -r '.degraded_reason' "$envelope")" "null" \
		"$label: an in-budget exit 124 is not marked DEGRADED"
	if [[ -s "$toolout" ]]; then
		pass "$label: tool-out is RETAINED on an in-budget exit 124 (not deleted as an expiry artefact)"
	else
		fail "$label: tool-out was deleted — the run was misclassified as expiry"
	fi
}

env_bare124_gnu="$WORKDIR/env-bare124-gnu.json"
env_bare124_shim="$WORKDIR/env-bare124-shim.json"
bare124_case "bare-124 (GNU timeout path)" "$PATH" "$env_bare124_gnu" "$WORKDIR/tool-bare124-gnu.json"
bare124_case "bare-124 (shim path)" "$HIDDEN_TIMEOUT_PATH" "$env_bare124_shim" "$WORKDIR/tool-bare124-shim.json"
assert_envelope_parity "$env_bare124_gnu" "$env_bare124_shim" "bare-124 case"

# --- Case 8 (G2, finding 4): a failing `ps` must not abort the expiry branch
# `self_pgid="$(ps ... | tr ...)"` is a pipeline; under the caller's
# `set -euo pipefail` a `ps` EPERM (macOS sandbox) made the assignment
# non-zero and `set -e` aborted _gate_sweep_pgid — and with it the whole
# expiry branch, BEFORE the `skipped` envelope was ever written.

ps_stub_dir="$WORKDIR/ps-stub-bin"
mkdir -p "$ps_stub_dir"
cat >"$ps_stub_dir/ps" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$ps_stub_dir/ps"

hang_stub="$WORKDIR/stub-hang-ps.sh"
cat >"$hang_stub" <<'EOF'
#!/usr/bin/env bash
printf '{"status":"approve","findings":[]}'
sleep 30
EOF
chmod +x "$hang_stub"

env_ps="$WORKDIR/env-ps-fail.json"
tool_ps="$WORKDIR/tool-ps-fail.json"
ps_rc=0
PATH="$ps_stub_dir:$HIDDEN_TIMEOUT_PATH" "$RUNNER" 1 "$env_ps" "$tool_ps" -- "$hang_stub" || ps_rc=$?
assert_eq "$ps_rc" "0" "failing-ps: gate_run_bounded still returns 0 when \`ps\` fails during the expiry sweep"
if [[ -s "$env_ps" ]]; then
	assert_eq "$(jq -r '.status' "$env_ps")" "skipped" \
		"failing-ps: the DEGRADED 'skipped' envelope is still written when \`ps\` fails"
else
	fail "failing-ps: expiry branch aborted before writing the envelope (the exact set -e hazard)"
fi

# --- Case 9 (G2, finding 24): a recorded pgid naming a DEAD leader is a
# silent no-op, and the envelope is still written. `wait` reaps the
# timeout/shim child before the expiry branch runs, so the recorded pgid is
# free for PID reuse; the sweep must confirm the group leader is still the
# recorded pid before signalling anything.

dead_leader_check() {
	# Source the lib directly so _gate_sweep_pgid can be called in isolation
	# against a pgid whose leader is certainly gone.
	local probe="$WORKDIR/probe-dead-leader.sh"
	cat >"$probe" <<EOF
#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=/dev/null
. "$GATE_BOUNDED"
sleep 30 &
victim=\$!
kill -KILL "\$victim" 2>/dev/null || true
wait "\$victim" 2>/dev/null || true
_gate_sweep_pgid "\$victim"
echo SWEEP_RETURNED
EOF
	chmod +x "$probe"
	local out rc=0
	out="$(bash "$probe" 2>&1)" || rc=$?
	if [[ $rc -eq 0 && "$out" == *SWEEP_RETURNED* ]]; then
		pass "dead-leader sweep: _gate_sweep_pgid on a reaped pid returns cleanly (silent no-op)"
	else
		fail "dead-leader sweep: _gate_sweep_pgid on a reaped pid failed (rc=$rc, out='$out')"
	fi
}
dead_leader_check

# --- Case 10 (G3, finding 6): `.findings` must be a real array to pass ----
# The old acceptance gate checked only `.status | type == "string"`.
# `run-gate.sh normalize` then reads `.findings[]?`, and the `?` swallows a
# null/non-array field — so a malformed gate reported as CLEAN.

findings_shape_case() {
	local label="$1" payload="$2" envelope="$3" toolout="$4"
	local stub="$WORKDIR/stub-findings-shape.sh"
	cat >"$stub" <<EOF
#!/usr/bin/env bash
printf '%s' '$payload'
exit 0
EOF
	chmod +x "$stub"
	local rc=0
	"$RUNNER" 60 "$envelope" "$toolout" -- "$stub" || rc=$?
	assert_eq "$rc" "0" "$label: gate_run_bounded returns 0"
	if [[ ! -s "$envelope" ]]; then
		fail "$label: no envelope written"
		return
	fi
	assert_eq "$(jq -r '.status' "$envelope")" "error" \
		"$label: falls through to the 'error' envelope rather than passing through as clean"
	if [[ "$(jq -r '.notes' "$envelope")" == *"object"* ]]; then
		pass "$label: the error envelope's notes name the shape failure"
	else
		fail "$label: the error envelope's notes do not name the shape failure"
	fi
}

findings_shape_case "null-findings" '{"status":"approve","findings":null}' \
	"$WORKDIR/env-findings-null.json" "$WORKDIR/tool-findings-null.json"
findings_shape_case "missing-findings" '{"status":"approve"}' \
	"$WORKDIR/env-findings-missing.json" "$WORKDIR/tool-findings-missing.json"
findings_shape_case "object-findings" '{"status":"approve","findings":{"a":1}}' \
	"$WORKDIR/env-findings-object.json" "$WORKDIR/tool-findings-object.json"

# A well-formed envelope with a real (even empty) findings array still passes.
wellformed_env="$WORKDIR/env-findings-ok.json"
wellformed_stub="$WORKDIR/stub-findings-ok.sh"
cat >"$wellformed_stub" <<'EOF'
#!/usr/bin/env bash
printf '{"status":"approve","findings":[]}'
EOF
chmod +x "$wellformed_stub"
"$RUNNER" 60 "$wellformed_env" "$WORKDIR/tool-findings-ok.json" -- "$wellformed_stub"
assert_eq "$(jq -r '.status' "$wellformed_env")" "approve" \
	"well-formed findings array: the tightened gate does not regress the clean path"

# --- A5: the sweep must fire when the LEADER dies on TERM -----------------
# Codex addendum A5. Distinct from Case 3: there the gate itself ignores
# TERM, so `timeout --kill-after` escalates to SIGKILL on the whole group and
# the descendant dies as a side effect. Here the gate leader dies on the
# FIRST TERM, so nothing ever escalates -- the shim broke out of its grace
# loop with `escalated` false, and on the timeout(1) path the recorded pgid
# is timeout's own pid, already reaped by `wait`, so the old leader-liveness
# guard in _gate_sweep_pgid returned early on EVERY expiry. Either way no
# SIGKILL reached a `trap "" TERM` descendant.

run_leader_dies_sweep_case() {
	local label="$1" test_path="$2"
	local stub="$WORKDIR/stub-sweep-$label.sh"
	local envelope="$WORKDIR/envelope-sweep-$label.json"
	local toolout="$WORKDIR/toolout-sweep-$label.json"
	local pidfile="$WORKDIR/sweep-child-pid-$label.txt"
	rm -f "$pidfile" "$envelope" "$toolout"

	# The stub does NOT trap TERM: it dies on the first signal. Its
	# descendant does, and must still be swept.
	cat >"$stub" <<STUB
#!/usr/bin/env bash
echo '{"status":"ok","findings":[]}'
( trap '' TERM; sleep 300 ) &
echo \$! >"$pidfile"
sleep 300
STUB
	chmod +x "$stub"

	PATH="$test_path" "$RUNNER" 1 "$envelope" "$toolout" -- "$stub" >/dev/null 2>&1 || true

	if [[ ! -s "$pidfile" ]]; then
		fail "$label: sweep stub never recorded its descendant pid"
		return
	fi
	local child_pid
	child_pid="$(cat "$pidfile")"

	local alive=1 i
	for i in $(seq 1 25); do
		if ! kill -0 "$child_pid" 2>/dev/null; then
			alive=0
			break
		fi
		sleep 1
	done

	if [[ "$alive" -eq 0 ]]; then
		pass "A5/$label: a TERM-ignoring descendant is swept even though the gate leader died on TERM"
	else
		fail "A5/$label: TERM-ignoring descendant (pid $child_pid) SURVIVED the expiry sweep"
		kill -9 "$child_pid" 2>/dev/null || true
	fi

	assert_eq "$(jq -r '.status' "$envelope")" "skipped" \
		"A5/$label: the swept expiry still writes a skipped envelope"
}

run_leader_dies_sweep_case "gnu-timeout" "$PATH"
run_leader_dies_sweep_case "shim" "$HIDDEN_TIMEOUT_PATH"

# --- A11: a real non-zero exit inside budget is never misread as expiry ----
# `duration_s >= seconds` is an integer-second INFERENCE over `date +%s`. A
# command that exits on its own at true elapsed 0.7s under a 1s budget
# measures duration_s == 1 whenever those 0.7s straddle an epoch-second
# boundary -- and was then reclassified as a timeout: its VALID tool-out was
# deleted and a degraded `skipped` envelope replaced its real result. Bash
# 3.2 has no $EPOCHREALTIME and `date +%s%N` is GNU-only, so the fix removes
# the inference rather than sharpening the clock: the command records its own
# $? to an rc_file, and an absent/empty rc_file -- not the clock -- is what
# proves it never exited on its own.
#
# The stub sleeps 0.7s (comfortably inside the 1s budget, so it is never
# genuinely killed) and exits 3 with a VALID envelope. Across 50 runs the
# boundary is straddled roughly 70% of the time, so pre-fix this reports
# `skipped` on most iterations and post-fix on none.

a11_stub="$WORKDIR/stub-a11.sh"
cat >"$a11_stub" <<'EOF'
#!/usr/bin/env bash
printf '{"status":"reject","findings":[]}'
sleep 0.7
exit 3
EOF
chmod +x "$a11_stub"

a11_tmp="$WORKDIR/a11-tmp"
mkdir -p "$a11_tmp"
a11_before="$(find "$a11_tmp" -type f 2>/dev/null | wc -l | tr -d ' ')"
a11_skipped=0
a11_straddled=0
a11_env="$WORKDIR/a11-env.json"
a11_out="$WORKDIR/a11-out.json"
for i in $(seq 1 50); do
	rm -f "$a11_env" "$a11_out"
	TMPDIR="$a11_tmp" "$RUNNER" 1 "$a11_env" "$a11_out" -- "$a11_stub" >/dev/null 2>&1 || true
	a11_status="$(jq -r '.status // "MISSING"' "$a11_env" 2>/dev/null || echo PARSE_ERROR)"
	a11_dur="$(jq -r '.duration_s // -1' "$a11_env" 2>/dev/null || echo -1)"
	[[ "$a11_dur" -ge 1 ]] && a11_straddled=$((a11_straddled + 1))
	[[ "$a11_status" == "skipped" ]] && a11_skipped=$((a11_skipped + 1))
done

# Non-vacuity: if no iteration ever measured duration_s >= budget, the case
# never exercised the misreading and proves nothing.
if [[ "$a11_straddled" -gt 0 ]]; then
	pass "A11: non-vacuous -- $a11_straddled/50 runs measured duration_s >= the 1s budget while exiting on their own"
else
	fail "A11: vacuous -- no run straddled the epoch-second boundary, the misreading was never exercised"
fi

if [[ "$a11_skipped" -eq 0 ]]; then
	pass "A11: 50x a self-exiting 'exit 3' under a 1s budget is never clock-inferred as 'skipped'"
else
	fail "A11: $a11_skipped/50 runs deleted a valid tool-out and wrote a degraded 'skipped' envelope for an in-budget exit"
fi

# The tool's own result survives: `reject`, stamped, with its tool-out kept.
if [[ "$(jq -r '.status' "$a11_env" 2>/dev/null)" == "reject" ]]; then
	pass "A11: the self-exiting gate's own status reaches the envelope"
else
	fail "A11: the self-exiting gate's status was not passed through (got '$(jq -r '.status' "$a11_env" 2>/dev/null)')"
fi

# Temp-file lifecycle. BSD `mktemp` ignores \$TMPDIR when given no template,
# so the count below is only discriminating where it is honoured; the
# structural assertion that follows is the portable one -- a new temp file
# that is not removed on EVERY exit path leaks one file per gate invocation.
a11_after="$(find "$a11_tmp" -type f 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$a11_after" == "$a11_before" ]]; then
	pass "A11: no temp-file residue under \$TMPDIR across 50 bounded runs"
else
	fail "A11: temp-file leak -- \$TMPDIR went from $a11_before to $a11_after files across 50 runs"
fi

a11_pgid_rm="$(grep -c 'rm -f "\$pgid_file"' "$GATE_BOUNDED" || true)"
a11_rc_rm="$(grep -c 'rm -f "\$pgid_file" "\$state_file" "\$rc_file"' "$GATE_BOUNDED" || true)"
if [[ "$a11_pgid_rm" -gt 0 && "$a11_rc_rm" == "$a11_pgid_rm" ]]; then
	pass "A11: rc_file is removed on every path that removes pgid_file ($a11_rc_rm/$a11_pgid_rm)"
else
	fail "A11: rc_file is missing from $((a11_pgid_rm - a11_rc_rm)) of the $a11_pgid_rm pgid_file cleanup paths"
fi

# --- A12: the envelope holds exactly ONE JSON object ----------------------
# `jq -e` without --slurp reports only the LAST document of a stream and the
# pass-through filter maps over ALL of them, so a gate printing two envelopes
# wrote TWO stamped objects into the envelope file. The invariant ("the
# envelope holds one JSON object") was always the contract; it is now
# enforced, and a multi-document tool-out falls to the `error` envelope.

a12_stub="$WORKDIR/stub-a12.sh"
cat >"$a12_stub" <<'EOF'
#!/usr/bin/env bash
printf '{"status":"approve","findings":[]}
{"status":"reject","findings":[]}
'
EOF
chmod +x "$a12_stub"
a12_env="$WORKDIR/a12-env.json"
a12_out="$WORKDIR/a12-out.json"
"$RUNNER" 60 "$a12_env" "$a12_out" -- "$a12_stub" >/dev/null 2>&1 || true
a12_doc_count="$(jq -s 'length' "$a12_env" 2>/dev/null || echo PARSE_ERROR)"
assert_eq "$a12_doc_count" "1" "A12: a two-document tool-out yields exactly one envelope document"
assert_eq "$(jq -r -s '.[0].status' "$a12_env" 2>/dev/null || echo PARSE_ERROR)" "error" \
	"A12: a two-document tool-out is rejected to the 'error' envelope, not passed through"
a12_note="$(jq -r -s '.[0].notes // ""' "$a12_env" 2>/dev/null || echo "")"
if [[ "$a12_note" == *"more than one JSON document"* ]]; then
	pass "A12: the error envelope names the multi-document cause"
else
	fail "A12: the error envelope note does not name the multi-document cause (got '$a12_note')"
fi

# ---------------------------------------------------------------------------
# (G10) A `return 2` must never leave a stale envelope behind.
#
# The unlink used to sit AFTER the `$4 != "--"` check, so three usage errors
# returned 2 with a previous round's envelope still on disk. Two of them
# (`--gate` with no name; fewer than two arguments) genuinely cannot know
# <envelope-out> and are named as exemptions in the header. The third -- a
# missing `--` separator -- already knew the path, so it was an outright
# contract violation: a caller that ignores the return value reads the
# previous round's possibly-CLEAN envelope as this round's result.
# ---------------------------------------------------------------------------
g10_dir="$WORKDIR/g10"
mkdir -p "$g10_dir"
g10_env="$g10_dir/env.json"
g10_tool="$g10_dir/tool.out"

printf '%s' '{"status":"approve","notes":"stale from a previous round","findings":[],"gate":null,"duration_s":1,"degraded_reason":null}' >"$g10_env"
printf '%s' 'stale tool output' >"$g10_tool"
printf '%s' 'stale stderr' >"${g10_tool}.stderr"

set +e
"$RUNNER" 5 "$g10_env" "$g10_tool" NOTDASHDASH -- true >/dev/null 2>&1
g10_rc=$?
set -e
assert_eq "$g10_rc" "2" "G10: a missing -- separator returns 2"
# r4 F16/F8 INVERSION. The round-3 hoist bought "no stale envelope on a usage
# error" by unlinking UNVALIDATED positional tokens: with the arguments
# shifted, `$2`/`$3` are not yet known to be <envelope-out>/<tool-out>, so the
# unlink was removing a guess. The contract is now the stronger one: rc=2
# means NO FILESYSTEM EFFECT and <envelope-out> WAS NOT TOUCHED -- do not read
# it. The unlink moved below every usage check, where the paths are validated.
if [[ -e "$g10_env" ]]; then
	pass "G10: rc=2 on a missing \`--\` touches nothing -- <envelope-out> is left alone"
else
	fail "G10: a usage error removed <envelope-out>; rc=2 must have no filesystem effect"
fi
if [[ -e "$g10_tool" && -e "${g10_tool}.stderr" ]]; then
	pass "G10: <tool-out> and its .stderr sibling are left alone too"
else
	fail "G10: a usage error removed <tool-out> artefacts; rc=2 must have no filesystem effect"
fi

# Same for the other two path-knowing return-2 arms: a missing <cmd...> and
# a non-positive <budget-seconds>.
printf '%s' '{"status":"approve"}' >"$g10_env"
set +e
"$RUNNER" 5 "$g10_env" "$g10_tool" -- >/dev/null 2>&1
g10_nocmd_rc=$?
set -e
g10_nocmd_gone=$([[ -e "$g10_env" ]] && echo no || echo yes)

printf '%s' '{"status":"approve"}' >"$g10_env"
set +e
"$RUNNER" 0 "$g10_env" "$g10_tool" -- true >/dev/null 2>&1
g10_zero_rc=$?
set -e
g10_zero_gone=$([[ -e "$g10_env" ]] && echo no || echo yes)

if [[ "$g10_nocmd_rc" -eq 2 && "$g10_nocmd_gone" == "no" && "$g10_zero_rc" -eq 2 && "$g10_zero_gone" == "no" ]]; then
	pass "G10: missing <cmd...> and <budget-seconds> 0 both return 2 without touching <envelope-out>"
else
	fail "G10: nocmd rc=$g10_nocmd_rc gone=$g10_nocmd_gone; zero-budget rc=$g10_zero_rc gone=$g10_zero_gone (both must be rc=2, gone=no)"
fi

# The two documented EXEMPTIONS must not crash: <envelope-out> is unknowable
# there, so the function returns 2 without touching the filesystem.
printf '%s' '{"status":"approve"}' >"$g10_env"
set +e
"$RUNNER" --gate >/dev/null 2>&1
g10_gate_rc=$?
"$RUNNER" 5 >/dev/null 2>&1
g10_short_rc=$?
set -e
if [[ "$g10_gate_rc" -eq 2 && "$g10_short_rc" -eq 2 && -e "$g10_env" ]]; then
	pass "G10: the two documented exemptions return 2 and leave unrelated files alone"
else
	fail "G10: exemption arms: --gate rc=$g10_gate_rc, short rc=$g10_short_rc, unrelated env present=$([[ -e "$g10_env" ]] && echo yes || echo no)"
fi

# Structural (r4 F16): the stale-artefact unlink sits in EXACTLY one window --
# below every POSITIONAL-SHAPE check, above every remaining check and above the
# first temp file. Asserted on the file, positionally, so a future shape check
# added below the unlink (or a precondition hoisted above it) is caught even
# when no behavioural test exercises it.
#
# The invariant, old -> new:
#   old: "`rm -f` only ever targets a token validated as <envelope-out>/
#         <tool-out>" -- FALSE. The round-3 hoist ran it on raw `$2`/`$3` at
#         the top of the function, before any shape check had established that
#         those positionals were paths at all.
#   new: TRUE. Both halves matter and pull opposite ways, which is why the
#        window is bounded on BOTH sides:
#          lower bound -- the unlink must come AFTER the four shape checks,
#            or it is deleting a guess again (F16);
#          upper bound -- it must come BEFORE the jq/bounding-mechanism
#            preconditions and before any temp file, or a `return 2` taken
#            after it leaves a stale envelope for a caller that ignores the
#            return code, which is the round-3 defect this must not undo.
g10_unlink_line="$(grep -n 'Stale-artefact unlink' "$GATE_BOUNDED" | head -1 | cut -d: -f1)"
g10_seconds_line="$(grep -n '<seconds> must be a positive integer' "$GATE_BOUNDED" | head -1 | cut -d: -f1)"
g10_missing_cmd_line="$(grep -n 'missing <cmd\.\.\.>' "$GATE_BOUNDED" | head -1 | cut -d: -f1)"
g10_sep_line="$(grep -n 'expected -- as the 4th argument' "$GATE_BOUNDED" | head -1 | cut -d: -f1)"
g10_jq_line="$(grep -n 'jq is required' "$GATE_BOUNDED" | head -1 | cut -d: -f1)"
g10_mktemp_line="$(awk -v f="$(grep -n '^gate_run_bounded() {' "$GATE_BOUNDED" | head -1 | cut -d: -f1)" \
	'NR > f && /mktemp/ {print NR; exit}' "$GATE_BOUNDED")"

if [[ -n "$g10_unlink_line" && -n "$g10_seconds_line" && -n "$g10_missing_cmd_line" &&
	-n "$g10_sep_line" && "$g10_sep_line" -lt "$g10_unlink_line" &&
	"$g10_missing_cmd_line" -lt "$g10_unlink_line" && "$g10_seconds_line" -lt "$g10_unlink_line" ]]; then
	pass "G10(F16): every positional-shape check returns 2 BEFORE the stale-artefact unlink"
else
	fail "G10(F16): a shape check does not precede the unlink (sep=$g10_sep_line cmd=$g10_missing_cmd_line secs=$g10_seconds_line unlink=$g10_unlink_line)"
fi

if [[ -n "$g10_jq_line" && -n "$g10_mktemp_line" && "$g10_unlink_line" -lt "$g10_jq_line" &&
	"$g10_unlink_line" -lt "$g10_mktemp_line" ]]; then
	pass "G10(F16): the unlink precedes the jq/bounding preconditions and the first temp file"
else
	fail "G10(F16): the unlink is not above the remaining preconditions (unlink=$g10_unlink_line jq=$g10_jq_line mktemp=$g10_mktemp_line)"
fi

g10_unlink_count="$(grep -c 'rm -f "\$envelope_out"' "$GATE_BOUNDED" || true)"
assert_eq "$g10_unlink_count" "1" "G10: the unlink targets the VALIDATED \$envelope_out local, not a raw positional"

g10_raw_unlink="$(grep -cE '^[[:space:]]*rm -f "\$[23]"' "$GATE_BOUNDED" || true)"
assert_eq "$g10_raw_unlink" "0" "G10: no \`rm -f\` targets an unvalidated positional token"

# F8: the unlink must be best-effort. It is the last command of its block, so
# under the caller's documented `set -euo pipefail` a bare failing `rm -f`
# aborts the caller outright -- the opposite of what the header promises.
g10_besteffort="$(grep -cE 'rm -f "\$(envelope_out|tool_out)".*\|\| :' "$GATE_BOUNDED" || true)"
if [[ "$g10_besteffort" -ge 2 ]]; then
	pass "G10(F8): both unlink lines are explicitly best-effort (\`|| :\`)"
else
	fail "G10(F8): only $g10_besteffort of 2 unlink lines are best-effort"
fi

# F8, behaviourally: with EXACTLY two arguments the hoisted `rm -f "$2"` was
# the last command of its `then` list, so a failing unlink (here: `$2` is a
# DIRECTORY) aborted the caller outright under the documented
# `set -euo pipefail` -- no usage message, no rc=2, the opposite of the
# "best-effort" the header and the comment both promise. With no unlink before
# the shape checks there is nothing to fail: the arity check reports cleanly.
g10f8_dir="$WORKDIR/g10f8"
mkdir -p "$g10f8_dir/env.json"
set +e
g10f8_err="$("$RUNNER" 5 "$g10f8_dir/env.json" 2>&1 >/dev/null)"
g10f8_rc=$?
set -e
if [[ "$g10f8_rc" -eq 2 && "$g10f8_err" == *"usage:"* ]]; then
	pass "G10(F8): an unremovable path does not abort the caller under set -e (rc=2 with a usage message)"
else
	fail "G10(F8): rc=$g10f8_rc err='$g10f8_err' (expected rc=2 and a usage message, not a set -e abort)"
fi

# F16, behaviourally: with the arguments shifted so `$3` is a COMMAND WORD
# rather than <tool-out>, the shape check must return 2 and that command word
# must still exist afterwards. Under the round-3 hoist it was unlinked.
g10f16_dir="$WORKDIR/g10f16"
mkdir -p "$g10f16_dir"
printf '%s\n' '#!/bin/sh' >"$g10f16_dir/my-gate.sh"
set +e
"$RUNNER" 900 -- "$g10f16_dir/my-gate.sh" >/dev/null 2>&1
g10f16_rc=$?
set -e
if [[ "$g10f16_rc" -eq 2 && -e "$g10f16_dir/my-gate.sh" ]]; then
	pass "G10(F16): a shifted-argument shape error returns 2 with the command word still present"
else
	fail "G10(F16): rc=$g10f16_rc present=$([[ -e "$g10f16_dir/my-gate.sh" ]] && echo yes || echo no)"
fi

# ---------------------------------------------------------------------------
# Group R5-G5 — gate_run_bounded's OWN state paths get the symlink guard its
# skill-mates already have.
#
# convergence-ledger.sh carries a bespoke hardened ledger_assert_no_symlink
# and the lens scripts route every repo-rooted path through
# af_assert_no_symlink; gate-bounded.sh, which unlinks and then writes
# <envelope-out>, <tool-out> and <tool-out>.stderr into the same .gauntlet/
# tree, had none. The hoisted `rm -f` removes a symlink ENTRY rather than
# following it, so the leaf is defended at that instant -- but the writes
# happen a whole bounded run later (minutes, in the codex case), and a
# SYMLINKED PARENT DIRECTORY was never defended at any point.
# ---------------------------------------------------------------------------

g11_dir="$WORKDIR/g11"
mkdir -p "$g11_dir"
printf 'ORIGINAL\n' >"$g11_dir/outside-target.json"
ln -s "$g11_dir/outside-target.json" "$g11_dir/env-link.json"
set +e
"$RUNNER" 5 "$g11_dir/env-link.json" "$g11_dir/tool.out" -- /bin/echo '{"status":"clean"}' >/dev/null 2>&1
g11_link_rc=$?
set -e
if [[ "$g11_link_rc" -eq 2 && -L "$g11_dir/env-link.json" ]] &&
	cmp -s "$g11_dir/outside-target.json" <(printf 'ORIGINAL\n'); then
	pass "G11(R5-G5): a symlinked <envelope-out> returns 2 with the symlink and its target untouched"
else
	fail "G11(R5-G5): rc=$g11_link_rc link_present=$([[ -L "$g11_dir/env-link.json" ]] && echo yes || echo no) target=$(cat "$g11_dir/outside-target.json" 2>/dev/null)"
fi

mkdir -p "$g11_dir/realdir"
ln -s "$g11_dir/realdir" "$g11_dir/linkdir"
set +e
"$RUNNER" 5 "$g11_dir/env2.json" "$g11_dir/linkdir/tool.out" -- /bin/echo '{"status":"clean"}' >/dev/null 2>&1
g11_parent_rc=$?
set -e
if [[ "$g11_parent_rc" -eq 2 ]]; then
	pass "G11(R5-G5): a SYMLINKED PARENT of <tool-out> returns 2"
else
	fail "G11(R5-G5): symlinked <tool-out> parent must return 2, got rc=$g11_parent_rc"
fi

# Control: ordinary in-tree paths are unaffected.
set +e
"$RUNNER" 5 "$g11_dir/env3.json" "$g11_dir/tool3.out" -- /bin/echo '{"status":"clean","findings":[]}' >/dev/null 2>&1
g11_ok_rc=$?
set -e
if [[ "$g11_ok_rc" -eq 0 && -s "$g11_dir/env3.json" ]]; then
	pass "G11(R5-G5/control): ordinary non-symlinked paths still run to a clean envelope"
else
	fail "G11(R5-G5/control): rc=$g11_ok_rc envelope=$(cat "$g11_dir/env3.json" 2>/dev/null)"
fi

# Structural: the guard sits AFTER the positional-shape checks (so it is not
# validating a guess) and BEFORE the stale-artefact unlink (so no filesystem
# effect precedes it).
g11_guard_line="$(grep -n 'gate_assert_no_symlink "\$envelope_out"' "$GATE_BOUNDED" | head -1 | cut -d: -f1 || true)"
g11_secs_line="$(grep -n '<seconds> must be a positive integer' "$GATE_BOUNDED" | head -1 | cut -d: -f1)"
g11_unlink_line="$(grep -n 'Stale-artefact unlink' "$GATE_BOUNDED" | head -1 | cut -d: -f1)"
if [[ -n "$g11_guard_line" && -n "$g11_secs_line" && -n "$g11_unlink_line" &&
	"$g11_secs_line" -lt "$g11_guard_line" && "$g11_guard_line" -lt "$g11_unlink_line" ]]; then
	pass "G11(R5-G5): the symlink guard sits after the shape checks and before the stale-artefact unlink"
else
	fail "G11(R5-G5): guard placement (secs=$g11_secs_line guard=$g11_guard_line unlink=$g11_unlink_line)"
fi

# ---------------------------------------------------------------------------
# Group R6-G1 — ONE state-path guard for the whole skill.
#
# Round 5 closed "gate-bounded.sh has no symlink guard" by writing a NEW,
# WEAKER copy of a walk that already existed in convergence-ledger.sh: leaf +
# immediate parent, no `..` rejection. `.gauntlet/` itself is the GRANDPARENT
# of every path the gauntlet composes (SKILL.md: gate_out_dir=
# "$run_dir/round-$round_n"), so a tracked symlink there was refused by the
# ledger and FOLLOWED by the gate, which wrote its envelope, tool-out and
# tool-out.stderr outside the repo. The policy now lives once, in
# lib/state-path-guard.sh, and both callers wrap it.
# ---------------------------------------------------------------------------

LEDGER_SCRIPT_R6="$SKILL_LIB/convergence-ledger.sh"
r6g1_root="$WORKDIR/r6g1"
mkdir -p "$r6g1_root/repo" "$r6g1_root/outside/r6" "$r6g1_root/outside/sub"
git -C "$r6g1_root/repo" init -q 2>/dev/null || git -C "$r6g1_root/repo" init >/dev/null 2>&1
ln -s "$r6g1_root/outside" "$r6g1_root/repo/.gauntlet"
ln -s "$r6g1_root/outside" "$r6g1_root/repo/link"
mkdir -p "$r6g1_root/repo/ok/dir"

# R6-G1a — grandparent symlink (`.gauntlet` itself). This is the exact shape
# the orchestrator composes, and the case the round-5 leaf+parent guard let
# through.
set +e
r6g1a_err="$(cd "$r6g1_root/repo" && "$RUNNER" --gate demo 5 .gauntlet/r6/env.json .gauntlet/r6/tool.txt -- /bin/echo 'hi' 2>&1 >/dev/null)"
r6g1a_rc=$?
set -e
r6g1a_leaked=""
for r6g1a_f in env.json tool.txt tool.txt.stderr; do
	[[ -e "$r6g1_root/outside/r6/$r6g1a_f" ]] && r6g1a_leaked="$r6g1a_leaked $r6g1a_f"
done
if [[ "$r6g1a_rc" -eq 2 && "$r6g1a_err" == *"refusing to operate on symlink"* && -z "$r6g1a_leaked" ]]; then
	pass "R6-G1a: a symlinked .gauntlet/ GRANDPARENT is refused and nothing is written through it"
else
	fail "R6-G1a: rc=$r6g1a_rc leaked='$r6g1a_leaked' err='$r6g1a_err'"
fi

# R6-G1b — deep ancestor: link -> outside, link/sub exists.
set +e
r6g1b_err="$(cd "$r6g1_root/repo" && "$RUNNER" --gate demo 5 "$r6g1_root/repo/link/sub/env.json" "$r6g1_root/repo/link/sub/tool.out" -- /bin/echo 'hi' 2>&1 >/dev/null)"
r6g1b_rc=$?
set -e
if [[ "$r6g1b_rc" -eq 2 && "$r6g1b_err" == *"refusing to operate on symlink"* &&
	! -e "$r6g1_root/outside/sub/env.json" && ! -e "$r6g1_root/outside/sub/tool.out" ]]; then
	pass "R6-G1b: a symlinked DEEP ancestor is refused and nothing is written through it"
else
	fail "R6-G1b: rc=$r6g1b_rc err='$r6g1b_err' env=$([[ -e "$r6g1_root/outside/sub/env.json" ]] && echo yes || echo no)"
fi

# R6-G1c — `..` re-entry. A `..` makes every lexical ancestor test unsound
# (`$repo/link/../.gauntlet` is NOT `$repo/.gauntlet` when `link` is a
# symlink), so the shape is refused outright.
set +e
r6g1c_err="$(cd "$r6g1_root/repo" && "$RUNNER" --gate demo 5 "$r6g1_root/repo/link/../ok/dir/env.json" "$r6g1_root/repo/ok/dir/tool.out" -- /bin/echo 'hi' 2>&1 >/dev/null)"
r6g1c_rc=$?
set -e
if [[ "$r6g1c_rc" -eq 2 && "$r6g1c_err" == *"'..'"* ]]; then
	pass "R6-G1c: a '..' component in a state path is refused outright"
else
	fail "R6-G1c: rc=$r6g1c_rc err='$r6g1c_err'"
fi

# R6-G1d — BEHAVIOURAL PARITY TABLE. The same case paths driven through the
# gate's entry point and the ledger's, asserting identical verdicts. This is
# the test that would have caught the round-5 divergence at round 5: two
# writers into one `.gauntlet/` tree must not apply two policies.
mkdir -p "$r6g1_root/outofrepo"
r6g1d_cases=(
	"$r6g1_root/repo/.gauntlet/r6/x.json"
	"$r6g1_root/repo/link/sub/x.json"
	"$r6g1_root/repo/link/../ok/dir/x.json"
	"$r6g1_root/repo/ok/dir/x.json"
	"$r6g1_root/outofrepo/x.json"
)
r6g1d_mismatch=""
for r6g1d_case in "${r6g1d_cases[@]}"; do
	set +e
	# Distinct leaves per writer: the symlink under test is an ANCESTOR in
	# every case, so the leaf name is free -- and sharing one leaf would have
	# the gate's envelope make the ledger's `--init` refuse an existing file,
	# which is not the verdict under comparison.
	(cd "$r6g1_root/repo" && "$RUNNER" --gate demo 5 "$r6g1d_case.env" "$r6g1d_case.tool" -- /bin/echo '{"status":"clean"}') >/dev/null 2>&1
	r6g1d_gate=$?
	(cd "$r6g1_root/repo" && bash "$LEDGER_SCRIPT_R6" --init --ledger "$r6g1d_case.ledger" --target t --cap 3 --k 2) >/dev/null 2>&1
	r6g1d_ledger=$?
	set -e
	r6g1d_gv=$([[ "$r6g1d_gate" -eq 0 ]] && echo accept || echo refuse)
	r6g1d_lv=$([[ "$r6g1d_ledger" -eq 0 ]] && echo accept || echo refuse)
	[[ "$r6g1d_gv" == "$r6g1d_lv" ]] || r6g1d_mismatch="$r6g1d_mismatch [$r6g1d_case gate=$r6g1d_gv ledger=$r6g1d_lv]"
	rm -f "$r6g1d_case.env" "$r6g1d_case.tool" "$r6g1d_case.tool.stderr" "$r6g1d_case.ledger" 2>/dev/null || true
done
if [[ -z "$r6g1d_mismatch" ]]; then
	pass "R6-G1d: gate and ledger return IDENTICAL verdicts on every state-path case"
else
	fail "R6-G1d: guard policies disagree:$r6g1d_mismatch"
fi

# R6-G1e — control: ordinary paths, in-repo and out-of-worktree (the macOS
# $TMPDIR-under-/var case), must not be falsely refused.
set +e
(cd "$r6g1_root/repo" && "$RUNNER" --gate demo 5 "$r6g1_root/repo/ok/dir/env.json" "$r6g1_root/repo/ok/dir/tool.out" -- /bin/echo '{"status":"clean"}') >/dev/null 2>&1
r6g1e_in=$?
(cd "$r6g1_root/repo" && "$RUNNER" --gate demo 5 "$r6g1_root/outofrepo/env.json" "$r6g1_root/outofrepo/tool.out" -- /bin/echo '{"status":"clean"}') >/dev/null 2>&1
r6g1e_out=$?
set -e
if [[ "$r6g1e_in" -eq 0 && "$r6g1e_out" -eq 0 ]]; then
	pass "R6-G1e/control: ordinary in-repo and out-of-worktree paths are not falsely refused"
else
	fail "R6-G1e/control: in-repo rc=$r6g1e_in out-of-worktree rc=$r6g1e_out"
fi

# ---------------------------------------------------------------------------
# Group R6-G1 structural, GENERALISED in round 7 (F10).
#
# The old form extracted TWO function bodies BY NAME and asserted they carried
# no `-L`. The failure mode it exists to prevent is "a new caller hand-rolls a
# walk" — which is exactly what round 5 did, and which a name list cannot see:
# run-gate.sh's call site was not covered at all, and any future lib file or
# new function in the covered files was exempt forever. So sweep the
# DIRECTORY, the way tests/parity/test-applier-bundle-parity.sh sweeps
# canonical lib/ for unregistered basenames.
#
# The Codex mirror's lib/ is byte-identical by parity (GAUNTLET_LIB_PARITY_FILES
# in tests/parity/test-applier-bundle-parity.sh), so sweeping the canonical
# directory covers both mirrors.
# Round 8, F9: the detector recognised only the `[[ -L` spelling, so a
# hand-rolled walk written as `[ -L "$p" ]`, `test -L "$p"` or with `-h` — all
# exactly as dangerous — passed the sweep untouched.
R8G5_SYMLINK_RE='^[^#]*(\[\[? *-[Lh] |test +-[Lh] |readlink|realpath)'

# Round 8, F8: the SECOND half of this check used to be a hardcoded
# three-name caller list, so its failure mode ("a NEW lib file touches state
# with no symlink logic at all") tripped neither half. Derive the caller set
# from the DIRECTORY instead: any lib file that performs a filesystem effect on
# a variable-borne path is a state-path caller and must source the guard.
# Round 9, F7: the regex encoded the brace-LESS house spelling only, so
# `>"${v}/f"`, `mkdir -p "${v}/d"` and `tee "$v"` were invisible to the very
# sweep that exists to catch "a NEW lib file writes state with no guard" —
# and the braced form is already live in this tree
# (gate-bounded.sh writes `2>"${tool_out}.stderr"`). `\$\{?` covers both
# spellings; the verb anchor widens from `[;( ]` to `[;([:space:]]` because
# real lib code is TAB-indented, which would otherwise have made the added
# `tee` alternative dead on arrival.
R8G5_EFFECT_RE='(^|[^>])>>? *"\$\{?[A-Za-z_]|mkdir -p "\$\{?[A-Za-z_]|(^|[;([:space:]])cat "\$\{?[A-Za-z_]|(^|[;([:space:]])(mv|cp|touch|tee) [^|]*"\$\{?[A-Za-z_]'

# The only names left anywhere in this check, and they are ASSERTED by R8-G5c
# rather than trusted: state-path-guard.sh is the policy owner itself, and
# gauntlet-common.sh is the documented anchor-divergent parity exclusion (it
# resolves a harness-specific plugin-root anchor and composes no state path).
R8G5_EXCLUDED=(state-path-guard.sh gauntlet-common.sh)

r8g5_is_excluded() {
	local base="$1" x
	for x in "${R8G5_EXCLUDED[@]}"; do
		[[ "$base" == "$x" ]] && return 0
	done
	return 1
}

r7g6_sweep_lib() {
	local dir="$1" f base hits out=""
	for f in "$dir"/*.sh; do
		[[ -e "$f" ]] || continue
		base="$(basename "$f")"
		[[ "$base" == "state-path-guard.sh" ]] && continue
		hits="$(grep -nE "$R8G5_SYMLINK_RE" "$f" || true)"
		[[ -n "$hits" ]] && out="$out $base:$(printf '%s' "$hits" | head -1 | cut -d: -f1)"
	done
	printf '%s' "$out"
}

# Second half, directory-derived. Returns the basenames that perform a
# filesystem effect on a variable-borne path without sourcing the guard.
r8g5_sweep_callers() {
	local dir="$1" f base out=""
	for f in "$dir"/*.sh; do
		[[ -e "$f" ]] || continue
		base="$(basename "$f")"
		r8g5_is_excluded "$base" && continue
		grep -qE "$R8G5_EFFECT_RE" "$f" || continue
		if ! { grep -q 'state-path-guard.sh' "$f" && grep -q 'gauntlet_assert_no_symlink' "$f"; }; then
			out="$out $base"
		fi
	done
	printf '%s' "$out"
}

r7g6_real="$(r7g6_sweep_lib "$SKILL_LIB")"
r7g6_callers_missing="$(r8g5_sweep_callers "$SKILL_LIB")"
r7g6_callers_ok=1
[[ -n "$r7g6_callers_missing" ]] && r7g6_callers_ok=0
if [[ -z "$r7g6_real" && "$r7g6_callers_ok" -eq 1 ]]; then
	pass "R7-G6: state-path-guard.sh is the ONLY file in review-gauntlet lib/ with symlink-resolution logic, and every state-path caller calls it"
else
	fail "R7-G6: hand-rolled walk in$r7g6_real; callers missing the guard:$r7g6_callers_missing"
fi

# R7-G6a — NEGATIVE CONTROL for the sweep itself. A sweep that cannot fail is
# not a check. Plant a hand-rolled walk in a COPY of lib/ and require the
# sweep to catch it.
r7g6_tmp="$(mktemp -d "$WORKDIR/r7g6lib.XXXXXX")"
cp "$SKILL_LIB"/*.sh "$r7g6_tmp/"
cat >>"$r7g6_tmp/gate-bounded.sh" <<'R7G6EOF'

hand_rolled_walk() {
	local p="$1"
	if [[ -L "$p" ]]; then
		return 1
	fi
	return 0
}
R7G6EOF
r7g6_planted="$(r7g6_sweep_lib "$r7g6_tmp")"
if [[ -n "$r7g6_planted" ]]; then
	pass "R7-G6a/control: the sweep CATCHES a hand-rolled walk planted in a copy of lib/ ($r7g6_planted)"
else
	fail "R7-G6a/control: the sweep did not catch a planted hand-rolled '[[ -L ]]' walk"
fi

# R8-G5b — the reviewer's own reproduction of F9: the SINGLE-BRACKET spelling.
# A separate copy so it is this spelling alone that has to be caught.
r8g5b_tmp="$(mktemp -d "$WORKDIR/r8g5blib.XXXXXX")"
cp "$SKILL_LIB"/*.sh "$r8g5b_tmp/"
cat >>"$r8g5b_tmp/convergence-ledger.sh" <<'R8G5BEOF'

single_bracket_walk() {
	local p="$1"
	if [ -L "$p" ]; then
		return 1
	fi
	if test -h "$p"; then
		return 1
	fi
	return 0
}
R8G5BEOF
r8g5b_planted="$(r7g6_sweep_lib "$r8g5b_tmp")"
if [[ -n "$r8g5b_planted" ]]; then
	pass "R8-G5b/control: the sweep CATCHES the single-bracket '[ -L ]' / 'test -h' spellings too ($r8g5b_planted)"
else
	fail "R8-G5b/control: a planted '[ -L \"\$p\" ]' walk was invisible to the sweep"
fi

# R8-G5a — F8's failure mode, which the old three-name caller list could not
# see: a NEW lib file that writes a variable-borne path and carries no symlink
# logic at all. The first half stays silent (nothing to detect); the
# directory-derived second half must flag it.
r8g5a_tmp="$(mktemp -d "$WORKDIR/r8g5alib.XXXXXX")"
cp "$SKILL_LIB"/*.sh "$r8g5a_tmp/"
cat >"$r8g5a_tmp/new-writer.sh" <<'R8G5AEOF'
#!/usr/bin/env bash
new_writer() {
	local some_path="$1"
	printf 'x' >"$some_path"
}
R8G5AEOF
r8g5a_planted="$(r8g5_sweep_callers "$r8g5a_tmp")"
if [[ "$r8g5a_planted" == *"new-writer.sh"* ]]; then
	pass "R8-G5a/control: a NEW lib file that writes a variable-borne path with no guard is flagged ($r8g5a_planted)"
else
	fail "R8-G5a/control: an unguarded new state-path writer was invisible to the caller sweep (got '$r8g5a_planted')"
fi

# R9-G4a — the same failure mode in the BRACED house spelling (round 9, F7).
# R8G5_EFFECT_RE encoded `"$var` only, so `>"${v}/f"`, `mkdir -p "${v}/d"` and
# `tee "$v"` were invisible to the very sweep that exists to catch "a NEW lib
# file writes state with no guard" — and the braced form is already live in
# this tree (gate-bounded.sh writes `2>"${tool_out}.stderr"`), so R8-G5a's
# unbraced plant could never expose the gap. The verb anchor also had to widen
# from `[;( ]` to `[;([:space:]]`, since real lib code is TAB-indented.
# R8-G5a stays as the control for the unbraced spelling.
r9g4a_tmp="$(mktemp -d "$WORKDIR/r9g4alib.XXXXXX")"
cp "$SKILL_LIB"/*.sh "$r9g4a_tmp/"
cat >"$r9g4a_tmp/braced-writer.sh" <<'R9G4AEOF'
#!/usr/bin/env bash
braced_writer() {
	local out_dir="$1" out_file="$2"
	mkdir -p "${out_dir}/d"
	printf 'x' >"${out_dir}/f"
	printf 'y' | tee "${out_file}"
}
R9G4AEOF
r9g4a_planted="$(r8g5_sweep_callers "$r9g4a_tmp")"
if [[ "$r9g4a_planted" == *"braced-writer.sh"* ]]; then
	pass "R9-G4a/control: a NEW lib file writing state in the BRACED spelling is flagged ($r9g4a_planted)"
else
	fail "R9-G4a/control: an unguarded braced-spelling state writer was invisible to the caller sweep (got '$r9g4a_planted')"
fi

# R8-G5c — the exclusion list is CHECKED, not asserted: exactly two members,
# and the non-owner one (gauntlet-common.sh) must genuinely compose no state
# path, i.e. match no effect pattern. If it ever does, the exclusion has to go.
r8g5c_bad=""
if [[ "${R8G5_EXCLUDED[*]}" != "state-path-guard.sh gauntlet-common.sh" ]]; then
	r8g5c_bad="$r8g5c_bad [exclusion list is '${R8G5_EXCLUDED[*]}', expected 'state-path-guard.sh gauntlet-common.sh']"
fi
if grep -qE "$R8G5_EFFECT_RE" "$SKILL_LIB/gauntlet-common.sh"; then
	r8g5c_bad="$r8g5c_bad [gauntlet-common.sh now performs a filesystem effect on a variable path — it can no longer be excluded]"
fi
if [[ -z "$r8g5c_bad" ]]; then
	pass "R8-G5c: the sweep's only two excluded names are the policy owner and the anchor-divergent file, and the latter still composes no state path"
else
	fail "R8-G5c:$r8g5c_bad"
fi

# ---------------------------------------------------------------------------
# Group R7-G1 — the containment bound comes from the PATH, never the cwd.
#
# `gauntlet_assert_no_symlink` used to derive the worktree root with a bare
# `git rev-parse --show-toplevel`, i.e. from the CALLER's cwd. One and the
# same path was therefore refused from inside the repo and ACCEPTED from
# anywhere else, silently degrading to the leaf+immediate-parent bound this
# file exists to replace. INVARIANT UNDER TEST: the verdict is a function of
# (the path's spelling, the filesystem) alone.
r7g1_root="$WORKDIR/r7g1"
mkdir -p "$r7g1_root/repo" "$r7g1_root/out/round-1" "$r7g1_root/repo2/sub" \
	"$r7g1_root/outofrepo" "$r7g1_root/nonrepo" "$r7g1_root/repo/ok/dir"
git -C "$r7g1_root/repo" init -q >/dev/null 2>&1 || git -C "$r7g1_root/repo" init >/dev/null 2>&1
git -C "$r7g1_root/repo2" init -q >/dev/null 2>&1 || git -C "$r7g1_root/repo2" init >/dev/null 2>&1
ln -s "$r7g1_root/out" "$r7g1_root/repo/.gauntlet"
ln -s "$r7g1_root/repo2" "$r7g1_root/repo/otherlink"

# Round-8 F1 fixture, folded into this matrix so cwd-invariance covers it too:
# the escape target itself carries a checkout marker BELOW the symlink
# (`evil/r8/.git`). Round 7 stopped the bound at the INNERMOST worktree-bearing
# ancestor, which here is the guarded path's own parent — pass 2 never ran and
# the symlinked `.gauntlet` was never -L-tested. The bound must come from the
# OUTERMOST boundary (`victim2`), which the attacker cannot lower.
mkdir -p "$r7g1_root/evil/r8" "$r7g1_root/victim2"
git -C "$r7g1_root/victim2" init -q >/dev/null 2>&1 || git -C "$r7g1_root/victim2" init >/dev/null 2>&1
# A REAL checkout at the escape target, not just a `.git` directory: round 7
# asked git, so only a repo git recognises reproduces its bypass.
git -C "$r7g1_root/evil/r8" init -q >/dev/null 2>&1 || git -C "$r7g1_root/evil/r8" init >/dev/null 2>&1
ln -s "$r7g1_root/evil" "$r7g1_root/victim2/.gauntlet"

# Round-8 F10: this row used to be a HARD-CODED `/tmp/<literal>/env.json`, i.e.
# a security fixture whose expected verdict (accepted) any local user could
# flip by pre-creating that directory as a symlink. `mktemp -d` under $WORKDIR
# keeps the meaning (a path with no checkout on its chain) without the
# predictable name, and the file's existing trap already removes it.
r7g1_outside="$(mktemp -d "$WORKDIR/r7g1out.XXXXXX")"

# Ask the guard directly, from a chosen cwd, in a subshell.
r7g1_verdict() {
	local cwd="$1" path="$2"
	(
		cd "$cwd" || exit 9
		# shellcheck source=/dev/null
		. "$SKILL_LIB/state-path-guard.sh"
		gauntlet_assert_no_symlink "$path" r7 >/dev/null 2>&1
	)
	echo $?
}

r7g1_paths=(
	"$r7g1_root/repo/.gauntlet/round-1/env.json"
	"$r7g1_root/repo/otherlink/sub/env.json"
	"$r7g1_root/repo/ok/dir/env.json"
	"$r7g1_root/repo/deep/new/dir/env.json"
	"$r7g1_root/outofrepo/env.json"
	"$r7g1_outside/env.json"
	"$r7g1_root/victim2/.gauntlet/r8/ledger.json"
)
r7g1_expected=(1 1 0 0 0 0 1)
r7g1_cwds=("$r7g1_root/repo" "$r7g1_root/nonrepo" "/tmp")

r7g1a_bad=""
r7g1a_matrix=""
for r7g1_i in "${!r7g1_paths[@]}"; do
	r7g1_row=""
	for r7g1_cwd in "${r7g1_cwds[@]}"; do
		r7g1_row="$r7g1_row $(r7g1_verdict "$r7g1_cwd" "${r7g1_paths[$r7g1_i]}")"
	done
	r7g1_uniq="$(printf '%s\n' $r7g1_row | sort -u | tr '\n' ',' | sed 's/,$//')"
	r7g1a_matrix="$r7g1a_matrix
  ${r7g1_paths[$r7g1_i]#"$r7g1_root/"} ->$r7g1_row (expected ${r7g1_expected[$r7g1_i]})"
	if [[ "$r7g1_uniq" != "${r7g1_expected[$r7g1_i]}" ]]; then
		r7g1a_bad="$r7g1a_bad [${r7g1_paths[$r7g1_i]} got:$r7g1_row want:${r7g1_expected[$r7g1_i]} across all cwds]"
	fi
done
if [[ -z "$r7g1a_bad" ]]; then
	pass "R7-G1a: the verdict is IDENTICAL from every cwd (repo / non-repo / /tmp) for every path, and equals the expected column:$r7g1a_matrix"
else
	fail "R7-G1a: cwd-dependent or wrong verdict:$r7g1a_bad$r7g1a_matrix"
fi

# R7-G1b — a symlinked ancestor pointing at ANOTHER WORKTREE ROOT must not be
# allowed to END the walk at itself (the `! -L "$cand"` / `! -L "$probe"`
# rule). Without it the candidate search accepts repo2 as the bound, stops AT
# `otherlink`, and never -L-tests the one component that matters.
r7g1b_bad=""
for r7g1_cwd in "${r7g1_cwds[@]}"; do
	r7g1b_rc="$(r7g1_verdict "$r7g1_cwd" "$r7g1_root/repo/otherlink/sub/env.json")"
	[[ "$r7g1b_rc" == "1" ]] || r7g1b_bad="$r7g1b_bad [cwd=$r7g1_cwd rc=$r7g1b_rc]"
done
if [[ -z "$r7g1b_bad" ]]; then
	pass "R7-G1b: a symlink pointing AT a second worktree root is refused from every cwd (it can never be the containment bound)"
else
	fail "R7-G1b: symlink-to-other-worktree accepted:$r7g1b_bad"
fi

# R7-G1c — the finding's own reproduction, promoted: gate_run_bounded run from
# a cwd OUTSIDE the repo, writing into repo/.gauntlet/... through the
# symlinked `.gauntlet`, must fail and leak nothing.
set +e
(cd "$r7g1_root/nonrepo" && "$RUNNER" --gate demo 5 \
	"$r7g1_root/repo/.gauntlet/round-1/env.json" \
	"$r7g1_root/repo/.gauntlet/round-1/tool.txt" -- /bin/echo '{"status":"clean"}') >/dev/null 2>&1
r7g1c_rc=$?
set -e
r7g1c_leaked=""
for r7g1c_f in env.json tool.txt tool.txt.stderr; do
	[[ -e "$r7g1_root/out/round-1/$r7g1c_f" ]] && r7g1c_leaked="$r7g1c_leaked $r7g1c_f"
done
if [[ "$r7g1c_rc" -ne 0 && -z "$r7g1c_leaked" ]]; then
	pass "R7-G1c/control: gate_run_bounded from a FOREIGN cwd still refuses a symlinked .gauntlet/ and writes nothing through it"
else
	fail "R7-G1c/control: rc=$r7g1c_rc leaked='$r7g1c_leaked'"
fi

# R7-G1d — no false refusal from a foreign cwd either: the R6-G1e controls
# (ordinary in-repo path, out-of-worktree $TMPDIR path) must still be accepted.
set +e
(cd "$r7g1_root/nonrepo" && "$RUNNER" --gate demo 5 "$r7g1_root/repo/ok/dir/env.json" "$r7g1_root/repo/ok/dir/tool.out" -- /bin/echo '{"status":"clean"}') >/dev/null 2>&1
r7g1d_in=$?
(cd "$r7g1_root/nonrepo" && "$RUNNER" --gate demo 5 "$r7g1_root/outofrepo/env.json" "$r7g1_root/outofrepo/tool.out" -- /bin/echo '{"status":"clean"}') >/dev/null 2>&1
r7g1d_out=$?
set -e
if [[ "$r7g1d_in" -eq 0 && "$r7g1d_out" -eq 0 ]]; then
	pass "R7-G1d/control: ordinary in-repo and out-of-worktree paths are not falsely refused FROM A FOREIGN CWD"
else
	fail "R7-G1d/control: in-repo rc=$r7g1d_in out-of-worktree rc=$r7g1d_out"
fi

# ---------------------------------------------------------------------------
# Group R8-G1 — the containment bound is the OUTERMOST checkout boundary on the
# path's own lexical ancestor chain, decided by `-e <cand>/.git` alone.
#
# Round 7 asked `git -C <ancestor> rev-parse --show-toplevel` and stopped at the
# INNERMOST match. Both halves of that sentence were findings:
#   F1 — innermost means the ATTACKER picks the bound (plant a `.git` under the
#        escape target and the bound lands below the escaping symlink).
#   F2 — `git -C` reads GIT_DIR/GIT_WORK_TREE from the environment, so an
#        exported pair moved the answer off the path entirely and the bound
#        vanished, silently degrading the guard to leaf+parent.
r8g1_root="$WORKDIR/r8g1"
mkdir -p "$r8g1_root/victim" "$r8g1_root/evil/r8" "$r8g1_root/nonrepo" \
	"$r8g1_root/envrepo" "$r8g1_root/outer" "$r8g1_root/elsewhere/proj/.gauntlet/r1" \
	"$r8g1_root/tmprepo/ok/dir"
git -C "$r8g1_root/victim" init -q >/dev/null 2>&1 || git -C "$r8g1_root/victim" init >/dev/null 2>&1
# The escape target is a REAL checkout (round 7 asked git, so only a repo git
# recognises reproduces its innermost-bound bypass).
git -C "$r8g1_root/evil/r8" init -q >/dev/null 2>&1 || git -C "$r8g1_root/evil/r8" init >/dev/null 2>&1
git -C "$r8g1_root/envrepo" init -q >/dev/null 2>&1 || git -C "$r8g1_root/envrepo" init >/dev/null 2>&1
git -C "$r8g1_root/elsewhere/proj" init -q >/dev/null 2>&1 || git -C "$r8g1_root/elsewhere/proj" init >/dev/null 2>&1
git -C "$r8g1_root/tmprepo" init -q >/dev/null 2>&1 || git -C "$r8g1_root/tmprepo" init >/dev/null 2>&1
ln -s "$r8g1_root/evil" "$r8g1_root/victim/.gauntlet"
mkdir -p "$r8g1_root/outer/.git"
ln -s "$r8g1_root/elsewhere/proj" "$r8g1_root/outer/proj"

r8g1_cwds=("$r8g1_root/victim" "$r8g1_root/nonrepo" "/tmp")

# Like r7g1_verdict, but also captures the diagnostic and can export a
# GIT_DIR/GIT_WORK_TREE pair pointing at an UNRELATED repo.
r8g1_verdict() {
	local cwd="$1" path="$2" with_env="${3:-0}"
	(
		cd "$cwd" || exit 9
		if [[ "$with_env" -eq 1 ]]; then
			export GIT_DIR="$r8g1_root/envrepo/.git"
			export GIT_WORK_TREE="$r8g1_root/envrepo"
		fi
		# shellcheck source=/dev/null
		. "$SKILL_LIB/state-path-guard.sh"
		gauntlet_assert_no_symlink "$path" r8 >/dev/null 2>&1
	)
	echo $?
}

# R8-G1a — F1's own reproduction: the escape target carries a `.git` BELOW the
# escaping symlink, so the innermost worktree-bearing ancestor IS the guarded
# path's parent. Must be refused from every cwd.
r8g1a_bad=""
for r8g1_cwd in "${r8g1_cwds[@]}"; do
	r8g1a_rc="$(r8g1_verdict "$r8g1_cwd" "$r8g1_root/victim/.gauntlet/r8/ledger.json")"
	[[ "$r8g1a_rc" == "1" ]] || r8g1a_bad="$r8g1a_bad [cwd=$r8g1_cwd rc=$r8g1a_rc]"
done
if [[ -z "$r8g1a_bad" ]]; then
	pass "R8-G1a: a '.git' planted under the escape target cannot lower the bound — the symlinked ancestor is still refused from every cwd"
else
	fail "R8-G1a: attacker-planted inner boundary bypassed the guard:$r8g1a_bad"
fi

# R8-G1b — F2: an exported GIT_DIR/GIT_WORK_TREE pair at an unrelated repo must
# not change ONE verdict. The whole R7-G1a matrix is re-run with the pair
# exported and compared cell for cell against the plain run.
r8g1b_bad=""
r8g1b_table=""
for r8g1_i in "${!r7g1_paths[@]}"; do
	r8g1_plain=""
	r8g1_env=""
	for r8g1_cwd in "${r7g1_cwds[@]}"; do
		r8g1_plain="$r8g1_plain $(r8g1_verdict "$r8g1_cwd" "${r7g1_paths[$r8g1_i]}" 0)"
		r8g1_env="$r8g1_env $(r8g1_verdict "$r8g1_cwd" "${r7g1_paths[$r8g1_i]}" 1)"
	done
	r8g1b_table="$r8g1b_table
  ${r7g1_paths[$r8g1_i]#"$r7g1_root/"} -> plain:$r8g1_plain env:$r8g1_env"
	[[ "$r8g1_plain" == "$r8g1_env" ]] ||
		r8g1b_bad="$r8g1b_bad [${r7g1_paths[$r8g1_i]} plain:$r8g1_plain env:$r8g1_env]"
done
if [[ -z "$r8g1b_bad" ]]; then
	pass "R8-G1b: the verdict matrix is IDENTICAL with GIT_DIR/GIT_WORK_TREE exported at an unrelated repo — no environment channel into the bound:$r8g1b_table"
else
	fail "R8-G1b: an exported GIT_DIR/GIT_WORK_TREE moved the bound:$r8g1b_bad$r8g1b_table"
fi

# R8-G1c — the ONE deliberate widening, pinned as intended behaviour so a later
# round cannot quietly "fix" it back: a symlinked ancestor BELOW the outermost
# boundary (`outer/.git` present, `outer/proj -> elsewhere/proj`) is refused,
# and the diagnostic names the offending component.
set +e
r8g1c_err="$(
	# shellcheck source=/dev/null
	. "$SKILL_LIB/state-path-guard.sh"
	gauntlet_assert_no_symlink "$r8g1_root/outer/proj/.gauntlet/r1/x.json" r8 2>&1 >/dev/null
)"
r8g1c_rc=$?
set -e
if [[ "$r8g1c_rc" -eq 1 && "$r8g1c_err" == *"$r8g1_root/outer/proj"* ]]; then
	pass "R8-G1c: a symlinked ancestor below the outermost boundary is refused fail-closed, and the diagnostic names it"
else
	fail "R8-G1c: rc=$r8g1c_rc err='$r8g1c_err'"
fi

# ---------------------------------------------------------------------------
# R9-G1a — a TRAILING SLASH (or a `//` run) must not change the verdict
# (round 9, F1/F2). Every test in the guard is lexical, and `[[ -L "$p/" ]]` is
# ALWAYS false — a trailing slash forces bash to resolve the symlink — while a
# `//` run makes `${p%/*}` strip an EMPTY component. On 6703445 the four
# spellings below returned 1/0/0/0: an escaping leaf symlink was ACCEPTED
# whenever the caller happened to type a trailing slash. The guard now
# normalises its input once, so the verdict is a function of the path, not of
# its spelling.
# The `dirname` shadow used by R9-G1b; created up front so `r9g1_verdict`
# below can reference it unconditionally.
r9g1_fakebin="$WORKDIR/r9g1bin"
mkdir -p "$r9g1_fakebin"
printf '%s\n' '#!/usr/bin/env bash' 'echo /' >"$r9g1_fakebin/dirname"
chmod +x "$r9g1_fakebin/dirname"

r9g1_spellings=(
	"$r8g1_root/victim/.gauntlet"
	"$r8g1_root/victim/.gauntlet/"
	"$r8g1_root/victim/.gauntlet//"
	"$r8g1_root//victim/.gauntlet/"
)
r9g1_verdict() {
	# $1 path, $2 = 1 to put a `dirname` that answers `/` earlier on PATH.
	(
		if [[ "${2:-0}" -eq 1 ]]; then
			PATH="$r9g1_fakebin:$PATH"
			export PATH
		fi
		# shellcheck source=/dev/null
		. "$SKILL_LIB/state-path-guard.sh"
		set +e
		r9g1_err="$(gauntlet_assert_no_symlink "$1" r9 2>&1 >/dev/null)"
		r9g1_rc=$?
		set -e
		printf '%s:%s' "$r9g1_rc" "$([[ "$r9g1_err" == *"refusing to operate on symlink"* ]] && echo named || echo unnamed)"
	)
}

r9g1a_bad=""
r9g1a_table=""
for r9g1a_p in "${r9g1_spellings[@]}"; do
	r9g1a_got="$(r9g1_verdict "$r9g1a_p")"
	r9g1a_table="$r9g1a_table [${r9g1a_p#"$r8g1_root"} -> $r9g1a_got]"
	[[ "$r9g1a_got" == "1:named" ]] || r9g1a_bad="$r9g1a_bad [${r9g1a_p#"$r8g1_root"} -> $r9g1a_got]"
done
if [[ -z "$r9g1a_bad" ]]; then
	pass "R9-G1a: every slash spelling of an escaping leaf symlink is refused with the naming diagnostic:$r9g1a_table"
else
	fail "R9-G1a: a slash spelling changed the verdict:$r9g1a_bad"
fi

# ---------------------------------------------------------------------------
# R9-G1b — no PATH channel into the guard (round 9, F3). R8-G1b is the same
# control for GIT_DIR/GIT_WORK_TREE; the ancestor walk still called `dirname`,
# which is a PATH lookup, so a shadowing `dirname` that answers `/` collapsed
# the bound search and the containment guard could be bypassed by an
# attacker-controlled PATH entry. The walk is `${p%/*}` now and invokes
# nothing, so the two matrices must be byte-identical. Also asserts the empty
# path is refused rather than silently rewritten into $PWD.
r9g1b_plain=""
r9g1b_shadow=""
for r9g1b_p in "${r9g1_spellings[@]}"; do
	r9g1b_plain="$r9g1b_plain $(r9g1_verdict "$r9g1b_p" 0)"
	r9g1b_shadow="$r9g1b_shadow $(r9g1_verdict "$r9g1b_p" 1)"
done
set +e
r9g1b_empty_err="$(
	# shellcheck source=/dev/null
	. "$SKILL_LIB/state-path-guard.sh"
	gauntlet_assert_no_symlink "" r9 2>&1 >/dev/null
)"
r9g1b_empty_rc=$?
set -e
if [[ "$r9g1b_plain" == "$r9g1b_shadow" && "$r9g1b_empty_rc" -eq 1 && "$r9g1b_empty_err" == *"empty state path"* ]]; then
	pass "R9-G1b: a shadowing 'dirname' on PATH cannot move a verdict (plain:$r9g1b_plain), and an empty path is refused"
else
	fail "R9-G1b: plain:$r9g1b_plain shadow:$r9g1b_shadow empty_rc=$r9g1b_empty_rc empty_err='$r9g1b_empty_err'"
fi

# ---------------------------------------------------------------------------
# R9-G1c — the SAME normalisation defect existed in the second guard,
# af_assert_no_symlink (scripts/lib/auto-fix-common.sh), which owns the
# `.deep-review/` / `.review-plan/` trees. Two extra properties are asserted
# here that the gauntlet guard does not have: this guard accepts RELATIVE
# paths (resolve_path rejects absolute ones upstream), so it must NOT
# absolutise, and its `${p%/*}` walk needs the `!= "$path"` arm — `${p%/*}` on
# `foo` yields `foo` where `dirname foo` is `.` — or a relative single-component
# path would loop forever.
r9g1c_root="$WORKDIR/r9g1c"
mkdir -p "$r9g1c_root/proj" "$r9g1c_root/outside"
ln -s "$r9g1c_root/outside" "$r9g1c_root/proj/.deep-review"
mkdir -p "$r9g1c_root/proj/reldir"
ln -s "$r9g1c_root/outside" "$r9g1c_root/proj/rellink"

r9g1c_af() {
	(
		cd "$r9g1c_root/proj" || exit 9
		# shellcheck source=/dev/null
		. "$ROOT_DIR/scripts/lib/auto-fix-common.sh"
		set +e
		af_assert_no_symlink "$1" >/dev/null 2>&1
		printf '%s' "$?"
		set -e
	)
}

r9g1c_bad=""
for r9g1c_p in ".deep-review" ".deep-review/" ".deep-review//" "rellink/x.json" "rellink//x.json"; do
	r9g1c_got="$(r9g1c_af "$r9g1c_p")"
	[[ "$r9g1c_got" == "6" ]] || r9g1c_bad="$r9g1c_bad [$r9g1c_p -> $r9g1c_got, expected 6]"
done
# Relative negative controls: the walk must TERMINATE and ACCEPT.
for r9g1c_ok in "reldir" "reldir/x.json" "./reldir/x.json"; do
	r9g1c_got="$(r9g1c_af "$r9g1c_ok")"
	[[ "$r9g1c_got" == "0" ]] || r9g1c_bad="$r9g1c_bad [$r9g1c_ok -> $r9g1c_got, expected 0]"
done
r9g1c_empty="$(r9g1c_af "")"
[[ "$r9g1c_empty" == "6" ]] || r9g1c_bad="$r9g1c_bad [empty -> $r9g1c_empty, expected 6]"

if [[ -z "$r9g1c_bad" ]]; then
	pass "R9-G1c: af_assert_no_symlink refuses every slash spelling of a symlinked path, still accepts relative in-tree paths, and refuses an empty one"
else
	fail "R9-G1c:$r9g1c_bad"
fi

# R8-G1d — negative control (the round-4 F7 false-refusal guard): an ordinary
# path inside a checkout that itself sits below a platform alias ($WORKDIR is
# mktemp -d, i.e. under /var -> /private/var on macOS) must still be ACCEPTED.
# The outermost boundary is the checkout, so nothing above it is ever -L-tested.
r8g1d_rc="$(r8g1_verdict "$r8g1_root/nonrepo" "$r8g1_root/tmprepo/ok/dir/env.json")"
if [[ "$r8g1d_rc" == "0" ]]; then
	pass "R8-G1d/control: an ordinary in-checkout path below a platform symlink alias is not falsely refused"
else
	fail "R8-G1d/control: rc=$r8g1d_rc (platform alias above the boundary was -L-tested)"
fi

# ---------------------------------------------------------------------------
# Group R7-G2 — the boundary between the repo's TWO containment owners is
# asserted by a test, not by a comment (round 7, F4).
#
# `gauntlet_assert_no_symlink` owns `.gauntlet/`; `af_assert_no_symlink`
# (scripts/lib/auto-fix-common.sh) owns `.deep-review/` / `.review-plan/`.
# The documented relation is `gauntlet ⊇ af-bounded` FOR IN-ROOT PATHS:
# anything the auto-fix walk refuses for an in-root path, the gauntlet walk
# also refuses. A future edit that makes `gauntlet` WEAKER than `af` on an
# in-root row fails here.
r7g2_root="$WORKDIR/r7g2"
mkdir -p "$r7g2_root/repo/ok/dir" "$r7g2_root/outside/sub" "$r7g2_root/outofrepo"
git -C "$r7g2_root/repo" init -q >/dev/null 2>&1 || git -C "$r7g2_root/repo" init >/dev/null 2>&1
ln -s "$r7g2_root/outside" "$r7g2_root/repo/link"
ln -s "$r7g2_root/outside" "$r7g2_root/repo/.gauntlet"
ln -s "$r7g2_root/outside/sub" "$r7g2_root/repo/ok/leaflink"

r7g2_gauntlet() {
	(
		# shellcheck source=/dev/null
		. "$SKILL_LIB/state-path-guard.sh"
		gauntlet_assert_no_symlink "$1" r7 >/dev/null 2>&1
	)
	echo $?
}
r7g2_af() {
	(
		# shellcheck source=/dev/null
		. "$ROOT_DIR/scripts/lib/auto-fix-common.sh"
		af_assert_no_symlink "$1" "$2" >/dev/null 2>&1
	)
	echo $?
}

# rows: <in-root?>|<label>|<path>
r7g2_rows=(
	"1|ordinary in-repo|$r7g2_root/repo/ok/dir/x.json"
	"1|leaf symlink|$r7g2_root/repo/ok/leaflink"
	"1|parent symlink|$r7g2_root/repo/link/sub/x.json"
	"1|grandparent symlink|$r7g2_root/repo/.gauntlet/r/x.json"
	"1|'..' with no symlink on the chain|$r7g2_root/repo/ok/../ok/dir/x.json"
	"0|out-of-tree fixture|$r7g2_root/outofrepo/x.json"
)
r7g2_violations=""
r7g2_table=""
r7g2_dotdot_divergence=0
r7g2_outoftree_divergence=0
for r7g2_row in "${r7g2_rows[@]}"; do
	r7g2_in="${r7g2_row%%|*}"
	r7g2_rest="${r7g2_row#*|}"
	r7g2_label="${r7g2_rest%%|*}"
	r7g2_path="${r7g2_rest#*|}"
	r7g2_g="$(r7g2_gauntlet "$r7g2_path")"
	r7g2_a="$(r7g2_af "$r7g2_path" "$r7g2_root/repo")"
	r7g2_table="$r7g2_table
  [$r7g2_label] gauntlet=$([[ $r7g2_g -eq 0 ]] && echo accept || echo refuse) af=$([[ $r7g2_a -eq 0 ]] && echo accept || echo refuse)"
	if [[ "$r7g2_in" == "1" ]]; then
		# af refuses => gauntlet must refuse.
		if [[ "$r7g2_a" -ne 0 && "$r7g2_g" -eq 0 ]]; then
			r7g2_violations="$r7g2_violations [$r7g2_label: af refused, gauntlet ACCEPTED]"
		fi
		# Documented divergence #1: `..` is refused by gauntlet only.
		if [[ "$r7g2_label" == "'..' with no symlink on the chain" && "$r7g2_g" -ne 0 && "$r7g2_a" -eq 0 ]]; then
			r7g2_dotdot_divergence=1
		fi
	else
		# Documented divergence #2: an OUT-OF-ROOT path is out of scope for
		# the implication — af (bounded at a root it never reaches) walks to
		# `/` and refuses on a platform symlink; gauntlet answers "not in a
		# worktree" and accepts. Neither is a defect; it is why the relation
		# is stated for in-root paths only.
		[[ "$r7g2_g" -eq 0 ]] && r7g2_outoftree_divergence=1
	fi
done
if [[ -z "$r7g2_violations" && "$r7g2_dotdot_divergence" -eq 1 && "$r7g2_outoftree_divergence" -eq 1 ]]; then
	pass "R7-G2a: gauntlet ⊇ af-bounded on every in-root row, with both documented divergences present:$r7g2_table"
else
	fail "R7-G2a: relation broken:$r7g2_violations dotdot_divergence=$r7g2_dotdot_divergence outoftree_divergence=$r7g2_outoftree_divergence$r7g2_table"
fi

# R7-G2b — the LAYERING half of the same rule: the authored guard must not
# source a GENERATED file, and review-gauntlet must not acquire
# lib/persist-common.sh as a bundle extra just to reuse a predicate.
r7g2b_bad=""
if grep -q 'auto-fix-common' "$SKILL_LIB/state-path-guard.sh"; then
	grep -qE '^[^#]*auto-fix-common' "$SKILL_LIB/state-path-guard.sh" &&
		r7g2b_bad="$r7g2b_bad [state-path-guard.sh SOURCES auto-fix-common.sh]"
fi
if grep -qE '^[^#]*persist-common' "$SKILL_LIB/state-path-guard.sh"; then
	r7g2b_bad="$r7g2b_bad [state-path-guard.sh SOURCES persist-common.sh]"
fi
r7g2b_extra="$(
	# shellcheck source=/dev/null
	. "$ROOT_DIR/scripts/lib/bundle-map.sh"
	bundle_extra_for review-gauntlet
)"
if [[ "$r7g2b_extra" != "finding-key.sh" ]]; then
	r7g2b_bad="$r7g2b_bad [bundle_extra_for review-gauntlet = '$r7g2b_extra', expected 'finding-key.sh']"
fi
if [[ -z "$r7g2b_bad" ]]; then
	pass "R7-G2b: the authored guard sources no generated lib, and review-gauntlet's bundle extras are still exactly finding-key.sh"
else
	fail "R7-G2b:$r7g2b_bad"
fi

echo ""
echo "Results: $pass_count passed, $fail_count failed"
[[ "$fail_count" -eq 0 ]]
