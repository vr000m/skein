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
# ONE PAYLOAD TRANSPORT (R11/F4). There is no flag mode. Until round 11 this
# script also accepted the payload as ten argv flags
# (--type/--units/--unit/--status/--severity/--category/--location/--summary/
# --evidence/--suggestion), documented in its own header as back-compat/test
# only, and it had ZERO non-test callers: every SKILL.md mirror, every sibling
# script and every doc used --json-stdin/--json-file, and
# tests/lenses/test-lens-skill-shape.sh::G6(a) already asserted that no
# flag-mode prose survived anywhere. Its six content flags re-opened precisely
# the argv hole --json-stdin exists to close -- reviewed text on argv is
# expanded by the LENS'S OWN SHELL (`$(...)`, backticks, quotes) before this
# script is ever entered -- so the transport was kept alive solely by the
# tests that tested it. Those tests were ported to --json-file, which
# exercises the same downstream gates.
#
# The five CONTEXT flags (--root/--skill/--run-id/--lens/--attempt) are
# unaffected and still required: they name WHERE the record goes, never what
# it says, and no reviewed content passes through them.
#
# --json-file <path> (G5) is --json-stdin with the transport swapped: it
# reads the same one-JSON-object payload from a FILE instead of stdin, and
# every gate after the read -- one-object shape, scalar type, units, the
# serializer -- is shared verbatim, so the two forms cannot drift in what
# they accept. Mutually exclusive with --json-stdin.
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
# reviewing into the payload. In the flag mode this script CARRIED UNTIL R11
# that reviewed text landed on the lens's own argv, where `$(...)`, backticks
# and `"` are expanded by the lens's shell BEFORE this script ever runs. `--json-stdin` moves the
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
#     separately as an array of strings — the CSV spelling is argv-only.)
#   * There is NO `eval` in this script and no shell-quoting round-trip:
#     the payload is decoded by jq into a NUL-delimited key/value stream
#     that `read -d ''` consumes verbatim. No payload byte is ever parsed
#     by a shell. (An earlier revision built `@sh`-quoted assignments and
#     `eval`ed them, on the false premise that `@sh` rejects non-scalars;
#     `@sh` errors only on objects, and rendered an ARRAY as several
#     shell-quoted WORDS -- an assignment followed by a command.)
#   * Recognised body keys: type, units (JSON array of strings; no CSV spelling on this wire),
#     unit, status, severity, category, location, summary, evidence,
#     suggestion. They populate internal variables which then fall through
#     to the shared per-`type` required-field validation and the shared jq
#     serializer -- one encoder, one validator. (Before R11/F4 the same
#     variables were also reachable from ten argv flags; that transport is
#     gone, and these keys are now their only source.)
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
# scripts/lib/lens-common.sh's persist_lens_state_dir).
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
# Per-`type` required payload keys (validated BEFORE any directory is created
# or any byte is written — a missing/unknown key combination writes nothing):
#   start    — requires `units` (may be `[]` for zero assigned units, but the
#              key itself must be present).
#   progress — requires `unit`.
#   finding  — requires `severity`, `category`, `location`, `summary`.
#              `evidence`/`suggestion` are optional (default to "").
#   done     — requires `status`, one of completed|errored|skipped. (This is
#              the writer-side enum; "timed_out"/"partial"/"missing" are
#              collector-derived and are never a `status` value here — see
#              collect-lens-results.sh header.)
#
# Every line additionally carries `type`, `run_id`, `lens`, `attempt`
# (number), and `ts` (unix epoch seconds) so a line is self-describing even
# read in isolation from its filename.
#
# --run-id/--lens charset: both are validated against a whitelist (see
# scripts/lib/lens-common.sh's persist_validate_id) before any path is
# built. --lens (and every other name-shaped component) must match
# `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$` (no ':', no '/', no glob metachars,
# max 64 chars). --run-id additionally allows ':' (kind "run-id") so an
# ISO-8601 run-id like "2026-03-17T14:30:00Z" keeps working. A value
# outside its charset is rejected before any directory is created or byte
# written.
#
# A UNIT IS A STRING, NOT A CSV FIELD (round 4 reversed the round-3 contract;
# round 5 brought this header into line with the code it describes).
#
#   * On the FILE/JSON transports — `--json-file`, and the `--json-stdin`
#     `units` ARRAY spelling, which is the ONLY spelling — a unit's rules are exactly
#     PERSIST_UNIT_JQ_GATE's (scripts/lib/lens-common.sh): non-empty and
#     NUL-free. A comma, a newline, a leading `-` and shell metacharacters
#     are DATA on this wire; `## Post-completion follow-ups (A3/A5,
#     2026-05-24)` is a real review-plan heading that must round-trip. The
#     collector applies the same filter to --expected-file, so writer and
#     reader cannot disagree about what a unit is.
#   * The comma is a SEPARATOR only where it genuinely is one: an ARGV wire.
#     Round 6 removed the `--json-stdin`/`--json-file` `units` CSV-*string*
#     spelling entirely (on a JSON wire a comma is data, and that spelling
#     split a legitimate comma-bearing unit into two units nothing could ever
#     report); `units` on the JSON wire is an ARRAY or it is exit 2. R11/F4
#     then removed flag mode, so THIS SCRIPT NO LONGER HAS AN ARGV UNIT WIRE
#     AT ALL: the collector's `--expected` is the tree's last one.
#   * Consequently persist_validate_unit's ARGV BLACKLIST — a leading `-`,
#     `$`, backtick, `"`, `\`, a newline, or a comma — no longer applies
#     anywhere in this script. That is not a loosening of the unit rules; it
#     is the blacklist's own stated scope. Those are properties of a COMMAND
#     LINE, not of a unit, and this script no longer accepts a unit on one.
#     (A NUL was never in that list because it cannot reach argv at all:
#     execve() terminates every argument at the first NUL. PERSIST_UNIT_JQ_GATE
#     owns that rule, on the wire that can carry the byte — and it is now the
#     only unit rule this script applies.)
#   * persist_units_csv_to_json and persist_validate_unit both STAY in the
#     lens library: collect-lens-results.sh's `--expected` is still an ARGV
#     CSV wire and is still their caller. Their regression coverage moved
#     there with them (tests/lenses/test-lens-collect.sh).
#
# Exit codes:
#   0 — line appended.
#   2 — usage error (missing/unknown --skill; neither --json-stdin nor
#       --json-file given; a payload `type` or `status` that is missing or
#       outside its enum; a required per-`type` payload key missing;
#       non-positive --attempt; --run-id/--lens outside its charset; a
#       `units` element that is empty or contains a NUL; --json-file combined
#       with --json-stdin; an unreadable --json-file; input that is not
#       exactly one JSON object; a duplicate payload key; a payload key whose
#       value is neither absent, null, nor a NUL-free string). No file is
#       written.
#   1 — append refused or failed (symlink guard, permissions, disk full);
#       no line written.
#
# Dependencies: jq.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/auto-fix-common.sh disable=SC1091
. "$SCRIPT_DIR/lib/auto-fix-common.sh"
# shellcheck source=scripts/lib/lens-common.sh disable=SC1091
. "$SCRIPT_DIR/lib/lens-common.sh"

usage() {
	cat >&2 <<'EOF'
usage: scripts/persist-lens-result.sh --root <repo-root> --skill deep-review|review-plan \
    --run-id <id> --lens <name> --attempt <n> --json-stdin  < one-JSON-object
   or: scripts/persist-lens-result.sh --root <repo-root> --skill deep-review|review-plan \
    --run-id <id> --lens <name> --attempt <n> --json-file <path>

Exactly one of --json-stdin / --json-file is required: the payload is ALWAYS
one JSON object, never argv flags, so reviewed code never reaches a shell.

--json-stdin is the form every lens is given (heredoc, quoted delimiter).
--json-file <path> is the same payload read from a file, for
ORCHESTRATOR-SIDE writes (the caller has a file-write tool); it has no
heredoc delimiter to end early. The two are mutually exclusive.

The five context flags --root/--skill/--run-id/--lens/--attempt are required
in both forms.
EOF
}

ROOT=""
SKILL=""
RUN_ID=""
LENS=""
ATTEMPT=""
# TYPE and the eight content variables below are filled ONLY from the JSON
# payload (see the NUL-delimited extractor). Since R11/F4 removed flag mode
# they have no argv path at all; they are declared here so the serializer's
# --arg list has a defined value for an absent optional key.
TYPE=""
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

# --- payload decode ---------------------------------------------------------
# Decode the JSON object (from stdin or --json-file) into internal variables,
# then fall through to the shared per-`type` validation and the shared jq
# serializer below. Nothing here builds a path or writes a byte:
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

# R11/F4: with flag mode gone there is no other way to supply a payload, so
# the absence of a transport is its own usage error rather than a confusing
# "--type must be one of ..." from the type gate below, which now names a key
# of the JSON payload and no longer a flag anyone could have passed.
if [[ "$JSON_STDIN" -ne 1 ]]; then
	echo "persist-lens-result: exactly one of --json-stdin or --json-file is required (there is no flag-mode payload)" >&2
	usage
	exit 2
fi

if [[ "$JSON_STDIN" -eq 1 ]]; then
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

	# The one-document/object rule is a property of the JSON WIRE, so it runs
	# from the shared lib on BOTH sides of it — the same principle
	# collect-lens-results.sh states for the duplicate-key rule
	# (round 9, F8). This file used to restate the helper's rationale
	# verbatim and emit a DIFFERENT diagnostic for the same rejection.
	persist_validate_json_shape "$STDIN_JSON" persist-lens-result \
		"--json-stdin/--json-file payload" || exit 2

	# R7/F6: the WRITER half of the duplicate-key wire rule. jq collapses a
	# repeated key to the last occurrence before any filter runs, so a
	# payload spelling `units` (or any other key) twice silently loses the
	# earlier assignment on the way in. The reader
	# (collect-lens-results.sh --expected-file) has refused this since round
	# 6; a rule that holds on one side of a wire only is not a wire rule.
	# Applied to `$STDIN_JSON`, the exact bytes every gate below parses.
	persist_assert_no_duplicate_keys "$STDIN_JSON" persist-lens-result "--json-stdin/--json-file payload" || exit 2

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

	# Extract into the internal variables. There is no
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

	# `units` is a JSON ARRAY, full stop. Absent => --units was not passed.
	#
	# R6/F5: this filter also accepted a CSV *STRING* and split it on `,`.
	# That spelling contradicted this transport's own documented invariant —
	# restated in this script's header, in PERSIST_UNIT_JQ_GATE's comment
	# block, in the frozen plan, and in ALL FOUR lens SKILL.md mirrors ("a
	# JSON array of strings ... A unit is a string, not a CSV field") — that a
	# comma inside a unit is DATA. A lens emitting the plausible single-unit
	# rendering `{"type":"start","units":"## Post-completion follow-ups
	# (A3/A5, 2026-05-24)"}` silently registered TWO assigned units, neither
	# of which any `progress` record can ever match: the permanent-`partial`
	# failure mode the non-empty/NUL rules exist to prevent, and with no
	# exit 2. Round 5 defended the split SEMANTICS of that spelling; it never
	# justified the spelling existing at all ("kept for symmetry"). No
	# in-tree producer used it, and no mirror prescribes it, so the decoder is
	# now strictly narrower than every documented encoder. The remaining
	# ARGV-CSV wire is the COLLECTOR's `--expected` — that is where a comma
	# genuinely is a separator, and persist_units_csv_to_json remains its
	# only splitter. R11/F4 removed this script's own `--units` CSV along
	# with the rest of flag mode.
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
		 else error("units must be an array of non-empty strings") end)
		| if . == null then null else ('"$PERSIST_UNIT_JQ_GATE"') end
	')" || {
		echo "persist-lens-result: --json-stdin/--json-file 'units' must be an array of non-empty strings" >&2
		exit 2
	}
	if [[ "$STDIN_UNITS_JSON" != "null" ]]; then
		UNITS_SET=1
	fi
fi

case "$TYPE" in
start | progress | finding | done) ;;
*)
	echo "persist-lens-result: payload 'type' must be one of start|progress|finding|done (got '${TYPE:-<missing>}')" >&2
	usage
	exit 2
	;;
esac

case "$TYPE" in
start)
	if [[ "$UNITS_SET" -ne 1 ]]; then
		echo "persist-lens-result: payload type 'start' requires a 'units' array (pass [] for zero assigned units)" >&2
		usage
		exit 2
	fi
	;;
progress)
	if [[ -z "$UNIT" ]]; then
		echo "persist-lens-result: payload type 'progress' requires 'unit'" >&2
		usage
		exit 2
	fi
	# There is deliberately NO comma / leading-dash / metachar test here. It
	# once applied to both transports and refused a JSON-payload
	# `{"type":"progress","unit":"a,b"}` even though nothing on that wire
	# splits on a comma; F3/F10 moved it to the `--unit` FLAG handler, and
	# R11/F4 removed that handler with the rest of flag mode. On the JSON
	# wire those bytes are DATA -- `## Post-completion follow-ups (A3/A5,
	# 2026-05-24)` is a real review-plan heading that must round-trip -- and
	# the only unit rule is PERSIST_UNIT_JQ_GATE's per-element non-empty +
	# NUL-free check, which the `unit` scalar already passed through the type
	# gate above. Re-adding an argv blacklist to this wire would reverse a
	# recorded decision and reject legitimate unit names.
	;;
finding)
	if [[ -z "$SEVERITY" || -z "$CATEGORY" || -z "$LOCATION" || -z "$SUMMARY" ]]; then
		echo "persist-lens-result: payload type 'finding' requires 'severity', 'category', 'location', and 'summary'" >&2
		usage
		exit 2
	fi
	;;
done)
	case "$STATUS" in
	completed | errored | skipped) ;;
	*)
		echo "persist-lens-result: payload type 'done' requires 'status' one of completed|errored|skipped (got '${STATUS:-<missing>}')" >&2
		usage
		exit 2
		;;
	esac
	;;
esac

ts="$(date +%s)"

# R11/F4: the ARGV-CSV branch is gone with flag mode -- `units` only ever
# arrives as a JSON array now. persist_units_csv_to_json itself STAYS in the
# lens library: collect-lens-results.sh's `--expected` is the remaining
# argv-CSV surface and is still its caller.
units_json="[]"
if [[ "$TYPE" == "start" ]]; then
	units_json="${STDIN_UNITS_JSON:-[]}"
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

# The run dir is composed by the SHARED helper the reader uses (round 9, F9).
# Hand-composing `<lenses_dir>/$RUN_ID` here is the silent-divergence class
# lens-common.sh's "writer and reader derive the same directory" note
# exists to prevent.
attempt_dir="$(persist_lens_run_dir "$ROOT" "$SKILL" "$RUN_ID")" || exit 2
attempt_file="$attempt_dir/$LENS.$ATTEMPT.jsonl"

if ! af_assert_no_symlink "$attempt_file" "$ROOT"; then
	echo "persist-lens-result: refusing to write through a symlink at $attempt_file" >&2
	exit 1
fi

if ! persist_jsonl_append "$attempt_file" "$line"; then
	exit 1
fi

printf '%s\n' "$attempt_file"
