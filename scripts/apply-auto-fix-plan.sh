#!/usr/bin/env bash
# apply-auto-fix-plan.sh — `/review-plan` trivial-tier auto-fix applier.
#
# Usage:
#   scripts/apply-auto-fix-plan.sh <annotated-envelope.json>
#
# Reads a reconciled v2 finding envelope annotated with `auto_fix_status`
# (typically produced by `scripts/audit-auto-fix-eligibility.sh --skill
# review-plan`). For each finding whose status is `would_apply` AND whose
# kind is in the `review-plan` allowlist, the applier:
#
#   1. Re-verifies eligibility (kind in allowlist; scope-forbid heading
#      check via `scripts/plan-scope-detect.sh`). Mismatch → drops to
#      surfaced with a specific reject status.
#   2. For `marker_refresh`: NO-OP. The real review marker is only written
#      at the normal `/review-plan` acceptance step (`yes` / `waive`).
#      Lens-emitted marker_refresh blocks in the batch produce
#      `status: marker_pending` and never publish a marker.
#   3. Asserts the file:line still byte-matches `auto_fix.before` (drift).
#   4. Saves a `git hash-object -w` blob of every touched path (rollback).
#   5. Rewrites the line `before` → `after` in place.
#   6. Stages the file and commits with subject
#      `auto-fix(review-plan): <kind> at <file>:<line>` and trailer
#      `Auto-Fixed-By: review-plan`. No test gate — plans are markdown.
#
# If any apply hits a marker-hash failure (corrupt plan, malformed UTF-8 at
# the contract section), the applier rolls back ALL prose edits applied
# during this batch and exits with `status: marker_failed`.
#
# Writes a manifest at `.review-plan/auto-fix-<unix>.json` listing every
# attempted fix.
#
# Dependencies: git, jq, awk.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/lib/auto-fix-common.sh disable=SC1091
. "$SCRIPT_ROOT/scripts/lib/auto-fix-common.sh"
# shellcheck disable=SC2034  # consumed by sourced auto-fix-common.sh
AF_ALLOWLIST_PATH="$SCRIPT_ROOT/scripts/auto-fix-allowlist.json"

if WORKTREE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
	ROOT_DIR="$WORKTREE_ROOT"
else
	ROOT_DIR="$(pwd)"
fi
# shellcheck disable=SC2034  # consumed by sourced auto-fix-common.sh
AF_COMMON_ROOT="$ROOT_DIR"

SKILL="review-plan"

# Scope-forbid list per the dev plan. Matched against `plan-scope-detect.sh`
# output. `### Phase N:` is matched as a regex (any digit count) below; all
# other entries are exact (column-zero, normalised) string matches.
FORBIDDEN_HEADINGS=(
	"## Requirements"
	"## Acceptance Criteria"
	"### Files to Modify"
	"### New Files to Create"
	"### Architecture Decisions"
	"### Integration Seams"
)

usage() {
	cat >&2 <<'EOF'
usage: scripts/apply-auto-fix-plan.sh <annotated-envelope.json>
EOF
}

ENVELOPE_PATH=""

while [[ $# -gt 0 ]]; do
	case "$1" in
	--help | -h)
		usage
		exit 0
		;;
	-)
		ENVELOPE_PATH="-"
		;;
	*)
		if [[ -n "$ENVELOPE_PATH" && "$ENVELOPE_PATH" != "-" ]]; then
			echo "apply-auto-fix-plan: multiple envelope paths" >&2
			exit 2
		fi
		ENVELOPE_PATH="$1"
		;;
	esac
	shift
done

if [[ -z "$ENVELOPE_PATH" ]]; then
	usage
	exit 2
fi

af_have_jq

if [[ "$ENVELOPE_PATH" == "-" ]]; then
	envelope="$(cat)"
else
	envelope="$(cat "$ENVELOPE_PATH")"
fi

schema_version="$(printf '%s' "$envelope" | jq -r '.schema_version // empty')"
if [[ "$schema_version" != "2" ]]; then
	echo "apply-auto-fix-plan: schema_version mismatch (got ${schema_version:-missing}, expected 2)" >&2
	exit 2
fi

af_manifest_init "$SKILL"

resolve_path() {
	local p="$1"
	if [[ "$p" = /* ]]; then
		printf '%s\n' "$p"
	elif [[ -e "$p" ]]; then
		printf '%s\n' "$p"
	else
		printf '%s\n' "$ROOT_DIR/$p"
	fi
}

# Parse `auto_fix.scope` of the form `<path>:<start>[-<end>]`. Echo
# `<path>\t<start>\t<end>` or empty on failure. v1 only supports single-line
# spans; this function returns end == start when no range is present.
parse_plan_scope() {
	local scope="$1"
	local path start end
	if [[ "$scope" =~ ^(.+):([0-9]+)-([0-9]+)$ ]]; then
		path="${BASH_REMATCH[1]}"
		start="${BASH_REMATCH[2]}"
		end="${BASH_REMATCH[3]}"
	elif [[ "$scope" =~ ^(.+):([0-9]+)$ ]]; then
		path="${BASH_REMATCH[1]}"
		start="${BASH_REMATCH[2]}"
		end="${BASH_REMATCH[2]}"
	else
		return 1
	fi
	printf '%s\t%s\t%s\n' "$path" "$start" "$end"
}

# Return 0 if the heading text is in the scope-forbid set, 1 otherwise.
heading_is_forbidden() {
	local heading="$1"
	# Phase N — match any digit count.
	if [[ "$heading" =~ ^###[[:space:]]+Phase[[:space:]]+[0-9]+: ]]; then
		return 0
	fi
	local h
	for h in "${FORBIDDEN_HEADINGS[@]}"; do
		if [[ "$heading" == "$h" ]]; then
			return 0
		fi
	done
	return 1
}

# Roll back every commit + restore every blob recorded during this batch.
# Called when marker_failed is hit mid-batch.
APPLIED_COMMITS=()     # newest-last; reset HEAD by `git reset --hard <parent_of_first>`
APPLIED_BLOBS_PATHS=() # parallel arrays: index i is one applied fix
APPLIED_BLOBS_SHAS=()

rollback_batch() {
	# Restore blobs in reverse order so the first applied file ends up
	# pointing at its original blob even if multiple fixes touched it.
	local i
	if [[ "${#APPLIED_COMMITS[@]}" -gt 0 ]]; then
		# git reset --hard to the parent of the first applied commit.
		local first="${APPLIED_COMMITS[0]}"
		local parent
		parent="$(git -C "$ROOT_DIR" rev-parse "$first^" 2>/dev/null || true)"
		if [[ -n "$parent" ]]; then
			git -C "$ROOT_DIR" reset --hard "$parent" >/dev/null 2>&1 || true
		fi
	fi
	for ((i = ${#APPLIED_BLOBS_PATHS[@]} - 1; i >= 0; i--)); do
		af_restore_blob "${APPLIED_BLOBS_PATHS[$i]}" "${APPLIED_BLOBS_SHAS[$i]}"
	done
}

findings_json="$(printf '%s' "$envelope" | jq -c '.findings[]? | select(.auto_fix_status == "would_apply" and (has("auto_fix")))')"

if [[ -z "$findings_json" ]]; then
	af_manifest_write
	echo "apply-auto-fix-plan: no would_apply findings; manifest at $(af_manifest_path)" >&2
	exit 0
fi

while IFS= read -r finding; do
	[[ -n "$finding" ]] || continue
	kind="$(printf '%s' "$finding" | jq -r '.auto_fix.kind')"
	before="$(printf '%s' "$finding" | jq -r '.auto_fix.before')"
	after="$(printf '%s' "$finding" | jq -r '.auto_fix.after')"
	scope="$(printf '%s' "$finding" | jq -r '.auto_fix.scope')"
	file="$(printf '%s' "$finding" | jq -r '.file // ""')"
	line="$(printf '%s' "$finding" | jq -r '(.line // "") | tostring')"

	# Re-check allowlist (defence in depth).
	if ! af_allowlist_contains "$SKILL" "$kind"; then
		af_manifest_record "$kind" "$file" "$line" "rejected_kind" "" ""
		continue
	fi

	# marker_refresh is a no-op pre-acceptance. Step 7 of /review-plan writes
	# the real marker after the user accepts or waives remaining findings.
	if [[ "$kind" == "marker_refresh" ]]; then
		af_manifest_record "$kind" "$file" "$line" "marker_pending" "" ""
		continue
	fi

	# Parse scope: `<path>:<start>[-<end>]`. v1 single-line only.
	parsed="$(parse_plan_scope "$scope" || true)"
	if [[ -z "$parsed" ]]; then
		af_manifest_record "$kind" "$file" "$line" "rejected_scope" "" ""
		continue
	fi
	IFS=$'\t' read -r scope_path scope_start scope_end <<<"$parsed"
	if [[ "$scope_start" != "$scope_end" ]]; then
		# Multi-line spans not supported in v1.
		af_manifest_record "$kind" "$file" "$line" "rejected_multiline" "" ""
		continue
	fi

	abs_path="$(resolve_path "$scope_path")"
	if [[ ! -f "$abs_path" ]]; then
		af_manifest_record "$kind" "$file" "$line" "drift" "" ""
		continue
	fi

	# Validate the plan is UTF-8 before touching it. A corrupt plan can still
	# parse line-by-line but later defeat `git hash-object` semantics; refuse
	# to apply and trigger a marker_failed rollback rather than commit
	# nonsense. This MUST run before drift / scope-forbid: a corrupt-plan
	# batch must surface as marker_failed regardless of what other reasons
	# the fix might have been rejected for.
	if ! iconv -f utf-8 -t utf-8 "$abs_path" >/dev/null 2>&1; then
		af_manifest_record "$kind" "$file" "$line" "marker_failed" "" ""
		rollback_batch
		af_manifest_write
		echo "apply-auto-fix-plan: marker_failed on $abs_path; batch rolled back; manifest at $(af_manifest_path)" >&2
		exit 1
	fi

	# Scope-forbid check via plan-scope-detect at the cited scope line.
	heading="$("$SCRIPT_ROOT/scripts/plan-scope-detect.sh" "$abs_path" "$scope_start" 2>/dev/null || echo "unknown")"
	if heading_is_forbidden "$heading"; then
		af_manifest_record "$kind" "$file" "$line" "rejected_scope" "" ""
		continue
	fi

	# Drift / locate check. The cited `<path>:<line>` is informational —
	# the source of truth is the `before` block. We search the file for an
	# exact-line match against the stripped `before`; if it appears exactly
	# once we use that line as the apply target. Zero matches or multiple
	# matches → drift (ambiguous or stale block, refuse to apply).
	stripped_before="${before%$'\n'}"
	if [[ "$stripped_before" == *$'\n'* ]]; then
		# Multi-line before — reject; v1 plan auto-fix is single-line.
		af_manifest_record "$kind" "$file" "$line" "rejected_multiline" "" ""
		continue
	fi
	match_line="$(awk -v needle="$stripped_before" '
		$0 == needle { print NR; count++ }
		END { exit (count == 1 ? 0 : 1) }
	' "$abs_path" 2>/dev/null || true)"
	if [[ -z "$match_line" || ! "$match_line" =~ ^[0-9]+$ ]]; then
		af_manifest_record "$kind" "$file" "$line" "drift" "" ""
		continue
	fi
	# Re-run scope-forbid at the located line: an attacker (or a buggy lens)
	# could cite an innocuous scope line while the matching content lives
	# inside a forbidden section. Refuse to apply in that case too.
	located_heading="$("$SCRIPT_ROOT/scripts/plan-scope-detect.sh" "$abs_path" "$match_line" 2>/dev/null || echo "unknown")"
	if heading_is_forbidden "$located_heading"; then
		af_manifest_record "$kind" "$file" "$line" "rejected_scope" "" ""
		continue
	fi
	apply_line="$match_line"

	# Save pre-apply blob (rollback handle).
	before_sha="$(af_save_blob "$abs_path")"
	APPLIED_BLOBS_PATHS+=("$abs_path")
	APPLIED_BLOBS_SHAS+=("$before_sha")

	# Apply single-line replacement at the located line.
	if ! af_apply_replacement "$abs_path" "$apply_line" "$before" "$after"; then
		af_restore_blob "$abs_path" "$before_sha"
		# Pop the last-recorded blob since we rolled it back already.
		unset 'APPLIED_BLOBS_PATHS[${#APPLIED_BLOBS_PATHS[@]}-1]'
		unset 'APPLIED_BLOBS_SHAS[${#APPLIED_BLOBS_SHAS[@]}-1]'
		af_manifest_record "$kind" "$file" "$line" "drift" "" "$before_sha"
		continue
	fi

	git -C "$ROOT_DIR" add -- "$abs_path"

	subject="auto-fix($SKILL): $kind at $file:$line"
	trailer="Auto-Fixed-By: $SKILL"
	commit_sha="$(af_commit_one "$subject" "$trailer")"
	APPLIED_COMMITS+=("$commit_sha")
	# Record `status: "applied"` AND a separate `marker_pending: true` flag:
	# the prose edit lands as a commit but the real `<!-- reviewed: ... -->`
	# marker is intentionally not refreshed here — Step 7 of /review-plan
	# publishes the marker exactly once after the user accepts or waives
	# remaining findings.
	af_manifest_record "$kind" "$file" "$line" "applied" "$commit_sha" "$before_sha" "marker_pending"
done <<<"$findings_json"

af_manifest_write
echo "apply-auto-fix-plan: manifest written to $(af_manifest_path)" >&2
