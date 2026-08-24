#!/usr/bin/env bash
# persist-lens-result.sh — append one typed JSONL line recording a
# deep-review or review-plan lens subagent's progress, streamed to disk AS
# THE LENS WORKS rather than only once it returns. This is the writer half
# of Phase 2's disk-first design (plan
# docs/dev_plans/20260823-feature-review-skills-resilience.md, R3/R4): a
# silent lens (never returns through the Agent mailbox) still leaves a
# partial record on disk that `collect-lens-results.sh` can read and the
# orchestrator can respawn against.
#
# Usage:
#   scripts/persist-lens-result.sh --root <repo-root> --skill deep-review|review-plan \
#       --run-id <id> --lens <name> --attempt <n> --type start|progress|finding|done \
#       [--units <comma,separated,list>] [--unit <name>] \
#       [--status completed|errored|skipped] \
#       [--severity Critical|Important|Minor] [--category <name>] \
#       [--location <file:line>] [--summary <text>] [--evidence <text>] \
#       [--suggestion <text>]
#
# Appends exactly one JSON line to:
#   <root>/<state-dir>/lenses/<run-id>/<lens>.<attempt>.jsonl
# where <state-dir> is `.deep-review` for --skill deep-review and
# `.review-plan` for --skill review-plan (see
# scripts/lib/persist-common.sh's persist_lens_state_dir).
#
# --root is REQUIRED and used exactly as given — never derived from the
# current working directory. The lens subagent's cwd at spawn time is not
# guaranteed to be the repo root, so the orchestrator resolves the absolute
# root once and bakes it into the persist-lens-result.sh invocation it
# hands the lens in its prompt preamble.
#
# One writer per file: every attempt (`--attempt N`) gets its own file, so
# there is no cross-writer atomicity concern here — no `flock`, no
# temp-file-then-rename. A plain append (`persist_jsonl_append`) is
# sufficient and is what keeps a killed-mid-write lens's last line
# recoverable as "ignore the truncated trailing line" rather than "lost the
# whole file" (see collect-lens-results.sh).
#
# Per-`--type` required fields (validated BEFORE any directory is created or
# any byte is written — a missing/unknown flag combination writes nothing):
#   start    — requires --units (may be an empty string for zero assigned
#              units, but the flag itself must be passed).
#   progress — requires --unit.
#   finding  — requires --severity, --category, --location, --summary.
#              --evidence/--suggestion are optional (default to "").
#   done     — requires --status, one of completed|errored|skipped. (This is
#              the writer-side enum; "timed_out"/"partial"/"missing" are
#              collector-derived and are never a --status value here — see
#              collect-lens-results.sh header.)
#
# Every line additionally carries `type`, `run_id`, `lens`, `attempt`
# (number), and `ts` (unix epoch seconds) so a line is self-describing even
# read in isolation from its filename.
#
# Exit codes:
#   0 — line appended.
#   2 — usage error (missing/unknown --skill, --type, or --status; a
#       required --type-specific flag missing; non-positive --attempt).
#       No file is written.
#   1 — best-effort append failed (permissions, disk full, etc).
#
# Dependencies: jq.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/persist-common.sh disable=SC1091
. "$SCRIPT_DIR/lib/persist-common.sh"

usage() {
	cat >&2 <<'EOF'
usage: scripts/persist-lens-result.sh --root <repo-root> --skill deep-review|review-plan \
    --run-id <id> --lens <name> --attempt <n> --type start|progress|finding|done \
    [--units <csv>] [--unit <name>] [--status completed|errored|skipped] \
    [--severity <s>] [--category <c>] [--location <file:line>] \
    [--summary <text>] [--evidence <text>] [--suggestion <text>]
EOF
}

ROOT=""
SKILL=""
RUN_ID=""
LENS=""
ATTEMPT=""
TYPE=""
UNITS=""
UNITS_SET=0
UNIT=""
STATUS=""
SEVERITY=""
CATEGORY=""
LOCATION=""
SUMMARY=""
EVIDENCE=""
SUGGESTION=""

require_value() {
	if [[ $# -lt 1 ]]; then
		usage
		exit 2
	fi
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--root)
		shift
		require_value "$@"
		ROOT="$1"
		;;
	--skill)
		shift
		require_value "$@"
		SKILL="$1"
		;;
	--run-id)
		shift
		require_value "$@"
		RUN_ID="$1"
		;;
	--lens)
		shift
		require_value "$@"
		LENS="$1"
		;;
	--attempt)
		shift
		require_value "$@"
		ATTEMPT="$1"
		;;
	--type)
		shift
		require_value "$@"
		TYPE="$1"
		;;
	--units)
		shift
		require_value "$@"
		UNITS="$1"
		UNITS_SET=1
		;;
	--unit)
		shift
		require_value "$@"
		UNIT="$1"
		;;
	--status)
		shift
		require_value "$@"
		STATUS="$1"
		;;
	--severity)
		shift
		require_value "$@"
		SEVERITY="$1"
		;;
	--category)
		shift
		require_value "$@"
		CATEGORY="$1"
		;;
	--location)
		shift
		require_value "$@"
		LOCATION="$1"
		;;
	--summary)
		shift
		require_value "$@"
		SUMMARY="$1"
		;;
	--evidence)
		shift
		require_value "$@"
		EVIDENCE="$1"
		;;
	--suggestion)
		shift
		require_value "$@"
		SUGGESTION="$1"
		;;
	--help | -h)
		usage
		exit 0
		;;
	*)
		echo "persist-lens-result: unrecognised argument: $1" >&2
		usage
		exit 2
		;;
	esac
	shift
done

if [[ -z "$ROOT" ]]; then
	echo "persist-lens-result: --root is required" >&2
	usage
	exit 2
fi

case "$SKILL" in
deep-review | review-plan) ;;
*)
	echo "persist-lens-result: --skill must be deep-review or review-plan" >&2
	usage
	exit 2
	;;
esac

if [[ -z "$RUN_ID" || -z "$LENS" ]]; then
	echo "persist-lens-result: --run-id and --lens are required" >&2
	usage
	exit 2
fi

if [[ ! "$ATTEMPT" =~ ^[0-9]+$ ]] || ((10#$ATTEMPT < 1)); then
	echo "persist-lens-result: --attempt must be a positive integer (got '${ATTEMPT:-<missing>}')" >&2
	usage
	exit 2
fi

case "$TYPE" in
start | progress | finding | done) ;;
*)
	echo "persist-lens-result: --type must be one of start|progress|finding|done (got '${TYPE:-<missing>}')" >&2
	usage
	exit 2
	;;
esac

if ! command -v jq >/dev/null 2>&1; then
	echo "persist-lens-result: jq is required" >&2
	exit 2
fi

case "$TYPE" in
start)
	if [[ "$UNITS_SET" -ne 1 ]]; then
		echo "persist-lens-result: --type start requires --units (pass an empty string for zero assigned units)" >&2
		usage
		exit 2
	fi
	;;
progress)
	if [[ -z "$UNIT" ]]; then
		echo "persist-lens-result: --type progress requires --unit" >&2
		usage
		exit 2
	fi
	;;
finding)
	if [[ -z "$SEVERITY" || -z "$CATEGORY" || -z "$LOCATION" || -z "$SUMMARY" ]]; then
		echo "persist-lens-result: --type finding requires --severity, --category, --location, and --summary" >&2
		usage
		exit 2
	fi
	;;
done)
	case "$STATUS" in
	completed | errored | skipped) ;;
	*)
		echo "persist-lens-result: --type done requires --status one of completed|errored|skipped (got '${STATUS:-<missing>}')" >&2
		usage
		exit 2
		;;
	esac
	;;
esac

ts="$(date +%s)"

units_json="[]"
if [[ "$TYPE" == "start" ]]; then
	if [[ -z "$UNITS" ]]; then
		units_json="[]"
	else
		units_json="$(printf '%s' "$UNITS" | jq -R -c 'split(",")')"
	fi
fi

line="$(jq -n -c \
	--arg type "$TYPE" \
	--arg run_id "$RUN_ID" \
	--arg lens "$LENS" \
	--argjson attempt "$ATTEMPT" \
	--argjson ts "$ts" \
	--argjson units "$units_json" \
	--arg unit "$UNIT" \
	--arg status "$STATUS" \
	--arg severity "$SEVERITY" \
	--arg category "$CATEGORY" \
	--arg location "$LOCATION" \
	--arg summary "$SUMMARY" \
	--arg evidence "$EVIDENCE" \
	--arg suggestion "$SUGGESTION" \
	'
	{type: $type, run_id: $run_id, lens: $lens, attempt: $attempt, ts: $ts}
	+ (if $type == "start" then {units: $units} else {} end)
	+ (if $type == "progress" then {unit: $unit} else {} end)
	+ (if $type == "done" then {status: $status} else {} end)
	+ (if $type == "finding" then {
		severity: $severity, category: $category, location: $location,
		summary: $summary, evidence: $evidence, suggestion: $suggestion
	} else {} end)
	')" || {
	echo "persist-lens-result: failed to build JSON line" >&2
	exit 1
}

lenses_dir="$(persist_lens_state_dir "$ROOT" "$SKILL")" || exit 2
attempt_dir="$lenses_dir/$RUN_ID"
attempt_file="$attempt_dir/$LENS.$ATTEMPT.jsonl"

if ! persist_jsonl_append "$attempt_file" "$line"; then
	exit 1
fi

printf '%s\n' "$attempt_file"
