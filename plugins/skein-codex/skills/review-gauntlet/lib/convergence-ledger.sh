#!/usr/bin/env bash
# convergence-ledger.sh — deterministic, pure convergence decision for the
# review-gauntlet conductor loop.
#
# Usage:
#   convergence-ledger.sh --ledger <path> --count <N> --structural <N> \
#       --local <N> --pass-type <full|confirm> --quarantine <N> \
#       [--cap 10] [--k 2]
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
#   1. clean full pass      — pass_type=full && count=0
#                              -> success_with_quarantine (quarantine>0) else success
#   2. cap                  — loop_counter >= cap (default 10)
#   3. non-converge         — reconciled count has not strictly decreased
#                              over a K-round lookback (default K=2): the
#                              current round's count is compared to the
#                              count from K rounds earlier; a non-decrease
#                              (>=) over that window fires non-converge.
#                              This is a window comparison, not K
#                              consecutive single-round deltas — it is the
#                              only definition that classifies BOTH a
#                              plateau (3,3,3) AND a pure oscillation
#                              (5,3,5,3) as non-converge, since an
#                              oscillation never has two consecutive
#                              non-decreasing single-round deltas but does
#                              fail to make net progress over a 2-round
#                              window. Needs >= K+1 recorded rounds before
#                              it can fire.
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
           [--cap 10] [--k 2]
EOF
}

LEDGER_PATH=""
COUNT=""
STRUCTURAL=""
LOCAL=""
PASS_TYPE=""
QUARANTINE=""
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
jq \
	--argjson count "$COUNT" \
	--argjson structural "$STRUCTURAL" \
	--argjson local "$LOCAL" \
	--arg pass_type "$PASS_TYPE" \
	--argjson quarantine "$QUARANTINE" \
	'.loop_counter += 1
	 | .rounds += [{
		 count: $count,
		 structural_tally: $structural,
		 local_tally: $local,
		 pass_type: $pass_type,
		 quarantine_size: $quarantine
	 }]' \
	"$LEDGER_PATH" >"$tmp_ledger"
mv "$tmp_ledger" "$LEDGER_PATH"

loop_counter="$(jq -r '.loop_counter' "$LEDGER_PATH")"
rounds_len="$(jq -r '.rounds | length' "$LEDGER_PATH")"

# 1. Clean full pass -> success / success_with_quarantine.
if [[ "$PASS_TYPE" == "full" && "$COUNT" -eq 0 ]]; then
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

# 3. Non-convergence: K-round lookback window. Compare the current round's
# count to the count from K rounds earlier; a non-decrease (>=) over that
# window means no net progress was made across the window, regardless of
# any single-round zig-zag inside it. Requires at least K+1 recorded
# rounds (an earlier round K steps back must exist).
if [[ "$rounds_len" -ge $((K + 1)) ]]; then
	non_decrease="$(jq -r --argjson k "$K" '
		.rounds as $r
		| ($r | length) as $n
		| ($r[$n - 1].count >= $r[$n - 1 - $k].count)
	' "$LEDGER_PATH")"
	if [[ "$non_decrease" == "true" ]]; then
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
