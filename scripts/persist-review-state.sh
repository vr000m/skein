#!/usr/bin/env bash
# persist-review-state.sh — `/review-plan` state-file persistence.
#
# Usage:
#   scripts/persist-review-state.sh --harness claude|codex --plan-path <path> \
#       --plan-hash <sha1> --run-id <id> [envelope.json|-]
#
# Reads the reconciled v2 finding envelope Step 3's `reconcile-findings.sh`
# already emits (`{schema_version: 2, summary, findings, related}`) from the
# positional envelope-path argument, or from stdin when the argument is `-`
# or omitted. Extends the envelope with exactly three additive top-level
# fields — `plan_path`, `plan_hash`, `run_id` — no wrapper object and no
# second `schema_version`. Writes the result to
# `.review-plan/latest-<harness>.json`, root-anchored via
# `git rev-parse --show-toplevel` (falling back to the current working
# directory when not inside a git worktree, matching
# `scripts/apply-auto-fix-plan.sh`'s existing precedent).
#
# `plan_hash` is a snapshot of the plan at Step 3 (reconciliation) time — the
# caller computes it (typically `git hash-object <plan>`) and passes it in;
# this script never re-derives or re-hashes it.
#
# Exit codes:
#   0  — wrote the state file. Prints the absolute path written to stdout.
#   2  — usage error (missing/invalid argument, malformed input JSON, jq
#        unavailable). Prints a `persist-review-state: <reason>` usage
#        message to stderr.
#   1  — best-effort write failed (permissions, disk full, target path
#        blocked by a non-directory component, etc). Prints exactly
#        `Could not persist findings JSON: <reason>` to stderr — this exact
#        string is the caller's (SKILL.md Step 5's) signal to surface the
#        warning in the rendered report and force full-verbose rendering
#        for the run regardless of `--verbose`.
#
# Dependencies: git, jq.

set -euo pipefail

usage() {
	cat >&2 <<'EOF'
usage: scripts/persist-review-state.sh --harness claude|codex --plan-path <path> --plan-hash <sha1> --run-id <id> [envelope.json|-]
EOF
}

HARNESS=""
PLAN_PATH=""
PLAN_HASH=""
RUN_ID=""
ENVELOPE_PATH="-"

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
	--plan-path)
		shift
		[[ $# -gt 0 ]] || {
			usage
			exit 2
		}
		PLAN_PATH="$1"
		;;
	--plan-hash)
		shift
		[[ $# -gt 0 ]] || {
			usage
			exit 2
		}
		PLAN_HASH="$1"
		;;
	--run-id)
		shift
		[[ $# -gt 0 ]] || {
			usage
			exit 2
		}
		RUN_ID="$1"
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
			echo "persist-review-state: unexpected extra argument '$1'" >&2
			usage
			exit 2
		fi
		ENVELOPE_PATH="$1"
		;;
	esac
	shift
done

if [[ "$HARNESS" != "claude" && "$HARNESS" != "codex" ]]; then
	echo "persist-review-state: --harness must be claude or codex" >&2
	usage
	exit 2
fi

if [[ -z "$PLAN_PATH" || -z "$PLAN_HASH" || -z "$RUN_ID" ]]; then
	echo "persist-review-state: --plan-path, --plan-hash, and --run-id are all required" >&2
	usage
	exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
	echo "persist-review-state: jq is required" >&2
	exit 2
fi

if [[ "$ENVELOPE_PATH" == "-" ]]; then
	input="$(cat)"
else
	if [[ ! -f "$ENVELOPE_PATH" ]]; then
		echo "persist-review-state: envelope path '$ENVELOPE_PATH' does not exist" >&2
		exit 2
	fi
	input="$(cat "$ENVELOPE_PATH")"
fi

if ! printf '%s' "$input" | jq -e . >/dev/null 2>&1; then
	echo "persist-review-state: envelope is not valid JSON" >&2
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
	echo "persist-review-state: envelope must be exactly one JSON document (got $doc_count)" >&2
	exit 2
fi

# Must run before the schema_version lookup below: a non-object top-level
# value (e.g. a JSON array) would otherwise make the `.schema_version` jq
# lookup itself error out non-zero, crashing the script uninformatively
# under `set -e` instead of failing with a clear usage message.
if ! printf '%s' "$input" | jq -e 'type == "object"' >/dev/null 2>&1; then
	echo "persist-review-state: envelope must be a JSON object" >&2
	exit 2
fi

schema_version="$(printf '%s' "$input" | jq -r '.schema_version // empty')"
if [[ "$schema_version" != "2" ]]; then
	echo "persist-review-state: schema_version mismatch (got ${schema_version:-missing}, expected 2)" >&2
	exit 2
fi

# schema_version == 2 alone does not guarantee a well-formed reconciler v2
# envelope — {"schema_version": 2} would pass the check above with
# everything else missing. Enforce the documented contract
# {schema_version: 2, summary: {...}, findings: [...], related: [...]}
# before persisting, since the footer this file backs points at unusable
# state otherwise.
if ! printf '%s' "$input" | jq -e 'has("summary") and has("findings") and has("related") and (.summary | type == "object") and (.findings | type == "array") and (.related | type == "array")' >/dev/null 2>&1; then
	echo "persist-review-state: envelope missing required top-level keys (summary/findings/related) or wrong type" >&2
	exit 2
fi

# Root-anchor. Falls back to cwd when not inside a git worktree, matching
# scripts/apply-auto-fix-plan.sh's existing WORKTREE_ROOT precedent.
if WORKTREE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
	ROOT_DIR="$WORKTREE_ROOT"
else
	ROOT_DIR="$(pwd)"
fi

OUT_DIR="$ROOT_DIR/.review-plan"
OUT_PATH="$OUT_DIR/latest-$HARNESS.json"

output="$(printf '%s' "$input" | jq \
	--arg plan_path "$PLAN_PATH" \
	--arg plan_hash "$PLAN_HASH" \
	--arg run_id "$RUN_ID" \
	'. + {plan_path: $plan_path, plan_hash: $plan_hash, run_id: $run_id}')" || {
	echo "Could not persist findings JSON: failed to extend envelope with plan_path/plan_hash/run_id" >&2
	exit 1
}

# Symlink guard (defense-in-depth): refuse to write through a pre-existing
# symlink at either the target file or its parent directory. `.review-plan/`
# is gitignored, but a *tracked* symlink at that exact path would still
# materialize on checkout — without this guard a malicious clone could point
# it outside the repo and have this script's write clobber an arbitrary
# user-writable file. Must run before the temp-file write below so a
# symlinked target is rejected before we ever stage a rename into it.
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

# Atomic write: stage the output in a temp file created in the same directory
# as $OUT_PATH (same filesystem, so the final `mv` is an atomic rename), then
# rename it into place only after the write succeeds. This is what makes the
# write atomic — the target path is never truncated or partially written, so
# a killed/interrupted process leaves the previous good $OUT_PATH untouched.
# This fixes crash/interrupt corruption only; "last writer wins" for two
# concurrent runs targeting the same harness's latest file is an accepted,
# unchanged characteristic (same as deep-review's `.deep-review/latest-*.json`)
# — this does not add locking or per-run immutable snapshots.
TMP_PATH=""
cleanup_tmp() {
	if [[ -n "$TMP_PATH" && -e "$TMP_PATH" ]]; then
		rm -f "$TMP_PATH"
	fi
}
trap cleanup_tmp EXIT

if ! TMP_PATH=$(mktemp "$OUT_PATH.tmp.XXXXXX" 2>&1); then
	tmp_err="$TMP_PATH"
	TMP_PATH=""
	echo "Could not persist findings JSON: ${tmp_err:-could not create temp file for $OUT_PATH}" >&2
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

TMP_PATH=""
printf '%s\n' "$OUT_PATH"
