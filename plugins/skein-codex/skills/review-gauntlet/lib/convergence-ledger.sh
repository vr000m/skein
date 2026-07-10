#!/usr/bin/env bash
# convergence-ledger.sh - deterministic convergence decision and persistence
# for the review-gauntlet conductor loop.
#
# Usage:
#   convergence-ledger.sh --init --ledger <path> --target <target> [--force]
#   convergence-ledger.sh --last-decision --ledger <path> [--target <target>] \
#       [--cap 10] [--k 2]
#   convergence-ledger.sh --ledger <path> [--target <target>] --count <N> \
#       --structural <N> --local <N> --pass-type <full|confirm> \
#       --quarantine <N> [--unresolved <N>] [--cap 10] [--k 2]
#
# Exit codes:
#   0 - success / non-terminal decision
#   2 - usage error or malformed ledger
#   3 - target mismatch
#   4 - --last-decision ledger not found
#   5 - --last-decision reached a terminal decision
#   6 - --init refused to overwrite an existing ledger
#
# The append mode records exactly one round into the persistent JSON ledger at
# <path>, increments loop_counter by 1, then prints exactly one decision token:
#
#   continue | restart | confirm | success | success_with_quarantine | cap | non-converge
#
# --last-decision is read-only. It recomputes the token implied by the current
# on-disk ledger and exits 5 for terminal tokens so the conductor can refuse
# resume deterministically.
#
# Dependencies: bash + jq + shasum|sha1sum (via gauntlet-common.sh).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugins/skein/skills/review-gauntlet/lib/gauntlet-common.sh disable=SC1091
. "$SCRIPT_DIR/gauntlet-common.sh"

usage() {
	cat >&2 <<'EOF'
usage: convergence-ledger.sh --init --ledger <path> --target <target> [--force]
       convergence-ledger.sh --last-decision --ledger <path> [--target <target>] [--cap 10] [--k 2]
       convergence-ledger.sh --ledger <path> [--target <target>] --count <N> --structural <N> \
              --local <N> --pass-type <full|confirm> --quarantine <N> \
              [--unresolved <N>] [--cap 10] [--k 2]
EOF
}

LEDGER_PATH=""
TARGET=""
COUNT=""
STRUCTURAL=""
LOCAL=""
PASS_TYPE=""
QUARANTINE=""
UNRESOLVED=0
CAP=10
K=2
MODE="append"
FORCE=0
ROUND_ARG_SEEN=0

while [[ $# -gt 0 ]]; do
	case "$1" in
	--init)
		MODE="init"
		;;
	--last-decision)
		MODE="last-decision"
		;;
	--force)
		FORCE=1
		;;
	--ledger)
		shift
		[[ $# -gt 0 ]] || {
			usage
			exit 2
		}
		LEDGER_PATH="$1"
		;;
	--target)
		shift
		[[ $# -gt 0 ]] || {
			usage
			exit 2
		}
		TARGET="$1"
		;;
	--count)
		shift
		[[ $# -gt 0 ]] || {
			usage
			exit 2
		}
		COUNT="$1"
		ROUND_ARG_SEEN=1
		;;
	--structural)
		shift
		[[ $# -gt 0 ]] || {
			usage
			exit 2
		}
		STRUCTURAL="$1"
		ROUND_ARG_SEEN=1
		;;
	--local)
		shift
		[[ $# -gt 0 ]] || {
			usage
			exit 2
		}
		LOCAL="$1"
		ROUND_ARG_SEEN=1
		;;
	--pass-type)
		shift
		[[ $# -gt 0 ]] || {
			usage
			exit 2
		}
		PASS_TYPE="$1"
		ROUND_ARG_SEEN=1
		;;
	--quarantine)
		shift
		[[ $# -gt 0 ]] || {
			usage
			exit 2
		}
		QUARANTINE="$1"
		ROUND_ARG_SEEN=1
		;;
	--unresolved)
		shift
		[[ $# -gt 0 ]] || {
			usage
			exit 2
		}
		UNRESOLVED="$1"
		ROUND_ARG_SEEN=1
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

validate_common_args() {
	if [[ -z "$LEDGER_PATH" ]]; then
		echo "convergence-ledger: --ledger <path> is required" >&2
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
}

validate_append_args() {
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
}

validate_ledger_shape() {
	local ledger_path="$1"
	if ! jq -e 'has("loop_counter") and (.loop_counter | type == "number") and has("rounds") and (.rounds | type == "array")' "$ledger_path" >/dev/null 2>&1; then
		echo "convergence-ledger: ledger at $ledger_path is not a valid gauntlet ledger (expected {loop_counter, rounds})" >&2
		exit 2
	fi
}

check_target_match() {
	local ledger_path="$1"
	local target="$2"
	local existing
	[[ -n "$target" ]] || return 0
	existing="$(jq -r 'if has("target") and (.target != null) then .target else empty end' "$ledger_path")"
	if [[ -n "$existing" && "$existing" != "$target" ]]; then
		echo "convergence-ledger: target mismatch for $ledger_path (ledger has '$existing', got '$target')" >&2
		exit 3
	fi
}

write_fresh_ledger() {
	local ledger_path="$1"
	local target="$2"
	mkdir -p "$(dirname "$ledger_path")"
	jq -n --arg target "$target" '{target: $target, loop_counter: 0, rounds: []}' >"$ledger_path"
}

ensure_ledger_for_append() {
	if [[ -e "$LEDGER_PATH" ]]; then
		validate_ledger_shape "$LEDGER_PATH"
		check_target_match "$LEDGER_PATH" "$TARGET"
	else
		mkdir -p "$(dirname "$LEDGER_PATH")"
		if [[ -n "$TARGET" ]]; then
			jq -n --arg target "$TARGET" '{target: $target, loop_counter: 0, rounds: []}' >"$LEDGER_PATH"
		else
			printf '{"loop_counter": 0, "rounds": []}\n' >"$LEDGER_PATH"
		fi
	fi
}

last_round_field() {
	local ledger_path="$1"
	local field="$2"
	jq -r --arg field "$field" '.rounds[-1][$field]' "$ledger_path"
}

decision_from_ledger() {
	local ledger_path="$1"
	local cap="$2"
	local k="$3"
	local round_len loop_counter count structural local_tally pass_type quarantine unresolved

	round_len="$(jq -r '.rounds | length' "$ledger_path")"
	if [[ "$round_len" -eq 0 ]]; then
		echo "no-rounds"
		return 0
	fi

	loop_counter="$(jq -r '.loop_counter' "$ledger_path")"
	count="$(last_round_field "$ledger_path" count)"
	structural="$(last_round_field "$ledger_path" structural_tally)"
	local_tally="$(last_round_field "$ledger_path" local_tally)"
	pass_type="$(last_round_field "$ledger_path" pass_type)"
	quarantine="$(last_round_field "$ledger_path" quarantine_size)"
	unresolved="$(jq -r '.rounds[-1].unresolved_gates // 0' "$ledger_path")"

	# 1. Clean full pass -> success / success_with_quarantine. An unresolved gate
	# blocks a clean pass even at count=0 because the gate did not review.
	if [[ "$pass_type" == "full" && "$count" -eq 0 && "$unresolved" -eq 0 ]]; then
		if [[ "$quarantine" -gt 0 ]]; then
			echo "success_with_quarantine"
		else
			echo "success"
		fi
		return 0
	fi

	# 2. Cap.
	if [[ "$loop_counter" -ge "$cap" ]]; then
		echo "cap"
		return 0
	fi

	# 3. Restart: any structural fix this round. Checked before non-convergence.
	if [[ "$structural" -gt 0 ]]; then
		echo "restart"
		return 0
	fi

	# 4. Non-convergence: running-minimum stall scoped to the current epoch.
	epoch_stats="$(jq -c '
		(.rounds | to_entries | map(select(.value.structural_tally > 0)) | last | .key) as $restart_idx
		| (if $restart_idx == null then .rounds else .rounds[($restart_idx + 1):] end) as $epoch
		| {
			epoch_len: ($epoch | length),
			streak: ($epoch
				| reduce .[] as $round ({min: null, streak: 0};
					if (.min == null) or ($round.count < .min)
					then {min: $round.count, streak: 0}
					else {min: .min, streak: (.streak + 1)}
					end)
				| .streak)
		}
	' "$ledger_path")"
	epoch_len="$(printf '%s' "$epoch_stats" | jq -r '.epoch_len')"
	if [[ "$epoch_len" -ge $((k + 1)) ]]; then
		stall_streak="$(printf '%s' "$epoch_stats" | jq -r '.streak')"
		if [[ "$stall_streak" -ge "$k" ]]; then
			echo "non-converge"
			return 0
		fi
	fi

	# 5. Confirm: only-local round with remaining findings.
	if [[ "$count" -gt 0 && "$structural" -eq 0 && "$local_tally" -gt 0 ]]; then
		echo "confirm"
		return 0
	fi

	# 6. Clean confirm pass is not terminal; return to the full loop.
	if [[ "$pass_type" == "confirm" && "$count" -eq 0 ]]; then
		echo "continue"
		return 0
	fi

	# 7. Otherwise, continue.
	echo "continue"
}

validate_common_args
gc_have_jq

case "$MODE" in
init)
	if [[ -z "$TARGET" ]]; then
		echo "convergence-ledger: --init requires --target <target>" >&2
		exit 2
	fi
	if [[ "$ROUND_ARG_SEEN" -eq 1 ]]; then
		echo "convergence-ledger: --init cannot be combined with round-input flags" >&2
		exit 2
	fi
	if [[ -e "$LEDGER_PATH" && "$FORCE" -eq 0 ]]; then
		echo "convergence-ledger: ledger already exists at $LEDGER_PATH; pass --force to discard it" >&2
		exit 6
	fi
	write_fresh_ledger "$LEDGER_PATH" "$TARGET"
	;;
last-decision)
	if [[ "$FORCE" -eq 1 ]]; then
		echo "convergence-ledger: --force is only valid with --init" >&2
		exit 2
	fi
	if [[ "$ROUND_ARG_SEEN" -eq 1 ]]; then
		echo "convergence-ledger: --last-decision cannot be combined with round-input flags" >&2
		exit 2
	fi
	if [[ ! -e "$LEDGER_PATH" ]]; then
		echo "convergence-ledger: ledger not found at $LEDGER_PATH" >&2
		exit 4
	fi
	validate_ledger_shape "$LEDGER_PATH"
	check_target_match "$LEDGER_PATH" "$TARGET"
	decision="$(decision_from_ledger "$LEDGER_PATH" "$CAP" "$K")"
	echo "$decision"
	case "$decision" in
	success | success_with_quarantine | cap | non-converge)
		exit 5
		;;
	*)
		exit 0
		;;
	esac
	;;
append)
	if [[ "$FORCE" -eq 1 ]]; then
		echo "convergence-ledger: --force is only valid with --init" >&2
		exit 2
	fi
	validate_append_args
	ensure_ledger_for_append

	tmp_ledger="$(mktemp)"
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

	decision_from_ledger "$LEDGER_PATH" "$CAP" "$K"
	;;
*)
	echo "convergence-ledger: internal mode error: $MODE" >&2
	exit 2
	;;
esac
