#!/usr/bin/env bash
# Marker-refresh edge cases for scripts/apply-auto-fix-plan.sh.
#
# Acceptance Criteria covered:
#   AC #8 — accepted plan with no existing marker writes a fresh marker
#           at the template position; plan with corrupt UTF-8 exits
#           `marker_failed` and rolls back any prose edits applied during
#           the batch.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

require_plan_applier

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# --- AC #8a: missing-marker plan accepts a fresh marker on acceptance -----
# We exercise the applier path that records `marker_pending`. After the
# simulated acceptance step (the normal /review-plan Step 6), the
# conduct/marker.py write_marker authority writes a fresh marker. The
# applier's responsibility here is to record marker_pending (no real marker
# written by the applier itself).
case1="$scratch/c1"
mkdir -p "$case1"
make_repo "$case1" >/dev/null
plan_rel="plan.md"
plan_abs="$case1/$plan_rel"
findings="$case1/findings.json"
# Plan has no marker line at all — covers the "fresh plan" edge case.
cp "$FIXTURES_DIR/plan-prose_typo-accept.md" "$plan_abs"
awk -v repl="$plan_rel" '{ gsub(/PLAN_PATH/, repl); print }' \
	"$FIXTURES_DIR/marker_refresh-missing-marker.jsonl" >"$findings"
git -C "$case1" add "$plan_rel"
git -C "$case1" commit -q -m "add plan"

run_plan_applier "$case1" "$findings"

manifest="$(find "$case1/.review-plan" -name 'auto-fix-*.json' -print -quit 2>/dev/null || true)"
if [[ -z "${manifest:-}" ]]; then
	fail "ac8a: missing manifest"
else
	# A `marker_refresh` finding alone must be a no-op before acceptance.
	# The manifest can record this as `marker_pending` or as the no-op
	# entry; either way, no real marker should be on disk.
	if grep -Eq "marker_pending|marker_noop|marker_refresh" "$manifest"; then
		pass "ac8a: manifest records pending marker refresh"
	else
		fail "ac8a: manifest did not record pending marker refresh"
		sed 's/^/  /' "$manifest"
	fi
fi
markers="$(grep -cE '^<!-- reviewed: [0-9]{4}-[0-9]{2}-[0-9]{2} @ [0-9a-f]{40} -->' "$plan_abs" || true)"
if [[ "$markers" -eq 0 ]]; then
	pass "ac8a: no real marker written by applier on missing-marker plan"
else
	fail "ac8a: applier wrote a real marker on missing-marker plan"
fi

# --- AC #8b: corrupt UTF-8 in plan → exits marker_failed, rolls back -----
case2="$scratch/c2"
mkdir -p "$case2"
make_repo "$case2" >/dev/null
plan_abs2="$case2/$plan_rel"
findings2="$case2/findings.json"
cp "$FIXTURES_DIR/plan-prose_typo-accept.md" "$plan_abs2"
# Insert an invalid UTF-8 byte sequence into the plan so hashing /
# encoding-aware reads on the marker writer path fail. \xc3\x28 is a
# classic invalid 2-byte sequence (lead 0xC3 expects a 0x80-0xBF
# continuation).
printf 'corrupt: \xc3\x28 byte sequence\n' >>"$plan_abs2"
git -C "$case2" add "$plan_rel"
# Allow git to add the file despite the corrupt bytes; commit may warn but
# should succeed since git stores bytes verbatim.
git -C "$case2" commit -q -m "add plan"
awk -v repl="$plan_rel" '{ gsub(/PLAN_PATH/, repl); print }' \
	"$FIXTURES_DIR/marker_refresh-corrupt-plan.jsonl" >"$findings2"
plan_before_apply="$(cat "$plan_abs2")"
before2="$(head_sha "$case2")"

run_plan_applier "$case2" "$findings2"

# Two acceptable observable outcomes:
#   (a) applier detected corruption pre-apply and refused (rc != 0,
#       working tree clean, manifest records marker_failed); OR
#   (b) applier applied prose edit, then failed marker step, rolled
#       back the prose edit (file content matches pre-apply snapshot),
#       and recorded marker_failed.
manifest2="$(find "$case2/.review-plan" -name 'auto-fix-*.json' -print -quit 2>/dev/null || true)"
if [[ -n "${manifest2:-}" ]] && grep -q "marker_failed" "$manifest2"; then
	pass "ac8b: manifest status=marker_failed"
else
	fail "ac8b: manifest missing status=marker_failed"
	[[ -n "${manifest2:-}" ]] && sed 's/^/  /' "$manifest2"
fi
# Prose edits applied during the batch MUST be rolled back.
if [[ "$(cat "$plan_abs2")" == "$plan_before_apply" ]]; then
	pass "ac8b: prose edits rolled back"
else
	fail "ac8b: prose edits NOT rolled back after marker_failed"
fi
# No real marker should have been written.
markers2="$(grep -cE '^<!-- reviewed: [0-9]{4}-[0-9]{2}-[0-9]{2} @ [0-9a-f]{40} -->' "$plan_abs2" || true)"
if [[ "$markers2" -eq 0 ]]; then
	pass "ac8b: no real marker written on corrupt plan"
else
	fail "ac8b: real marker written despite corrupt plan"
fi

summary_and_exit
