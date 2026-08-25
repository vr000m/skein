#!/usr/bin/env bash
# collect-lens-results.sh — read every attempt file a lens (or set of
# lenses) has written via persist-lens-result.sh under one run-id, and emit
# a merged per-lens summary. This is the reader half of Phase 2's
# disk-first design (plan
# docs/dev_plans/20260823-feature-review-skills-resilience.md, R3/R4): the
# orchestrator calls this to detect a silent lens, decide what to respawn,
# and derive `.lenses` state (via `persist-deep-review-state.sh
# --from-collector`) without ever trusting the Agent-tool return value as
# the sole record.
#
# Usage:
#   scripts/collect-lens-results.sh [--root <repo-root>] --skill deep-review|review-plan \
#       --run-id <id> [--expected-file <path> | --expected <lens>:<unit1>,<unit2>,... ...] \
#       [--attempts <lens>:<n>] [--attempts ...] [--running <lens>:<n>] \
#       [--running ...] [--findings-jsonl]
#
# --attempts <lens>:<n> (repeatable, at most one *effective* entry per lens
# -- duplicates for the same lens: last wins) records the highest attempt
# number the orchestrator SPAWNED for that lens, whether or not that attempt
# ever wrote a file. Absent for a lens (or absent entirely) -> spawned=0,
# which makes status derivation collapse exactly to today's file-count-only
# behaviour (backward compatible). An --attempts entry naming a lens with no
# --expected entry is accepted and ignored. See "Status derivation" below
# for how `effective` feeds the timed_out/partial split -- this is what
# makes a spawned-but-silent attempt (no file at all) report timed_out
# instead of missing/partial.
#
# --running <lens>:<n> (repeatable, last wins per lens) is the orchestrator
# declaring "attempt <n> of this lens is STILL IN FLIGHT". --running is a
# status FLOOR, not an override: the derived status is `partial` rather than
# the terminal `timed_out`. A recorded terminal status (completed/errored/
# skipped) outranks that floor
# only when its attempt is >= the running attempt number
# -- a `done` line written BY the attempt still declared in
# flight is evidence that attempt actually finished, whereas a `done` line
# from an EARLIER attempt is stale and says nothing about the retry: letting
# it through retired a lens whose attempt 2 had been spawned and had not yet
# written a byte. This
# exists so the collector never has to INFER liveness from an attempt index
# -- an index is not a count, and inferring liveness from it is what made a
# healthy in-flight attempt 3 on --continue report the terminal `timed_out`
# and stop the orchestrator waiting. --continue passes
# `--running <lens>:<next-attempt>` for each lens it has just respawned.
#
# --findings-jsonl (boolean, mutually exclusive with the default summary
# object; changes stdout only) emits one JSON object per line instead of the
# per-lens summary:
#   {"lens":"<lens key>","severity":…,"category":…,"file":…,"line":…,
#    "summary":…,"evidence":…,"suggestion":…}
# in --expected order per lens, findings in collected (dedup-preserved)
# order. `file`/`line` are derived exactly as the dedup key does: explicit
# .file/.line if present, else `location` split on the LAST ":" (no ":" ->
# file = location, line = ""). Absent fields default to "". Emitted for
# every reported lens, including partial/timed_out ones -- on-disk findings
# from a still-running or silent lens are real findings; the lens's
# non-terminal status is tracked separately by the default summary output,
# not by this stream. Never hand-assemble this shape from raw lens
# replies -- this is the only place that owns the location-split and the
# lens key.
#
# --root is OPTIONAL (unlike persist-lens-result.sh's explicit-always
# --root): when omitted this script root-anchors the same way
# persist-review-state.sh/persist-deep-review-state.sh do, via
# `persist_root_dir` (git worktree root, falling back to cwd when not
# inside a git worktree). The plan's abbreviated collector signature names
# only --skill/--run-id/--expected; this script accepts an explicit --root
# too when a caller already has it resolved (e.g. the same orchestrator
# invocation that resolved it for persist-lens-result.sh), but does not
# require it. When --root is omitted AND cwd is not inside a git worktree
# the script REFUSES (exit 2) instead of falling back to cwd: the writer
# always takes an explicit --root, so a cwd fallback outside a worktree
# would silently read a different `<state-dir>/lenses` than the one written
# to and report every lens `missing`.
#
# --expected-file <path> is the PREFERRED transport for the assigned-units
# list, and the REQUIRED one whenever the units are derived from the diff or
# from any other reviewed text (G4). It names one JSON file holding a single
# object mapping lens name -> array of unit strings:
#
#   {"logic": ["src/app.ts", "src/db.ts"], "security": ["src/auth.ts"]}
#
# Key order is preserved, so it produces the same lens ordering repeated
# --expected flags would. Each key goes through persist_validate_id (the
# same lens-name whitelist --expected uses); the unit ARRAY goes through
# PERSIST_UNIT_JQ_GATE in one jq hop -- see "A UNIT IS A STRING" below.
#
# WHY a file and not a flag. `--expected "logic:src/$(id).ts"` is substituted
# by the ORCHESTRATOR'S SHELL before this script is ever entered, so no
# in-script whitelist can see the pre-substitution text; double quotes stop
# word-splitting and globbing but NOT substitution. This is the same class
# the --json-stdin work closed on the writer side, and the reason the fix is
# a transport change rather than a validation change. The orchestrator
# writes the file with its file-write tool (no shell) at
# `persist_lens_run_dir <root> <skill> <run-id>`/expected.json — i.e.
# <repo-root>/.deep-review/lenses/<run-id>/expected.json (review-plan:
# <repo-root>/.review-plan/lenses/<run-id>/expected.json), the same per-run
# directory the attempt files occupy, whose every component is already
# persist_validate_id-clean — and passes only that path on the command line.
# (Round 4/F2: it used to be given a path literal invented in SKILL.md prose,
# `<repo-root>/.skein/lens-runs/<run-id>/expected.json`, a third state root
# owned by no helper and absent from .gitignore. Both real state roots are
# gitignored, so a collect run now leaves no untracked file behind. Attempt
# discovery matches `<lens>.<attempt>.jsonl` basenames only, so expected.json
# sitting in that directory is never read as an attempt file.)
#
# A UNIT IS A STRING, NOT A CSV FIELD. Units read from --expected-file are
# held as a JSON array from jq to jq and are never joined, split, or passed
# through a bash round-trip, so a comma, a newline or a NUL inside a unit is
# just a byte in a name (round 4: F9/F10/F11). PERSIST_UNIT_JQ_GATE in
# scripts/lib/persist-common.sh is the single source of that wire's rules and
# persist-lens-result.sh enforces the same one on the writer side (F3). The
# comma restriction survives only on --expected, where the comma genuinely is
# the separator.
#
# --expected-file and --expected are MUTUALLY EXCLUSIVE (exit 2 if both are
# given): last-wins between two transports for the same list is too subtle a
# failure to debug. A lens named by neither is unreported, unchanged.
#
# --expected is repeatable, one per lens the orchestrator assigned work to.
# The orchestrator OWNS the assigned-units list (R4) — this script never
# infers "what should have been reviewed" from what a lens happened to
# write; a lens's `assigned` count always comes from its --expected entry
# when one was given. A lens with attempt files on disk but no matching
# --expected entry is not reported (the orchestrator did not ask about it).
#
# Output: one JSON object on stdout, keyed by lens name:
#   {
#     "<lens>": {
#       "status": "completed|partial|timed_out|errored|skipped|missing",
#       "assigned": <count>,
#       "reviewed": <count>,
#       "unreviewed": ["u2", ...],
#       "findings": [...whatever fields the "finding" lines carried...]
#     },
#     ...
#   }
# `assigned`/`reviewed` are counts (not the unit lists) — `unreviewed` is
# the only per-unit array, since that is what a respawn actually consumes.
#
# Status derivation, per lens, across ALL attempt files
# (<state-dir>/lenses/<run-id>/<lens>.<N>.jsonl, N ascending), with
# `files` = number of that lens's attempt files on disk, `spawned` = its
# --attempts value or 0 when absent, and `effective` = `spawned` when
# --attempts named this lens, else `files`. It is deliberately NOT
# max(spawned, files): `files` is a COUNT and `spawned` is an INDEX, and
# conflating the two misread two recovered attempt files plus an in-flight
# attempt 3 as two exhausted attempts. The orchestrator owns the attempt
# count (R4); this script only counts files when it was not told.
#   - No `done` line anywhere, files == 0, and effective <= 1 (i.e.
#     spawned <= 1) -> zero coverage; unreviewed := the full --expected unit
#     list (or [] if none was given). The status is "missing" ONLY when
#     --running does not name this lens; when it does, the status is
#     "partial". The --running floor is unconditional (see --running above):
#     a lens the orchestrator has declared in flight is never terminal and
#     never "missing", at EVERY attempt index including 1. "missing" is what
#     makes --continue treat a lens as never-spawned and reassign it from
#     scratch, which would discard a healthy in-flight attempt.
#   - Otherwise, take the `done` line (if any) from the LATEST (highest-
#     numbered) attempt file -- whether or not that file has one. A
#     completed attempt 1 does NOT supply the status for a start-only
#     attempt 2: status describes the latest attempt's own terminal state.
#     (`progress` and `findings` still merge across every attempt --
#     recovering earlier on-disk work is the point of the disk-first
#     design; only STATUS is latest-attempt-scoped.)
#       done.status == "completed" -> "completed"
#       done.status == "errored"   -> "errored"
#       done.status == "skipped"   -> "skipped" (orchestrator-emitted, on a
#         deliberately-skipped lens's behalf; terminal for --continue)
#   - No `done` line on the latest attempt:
#       --running names this lens -> "partial", unconditionally (the
#         orchestrator says it is still working; terminal would stop the
#         wait on a healthy attempt)
#       effective >= 2 -> "timed_out" (a respawn already happened -- whether
#         or not that respawned attempt ever wrote a file -- and still
#         produced no completion signal; one-respawn means this is terminal
#         for the current orchestrator invocation)
#       effective == 1 -> "partial" (still mid-run; a respawn on
#         `unreviewed` is expected to follow)
# With --attempts absent, spawned == 0 always, so effective == files and
# this collapses exactly to the file-count-only table every existing test
# already asserts on.
#
# `reviewed` is the union, across every attempt, of `--unit` values from
# `progress` lines, intersected with `assigned` (so a stray progress line
# for a unit the orchestrator never assigned cannot inflate coverage).
# `unreviewed` := assigned - reviewed, in assigned order.
#
# `findings` are the union, across every attempt, of `finding` lines,
# deduplicated by a (file, line, category) signature (case-insensitive on
# file/category), first occurrence wins — the SAME (file, line, category)
# signature the reconciler uses for cross-lens merging, applied here
# cross-attempt instead (R4: "deduped by the reconciler's (file, line,
# category) signature"). This is intentionally NOT the R5 regression key
# (scripts/finding-key.sh, Phase 3) — a different signature for a
# different purpose. A finding line may carry `file`/`line` directly, or a
# combined `location` field ("file:line") as persist-lens-result.sh writes
# it — the key is derived from whichever is present.
#
# Malformed lines: only a truncated trailing line (the classic
# killed-mid-write symptom — the process died with a partial JSON object on
# the file's last line) is expected and silently ignored. As a superset
# behaviour, any line that fails to parse as a JSON object is skipped
# (never crashes the collector), but a truncated *trailing* line is the
# documented, tested case.
#
# --run-id/each --expected, --attempts, and --running lens key are validated against the
# same charset whitelist persist-lens-result.sh uses (see
# scripts/lib/persist-common.sh's persist_validate_id): a lens name must
# match `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$` (no ':', no '/', no glob
# metachars) and --run-id additionally allows ':'. This closes the same
# glob/path-interpolation vector from the reader side that
# persist-lens-result.sh closes from the writer side. Unit names are NOT
# ids — they are free-form review targets (file paths for deep-review, plan
# sections for review-plan) — so they go through persist_validate_unit's
# narrow blacklist instead, and WHICH rules apply is a property of the
# TRANSPORT, not of the unit:
#
#   --expected-file (the required transport for diff- or heading-derived
#     units): a unit is a JSON string inside a JSON array. It is never a
#     shell word and never an option position, so the only rule is
#     non-empty. A comma, a newline, a NUL, a leading '-', a '$' or a
#     backtick are all just bytes and survive verbatim.
#
#   --expected (the hand-invocation transport): the comma really IS the
#     separator here, so a comma-bearing unit would silently split and is
#     rejected; a leading '-' really would occupy an option position, so it
#     is rejected too; and because the caller's shell has already expanded
#     this value before the script was entered, '$', backtick, '"', '\\' and
#     newline are rejected as defence in depth.
#
# See PERSIST_UNIT_JQ_GATE and persist_validate_unit in
# scripts/lib/persist-common.sh -- the wire gate and the argv gate.
#
# Exit codes:
#   0 — always, once flags validate (a stale/unknown run-id or empty
#       --expected list is a normal "missing" result, not an error).
#   2 — usage error (missing --skill/--run-id, unknown --skill, a malformed
#       --expected/--attempts/--running entry, a --run-id/lens name outside
#       its charset, a unit rejected by its transport's gate, --expected
#       given together with --expected-file, an --expected-file that is
#       unreadable or is not an object of string arrays, --root omitted
#       while cwd is not inside a git worktree, or a symlinked run directory
#       at <state-dir>/lenses/<run-id>).
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
usage: scripts/collect-lens-results.sh [--root <repo-root>] --skill deep-review|review-plan \
    --run-id <id> [--expected-file <path> | --expected <lens>:<unit1>,<unit2>,... ...] \
    [--attempts <lens>:<n>] [--attempts ...] [--running <lens>:<n>] \
    [--running ...] [--findings-jsonl]

--expected-file is the DOCUMENTED form for diff-derived unit lists (file
paths): the orchestrator writes the JSON with its file-write tool, so no
reviewed text is ever interpolated into a shell command line. --expected
remains for hand-written, non-diff-derived unit lists. They are mutually
exclusive.
EOF
}

ROOT=""
SKILL=""
RUN_ID=""
FINDINGS_JSONL=0
EXPECTED_FILE=""
SAW_EXPECTED_ARGV=0
declare -a EXPECTED_LENSES=()
# One compact JSON array per lens, index-parallel with EXPECTED_LENSES. NOT a
# comma-joined string: that single representation was the root cause of four
# round-4 findings at once (see the header's "A UNIT IS A STRING" note).
declare -a EXPECTED_UNITS_JSON=()
declare -a ATTEMPTS_LENSES=()
declare -a ATTEMPTS_N=()
declare -a RUNNING_LENSES=()
declare -a RUNNING_N=()

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
	--expected)
		shift
		persist_require_value "$@"
		entry="$1"
		if [[ "$entry" != *:* ]]; then
			echo "collect-lens-results: --expected entries must be <lens>:<unit1,unit2,...> (got '$entry')" >&2
			usage
			exit 2
		fi
		expected_lens_name="${entry%%:*}"
		persist_validate_id "$expected_lens_name" collect-lens-results name || exit 2
		expected_units_csv="${entry#*:}"
		# G4 layer 2: every unit that arrives on ARGV is blacklist-checked
		# (see persist_validate_unit). This is defence in depth, not the
		# primary control: the orchestrator's shell has already performed
		# any substitution before this script is entered, so a
		# diff-derived unit must not reach argv in the first place — use
		# --expected-file for those.
		if [[ -n "$expected_units_csv" ]]; then
			IFS=',' read -r -a expected_units_argv <<<"$expected_units_csv"
			for expected_unit in "${expected_units_argv[@]}"; do
				persist_validate_unit "$expected_unit" collect-lens-results argv || exit 2
			done
		fi
		SAW_EXPECTED_ARGV=1
		# CSV is THIS transport's own wire format, so the split stays
		# here -- and every unit reaching it has already been through
		# persist_validate_unit's argv rules, which forbid the newline
		# `jq -R` cannot survive.
		expected_units_json='[]'
		if [[ -n "$expected_units_csv" ]]; then
			expected_units_json="$(printf '%s' "$expected_units_csv" | jq -R -c 'split(",")')" || {
				echo "collect-lens-results: could not parse --expected unit list for '$expected_lens_name'" >&2
				exit 2
			}
		fi
		EXPECTED_LENSES+=("$expected_lens_name")
		EXPECTED_UNITS_JSON+=("$expected_units_json")
		;;
	--expected-file)
		shift
		persist_require_value "$@"
		if [[ -n "$EXPECTED_FILE" ]]; then
			echo "collect-lens-results: --expected-file may be given at most once (got '$EXPECTED_FILE' then '$1')" >&2
			usage
			exit 2
		fi
		EXPECTED_FILE="$1"
		;;
	--attempts)
		shift
		persist_require_value "$@"
		entry="$1"
		if [[ "$entry" != *:* ]]; then
			echo "collect-lens-results: --attempts entries must be <lens>:<n> (got '$entry')" >&2
			usage
			exit 2
		fi
		attempts_lens_name="${entry%%:*}"
		attempts_n_raw="${entry#*:}"
		persist_validate_id "$attempts_lens_name" collect-lens-results name || exit 2
		if [[ ! "$attempts_n_raw" =~ ^[0-9]+$ ]] || ((10#$attempts_n_raw < 1)); then
			echo "collect-lens-results: --attempts entries must be <lens>:<n> (got '$entry')" >&2
			usage
			exit 2
		fi
		ATTEMPTS_LENSES+=("$attempts_lens_name")
		ATTEMPTS_N+=("$((10#$attempts_n_raw))")
		;;
	--running)
		shift
		persist_require_value "$@"
		entry="$1"
		if [[ "$entry" != *:* ]]; then
			echo "collect-lens-results: --running entries must be <lens>:<n> (got '$entry')" >&2
			usage
			exit 2
		fi
		running_lens_name="${entry%%:*}"
		running_n_raw="${entry#*:}"
		persist_validate_id "$running_lens_name" collect-lens-results name || exit 2
		if [[ ! "$running_n_raw" =~ ^[0-9]+$ ]] || ((10#$running_n_raw < 1)); then
			echo "collect-lens-results: --running entries must be <lens>:<n> (got '$entry')" >&2
			usage
			exit 2
		fi
		RUNNING_LENSES+=("$running_lens_name")
		RUNNING_N+=("$((10#$running_n_raw))")
		;;
	--findings-jsonl)
		FINDINGS_JSONL=1
		;;
	--help | -h)
		usage
		exit 0
		;;
	*)
		echo "collect-lens-results: unrecognised argument: $1" >&2
		usage
		exit 2
		;;
	esac
	shift
done

if [[ -z "$ROOT" ]]; then
	# G12c: persist_root_dir falls back to cwd when cwd is not inside a git
	# worktree. That fallback is a silent-divergence hazard here: the WRITER
	# (persist-lens-result.sh) always takes an explicit --root, so an
	# unrooted collector outside a worktree would read a different
	# `.deep-review/lenses` than the one that was written to, and report
	# every lens `missing`. Refuse instead. --root stays OPTIONAL for the
	# documented happy path (a caller inside the worktree).
	if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
		echo "collect-lens-results: --root omitted and cwd is not a git worktree; pass --root explicitly" >&2
		exit 2
	fi
	ROOT="$(persist_root_dir)"
fi

case "$SKILL" in
deep-review | review-plan) ;;
*)
	echo "collect-lens-results: --skill must be deep-review or review-plan" >&2
	usage
	exit 2
	;;
esac

if [[ -z "$RUN_ID" ]]; then
	echo "collect-lens-results: --run-id is required" >&2
	usage
	exit 2
fi

persist_validate_id "$RUN_ID" collect-lens-results run-id || exit 2

if ! command -v jq >/dev/null 2>&1; then
	echo "collect-lens-results: jq is required" >&2
	exit 2
fi

# ---------------------------------------------------------------------------
# --expected-file (G4 layer 1): the unit-list transport that does not go
# through a shell.
#
# Mutually exclusive with --expected rather than last-wins: an orchestrator
# that passes both has a bug, and silently preferring one of them hides it.
# A lens named by NEITHER is simply unreported, exactly as before.
# ---------------------------------------------------------------------------
# G4/F12 ORDERING: derive the run dir and run its symlink guard BEFORE
# --expected-file is read, so a symlinked run directory is refused before any
# of its contents are trusted. Once the units file lives inside run_dir (F2),
# it inherits this check as well -- the two fixes reinforce each other.
run_dir="$(persist_lens_run_dir "$ROOT" "$SKILL" "$RUN_ID")" || exit 2

if [[ -e "$run_dir" ]]; then
	if ! af_assert_no_symlink "$run_dir" "$ROOT"; then
		echo "collect-lens-results: refusing to read through a symlink at $run_dir" >&2
		exit 2
	fi
fi

if [[ -n "$EXPECTED_FILE" ]]; then
	if [[ "$SAW_EXPECTED_ARGV" -eq 1 ]]; then
		echo "collect-lens-results: --expected and --expected-file are mutually exclusive (pass diff-derived units via --expected-file only)" >&2
		usage
		exit 2
	fi
	# G4/F12: a repo-rooted state path gets the same symlink guard every
	# other one already has. Which GUARD applies is decided by what the path
	# IS, not by which flag carried it. Scoped to in-root paths on purpose:
	# an out-of-tree fixture or payload path must stay legal, and walking its
	# parents would refuse ordinary platform symlinks (macOS puts $TMPDIR
	# under `/var` -> `/private/var`). persist_path_is_inside_root is LEXICAL
	# precisely so a path escaping the root THROUGH a symlink still counts as
	# in-root and is caught here rather than gating itself out.
	if persist_path_is_inside_root "$EXPECTED_FILE" "$ROOT"; then
		if ! af_assert_no_symlink "$EXPECTED_FILE" "$ROOT"; then
			echo "collect-lens-results: refusing to read through a symlink at $EXPECTED_FILE" >&2
			exit 2
		fi
	fi

	if [[ ! -f "$EXPECTED_FILE" || ! -r "$EXPECTED_FILE" ]]; then
		echo "collect-lens-results: --expected-file is not a readable file: $EXPECTED_FILE" >&2
		exit 2
	fi

	expected_file_json="$(cat "$EXPECTED_FILE")"
	persist_validate_json_shape "$expected_file_json" collect-lens-results "--expected-file content" || exit 2
	if ! printf '%s' "$expected_file_json" |
		jq -e 'all(.[]; type == "array" and all(.[]; type == "string"))' >/dev/null 2>&1; then
		echo "collect-lens-results: --expected-file must map each lens name to an ARRAY OF STRINGS: $EXPECTED_FILE" >&2
		exit 2
	fi

	# ONE jq hop per lens, array in and array out. NOTHING is carried
	# through a bash variable, which is what makes the unit's bytes
	# irrelevant: round 3 pulled each unit out through a NUL-delimited read
	# and re-joined them with commas, and every one of F9 (NUL),
	# F10 (comma) and F11 (newline) is a way for that round-trip to be
	# non-injective. The per-unit rules are PERSIST_UNIT_JQ_GATE's, the same
	# filter persist-lens-result.sh applies on the writer side (F3).
	#
	# Only the LENS NAMES still come through a NUL-delimited read, and they
	# are safe there because persist_validate_id's whitelist admits neither
	# a NUL nor a newline.
	#
	# Object key order is preserved by jq, so --expected-file yields the
	# same lens order the file was written in, matching repeated --expected.
	# shellcheck disable=SC2016  # $lens is a jq variable, not a shell one.
	expected_units_filter='.[$lens] | '"$PERSIST_UNIT_JQ_GATE"
	while IFS= read -r -d '' expected_file_lens; do
		persist_validate_id "$expected_file_lens" collect-lens-results name || exit 2
		if ! expected_file_units_json="$(printf '%s' "$expected_file_json" |
			jq -c --arg lens "$expected_file_lens" "$expected_units_filter" 2>/dev/null)"; then
			echo "collect-lens-results: --expected-file: lens '$expected_file_lens' has an invalid unit list (units must be non-empty strings): $EXPECTED_FILE" >&2
			exit 2
		fi
		EXPECTED_LENSES+=("$expected_file_lens")
		EXPECTED_UNITS_JSON+=("$expected_file_units_json")
	done < <(printf '%s' "$expected_file_json" | jq -j 'keys_unsorted[] | . + "\u0000"')
fi

# spawned_attempts_for <lens> -- the --attempts value for <lens>, or 0 when
# absent. Duplicate entries for one lens: last wins (documented in the
# header), matching the "highest attempt the orchestrator spawned"
# semantics.
spawned_attempts_for() {
	local want="$1" result=0
	local j="${#ATTEMPTS_LENSES[@]}"
	local idx=0
	while [[ "$idx" -lt "$j" ]]; do
		if [[ "${ATTEMPTS_LENSES[$idx]}" == "$want" ]]; then
			result="${ATTEMPTS_N[$idx]}"
		fi
		idx=$((idx + 1))
	done
	printf '%s' "$result"
}

units_json_for() {
	# $1 = the stored compact JSON array for this lens (may be empty when no
	# units were assigned). Both transports now store JSON, so there is
	# nothing left to parse here -- which is the point: the only place a unit
	# list is ever turned into or out of text is the one jq hop that read it.
	local stored="$1"
	if [[ -z "$stored" ]]; then
		printf '[]'
	else
		printf '%s' "$stored"
	fi
}

# Parse one attempt file into a JSON object:
#   {units: [...] (last start line seen), progress: [...unit names...],
#    findings: [...], done_status: "completed"|"errored"|"skipped"|null}
# Any line that fails to parse as a JSON object is skipped — the documented
# case is a truncated trailing line, but this is a superset guard so a
# mid-file corruption never crashes the whole collection.
parse_attempt_file() {
	local file="$1"
	jq -c -n '
		{units: [], progress: [], findings: [], done_status: null}
	' | jq -c --slurpfile lines <(
		while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
			[[ -n "$raw_line" ]] || continue
			printf '%s' "$raw_line" | jq -e -c 'select(type == "object")' 2>/dev/null || true
		done <"$file"
	) '
	reduce $lines[] as $l (.;
		if ($l.type // "") == "start" then .units = ($l.units // [])
		elif ($l.type // "") == "progress" then .progress += [$l.unit]
		elif ($l.type // "") == "finding" then .findings += [($l | del(.type, .run_id, .lens, .attempt, .ts))]
		elif ($l.type // "") == "done" then .done_status = ($l.status // null)
		else . end
	)'
}

# running_attempt_for <lens> -- the --running value for <lens>, or 0 when
# the orchestrator did not declare an in-flight attempt for it. A non-zero
# value means "this lens is still working"; the collector must then never
# report a terminal status for it, because terminal is what makes
# --continue stop waiting.
running_attempt_for() {
	local want="$1"
	local result=0
	local j="${#RUNNING_LENSES[@]}"
	local idx=0
	while [[ "$idx" -lt "$j" ]]; do
		if [[ "${RUNNING_LENSES[$idx]}" == "$want" ]]; then
			result="${RUNNING_N[$idx]}"
		fi
		idx=$((idx + 1))
	done
	printf '%s' "$result"
}

# has_attempts_entry_for <lens> -- 1 iff --attempts named this lens.
# `effective` is the orchestrator's attempt count when it declared one
# (R4: the orchestrator OWNS the attempt count) and the on-disk file count
# otherwise. It is never max(spawned, files): a file count is a COUNT and
# an --attempts value is an INDEX, and conflating them made a healthy
# in-flight attempt 3 look like two exhausted attempts.
has_attempts_entry_for() {
	local want="$1"
	local j="${#ATTEMPTS_LENSES[@]}"
	local idx=0
	while [[ "$idx" -lt "$j" ]]; do
		if [[ "${ATTEMPTS_LENSES[$idx]}" == "$want" ]]; then
			printf '1'
			return 0
		fi
		idx=$((idx + 1))
	done
	printf '0'
}

output="{}"
findings_jsonl_accum=""

n="${#EXPECTED_LENSES[@]}"
i=0
while [[ "$i" -lt "$n" ]]; do
	lens="${EXPECTED_LENSES[$i]}"
	assigned_json="$(units_json_for "${EXPECTED_UNITS_JSON[$i]}")"
	spawned="$(spawned_attempts_for "$lens")"
	i=$((i + 1))

	# Collect this lens's attempt files, sorted by attempt number ascending.
	# Exact basename match (no glob, no awk field-splitting): a basename's
	# lens component must be byte-equal to $lens and its attempt component
	# must be a decimal integer. `find` runs unconditionally (2>/dev/null
	# already swallows a missing $run_dir) -- no separate -d guard needed
	# here.
	attempt_files=()
	while IFS= read -r fpath; do
		attempt_files+=("$fpath")
	done < <(
		find "$run_dir" -maxdepth 1 -type f -name '*.jsonl' 2>/dev/null |
			while IFS= read -r fpath; do
				bn="${fpath##*/}"
				[[ "$bn" == *.jsonl ]] || continue
				rest="${bn%.jsonl}" # <lens>.<attempt>
				attempt_num="${rest##*.}"
				name="${rest%.*}"
				[[ "$name" == "$lens" ]] || continue # exact string equality
				[[ "$attempt_num" =~ ^[0-9]+$ ]] || continue
				printf '%s %s\n' "$((10#$attempt_num))" "$fpath"
			done | sort -n -k1,1 | cut -d' ' -f2-
	)

	files="${#attempt_files[@]}"

	# A4: `effective` is the highest attempt INDEX in play, never a file
	# COUNT. attempt_files is sorted ascending, so the last basename carries
	# the max on-disk index. A count is wrong whenever an attempt crashed
	# before writing a byte: a lone `logic.2.jsonl` counts 1 (read as "no
	# respawn happened", `partial`) while the index says 2 (a respawn
	# demonstrably happened, `timed_out`). It is the max of the on-disk index
	# and any `--attempts` the orchestrator declared, because either alone
	# can be the larger: a spawned-but-fileless attempt is only visible in
	# `--attempts`, and an attempt written by a PREVIOUS invocation is only
	# visible on disk.
	max_on_disk=0
	if ((files > 0)); then
		max_bn="${attempt_files[$((files - 1))]##*/}"
		max_rest="${max_bn%.jsonl}"
		max_on_disk="$((10#${max_rest##*.}))"
	fi
	if [[ "$(has_attempts_entry_for "$lens")" == "1" ]] && ((10#$spawned > max_on_disk)); then
		effective="$spawned"
	else
		effective="$max_on_disk"
	fi
	running="$(running_attempt_for "$lens")"

	# Decision table (D2): no done line found (checked below via
	# .done_status) AND files==0 AND effective<=1 -> ZERO-COVERAGE result.
	# With files==0 the max on-disk index is 0, so effective is exactly the
	# declared `--attempts` value (0 when none was declared). Everything else
	# (files>0, or spawned>=2) falls through to the merge/jq block so a
	# spawned-but-fileless attempt still reports timed_out via $effective.
	#
	# The zero-coverage status is `missing` ONLY when the orchestrator has
	# not declared this lens in flight. `--running` is documented (header and
	# the status table above) as an UNCONDITIONAL floor -- a running lens is
	# never terminal AND never `missing` -- but this shortcut sits ABOVE the
	# jq status ladder that was taught about `--running`, so before this fix
	# `--attempts logic:1 --running logic:1` on an empty run dir reported
	# `missing` while `--attempts logic:2 --running logic:2` reported
	# `partial`: the floor held at attempt 2 and not at attempt 1. `missing`
	# is what makes --continue treat a lens as never-spawned and reassign it
	# from scratch, discarding a healthy in-flight attempt 1.
	#
	# The `partial` arm emits the SAME zero-coverage object rather than
	# falling through to the jq block: with files==0 the `attempt_files`
	# array is empty, and bash 3.2 (the repo's declared floor) aborts under
	# `set -u` on `"${empty[@]}"` -- see the G5 comment below.
	#
	# `running` is `running_attempt_for`'s value: 0 when --running did not
	# name this lens, otherwise the in-flight attempt INDEX (>= 1, validated
	# at parse time). It is a number, never the empty string.
	if [[ "$files" -eq 0 && "$effective" -le 1 ]]; then
		if ((10#$running > 0)); then
			zero_coverage_status="partial"
		else
			zero_coverage_status="missing"
		fi
		lens_obj="$(jq -n -c --argjson assigned "$assigned_json" --arg status "$zero_coverage_status" \
			'{status: $status, assigned: ($assigned | length), reviewed: 0, unreviewed: $assigned, findings: []}')"
		output="$(printf '%s' "$output" | jq -c --arg lens "$lens" --argjson obj "$lens_obj" '. + {($lens): $obj}')"
		continue
	fi

	# G5: `attempt_files` is empty exactly in the spawned-but-silent case the
	# `missing` shortcut above deliberately falls through (files==0,
	# effective>=2). Under `set -u`, bash 3.2 -- the repo's declared floor --
	# treats `"${empty[@]}"` as an unbound variable and aborts with no JSON on
	# stdout. The `merged` seed already yields the correct zero-attempt
	# result, so the loop simply must not run.
	#
	# G4: `done_status` is the LATEST attempt's own terminal state, not "last
	# non-null across all attempts". attempt_files is sorted ascending, so the
	# final iteration's value wins whether or not it is null -- a completed
	# attempt 1 no longer masks a start-only attempt 2. progress and findings
	# still merge across every attempt: recovering on-disk work from earlier
	# attempts is the whole point of the disk-first design (R3/R4); only
	# STATUS is latest-attempt-scoped.
	# A8: `done_attempt` is the attempt INDEX that `done_status` came from.
	# Without it the ladder below could not tell a terminal status belonging
	# to the attempt --running names (evidence the retry finished) from one
	# belonging to an EARLIER attempt (stale, and no evidence at all about
	# the retry still in flight). attempt_files is sorted ascending, so the
	# final iteration's pair wins, matching G4's latest-attempt scoping.
	merged="$(jq -n -c '{progress: [], findings: [], done_status: null, done_attempt: 0}')"
	if ((files > 0)); then
		for f in "${attempt_files[@]}"; do
			parsed="$(parse_attempt_file "$f")"
			# Same exact parse the find loop above uses: <lens>.<attempt>.jsonl.
			f_bn="${f##*/}"
			f_rest="${f_bn%.jsonl}"
			f_attempt="$((10#${f_rest##*.}))"
			merged="$(printf '%s' "$merged" | jq -c --argjson p "$parsed" --argjson n "$f_attempt" '
				.progress += $p.progress
				| .findings += $p.findings
				| .done_status = $p.done_status
				| .done_attempt = $n
			')"
		done
	fi

	lens_full="$(printf '%s' "$merged" | jq -c \
		--argjson assigned "$assigned_json" \
		--argjson effective "$effective" \
		--argjson running "$running" \
		--arg lens "$lens" \
		'
		# file/line for the dedup key: prefer explicit .file/.line, else
		# split a combined "file:line" .location (persist-lens-result.sh
		# own wire format) on the last ":".
		def key_file:
			if has("file") then (.file // "")
			else (
				(.location // "") as $loc
				| if ($loc | index(":")) then ($loc | split(":")[:-1] | join(":"))
				  else $loc end
			) end;
		def key_line:
			if has("line") then (.line | tostring)
			else (
				(.location // "") as $loc
				| if ($loc | index(":")) then ($loc | split(":") | last)
				  else "" end
			) end;
		(.progress) as $reviewed_raw
		| ([$assigned[] | select(. as $u | $reviewed_raw | index($u) != null)]) as $reviewed_list
		| ([$assigned[] | select(. as $u | $reviewed_raw | index($u) == null)]) as $unreviewed
		| (
			reduce .findings[] as $f ([];
				(($f | key_file)) as $file
				| (($f | key_line)) as $line
				| (($f.category // "") | ascii_downcase) as $cat
				# Identity policy authority: the header of finding-key.sh.
				# It case-folds `category` (a free-text label whose casing
				# carries no meaning) and deliberately does NOT case-fold
				# `file` (paths are case-sensitive on the filesystems this
				# runs on, and the reconciler folds no case either).
				# Folding the path here made this collector a third,
				# contradictory identity policy that silently dropped a
				# Foo.md:10 / foo.md:10 pair down to one finding.
				| ($file + "|" + $line + "|" + $cat) as $key
				| if any(.[]; ._key == $key) then . else . + [$f + {_key: $key, _file: $file, _line: $line}] end
			)
		) as $dedup_raw
		| ($dedup_raw | map(del(._key, ._file, ._line))) as $dedup_findings
		| ($dedup_raw | map({
			lens: $lens,
			severity: (.severity // ""),
			category: (.category // ""),
			file: ._file,
			line: ._line,
			summary: (.summary // ""),
			evidence: (.evidence // ""),
			suggestion: (.suggestion // "")
		})) as $findings_jsonl
		| (.done_attempt // 0) as $done_attempt
		# A8 reconciled rule: a terminal status wins over --running ONLY when
		# the attempt that recorded it is >= the running attempt number.
		# A `done completed` from attempt 1 says nothing about a silent
		# attempt 2, so it must not retire the lens; a `done` line written BY
		# attempt 2 is direct evidence the retry finished and still wins
		# (C19).
		| (($running == 0) or ($done_attempt >= $running)) as $done_is_current
		| (
			if $done_is_current and .done_status == "completed" then "completed"
			elif $done_is_current and .done_status == "errored" then "errored"
			elif $done_is_current and .done_status == "skipped" then "skipped"
			# $running > 0 means the orchestrator declared this lens still
			# in flight, so a non-terminal `partial` is the honest answer --
			# `timed_out` would make --continue stop waiting on a healthy
			# attempt.
			elif $running > 0 then "partial"
			elif $effective >= 2 then "timed_out"
			else "partial"
			end
		) as $status
		| {
			lens_obj: {status: $status, assigned: ($assigned | length), reviewed: ($reviewed_list | length), unreviewed: $unreviewed, findings: $dedup_findings},
			findings_jsonl: $findings_jsonl
		}
		')"

	lens_obj="$(printf '%s' "$lens_full" | jq -c '.lens_obj')"
	output="$(printf '%s' "$output" | jq -c --arg lens "$lens" --argjson obj "$lens_obj" '. + {($lens): $obj}')"

	if [[ "$FINDINGS_JSONL" -eq 1 ]]; then
		lens_findings_lines="$(printf '%s' "$lens_full" | jq -c '.findings_jsonl[]')"
		if [[ -n "$lens_findings_lines" ]]; then
			findings_jsonl_accum="${findings_jsonl_accum}${lens_findings_lines}"$'\n'
		fi
	fi
done

if [[ "$FINDINGS_JSONL" -eq 1 ]]; then
	printf '%s' "$findings_jsonl_accum"
else
	printf '%s\n' "$output"
fi
