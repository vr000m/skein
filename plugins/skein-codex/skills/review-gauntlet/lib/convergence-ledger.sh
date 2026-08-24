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
#       --quarantine <N> [--unresolved <N>] [--cap 10] [--k 2] \
#       [--present-keys <file>] [--claimed-keys <file>]
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
#   continue | restart | confirm | success | success_with_quarantine
#       | regression | cap | non-converge
#
# --last-decision is read-only. It recomputes the token implied by the current
# on-disk ledger and exits 5 for terminal tokens so the conductor can refuse
# resume deterministically.
#
# --present-keys <file> and --claimed-keys <file> (both optional; a missing or
# malformed file is treated as an empty key list, never a crash — see
# read_keys_file below) feed the regression-loop stop condition:
#
#   --present-keys <file>  newline-separated regression keys (from the
#                           bundled scripts/finding-key.sh) observed in THIS
#                           round's reconciled findings. Persisted verbatim
#                           onto this round (`rounds[-1].present_keys`) so a
#                           later --last-decision peek can recompute the same
#                           regression check without re-deriving it.
#   --claimed-keys <file>  newline-separated regression keys the fixer
#                           subagent claims to have fixed THIS round (schema
#                           `{claimed:[key...]}` on the SKILL.md side; the
#                           caller extracts the array before writing the
#                           file). The ledger — never the caller — decides
#                           when a claimed key is actually promoted to
#                           `fixed_keys`: only when it is ALSO absent from
#                           THIS SAME round's `--present-keys`, on a
#                           `pass_type: full` round (a round already bundles
#                           "the gates re-ran after the fix" together with
#                           "the fixer's claim", so there is nothing to defer
#                           to a later round). A `pass_type: confirm` round
#                           never promotes, and a claimed key still present
#                           this same round is simply dropped — it never
#                           enters `fixed_keys` and there is no retry queue;
#                           the fixer must claim it again on a later round
#                           that actually shows it gone. `fixed_keys` is a
#                           cumulative, top-level, monotonically-growing set
#                           that survives a structural restart (nothing in
#                           this script ever removes from it short of
#                           `--init --force` starting a brand new ledger).
#
# `regression` fires whenever THIS round's `--present-keys` intersects the
# ledger's cumulative `fixed_keys` — on BOTH pass types (a previously-fixed
# bug reappearing during a confirm pass is exactly as much a regression as
# one reappearing on a full pass) — and is terminal, slotted in the decision
# priority chain immediately after `success`/`success_with_quarantine` and
# before `cap`. A ledger with neither flag ever supplied has `fixed_keys: []`
# and no round ever carries `present_keys`, so `regression` can never fire and
# every other decision is computed exactly as before these flags existed —
# the regression key machinery is additive, not a modification of the
# existing decision table.
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
              [--unresolved <N>] [--cap 10] [--k 2] \
              [--present-keys <file>] [--claimed-keys <file>]
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
PRESENT_KEYS_FILE=""
CLAIMED_KEYS_FILE=""

while [[ $# -gt 0 ]]; do
	case "$1" in
	--init)
		if [[ "$MODE" != "append" && "$MODE" != "init" ]]; then
			echo "convergence-ledger: --init cannot be combined with --last-decision" >&2
			usage
			exit 2
		fi
		MODE="init"
		;;
	--last-decision)
		if [[ "$MODE" != "append" && "$MODE" != "last-decision" ]]; then
			echo "convergence-ledger: --last-decision cannot be combined with --init" >&2
			usage
			exit 2
		fi
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
	--present-keys)
		shift
		[[ $# -gt 0 ]] || {
			usage
			exit 2
		}
		PRESENT_KEYS_FILE="$1"
		ROUND_ARG_SEEN=1
		;;
	--claimed-keys)
		shift
		[[ $# -gt 0 ]] || {
			usage
			exit 2
		}
		CLAIMED_KEYS_FILE="$1"
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

# read_keys_file <path> — echo a JSON array of newline-separated keys read
# from <path>. An empty/unset <path>, a missing file, or any unreadable/
# non-utf8 content all degrade to an empty array rather than a crash: this is
# the "malformed/missing --claimed-keys file -> defined behaviour, never a
# crash" contract. `jq -R -s` on raw text can only fail to produce the
# structure we want (never fails to parse — it treats its input as raw
# text), so the fallback branch below only guards the pathological case of
# `jq` itself being unable to run against the file (e.g. a directory path).
read_keys_file() {
	local path="$1"
	if [[ -z "$path" ]]; then
		printf '[]'
		return 0
	fi
	if [[ ! -f "$path" ]]; then
		echo "convergence-ledger: keys file not found: $path (treating as empty)" >&2
		printf '[]'
		return 0
	fi
	jq -R -s 'split("\n") | map(select(length > 0))' "$path" 2>/dev/null || printf '[]'
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

# validate_last_round_fields guards decision_from_ledger's bash arithmetic
# tests (`[[ "$x" -eq N ]]`) against a malformed on-disk ledger. --last-decision
# reads back arbitrary, possibly stale ledger state from a prior/interrupted
# session, a plugin upgrade, or a hand-edited file — validate_ledger_shape
# alone only checks the top-level {loop_counter, rounds} shape, not that the
# LAST round actually has numeric count/structural_tally/local_tally/
# quarantine_size or a valid pass_type. Without this check a null/missing
# field becomes the literal string "null", and bash's arithmetic evaluator
# aborts with an "unbound variable" crash instead of the documented exit-code
# contract. Only called once round_len > 0 is already established.
validate_last_round_fields() {
	local ledger_path="$1"
	if ! jq -e '
		.rounds[-1] as $r
		| ($r.count | type == "number")
		and ($r.structural_tally | type == "number")
		and ($r.local_tally | type == "number")
		and ($r.quarantine_size | type == "number")
		and ($r.pass_type == "full" or $r.pass_type == "confirm")
	' "$ledger_path" >/dev/null 2>&1; then
		echo "convergence-ledger: ledger at $ledger_path has a malformed last round (missing/invalid count, structural_tally, local_tally, quarantine_size, or pass_type)" >&2
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

# write_fresh_ledger writes via a temp file + atomic rename, matching the
# round-append path below — this is the one write meant to survive an
# interruption (it runs before a possibly-long, droppable loop even starts),
# so it must not leave a truncated/partial file at $ledger_path if killed
# mid-write. cap/k are persisted alongside target so a later --last-decision
# peek reads the SAME cap/k the run was created with, rather than falling
# back to this script's own (possibly different) --cap/--k defaults.
write_fresh_ledger() {
	local ledger_path="$1"
	local target="$2"
	local cap="$3"
	local k="$4"
	local tmp
	mkdir -p "$(dirname "$ledger_path")"
	tmp="$(mktemp)"
	# fixed_keys/pending_claimed are deliberately NOT written here: a ledger
	# that never sees --present-keys/--claimed-keys must stay byte-for-byte
	# identical to the pre-Phase-3 shape (no key-tracking pollution). Both
	# fields are added lazily, only once a round actually supplies one of
	# those flags — see the append-mode handler below.
	if [[ -n "$target" ]]; then
		jq -n --arg target "$target" --argjson cap "$cap" --argjson k "$k" \
			'{target: $target, cap: $cap, k: $k, loop_counter: 0, rounds: []}' >"$tmp"
	else
		jq -n --argjson cap "$cap" --argjson k "$k" \
			'{cap: $cap, k: $k, loop_counter: 0, rounds: []}' >"$tmp"
	fi
	mv "$tmp" "$ledger_path"
}

ensure_ledger_for_append() {
	if [[ -e "$LEDGER_PATH" ]]; then
		validate_ledger_shape "$LEDGER_PATH"
		check_target_match "$LEDGER_PATH" "$TARGET"
	else
		write_fresh_ledger "$LEDGER_PATH" "$TARGET" "$CAP" "$K"
	fi
}

# decision_from_ledger's cap/k args are CLI-supplied fallbacks only. Once a
# ledger has cap/k persisted (write_fresh_ledger and every append backfill
# them — see below), the LEDGER'S stored values are authoritative and win
# over whatever --cap/--k a given --last-decision/append call happens to
# pass, so a peek always resolves the terminal/non-terminal boundary the same
# way the run that produced the ledger did — not against this script's
# current defaults, which may differ (a version bump, an operator override
# on only one of the two calls, etc).
decision_from_ledger() {
	local ledger_path="$1"
	local cli_cap="$2"
	local cli_k="$3"
	local round_len loop_counter cap k count structural local_tally pass_type quarantine unresolved regression_hit

	round_len="$(jq -r '.rounds | length' "$ledger_path")"
	if [[ "$round_len" -eq 0 ]]; then
		echo "no-rounds"
		return 0
	fi

	validate_last_round_fields "$ledger_path"

	# One combined jq call for loop_counter, ledger-persisted cap/k, and every
	# field of the last round, instead of one jq subprocess per field.
	IFS=$'\t' read -r loop_counter cap k count structural local_tally pass_type quarantine unresolved < <(
		jq -r '
			[
				.loop_counter,
				(if has("cap") then .cap else "" end),
				(if has("k") then .k else "" end),
				.rounds[-1].count,
				.rounds[-1].structural_tally,
				.rounds[-1].local_tally,
				.rounds[-1].pass_type,
				.rounds[-1].quarantine_size,
				(.rounds[-1].unresolved_gates // 0)
			] | @tsv
		' "$ledger_path"
	)
	cap="${cap:-$cli_cap}"
	k="${k:-$cli_k}"

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

	# 2. Regression: THIS round's present_keys intersects the ledger's
	# cumulative fixed_keys — a previously-confirmed-fixed finding has
	# reappeared. Fires on BOTH pass types (full and confirm alike — a
	# reappearance during a confirm pass is exactly as much a regression);
	# promotion into fixed_keys itself only ever happens on a full pass (see
	# the append-mode handler below). A ledger where neither field was ever
	# populated (no --present-keys/--claimed-keys flag ever passed) has
	# fixed_keys == [] and every round's present_keys == [], so this check is
	# a no-op and every other decision below is unaffected.
	regression_hit="$(jq -r '
		(.fixed_keys // []) as $fixed
		| (.rounds[-1].present_keys // []) as $present
		| (([$present[] as $p | $fixed | index($p)] | map(select(. != null)) | length) > 0)
	' "$ledger_path")"
	if [[ "$regression_hit" == "true" ]]; then
		echo "regression"
		return 0
	fi

	# 3. Cap.
	if [[ "$loop_counter" -ge "$cap" ]]; then
		echo "cap"
		return 0
	fi

	# 4. Restart: any structural fix this round. Checked before non-convergence.
	if [[ "$structural" -gt 0 ]]; then
		echo "restart"
		return 0
	fi

	# 5. Non-convergence: running-minimum stall scoped to the current epoch.
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

	# 6. Confirm: only-local round with remaining findings.
	if [[ "$count" -gt 0 && "$structural" -eq 0 && "$local_tally" -gt 0 ]]; then
		echo "confirm"
		return 0
	fi

	# 7. Clean confirm pass is not terminal; return to the full loop.
	if [[ "$pass_type" == "confirm" && "$count" -eq 0 ]]; then
		echo "continue"
		return 0
	fi

	# 8. Otherwise, continue.
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
	write_fresh_ledger "$LEDGER_PATH" "$TARGET" "$CAP" "$K"
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
	success | success_with_quarantine | regression | cap | non-converge)
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

	present_keys_json="$(read_keys_file "$PRESENT_KEYS_FILE")"
	claimed_keys_json="$(read_keys_file "$CLAIMED_KEYS_FILE")"

	# keys_active gates EVERY bit of the regression-key machinery below,
	# including whether a round even GAINS a `present_keys` field: a ledger
	# that has never once seen --present-keys/--claimed-keys (this round OR
	# any prior round already on disk) must come out of this append
	# byte-for-byte identical to the pre-Phase-3 shape — no `fixed_keys`,
	# no `present_keys` anywhere. Once either flag is used for the first
	# time, the ledger switches into key-tracking mode for good (fixed_keys
	# persists across every later round, structural restarts included),
	# which is why "already has fixed_keys on disk" also counts as active
	# even on a round that itself supplies neither flag.
	keys_active="false"
	if [[ -n "$PRESENT_KEYS_FILE" || -n "$CLAIMED_KEYS_FILE" ]]; then
		keys_active="true"
	elif jq -e 'has("fixed_keys")' "$LEDGER_PATH" >/dev/null 2>&1; then
		keys_active="true"
	fi

	tmp_ledger="$(mktemp)"
	trap 'rm -f "$tmp_ledger"' EXIT
	jq \
		--argjson count "$COUNT" \
		--argjson structural "$STRUCTURAL" \
		--argjson local "$LOCAL" \
		--arg pass_type "$PASS_TYPE" \
		--argjson quarantine "$QUARANTINE" \
		--argjson unresolved "$UNRESOLVED" \
		--argjson cap "$CAP" \
		--argjson k "$K" \
		--argjson present_keys "$present_keys_json" \
		--argjson claimed_keys "$claimed_keys_json" \
		--argjson keys_active "$keys_active" \
		'.loop_counter += 1
		 | (if has("cap") then . else .cap = $cap end)
		 | (if has("k") then . else .k = $k end)
		 | (if $keys_active then
		      (if has("fixed_keys") then . else .fixed_keys = [] end)
		      # Promotion: a THIS-ROUND claimed key that is ALSO absent
		      # from THIS ROUND'"'"'S OWN present_keys, on a full pass,
		      # is proven fixed and promoted into the cumulative
		      # fixed_keys set right away — a round bundles "the gates
		      # ran again after the fix" and "the fixer'"'"'s claim" as
		      # one unit, so there is nothing to defer to a later round.
		      # Promotion is full-pass-only: a confirm-pass round never
		      # promotes (a clean confirm pass does not prove global
		      # convergence any more than it does for the plain
		      # success/cap/restart decisions above). A claimed key that
		      # is STILL present this round is simply dropped — it never
		      # enters fixed_keys and there is no retry queue; the fixer
		      # must claim it again on a later round that actually shows
		      # it gone.
		      | (if $pass_type == "full" then
		           ($claimed_keys - $present_keys) as $promoted
		           | .fixed_keys = ((.fixed_keys + $promoted) | unique)
		         else . end)
		    else . end)
		 | .rounds += [
		     (if $keys_active then
		        {
		          count: $count,
		          structural_tally: $structural,
		          local_tally: $local,
		          pass_type: $pass_type,
		          quarantine_size: $quarantine,
		          unresolved_gates: $unresolved,
		          present_keys: $present_keys
		        }
		      else
		        {
		          count: $count,
		          structural_tally: $structural,
		          local_tally: $local,
		          pass_type: $pass_type,
		          quarantine_size: $quarantine,
		          unresolved_gates: $unresolved
		        }
		      end)
		   ]' \
		"$LEDGER_PATH" >"$tmp_ledger"
	mv "$tmp_ledger" "$LEDGER_PATH"

	decision_from_ledger "$LEDGER_PATH" "$CAP" "$K"
	;;
*)
	echo "convergence-ledger: internal mode error: $MODE" >&2
	exit 2
	;;
esac
