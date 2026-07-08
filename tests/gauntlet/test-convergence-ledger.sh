#!/usr/bin/env bash
# test-convergence-ledger.sh — Phase 2 acceptance: convergence-ledger.sh is a
# deterministic, pure function of {ledger state, per-round inputs} that
# always resolves to exactly one of the seven decision tokens
# (continue|restart|confirm|success|success_with_quarantine|cap|non-converge)
# and provably terminates.
#
# Plan: docs/dev_plans/20260707-feature-review-gauntlet-skill.md, Phase 2
# "Gate-runner + convergence bundled scripts (Claude)", Testing Notes
# (plateau/oscillation/monotonic-decrease/cap/clean-confirm-vs-clean-full/
# converged-with-quarantine/gate failure vectors).
#
# Every vector drives the REAL CLI:
#   convergence-ledger.sh --ledger <path> --count <N> --structural <N> \
#       --local <N> --pass-type <full|confirm> --quarantine <N> \
#       [--cap N] [--k N]
# against a fresh `mktemp` ledger, and asserts the decision token printed on
# stdout. Ledger internals (loop_counter, rounds[].count) are inspected via
# `jq` only to corroborate the monotonic-counter and window-lookback
# invariants — the token itself is always read from stdout, never inferred.
#
# Exit codes: 0 all assertions pass, 1 any assertion fails.

set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
LEDGER_SCRIPT="$ROOT_DIR/plugins/skein/skills/review-gauntlet/lib/convergence-ledger.sh"

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

if [[ ! -x "$LEDGER_SCRIPT" ]]; then
	fail "convergence-ledger.sh missing or not executable: $LEDGER_SCRIPT"
	echo ""
	echo "Results: $pass_count passed, $fail_count failed"
	exit 1
fi

# Track every temp ledger we create so we can clean up unconditionally on
# exit, including on early failure.
TMP_LEDGERS=()
cleanup() {
	local f
	for f in "${TMP_LEDGERS[@]:-}"; do
		[[ -n "$f" && -e "$f" ]] && rm -f "$f"
	done
}
trap cleanup EXIT

new_ledger() {
	local f
	f="$(mktemp)"
	rm -f "$f" # convergence-ledger.sh creates it fresh on first round
	TMP_LEDGERS+=("$f")
	printf '%s\n' "$f"
}

# assert_eq ACTUAL EXPECTED LABEL
assert_eq() {
	local actual="$1" expected="$2" label="$3"
	if [[ "$actual" == "$expected" ]]; then
		pass "$label"
	else
		fail "$label (expected '$expected', got '$actual')"
	fi
}

# assert_ne ACTUAL UNEXPECTED LABEL
assert_ne() {
	local actual="$1" unexpected="$2" label="$3"
	if [[ "$actual" != "$unexpected" ]]; then
		pass "$label"
	else
		fail "$label (expected token != '$unexpected', got '$actual')"
	fi
}

# assert_nonzero_exit CMD... — runs the command, asserts a non-zero exit.
# Output is discarded (stdout+stderr) since these are usage-error vectors.
assert_nonzero_exit() {
	local label="$1"
	shift
	if "$@" >/tmp/gauntlet-ledger-test-out.$$ 2>&1; then
		fail "$label (expected non-zero exit, got 0)"
	else
		pass "$label"
	fi
	rm -f "/tmp/gauntlet-ledger-test-out.$$"
}

round() {
	# round LEDGER COUNT STRUCTURAL LOCAL PASS_TYPE QUARANTINE [EXTRA...]
	local ledger="$1" count="$2" structural="$3" local_="$4" pass_type="$5" quarantine="$6"
	shift 6
	"$LEDGER_SCRIPT" --ledger "$ledger" --count "$count" --structural "$structural" \
		--local "$local_" --pass-type "$pass_type" --quarantine "$quarantine" "$@"
}

# --- 1. Clean full pass -> success ---------------------------------------

L="$(new_ledger)"
tok="$(round "$L" 0 0 0 full 0)"
assert_eq "$tok" "success" "clean full pass (count=0, pass-type=full, quarantine=0) -> success"

# --- 2. Clean full pass + quarantine -> success_with_quarantine ----------

L="$(new_ledger)"
tok="$(round "$L" 0 0 0 full 2)"
assert_eq "$tok" "success_with_quarantine" "clean full pass with quarantine>0 -> success_with_quarantine (distinct from success)"

# --- 3. Clean confirm pass -> continue (NOT terminal) --------------------

L="$(new_ledger)"
tok="$(round "$L" 0 0 0 confirm 0)"
assert_eq "$tok" "continue" "clean confirm pass (count=0, pass-type=confirm) -> continue, NOT success"

# --- 4. Only-local round -> confirm --------------------------------------

L="$(new_ledger)"
tok="$(round "$L" 5 0 3 full 0)"
assert_eq "$tok" "confirm" "only-local round (count>0, structural=0, local>0) -> confirm"

# --- 5. Structural fix present -> restart --------------------------------

L="$(new_ledger)"
tok="$(round "$L" 5 1 0 full 0)"
assert_eq "$tok" "restart" "structural fix present (structural>0) -> restart, regardless of local tally"

# --- 6. Plateau 3 -> 3 -> 3 => terminal non-converge ---------------------

L="$(new_ledger)"
tok1="$(round "$L" 3 0 1 confirm 0)"
tok2="$(round "$L" 3 0 1 confirm 0)"
tok3="$(round "$L" 3 0 1 confirm 0)"
assert_eq "$tok1" "confirm" "plateau round 1 (count=3, insufficient history) -> confirm, not a premature bail"
assert_eq "$tok2" "confirm" "plateau round 2 (count=3, still insufficient K+1 history) -> confirm, not a premature bail"
assert_eq "$tok3" "non-converge" "plateau round 3 (3,3,3 across the K=2 lookback window) -> terminal non-converge"

# --- 7. Oscillation 5 -> 3 -> 5 -> 3 => terminal non-converge ------------

L="$(new_ledger)"
tok1="$(round "$L" 5 0 1 confirm 0)"
tok2="$(round "$L" 3 0 1 confirm 0)"
tok3="$(round "$L" 5 0 1 confirm 0)"
tok4="$(round "$L" 3 0 1 confirm 0)"
assert_eq "$tok1" "confirm" "oscillation round 1 (count=5, insufficient history) -> confirm"
assert_eq "$tok2" "confirm" "oscillation round 2 (count=3, insufficient history) -> confirm"
assert_eq "$tok3" "non-converge" "oscillation round 3 (5,3,5 — no net progress over the K=2 window) -> non-converge"
assert_eq "$tok4" "non-converge" "oscillation round 4 (3,5,3 — still no net progress over the K=2 window) -> non-converge"

# --- 8. Monotonic decrease 5 -> 4 -> 3 must NOT false-positive-bail ------

L="$(new_ledger)"
tok1="$(round "$L" 5 0 1 confirm 0)"
tok2="$(round "$L" 4 0 1 confirm 0)"
tok3="$(round "$L" 3 0 1 confirm 0)"
assert_ne "$tok1" "non-converge" "monotonic decrease round 1 (count=5) must not bail"
assert_ne "$tok2" "non-converge" "monotonic decrease round 2 (count=4) must not bail"
assert_ne "$tok3" "non-converge" "monotonic decrease round 3 (5,4,3 strictly decreasing over the window) must not false-positive-bail"
assert_eq "$tok3" "confirm" "monotonic decrease round 3 correctly resolves to confirm (findings remain, no structural fix)"

# --- 9. Cap: loop_counter reaches 10 => cap is reachable -----------------
# Structural fix every round (so absent the cap, the decision would always
# be `restart`), with a strictly decreasing count sequence so the
# non-converge window check never preempts the cap/restart precedence.

L="$(new_ledger)"
last_tok=""
i=0
for c in 10 9 8 7 6 5 4 3 2 1; do
	i=$((i + 1))
	last_tok="$(round "$L" "$c" 1 0 full 0)"
	if [[ "$i" -lt 10 ]]; then
		assert_eq "$last_tok" "restart" "structural-restart-every-round: round $i (pre-cap) -> restart"
	fi
done
assert_eq "$last_tok" "cap" "structural-restart-every-round: round 10 -> cap (loop_counter reaches the hard cap of 10, restart never resets it)"

loop_counter="$(jq -r '.loop_counter' "$L")"
assert_eq "$loop_counter" "10" "monotonic loop counter after 10 rounds (including every structural restart) == 10"

# --- 10. Determinism: same ledger + inputs -> same token -----------------

L="$(new_ledger)"
round "$L" 5 0 2 full 0 >/dev/null
snapshot="$(mktemp)"
TMP_LEDGERS+=("$snapshot")
cp "$L" "$snapshot"
tok_a="$(round "$L" 3 0 1 confirm 0)"
cp "$snapshot" "$L"
tok_b="$(round "$L" 3 0 1 confirm 0)"
assert_eq "$tok_a" "$tok_b" "determinism: identical ledger state + identical round inputs -> identical decision token"

# --- 11. Input validation: missing/invalid flags -> non-zero exit -------

assert_nonzero_exit "missing --ledger -> non-zero exit" \
	"$LEDGER_SCRIPT" --count 1 --structural 0 --local 0 --pass-type full --quarantine 0

L="$(new_ledger)"
assert_nonzero_exit "invalid --pass-type -> non-zero exit" \
	"$LEDGER_SCRIPT" --ledger "$L" --count 1 --structural 0 --local 0 --pass-type bogus --quarantine 0

L="$(new_ledger)"
assert_nonzero_exit "non-integer --count -> non-zero exit" \
	"$LEDGER_SCRIPT" --ledger "$L" --count not-a-number --structural 0 --local 0 --pass-type full --quarantine 0

L="$(new_ledger)"
assert_nonzero_exit "--cap 0 -> non-zero exit (cap must be positive)" \
	"$LEDGER_SCRIPT" --ledger "$L" --count 1 --structural 0 --local 0 --pass-type full --quarantine 0 --cap 0

echo ""
echo "Results: $pass_count passed, $fail_count failed"

if [[ "$fail_count" -gt 0 ]]; then
	exit 1
fi

exit 0
