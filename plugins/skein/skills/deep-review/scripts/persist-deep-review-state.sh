#!/usr/bin/env bash
# persist-deep-review-state.sh — `/deep-review` state-file persistence.
#
# Usage:
#   scripts/persist-deep-review-state.sh --harness claude|codex --run-id <id> \
#       --base-commit <sha> --head-commit <sha> --diff-hash <sha> \
#       --review-focus-hash <sha-or-empty> [--from-collector] [lenses.json|-]
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
# --from-collector (Phase 2, disk-first streamed lens results): the
# OPERATIVE input path. The orchestrator pipes `collect-lens-results.sh`
# stdout directly into this script's stdin (positional argument, if any, is
# ignored — --from-collector always reads stdin). This is a single
# derivation path: disk attempt files -> collect-lens-results.sh ->
# persist-deep-review-state.sh --from-collector -> `.lenses`, with no
# second writer of the summary. Beyond the generic object-shape check
# already performed below, --from-collector additionally requires every
# top-level value to itself be an object carrying a `status` string field
# (the collector's per-lens contract) — a clearer, earlier error than
# discovering a malformed collector shape only when `--continue` later
# tries to read `.lenses.<lens>.status`.
#
# The positional `lenses.json`/stdin input (no `--from-collector`) is
# retained TEST-ONLY: existing tests construct the raw per-lens shape by
# hand without running the collector. New callers should use
# --from-collector; this script does not otherwise distinguish the two
# input shapes beyond the extra check above.
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
# `mv -f`. Root-anchoring, the CLI required-value check, and the guard +
# atomic-write sequence are all shared with persist-review-state.sh via
# `scripts/lib/persist-common.sh` — see that file for the guard/write
# contract in detail.
#
# Writes to `.deep-review/latest-<harness>.json`, root-anchored via
# `git rev-parse --show-toplevel` (falling back to the current working
# directory when not inside a git worktree).
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/lib/auto-fix-common.sh disable=SC1091
. "$SCRIPT_ROOT/scripts/lib/auto-fix-common.sh"
# shellcheck source=scripts/lib/persist-common.sh disable=SC1091
. "$SCRIPT_ROOT/scripts/lib/persist-common.sh"

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
FROM_COLLECTOR=0

while [[ $# -gt 0 ]]; do
	case "$1" in
	--harness)
		shift
		persist_require_value "$@"
		HARNESS="$1"
		;;
	--run-id)
		shift
		persist_require_value "$@"
		RUN_ID="$1"
		;;
	--base-commit)
		shift
		persist_require_value "$@"
		BASE_COMMIT="$1"
		;;
	--head-commit)
		shift
		persist_require_value "$@"
		HEAD_COMMIT="$1"
		;;
	--diff-hash)
		shift
		persist_require_value "$@"
		DIFF_HASH="$1"
		;;
	--review-focus-hash)
		shift
		persist_require_value "$@"
		REVIEW_FOCUS_HASH="$1"
		REVIEW_FOCUS_HASH_SET=1
		;;
	--from-collector)
		FROM_COLLECTOR=1
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

if [[ "$FROM_COLLECTOR" -eq 1 ]]; then
	# --from-collector always reads stdin; a positional lenses.json is the
	# test-only path and is ignored here (never silently mixed with a
	# collector pipe).
	input="$(cat)"
else
	if [[ "$LENSES_PATH" == "-" ]]; then
		input="$(cat)"
	else
		if [[ ! -f "$LENSES_PATH" ]]; then
			echo "persist-deep-review-state: lenses path '$LENSES_PATH' does not exist" >&2
			exit 2
		fi
		input="$(cat "$LENSES_PATH")"
	fi
fi

persist_validate_json_shape "$input" "persist-deep-review-state" "lenses input" " (one key per lens)" || exit 2
# Duplicate-key rule, on the STATE-FILE side of the wire too (round 8, F7).
# This payload is a per-lens KEYED object whose .lenses.<lens>.status entries
# drive --continue resumption, so a hand-built lenses.json spelling one lens
# twice would silently lose the earlier lens's status. Ordering is deliberate:
# shape first (clearer message for a non-object), duplicates second, both over
# the already-captured $input — never a second read (round 7, F7/F8).
persist_assert_no_duplicate_keys "$input" "persist-deep-review-state" "lenses input" || exit 2

if [[ "$FROM_COLLECTOR" -eq 1 ]]; then
	# Collector contract: every top-level value must itself be an object
	# carrying a "status" string field. This is a clearer, earlier error
	# than discovering a malformed collector shape only when --continue
	# later tries to read `.lenses.<lens>.status`.
	if ! printf '%s' "$input" | jq -e 'all(.[]; type == "object" and (has("status")) and (.status | type == "string"))' >/dev/null 2>&1; then
		echo "persist-deep-review-state: --from-collector input must have one object per lens, each with a string 'status' field (collector contract)" >&2
		exit 2
	fi
fi

ROOT_DIR="$(persist_root_dir)"
# SKILL->STATE-DIR MAPPING (4 sites). The same skill -> state-directory mapping
# (.deep-review for deep-review, .review-plan for review-plan) is spelled out in
# FOUR places, deliberately NOT consolidated: they differ in root source
# ($AF_COMMON_ROOT vs an explicit argument) and in failure exit code (2 vs
# 1), so merging them would be a behaviour change at four call sites for no
# functional gain. A NEW SKILL must therefore be registered in all four:
#   scripts/lib/persist-common.sh      persist_lens_state_dir  (per-run lens attempt dirs)
#   scripts/lib/auto-fix-common.sh     af_manifest_dir         (auto-fix manifests)
#   scripts/persist-deep-review-state.sh  OUT_DIR
#   scripts/persist-review-state.sh       OUT_DIR
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

# Guards + atomic temp-file-then-rename write, shared with
# persist-review-state.sh via scripts/lib/persist-common.sh.
if ! persist_atomic_write "$OUT_DIR" "$OUT_PATH" "$OUT_DIR/.latest-$HARNESS.json.XXXXXX" "$output"; then
	exit 1
fi

printf '%s\n' "$OUT_PATH"
