#!/usr/bin/env bash
# Phase 5 marker freshness check.
#
# Recompute the review marker hash for the Phase 5 plan from the bytes above
# the last column-zero reviewed marker. This prevents phase completion with a
# stale marker after Phase 5 plan edits or review-fix updates.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

plan="$REPO_ROOT/docs/dev_plans/20260515-feature-review-auto-fix-tier.md"

if [[ ! -f "$plan" ]]; then
	fail "plan exists: $plan"
	summary_and_exit
fi

marker_line="$(
	awk '/^<!-- reviewed: [0-9]{4}-[0-9]{2}-[0-9]{2} @ [0-9a-f]{40} -->[[:space:]]*$/ { line = NR } END { if (line) print line }' "$plan"
)"

if [[ -z "$marker_line" ]]; then
	fail "review marker present"
	summary_and_exit
fi
pass "review marker present at line $marker_line"

marker_text="$(awk -v n="$marker_line" 'NR == n { print; exit }' "$plan")"
embedded_hash="$(printf '%s\n' "$marker_text" | sed -E 's/^<!-- reviewed: [0-9]{4}-[0-9]{2}-[0-9]{2} @ ([0-9a-f]{40}) -->[[:space:]]*$/\1/')"

if [[ ! "$embedded_hash" =~ ^[0-9a-f]{40}$ ]]; then
	fail "embedded marker hash parses"
	summary_and_exit
fi
pass "embedded marker hash parses"

computed_hash="$(
	awk -v marker="$marker_line" 'NR < marker { print }' "$plan" |
		git hash-object --stdin
)"

if [[ "$computed_hash" == "$embedded_hash" ]]; then
	pass "marker hash matches content above marker"
else
	fail "marker hash stale"
	echo "  embedded: $embedded_hash"
	echo "  computed: $computed_hash"
fi

summary_and_exit
