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
# directory when not inside a git worktree). Root-anchoring, the CLI
# required-value check, and the guard + atomic-write sequence are all
# shared with persist-deep-review-state.sh via
# `scripts/lib/persist-common.sh` — see that file for the guard/write
# contract in detail.
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/lib/auto-fix-common.sh disable=SC1091
. "$SCRIPT_ROOT/scripts/lib/auto-fix-common.sh"
# shellcheck source=scripts/lib/persist-common.sh disable=SC1091
. "$SCRIPT_ROOT/scripts/lib/persist-common.sh"

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
		persist_require_value "$@"
		HARNESS="$1"
		;;
	--plan-path)
		shift
		persist_require_value "$@"
		PLAN_PATH="$1"
		;;
	--plan-hash)
		shift
		persist_require_value "$@"
		PLAN_HASH="$1"
		;;
	--run-id)
		shift
		persist_require_value "$@"
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

ROOT_DIR="$(persist_root_dir)"
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

# Guards + atomic temp-file-then-rename write, shared with
# persist-deep-review-state.sh via scripts/lib/persist-common.sh. "Last
# writer wins" for two concurrent runs targeting the same harness's latest
# file is an accepted, unchanged characteristic (same as deep-review's
# `.deep-review/latest-*.json`) — this does not add locking or per-run
# immutable snapshots.
if ! persist_atomic_write "$OUT_DIR" "$OUT_PATH" "$OUT_PATH.tmp.XXXXXX" "$output"; then
	exit 1
fi

printf '%s\n' "$OUT_PATH"
