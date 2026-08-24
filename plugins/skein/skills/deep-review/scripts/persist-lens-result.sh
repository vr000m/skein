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
# or, preferred for any payload derived from reviewed code (stdin mode):
#
#   scripts/persist-lens-result.sh --root <repo-root> --skill <s> --run-id <id> \
#       --lens <name> --attempt <n> --json-stdin <<'SKEIN_JSON'
#   {"type":"finding","severity":"Critical","category":"Logic", ...}
#   SKEIN_JSON
#
# WHY STDIN MODE EXISTS. The lens-persistence prompt contract is a shell
# command template, and a lens is instructed to quote the code it is
# reviewing into the payload. In flag mode that reviewed text lands on the
# lens's own argv, where `$(...)`, backticks and `"` are expanded by the
# lens's shell BEFORE this script ever runs. `--json-stdin` moves the
# payload off argv entirely: it crosses the process boundary as heredoc
# stdin under a quoted delimiter (`<<'SKEIN_JSON'`, no expansion) and is
# parsed by jq, never by a shell.
#
# --json-stdin semantics:
#   * Reads exactly one JSON object from stdin. `type == "object"` is
#     checked first; invalid JSON or a non-object exits 2 with NO directory
#     created and NO byte written.
#   * Mutually exclusive with the payload flags --type/--units/--unit/
#     --status/--severity/--category/--location/--summary/--evidence/
#     --suggestion. Passing both exits 2, nothing written.
#   * Recognised body keys: type, units (JSON array, or a CSV string),
#     unit, status, severity, category, location, summary, evidence,
#     suggestion. They populate the SAME internal variables flag mode uses
#     and then fall through to the SAME per-`--type` required-field
#     validation and the SAME jq serializer -- one encoder, one validator,
#     and an on-disk line byte-identical to flag mode's.
#   * --root/--skill/--run-id/--lens/--attempt stay flags: they are
#     orchestrator-resolved, never lens-authored. If any of those keys
#     appears in the JSON body it is IGNORED -- a lens must not be able to
#     redirect its own write path.
#   * Flag mode is retained unchanged for backward compatibility.
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
# --run-id/--lens charset: both are validated against a whitelist (see
# scripts/lib/persist-common.sh's persist_validate_id) before any path is
# built. --lens (and every other name-shaped component) must match
# `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$` (no ':', no '/', no glob metachars,
# max 64 chars). --run-id additionally allows ':' (kind "run-id") so an
# ISO-8601 run-id like "2026-03-17T14:30:00Z" keeps working. A value
# outside its charset is rejected before any directory is created or byte
# written.
#
# Unit names must not contain commas — unit lists are comma-joined and
# unescaped end-to-end (writer --units, collector --expected). A
# comma-bearing --unit is rejected at the boundary rather than silently
# split; --units is a CSV itself so its comma is the separator, not a
# rejected character.
#
# Exit codes:
#   0 — line appended.
#   2 — usage error (missing/unknown --skill, --type, or --status; a
#       required --type-specific flag missing; non-positive --attempt;
#       --run-id/--lens outside its charset; a comma in --unit;
#       --json-stdin combined with a payload flag; stdin that is not one
#       JSON object). No file is written.
#   1 — append refused or failed (symlink guard, permissions, disk full);
#       no line written.
#
# Dependencies: jq.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/auto-fix-common.sh disable=SC1091
. "$SCRIPT_DIR/lib/auto-fix-common.sh"
# shellcheck source=scripts/lib/persist-common.sh disable=SC1091
. "$SCRIPT_DIR/lib/persist-common.sh"

usage() {
	cat >&2 <<'EOF'
usage: scripts/persist-lens-result.sh --root <repo-root> --skill deep-review|review-plan \
    --run-id <id> --lens <name> --attempt <n> --type start|progress|finding|done \
    [--units <csv>] [--unit <name>] [--status completed|errored|skipped] \
    [--severity <s>] [--category <c>] [--location <file:line>] \
    [--summary <text>] [--evidence <text>] [--suggestion <text>]
   or: scripts/persist-lens-result.sh --root <repo-root> --skill deep-review|review-plan \
    --run-id <id> --lens <name> --attempt <n> --json-stdin  < one-JSON-object

--json-stdin reads the payload as one JSON object on stdin instead of on
argv, so reviewed code never reaches a shell. It is mutually exclusive with
--type/--units/--unit/--status/--severity/--category/--location/--summary/
--evidence/--suggestion.
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
JSON_STDIN=0
PAYLOAD_FLAGS=""

# note_payload_flag <flag> -- record that a flag-mode payload flag was used
# so --json-stdin can refuse the ambiguous mixed invocation.
note_payload_flag() {
	PAYLOAD_FLAGS="${PAYLOAD_FLAGS:+$PAYLOAD_FLAGS }$1"
}

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
		note_payload_flag --type
		;;
	--units)
		shift
		require_value "$@"
		UNITS="$1"
		UNITS_SET=1
		note_payload_flag --units
		;;
	--unit)
		shift
		require_value "$@"
		UNIT="$1"
		note_payload_flag --unit
		;;
	--status)
		shift
		require_value "$@"
		STATUS="$1"
		note_payload_flag --status
		;;
	--severity)
		shift
		require_value "$@"
		SEVERITY="$1"
		note_payload_flag --severity
		;;
	--category)
		shift
		require_value "$@"
		CATEGORY="$1"
		note_payload_flag --category
		;;
	--location)
		shift
		require_value "$@"
		LOCATION="$1"
		note_payload_flag --location
		;;
	--summary)
		shift
		require_value "$@"
		SUMMARY="$1"
		note_payload_flag --summary
		;;
	--evidence)
		shift
		require_value "$@"
		EVIDENCE="$1"
		note_payload_flag --evidence
		;;
	--suggestion)
		shift
		require_value "$@"
		SUGGESTION="$1"
		note_payload_flag --suggestion
		;;
	--json-stdin)
		JSON_STDIN=1
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

persist_validate_id "$RUN_ID" persist-lens-result run-id || exit 2
persist_validate_id "$LENS" persist-lens-result name || exit 2

if [[ ! "$ATTEMPT" =~ ^[0-9]+$ ]] || ((10#$ATTEMPT < 1)); then
	echo "persist-lens-result: --attempt must be a positive integer (got '${ATTEMPT:-<missing>}')" >&2
	usage
	exit 2
fi
# Normalise so "007" and "7" resolve to the same file and the same JSON
# `attempt` value (finding 9) -- one writer per file must hold for every
# spelling of the same number.
ATTEMPT=$((10#$ATTEMPT))

if ! command -v jq >/dev/null 2>&1; then
	echo "persist-lens-result: jq is required" >&2
	exit 2
fi

# --- stdin payload mode -----------------------------------------------------
# Decode the JSON object on stdin into the SAME internal variables flag mode
# fills, then fall through to the shared per-`--type` validation and the
# shared jq serializer below. Nothing here builds a path or writes a byte:
# every rejection is exit 2 before persist_lens_state_dir is ever called.
if [[ "$JSON_STDIN" -eq 1 ]]; then
	if [[ -n "$PAYLOAD_FLAGS" ]]; then
		echo "persist-lens-result: --json-stdin is mutually exclusive with payload flags (got: $PAYLOAD_FLAGS)" >&2
		usage
		exit 2
	fi

	STDIN_JSON="$(cat)" || {
		echo "persist-lens-result: failed to read --json-stdin payload" >&2
		exit 2
	}

	if ! printf '%s' "$STDIN_JSON" | jq -e 'type == "object"' >/dev/null 2>&1; then
		echo "persist-lens-result: --json-stdin requires exactly one JSON object on stdin" >&2
		exit 2
	fi

	# @sh-quoted assignments: jq owns the shell quoting, so no payload byte is
	# ever re-parsed as shell syntax. A non-scalar value for any of these keys
	# makes jq fail, which is a clean exit 2 with nothing written.
	json_assignments="$(printf '%s' "$STDIN_JSON" | jq -r '
		@sh "TYPE=\(.type // "") UNIT=\(.unit // "") STATUS=\(.status // "") SEVERITY=\(.severity // "") CATEGORY=\(.category // "") LOCATION=\(.location // "") SUMMARY=\(.summary // "") EVIDENCE=\(.evidence // "") SUGGESTION=\(.suggestion // "")"
	')" || {
		echo "persist-lens-result: --json-stdin payload fields must be scalars" >&2
		exit 2
	}
	# shellcheck disable=SC2086 # jq's @sh output is already shell-quoted
	eval "$json_assignments"

	# `units` may be a JSON array (preferred -- no comma-separator restriction)
	# or a CSV string (flag-mode spelling). Absent => --units was not passed.
	STDIN_UNITS_JSON="$(printf '%s' "$STDIN_JSON" | jq -c '
		if has("units") | not then null
		elif (.units | type) == "array" then
			(if (.units | all(type == "string")) then .units
			 else error("units array must contain only strings") end)
		elif (.units | type) == "string" then
			(if .units == "" then [] else (.units | split(",")) end)
		else error("units must be an array or a CSV string") end
	')" || {
		echo "persist-lens-result: --json-stdin 'units' must be an array of strings or a CSV string" >&2
		exit 2
	}
	if [[ "$STDIN_UNITS_JSON" != "null" ]]; then
		UNITS_SET=1
	fi
fi

case "$TYPE" in
start | progress | finding | done) ;;
*)
	echo "persist-lens-result: --type must be one of start|progress|finding|done (got '${TYPE:-<missing>}')" >&2
	usage
	exit 2
	;;
esac

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
	if [[ "$UNIT" == *,* ]]; then
		echo "persist-lens-result: --unit must not contain a comma (unit lists are comma-joined and unescaped: '$UNIT')" >&2
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
	if [[ "$JSON_STDIN" -eq 1 ]]; then
		units_json="${STDIN_UNITS_JSON:-[]}"
	elif [[ -z "$UNITS" ]]; then
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

if ! af_assert_no_symlink "$attempt_file" "$ROOT"; then
	echo "persist-lens-result: refusing to write through a symlink at $attempt_file" >&2
	exit 1
fi

if ! persist_jsonl_append "$attempt_file" "$line"; then
	exit 1
fi

printf '%s\n' "$attempt_file"
