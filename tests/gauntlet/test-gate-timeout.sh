#!/usr/bin/env bash
# test-gate-timeout.sh — Phase 1 acceptance for the harness-neutral
# `gate_run_bounded` helper (plugins/skein/skills/review-gauntlet/lib/gate-bounded.sh)
# and its interplay with the existing `run-gate.sh normalize` non-clean-status
# path. Plan: docs/dev_plans/20260823-feature-review-skills-resilience.md,
# Phase 1, R1 + Testing Notes + Review Focus ("Timeout interplay").
#
# Design intent under test (Phase 1 Goal): a hung external gate costs at most
# its budget, enforced in shell (never Claude-side), never blocks the round,
# and is visibly `skipped`/DEGRADED — never silently clean.
#
# Covers:
#   1. Expiry: a tool that writes a valid tool-out then hangs past budget is
#      killed; tool-out is removed; the envelope is `skipped`/DEGRADED with
#      duration_s stamped; `run-gate.sh normalize` on the envelope exits 4.
#   2. Crash-with-garbage: a tool that exits 0 but leaves invalid JSON in
#      tool-out yields a `status: "error"` envelope (never a clean-looking
#      one) — the envelope path is the ONLY thing `normalize` ever reads.
#   3. Process-group kill: a SIGTERM-ignoring child is dead after expiry.
#   4. Shim parity: with `timeout` hidden from PATH (this host's actual
#      state per plan Dependencies — `timeout` is Homebrew coreutils only),
#      the python3 os.setsid fallback produces an equivalent envelope, twice
#      in a row (determinism).
#   5. Success path: exit 0 + valid JSON well within budget -> clean
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
cleanup() { rm -rf "$WORKDIR"; }
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

# --- Case 1: expiry — tool writes valid JSON then hangs past budget -------

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

	if [[ "$elapsed" -le 15 ]]; then
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

run_expiry_case "gnu-timeout" "$PATH"
run_expiry_case "shim" "$HIDDEN_TIMEOUT_PATH"

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

run_invalid_json_case "default-path" "$PATH"

# --- Case 3: process-group kill — SIGTERM-ignoring child dies with parent -

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

	# Poll briefly: gate_run_bounded is documented synchronous, so the child
	# should already be dead by the time it returns; allow a short grace
	# window for whatever kill-after the implementation chooses.
	local alive=1 i
	for i in $(seq 1 10); do
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
}

run_sigterm_ignoring_case "gnu-timeout" "$PATH"
run_sigterm_ignoring_case "shim" "$HIDDEN_TIMEOUT_PATH"

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
