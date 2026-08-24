#!/usr/bin/env bash
# test-status-row.sh — Phase 3 acceptance: `run-gate.sh status-row <envelope>`
# emits one gate-status table row from a gate envelope (script-emitted, per
# R7 -- SKILL.md only says *where* to print rows, never how to build one).
#
# Plan: docs/dev_plans/20260823-feature-review-skills-resilience.md, Phase 3,
# R7. Envelope shape is the one `gate-bounded.sh`'s `gate_run_bounded` already
# writes on every exit path: {status, notes, findings, gate, duration_s,
# degraded_reason} -- see plugins/skein/skills/review-gauntlet/lib/gate-bounded.sh.
# Row columns (plan order): gate, status, duration_s, findings, degraded_reason.
# `-` renders any null duration_s/degraded_reason; the DEGRADED case additionally
# renders findings as `-`/0.
#
# Interface assumption: `run-gate.sh status-row [<envelope.json>|-]`, matching
# the `normalize`/`reconcile`/`route` subcommands' own positional-file-or-stdin
# convention. If `status-row` does not exist yet, or emits a different shape,
# this suite should read as RED (missing subcommand / wrong shape), not a
# silent false pass -- a parallel implementer is landing it in this same phase.
#
# Exit codes: 0 all assertions pass, 1 any assertion fails.

set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
RUN_GATE="$ROOT_DIR/plugins/skein/skills/review-gauntlet/lib/run-gate.sh"
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

assert_contains() {
	local haystack="$1" needle="$2" label="$3"
	if [[ "$haystack" == *"$needle"* ]]; then
		pass "$label"
	else
		fail "$label (expected to find '$needle' in: $haystack)"
	fi
}

assert_not_contains() {
	local haystack="$1" needle="$2" label="$3"
	if [[ "$haystack" != *"$needle"* ]]; then
		pass "$label"
	else
		fail "$label (did not expect to find '$needle' in: $haystack)"
	fi
}

# --- 1. Clean envelope: populated duration_s, `-` degraded_reason --------

clean_envelope="$WORKDIR/clean.json"
cat >"$clean_envelope" <<'EOF'
{
  "gate": "code-review",
  "status": "approve",
  "findings": [
    {"file": "a.py", "line": 10, "category": "correctness", "severity": "high",
     "confidence": 0.9, "summary": "off-by-one", "evidence": "loop bound"},
    {"file": "b.py", "line": 3, "category": "style", "severity": "low",
     "confidence": 0.5, "summary": "typo", "evidence": "teh"}
  ],
  "notes": null,
  "duration_s": 42,
  "degraded_reason": null
}
EOF

clean_row="$WORKDIR/clean-row.out"
clean_rc=0
"$RUN_GATE" status-row "$clean_envelope" >"$clean_row" 2>/dev/null || clean_rc=$?
clean_row_text="$(cat "$clean_row")"

if [[ "$clean_rc" -eq 0 ]]; then
	pass "status-row on a clean envelope exits 0"
else
	fail "status-row on a clean envelope exits 0 (got $clean_rc)"
fi

line_count="$(grep -c '^' "$clean_row" 2>/dev/null || echo 0)"
if [[ "$line_count" -eq 1 ]]; then
	pass "status-row emits exactly one table row (one line)"
else
	fail "status-row emits exactly one table row (got $line_count lines: $clean_row_text)"
fi

assert_contains "$clean_row_text" "code-review" "clean envelope row: includes the gate name"
assert_contains "$clean_row_text" "approve" "clean envelope row: includes the status"
assert_contains "$clean_row_text" "42" "clean envelope row: includes the populated duration_s (42)"
assert_contains "$clean_row_text" "2" "clean envelope row: includes the findings count (2)"

# degraded_reason must render as literal '-', not "null" and not empty-string.
assert_not_contains "$clean_row_text" "null" "clean envelope row: does not render the raw JSON token 'null' anywhere"
if [[ "$clean_row_text" == *"-"* ]]; then
	pass "clean envelope row: renders '-' for the null degraded_reason"
else
	fail "clean envelope row: renders '-' for the null degraded_reason (got: $clean_row_text)"
fi

# --- 2. DEGRADED envelope: status skipped, degraded_reason populated,
#        findings rendered as `-`/0 ------------------------------------------
# Shape matches gate-bounded.sh's own expiry envelope verbatim.

degraded_envelope="$WORKDIR/degraded.json"
cat >"$degraded_envelope" <<'EOF'
{
  "status": "skipped",
  "notes": "DEGRADED: timeout after 1200s",
  "findings": [],
  "gate": null,
  "duration_s": 1200,
  "degraded_reason": "DEGRADED: timeout after 1200s"
}
EOF

degraded_row="$WORKDIR/degraded-row.out"
degraded_rc=0
"$RUN_GATE" status-row "$degraded_envelope" >"$degraded_row" 2>/dev/null || degraded_rc=$?
degraded_row_text="$(cat "$degraded_row")"

if [[ "$degraded_rc" -eq 0 ]]; then
	pass "status-row on a DEGRADED envelope exits 0 (a degraded row is still a valid row, not a script error)"
else
	fail "status-row on a DEGRADED envelope exits 0 (got $degraded_rc)"
fi

degraded_line_count="$(grep -c '^' "$degraded_row" 2>/dev/null || echo 0)"
assert_contains "$degraded_row_text" "skipped" "DEGRADED envelope row: includes status=skipped"
assert_contains "$degraded_row_text" "1200" "DEGRADED envelope row: includes the populated duration_s (1200)"
assert_contains "$degraded_row_text" "DEGRADED" "DEGRADED envelope row: includes the populated degraded_reason"

if [[ "$degraded_row_text" == *"-"* || "$degraded_row_text" == *"0"* ]]; then
	pass "DEGRADED envelope row: findings render as '-' or '0' (empty findings array)"
else
	fail "DEGRADED envelope row: findings render as '-' or '0' (got: $degraded_row_text)"
fi
if [[ "$degraded_line_count" -eq 1 ]]; then
	pass "DEGRADED envelope row is still exactly one line"
else
	fail "DEGRADED envelope row is still exactly one line (got $degraded_line_count)"
fi

# --- 3. Null fields render as `-` when tested directly (not only via the
#        gate-bounded.sh-shaped DEGRADED case above) -----------------------

nullfields_envelope="$WORKDIR/nullfields.json"
cat >"$nullfields_envelope" <<'EOF'
{
  "gate": "security-review",
  "status": "approve",
  "findings": [],
  "notes": null,
  "duration_s": null,
  "degraded_reason": null
}
EOF

nullfields_row="$WORKDIR/nullfields-row.out"
nullfields_rc=0
"$RUN_GATE" status-row "$nullfields_envelope" >"$nullfields_row" 2>/dev/null || nullfields_rc=$?
nullfields_row_text="$(cat "$nullfields_row")"

assert_eq_rc() {
	local rc="$1"
	if [[ "$rc" -eq 0 ]]; then
		pass "status-row on an envelope with null duration_s/degraded_reason exits 0"
	else
		fail "status-row on an envelope with null duration_s/degraded_reason exits 0 (got $rc)"
	fi
}
assert_eq_rc "$nullfields_rc"

assert_not_contains "$nullfields_row_text" "null" "null-fields row: never renders the raw JSON token 'null'"
assert_contains "$nullfields_row_text" "security-review" "null-fields row: still includes the gate name"
if [[ "$nullfields_row_text" == *"-"* ]]; then
	pass "null-fields row: renders '-' for null duration_s and/or degraded_reason"
else
	fail "null-fields row: renders '-' for null duration_s and/or degraded_reason (got: $nullfields_row_text)"
fi

echo ""
echo "Results: $pass_count passed, $fail_count failed"

if [[ "$fail_count" -gt 0 ]]; then
	exit 1
fi

exit 0
