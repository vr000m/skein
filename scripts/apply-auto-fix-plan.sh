#!/usr/bin/env bash
# apply-auto-fix-plan.sh — `/review-plan` trivial-tier auto-fix applier.
#
# Usage:
#   scripts/apply-auto-fix-plan.sh --plan <reviewed-plan> <annotated-envelope.json>
#
# Reads a reconciled v2 finding envelope annotated with `auto_fix_status`
# (typically produced by `scripts/audit-auto-fix-eligibility.sh --skill
# review-plan`). For each finding whose status is `would_apply` AND whose
# kind is in the `review-plan` allowlist, the applier:
#
#   1. Re-verifies eligibility (kind in allowlist; scope-forbid heading
#      check via `scripts/plan-scope-detect.sh --stack`) and triple path
#      equality (`finding.file` == `auto_fix.scope` path == `--plan`).
#      Mismatch → drops to surfaced with a specific reject status.
#   2. For `marker_refresh`: NO-OP. The real review marker is only written
#      at the normal `/review-plan` acceptance step (`yes` / `waive`).
#      Lens-emitted marker_refresh blocks in the batch produce
#      `status: marker_pending` and never publish a marker.
#   3. Asserts the exact `auto_fix.scope` line still byte-matches
#      `auto_fix.before` (`status: rejected_drift` on mismatch). No
#      find-anywhere fallback is allowed.
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
# The lib owns AF_ALLOWLIST_PATH; the caller owns AF_COMMON_ROOT.

if WORKTREE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
	ROOT_DIR="$WORKTREE_ROOT"
else
	ROOT_DIR="$(pwd)"
fi
# shellcheck disable=SC2034  # required by lib's af_manifest_init
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
usage: scripts/apply-auto-fix-plan.sh --plan <reviewed-plan> <annotated-envelope.json>
EOF
}

ENVELOPE_PATH=""
REVIEWED_PLAN=""

while [[ $# -gt 0 ]]; do
	case "$1" in
	--plan)
		shift
		[[ $# -gt 0 ]] || {
			usage
			exit 2
		}
		REVIEWED_PLAN="$1"
		;;
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
if [[ -z "$REVIEWED_PLAN" ]]; then
	echo "apply-auto-fix-plan: --plan <reviewed-plan> is required" >&2
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
# Advisory lock: serialise concurrent applier runs in the same repo. See
# apply-auto-fix-code.sh for rationale.
AF_LOCKDIR="$ROOT_DIR/.git/auto-fix-plan.lock"
if ! mkdir "$AF_LOCKDIR" 2>/dev/null; then
	echo "apply-auto-fix-plan: another applier appears to be running (lock at $AF_LOCKDIR); refusing to start" >&2
	exit 8
fi
# Ensure the manifest is always flushed and the lock is always released,
# even on an unexpected early exit under `set -euo pipefail`.
trap 'af_manifest_write; rmdir "$AF_LOCKDIR" 2>/dev/null || true' EXIT

# Resolve a scope-supplied path against ROOT_DIR with a containment guard.
# Rejects absolute paths and any `..` segment to prevent semi-trusted lens
# output from directing writes outside the repo.
resolve_path() {
	local p="$1"
	if [[ -z "$p" || "$p" = /* ]]; then
		return 1
	fi
	if [[ "$p" =~ (^|/)\.\.(/|$) ]]; then
		return 1
	fi
	printf '%s\n' "$ROOT_DIR/$p"
}

resolve_plan_arg() {
	local p="$1"
	if [[ -z "$p" ]]; then
		return 1
	fi
	if [[ "$p" = /* ]]; then
		printf '%s\n' "$p"
	else
		printf '%s\n' "$ROOT_DIR/$p"
	fi
}

canonical_existing_path() {
	local p="$1"
	if [[ ! -e "$p" ]]; then
		return 1
	fi
	local dir base
	dir="$(dirname "$p")"
	base="$(basename "$p")"
	dir="$(cd "$dir" && pwd -P)"
	printf '%s/%s\n' "$dir" "$base"
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

stack_is_forbidden() {
	local path="$1"
	local line="$2"
	local heading
	while IFS= read -r heading; do
		[[ -n "$heading" ]] || continue
		if heading_is_forbidden "$heading"; then
			return 0
		fi
	done < <("$SCRIPT_ROOT/scripts/plan-scope-detect.sh" --stack "$path" "$line" 2>/dev/null || true)
	return 1
}

reviewed_plan_path="$(resolve_plan_arg "$REVIEWED_PLAN")" || {
	echo "apply-auto-fix-plan: invalid --plan path: $REVIEWED_PLAN" >&2
	exit 2
}
reviewed_plan_canon="$(canonical_existing_path "$reviewed_plan_path")" || {
	echo "apply-auto-fix-plan: reviewed plan not found: $REVIEWED_PLAN" >&2
	exit 2
}

# Roll back every commit + restore every blob recorded during this batch.
# Called when marker_failed is hit mid-batch.
APPLIED_COMMITS=()     # newest-last; unwound via `git revert` in reverse order
APPLIED_BLOBS_PATHS=() # parallel arrays: index i is one applied fix
APPLIED_BLOBS_SHAS=()

rollback_batch() {
	# Unwind each applier commit with `git revert --no-edit` in newest-first
	# order. Using revert (not `git reset --hard`) preserves any unrelated
	# commits that landed on this ref between the first applier commit and
	# now, AND preserves any uncommitted operator work in the worktree —
	# `reset --hard` would silently discard both.
	local i sha
	for ((i = ${#APPLIED_COMMITS[@]} - 1; i >= 0; i--)); do
		sha="${APPLIED_COMMITS[$i]}"
		git -C "$ROOT_DIR" revert --no-edit "$sha" >/dev/null 2>&1 || true
	done
	# Restore saved blobs in reverse order so a path touched twice still ends
	# up at the original pre-batch content. The revert above takes the
	# committed state back; this restores any unstaged residue (defence in
	# depth — revert+stage clean should already match).
	for ((i = ${#APPLIED_BLOBS_PATHS[@]} - 1; i >= 0; i--)); do
		af_restore_blob "${APPLIED_BLOBS_PATHS[$i]}" "${APPLIED_BLOBS_SHAS[$i]}"
	done
}

# Refuse to start the batch if the worktree has uncommitted changes — the
# rollback path relies on `git revert` which composes cleanly only on a
# clean tree. A dirty tree at start signals concurrent operator work that
# we don't want to interleave with applier commits.
if ! git -C "$ROOT_DIR" diff --quiet || ! git -C "$ROOT_DIR" diff --cached --quiet; then
	echo "apply-auto-fix-plan: worktree has uncommitted changes; commit or stash before running" >&2
	exit 7
fi

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

	if ! abs_path="$(resolve_path "$scope_path")"; then
		af_manifest_record "$kind" "$file" "$line" "rejected_path" "" ""
		continue
	fi
	if ! finding_abs_path="$(resolve_path "$file")"; then
		af_manifest_record "$kind" "$file" "$line" "rejected_path" "" ""
		continue
	fi
	if [[ ! -f "$abs_path" ]]; then
		af_manifest_record "$kind" "$file" "$line" "rejected_drift" "" ""
		continue
	fi
	if [[ ! -f "$finding_abs_path" ]]; then
		af_manifest_record "$kind" "$file" "$line" "rejected_drift" "" ""
		continue
	fi
	scope_canon="$(canonical_existing_path "$abs_path")" || {
		af_manifest_record "$kind" "$file" "$line" "rejected_drift" "" ""
		continue
	}
	finding_canon="$(canonical_existing_path "$finding_abs_path")" || {
		af_manifest_record "$kind" "$file" "$line" "rejected_drift" "" ""
		continue
	}
	if [[ "$scope_canon" != "$finding_canon" || "$finding_canon" != "$reviewed_plan_canon" ]]; then
		af_manifest_record "$kind" "$file" "$line" "rejected_path" "" ""
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
	# A UTF-8 BOM (EF BB BF) is a valid byte sequence but throws off
	# line-anchored matchers and downstream marker-hash semantics. iconv
	# accepts it; we don't. Refuse to apply rather than commit through it.
	if [[ "$(head -c 3 "$abs_path" 2>/dev/null | od -An -tx1 | tr -d ' ')" == "efbbbf" ]]; then
		af_manifest_record "$kind" "$file" "$line" "marker_failed" "" ""
		rollback_batch
		af_manifest_write
		echo "apply-auto-fix-plan: UTF-8 BOM detected on $abs_path; batch rolled back; manifest at $(af_manifest_path)" >&2
		exit 1
	fi

	# Scope-forbid check via plan-scope-detect stack mode at the cited scope
	# line. Any forbidden ancestor rejects the fix.
	if stack_is_forbidden "$abs_path" "$scope_start"; then
		af_manifest_record "$kind" "$file" "$line" "rejected_scope" "" ""
		continue
	fi

	# Drift check. The scope line is authoritative: the before block must
	# byte-match exactly at auto_fix.scope's line. There is no unique-match
	# anywhere fallback.
	stripped_before="${before%$'\n'}"
	if [[ "$stripped_before" == *$'\n'* ]]; then
		# Multi-line before — reject; v1 plan auto-fix is single-line.
		af_manifest_record "$kind" "$file" "$line" "rejected_multiline" "" ""
		continue
	fi
	actual_line="$(awk -v target="$scope_start" '
		NR == target { print; found = 1; exit }
		END { if (!found) exit 1 }
	' "$abs_path" 2>/dev/null || true)"
	if [[ "$actual_line" != "$stripped_before" ]]; then
		af_manifest_record "$kind" "$file" "$line" "rejected_drift" "" ""
		continue
	fi
	exact_match_count="$(awk -v needle="$stripped_before" '
		$0 == needle { count++ }
		END { print count + 0 }
	' "$abs_path")"
	if [[ "$exact_match_count" -ne 1 ]]; then
		af_manifest_record "$kind" "$file" "$line" "rejected_drift" "" ""
		continue
	fi
	apply_line="$scope_start"

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
