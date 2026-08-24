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
#       --run-id <id> [--expected <lens>:<unit1>,<unit2>,...] [--expected ...] \
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
# declaring "attempt <n> of this lens is STILL IN FLIGHT". A lens named by
# --running is never reported terminal: its status floor is `partial`. This
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
#     spawned <= 1) -> "missing"; unreviewed := the full --expected unit
#     list (or [] if none was given).
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
# persist-lens-result.sh closes from the writer side. Unit names must not
# contain commas — unit lists are comma-joined and unescaped end-to-end
# (writer --units, collector --expected); a comma-bearing unit is rejected
# at the writer boundary rather than silently split (see
# persist-lens-result.sh).
#
# Exit codes:
#   0 — always, once flags validate (a stale/unknown run-id or empty
#       --expected list is a normal "missing" result, not an error).
#   2 — usage error (missing --skill/--run-id, unknown --skill, a malformed
#       --expected/--attempts/--running entry, a --run-id/lens name outside
#       its charset, --root omitted while cwd is not inside a git worktree,
#       or a symlinked run directory at <state-dir>/lenses/<run-id>).
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
    --run-id <id> [--expected <lens>:<unit1>,<unit2>,...] [--expected ...] \
    [--attempts <lens>:<n>] [--attempts ...] [--running <lens>:<n>] \
    [--running ...] [--findings-jsonl]
EOF
}

ROOT=""
SKILL=""
RUN_ID=""
FINDINGS_JSONL=0
declare -a EXPECTED_LENSES=()
declare -a EXPECTED_UNITS_CSV=()
declare -a ATTEMPTS_LENSES=()
declare -a ATTEMPTS_N=()
declare -a RUNNING_LENSES=()
declare -a RUNNING_N=()

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
	--expected)
		shift
		require_value "$@"
		entry="$1"
		if [[ "$entry" != *:* ]]; then
			echo "collect-lens-results: --expected entries must be <lens>:<unit1,unit2,...> (got '$entry')" >&2
			usage
			exit 2
		fi
		expected_lens_name="${entry%%:*}"
		persist_validate_id "$expected_lens_name" collect-lens-results name || exit 2
		EXPECTED_LENSES+=("$expected_lens_name")
		EXPECTED_UNITS_CSV+=("${entry#*:}")
		;;
	--attempts)
		shift
		require_value "$@"
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
		require_value "$@"
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

lenses_dir="$(persist_lens_state_dir "$ROOT" "$SKILL")" || exit 2
run_dir="$lenses_dir/$RUN_ID"

if [[ -d "$run_dir" ]]; then
	if ! af_assert_no_symlink "$run_dir" "$ROOT"; then
		echo "collect-lens-results: refusing to read through a symlink at $run_dir" >&2
		exit 2
	fi
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
	# $1 = comma-separated unit list (may be empty)
	local csv="$1"
	if [[ -z "$csv" ]]; then
		printf '[]'
	else
		printf '%s' "$csv" | jq -R -c 'split(",")'
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
	assigned_json="$(units_json_for "${EXPECTED_UNITS_CSV[$i]}")"
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
	if [[ "$(has_attempts_entry_for "$lens")" == "1" ]]; then
		effective="$spawned"
	else
		effective="$files"
	fi
	running="$(running_attempt_for "$lens")"

	# Decision table (D2): no done line found (checked below via
	# .done_status) AND files==0 AND effective<=1 (i.e. spawned<=1, since
	# effective==files==0 when spawned==0) -> missing. Everything else
	# (files>0, or spawned>=2) falls through to the merge/jq block so a
	# spawned-but-fileless attempt still reports timed_out via $effective.
	if [[ "$files" -eq 0 && "$effective" -le 1 ]]; then
		lens_obj="$(jq -n -c --argjson assigned "$assigned_json" \
			'{status: "missing", assigned: ($assigned | length), reviewed: 0, unreviewed: $assigned, findings: []}')"
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
	merged="$(jq -n -c '{progress: [], findings: [], done_status: null}')"
	if ((files > 0)); then
		for f in "${attempt_files[@]}"; do
			parsed="$(parse_attempt_file "$f")"
			merged="$(printf '%s' "$merged" | jq -c --argjson p "$parsed" '
				.progress += $p.progress
				| .findings += $p.findings
				| .done_status = $p.done_status
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
				| (($file | ascii_downcase) + "|" + $line + "|" + $cat) as $key
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
		| (
			if .done_status == "completed" then "completed"
			elif .done_status == "errored" then "errored"
			elif .done_status == "skipped" then "skipped"
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
