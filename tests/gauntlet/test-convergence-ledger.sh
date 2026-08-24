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
# `jq` only to corroborate the monotonic-counter and running-min-stall
# invariants — the token itself is always read from stdout, never inferred.
#
# Exit codes: 0 all assertions pass, 1 any assertion fails.

set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
LEDGER_SCRIPT="$ROOT_DIR/plugins/skein/skills/review-gauntlet/lib/convergence-ledger.sh"
CLAUDE_COMMON="$ROOT_DIR/plugins/skein/skills/review-gauntlet/lib/gauntlet-common.sh"

# gc_hash FILE — hash via gauntlet-common.sh's own gc_sha1 helper (not a
# hand-rolled shasum/sha1sum fallback) so this test never drifts from the
# same hashing logic gc_ledger_path relies on. Run in a subshell so sourcing
# gauntlet-common.sh here doesn't collide with its readonly GC_LIB_DIR when
# other sections below source it again in their own subshells.
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

# --- 7. Sustained oscillation 5 -> 3 -> 5 -> 3 => terminal non-converge ---
# Under running-minimum-stall semantics, a lone up-tick is NOT terminal: after
# 5,3,5 the running minimum (3) has only stalled for one round, so round 3 is
# still `confirm`. It is the SECOND consecutive failure to beat the running
# minimum (round 4, giving stall streak K=2) that fires non-converge.

L="$(new_ledger)"
tok1="$(round "$L" 5 0 1 confirm 0)"
tok2="$(round "$L" 3 0 1 confirm 0)"
tok3="$(round "$L" 5 0 1 confirm 0)"
tok4="$(round "$L" 3 0 1 confirm 0)"
assert_eq "$tok1" "confirm" "oscillation round 1 (count=5, insufficient history) -> confirm"
assert_eq "$tok2" "confirm" "oscillation round 2 (count=3, new running min) -> confirm"
assert_eq "$tok3" "confirm" "oscillation round 3 (5,3,5 — running min 3 stalled only 1 round) -> confirm, NOT a premature bail"
assert_eq "$tok4" "non-converge" "oscillation round 4 (5,3,5,3 — running min 3 stalled K=2 rounds) -> terminal non-converge"

# --- 7b. Converging run with a transient blip must NOT false-bail ---------
# 5,4,5,3,2,1: a genuine convergence with one up-tick at round 3. A raw
# K-round window comparison would bail at round 3 (count[2]=5 >= count[0]=5);
# running-min-stall must not, because the running minimum keeps improving
# (5,4,4,3,2,1) so the stall streak never reaches K.

L="$(new_ledger)"
blip_bail=""
i=0
for c in 5 4 5 3 2 1; do
	i=$((i + 1))
	tok="$(round "$L" "$c" 0 1 confirm 0)"
	if [[ "$tok" == "non-converge" ]]; then
		blip_bail="round $i (count=$c)"
	fi
done
assert_eq "$blip_bail" "" "converging-with-blip 5,4,5,3,2,1 never fires non-converge (running min keeps improving)"

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

# --- 9b. Restart precedes non-convergence: a stalled count with a genuine --
# structural fix must still restart, not bail to non-converge. Regression
# for a rule-ordering bug: the stall-streak check was evaluated BEFORE the
# structural-restart check, so a structural round whose count failed to beat
# the running minimum for K rounds could resolve to non-converge instead of
# restart -- contradicting Requirements' unconditional "any structural fix
# lands in a round -> restart". Same count (5) every round with structural=1
# each time reaches a stall streak of K=2 by round 3, which would have fired
# non-converge under the old precedence.

L="$(new_ledger)"
tok1="$(round "$L" 5 1 0 full 0)"
assert_eq "$tok1" "restart" "restart-precedes-non-converge round 1 (count=5, structural=1) -> restart"
tok2="$(round "$L" 5 1 0 full 0)"
assert_eq "$tok2" "restart" "restart-precedes-non-converge round 2 (count=5, structural=1, stall streak building) -> restart"
tok3="$(round "$L" 5 1 0 full 0)"
assert_ne "$tok3" "non-converge" "restart-precedes-non-converge round 3 (stall streak reaches K=2) must not bail to non-converge"
assert_eq "$tok3" "restart" "restart-precedes-non-converge round 3 (count stalled AND structural fix present) -> restart wins over non-converge"

# --- 9c. Stall streak is scoped to the post-restart epoch -----------------
# Regression for a second, distinct bug: even with restart correctly taking
# precedence (9b above), the running-minimum stall detector walked the
# ENTIRE ledger history, so a count recorded before a structural restart
# could anchor the running minimum for rounds AFTER it -- comparing a
# freshly-restarted corpus against a stale pre-restart floor from a
# different corpus state. Sequence: round 1 count=1 (no restart, sets a low
# historical floor), round 2 count=5 structural=1 (restart -- corpus
# changes), round 3 count=4 (fresh post-restart measurement, no restart).
# Under the old whole-history reduce, round 3's streak was 2 (>= K=2)
# because neither round 2's nor round 3's count beat round 1's stale
# minimum of 1, incorrectly firing non-converge on a round that has no
# structural fix and where only ONE round has occurred since the restart
# (an epoch needs its own K+1 rounds before it can stall).

L="$(new_ledger)"
tok1="$(round "$L" 1 0 1 full 0)"
assert_eq "$tok1" "confirm" "epoch-scoping round 1 (count=1, no structural, sets a low pre-restart floor) -> confirm"
tok2="$(round "$L" 5 1 0 full 0)"
assert_eq "$tok2" "restart" "epoch-scoping round 2 (count=5, structural=1) -> restart (corpus changes here)"
tok3="$(round "$L" 4 0 1 full 0)"
assert_ne "$tok3" "non-converge" "epoch-scoping round 3 (count=4, fresh post-restart, only 1 round into the new epoch) must not bail to non-converge on the stale pre-restart minimum"
assert_eq "$tok3" "confirm" "epoch-scoping round 3 resolves to confirm (findings remain, no structural fix, epoch too young to stall)"

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

L="$(new_ledger)"
assert_nonzero_exit "non-integer --unresolved -> non-zero exit" \
	"$LEDGER_SCRIPT" --ledger "$L" --count 0 --structural 0 --local 0 --pass-type full --quarantine 0 --unresolved not-a-number

# --- 12. Unresolved gate blocks a clean full pass ------------------------
# A full pass at count=0 is `success` only when every gate produced a clean
# review. If any gate errored/skipped/deferred this round (--unresolved > 0),
# the round is NOT terminal — it must fall through to `continue` so the
# conductor re-runs the errored gate.

L="$(new_ledger)"
tok="$(round "$L" 0 0 0 full 0 --unresolved 0)"
assert_eq "$tok" "success" "clean full pass with --unresolved 0 -> success"

L="$(new_ledger)"
tok="$(round "$L" 0 0 0 full 0 --unresolved 1)"
assert_eq "$tok" "continue" "full pass count=0 but --unresolved 1 (a gate errored) -> continue, NOT success"

L="$(new_ledger)"
tok="$(round "$L" 0 0 0 full 2 --unresolved 1)"
assert_eq "$tok" "continue" "full pass count=0, quarantine>0, --unresolved 1 -> continue, NOT success_with_quarantine (errored gate outranks quarantine terminal)"

# --- 13. --target: first-use records, mismatch/match/legacy behavior ----

L="$(new_ledger)"
tok="$("$LEDGER_SCRIPT" --ledger "$L" --target "branch:foo" --count 0 --structural 0 --local 0 --pass-type full --quarantine 0)"
assert_eq "$tok" "success" "--target first-use: records target on a fresh ledger, round still resolves normally"
recorded_target="$(jq -r '.target' "$L")"
assert_eq "$recorded_target" "branch:foo" "--target first-use: ledger persists the recorded target"

set +e
"$LEDGER_SCRIPT" --ledger "$L" --target "branch:bar" --count 0 --structural 0 --local 0 --pass-type full --quarantine 0 >/tmp/gauntlet-ledger-test-out.$$ 2>&1
mismatch_exit=$?
set -e
rm -f "/tmp/gauntlet-ledger-test-out.$$"
assert_eq "$mismatch_exit" "3" "--target mismatch on append exits 3 (distinct from usage-error exit 2)"

L2="$(new_ledger)"
"$LEDGER_SCRIPT" --ledger "$L2" --target "branch:foo" --count 5 --structural 0 --local 1 --pass-type confirm --quarantine 0 >/dev/null
tok="$("$LEDGER_SCRIPT" --ledger "$L2" --target "branch:foo" --count 0 --structural 0 --local 0 --pass-type full --quarantine 0)"
assert_eq "$tok" "success" "--target matching value on a subsequent append succeeds"

L3="$(new_ledger)"
"$LEDGER_SCRIPT" --ledger "$L3" --target "branch:foo" --count 5 --structural 0 --local 1 --pass-type confirm --quarantine 0 >/dev/null
tok="$("$LEDGER_SCRIPT" --ledger "$L3" --count 0 --structural 0 --local 0 --pass-type full --quarantine 0)"
assert_eq "$tok" "success" "omitted --target on a subsequent append skips the mismatch check entirely"

# Legacy ledger: no "target" key at all (pre-upgrade shape) — first post-upgrade
# --target call must not treat "field absent" as a mismatch.
L4="$(new_ledger)"
printf '{"loop_counter": 0, "rounds": []}\n' >"$L4"
tok="$("$LEDGER_SCRIPT" --ledger "$L4" --target "branch:legacy" --count 0 --structural 0 --local 0 --pass-type full --quarantine 0)"
assert_eq "$tok" "success" "legacy (pre-target-field) ledger accepts any --target on first post-upgrade use"

# --target mismatch check on the --last-decision peek path too, not just append.
L5="$(new_ledger)"
"$LEDGER_SCRIPT" --ledger "$L5" --target "branch:foo" --count 5 --structural 0 --local 1 --pass-type confirm --quarantine 0 >/dev/null
set +e
"$LEDGER_SCRIPT" --last-decision --ledger "$L5" --target "branch:bar" >/tmp/gauntlet-ledger-test-out.$$ 2>&1
peek_mismatch_exit=$?
set -e
rm -f "/tmp/gauntlet-ledger-test-out.$$"
assert_eq "$peek_mismatch_exit" "3" "--target mismatch on --last-decision peek path also exits 3"

# --- 14. --last-decision: all seven tokens + no-rounds + not-found ------

# Non-terminal tokens via --last-decision (exit 0), matching the append-path
# token from section 1-5 above but read back via the read-only peek. The two
# terminal tokens (success/success_with_quarantine) are covered separately
# below alongside the other two terminal tokens (cap/non-converge).
for spec in "0 0 0 confirm 0:continue" "5 0 3 full 0:confirm" "5 1 0 full 0:restart"; do
	ledger="$(new_ledger)"
	args="${spec%%:*}"
	expected="${spec##*:}"
	# shellcheck disable=SC2086
	round "$ledger" $args >/dev/null
	peek_tok=""
	peek_exit=0
	peek_tok="$("$LEDGER_SCRIPT" --last-decision --ledger "$ledger")" || peek_exit=$?
	assert_eq "$peek_tok" "$expected" "--last-decision peek matches append-path token for '$args' -> $expected"
	assert_eq "$peek_exit" "0" "--last-decision peek for non-terminal token '$expected' exits 0"
done

# All four terminal tokens exit 5, not just success.
assert_terminal_peek() {
	local ledger="$1" expected="$2" label="$3"
	local tok exit_code
	exit_code=0
	tok="$("$LEDGER_SCRIPT" --last-decision --ledger "$ledger")" || exit_code=$?
	assert_eq "$tok" "$expected" "$label: token"
	assert_eq "$exit_code" "5" "$label: exits 5 (terminal)"
}

L="$(new_ledger)"
round "$L" 0 0 0 full 0 >/dev/null
assert_terminal_peek "$L" "success" "--last-decision terminal: success"

L="$(new_ledger)"
round "$L" 0 0 0 full 2 >/dev/null
assert_terminal_peek "$L" "success_with_quarantine" "--last-decision terminal: success_with_quarantine"

L="$(new_ledger)"
for c in 3 3 3; do round "$L" "$c" 0 1 confirm 0 >/dev/null; done
assert_terminal_peek "$L" "non-converge" "--last-decision terminal: non-converge"

L="$(new_ledger)"
for c in 10 9 8 7 6 5 4 3 2 1; do round "$L" "$c" 1 0 full 0 >/dev/null; done
assert_terminal_peek "$L" "cap" "--last-decision terminal: cap"

# Zero-round ledger -> no-rounds, exit 0 (distinct from the not-found case).
L="$(new_ledger)"
printf '{"loop_counter": 0, "rounds": []}\n' >"$L"
no_rounds_tok="$("$LEDGER_SCRIPT" --last-decision --ledger "$L")"
no_rounds_exit=0
"$LEDGER_SCRIPT" --last-decision --ledger "$L" >/dev/null 2>&1 || no_rounds_exit=$?
assert_eq "$no_rounds_tok" "no-rounds" "--last-decision on a zero-round ledger prints no-rounds"
assert_eq "$no_rounds_exit" "0" "--last-decision on a zero-round ledger exits 0, not an error"

# Nonexistent ledger file -> distinct not-found exit code (4), different from no-rounds.
NONEXISTENT="$(mktemp -u)"
set +e
"$LEDGER_SCRIPT" --last-decision --ledger "$NONEXISTENT" >/tmp/gauntlet-ledger-test-out.$$ 2>&1
not_found_exit=$?
set -e
rm -f "/tmp/gauntlet-ledger-test-out.$$"
assert_eq "$not_found_exit" "4" "--last-decision on a genuinely nonexistent ledger file exits 4 (distinct from no-rounds/exit 0)"

# --last-decision combined with a round-input flag is a usage error.
L="$(new_ledger)"
round "$L" 0 0 0 full 0 >/dev/null
assert_nonzero_exit "--last-decision combined with --count is a usage error" \
	"$LEDGER_SCRIPT" --last-decision --ledger "$L" --count 1

# --last-decision must not mutate loop_counter/rounds (byte-identical file before/after).
L="$(new_ledger)"
round "$L" 5 0 1 confirm 0 >/dev/null
before_hash="$(gc_hash "$L")"
"$LEDGER_SCRIPT" --last-decision --ledger "$L" >/dev/null
after_hash="$(gc_hash "$L")"
assert_eq "$after_hash" "$before_hash" "--last-decision peek does not mutate the ledger file (byte-identical before/after)"

# cap-boundary off-by-one: loop_counter == cap exactly reads back as cap, verbatim.
L="$(new_ledger)"
for c in 10 9 8 7 6 5 4 3 2 1; do round "$L" "$c" 1 0 full 0 >/dev/null; done
lc="$(jq -r '.loop_counter' "$L")"
assert_eq "$lc" "10" "cap-boundary: loop_counter reads back as exactly 10 (the default cap) after 10 structural rounds"
assert_terminal_peek "$L" "cap" "cap-boundary: --last-decision at loop_counter==cap peeks as cap using the stored counter verbatim, no off-by-one"

# --- 15. --init / --force ------------------------------------------------

INIT_L="$(mktemp -u)"
TMP_LEDGERS+=("$INIT_L")
"$LEDGER_SCRIPT" --init --ledger "$INIT_L" --target "branch:init-fresh"
if [[ -e "$INIT_L" ]]; then
	pass "--init on an absent path creates a fresh ledger file"
else
	fail "--init on an absent path creates a fresh ledger file (file not created)"
fi
init_target="$(jq -r '.target' "$INIT_L")"
init_counter="$(jq -r '.loop_counter' "$INIT_L")"
init_rounds="$(jq -r '.rounds | length' "$INIT_L")"
assert_eq "$init_target" "branch:init-fresh" "--init records the given --target"
assert_eq "$init_counter" "0" "--init creates loop_counter == 0"
assert_eq "$init_rounds" "0" "--init creates an empty rounds array"

set +e
"$LEDGER_SCRIPT" --init --ledger "$INIT_L" --target "branch:init-fresh" >/tmp/gauntlet-ledger-test-out.$$ 2>&1
reinit_exit=$?
set -e
rm -f "/tmp/gauntlet-ledger-test-out.$$"
assert_eq "$reinit_exit" "6" "--init on an existing path without --force refuses with exit 6"

# Populate the existing ledger with a round + distinct target, then --force
# reinitialize and confirm the old state is gone.
"$LEDGER_SCRIPT" --ledger "$INIT_L" --count 5 --structural 0 --local 1 --pass-type confirm --quarantine 0 >/dev/null
"$LEDGER_SCRIPT" --init --force --ledger "$INIT_L" --target "branch:init-forced"
forced_target="$(jq -r '.target' "$INIT_L")"
forced_counter="$(jq -r '.loop_counter' "$INIT_L")"
forced_rounds="$(jq -r '.rounds | length' "$INIT_L")"
assert_eq "$forced_target" "branch:init-forced" "--init --force truncates and reinitializes with the new target"
assert_eq "$forced_counter" "0" "--init --force resets loop_counter back to 0"
assert_eq "$forced_rounds" "0" "--init --force discards prior round history (old rounds gone)"

# --- 16. gc_ledger_path: sourced directly from gauntlet-common.sh (both mirrors) ---
# This needs its own sourcing harness since the script is normally invoked as
# a subprocess by convergence-ledger.sh, not sourced by tests. CLAUDE_COMMON
# is already sourced at the top of this file (for gc_sha1); only the Codex
# copy needs declaring here.

CODEX_COMMON="$ROOT_DIR/plugins/skein-codex/skills/review-gauntlet/lib/gauntlet-common.sh"

assert_gc_ledger_path_for() {
	local common_file="$1" mirror_label="$2"
	if [[ ! -f "$common_file" ]]; then
		fail "$mirror_label: gauntlet-common.sh missing: $common_file"
		return
	fi
	(
		# shellcheck source=/dev/null
		. "$common_file"

		local slug_path
		slug_path="$(gc_ledger_path "feature/foo-bar" claude)"
		local slug_basename
		slug_basename="$(basename "$slug_path")"
		if [[ "$slug_basename" != *"/"* && "$slug_basename" == *"feature-foo-bar"* ]]; then
			pass "$mirror_label: gc_ledger_path slugifies a branch name containing '/' to a '/'-free, filesystem-safe basename"
		else
			fail "$mirror_label: gc_ledger_path slugifies a branch name containing '/' to a '/'-free, filesystem-safe basename (got '$slug_basename')"
		fi

		local p1 p2
		p1="$(gc_ledger_path "branch:determinism-check" claude)"
		p2="$(gc_ledger_path "branch:determinism-check" claude)"
		if [[ "$p1" == "$p2" ]]; then
			pass "$mirror_label: gc_ledger_path is deterministic (same target+author -> same path)"
		else
			fail "$mirror_label: gc_ledger_path is deterministic (same target+author -> same path) (got '$p1' vs '$p2')"
		fi

		local pa pb
		pa="$(gc_ledger_path "branch:target-a" claude)"
		pb="$(gc_ledger_path "branch:target-b" claude)"
		if [[ "$pa" != "$pb" ]]; then
			pass "$mirror_label: gc_ledger_path distinct targets produce distinct paths (collision-safety)"
		else
			fail "$mirror_label: gc_ledger_path distinct targets produce distinct paths (collision-safety) (got '$pa' == '$pb')"
		fi

		local expected_root anchored_path
		expected_root="$(git rev-parse --show-toplevel)/.gauntlet/"
		anchored_path="$(gc_ledger_path "branch:anchor-check" claude)"
		if [[ "$anchored_path" == "$expected_root"* ]]; then
			pass "$mirror_label: gc_ledger_path is rooted at \$(git rev-parse --show-toplevel)/.gauntlet/"
		else
			fail "$mirror_label: gc_ledger_path is rooted at \$(git rev-parse --show-toplevel)/.gauntlet/ (got '$anchored_path', expected prefix '$expected_root')"
		fi

		local bogus_path
		bogus_path="$(CLAUDE_PLUGIN_ROOT="/bogus/plugin/root/that/does/not/exist" SKILL_DIR="/bogus/skill/dir/that/does/not/exist" gc_ledger_path "branch:anchor-check" claude)"
		if [[ "$bogus_path" == "$anchored_path" ]]; then
			pass "$mirror_label: gc_ledger_path's emitted path is unaffected by a bogus CLAUDE_PLUGIN_ROOT/SKILL_DIR (anchored at repo root, not the plugin anchor)"
		else
			fail "$mirror_label: gc_ledger_path's emitted path is unaffected by a bogus CLAUDE_PLUGIN_ROOT/SKILL_DIR (got '$bogus_path', expected '$anchored_path')"
		fi
	)
}

assert_gc_ledger_path_for "$CLAUDE_COMMON" "gc_ledger_path (Claude mirror)"
assert_gc_ledger_path_for "$CODEX_COMMON" "gc_ledger_path (Codex mirror)"

# Cross-mirror: gc_ledger_path's function body (not the whole file) is identical.
extract_fn_body() {
	local file="$1"
	sed -n '/^gc_ledger_path()[[:space:]]*{/,/^}/p' "$file"
}
claude_fn_body="$(extract_fn_body "$CLAUDE_COMMON")"
codex_fn_body="$(extract_fn_body "$CODEX_COMMON")"
if [[ -n "$claude_fn_body" && "$claude_fn_body" == "$codex_fn_body" ]]; then
	pass "gc_ledger_path function body is byte-identical across both mirrors"
else
	fail "gc_ledger_path function body is byte-identical across both mirrors"
fi

# --- 17. Cross-mirror byte-identity: convergence-ledger.sh (whole file) ---
# gauntlet-common.sh is deliberately NOT held to whole-file identity (it
# legitimately diverges at the ${CLAUDE_PLUGIN_ROOT}/$SKILL_DIR anchor lines
# in gc_bundled_scripts_dir) — only gc_ledger_path's function body is checked
# above (section 16). convergence-ledger.sh itself has no such divergence and
# must stay byte-identical across mirrors per Requirements.

CODEX_LEDGER_SCRIPT="$ROOT_DIR/plugins/skein-codex/skills/review-gauntlet/lib/convergence-ledger.sh"
if [[ ! -f "$CODEX_LEDGER_SCRIPT" ]]; then
	fail "Codex mirror convergence-ledger.sh missing: $CODEX_LEDGER_SCRIPT"
elif diff -q "$LEDGER_SCRIPT" "$CODEX_LEDGER_SCRIPT" >/dev/null 2>&1; then
	pass "convergence-ledger.sh is byte-identical across the Claude and Codex mirrors"
else
	fail "convergence-ledger.sh is byte-identical across the Claude and Codex mirrors"
fi

# --- 18. Phase 3 golden/byte-parity: flag-absent behaviour is UNCHANGED ---
# Plan: docs/dev_plans/20260823-feature-review-skills-resilience.md, Phase 3,
# Goal: "Existing ledger decisions are byte-for-byte unchanged when the key
# flags [--present-keys/--claimed-keys] are absent." This locks the exact
# on-disk ledger shape produced by an append call that never mentions the new
# flags: no present_keys/claimed_keys/fixed_keys pollution, decision tokens
# unchanged from the pre-Phase-3 golden values asserted in sections 1-17
# above. The golden JSON below is constructed inline (via jq, not a checked-in
# fixture) from the documented pre-Phase-3 schema, so this test does not
# depend on a byte-identical fixture surviving unrelated formatting drift.

golden_flag_absent_round() {
	local label="$1" count="$2" structural="$3" local_="$4" pass_type="$5" quarantine="$6" expected_json="$7"
	local ledger
	ledger="$(new_ledger)"
	"$LEDGER_SCRIPT" --ledger "$ledger" --target "branch:golden-$label" --count "$count" \
		--structural "$structural" --local "$local_" --pass-type "$pass_type" \
		--quarantine "$quarantine" >/dev/null
	local actual
	actual="$(jq -S . "$ledger")"
	local expected
	expected="$(jq -S . <<<"$expected_json")"
	assert_eq "$actual" "$expected" "$label: flag-absent append produces byte-for-byte-identical ledger shape (no present_keys/claimed_keys/fixed_keys pollution)"
}

golden_flag_absent_round "clean-full-pass" 0 0 0 full 0 \
	'{"target":"branch:golden-clean-full-pass","cap":10,"k":2,"loop_counter":1,"rounds":[{"count":0,"structural_tally":0,"local_tally":0,"pass_type":"full","quarantine_size":0,"unresolved_gates":0}]}'

golden_flag_absent_round "quarantine-success" 0 0 0 full 3 \
	'{"target":"branch:golden-quarantine-success","cap":10,"k":2,"loop_counter":1,"rounds":[{"count":0,"structural_tally":0,"local_tally":0,"pass_type":"full","quarantine_size":3,"unresolved_gates":0}]}'

golden_flag_absent_round "confirm-with-findings" 4 0 4 confirm 0 \
	'{"target":"branch:golden-confirm-with-findings","cap":10,"k":2,"loop_counter":1,"rounds":[{"count":4,"structural_tally":0,"local_tally":4,"pass_type":"confirm","quarantine_size":0,"unresolved_gates":0}]}'

# Decision tokens for the same three vectors must also be unchanged.
L_golden_tok="$(new_ledger)"
tok_golden="$(round "$L_golden_tok" 0 0 0 full 0)"
assert_eq "$tok_golden" "success" "flag-absent decision token unchanged: clean full pass -> success"

# --- 19. Backward compat: --resume (append + --last-decision) on a
#         pre-change ledger file lacking the new fields (no fixed_keys key
#         at all, matching a ledger written before Phase 3 shipped) --------

PRECHANGE_LEDGER="$(new_ledger)"
printf '{"target":"branch:precompat","cap":10,"k":2,"loop_counter":1,"rounds":[{"count":0,"structural_tally":0,"local_tally":0,"pass_type":"full","quarantine_size":0,"unresolved_gates":0}]}\n' >"$PRECHANGE_LEDGER"

set +e
precompat_peek="$("$LEDGER_SCRIPT" --last-decision --ledger "$PRECHANGE_LEDGER" --target "branch:precompat")"
precompat_peek_exit=$?
set -e
assert_eq "$precompat_peek" "success" "backward compat: --last-decision on a pre-Phase-3 ledger (no fixed_keys field) reads back its correct token"
assert_eq "$precompat_peek_exit" "5" "backward compat: --last-decision on the pre-Phase-3 ledger's terminal token still exits 5"

# A fresh --resume-style append onto that same pre-change ledger, with the
# new key flags actually supplied this time, must not crash on the missing
# fixed_keys field -- it should treat "field absent" as "empty fixed_keys".
PRECHANGE_LEDGER2="$(new_ledger)"
printf '{"target":"branch:precompat2","cap":10,"k":2,"loop_counter":2,"rounds":[{"count":3,"structural_tally":0,"local_tally":3,"pass_type":"confirm","quarantine_size":0,"unresolved_gates":0},{"count":3,"structural_tally":0,"local_tally":3,"pass_type":"confirm","quarantine_size":0,"unresolved_gates":0}]}\n' >"$PRECHANGE_LEDGER2"

present_keys_file="$(mktemp)"
TMP_LEDGERS+=("$present_keys_file")
printf 'some-regression-key\n' >"$present_keys_file"

set +e
precompat_resume_tok="$("$LEDGER_SCRIPT" --ledger "$PRECHANGE_LEDGER2" --target "branch:precompat2" \
	--count 0 --structural 0 --local 0 --pass-type full --quarantine 0 \
	--present-keys "$present_keys_file" 2>/tmp/gauntlet-ledger-test-precompat.$$)"
precompat_resume_exit=$?
set -e
rm -f /tmp/gauntlet-ledger-test-precompat.$$
if [[ "$precompat_resume_exit" -eq 0 ]]; then
	pass "backward compat: --resume append onto a pre-Phase-3 ledger (missing fixed_keys field) with --present-keys supplied does not crash, resolves normally ('$precompat_resume_tok')"
else
	fail "backward compat: --resume append onto a pre-Phase-3 ledger with --present-keys supplied must not crash (got exit $precompat_resume_exit)"
fi
assert_ne "$precompat_resume_tok" "regression" "backward compat: a present key never previously claimed on the pre-Phase-3 ledger must not spuriously fire regression (absent fixed_keys treated as empty, not as 'everything is fixed')"

echo ""
echo "Results: $pass_count passed, $fail_count failed"

if [[ "$fail_count" -gt 0 ]]; then
	exit 1
fi

exit 0
