#!/usr/bin/env bash
# persist-deep-review-state.sh — `/deep-review` state-file persistence.
#
# Usage:
#   scripts/persist-deep-review-state.sh --harness claude|codex --run-id <id> \
#       --base-commit <sha> --head-commit <sha> --diff-hash <sha> \
#       --review-focus-hash <sha-or-empty> [lenses.json|-]
#
# Reads the per-lens status/findings data the orchestrator assembles after
# Step 2 completes (before Step 3.5's reconciliation) from the positional
# lenses-path argument, or from stdin when the argument is `-` or omitted.
# This is deliberately the RAW per-lens shape documented in SKILL.md's
# "## Review State" section — a JSON object keyed by lens name (e.g.
# `logic`, `security`, `spec`, `architecture`, `documentation`), each value
# an object such as `{"status": "completed", "model": "opus", "effort":
# "high", "findings": [...]}` or `{"status": "skipped", "reason": "..."}`.
# It is NOT the merged/reconciled v2 envelope `reconcile-findings.sh`
# produces for the rendered report — review-plan's persist-review-state.sh
# persists that post-audit *reconciled* envelope; this script persists
# pre-reconciliation per-lens data. Do not conflate the two schemas or their
# scripts.
#
# The only structural validation performed on the input is that it is valid
# JSON and its top level is a JSON object (`type == "object"`). This script
# does not enforce a fixed lens-name set or per-lens field shape — the
# orchestrator prose in SKILL.md's "## Review State" and "Lens Model Tiers"
# sections is the source of truth for what a well-formed lens entry looks
# like; the caller is responsible for prompting/spawning lenses correctly.
#
# The input is wrapped (not merged in place, unlike persist-review-state.sh,
# whose upstream reconciler already emits a top-level object to extend) as
# the `lenses` key of the final state object, alongside the run metadata,
# exactly matching the suggested schema in SKILL.md's "## Review State"
# section:
#
#   {
#     "schema_version": 1,
#     "run_id": "...", "base_commit": "...", "head_commit": "...",
#     "diff_hash": "...", "review_focus_hash": "...",
#     "lenses": <input>
#   }
#
# `schema_version` is stamped by THIS script (always `1`) — unlike
# persist-review-state.sh, which validates an already-stamped
# `schema_version` from its upstream reconciler (`reconcile-findings.sh`),
# nothing upstream of this script stamps a schema_version onto the raw
# per-lens data, so this script owns it.
#
# `--review-focus-hash` accepts an empty string (`--review-focus-hash ""`)
# for the common case where no plan file / `## Review Focus` section was
# supplied to this run — the flag is still required to be *passed* (so a
# caller cannot silently omit it), but its value may be empty.
#
# Writes atomically: the envelope is written to a temp file created via
# `mktemp` in the same directory as the target, then renamed into place with
# `mv -f`. This is a deliberate departure from persist-review-state.sh's
# documented direct in-place write (that script's non-atomic write is a
# separate, intentionally scoped decision under review elsewhere) — this new
# script goes straight to atomic temp+rename semantics rather than repeat
# the same gap.
#
# Writes to `.deep-review/latest-<harness>.json`, root-anchored via
# `git rev-parse --show-toplevel` (falling back to the current working
# directory when not inside a git worktree, matching
# `scripts/apply-auto-fix-plan.sh`'s and `persist-review-state.sh`'s existing
# precedent).
#
# Exit codes:
#   0  — wrote the state file. Prints the absolute path written to stdout.
#   2  — usage error (missing/invalid argument, malformed input JSON, jq
#        unavailable). Prints a `persist-deep-review-state: <reason>` usage
#        message to stderr.
#   1  — best-effort write failed (permissions, disk full, target path
#        blocked by a non-directory component, symlink guard tripped, temp
#        file could not be created/renamed, etc). Prints exactly
#        `Could not persist findings JSON: <reason>` to stderr — this exact
#        string is the caller's (SKILL.md Step 5's) signal to surface the
#        warning in the rendered report and force full-verbose rendering
#        for the run regardless of `--verbose`.
#
# Dependencies: git, jq.

set -euo pipefail

usage() {
	cat >&2 <<'EOF'
usage: scripts/persist-deep-review-state.sh --harness claude|codex --run-id <id> --base-commit <sha> --head-commit <sha> --diff-hash <sha> --review-focus-hash <sha-or-empty> [lenses.json|-]
EOF
}

HARNESS=""
RUN_ID=""
BASE_COMMIT=""
HEAD_COMMIT=""
DIFF_HASH=""
REVIEW_FOCUS_HASH=""
REVIEW_FOCUS_HASH_SET=0
LENSES_PATH="-"

while [[ $# -gt 0 ]]; do
	case "$1" in
	--harness)
		shift
		[[ $# -gt 0 ]] || {
			usage
			exit 2
		}
		HARNESS="$1"
		;;
	--run-id)
		shift
		[[ $# -gt 0 ]] || {
			usage
			exit 2
		}
		RUN_ID="$1"
		;;
	--base-commit)
		shift
		[[ $# -gt 0 ]] || {
			usage
			exit 2
		}
		BASE_COMMIT="$1"
		;;
	--head-commit)
		shift
		[[ $# -gt 0 ]] || {
			usage
			exit 2
		}
		HEAD_COMMIT="$1"
		;;
	--diff-hash)
		shift
		[[ $# -gt 0 ]] || {
			usage
			exit 2
		}
		DIFF_HASH="$1"
		;;
	--review-focus-hash)
		shift
		[[ $# -gt 0 ]] || {
			usage
			exit 2
		}
		REVIEW_FOCUS_HASH="$1"
		REVIEW_FOCUS_HASH_SET=1
		;;
	--help | -h)
		usage
		exit 0
		;;
	-)
		LENSES_PATH="-"
		;;
	*)
		if [[ -n "$LENSES_PATH" && "$LENSES_PATH" != "-" ]]; then
			echo "persist-deep-review-state: unexpected extra argument '$1'" >&2
			usage
			exit 2
		fi
		LENSES_PATH="$1"
		;;
	esac
	shift
done

if [[ "$HARNESS" != "claude" && "$HARNESS" != "codex" ]]; then
	echo "persist-deep-review-state: --harness must be claude or codex" >&2
	usage
	exit 2
fi

if [[ -z "$RUN_ID" || -z "$BASE_COMMIT" || -z "$HEAD_COMMIT" || -z "$DIFF_HASH" ]]; then
	echo "persist-deep-review-state: --run-id, --base-commit, --head-commit, and --diff-hash are all required" >&2
	usage
	exit 2
fi

if [[ "$REVIEW_FOCUS_HASH_SET" -ne 1 ]]; then
	echo "persist-deep-review-state: --review-focus-hash is required (pass an empty string '' when no Review Focus section applies)" >&2
	usage
	exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
	echo "persist-deep-review-state: jq is required" >&2
	exit 2
fi

if [[ "$LENSES_PATH" == "-" ]]; then
	input="$(cat)"
else
	if [[ ! -f "$LENSES_PATH" ]]; then
		echo "persist-deep-review-state: lenses path '$LENSES_PATH' does not exist" >&2
		exit 2
	fi
	input="$(cat "$LENSES_PATH")"
fi

if ! printf '%s' "$input" | jq -e . >/dev/null 2>&1; then
	echo "persist-deep-review-state: lenses input is not valid JSON" >&2
	exit 2
fi

# jq without --slurp processes a stream of top-level JSON values, applying
# the filter to each one independently — so "{} {}" (two concatenated JSON
# documents) would pass the check above (its exit status reflects only the
# last value) and then also pass through the extend step below, silently
# producing multiple concatenated JSON objects as $output. Reject anything
# but exactly one top-level document up front.
doc_count="$(printf '%s' "$input" | jq -s 'length')"
if [[ "$doc_count" != "1" ]]; then
	echo "persist-deep-review-state: lenses input must be exactly one JSON document (got $doc_count)" >&2
	exit 2
fi

if ! printf '%s' "$input" | jq -e 'type == "object"' >/dev/null 2>&1; then
	echo "persist-deep-review-state: lenses input must be a JSON object (one key per lens)" >&2
	exit 2
fi

# Root-anchor. Falls back to cwd when not inside a git worktree, matching
# scripts/apply-auto-fix-plan.sh's and persist-review-state.sh's existing
# WORKTREE_ROOT precedent.
if WORKTREE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
	ROOT_DIR="$WORKTREE_ROOT"
else
	ROOT_DIR="$(pwd)"
fi

OUT_DIR="$ROOT_DIR/.deep-review"
OUT_PATH="$OUT_DIR/latest-$HARNESS.json"

output="$(printf '%s' "$input" | jq \
	--argjson schema_version 1 \
	--arg run_id "$RUN_ID" \
	--arg base_commit "$BASE_COMMIT" \
	--arg head_commit "$HEAD_COMMIT" \
	--arg diff_hash "$DIFF_HASH" \
	--arg review_focus_hash "$REVIEW_FOCUS_HASH" \
	'{
		schema_version: $schema_version,
		run_id: $run_id,
		base_commit: $base_commit,
		head_commit: $head_commit,
		diff_hash: $diff_hash,
		review_focus_hash: $review_focus_hash,
		lenses: .
	}')" || {
	echo "Could not persist findings JSON: failed to build state object from lenses input" >&2
	exit 1
}

# Symlink guards (defense-in-depth): refuse to write through a pre-existing
# symlink at either the target file or its parent directory. `.deep-review/`
# is gitignored, but a *tracked* symlink at that exact path would still
# materialize on checkout — without this guard a malicious clone could point
# it outside the repo and have this script's write clobber an arbitrary
# user-writable file.
if [[ -L "$OUT_DIR" ]]; then
	echo "Could not persist findings JSON: refusing to write through a symlink at $OUT_DIR" >&2
	exit 1
fi

if [[ -L "$OUT_PATH" ]]; then
	echo "Could not persist findings JSON: refusing to write through a symlink at $OUT_PATH" >&2
	exit 1
fi

# By this point $OUT_PATH is confirmed not to be a symlink (checked above).
# If it still exists but is not a regular file (e.g. a directory), `mv -f`
# below would silently succeed by moving the temp file *inside* it instead
# of replacing it — a false success that leaves the advertised path
# unusable. Reject that case up front instead of attempting the write.
if [[ -e "$OUT_PATH" && ! -f "$OUT_PATH" ]]; then
	echo "Could not persist findings JSON: refusing to overwrite non-regular-file target at $OUT_PATH" >&2
	exit 1
fi

if ! mkdir_err=$({ mkdir -p "$OUT_DIR"; } 2>&1); then
	echo "Could not persist findings JSON: ${mkdir_err:-could not create $OUT_DIR}" >&2
	exit 1
fi

# Atomic write: temp file in the same directory, then rename into place.
TMP_PATH=""
cleanup_tmp() {
	if [[ -n "$TMP_PATH" && -e "$TMP_PATH" ]]; then
		rm -f "$TMP_PATH" 2>/dev/null || true
	fi
}
trap cleanup_tmp EXIT

if ! TMP_PATH="$(mktemp "$OUT_DIR/.latest-$HARNESS.json.XXXXXX" 2>&1)"; then
	tmp_err="$TMP_PATH"
	TMP_PATH=""
	echo "Could not persist findings JSON: ${tmp_err:-could not create temp file in $OUT_DIR}" >&2
	exit 1
fi

if ! write_err=$({ printf '%s\n' "$output" >"$TMP_PATH"; } 2>&1); then
	echo "Could not persist findings JSON: ${write_err:-could not write $TMP_PATH}" >&2
	exit 1
fi

if ! mv_err=$({ mv -f "$TMP_PATH" "$OUT_PATH"; } 2>&1); then
	echo "Could not persist findings JSON: ${mv_err:-could not rename $TMP_PATH to $OUT_PATH}" >&2
	exit 1
fi

trap - EXIT

printf '%s\n' "$OUT_PATH"
