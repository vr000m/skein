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
# Usage (stdin mode -- THE form a lens is ever given):
#
#   scripts/persist-lens-result.sh --root <repo-root> --skill <s> --run-id <id> \
#       --lens <name> --attempt <n> --json-stdin <<'SKEIN_JSON'
#   {"type":"finding","severity":"Critical","category":"Logic", ...}
#   SKEIN_JSON
#
# or, flag mode -- BACK-COMPAT/TEST ONLY, never from a lens prompt (see the
# six content flags' annotation below):
#
#   scripts/persist-lens-result.sh --root <repo-root> --skill deep-review|review-plan \
#       --run-id <id> --lens <name> --attempt <n> --type start|progress|finding|done \
#       [--units <comma,separated,list>] [--unit <name>] \
#       [--status completed|errored|skipped] \
#       [--severity Critical|Important|Minor] [--category <name>] \
#       [--location <file:line>] [--summary <text>] [--evidence <text>] \
#       [--suggestion <text>]
#
# The six content flags --severity/--category/--location/--summary/
# --evidence/--suggestion are back-compat/test only -- never from a lens
# prompt. Reviewed text on argv is expanded by the lens's own shell (its
# `$(...)`, backticks and quotes) BEFORE this script is entered, so a lens
# quoting reviewed code into them re-opens exactly the hole --json-stdin
# exists to close. Every SKILL.md mirror instructs --json-stdin only.
#
# --json-file <path> (G5) is --json-stdin with the transport swapped: it
# reads the same one-JSON-object payload from a FILE instead of stdin, and
# every gate after the read -- one-object shape, scalar type, units, the
# serializer -- is shared verbatim, so the two forms cannot drift in what
# they accept. Mutually exclusive with --json-stdin and with the payload
# flags.
#
# It exists for ORCHESTRATOR-SIDE writes: the Codex sequential clause, the
# skipped-lens clause, and the attempt-N `start` clause. Those payloads are
# written by a caller that HAS a file-write tool, and a file has no
# delimiter to end early. `--json-stdin` reaches this script under a quoted
# heredoc (`<<'SKEIN_JSON'`), and bash ends a heredoc at a line consisting
# EXACTLY of the delimiter -- so a payload that ever contained a bare
# `SKEIN_JSON` line would end the heredoc there and the remainder would be
# executed as shell. Valid JSON cannot produce such a line (the payload is
# one line, and a raw newline inside a JSON string is invalid JSON, which
# the shape gate below rejects anyway), so this is gated on a MODEL
# FORMATTING ERROR rather than on reviewed content -- but the trigger (a
# diff line reading exactly `SKEIN_JSON`, giving the model a template to
# copy) is plausible, and an orchestrator has no reason to accept that risk
# when it can write a file.
#
# LENSES KEEP --json-stdin. A temp file per streamed finding is worse
# ergonomics for the streaming writer, and the prompt contract in every
# SKILL.md mirror now names the delimiter-line hazard explicitly instead of
# expecting the model to infer the boundary rule.
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
#   * Stdin must be EXACTLY ONE JSON document and that document an object.
#     The check is slurped (`jq -s`) on purpose: without --slurp jq applies
#     its filter to each top-level document independently and reports only
#     the LAST one's status, so two concatenated objects would pass and the
#     first would be silently dropped. Invalid JSON, empty stdin, more than
#     one document, or a non-object exits 2 with NO directory created and
#     NO byte written.
#   * Every recognised scalar key (type, unit, status, severity, category,
#     location, summary, evidence, suggestion) must be absent, `null`, or a
#     STRING containing no NUL. An array, object, number or boolean for any
#     of them exits 2, nothing written. (`units` is exempt and validated
#     separately as an array-of-strings or a CSV string.)
#   * There is NO `eval` in this script and no shell-quoting round-trip:
#     the payload is decoded by jq into a NUL-delimited key/value stream
#     that `read -d ''` consumes verbatim. No payload byte is ever parsed
#     by a shell. (An earlier revision built `@sh`-quoted assignments and
#     `eval`ed them, on the false premise that `@sh` rejects non-scalars;
#     `@sh` errors only on objects, and rendered an ARRAY as several
#     shell-quoted WORDS -- an assignment followed by a command.)
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
# split; --units (and the --json-stdin `units` CSV *string* spelling) is a
# CSV itself, so its comma is the separator, not a rejected character. The
# --json-stdin `units` ARRAY spelling has no separator to hide behind: a
# comma inside an element is rejected with exit 2, because --expected
# transports the collector's expected units as a CSV and would re-split it
# into units no lens ever reports.
#
# Exit codes:
#   0 — line appended.
#   2 — usage error (missing/unknown --skill, --type, or --status; a
#       required --type-specific flag missing; non-positive --attempt;
#       --run-id/--lens outside its charset; a comma in --unit;
#       --json-stdin/--json-file combined with a payload flag; --json-file
#       combined with --json-stdin; an unreadable --json-file; input that is
#       not exactly one JSON object; a payload key whose value is
#       neither absent, null, nor a NUL-free string). No file is written.
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
    --run-id <id> --lens <name> --attempt <n> --json-stdin  < one-JSON-object
   or: scripts/persist-lens-result.sh --root <repo-root> --skill deep-review|review-plan \
    --run-id <id> --lens <name> --attempt <n> --type start|progress|finding|done \
    [--units <csv>] [--unit <name>] [--status completed|errored|skipped] \
    [--severity <s>] [--category <c>] [--location <file:line>] \
    [--summary <text>] [--evidence <text>] [--suggestion <text>]

--json-stdin is the form every lens is given: it reads the payload as one
JSON object on stdin instead of on argv, so reviewed code never reaches a
shell. It is mutually exclusive with
--type/--units/--unit/--status/--severity/--category/--location/--summary/
--evidence/--suggestion.

--json-file <path> is the same payload read from a file instead of stdin,
for ORCHESTRATOR-SIDE writes (the caller has a file-write tool). It has no
heredoc delimiter to end early. Mutually exclusive with --json-stdin.

The six content flags --severity/--category/--location/--summary/--evidence/
--suggestion are back-compat/test only -- never from a lens prompt: reviewed
text on argv is expanded by the lens's own shell before this script runs.
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
JSON_FILE=""
PAYLOAD_FLAGS=""

# note_payload_flag <flag> -- record that a flag-mode payload flag was used
# so --json-stdin can refuse the ambiguous mixed invocation.
note_payload_flag() {
	PAYLOAD_FLAGS="${PAYLOAD_FLAGS:+$PAYLOAD_FLAGS }$1"
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--root)
		shift
		persist_require_value "$@"
		ROOT="$1"
		;;
	--skill)
		shift
		persist_require_value "$@"
		SKILL="$1"
		;;
	--run-id)
		shift
		persist_require_value "$@"
		RUN_ID="$1"
		;;
	--lens)
		shift
		persist_require_value "$@"
		LENS="$1"
		;;
	--attempt)
		shift
		persist_require_value "$@"
		ATTEMPT="$1"
		;;
	--type)
		shift
		persist_require_value "$@"
		TYPE="$1"
		note_payload_flag --type
		;;
	--units)
		shift
		persist_require_value "$@"
		UNITS="$1"
		UNITS_SET=1
		note_payload_flag --units
		;;
	--unit)
		shift
		persist_require_value "$@"
		# F3 (writer/reader parity): the reader ran every ARGV unit
		# through persist_validate_unit; the writer ran a hand-rolled
		# `*,*` test at the type-validation step and nothing else, so
		# `--unit -foo` and `--unit 'src/$(id).ts'` were both accepted.
		# persist_require_value only checks ARITY -- it has no idea what
		# the token looks like. One helper, both sides of the wire.
		persist_validate_unit "$1" persist-lens-result argv || exit 2
		UNIT="$1"
		note_payload_flag --unit
		;;
	--status)
		shift
		persist_require_value "$@"
		STATUS="$1"
		note_payload_flag --status
		;;
	--severity)
		shift
		persist_require_value "$@"
		SEVERITY="$1"
		note_payload_flag --severity
		;;
	--category)
		shift
		persist_require_value "$@"
		CATEGORY="$1"
		note_payload_flag --category
		;;
	--location)
		shift
		persist_require_value "$@"
		LOCATION="$1"
		note_payload_flag --location
		;;
	--summary)
		shift
		persist_require_value "$@"
		SUMMARY="$1"
		note_payload_flag --summary
		;;
	--evidence)
		shift
		persist_require_value "$@"
		EVIDENCE="$1"
		note_payload_flag --evidence
		;;
	--suggestion)
		shift
		persist_require_value "$@"
		SUGGESTION="$1"
		note_payload_flag --suggestion
		;;
	--json-stdin)
		JSON_STDIN=1
		;;
	--json-file)
		shift
		persist_require_value "$@"
		if [[ -n "$JSON_FILE" ]]; then
			echo "persist-lens-result: --json-file may be given at most once (got '$JSON_FILE' then '$1')" >&2
			usage
			exit 2
		fi
		JSON_FILE="$1"
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
# G5: --json-file is --json-stdin with the transport swapped. Everything
# after the read -- the one-object shape gate, the scalar type gate, the
# units gate, the serializer -- is shared verbatim, so the two forms cannot
# drift in what they accept.
if [[ -n "$JSON_FILE" ]]; then
	if [[ "$JSON_STDIN" -eq 1 ]]; then
		echo "persist-lens-result: --json-file and --json-stdin are mutually exclusive" >&2
		usage
		exit 2
	fi
	JSON_STDIN=1
fi

if [[ "$JSON_STDIN" -eq 1 ]]; then
	if [[ -n "$PAYLOAD_FLAGS" ]]; then
		echo "persist-lens-result: --json-stdin is mutually exclusive with payload flags (got: $PAYLOAD_FLAGS)" >&2
		usage
		exit 2
	fi

	if [[ -n "$JSON_FILE" ]]; then
		# G4/F12: a repo-rooted path gets the same symlink guard every
		# other state path already has. Which guard applies is decided by
		# what the path IS, not by which flag carried it -- an
		# out-of-tree payload file (a fixture, a scratch file in $TMPDIR)
		# stays legal, and is deliberately NOT walked, because walking it
		# would refuse ordinary platform symlinks (macOS puts $TMPDIR
		# under `/var` -> `/private/var`).
		if persist_path_is_inside_root "$JSON_FILE" "$ROOT"; then
			if ! af_assert_no_symlink "$JSON_FILE" "$ROOT"; then
				echo "persist-lens-result: refusing to read through a symlink at $JSON_FILE" >&2
				exit 2
			fi
		fi
		if [[ ! -f "$JSON_FILE" || ! -r "$JSON_FILE" ]]; then
			echo "persist-lens-result: --json-file is not a readable file: $JSON_FILE" >&2
			exit 2
		fi
		STDIN_JSON="$(cat "$JSON_FILE")" || {
			echo "persist-lens-result: failed to read --json-file payload: $JSON_FILE" >&2
			exit 2
		}
	else
		STDIN_JSON="$(cat)" || {
			echo "persist-lens-result: failed to read --json-stdin payload" >&2
			exit 2
		}
	fi

	# Shape gate. jq WITHOUT --slurp applies the filter to each top-level
	# document independently and its exit status reflects only the LAST one,
	# so `{"a":1} {"b":2}` would pass a bare `type == "object"` check and the
	# first document would be silently dropped. Slurp first, then require
	# exactly one document and that document an object. Empty stdin slurps to
	# `[]` -> length 0 -> exit 2.
	if ! printf '%s' "$STDIN_JSON" | jq -e -s 'length == 1 and (.[0] | type == "object")' >/dev/null 2>&1; then
		echo "persist-lens-result: --json-stdin/--json-file requires exactly one JSON object" >&2
		exit 2
	fi

	# Type gate for the nine recognised scalar keys: each must be absent,
	# `null`, or a string, and no string may contain a NUL -- NUL is the
	# extractor's delimiter below, and a bash variable cannot hold one anyway.
	# `units` is deliberately NOT in this list: it has its own
	# array-of-strings/CSV filter below and reaches the serializer via
	# --argjson, never a shell.
	if ! printf '%s' "$STDIN_JSON" | jq -e -s '
		.[0] as $o
		| ["type","unit","status","severity","category","location","summary","evidence","suggestion"]
		| all($o[.] as $v
			| ($v == null)
			  or (($v | type) == "string" and ($v | contains("\u0000") | not)))
	' >/dev/null 2>&1; then
		echo "persist-lens-result: --json-stdin payload fields must be strings or null" >&2
		exit 2
	fi

	# Extract into the SAME internal variables flag mode fills. There is no
	# `eval` here and no shell-quoting round-trip: jq emits a NUL-delimited
	# key/value stream and `read -d ''` consumes it verbatim, so no payload
	# byte is ever parsed as shell syntax. NUL (rather than newline) is the
	# delimiter because a value may contain embedded AND trailing newlines,
	# which nine separate `jq -r` command substitutions would strip.
	while IFS= read -r -d '' k && IFS= read -r -d '' v; do
		case "$k" in
		type) TYPE="$v" ;;
		unit) UNIT="$v" ;;
		status) STATUS="$v" ;;
		severity) SEVERITY="$v" ;;
		category) CATEGORY="$v" ;;
		location) LOCATION="$v" ;;
		summary) SUMMARY="$v" ;;
		evidence) EVIDENCE="$v" ;;
		suggestion) SUGGESTION="$v" ;;
		esac
	done < <(printf '%s' "$STDIN_JSON" | jq -j -s '
		.[0] as $o
		| ["type","unit","status","severity","category","location","summary","evidence","suggestion"][]
		| ., "\u0000", (($o[.] // "")), "\u0000"
	')

	# `units` may be a JSON array (the transport form) or a CSV string (the
	# flag-mode spelling, accepted here for symmetry). Absent => --units was
	# not passed.
	#
	# F3/F10: the comma gate used to apply to BOTH spellings. On the CSV
	# spelling it was a no-op by construction (`split(",")` cannot yield a
	# comma-bearing element); on the ARRAY spelling it was the collector's old
	# comma-joined internal representation leaking into the writer's contract.
	# The collector no longer joins anything, so a comma in an array element
	# is just a byte in a name -- and `## Post-completion follow-ups (A3/A5,
	# 2026-05-24)` is a real review-plan heading the rule was rejecting. What
	# remains is PERSIST_UNIT_JQ_GATE, the SAME filter
	# collect-lens-results.sh's --expected-file reader applies, so writer and
	# reader can no longer disagree about what a unit is.
	STDIN_UNITS_JSON="$(printf '%s' "$STDIN_JSON" | jq -c '
		(if has("units") | not then null
		 elif (.units | type) == "array" then .units
		 elif (.units | type) == "string" then
			(if .units == "" then [] else (.units | split(",")) end)
		 else error("units must be an array or a CSV string") end)
		| if . == null then null else ('"$PERSIST_UNIT_JQ_GATE"') end
	')" || {
		echo "persist-lens-result: --json-stdin/--json-file 'units' must be an array of non-empty strings or a CSV string" >&2
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
	# The comma test that used to live here applied to BOTH transports, so a
	# JSON-payload `{"type":"progress","unit":"a,b"}` was refused even though
	# nothing on that wire splits on a comma. It moved to the `--unit` FLAG
	# handler, via persist_validate_unit's argv rules -- which is also where
	# the leading-dash and shell-metachar rules the writer was missing now
	# apply (F3). Nothing extra is needed for the JSON transports: the
	# non-empty check above is PERSIST_UNIT_JQ_GATE's per-element rule.
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
		# Comma is the separator here, so every element is comma-free by
		# construction. What the shared gate still catches on this wire is
		# an EMPTY element (`--units 'a,,b'`), which no lens could ever
		# report as reviewed.
		units_json="$(printf '%s' "$UNITS" | jq -R -c 'split(",") | ('"$PERSIST_UNIT_JQ_GATE"')')" || {
			echo "persist-lens-result: --units elements must be non-empty" >&2
			exit 2
		}
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
