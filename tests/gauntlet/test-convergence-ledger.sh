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

# One registered sink for the handful of places that run a command purely for
# its exit status and discard its output. R5/R11: these used to be spelled
# `/tmp/gauntlet-ledger-test-*.<pid>`, a PREDICTABLE path -- on a shared host a
# pre-planted symlink there is followed by bash's `>` redirect, truncating
# whatever the test-runner user can write, and the inline `rm -f` then removes
# the evidence. Every other temp file in this file already goes through
# `mktemp`; the asymmetry was the defect. Registered in TMP_LEDGERS so cleanup
# is trap-driven and survives an early `fail`, which an inline `rm -f` does
# not.
TMP_SINK="$(mktemp)"
TMP_LEDGERS+=("$TMP_SINK")

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
	if "$@" >"$TMP_SINK" 2>&1; then
		fail "$label (expected non-zero exit, got 0)"
	else
		pass "$label"
	fi
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
"$LEDGER_SCRIPT" --ledger "$L" --target "branch:bar" --count 0 --structural 0 --local 0 --pass-type full --quarantine 0 >"$TMP_SINK" 2>&1
mismatch_exit=$?
set -e
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
"$LEDGER_SCRIPT" --last-decision --ledger "$L5" --target "branch:bar" >"$TMP_SINK" 2>&1
peek_mismatch_exit=$?
set -e
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
"$LEDGER_SCRIPT" --last-decision --ledger "$NONEXISTENT" >"$TMP_SINK" 2>&1
not_found_exit=$?
set -e
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
"$LEDGER_SCRIPT" --init --ledger "$INIT_L" --target "branch:init-fresh" >"$TMP_SINK" 2>&1
reinit_exit=$?
set -e
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
precompat_err="$(mktemp)"
TMP_LEDGERS+=("$precompat_err")
printf 'some-regression-key\n' >"$present_keys_file"

set +e
precompat_resume_tok="$("$LEDGER_SCRIPT" --ledger "$PRECHANGE_LEDGER2" --target "branch:precompat2" \
	--count 0 --structural 0 --local 0 --pass-type full --quarantine 0 \
	--present-keys "$present_keys_file" 2>"$precompat_err")"
precompat_resume_exit=$?
set -e
if [[ "$precompat_resume_exit" -eq 0 ]]; then
	pass "backward compat: --resume append onto a pre-Phase-3 ledger (missing fixed_keys field) with --present-keys supplied does not crash, resolves normally ('$precompat_resume_tok')"
else
	fail "backward compat: --resume append onto a pre-Phase-3 ledger with --present-keys supplied must not crash (got exit $precompat_resume_exit)"
fi
assert_ne "$precompat_resume_tok" "regression" "backward compat: a present key never previously claimed on the pre-Phase-3 ledger must not spuriously fire regression (absent fixed_keys treated as empty, not as 'everything is fixed')"

# =========================================================================
# I7 byte-parity guard: a ledger built with NEITHER --present-keys NOR
# --claimed-keys ever supplied, across every round, must carry NEITHER
# `fixed_keys` NOR `pending_claims` at all -- the whole regression-key
# machinery (F1's deferred-promotion state) is additive and must not
# pollute a flags-absent ledger's shape.
# =========================================================================

FLAGS_ABSENT_LEDGER="$(new_ledger)"
"$LEDGER_SCRIPT" --ledger "$FLAGS_ABSENT_LEDGER" --count 3 --structural 0 --local 3 --pass-type full --quarantine 0 >/dev/null
"$LEDGER_SCRIPT" --ledger "$FLAGS_ABSENT_LEDGER" --count 0 --structural 1 --local 0 --pass-type full --quarantine 0 >/dev/null
"$LEDGER_SCRIPT" --ledger "$FLAGS_ABSENT_LEDGER" --count 0 --structural 0 --local 0 --pass-type full --quarantine 0 >/dev/null

if jq -e 'has("fixed_keys")' "$FLAGS_ABSENT_LEDGER" >/dev/null 2>&1; then
	fail "I7: a flags-absent ledger (never saw --present-keys/--claimed-keys) must NOT have a fixed_keys field"
else
	pass "I7: a flags-absent ledger has no fixed_keys field"
fi

if jq -e 'has("pending_claims")' "$FLAGS_ABSENT_LEDGER" >/dev/null 2>&1; then
	fail "I7: a flags-absent ledger (never saw --present-keys/--claimed-keys) must NOT have a pending_claims field"
else
	pass "I7: a flags-absent ledger has no pending_claims field"
fi

if jq -e '.rounds | map(has("present_keys") or has("claimed_keys")) | any' "$FLAGS_ABSENT_LEDGER" >/dev/null 2>&1; then
	fail "I7: a flags-absent ledger must not carry present_keys/claimed_keys on ANY round"
else
	pass "I7: a flags-absent ledger carries no present_keys/claimed_keys on any round"
fi

# --- G7 (finding 10): @tsv + IFS=$'\t' collapses EMPTY fields -------------
# Tab is IFS-whitespace, so bash collapses runs of tabs and empty fields
# vanish, shifting every later field. On a ledger written before `cap`/`k`
# were persisted (or one carrying an explicit `"cap": null`), the decision
# chain read shifted values: `pass_type` became `0`, so a clean full pass
# could never fire `success`, and --last-decision silently degraded to
# `continue`.

handmade_ledger() {
	local f
	f="$(mktemp)"
	TMP_LEDGERS+=("$f")
	cat >"$f"
	printf '%s\n' "$f"
}

# (a) A pre-cap/k ledger: neither key present at all.
L_precap="$(
	handmade_ledger <<'EOF'
{
  "loop_counter": 1,
  "rounds": [
    {
      "count": 0,
      "structural_tally": 0,
      "local_tally": 0,
      "pass_type": "full",
      "quarantine_size": 0,
      "unresolved_gates": 0
    }
  ]
}
EOF
)"
precap_tok="$("$LEDGER_SCRIPT" --last-decision --ledger "$L_precap" 2>/dev/null || true)"
assert_eq "$precap_tok" "success" "G7(a): a pre-cap/k ledger's clean full pass still decodes to success (no field shift)"

# (b) An explicit "cap": null / "k": null must behave like absent, not like
# the literal string "null".
L_nullcap="$(
	handmade_ledger <<'EOF'
{
  "loop_counter": 1,
  "cap": null,
  "k": null,
  "rounds": [
    {
      "count": 0,
      "structural_tally": 0,
      "local_tally": 0,
      "pass_type": "full",
      "quarantine_size": 2,
      "unresolved_gates": 0
    }
  ]
}
EOF
)"
nullcap_tok="$("$LEDGER_SCRIPT" --last-decision --ledger "$L_nullcap" 2>/dev/null || true)"
assert_eq "$nullcap_tok" "success_with_quarantine" "G7(b): an explicit \"cap\": null decodes as absent, not as the string \"null\""

# (c) A round whose pass_type is 'confirm' with findings must still decode
# positionally even with cap/k absent.
L_confirm="$(
	handmade_ledger <<'EOF'
{
  "loop_counter": 2,
  "rounds": [
    {
      "count": 4,
      "structural_tally": 2,
      "local_tally": 2,
      "pass_type": "confirm",
      "quarantine_size": 0,
      "unresolved_gates": 0
    }
  ]
}
EOF
)"
confirm_tok="$("$LEDGER_SCRIPT" --last-decision --ledger "$L_confirm" 2>/dev/null || true)"
assert_eq "$confirm_tok" "restart" "G7(c): structural_tally decodes in the right position with cap/k absent (-> restart)"

# --- G7 (finding 14): unresolved_gates and non-integral numbers ------------
# validate_last_round_fields never checked unresolved_gates, and `number`
# admits 1.5. Both reached bash arithmetic and crashed outside the
# documented exit-code contract.

L_bad_unresolved="$(
	handmade_ledger <<'EOF'
{
  "loop_counter": 1,
  "rounds": [
    {
      "count": 0,
      "structural_tally": 0,
      "local_tally": 0,
      "pass_type": "full",
      "quarantine_size": 0,
      "unresolved_gates": "oops"
    }
  ]
}
EOF
)"
bu_rc=0
bu_out="$("$LEDGER_SCRIPT" --last-decision --ledger "$L_bad_unresolved" 2>/dev/null)" || bu_rc=$?
if [[ "$bu_rc" -eq 2 && -z "$bu_out" ]]; then
	pass "G7(d): a non-numeric unresolved_gates exits 2 (invalid ledger), not an arithmetic crash"
else
	fail "G7(d): non-numeric unresolved_gates should exit 2 with empty stdout (rc=$bu_rc, out='$bu_out')"
fi

L_frac="$(
	handmade_ledger <<'EOF'
{
  "loop_counter": 1,
  "rounds": [
    {
      "count": 0,
      "structural_tally": 0,
      "local_tally": 0,
      "pass_type": "full",
      "quarantine_size": 0,
      "unresolved_gates": 1.5
    }
  ]
}
EOF
)"
fr_rc=0
fr_out="$("$LEDGER_SCRIPT" --last-decision --ledger "$L_frac" 2>/dev/null)" || fr_rc=$?
if [[ "$fr_rc" -eq 2 && -z "$fr_out" ]]; then
	pass "G7(e): a non-integral unresolved_gates (1.5) exits 2, not an arithmetic crash"
else
	fail "G7(e): non-integral unresolved_gates should exit 2 with empty stdout (rc=$fr_rc, out='$fr_out')"
fi

L_frac_count="$(
	handmade_ledger <<'EOF'
{
  "loop_counter": 1,
  "rounds": [
    {
      "count": 1.5,
      "structural_tally": 0,
      "local_tally": 0,
      "pass_type": "full",
      "quarantine_size": 0,
      "unresolved_gates": 0
    }
  ]
}
EOF
)"
fc_rc=0
fc_out="$("$LEDGER_SCRIPT" --last-decision --ledger "$L_frac_count" 2>/dev/null)" || fc_rc=$?
if [[ "$fc_rc" -eq 2 && -z "$fc_out" ]]; then
	pass "G7(f): a non-integral count (1.5) exits 2, not an arithmetic crash"
else
	fail "G7(f): non-integral count should exit 2 with empty stdout (rc=$fc_rc, out='$fc_out')"
fi

# A missing unresolved_gates stays legal (it defaults to 0) — the tightened
# validator must not break the documented backward-compatible ledger shape.
L_no_unresolved="$(
	handmade_ledger <<'EOF'
{
  "loop_counter": 1,
  "rounds": [
    {
      "count": 0,
      "structural_tally": 0,
      "local_tally": 0,
      "pass_type": "full",
      "quarantine_size": 0
    }
  ]
}
EOF
)"
nu_tok="$("$LEDGER_SCRIPT" --last-decision --ledger "$L_no_unresolved" 2>/dev/null || true)"
assert_eq "$nu_tok" "success" "G7(g): a ledger with no unresolved_gates key still decodes (defaults to 0)"

# --- G8. The ledger write must be a same-filesystem rename ---------------
#
# r2 finding #18: both write paths (`write_fresh_ledger` and the round-append
# handler) used a bare `mktemp`, which lands in $TMPDIR, then `mv` to
# $LEDGER_PATH. The header asserts the write cannot leave a truncated file if
# killed mid-write — true only for a same-filesystem `rename(2)`. `mv` across
# filesystems is a copy-then-unlink, which has no such guarantee (macOS
# happens to put /tmp on the same device; Linux CI commonly puts it on tmpfs).
#
# Invariant, old -> new: "atomic replace" held only when $TMPDIR happened to
# share a device with the ledger's directory -> it holds unconditionally,
# because the temp file is created IN THE LEDGER'S OWN DIRECTORY (the
# in-directory template `persist_atomic_write` already uses).
#
# Two observable consequences are asserted, since the rename itself is not
# directly observable: (a) the temp file is a sibling of the ledger, so no
# `.ledger.*` residue may survive a successful write; (b) the write no longer
# depends on $TMPDIR at all, so an unusable $TMPDIR must not break it.

g8_dir="$(mktemp -d)"
g8_ledger="$g8_dir/sub/gauntlet-ledger.json"

# (a) fresh-ledger write (--init path) then an append round, both clean.
g8_tok_init="$(round "$g8_ledger" 1 0 1 full 0 --target "branch:g8" || true)"
g8_tok_append="$(round "$g8_ledger" 0 0 0 full 0 || true)"
if [[ ! -f "$g8_ledger" ]]; then
	fail "G8(a): no ledger written at $g8_ledger (tokens: '$g8_tok_init'/'$g8_tok_append')"
elif [[ -n "$(find "$g8_dir" -name '.ledger.*' -print -quit)" ]]; then
	fail "G8(a): temp-file residue left beside the ledger: $(find "$g8_dir" -name '.ledger.*')"
elif ! jq empty "$g8_ledger" >/dev/null 2>&1; then
	fail "G8(a): ledger is not valid JSON after two writes"
else
	pass "G8(a): both write paths leave a valid ledger and no .ledger.* residue"
fi

# (b) an unusable $TMPDIR must not break either write path. A bare `mktemp`
# fails outright here; an in-directory template never consults $TMPDIR.
g8_dir2="$(mktemp -d)"
g8_ledger2="$g8_dir2/sub/gauntlet-ledger.json"
g8_rc=0
TMPDIR=/nonexistent-skein-r2 "$LEDGER_SCRIPT" --ledger "$g8_ledger2" \
	--target "branch:g8b" --count 1 --structural 0 --local 1 \
	--pass-type full --quarantine 0 >"$g8_dir2/tok" 2>"$g8_dir2/err" || g8_rc=$?
if [[ $g8_rc -ne 0 ]]; then
	fail "G8(b): fresh-ledger write failed under an unusable \$TMPDIR (rc=$g8_rc; $(tr '\n' ' ' <"$g8_dir2/err"))"
elif [[ ! -f "$g8_ledger2" ]]; then
	fail "G8(b): no ledger written under an unusable \$TMPDIR"
else
	g8_rc2=0
	TMPDIR=/nonexistent-skein-r2 "$LEDGER_SCRIPT" --ledger "$g8_ledger2" \
		--count 0 --structural 0 --local 0 --pass-type full --quarantine 0 \
		>"$g8_dir2/tok2" 2>"$g8_dir2/err2" || g8_rc2=$?
	if [[ $g8_rc2 -ne 0 ]]; then
		fail "G8(b): append round failed under an unusable \$TMPDIR (rc=$g8_rc2; $(tr '\n' ' ' <"$g8_dir2/err2"))"
	elif [[ "$(jq -r '.loop_counter' "$g8_ledger2")" != "2" ]]; then
		fail "G8(b): append round under an unusable \$TMPDIR did not record the round (loop_counter=$(jq -r '.loop_counter' "$g8_ledger2"))"
	else
		pass "G8(b): both write paths are independent of \$TMPDIR"
	fi
fi

# (c) The rename's atomicity is NOT directly observable from a test: `mv`
# across filesystems still succeeds (it degrades to copy-then-unlink), and on
# macOS a bare `mktemp` ignores $TMPDIR entirely, so (b) above cannot go RED
# on this host even though it is the real Linux-CI regression. Assert the
# mechanism structurally as well: every `mktemp` in the ledger must be given
# an IN-DIRECTORY template derived from the ledger's own path, so the
# subsequent `mv` is always a same-filesystem rename(2).
g8_bare="$(awk '
	{ line = $0; sub(/^[[:space:]]+/, "", line) }
	line ~ /^#/ { next }
	/mktemp/ && !/dirname/ { printf "%d:%s\n", NR, line }
' "$LEDGER_SCRIPT")"
if [[ -n "$g8_bare" ]]; then
	fail "G8(c): convergence-ledger.sh has a mktemp with no in-directory template (mv would be cross-filesystem): $g8_bare"
else
	pass "G8(c): every mktemp in convergence-ledger.sh uses an in-directory template"
fi
rm -rf "$g8_dir" "$g8_dir2"

# ---------------------------------------------------------------------------
# (G12) The ledger write paths must refuse a symlinked target or parent.
#
# persist_atomic_write (scripts/lib/persist-common.sh) guards exactly this
# case for the state files and documents the threat: `.gauntlet/` is
# gitignored, but a *tracked* symlink at that path still materialises on
# checkout, and `mkdir -p` follows it. Impact is bounded (a ledger-shaped
# JSON file in an attacker-chosen user-writable directory) -- the asymmetry
# inside one change set is the point.
#
# The fixture is built INSIDE the repo worktree on purpose: the guard's
# parent walk is deliberately bounded to the worktree (a checkout is the only
# way this symlink appears), so a fixture in $TMPDIR would exercise the
# bounded, early-return path instead of the real one.
# ---------------------------------------------------------------------------
g12_base="$ROOT_DIR/.gauntlet-g12-fixture.$$"
mkdir -p "$g12_base/run" "$g12_base/outside"
ln -s "$g12_base/outside" "$g12_base/run/.gauntlet"
g12_ledger="$g12_base/run/.gauntlet/ledger.json"

set +e
g12_err="$(bash "$LEDGER_SCRIPT" --ledger "$g12_ledger" --init --target "t" --cap 3 --k 2 2>&1 >/dev/null)"
g12_rc=$?
set -e

if [[ "$g12_rc" -ne 0 ]]; then
	pass "G12: a fresh-ledger write through a symlinked parent exits non-zero (rc=$g12_rc)"
else
	fail "G12: a fresh-ledger write through a symlinked parent must exit non-zero (got 0)"
fi
if [[ "$g12_err" == *"refusing to operate on symlink"* ]]; then
	pass "G12: the refusal names the symlink in its diagnostic"
else
	fail "G12: expected a 'refusing to operate on symlink' diagnostic, got: $g12_err"
fi
if [[ ! -e "$g12_base/outside/ledger.json" ]]; then
	pass "G12: nothing was written through the symlink into the outside directory"
else
	fail "G12: the write escaped through the symlink to $g12_base/outside/ledger.json"
fi

# A DIRECT symlink at the ledger path itself is refused too.
mkdir -p "$g12_base/run2/.gauntlet"
ln -s "$g12_base/outside/direct.json" "$g12_base/run2/.gauntlet/ledger.json"
set +e
g12_direct_err="$(bash "$LEDGER_SCRIPT" --ledger "$g12_base/run2/.gauntlet/ledger.json" --init --target "t" --cap 3 --k 2 2>&1 >/dev/null)"
g12_direct_rc=$?
set -e
if [[ "$g12_direct_rc" -ne 0 && "$g12_direct_err" == *"refusing to operate on symlink"* && ! -e "$g12_base/outside/direct.json" ]]; then
	pass "G12: a symlink AT the ledger path is refused and nothing is written through it"
else
	fail "G12: direct-symlink case: rc=$g12_direct_rc err='$g12_direct_err'"
fi

# Control: the same write into a real directory still succeeds, so the guard
# is rejecting the symlink and not the write path.
mkdir -p "$g12_base/clean/.gauntlet"
set +e
bash "$LEDGER_SCRIPT" --ledger "$g12_base/clean/.gauntlet/ledger.json" --init --target "t" --cap 3 --k 2 >/dev/null 2>&1
g12_clean_rc=$?
set -e
if [[ "$g12_clean_rc" -eq 0 && -f "$g12_base/clean/.gauntlet/ledger.json" ]]; then
	pass "G12(control): an unsymlinked ledger path still writes normally"
else
	fail "G12(control): a clean ledger write broke (rc=$g12_clean_rc)"
fi

rm -rf "$g12_base"

# ---------------------------------------------------------------------------
# G13 (r4 F7 + Codex addendum) — the parent walk is bounded BY the worktree
# root, and it does not give up on an ancestor that does not exist yet.
#
# F7: the old loop advanced `parent` past the already-checked parent and then
# applied `-L` BEFORE the root-equality break, so when the checked parent WAS
# the root, the first iteration tested the ROOT'S PARENT. Under a repo whose
# own ancestor is a symlink (`/tmp` -> `/private/tmp` on macOS is the everyday
# case) that refused a perfectly legitimate `--init`.
#
# Codex addendum (convergence-ledger.sh:508): the containment probe returned
# SUCCESS when `cd "$parent"` failed. For `--ledger "$repo/link/sub/new/l.json"`
# with `link` a symlink pointing out of the repo, `$repo/link/sub/new` does not
# exist, the probe bailed out with 0, and `mkdir -p` then followed the symlink
# and wrote the ledger outside the worktree. Unresolved ancestors must be
# WALKED, not treated as proof of safety.
# ---------------------------------------------------------------------------

# Fixture geometry matches the reported repro exactly: the SYMLINK is the
# worktree root's PARENT (`symtest` -> `symreal`), and every component from
# the root downward is a real directory.
g13_base="$(mktemp -d "${TMPDIR:-/tmp}/gauntlet-g13.XXXXXX")"
g13_real="$g13_base/symreal"
g13_link="$g13_base/symtest"
mkdir -p "$g13_real/repo"
ln -s "$g13_real" "$g13_link"
g13_repo="$g13_link/repo"

(
	cd "$g13_repo"
	git init -q
	git config user.email "t@example.com"
	git config user.name "T"
	echo x >README.md
	git add README.md
	git commit -q -m init
) >/dev/null 2>&1

set +e
g13_sym_err="$(cd "$g13_repo" && bash "$LEDGER_SCRIPT" --ledger "$g13_repo/.gauntlet/ledger.json" \
	--init --target "t" --cap 3 --k 2 2>&1 >/dev/null)"
g13_sym_rc=$?
set -e
if [[ "$g13_sym_rc" -eq 0 && -f "$g13_real/repo/.gauntlet/ledger.json" ]]; then
	pass "G13(F7): a repo under a symlinked ancestor still --inits (nothing above the worktree root is -L-tested)"
else
	fail "G13(F7): rc=$g13_sym_rc err='$g13_sym_err' (a symlinked ancestor ABOVE the worktree root must not be tested)"
fi

# Codex addendum: an UNRESOLVED chain, strictly inside the root, whose first
# EXISTING component is a symlink out of the repo. `$repo/link2/sub/new` does
# not exist, so the old containment probe could not `cd` into it and returned
# SUCCESS -- then `mkdir -p` followed `link2` and wrote the ledger outside the
# worktree. The walk must climb through the unresolved components, reach
# `link2`, and refuse before anything is created.
g13_out="$g13_base/outside"
mkdir -p "$g13_out"
ln -s "$g13_out" "$g13_real/repo/link2"
set +e
g13_unres_err="$(cd "$g13_repo" && bash "$LEDGER_SCRIPT" \
	--ledger "$g13_repo/link2/sub/new/ledger.json" --init --target "t" --cap 3 --k 2 2>&1 >/dev/null)"
g13_unres_rc=$?
set -e
if [[ "$g13_unres_rc" -ne 0 && "$g13_unres_err" == *"refusing to operate on symlink"* &&
	! -e "$g13_out/sub" ]]; then
	pass "G13(addendum): an unresolved ancestor chain through a symlink is refused before mkdir"
else
	fail "G13(addendum): rc=$g13_unres_rc err='$g13_unres_err' escaped=$([[ -e "$g13_out/sub" ]] && echo yes || echo no)"
fi

# Control: a symlinked INTERMEDIATE directory strictly inside the root is
# still refused -- the F7 fix must not widen the hole it narrows.
ln -s "$g13_out" "$g13_real/repo/inner"
set +e
g13_inner_err="$(cd "$g13_repo" && bash "$LEDGER_SCRIPT" \
	--ledger "$g13_repo/inner/ledger.json" --init --target "t" --cap 3 --k 2 2>&1 >/dev/null)"
g13_inner_rc=$?
set -e
if [[ "$g13_inner_rc" -ne 0 && "$g13_inner_err" == *"refusing to operate on symlink"* &&
	! -e "$g13_out/ledger.json" ]]; then
	pass "G13(control): a symlinked intermediate dir strictly inside the root is still refused"
else
	fail "G13(control): rc=$g13_inner_rc err='$g13_inner_err'"
fi

# G14 (C1, design step 1): a `..` component anywhere in the ledger path is
# REFUSED outright. This is not tidiness -- it is what makes every other check
# in this guard sound. The walk is lexical, and lexical normalisation is
# unsound under symlinks: `$repo/link/../.gauntlet` does NOT mean
# `$repo/.gauntlet` when `link` is a symlink, it means
# `<link-target-parent>/.gauntlet`. Any guard that reasons about components
# can be walked straight past by a `..` that re-enters somewhere else, so the
# fail-closed answer is to reject the shape rather than try to resolve it.
g14_base="$(mktemp -d "${TMPDIR:-/tmp}/gauntlet-g14.XXXXXX")"
g14_out="$g14_base/outside"
mkdir -p "$g14_base/repo" "$g14_out"
(
	cd "$g14_base/repo"
	git init -q
	git config user.email "t@example.com"
	git config user.name "T"
	echo x >README.md
	git add README.md
	git commit -q -m init
) >/dev/null 2>&1
ln -s "$g14_out" "$g14_base/repo/esc"

set +e
g14_err="$(cd "$g14_base/repo" && bash "$LEDGER_SCRIPT" \
	--ledger "$g14_base/repo/esc/../ledger.json" --init --target "t" --cap 3 --k 2 2>&1 >/dev/null)"
g14_rc=$?
set -e
if [[ "$g14_rc" -ne 0 && "$g14_err" == *".."* && ! -e "$g14_base/ledger.json" ]]; then
	pass "G14: a '..' component in the ledger path is refused with a diagnostic naming it"
else
	fail "G14: rc=$g14_rc err='$g14_err' (a '..' component must be refused, not lexically resolved)"
fi

# A plain `..` with no symlink involved is refused too -- the rule is on the
# SHAPE of the path, not on whether this particular one happens to escape.
set +e
g14b_err="$(cd "$g14_base/repo" && bash "$LEDGER_SCRIPT" \
	--ledger "$g14_base/repo/sub/../ledger.json" --init --target "t" --cap 3 --k 2 2>&1 >/dev/null)"
g14b_rc=$?
set -e
if [[ "$g14b_rc" -ne 0 && "$g14b_err" == *".."* ]]; then
	pass "G14: the '..' rejection is unconditional, not contingent on an escape"
else
	fail "G14: rc=$g14b_rc err='$g14b_err'"
fi

# Control: an ordinary filename that merely CONTAINS dots is not a `..`
# component and must still be accepted.
set +e
g14c_err="$(cd "$g14_base/repo" && bash "$LEDGER_SCRIPT" \
	--ledger "$g14_base/repo/.gauntlet/a..b.json" --init --target "t" --cap 3 --k 2 2>&1 >/dev/null)"
g14c_rc=$?
set -e
if [[ "$g14c_rc" -eq 0 && -f "$g14_base/repo/.gauntlet/a..b.json" ]]; then
	pass "G14(control): a filename containing '..' is not a '..' component and is accepted"
else
	fail "G14(control): rc=$g14c_rc err='$g14c_err'"
fi

rm -rf "$g14_base"

rm -rf "$g13_base"

# --- R11 F5: root-level arithmetic fields (cap / k / loop_counter) ---------
# validate_ledger_fields (renamed from validate_last_round_fields) gated only
# the LAST ROUND's five numbers. `cap`, `k` and `loop_counter` are top-level
# ledger fields that feed `((loop_counter >= cap))` and `((epoch_len >= k+1))`
# with no gate at all, so a malformed one either DEGRADED a terminal stop into
# a non-terminal token (fractional cap -> the `cap` comparison errors, the
# chain falls through to `continue`, exit 0) or crashed outside the documented
# 0/2/3/4/5/6 alphabet (non-numeric k -> unbound-variable exit 1). Both must
# now be exit 2 (invalid ledger), the code already reserved for this class.
#
# Each fixture is otherwise a ledger that WOULD reach the guarded comparison:
# loop_counter 3 against cap 1.5 is past any sane cap, and the k fixture's
# last round is a non-clean full pass that falls through to the epoch check.

L_frac_cap="$(
	handmade_ledger <<'EOF'
{
  "loop_counter": 3,
  "cap": 1.5,
  "k": 2,
  "rounds": [
    {
      "count": 2,
      "structural_tally": 0,
      "local_tally": 0,
      "pass_type": "full",
      "quarantine_size": 0,
      "unresolved_gates": 0
    }
  ]
}
EOF
)"
fcap_rc=0
fcap_out="$("$LEDGER_SCRIPT" --last-decision --ledger "$L_frac_cap" 2>/dev/null)" || fcap_rc=$?
if [[ "$fcap_rc" -eq 2 && -z "$fcap_out" ]]; then
	pass "R11-F5a: a fractional cap (1.5) exits 2, not a silent non-terminal continue"
else
	fail "R11-F5a: fractional cap should exit 2 with empty stdout (rc=$fcap_rc, out='$fcap_out')"
fi

L_bad_k="$(
	handmade_ledger <<'EOF'
{
  "loop_counter": 3,
  "cap": 10,
  "k": "abc",
  "rounds": [
    {
      "count": 2,
      "structural_tally": 0,
      "local_tally": 0,
      "pass_type": "full",
      "quarantine_size": 0,
      "unresolved_gates": 0
    }
  ]
}
EOF
)"
bk_rc=0
bk_out="$("$LEDGER_SCRIPT" --last-decision --ledger "$L_bad_k" 2>/dev/null)" || bk_rc=$?
if [[ "$bk_rc" -eq 2 && -z "$bk_out" ]]; then
	pass "R11-F5b: a non-numeric k exits 2, inside the documented exit-code alphabet"
else
	fail "R11-F5b: non-numeric k should exit 2 with empty stdout (rc=$bk_rc, out='$bk_out')"
fi

L_frac_lc="$(
	handmade_ledger <<'EOF'
{
  "loop_counter": 1.5,
  "rounds": [
    {
      "count": 0,
      "structural_tally": 0,
      "local_tally": 0,
      "pass_type": "confirm",
      "quarantine_size": 0,
      "unresolved_gates": 0
    }
  ]
}
EOF
)"
flc_rc=0
flc_out="$("$LEDGER_SCRIPT" --last-decision --ledger "$L_frac_lc" 2>/dev/null)" || flc_rc=$?
if [[ "$flc_rc" -eq 2 && -z "$flc_out" ]]; then
	pass "R11-F5c: a non-integral loop_counter exits 2 (validate_ledger_shape admits any number)"
else
	fail "R11-F5c: non-integral loop_counter should exit 2 with empty stdout (rc=$flc_rc, out='$flc_out')"
fi

# CONTROL: cap/k are OPTIONAL by construction — the decoder reads them as
# `(.cap // "")` and falls back to the CLI-supplied, already-validated
# --cap/--k. An absent OR EXPLICITLY NULL cap/k must stay legal, or the
# tightened root gate would break every legacy ledger written before cap/k
# were persisted.
L_null_capk="$(
	handmade_ledger <<'EOF'
{
  "loop_counter": 1,
  "cap": null,
  "k": null,
  "rounds": [
    {
      "count": 0,
      "structural_tally": 0,
      "local_tally": 0,
      "pass_type": "full",
      "quarantine_size": 0,
      "unresolved_gates": 0
    }
  ]
}
EOF
)"
nck_rc=0
nck_out="$("$LEDGER_SCRIPT" --last-decision --ledger "$L_null_capk" 2>/dev/null)" || nck_rc=$?
assert_eq "$nck_out" "success" "R11-F5d/control: an explicit cap:null / k:null still falls back to the CLI values (-> success)"
assert_eq "$nck_rc" "5" "R11-F5d/control: ...and still exits 5 for a terminal token, not 2"

# --- R12 F-ledger-root: root fields are validated BEFORE the no-rounds ----
# short-circuit.
# decision_from_ledger returns `no-rounds` (exit 0) the moment
# `.rounds | length == 0`, BEFORE validate_ledger_fields runs. So the R11-F5
# root guard above — which lived only inside validate_ledger_fields — was
# unreachable on a round-less ledger: a fractional cap, a string k, or a
# negative loop_counter all reported `no-rounds` at exit 0 and the caller
# looped on against a cap that would crash on the first appended round.
# Root validation now runs at both entry points before the short-circuit.

# (a) --last-decision, round-less ledger, fractional cap -> exit 2.
L_rl_cap="$(
	handmade_ledger <<'EOF'
{
  "loop_counter": 0,
  "cap": 1.5,
  "k": 2,
  "rounds": []
}
EOF
)"
rlcap_rc=0
rlcap_out="$("$LEDGER_SCRIPT" --last-decision --ledger "$L_rl_cap" 2>/dev/null)" || rlcap_rc=$?
if [[ "$rlcap_rc" -eq 2 && -z "$rlcap_out" ]]; then
	pass "R12-root-a: a round-less ledger with a fractional cap exits 2, not no-rounds/exit 0"
else
	fail "R12-root-a: expected exit 2 with empty stdout (rc=$rlcap_rc, out='$rlcap_out')"
fi

# ...with the existing root-field diagnostic, not some new message.
rlcap_err="$("$LEDGER_SCRIPT" --last-decision --ledger "$L_rl_cap" 2>&1 >/dev/null || true)"
case "$rlcap_err" in
*"malformed root fields"*)
	pass "R12-root-a2: ...and emits the existing 'malformed root fields' diagnostic"
	;;
*)
	fail "R12-root-a2: expected the 'malformed root fields' diagnostic (got '$rlcap_err')"
	;;
esac

# (b) --last-decision, round-less ledger, non-numeric k -> exit 2.
L_rl_k="$(
	handmade_ledger <<'EOF'
{
  "loop_counter": 0,
  "cap": 10,
  "k": "abc",
  "rounds": []
}
EOF
)"
rlk_rc=0
rlk_out="$("$LEDGER_SCRIPT" --last-decision --ledger "$L_rl_k" 2>/dev/null)" || rlk_rc=$?
if [[ "$rlk_rc" -eq 2 && -z "$rlk_out" ]]; then
	pass "R12-root-b: a round-less ledger with a non-numeric k exits 2"
else
	fail "R12-root-b: expected exit 2 with empty stdout (rc=$rlk_rc, out='$rlk_out')"
fi

# (c) --last-decision, round-less ledger, negative loop_counter -> exit 2.
L_rl_lc="$(
	handmade_ledger <<'EOF'
{
  "loop_counter": -1,
  "cap": 10,
  "k": 2,
  "rounds": []
}
EOF
)"
rllc_rc=0
rllc_out="$("$LEDGER_SCRIPT" --last-decision --ledger "$L_rl_lc" 2>/dev/null)" || rllc_rc=$?
if [[ "$rllc_rc" -eq 2 && -z "$rllc_out" ]]; then
	pass "R12-root-c: a round-less ledger with a negative loop_counter exits 2"
else
	fail "R12-root-c: expected exit 2 with empty stdout (rc=$rllc_rc, out='$rllc_out')"
fi

# (d) APPEND against the same malformed round-less ledger also exits 2 --
# and does so BEFORE the write, so loop_counter is untouched and the bad
# `cap` is not carried forward by the has("cap") backfill.
L_rl_app="$(
	handmade_ledger <<'EOF'
{
  "loop_counter": 0,
  "cap": 1.5,
  "k": 2,
  "rounds": []
}
EOF
)"
rlapp_rc=0
"$LEDGER_SCRIPT" --ledger "$L_rl_app" --count 0 --structural 0 --local 0 \
	--pass-type full --quarantine 0 >/dev/null 2>&1 || rlapp_rc=$?
assert_eq "$rlapp_rc" "2" "R12-root-d: append onto a round-less ledger with a fractional cap exits 2"
assert_eq "$(jq -r '.loop_counter' "$L_rl_app")" "0" "R12-root-d2: ...and the refused append left loop_counter at 0"
assert_eq "$(jq -r '.rounds | length' "$L_rl_app")" "0" "R12-root-d3: ...and appended no round"

# (e) CONTROL: a well-formed round-less ledger still prints no-rounds at
# exit 0, and an explicit cap:null / k:null is still legitimate there.
L_rl_ok="$(
	handmade_ledger <<'EOF'
{
  "loop_counter": 0,
  "cap": null,
  "k": null,
  "rounds": []
}
EOF
)"
rlok_rc=0
rlok_out="$("$LEDGER_SCRIPT" --last-decision --ledger "$L_rl_ok" 2>/dev/null)" || rlok_rc=$?
assert_eq "$rlok_out" "no-rounds" "R12-root-e/control: a round-less ledger with cap:null/k:null still prints no-rounds"
assert_eq "$rlok_rc" "0" "R12-root-e2/control: ...and still exits 0"

# --- R12/F9: the round-append filter is a jq FILE, run directly -----------
# The pending_claims/fixed_keys promotion state machine used to be an inline
# single-quoted jq program inside the append call, which forced every
# apostrophe in its prose through the shell and made the comments unreadable
# exactly where the logic decides what counts as PROVEN FIXED. It now lives
# in lib/ledger-promote.jq, loaded with `jq -f`.
#
# The tests above already cover it through the CLI. THIS section runs the
# .jq file directly, with no shell in between, so a regression in the filter
# is attributed to the filter rather than to the caller -- the seam the F9
# deferral said extraction would not create.

PROMOTE_JQ="$ROOT_DIR/plugins/skein/skills/review-gauntlet/lib/ledger-promote.jq"

if [[ -f "$PROMOTE_JQ" ]]; then
	pass "R12-F9a: lib/ledger-promote.jq exists"
else
	fail "R12-F9a: lib/ledger-promote.jq is missing"
fi

# promote_direct <ledger-json> <pass_type> <unresolved> <present-json>
#                <claimed-json> <present_supplied> -> filtered ledger on stdout
promote_direct() {
	local ledger_json="$1" pass_type="$2" unresolved="$3"
	local present="$4" claimed="$5" present_supplied="$6"
	printf '%s' "$ledger_json" | jq \
		--argjson count 1 \
		--argjson structural 0 \
		--argjson local 0 \
		--arg pass_type "$pass_type" \
		--argjson quarantine 0 \
		--argjson unresolved "$unresolved" \
		--argjson cap 10 \
		--argjson k 2 \
		--argjson present_keys "$present" \
		--argjson claimed_keys "$claimed" \
		--argjson keys_active true \
		--argjson present_supplied "$present_supplied" \
		-f "$PROMOTE_JQ"
}

R12_BASE='{"cap":10,"k":2,"loop_counter":1,"fixed_keys":["old:1"],"pending_claims":["a:1","b:2"],"rounds":[]}'

# (b) PROMOTE: a full pass with evidence promotes the pending claim that is
# absent from present_keys, drops the one still present, and records the new
# claim.
r12b="$(promote_direct "$R12_BASE" full 0 '["b:2"]' '["c:3"]' true)"
assert_eq "$(printf '%s' "$r12b" | jq -c '.fixed_keys')" '["a:1","old:1"]' \
	"R12-F9b: a full pass with evidence promotes the absent claim into fixed_keys"
assert_eq "$(printf '%s' "$r12b" | jq -c '.pending_claims')" '["c:3"]' \
	"R12-F9b2: ...drops the still-present claim and records this round's claim"

# (c) NO-PROMOTE on a confirm pass: pending_claims is left exactly as it was
# (plus this round's new claim), fixed_keys untouched.
r12c="$(promote_direct "$R12_BASE" confirm 0 '["z:9"]' '["q:4"]' true)"
assert_eq "$(printf '%s' "$r12c" | jq -c '.fixed_keys')" '["old:1"]' \
	"R12-F9c: a confirm pass promotes nothing"
assert_eq "$(printf '%s' "$r12c" | jq -c '.pending_claims')" '["a:1","b:2","q:4"]' \
	"R12-F9c2: ...and drops nothing either"

# (d) NO-PROMOTE on a DEGRADED full pass (unresolved > 0) -- the gate did not
# review, so absence from present_keys is not evidence.
r12d="$(promote_direct "$R12_BASE" full 2 '[]' '[]' true)"
assert_eq "$(printf '%s' "$r12d" | jq -c '.fixed_keys')" '["old:1"]' \
	"R12-F9d: a degraded full pass (unresolved > 0) promotes nothing"
assert_eq "$(printf '%s' "$r12d" | jq -c '.pending_claims')" '["a:1","b:2"]' \
	"R12-F9d2: ...and leaves pending_claims intact"

# (e) NO-PROMOTE when the round supplied no --present-keys at all: an absent
# flag is not vacuous "present_keys == []" evidence (F1/F2).
r12e="$(promote_direct "$R12_BASE" full 0 '[]' '[]' false)"
assert_eq "$(printf '%s' "$r12e" | jq -c '.fixed_keys')" '["old:1"]' \
	"R12-F9e: a full pass that omits --present-keys promotes nothing"

# (f) Step 3 runs strictly AFTER step 2: a claim made THIS round is never
# evaluated by the round that made it, and an already-fixed key is not
# re-added as pending.
r12f="$(promote_direct "$R12_BASE" full 0 '["a:1","b:2"]' '["old:1","new:9"]' true)"
assert_eq "$(printf '%s' "$r12f" | jq -c '.pending_claims')" '["new:9"]' \
	"R12-F9f: a key already in fixed_keys is not re-recorded as a pending claim"

# (g) keys_active false leaves the ledger in the pre-Phase-3 shape: no
# fixed_keys, no pending_claims, and a six-field round.
r12g="$(printf '%s' '{"cap":10,"k":2,"loop_counter":1,"rounds":[]}' | jq \
	--argjson count 1 --argjson structural 0 --argjson local 0 \
	--arg pass_type full --argjson quarantine 0 --argjson unresolved 0 \
	--argjson cap 10 --argjson k 2 \
	--argjson present_keys '[]' --argjson claimed_keys '[]' \
	--argjson keys_active false --argjson present_supplied false \
	-f "$PROMOTE_JQ")"
assert_eq "$(printf '%s' "$r12g" | jq -c 'has("fixed_keys") or has("pending_claims")')" "false" \
	"R12-F9g: keys_active false adds no key-tracking fields"
assert_eq "$(printf '%s' "$r12g" | jq -c '.rounds[-1] | keys_unsorted | length')" "6" \
	"R12-F9g2: ...and the round keeps the pre-Phase-3 six-field shape"

# (h) Every argument is REQUIRED -- jq errors on an undefined $variable, so a
# caller that drops one fails loudly instead of writing a different ledger.
r12h_rc=0
printf '%s' "$R12_BASE" | jq --argjson count 1 -f "$PROMOTE_JQ" >/dev/null 2>&1 || r12h_rc=$?
if [[ "$r12h_rc" -ne 0 ]]; then
	pass "R12-F9h: omitting arguments is a hard jq error, not a silently different ledger"
else
	fail "R12-F9h: the filter ran with 11 of 12 arguments missing"
fi

# (i) The mirrors carry the same filter byte-for-byte -- a drifted copy would
# change what the Codex-side ledger treats as proven-fixed with no shell diff.
if cmp -s "$PROMOTE_JQ" "$ROOT_DIR/plugins/skein-codex/skills/review-gauntlet/lib/ledger-promote.jq"; then
	pass "R12-F9i: ledger-promote.jq is byte-identical across the Claude and Codex mirrors"
else
	fail "R12-F9i: ledger-promote.jq differs between plugins/skein and plugins/skein-codex"
fi

echo ""
echo "Results: $pass_count passed, $fail_count failed"

if [[ "$fail_count" -gt 0 ]]; then
	exit 1
fi

exit 0
