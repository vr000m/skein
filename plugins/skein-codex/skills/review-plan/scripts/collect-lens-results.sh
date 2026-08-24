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
#       --run-id <id> [--expected <lens>:<unit1>,<unit2>,...] [--expected ...]
#
# --root is OPTIONAL (unlike persist-lens-result.sh's explicit-always
# --root): when omitted this script root-anchors the same way
# persist-review-state.sh/persist-deep-review-state.sh do, via
# `persist_root_dir` (git worktree root, falling back to cwd when not
# inside a git worktree). The plan's abbreviated collector signature names
# only --skill/--run-id/--expected; this script accepts an explicit --root
# too when a caller already has it resolved (e.g. the same orchestrator
# invocation that resolved it for persist-lens-result.sh), but does not
# require it.
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
# (<state-dir>/lenses/<run-id>/<lens>.<N>.jsonl, N ascending):
#   - No run-id directory, or no attempt file at all for this lens
#     -> "missing"; unreviewed := the full --expected unit list (or [] if
#     none was given).
#   - Otherwise, take the `done` line (if any) from the HIGHEST-numbered
#     attempt file that has one:
#       done.status == "completed" -> "completed"
#       done.status == "errored"   -> "errored"
#       done.status == "skipped"   -> "skipped" (orchestrator-emitted, on a
#         deliberately-skipped lens's behalf; terminal for --continue)
#   - No `done` line found in any attempt:
#       exactly 1 attempt file observed -> "partial" (still mid-run; a
#         respawn on `unreviewed` is expected to follow)
#       2+ attempt files observed -> "timed_out" (a respawn already
#         happened and still produced no completion signal; one-respawn
#         means this is terminal for the current orchestrator invocation)
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
# Exit codes:
#   0 — always, once flags validate (a stale/unknown run-id or empty
#       --expected list is a normal "missing" result, not an error).
#   2 — usage error (missing --skill/--run-id, unknown --skill, or a
#       malformed --expected entry).
#
# Dependencies: jq.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/persist-common.sh disable=SC1091
. "$SCRIPT_DIR/lib/persist-common.sh"

usage() {
	cat >&2 <<'EOF'
usage: scripts/collect-lens-results.sh [--root <repo-root>] --skill deep-review|review-plan \
    --run-id <id> [--expected <lens>:<unit1>,<unit2>,...] [--expected ...]
EOF
}

ROOT=""
SKILL=""
RUN_ID=""
declare -a EXPECTED_LENSES=()
declare -a EXPECTED_UNITS_CSV=()

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
		EXPECTED_LENSES+=("${entry%%:*}")
		EXPECTED_UNITS_CSV+=("${entry#*:}")
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

if ! command -v jq >/dev/null 2>&1; then
	echo "collect-lens-results: jq is required" >&2
	exit 2
fi

lenses_dir="$(persist_lens_state_dir "$ROOT" "$SKILL")" || exit 2
run_dir="$lenses_dir/$RUN_ID"

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

output="{}"

n="${#EXPECTED_LENSES[@]}"
i=0
while [[ "$i" -lt "$n" ]]; do
	lens="${EXPECTED_LENSES[$i]}"
	assigned_json="$(units_json_for "${EXPECTED_UNITS_CSV[$i]}")"
	i=$((i + 1))

	if [[ ! -d "$run_dir" ]]; then
		lens_obj="$(jq -n -c --argjson assigned "$assigned_json" \
			'{status: "missing", assigned: ($assigned | length), reviewed: 0, unreviewed: $assigned, findings: []}')"
		output="$(printf '%s' "$output" | jq -c --arg lens "$lens" --argjson obj "$lens_obj" '. + {($lens): $obj}')"
		continue
	fi

	# Collect this lens's attempt files, sorted by attempt number ascending.
	# Sort key is derived from the basename only (not the full path) --
	# --root may itself contain dots (e.g. a mktemp path like
	# /tmp/tmp.XXXXXXXXXX on Linux), which would otherwise throw off the
	# "second-to-last dot field" split.
	mapfile -t attempt_files < <(find "$run_dir" -maxdepth 1 -type f -name "$lens.*.jsonl" 2>/dev/null |
		while IFS= read -r fpath; do
			bn="$(basename "$fpath")"
			# basename: <lens>.<attempt>.jsonl -- attempt is the second-to-last dot field
			n_fields=$(awk -F'.' '{print NF}' <<<"$bn")
			attempt_num=$(awk -F'.' -v nf="$n_fields" '{print $(nf-1)}' <<<"$bn")
			printf '%s %s\n' "$attempt_num" "$fpath"
		done | sort -n -k1,1 | cut -d' ' -f2-)

	if [[ "${#attempt_files[@]}" -eq 0 ]]; then
		lens_obj="$(jq -n -c --argjson assigned "$assigned_json" \
			'{status: "missing", assigned: ($assigned | length), reviewed: 0, unreviewed: $assigned, findings: []}')"
		output="$(printf '%s' "$output" | jq -c --arg lens "$lens" --argjson obj "$lens_obj" '. + {($lens): $obj}')"
		continue
	fi

	merged="$(jq -n -c '{progress: [], findings: [], done_status: null}')"
	for f in "${attempt_files[@]}"; do
		parsed="$(parse_attempt_file "$f")"
		merged="$(printf '%s' "$merged" | jq -c --argjson p "$parsed" '
			.progress += $p.progress
			| .findings += $p.findings
			| .done_status = (if $p.done_status != null then $p.done_status else .done_status end)
		')"
	done

	attempt_count="${#attempt_files[@]}"

	lens_obj="$(printf '%s' "$merged" | jq -c \
		--argjson assigned "$assigned_json" \
		--argjson attempt_count "$attempt_count" \
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
				(($f | key_file) | ascii_downcase) as $file
				| (($f | key_line)) as $line
				| (($f.category // "") | ascii_downcase) as $cat
				| ($file + "|" + $line + "|" + $cat) as $key
				| if any(.[]; ._key == $key) then . else . + [$f + {_key: $key}] end
			) | map(del(._key))
		) as $dedup_findings
		| (
			if .done_status == "completed" then "completed"
			elif .done_status == "errored" then "errored"
			elif .done_status == "skipped" then "skipped"
			elif $attempt_count >= 2 then "timed_out"
			else "partial"
			end
		) as $status
		| {status: $status, assigned: ($assigned | length), reviewed: ($reviewed_list | length), unreviewed: $unreviewed, findings: $dedup_findings}
		')"

	output="$(printf '%s' "$output" | jq -c --arg lens "$lens" --argjson obj "$lens_obj" '. + {($lens): $obj}')"
done

printf '%s\n' "$output"
