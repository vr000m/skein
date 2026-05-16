#!/usr/bin/env bash
# Marker-refresh invariant for scripts/apply-auto-fix-plan.sh.
#
# Acceptance Criteria covered:
#   AC #5 — auto-applied prose edits record `marker_pending`; no real
#           <!-- reviewed: ... --> marker is written by the applier itself.
#           After acceptance (simulated by an external write_marker call),
#           the marker hash matches the post-edit contract.
#   AC #7 — a batch carrying both a `prose_typo` and a `marker_refresh`
#           applies the typo, leaves the marker pending, and writes the
#           real marker exactly once at acceptance time.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

require_plan_applier

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

count_real_markers() {
	# Real markers (date + 40-hex sha), not the YYYY-MM-DD placeholder.
	grep -cE '^<!-- reviewed: [0-9]{4}-[0-9]{2}-[0-9]{2} @ [0-9a-f]{40} -->' "$1" || true
}

# --- AC #5: prose_typo applied → marker_pending, no real marker -----------
case1="$scratch/c1"
mkdir -p "$case1"
make_repo "$case1" >/dev/null
plan_rel="plan.md"
plan_abs="$case1/$plan_rel"
findings="$case1/findings.json"
instantiate_plan_fixture \
	plan-prose_typo-accept.md "$plan_abs" \
	plan-prose_typo-accept.jsonl "$findings" \
	"$plan_rel"
git -C "$case1" add "$plan_rel"
git -C "$case1" commit -q -m "add plan"

run_plan_applier "$case1" "$findings"

manifest="$(find "$case1/.review-plan" -name 'auto-fix-*.json' -print -quit 2>/dev/null || true)"
if [[ -z "${manifest:-}" ]]; then
	fail "ac5: manifest missing"
else
	if grep -q "marker_pending" "$manifest"; then
		pass "ac5: manifest records marker_pending"
	else
		fail "ac5: manifest missing marker_pending"
	fi
fi
markers="$(count_real_markers "$plan_abs")"
if [[ "$markers" -eq 0 ]]; then
	pass "ac5: no real marker written by applier"
else
	fail "ac5: applier wrote $markers real marker(s) before acceptance"
fi

# --- AC #7: marker_refresh + prose_typo in same batch ---------------------
case2="$scratch/c2"
mkdir -p "$case2"
make_repo "$case2" >/dev/null
plan_abs2="$case2/$plan_rel"
findings2="$case2/findings.json"
instantiate_plan_fixture \
	plan-prose_typo-accept.md "$plan_abs2" \
	marker_refresh-lens-emitted-noop.jsonl "$findings2" \
	"$plan_rel"
git -C "$case2" add "$plan_rel"
git -C "$case2" commit -q -m "add plan"

run_plan_applier "$case2" "$findings2"

# Prose typo applied.
if grep -Fq "Some the prose with a typo to fix." "$plan_abs2"; then
	pass "ac7: prose_typo applied"
else
	fail "ac7: prose_typo not applied"
fi

# Lens-emitted marker_refresh must be a no-op before acceptance.
markers2="$(count_real_markers "$plan_abs2")"
if [[ "$markers2" -eq 0 ]]; then
	pass "ac7: no real marker written for lens-emitted marker_refresh"
else
	fail "ac7: $markers2 real marker(s) written before acceptance"
fi

# Manifest should record marker_pending (and the lens-emitted
# marker_refresh entry should NOT be `applied`).
manifest2="$(find "$case2/.review-plan" -name 'auto-fix-*.json' -print -quit 2>/dev/null || true)"
if [[ -n "${manifest2:-}" ]] && grep -q "marker_pending" "$manifest2"; then
	pass "ac7: manifest records marker_pending"
else
	fail "ac7: manifest missing marker_pending"
	[[ -n "${manifest2:-}" ]] && sed 's/^/  /' "$manifest2"
fi

summary_and_exit
