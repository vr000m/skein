#!/usr/bin/env bash
# test-regression-stop.sh — Phase 3 acceptance: convergence-ledger.sh's
# ledger-owned regression stop condition.
#
# Plan: docs/dev_plans/20260823-feature-review-skills-resilience.md, Phase 3,
# R5. Interface: `--present-keys <file>` / `--claimed-keys <file>`, newline-
# delimited key lists (empty file == no keys), per convergence-ledger.sh's
# own header comment. Promotion: a THIS-ROUND claimed key that is ALSO
# absent from THIS SAME ROUND's `--present-keys`, on a `pass_type: full`
# round, is promoted immediately into the cumulative `fixed_keys` set (a
# round already bundles "the gates re-ran after the fix" together with "the
# fixer's claim", so there is nothing to defer to a later round — see the
# script's own comment above its promotion block). Promotion is full-pass-
# only: a `pass_type: confirm` round never promotes, and there is no retry
# queue — a claimed key still present this same round, or claimed only
# during a confirm round, is simply dropped; the fixer must claim it again on
# a later round that actually shows it gone. `regression = present_keys ∩
# fixed_keys`, computed internally, slotted in the decision-priority chain
# AFTER success/success_with_quarantine and BEFORE cap, and fires on BOTH
# pass types (a reappearance is a reappearance, confirm or full).
# `fixed_keys` persists across structural restarts.
#
# Exit codes: 0 all assertions pass, 1 any assertion fails.

set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
LEDGER_SCRIPT="$ROOT_DIR/plugins/skein/skills/review-gauntlet/lib/convergence-ledger.sh"
CLAUDE_COMMON="$ROOT_DIR/plugins/skein/skills/review-gauntlet/lib/gauntlet-common.sh"

gc_hash() {
	(
		# shellcheck source=plugins/skein/skills/review-gauntlet/lib/gauntlet-common.sh disable=SC1091
		. "$CLAUDE_COMMON"
		gc_sha1 <"$1"
	)
}

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

TMP_FILES=()
cleanup() {
	local f
	for f in "${TMP_FILES[@]:-}"; do
		[[ -n "$f" && -e "$f" ]] && rm -f "$f"
	done
}
trap cleanup EXIT

new_ledger() {
	local f
	f="$(mktemp)"
	rm -f "$f"
	TMP_FILES+=("$f")
	printf '%s\n' "$f"
}

# keyfile KEY... -> path to a newline-delimited key-list file (possibly empty).
keyfile() {
	local f
	f="$(mktemp)"
	TMP_FILES+=("$f")
	if [[ "$#" -gt 0 ]]; then
		printf '%s\n' "$@" >"$f"
	else
		: >"$f"
	fi
	printf '%s\n' "$f"
}

assert_eq() {
	local actual="$1" expected="$2" label="$3"
	if [[ "$actual" == "$expected" ]]; then
		pass "$label"
	else
		fail "$label (expected '$expected', got '$actual')"
	fi
}

assert_ne() {
	local actual="$1" unexpected="$2" label="$3"
	if [[ "$actual" != "$unexpected" ]]; then
		pass "$label"
	else
		fail "$label (expected token != '$unexpected', got '$actual')"
	fi
}

# roundk LEDGER COUNT STRUCTURAL LOCAL PASS_TYPE QUARANTINE [EXTRA ARGS...]
roundk() {
	local ledger="$1" count="$2" structural="$3" local_="$4" pass_type="$5" quarantine="$6"
	shift 6
	"$LEDGER_SCRIPT" --ledger "$ledger" --count "$count" --structural "$structural" \
		--local "$local_" --pass-type "$pass_type" --quarantine "$quarantine" "$@"
}

fixed_keys_of() {
	jq -r '(.fixed_keys // []) | sort | join(",")' "$1"
}

empty_keys="$(keyfile)"

# =========================================================================
# 1. Basic promotion: claimed key absent from THIS round's present_keys, on
#    a full pass -> promoted into fixed_keys by the ledger.
# =========================================================================

L="$(new_ledger)"
present_A="$(keyfile A)"

# Round 1: full pass, A present, not yet claimed -> findings remain.
tok1="$(roundk "$L" 1 0 1 full 0 --present-keys "$present_A" --claimed-keys "$empty_keys")"
assert_eq "$tok1" "confirm" "promotion round 1 (A present, unclaimed, local findings remain) -> confirm"
assert_eq "$(fixed_keys_of "$L")" "" "promotion round 1: fixed_keys still empty (A not claimed)"

# Round 2: fixer claims A; this same full-pass round shows A absent from
# present_keys -> the ledger promotes A into fixed_keys.
claimed_A="$(keyfile A)"
tok2="$(roundk "$L" 0 0 0 full 0 --present-keys "$empty_keys" --claimed-keys "$claimed_A")"
assert_eq "$tok2" "success" "promotion round 2 (claimed A, present_keys empty, count=0) -> success"
assert_eq "$(fixed_keys_of "$L")" "A" "promotion round 2: ledger promotes claimed-and-absent key A into fixed_keys"

# =========================================================================
# 2. Reappearance of a fixed key on a later full pass -> regression.
# =========================================================================

tok3="$(roundk "$L" 1 0 1 full 0 --present-keys "$present_A" --claimed-keys "$empty_keys")"
assert_eq "$tok3" "regression" "round 3: fixed key A reappears in present_keys on a full pass -> regression (terminal, overrides confirm)"

# =========================================================================
# 3. Regression survives a structural restart.
# =========================================================================

L2="$(new_ledger)"
claimed_B="$(keyfile B)"
present_B="$(keyfile B)"

tokp1="$(roundk "$L2" 0 0 0 full 0 --present-keys "$empty_keys" --claimed-keys "$claimed_B")"
assert_eq "$tokp1" "success" "restart-survival setup: claim B on a clean full pass -> success"
assert_eq "$(fixed_keys_of "$L2")" "B" "restart-survival setup: B promoted to fixed_keys"

tok_restart="$(roundk "$L2" 3 1 0 full 0 --present-keys "$empty_keys" --claimed-keys "$empty_keys")"
assert_eq "$tok_restart" "restart" "restart round: structural fix present -> restart (fixed_keys must survive this)"
assert_eq "$(fixed_keys_of "$L2")" "B" "fixed_keys persists across the structural restart"

tok_after_restart="$(roundk "$L2" 1 0 1 full 0 --present-keys "$present_B" --claimed-keys "$empty_keys")"
assert_eq "$tok_after_restart" "regression" "post-restart round: B reappears in present_keys -> regression (fixed_keys carried across the restart)"

# =========================================================================
# 4. Claimed-but-still-present key never enters fixed_keys, and never later
#    fires regression (there is no retry queue: still-present at claim time
#    means the claim is simply dropped).
# =========================================================================

L3="$(new_ledger)"
claimed_C="$(keyfile C)"
present_C="$(keyfile C)"

tokc1="$(roundk "$L3" 1 0 1 full 0 --present-keys "$present_C" --claimed-keys "$claimed_C")"
assert_eq "$tokc1" "confirm" "claimed-but-still-present round 1: C claimed but still present -> confirm (not success)"
assert_eq "$(fixed_keys_of "$L3")" "" "claimed-but-still-present round 1: C never enters fixed_keys (it was never actually absent)"

tokc2="$(roundk "$L3" 1 0 1 full 0 --present-keys "$present_C" --claimed-keys "$empty_keys")"
assert_ne "$tokc2" "regression" "claimed-but-still-present round 2: C reappearing later must NOT fire regression (never promoted)"
assert_eq "$(fixed_keys_of "$L3")" "" "claimed-but-still-present round 2: fixed_keys still empty"

# =========================================================================
# 5. A key present only in a pass_type: confirm pass never promotes
#    (promotion is full-pass-only).
# =========================================================================

L4="$(new_ledger)"
claimed_D="$(keyfile D)"

# Confirm pass, D claimed and absent from present_keys -- promotion must NOT
# fire here; it is scoped to full passes only.
tokd1="$(roundk "$L4" 0 0 0 confirm 0 --present-keys "$empty_keys" --claimed-keys "$claimed_D")"
assert_eq "$tokd1" "continue" "confirm-pass-absence round 1: clean confirm pass -> continue (non-terminal), even with D claimed+absent"
assert_eq "$(fixed_keys_of "$L4")" "" "confirm-pass-absence round 1: D NOT promoted merely by being absent during a confirm pass"

present_D="$(keyfile D)"
tokd2="$(roundk "$L4" 1 0 1 full 0 --present-keys "$present_D" --claimed-keys "$empty_keys")"
assert_ne "$tokd2" "regression" "confirm-pass-absence round 2: D reappearing on a full pass must NOT fire regression (never promoted)"

# But a genuine full-pass claim+absence still promotes it.
tokd3="$(roundk "$L4" 0 0 0 full 0 --present-keys "$empty_keys" --claimed-keys "$claimed_D")"
assert_eq "$tokd3" "success" "confirm-pass-absence round 3: D claimed again, absent on a FULL pass -> success"
assert_eq "$(fixed_keys_of "$L4")" "D" "confirm-pass-absence round 3: D promoted once a genuine full-pass claim+absence occurs"

# =========================================================================
# 6. Deferred key (never claimed at all) never promotes, regardless of how
#    its presence fluctuates across rounds.
# =========================================================================

L5="$(new_ledger)"
present_E="$(keyfile E)"

tok_e1="$(roundk "$L5" 1 0 1 full 0 --present-keys "$present_E" --claimed-keys "$empty_keys")"
assert_eq "$tok_e1" "confirm" "deferred-key round 1: E present, unclaimed (deferred) -> confirm"

tok_e2="$(roundk "$L5" 0 0 0 full 0 --present-keys "$empty_keys" --claimed-keys "$empty_keys")"
assert_eq "$tok_e2" "success" "deferred-key round 2: E vanishes from present_keys, but was never claimed -> success, not a promotion event"
assert_eq "$(fixed_keys_of "$L5")" "" "deferred-key round 2: E never enters fixed_keys (deferred keys never promote)"

tok_e3="$(roundk "$L5" 1 0 1 full 0 --present-keys "$present_E" --claimed-keys "$empty_keys")"
assert_ne "$tok_e3" "regression" "deferred-key round 3: E reappearing must NOT fire regression (it was never promoted)"

# =========================================================================
# 7. Quarantined key never promotes.
# =========================================================================

L6="$(new_ledger)"
present_Q="$(keyfile Q)"

tok_q1="$(roundk "$L6" 0 0 0 full 1 --present-keys "$present_Q" --claimed-keys "$empty_keys")"
assert_eq "$tok_q1" "success_with_quarantine" "quarantined-key round 1: Q present+quarantined, unclaimed -> success_with_quarantine"
assert_eq "$(fixed_keys_of "$L6")" "" "quarantined-key round 1: Q never enters fixed_keys"

tok_q2="$(roundk "$L6" 0 0 0 full 1 --present-keys "$present_Q" --claimed-keys "$empty_keys")"
assert_ne "$tok_q2" "regression" "quarantined-key round 2: Q still present across rounds must NOT fire regression (never promoted)"

# =========================================================================
# 8. A fixed key reappearing in a `confirm` pass DOES fire regression
#    (regression fires on BOTH pass types; only promotion is full-pass-only).
# =========================================================================

L7="$(new_ledger)"
claimed_F="$(keyfile F)"
present_F="$(keyfile F)"

tok_f1="$(roundk "$L7" 0 0 0 full 0 --present-keys "$empty_keys" --claimed-keys "$claimed_F")"
assert_eq "$tok_f1" "success" "confirm-regression setup: claim F on a clean full pass -> success"
assert_eq "$(fixed_keys_of "$L7")" "F" "confirm-regression setup: F promoted to fixed_keys"

tok_f2="$(roundk "$L7" 1 0 1 confirm 0 --present-keys "$present_F" --claimed-keys "$empty_keys")"
assert_eq "$tok_f2" "regression" "confirm-regression round 2: F (fixed) reappears during a CONFIRM pass -> regression fires on both pass types"

# =========================================================================
# 9. --last-decision on a regression ledger exits terminal (5).
# =========================================================================

set +e
peek_out="$("$LEDGER_SCRIPT" --last-decision --ledger "$L7")"
peek_exit=$?
set -e
assert_eq "$peek_out" "regression" "--last-decision on a regression ledger reads back the regression token"
assert_eq "$peek_exit" "5" "--last-decision on a regression ledger exits 5 (terminal)"

# =========================================================================
# 10. Golden: append decision == subsequent --last-decision token; peek does
#     not re-promote (fixed_keys count + ledger bytes unchanged across peeks).
# =========================================================================

fk_before_peek="$(fixed_keys_of "$L7")"
hash_before_peek="$(gc_hash "$L7")"
"$LEDGER_SCRIPT" --last-decision --ledger "$L7" >/dev/null 2>&1 || true
"$LEDGER_SCRIPT" --last-decision --ledger "$L7" >/dev/null 2>&1 || true
fk_after_peek="$(fixed_keys_of "$L7")"
hash_after_peek="$(gc_hash "$L7")"
assert_eq "$fk_after_peek" "$fk_before_peek" "repeated --last-decision peeks do not mutate fixed_keys"
assert_eq "$hash_after_peek" "$hash_before_peek" "repeated --last-decision peeks leave the ledger file byte-identical (no re-promotion side effect)"

# =========================================================================
# 11. Malformed/missing --claimed-keys file -> defined non-crash behaviour
#     (either a documented usage error, or treated as an empty key set --
#     never an uncaught jq/bash crash).
# =========================================================================

L8="$(new_ledger)"
NONEXISTENT_KEYS="$(mktemp -u)"
malformed_stderr="$(mktemp)"
TMP_FILES+=("$malformed_stderr")
set +e
malformed_tok="$(roundk "$L8" 0 0 0 full 0 --present-keys "$empty_keys" --claimed-keys "$NONEXISTENT_KEYS" 2>"$malformed_stderr")"
malformed_exit=$?
set -e
if [[ "$malformed_exit" -eq 0 || "$malformed_exit" -eq 2 ]]; then
	pass "missing --claimed-keys file: defined exit code ($malformed_exit), not an uncontrolled crash"
else
	fail "missing --claimed-keys file: expected exit 0 (treated as empty) or 2 (usage error), got $malformed_exit"
fi
if grep -qi 'jq: error\|Traceback\|core dumped' "$malformed_stderr"; then
	fail "missing --claimed-keys file: stderr shows a raw jq/interpreter crash, not a controlled error message"
else
	pass "missing --claimed-keys file: no raw jq/interpreter crash on stderr"
fi
if [[ "$malformed_exit" -eq 2 ]]; then
	if grep -q 'convergence-ledger:' "$malformed_stderr"; then
		pass "missing --claimed-keys file (usage-error path): error message follows this script's own 'convergence-ledger:' prefix convention"
	else
		fail "missing --claimed-keys file (usage-error path): error message does not follow the 'convergence-ledger:' prefix convention"
	fi
fi

# A claimed-keys file that exists but is garbage (blank lines / stray
# whitespace, not JSON) must also not crash -- keys files are plain
# newline-delimited lists, not JSON.
L9="$(new_ledger)"
garbage_keys="$(mktemp)"
TMP_FILES+=("$garbage_keys")
printf '\n   \n\t\nA\n\n' >"$garbage_keys"
set +e
garbage_tok="$(roundk "$L9" 0 0 0 full 0 --present-keys "$empty_keys" --claimed-keys "$garbage_keys" 2>/dev/null)"
garbage_exit=$?
set -e
if [[ "$garbage_exit" -eq 0 ]]; then
	pass "garbage/blank-line --claimed-keys file: tolerated, decision computed (got '$garbage_tok')"
else
	fail "garbage/blank-line --claimed-keys file: expected exit 0 (blank lines tolerated as no-op entries), got $garbage_exit"
fi

# =========================================================================
# 12. Decision-priority: success beats regression.
# =========================================================================
# A full pass with count=0 (nothing outstanding, unresolved=0, quarantine=0)
# is eligible for `success`. If present_keys ALSO happens to include a
# previously-fixed key (eligible for `regression`), success must win --
# regression is slotted strictly AFTER success in the priority chain.

L10="$(new_ledger)"
claimed_G="$(keyfile G)"
present_G="$(keyfile G)"

tok_g1="$(roundk "$L10" 0 0 0 full 0 --present-keys "$empty_keys" --claimed-keys "$claimed_G")"
assert_eq "$tok_g1" "success" "priority setup: claim G on a clean full pass -> success"
assert_eq "$(fixed_keys_of "$L10")" "G" "priority setup: G promoted to fixed_keys"

tok_g2="$(roundk "$L10" 0 0 0 full 0 --present-keys "$present_G" --claimed-keys "$empty_keys")"
assert_eq "$tok_g2" "success" "priority: success beats regression (count=0/unresolved=0/quarantine=0 wins even though G, a fixed key, is present)"

# =========================================================================
# 13. Decision-priority: regression beats cap.
# =========================================================================
# Use a small --cap so the boundary is reachable quickly. Claim+promote H on
# round 1 (loop_counter=1); round 2 both reaches loop_counter==cap AND
# re-presents the fixed key H -- regression must win over cap.

L11="$(new_ledger)"
claimed_H="$(keyfile H)"
present_H="$(keyfile H)"

tok_h1="$(roundk "$L11" 0 0 0 full 0 --present-keys "$empty_keys" --claimed-keys "$claimed_H" --cap 2)"
assert_eq "$tok_h1" "success" "cap-priority setup: claim H on a clean full pass -> success (loop_counter=1)"
assert_eq "$(fixed_keys_of "$L11")" "H" "cap-priority setup: H promoted to fixed_keys"

tok_h2="$(roundk "$L11" 1 0 1 full 0 --present-keys "$present_H" --claimed-keys "$empty_keys" --cap 2)"
assert_eq "$tok_h2" "regression" "priority: regression beats cap (loop_counter reaches cap=2 on this round, but H, a fixed key, reappears -> regression wins)"

echo ""
echo "Results: $pass_count passed, $fail_count failed"

if [[ "$fail_count" -gt 0 ]]; then
	exit 1
fi

exit 0
