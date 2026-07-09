#!/usr/bin/env bash
# convergence-ledger.sh — deterministic, pure convergence decision for the
# review-gauntlet conductor loop.
#
# Usage:
#   convergence-ledger.sh --ledger <path> --count <N> --structural <N> \
#       --local <N> --pass-type <full|confirm> --quarantine <N> \
#       [--unresolved <N>] [--cap 10] [--k 2]
#
# --unresolved <N> is the number of gates that returned a non-clean status
# (error|skipped|deferred) this round — run-gate.sh signals each such gate by
# exiting 4, and the conductor tallies them. A round with any unresolved gate
# is NOT a clean pass even when the reconciled count reached 0, because a gate
# that errored never actually reviewed the diff. Default 0.
#
# Records exactly one round into the persistent JSON ledger at <path>
# (created if absent: `{"loop_counter": 0, "rounds": []}`), appends the
# round's fields to `rounds`, increments `loop_counter` by 1 (every round
# increments, including gate-1 structural restarts — the counter never
# resets), then prints exactly one decision token to stdout:
#
#   continue | restart | confirm | success | success_with_quarantine | cap | non-converge
#
# Decision precedence (first match wins):
#   1. clean full pass      — pass_type=full && count=0 && unresolved=0
#                              -> success_with_quarantine (quarantine>0) else success.
#                              An unresolved gate (unresolved>0) blocks this
#                              rule even at count=0 — the round falls through
#                              to `continue` so the errored gate re-runs.
#   2. cap                  — loop_counter >= cap (default 10)
#   3. non-converge         — the reconciled count has failed to reach a new
#                              running minimum for K (default 2) consecutive
#                              rounds. Per round, track the minimum count seen
#                              so far; a round whose count is strictly below
#                              that running minimum resets the stall streak to
#                              0, otherwise the streak increments. A stall
#                              streak >= K fires non-converge. This classifies
#                              a plateau (3,3,3) and a sustained oscillation
#                              (5,3,5,3) as non-converge, but — unlike a raw
#                              K-round window comparison — does NOT bail on a
#                              genuinely converging run with a transient blip
#                              (5,4,5,3,2,1: the running minimum keeps
#                              improving, so the streak never reaches K). Needs
#                              >= K+1 recorded rounds before it can fire (the
#                              first round is always a new minimum).
#   4. restart              — structural_tally > 0
#   5. confirm              — count>0 && structural_tally=0 && local_tally>0
#   6. clean confirm pass   — pass_type=confirm && count=0 -> continue (NOT
#                              terminal; a clean confirm returns to the loop)
#   7. otherwise            — continue
#
# Same ledger + same inputs -> same token (pure function of ledger state).
#
# Dependencies: bash + jq.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugins/skein/skills/review-gauntlet/lib/gauntlet-common.sh disable=SC1091
. "$SCRIPT_DIR/gauntlet-common.sh"

usage() {
	cat >&2 <<'EOF'
usage: convergence-ledger.sh --ledger <path> --count <N> --structural <N> \
           --local <N> --pass-type <full|confirm> --quarantine <N> \
           [--unresolved <N>] [--cap 10] [--k 2]
EOF
}

LEDGER_PATH=""
COUNT=""
STRUCTURAL=""
LOCAL=""
PASS_TYPE=""
QUARANTINE=""
UNRESOLVED=0
CAP=10
K=2

while [[ $# -gt 0 ]]; do
	case "$1" in
	--ledger)
		shift
		[[ $# -gt 0 ]] || {
			usage
			exit 2
		}
		LEDGER_PATH="$1"
		;;
	--count)
		shift
		[[ $# -gt 0 ]] || {
			usage
			exit 2
		}
		COUNT="$1"
		;;
	--structural)
		shift
		[[ $# -gt 0 ]] || {
			usage
			exit 2
		}
		STRUCTURAL="$1"
		;;
	--local)
		shift
		[[ $# -gt 0 ]] || {
			usage
			exit 2
		}
		LOCAL="$1"
		;;
	--pass-type)
		shift
		[[ $# -gt 0 ]] || {
			usage
			exit 2
		}
		PASS_TYPE="$1"
		;;
	--quarantine)
		shift
		[[ $# -gt 0 ]] || {
			usage
			exit 2
		}
		QUARANTINE="$1"
		;;
	--unresolved)
		shift
		[[ $# -gt 0 ]] || {
			usage
			exit 2
		}
		UNRESOLVED="$1"
		;;
	--cap)
		shift
		[[ $# -gt 0 ]] || {
			usage
			exit 2
		}
		CAP="$1"
		;;
	--k)
		shift
		[[ $# -gt 0 ]] || {
			usage
			exit 2
		}
		K="$1"
		;;
	--help | -h)
		usage
		exit 0
		;;
	*)
		echo "convergence-ledger: unknown argument: $1" >&2
		usage
		exit 2
		;;
	esac
	shift
done

is_nonneg_int() {
	[[ "$1" =~ ^[0-9]+$ ]]
}

if [[ -z "$LEDGER_PATH" ]]; then
	echo "convergence-ledger: --ledger <path> is required" >&2
	exit 2
fi
if [[ -z "$COUNT" ]] || ! is_nonneg_int "$COUNT"; then
	echo "convergence-ledger: --count must be a non-negative integer (got '${COUNT}')" >&2
	exit 2
fi
if [[ -z "$STRUCTURAL" ]] || ! is_nonneg_int "$STRUCTURAL"; then
	echo "convergence-ledger: --structural must be a non-negative integer (got '${STRUCTURAL}')" >&2
	exit 2
fi
if [[ -z "$LOCAL" ]] || ! is_nonneg_int "$LOCAL"; then
	echo "convergence-ledger: --local must be a non-negative integer (got '${LOCAL}')" >&2
	exit 2
fi
if [[ "$PASS_TYPE" != "full" && "$PASS_TYPE" != "confirm" ]]; then
	echo "convergence-ledger: --pass-type must be 'full' or 'confirm' (got '${PASS_TYPE}')" >&2
	exit 2
fi
if [[ -z "$QUARANTINE" ]] || ! is_nonneg_int "$QUARANTINE"; then
	echo "convergence-ledger: --quarantine must be a non-negative integer (got '${QUARANTINE}')" >&2
	exit 2
fi
if [[ -z "$UNRESOLVED" ]] || ! is_nonneg_int "$UNRESOLVED"; then
	echo "convergence-ledger: --unresolved must be a non-negative integer (got '${UNRESOLVED}')" >&2
	exit 2
fi
if ! is_nonneg_int "$CAP" || [[ "$CAP" -eq 0 ]]; then
	echo "convergence-ledger: --cap must be a positive integer (got '${CAP}')" >&2
	exit 2
fi
if ! is_nonneg_int "$K" || [[ "$K" -eq 0 ]]; then
	echo "convergence-ledger: --k must be a positive integer (got '${K}')" >&2
	exit 2
fi

gc_have_jq

if [[ -e "$LEDGER_PATH" ]]; then
	if ! jq -e 'has("loop_counter") and has("rounds")' "$LEDGER_PATH" >/dev/null 2>&1; then
		echo "convergence-ledger: ledger at $LEDGER_PATH is not a valid gauntlet ledger (expected {loop_counter, rounds})" >&2
		exit 2
	fi
else
	mkdir -p "$(dirname "$LEDGER_PATH")"
	printf '{"loop_counter": 0, "rounds": []}\n' >"$LEDGER_PATH"
fi

# Append this round and bump the monotonic loop counter. Every invocation
# records exactly one round, including a gate-1 structural restart — the
# counter never resets.
tmp_ledger="$(mktemp)"
# Remove the temp ledger if we abort before the mv (e.g. jq fails under
# `set -e`); the successful mv renames it away so the rm is a no-op then.
trap 'rm -f "$tmp_ledger"' EXIT
jq \
	--argjson count "$COUNT" \
	--argjson structural "$STRUCTURAL" \
	--argjson local "$LOCAL" \
	--arg pass_type "$PASS_TYPE" \
	--argjson quarantine "$QUARANTINE" \
	--argjson unresolved "$UNRESOLVED" \
	'.loop_counter += 1
	 | .rounds += [{
		 count: $count,
		 structural_tally: $structural,
		 local_tally: $local,
		 pass_type: $pass_type,
		 quarantine_size: $quarantine,
		 unresolved_gates: $unresolved
	 }]' \
	"$LEDGER_PATH" >"$tmp_ledger"
mv "$tmp_ledger" "$LEDGER_PATH"

loop_counter="$(jq -r '.loop_counter' "$LEDGER_PATH")"
rounds_len="$(jq -r '.rounds | length' "$LEDGER_PATH")"

# 1. Clean full pass -> success / success_with_quarantine. An unresolved gate
# (error/skipped/deferred this round) blocks a clean pass even at count=0: the
# gate never actually reviewed the diff, so the round falls through to
# `continue` and the conductor re-runs it.
if [[ "$PASS_TYPE" == "full" && "$COUNT" -eq 0 && "$UNRESOLVED" -eq 0 ]]; then
	if [[ "$QUARANTINE" -gt 0 ]]; then
		echo "success_with_quarantine"
	else
		echo "success"
	fi
	exit 0
fi

# 2. Cap.
if [[ "$loop_counter" -ge "$CAP" ]]; then
	echo "cap"
	exit 0
fi

# 3. Non-convergence: running-minimum stall. Walk the rounds tracking the
# minimum count seen so far; a round whose count is strictly below that
# running minimum resets the stall streak to 0, otherwise the streak
# increments. A trailing stall streak >= K means the count has failed to
# reach a new best for K consecutive rounds — a plateau or a sustained
# oscillation — without false-positive-bailing on a converging run that has a
# transient blip (the running minimum keeps improving). The first round is
# always a new minimum, so the streak can only reach K after >= K+1 rounds.
if [[ "$rounds_len" -ge $((K + 1)) ]]; then
	stall_streak="$(jq -r '
		.rounds
		| reduce .[] as $round ({min: null, streak: 0};
			if (.min == null) or ($round.count < .min)
			then {min: $round.count, streak: 0}
			else {min: .min, streak: (.streak + 1)}
			end)
		| .streak
	' "$LEDGER_PATH")"
	if [[ "$stall_streak" -ge "$K" ]]; then
		echo "non-converge"
		exit 0
	fi
fi

# 4. Restart: any structural fix this round.
if [[ "$STRUCTURAL" -gt 0 ]]; then
	echo "restart"
	exit 0
fi

# 5. Confirm: only-local round with remaining findings.
if [[ "$COUNT" -gt 0 && "$STRUCTURAL" -eq 0 && "$LOCAL" -gt 0 ]]; then
	echo "confirm"
	exit 0
fi

# 6. Clean confirm pass is NOT terminal — return to the loop for a fresh
# full pass.
if [[ "$PASS_TYPE" == "confirm" && "$COUNT" -eq 0 ]]; then
	echo "continue"
	exit 0
fi

# 7. Otherwise, continue.
echo "continue"
