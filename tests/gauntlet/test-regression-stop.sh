#!/usr/bin/env bash
# test-regression-stop.sh — Phase 3 acceptance: convergence-ledger.sh's
# ledger-owned regression stop condition, with DEFERRED (next-full-pass)
# promotion semantics (F1/F2/F3 fix spec, .conduct/phase3-fix-spec.md).
#
# Plan: docs/dev_plans/20260823-feature-review-skills-resilience.md, Phase 3,
# R5. Interface: `--present-keys <file>` / `--claimed-keys <file>`, newline-
# delimited key lists. `--present-keys`, if given, MUST be an existing
# readable regular file (an empty file is legitimate evidence; a
# missing/unreadable one is a hard usage error, exit 2). `--claimed-keys`
# requires `--present-keys` to also be supplied (exit 2 otherwise); a
# missing/unreadable `--claimed-keys` file degrades tolerantly to an empty
# claim list.
#
# Promotion is DEFERRED, not same-round: a claimed key is recorded into a
# cumulative `pending_claims` set (never evaluated by the very round that
# made the claim), and is only EVALUATED — promoted into `fixed_keys` if
# absent, or dropped if still present — on a LATER round that is a COMPLETE
# FULL PASS WITH EVIDENCE (`pass_type == full AND unresolved == 0 AND
# --present-keys was supplied on that invocation`). A confirm pass, a
# degraded full pass (`unresolved > 0`), or a full pass that itself omits
# `--present-keys` neither promotes nor drops pending claims.
#
# `regression = present_keys ∩ fixed_keys`, computed internally, slotted in
# the decision-priority chain AFTER success/success_with_quarantine and
# BEFORE cap, and fires on BOTH pass types (a reappearance is a reappearance,
# confirm or full). `fixed_keys` and `pending_claims` both persist across
# structural restarts.
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

pending_claims_of() {
	jq -r '(.pending_claims // []) | sort | join(",")' "$1"
}

empty_keys="$(keyfile)"

# =========================================================================
# 1. Real round ordering: claim -> next full pass promotes -> reappearance
#    regresses. This is the critical assertion the pre-fix tests never
#    made: A is claimed and present IN THE SAME ROUND (the normal case —
#    the conductor's --claimed-keys is always a subset of that same round's
#    --present-keys, since the claim is for a finding the gates just saw),
#    and that claim must NOT promote until a LATER round shows A absent.
# =========================================================================

L="$(new_ledger)"
present_A="$(keyfile A)"

# Round 1: full pass, A present, not yet claimed -> findings remain, confirm.
tok1="$(roundk "$L" 1 0 1 full 0 --present-keys "$present_A" --claimed-keys "$empty_keys")"
assert_eq "$tok1" "confirm" "round ordering round 1 (A present, unclaimed, local findings remain) -> confirm"
assert_eq "$(fixed_keys_of "$L")" "" "round ordering round 1: fixed_keys still empty"
assert_eq "$(pending_claims_of "$L")" "" "round ordering round 1: pending_claims still empty (nothing claimed yet)"

# Round 2 (= round N): fixer claims A, but A is STILL PRESENT this same
# round (the real ordering: the fixer claims a finding the gates just
# reported, before the next pass has re-run against the fix). This must
# NOT promote — it only records the claim as pending.
claimed_A="$(keyfile A)"
tok2="$(roundk "$L" 1 0 1 full 0 --present-keys "$present_A" --claimed-keys "$claimed_A")"
assert_eq "$tok2" "confirm" "round ordering round 2 (A claimed AND present in the SAME round -> the normal case) -> confirm, not success"
assert_eq "$(fixed_keys_of "$L")" "" "round ordering round 2: A NOT promoted same-round (deferred promotion)"
assert_eq "$(pending_claims_of "$L")" "A" "round ordering round 2: A recorded into pending_claims"

# Round 3 (= round N+1): next full pass, A genuinely absent from
# present_keys, no new claim -> the ledger evaluates the pending claim and
# promotes A into fixed_keys.
tok3="$(roundk "$L" 0 0 0 full 0 --present-keys "$empty_keys" --claimed-keys "$empty_keys")"
assert_eq "$tok3" "success" "round ordering round 3 (next full pass, A absent) -> success"
assert_eq "$(fixed_keys_of "$L")" "A" "round ordering round 3: deferred promotion — A promoted into fixed_keys on the NEXT full pass"
assert_eq "$(pending_claims_of "$L")" "" "round ordering round 3: pending_claims cleared after evaluation"

# Round 4 (= round N+2): A reappears in present_keys on a full pass ->
# regression (terminal, overrides confirm).
tok4="$(roundk "$L" 1 0 1 full 0 --present-keys "$present_A" --claimed-keys "$empty_keys")"
assert_eq "$tok4" "regression" "round ordering round 4: fixed key A reappears in present_keys on a full pass -> regression"
assert_eq "$(fixed_keys_of "$L")" "A" "round ordering round 4: fixed_keys unchanged by the regression"

# =========================================================================
# 2. Pending claim survives a structural restart, then promotes, then
#    later regresses.
# =========================================================================

L2="$(new_ledger)"
claimed_B="$(keyfile B)"
present_B="$(keyfile B)"

tokb1="$(roundk "$L2" 1 0 1 full 0 --present-keys "$present_B" --claimed-keys "$claimed_B")"
assert_eq "$tokb1" "confirm" "restart-survival round 1: claim B while B is still present -> confirm"
assert_eq "$(fixed_keys_of "$L2")" "" "restart-survival round 1: B not yet promoted"
assert_eq "$(pending_claims_of "$L2")" "B" "restart-survival round 1: B recorded as pending"

# Restart round: structural fix present, no --present-keys/--claimed-keys
# supplied at all (present_supplied=false) -> neither evaluates nor drops
# the pending claim; it must survive untouched.
tok_restart="$(roundk "$L2" 3 1 0 full 0)"
assert_eq "$tok_restart" "restart" "restart-survival round 2: structural fix present -> restart"
assert_eq "$(fixed_keys_of "$L2")" "" "restart-survival round 2: fixed_keys unaffected by the restart round"
assert_eq "$(pending_claims_of "$L2")" "B" "restart-survival round 2: pending_claims (B) survives the structural restart untouched"

# Evaluation round: a genuine full pass with evidence, B absent -> B
# promotes.
tok_eval="$(roundk "$L2" 0 0 0 full 0 --present-keys "$empty_keys" --claimed-keys "$empty_keys")"
assert_eq "$tok_eval" "success" "restart-survival round 3 (post-restart evaluation pass, B absent) -> success"
assert_eq "$(fixed_keys_of "$L2")" "B" "restart-survival round 3: B promoted into fixed_keys, carried across the earlier restart"
assert_eq "$(pending_claims_of "$L2")" "" "restart-survival round 3: pending_claims cleared"

tok_after_restart="$(roundk "$L2" 1 0 1 full 0 --present-keys "$present_B" --claimed-keys "$empty_keys")"
assert_eq "$tok_after_restart" "regression" "restart-survival round 4: B reappears in present_keys -> regression (fixed_keys carried across the restart)"

# =========================================================================
# 3. Claimed-but-still-present key: dropped on the next full pass, never
#    promoted, never later fires regression (there is no retry queue).
# =========================================================================

L3="$(new_ledger)"
claimed_C="$(keyfile C)"
present_C="$(keyfile C)"

tokc1="$(roundk "$L3" 1 0 1 full 0 --present-keys "$present_C" --claimed-keys "$claimed_C")"
assert_eq "$tokc1" "confirm" "claimed-but-still-present round 1: C claimed while present -> confirm"
assert_eq "$(pending_claims_of "$L3")" "C" "claimed-but-still-present round 1: C recorded as pending"

# Next full pass: C is STILL present, no new claim -> the ledger evaluates
# the pending claim, finds C still present, and DROPS it (never promoted).
tokc2="$(roundk "$L3" 1 0 1 full 0 --present-keys "$present_C" --claimed-keys "$empty_keys")"
assert_eq "$tokc2" "confirm" "claimed-but-still-present round 2 (next full pass, C still present) -> confirm"
assert_eq "$(fixed_keys_of "$L3")" "" "claimed-but-still-present round 2: C never enters fixed_keys (still present at evaluation time)"
assert_eq "$(pending_claims_of "$L3")" "" "claimed-but-still-present round 2: the still-present claim is DROPPED (pending_claims cleared, not carried forward)"

# Later reappearance (really: continued presence) of C must NOT fire
# regression -- it was never promoted.
tokc3="$(roundk "$L3" 1 0 1 full 0 --present-keys "$present_C" --claimed-keys "$empty_keys")"
assert_ne "$tokc3" "regression" "claimed-but-still-present round 3: C reappearing later must NOT fire regression (never promoted)"
assert_eq "$(fixed_keys_of "$L3")" "" "claimed-but-still-present round 3: fixed_keys still empty"

# =========================================================================
# 4. A confirm pass neither promotes nor drops pending claims; promotion
#    requires a full pass with evidence, and may need one extra round to
#    actually land (deferred, never same-round -- even the round that
#    finally sees the claimed key absent on a genuine full pass cannot
#    promote it in that same call; the NEXT full-pass-with-evidence round
#    does).
# =========================================================================

L4="$(new_ledger)"
claimed_D="$(keyfile D)"

# Confirm pass, D claimed, absent from present_keys -- promotion must NOT
# fire (full-pass-only), but the claim IS still recorded as pending (RECORD
# is unconditional; only EVALUATE is full-pass-gated).
tokd1="$(roundk "$L4" 0 0 0 confirm 0 --present-keys "$empty_keys" --claimed-keys "$claimed_D")"
assert_eq "$tokd1" "continue" "confirm-pass round 1: clean confirm pass -> continue (non-terminal), even with D claimed+absent"
assert_eq "$(fixed_keys_of "$L4")" "" "confirm-pass round 1: D NOT promoted merely by being absent during a confirm pass"
assert_eq "$(pending_claims_of "$L4")" "D" "confirm-pass round 1: D IS still recorded as a pending claim (recording is unconditional)"

# Full pass, D reappears in present_keys (still present) -- must NOT fire
# regression (never promoted), and the pending claim is evaluated+dropped
# (still present at evaluation time).
present_D="$(keyfile D)"
tokd2="$(roundk "$L4" 1 0 1 full 0 --present-keys "$present_D" --claimed-keys "$empty_keys")"
assert_ne "$tokd2" "regression" "confirm-pass round 2: D reappearing on a full pass must NOT fire regression (never promoted)"
assert_eq "$(pending_claims_of "$L4")" "" "confirm-pass round 2: the still-present pending claim D is dropped on evaluation"

# Full pass, D claimed again, absent this round -- records as pending
# again, does NOT promote same-round.
tokd3="$(roundk "$L4" 0 0 0 full 0 --present-keys "$empty_keys" --claimed-keys "$claimed_D")"
assert_eq "$tokd3" "success" "confirm-pass round 3: D claimed again, absent on a full pass -> success (this round's own claim is not yet promoted)"
assert_eq "$(fixed_keys_of "$L4")" "" "confirm-pass round 3: D still NOT promoted -- this round's own claim can never be evaluated by this same round"
assert_eq "$(pending_claims_of "$L4")" "D" "confirm-pass round 3: D recorded as pending"

# Round 4: the NEXT full pass with evidence -- D still absent -> NOW it
# promotes.
tokd4="$(roundk "$L4" 0 0 0 full 0 --present-keys "$empty_keys" --claimed-keys "$empty_keys")"
assert_eq "$tokd4" "success" "confirm-pass round 4: next full pass, D still absent -> success"
assert_eq "$(fixed_keys_of "$L4")" "D" "confirm-pass round 4: D promoted once a LATER full-pass-with-evidence round confirms its continued absence"

# =========================================================================
# 5. Deferred key (never claimed at all) never promotes, regardless of how
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
# 6. Quarantined key never promotes.
# =========================================================================

L6="$(new_ledger)"
present_Q="$(keyfile Q)"

tok_q1="$(roundk "$L6" 0 0 0 full 1 --present-keys "$present_Q" --claimed-keys "$empty_keys")"
assert_eq "$tok_q1" "success_with_quarantine" "quarantined-key round 1: Q present+quarantined, unclaimed -> success_with_quarantine"
assert_eq "$(fixed_keys_of "$L6")" "" "quarantined-key round 1: Q never enters fixed_keys"

tok_q2="$(roundk "$L6" 0 0 0 full 1 --present-keys "$present_Q" --claimed-keys "$empty_keys")"
assert_ne "$tok_q2" "regression" "quarantined-key round 2: Q still present across rounds must NOT fire regression (never promoted)"

# =========================================================================
# 7. A fixed key reappearing in a `confirm` pass DOES fire regression
#    (regression fires on BOTH pass types; only promotion is full-pass-only
#    and evidence-gated). Setup: claim F while present (confirm), then a
#    genuine evaluation full pass promotes F, then a confirm pass sees F
#    reappear.
# =========================================================================

L7="$(new_ledger)"
claimed_F="$(keyfile F)"
present_F="$(keyfile F)"

tok_f1="$(roundk "$L7" 1 0 1 full 0 --present-keys "$present_F" --claimed-keys "$claimed_F")"
assert_eq "$tok_f1" "confirm" "confirm-regression setup round 1: claim F while F is still present -> confirm"
assert_eq "$(pending_claims_of "$L7")" "F" "confirm-regression setup round 1: F recorded as pending"

tok_f_eval="$(roundk "$L7" 0 0 0 full 0 --present-keys "$empty_keys" --claimed-keys "$empty_keys")"
assert_eq "$tok_f_eval" "success" "confirm-regression setup round 2 (evaluation pass, F absent) -> success"
assert_eq "$(fixed_keys_of "$L7")" "F" "confirm-regression setup round 2: F promoted to fixed_keys"

tok_f2="$(roundk "$L7" 1 0 1 confirm 0 --present-keys "$present_F" --claimed-keys "$empty_keys")"
assert_eq "$tok_f2" "regression" "confirm-regression round 3: F (fixed) reappears during a CONFIRM pass -> regression fires on both pass types"

# =========================================================================
# 8. --last-decision on a regression ledger exits terminal (5).
# =========================================================================

set +e
peek_out="$("$LEDGER_SCRIPT" --last-decision --ledger "$L7")"
peek_exit=$?
set -e
assert_eq "$peek_out" "regression" "--last-decision on a regression ledger reads back the regression token"
assert_eq "$peek_exit" "5" "--last-decision on a regression ledger exits 5 (terminal)"

# =========================================================================
# 9. Golden: append decision == subsequent --last-decision token; peek does
#    not re-promote (fixed_keys count + ledger bytes unchanged across peeks).
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
# 10. F2: key-file argument validation.
# =========================================================================

# 10a. --claimed-keys without --present-keys -> exit 2, 'convergence-ledger:'
# prefixed message.
L8="$(new_ledger)"
claimed_only="$(keyfile Z)"
claimed_only_stderr="$(mktemp)"
TMP_FILES+=("$claimed_only_stderr")
set +e
"$LEDGER_SCRIPT" --ledger "$L8" --count 0 --structural 0 --local 0 --pass-type full --quarantine 0 \
	--claimed-keys "$claimed_only" >/dev/null 2>"$claimed_only_stderr"
claimed_only_exit=$?
set -e
assert_eq "$claimed_only_exit" "2" "F2: --claimed-keys without --present-keys exits 2"
if grep -q 'convergence-ledger:.*--claimed-keys requires --present-keys' "$claimed_only_stderr"; then
	pass "F2: --claimed-keys-without-present-keys error message follows the documented convergence-ledger: prefix and wording"
else
	fail "F2: --claimed-keys-without-present-keys error message missing expected text (got: $(cat "$claimed_only_stderr"))"
fi

# 10b. Missing/nonexistent --present-keys file -> exit 2, ledger file NOT
# written/modified, 'convergence-ledger:' prefixed message.
L9="$(new_ledger)"
NONEXISTENT_PRESENT="$(mktemp -u)"
missing_present_stderr="$(mktemp)"
TMP_FILES+=("$missing_present_stderr")
set +e
"$LEDGER_SCRIPT" --ledger "$L9" --count 0 --structural 0 --local 0 --pass-type full --quarantine 0 \
	--present-keys "$NONEXISTENT_PRESENT" >/dev/null 2>"$missing_present_stderr"
missing_present_exit=$?
set -e
assert_eq "$missing_present_exit" "2" "F2: missing/nonexistent --present-keys file exits 2"
if grep -q 'convergence-ledger:.*--present-keys file not found or unreadable' "$missing_present_stderr"; then
	pass "F2: missing --present-keys error message follows the documented convergence-ledger: prefix and wording"
else
	fail "F2: missing --present-keys error message missing expected text (got: $(cat "$missing_present_stderr"))"
fi
if [[ ! -e "$L9" ]]; then
	pass "F2: missing --present-keys file -- the ledger was NOT created/written"
else
	fail "F2: missing --present-keys file -- the ledger file was written despite the exit-2 validation failure"
fi

# 10c. Empty (zero-byte) --present-keys file IS accepted as evidence (not
# an error) -- exit 0, decision computed normally.
L10a="$(new_ledger)"
zero_byte_present="$(keyfile)"
set +e
zero_byte_tok="$("$LEDGER_SCRIPT" --ledger "$L10a" --count 0 --structural 0 --local 0 --pass-type full --quarantine 0 \
	--present-keys "$zero_byte_present" 2>/dev/null)"
zero_byte_exit=$?
set -e
assert_eq "$zero_byte_exit" "0" "F2: a zero-byte --present-keys file is accepted as legitimate evidence, exit 0"
assert_eq "$zero_byte_tok" "success" "F2: a zero-byte --present-keys file on a clean full pass computes 'success' normally"

# 10d. Missing --claimed-keys file (with a VALID --present-keys supplied)
# keeps the tolerant behaviour: warn on stderr, treat as [], exit 0 exactly
# (narrowed from the old "0 or 2" tolerance).
L11="$(new_ledger)"
NONEXISTENT_CLAIMED="$(mktemp -u)"
malformed_stderr="$(mktemp)"
TMP_FILES+=("$malformed_stderr")
set +e
malformed_tok="$(roundk "$L11" 0 0 0 full 0 --present-keys "$empty_keys" --claimed-keys "$NONEXISTENT_CLAIMED" 2>"$malformed_stderr")"
malformed_exit=$?
set -e
assert_eq "$malformed_exit" "0" "F2: missing --claimed-keys file (with a valid --present-keys) exits 0 exactly (tolerant path)"
assert_eq "$malformed_tok" "success" "F2: missing --claimed-keys file still computes the decision normally (treated as an empty claim set)"
if grep -qi 'jq: error\|Traceback\|core dumped' "$malformed_stderr"; then
	fail "F2: missing --claimed-keys file: stderr shows a raw jq/interpreter crash, not a controlled warning"
else
	pass "F2: missing --claimed-keys file: no raw jq/interpreter crash on stderr"
fi

# 10e. A --claimed-keys file that exists but is garbage (blank lines /
# stray whitespace, not JSON) must also not crash -- keys files are plain
# newline-delimited lists, not JSON. Whitespace-only lines are trimmed, not
# merely non-empty-checked.
L12="$(new_ledger)"
garbage_keys="$(mktemp)"
TMP_FILES+=("$garbage_keys")
printf '\n   \n\t\nA\n\n' >"$garbage_keys"
set +e
garbage_tok="$(roundk "$L12" 0 0 0 full 0 --present-keys "$empty_keys" --claimed-keys "$garbage_keys" 2>/dev/null)"
garbage_exit=$?
set -e
assert_eq "$garbage_exit" "0" "F2: garbage/blank-line --claimed-keys file is tolerated, decision computed"
assert_eq "$garbage_tok" "success" "F2: garbage/blank-line --claimed-keys file still resolves the decision correctly"

# =========================================================================
# 11. F3: promotion requires unresolved == 0 -- a degraded full pass
#    (unresolved > 0) neither promotes NOR drops a pending claim.
# =========================================================================

L13="$(new_ledger)"
claimed_I="$(keyfile I)"
present_I="$(keyfile I)"

toki1="$(roundk "$L13" 1 0 1 full 0 --present-keys "$present_I" --claimed-keys "$claimed_I")"
assert_eq "$toki1" "confirm" "F3 round 1: claim I while present -> confirm"
assert_eq "$(pending_claims_of "$L13")" "I" "F3 round 1: I recorded as pending"

# A DEGRADED full pass (unresolved=1): the gate that would have
# re-reported I never ran, so its silence is not evidence in either
# direction -- I must remain pending, untouched.
toki2="$("$LEDGER_SCRIPT" --ledger "$L13" --count 0 --structural 0 --local 0 --pass-type full --quarantine 0 \
	--unresolved 1 --present-keys "$empty_keys" --claimed-keys "$empty_keys")"
assert_eq "$toki2" "continue" "F3 round 2: degraded full pass (unresolved=1), I absent -> continue (not success)"
assert_eq "$(fixed_keys_of "$L13")" "" "F3 round 2: I NOT promoted on a degraded (unresolved>0) full pass, despite being absent"
assert_eq "$(pending_claims_of "$L13")" "I" "F3 round 2: pending claim I is NOT dropped either -- an unresolved gate blocks both promotion and drop"

# A genuine (unresolved=0) full pass, I still absent -> now it promotes.
toki3="$("$LEDGER_SCRIPT" --ledger "$L13" --count 0 --structural 0 --local 0 --pass-type full --quarantine 0 \
	--unresolved 0 --present-keys "$empty_keys" --claimed-keys "$empty_keys")"
assert_eq "$toki3" "success" "F3 round 3: unresolved=0, I absent -> success"
assert_eq "$(fixed_keys_of "$L13")" "I" "F3 round 3: I promoted once a genuine (unresolved=0) full pass confirms its continued absence"

# =========================================================================
# 12. Decision-priority: success beats regression.
# =========================================================================
# A full pass with count=0 (nothing outstanding, unresolved=0, quarantine=0)
# is eligible for `success`. If present_keys ALSO happens to include a
# previously-fixed key (eligible for `regression`), success must win --
# regression is slotted strictly AFTER success in the priority chain.

L14="$(new_ledger)"
claimed_G="$(keyfile G)"
present_G="$(keyfile G)"

tok_g1="$(roundk "$L14" 1 0 1 full 0 --present-keys "$present_G" --claimed-keys "$claimed_G")"
assert_eq "$tok_g1" "confirm" "priority setup round 1: claim G while present -> confirm"

tok_g_eval="$(roundk "$L14" 0 0 0 full 0 --present-keys "$empty_keys" --claimed-keys "$empty_keys")"
assert_eq "$tok_g_eval" "success" "priority setup round 2 (evaluation pass, G absent) -> success"
assert_eq "$(fixed_keys_of "$L14")" "G" "priority setup round 2: G promoted to fixed_keys"

tok_g2="$(roundk "$L14" 0 0 0 full 0 --present-keys "$present_G" --claimed-keys "$empty_keys")"
assert_eq "$tok_g2" "success" "priority: success beats regression (count=0/unresolved=0/quarantine=0 wins even though G, a fixed key, is present)"

# =========================================================================
# 13. Decision-priority: regression beats cap.
# =========================================================================
# Use a small --cap so the boundary is reachable quickly. Claim+promote H
# across two setup rounds (loop_counter=1 confirm, loop_counter=2
# evaluation/promotion); round 3 both reaches loop_counter==cap AND
# re-presents the fixed key H -- regression must win over cap. --cap bumped
# from 2 to 3 (per the fix spec's blast-radius note) because the setup now
# spans one extra round.

L15="$(new_ledger)"
claimed_H="$(keyfile H)"
present_H="$(keyfile H)"

tok_h1="$(roundk "$L15" 1 0 1 full 0 --present-keys "$present_H" --claimed-keys "$claimed_H" --cap 3)"
assert_eq "$tok_h1" "confirm" "cap-priority setup round 1: claim H while present -> confirm (loop_counter=1)"

tok_h_eval="$(roundk "$L15" 0 0 0 full 0 --present-keys "$empty_keys" --claimed-keys "$empty_keys" --cap 3)"
assert_eq "$tok_h_eval" "success" "cap-priority setup round 2 (evaluation pass, H absent) -> success (loop_counter=2)"
assert_eq "$(fixed_keys_of "$L15")" "H" "cap-priority setup round 2: H promoted to fixed_keys"

tok_h2="$(roundk "$L15" 1 0 1 full 0 --present-keys "$present_H" --claimed-keys "$empty_keys" --cap 3)"
assert_eq "$tok_h2" "regression" "priority: regression beats cap (loop_counter reaches cap=3 on this round, but H, a fixed key, reappears -> regression wins)"


# ---------------------------------------------------------------------------
# (B9) The applier join must be EXACT on (file, line).
#
# r2 finding #9: the join used `[{file,line}] | inside($ok)`, and jq's
# `inside`/`contains` compare STRINGS BY SUBSTRING. A manifest holding only
# `vendor/src/a.js:10` therefore "matched" a finding at `src/a.js:10`,
# fabricating a claimed key for a fix that never happened — which the ledger
# promotes into fixed_keys on the next clean full pass and then reports as a
# terminal `regression` when the finding legitimately reappears.
#
# Invariant: join on (file, line) by EXACT EQUALITY of the pair, never by
# substring.
#
# R11/F2 RE-TARGETING. B9, A6 and A7 below used to `awk` the jq program out of
# each mirror's SKILL.md prose and run it. That prose no longer exists: the
# join is now scripts/claimed-findings.sh, bundled byte-identically into both
# mirrors. Testing the extracted prose was always a proxy for testing the
# rule; the rule now has an executable home, so these cases drive the BUNDLED
# copy in each mirror directly. That is strictly stronger — it exercises the
# artifact that actually runs, and it covers the CLI contract (which source
# is optional, which exit code) that prose extraction could not reach.
# ---------------------------------------------------------------------------

# claimed_for <mirror> <args...> — run the mirror's own bundled copy.
claimed_for() {
	local mirror="$1"
	shift
	"$ROOT_DIR/plugins/$mirror/skills/review-gauntlet/scripts/claimed-findings.sh" "$@"
}

b9_dir="$(mktemp -d)"
cat >"$b9_dir/manifest.json" <<'B9M'
[{"kind":"typo","file":"vendor/src/a.js","line":10,"status":"applied"}]
B9M
cat >"$b9_dir/annotated-envelope.json" <<'B9E'
{"findings":[
  {"file":"src/a.js","line":10,"category":"Logic","summary":"never fixed"},
  {"file":"other.js","line":10,"category":"Logic","summary":"also never fixed"}
]}
B9E

for b9_mirror in skein skein-codex; do
	b9_script="$ROOT_DIR/plugins/$b9_mirror/skills/review-gauntlet/scripts/claimed-findings.sh"
	if [[ ! -x "$b9_script" ]]; then
		fail "(B9/$b9_mirror) claimed-findings.sh is not bundled into this mirror: $b9_script"
		continue
	fi
	b9_out="$(claimed_for "$b9_mirror" --envelope "$b9_dir/annotated-envelope.json" \
		--manifest "$b9_dir/manifest.json" 2>"$b9_dir/err" || true)"
	if [[ -n "$b9_out" ]]; then
		fail "(B9/$b9_mirror) the applier join claimed an unfixed finding via substring match: $b9_out"
	else
		pass "(B9/$b9_mirror) the applier join is exact on (file, line): vendor/src/a.js:10 does not claim src/a.js:10"
	fi
done

# Positive control: an exact (file, line) hit must still be claimed, so the
# fix cannot pass by matching nothing at all.
cat >"$b9_dir/manifest-exact.json" <<'B9MX'
[{"kind":"typo","file":"src/a.js","line":10,"status":"applied"}]
B9MX
for b9_mirror in skein skein-codex; do
	b9_hit="$(claimed_for "$b9_mirror" --envelope "$b9_dir/annotated-envelope.json" \
		--manifest "$b9_dir/manifest-exact.json" 2>/dev/null | jq -r -s 'map(.file) | join(",")')"
	if [[ "$b9_hit" == "src/a.js" ]]; then
		pass "(B9/$b9_mirror) positive control: an exact (file, line) match is still claimed"
	else
		fail "(B9/$b9_mirror) positive control failed -- claimed files were '$b9_hit' (expected src/a.js)"
	fi
done

# ---------------------------------------------------------------------------
# (A6) The join may only claim a finding that is UNIQUE at its (file, line).
#
# Codex addendum A6. The manifest records (kind, file, line, status, ...) and
# `kind` is the auto-fix KIND, not a review category, so the join key cannot
# be tightened with a category -- there is nothing on the manifest side to
# match one against. The consequence must be fixed instead: two envelope
# findings sharing one (file, line) in different categories were BOTH claimed
# by a single applied fix, and a false claim is promoted into `fixed_keys` and
# fires the TERMINAL `regression` stop when the unfixed finding reappears.
# Asymmetry: under-claiming loses one key; over-claiming is a false stop.
# ---------------------------------------------------------------------------

a6_dir="$(mktemp -d)"
cat >"$a6_dir/manifest.json" <<'A6M'
[{"kind":"typo","file":"src/a.js","line":10,"status":"applied"},
 {"kind":"typo","file":"src/b.js","line":4,"status":"applied"}]
A6M
cat >"$a6_dir/annotated-envelope.json" <<'A6E'
{"findings":[
  {"file":"src/a.js","line":10,"category":"logic","summary":"ambiguous one"},
  {"file":"src/a.js","line":10,"category":"security","summary":"ambiguous two"},
  {"file":"src/b.js","line":4,"category":"logic","summary":"unambiguous"}
]}
A6E

for a6_mirror in skein skein-codex; do
	a6_hit="$(claimed_for "$a6_mirror" --envelope "$a6_dir/annotated-envelope.json" \
		--manifest "$a6_dir/manifest.json" 2>/dev/null |
		jq -r -s 'map(.file + ":" + (.line|tostring)) | sort | join(",")')"
	if [[ "$a6_hit" == "src/b.js:4" ]]; then
		pass "(A6/$a6_mirror) only the UNIQUE (file, line) finding is claimed; the ambiguous pair is not"
	else
		fail "(A6/$a6_mirror) the join over-claimed at an ambiguous (file, line) -- claimed '$a6_hit' (expected src/b.js:4)"
	fi
done

# ---------------------------------------------------------------------------
# (A7) A CLEAN round has neither claim artifact, and must not abort.
#
# Codex addendum A7. `jq -c '.claimed[]' fixer-report.json` was
# unconditional, and no fixer runs on a clean round -- jq exits 2 and aborts
# convergence exactly when it would have succeeded. The applier join had the
# SAME hole: `--slurpfile m "$auto_fix_manifest"` also fails when no applier
# ran. Rule: each source contributes an EMPTY list when its artifact is
# absent, and an empty $claimed_findings_file is legitimate.
#
# Post-R11 this is the SCRIPT's both-sources-optional contract on the runtime
# side, plus the two prose guards that decide whether each flag is passed at
# all on the SKILL.md side. Both halves are still asserted, because either one
# failing alone re-opens the abort.
# ---------------------------------------------------------------------------

a7_dir="$(mktemp -d)"
: >"$a7_dir/empty-manifest.json"
cp "$a6_dir/annotated-envelope.json" "$a7_dir/annotated-envelope.json"

for a7_mirror in skein skein-codex; do
	a7_skill="$ROOT_DIR/plugins/$a7_mirror/skills/review-gauntlet/SKILL.md"
	a7_script="$ROOT_DIR/plugins/$a7_mirror/skills/review-gauntlet/scripts/claimed-findings.sh"

	# Runtime totality: an EMPTY manifest slurps to [null]; `$m[0] // []`
	# must absorb it rather than erroring on `null | map(...)`.
	a7_rc=0
	a7_out="$(claimed_for "$a7_mirror" --envelope "$a7_dir/annotated-envelope.json" \
		--manifest "$a7_dir/empty-manifest.json" 2>/dev/null)" || a7_rc=$?
	if [[ "$a7_rc" -eq 0 && -z "$a7_out" ]]; then
		pass "(A7/$a7_mirror) an empty manifest exits 0 and claims nothing"
	else
		fail "(A7/$a7_mirror) aborted on an empty manifest (rc=$a7_rc, out='$a7_out')"
	fi

	# ...and no claim source at all is likewise a success with no output.
	a7_rc2=0
	a7_out2="$(claimed_for "$a7_mirror" --envelope "$a7_dir/annotated-envelope.json" 2>/dev/null)" || a7_rc2=$?
	if [[ "$a7_rc2" -eq 0 && -z "$a7_out2" ]]; then
		pass "(A7/$a7_mirror) neither claim source present exits 0 and claims nothing"
	else
		fail "(A7/$a7_mirror) aborted with no claim source (rc=$a7_rc2, out='$a7_out2')"
	fi

	# Totality of both extractions, asserted on the bundled source. These are
	# the two `?`/`//` forms whose removal reintroduces the abort.
	if grep -Fq '.claimed[]?' "$a7_script"; then
		pass "(A7/$a7_mirror) the bundled script uses the total \`.claimed[]?\` extraction"
	else
		fail "(A7/$a7_mirror) the bundled script no longer uses the total \`.claimed[]?\` extraction"
	fi
	if grep -Fq '($m[0] // [])' "$a7_script"; then
		pass "(A7/$a7_mirror) the bundled script keeps the total \`(\$m[0] // [])\` manifest read"
	else
		fail "(A7/$a7_mirror) the bundled script no longer guards a null-slurped manifest"
	fi

	# Prose side: each flag is only passed when its artifact exists. G11 (r3)
	# made the manifest guard set -u safe (`${auto_fix_manifest:-}`); accept
	# either spelling so the guard's presence, not its default syntax, is
	# tested. R11/F2 also moved both artifact paths onto $gate_out_dir --
	# they were bare cwd-relative before -- so the fixer-report guard is
	# matched on the flag and basename, not on a fixed full path.
	if grep -Eq '\[\[ -s "\$\{?auto_fix_manifest(:-)?\}?" \]\]' "$a7_skill"; then
		pass "(A7/$a7_mirror) the manifest flag is passed only when the manifest exists"
	else
		fail "(A7/$a7_mirror) the manifest flag is passed unconditionally -- a clean round with no applier exits 2"
	fi
	if grep -Eq '\[\[ -s "[^"]*fixer-report\.json" \]\]' "$a7_skill"; then
		pass "(A7/$a7_mirror) the fixer-report flag is passed only when the report exists"
	else
		fail "(A7/$a7_mirror) the fixer-report flag is passed unconditionally -- a clean round runs no fixer"
	fi
	if grep -Eq '\$gate_out_dir/(annotated-envelope|fixer-report)\.json' "$a7_skill"; then
		pass "(A7/$a7_mirror) the claim artifacts are composed from \$gate_out_dir, not read from a bare cwd-relative path"
	else
		fail "(A7/$a7_mirror) the claim artifacts are still bare cwd-relative paths"
	fi
done
rm -rf "$a6_dir" "$a7_dir"
rm -rf "$b9_dir"

echo ""
echo "Results: $pass_count passed, $fail_count failed"

if [[ "$fail_count" -gt 0 ]]; then
	exit 1
fi

exit 0
