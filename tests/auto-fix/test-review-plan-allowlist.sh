#!/usr/bin/env bash
# Allowlist gating for scripts/apply-auto-fix-plan.sh.
#
# Acceptance Criteria covered:
#   AC #5 — allowlisted prose_typo applies, marker_pending recorded.
#   AC #6 — non-allowlisted symbol_rename whose scope resolves under
#           ## Requirements is dropped (rejected_scope handled by
#           test-review-plan-scope-forbid.sh).
#
# This file focuses on allowlist enforcement:
#   - Allowlisted kind (prose_typo) in ordinary prose → applies.
#   - Non-allowlisted kind (e.g. `prose_rewrite`) → status: rejected_kind.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

require_plan_applier

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# --- Case 1: allowlisted prose_typo applies in ordinary prose -------------
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
before_head="$(head_sha "$case1")"

run_plan_applier "$case1" "$findings"

if [[ $LAST_RC -ne 0 ]]; then
	fail "prose_typo-accept: applier exited $LAST_RC"
	echo "$LAST_OUT" | sed 's/^/  /'
else
	pass "prose_typo-accept: applier exited 0"
	if ! grep -Fq "Some the prose with a typo to fix." "$plan_abs"; then
		fail "prose_typo-accept: typo not rewritten in plan body"
	else
		pass "prose_typo-accept: plan body rewritten"
	fi
	manifest="$(find "$case1/.review-plan" -name 'auto-fix-*.json' -print -quit 2>/dev/null || true)"
	if [[ -z "${manifest:-}" ]]; then
		fail "prose_typo-accept: no manifest under .review-plan/"
	else
		if grep -q '"applied"' "$manifest"; then
			pass "prose_typo-accept: manifest status=applied"
		else
			fail "prose_typo-accept: manifest missing status=applied"
			sed 's/^/  /' "$manifest"
		fi
		# AC #5 invariant — marker_pending recorded; no real marker yet.
		if grep -q "marker_pending" "$manifest"; then
			pass "prose_typo-accept: manifest records marker_pending"
		else
			fail "prose_typo-accept: manifest missing marker_pending"
			sed 's/^/  /' "$manifest"
		fi
	fi
	# No real review marker should have been written by the applier itself.
	if grep -Eq '^<!-- reviewed: [0-9]{4}-[0-9]{2}-[0-9]{2} @ [0-9a-f]{40} -->' "$plan_abs"; then
		fail "prose_typo-accept: real review marker written before acceptance"
	else
		pass "prose_typo-accept: no real review marker (pending only)"
	fi
	# HEAD must advance (per-fix commit) but the marker invariant is held
	# by status, not by skipping the commit.
	after_head="$(head_sha "$case1")"
	if [[ "$after_head" == "$before_head" ]]; then
		fail "prose_typo-accept: HEAD did not advance"
	else
		pass "prose_typo-accept: HEAD advanced for applied edit"
	fi
fi

# --- Case 2: non-allowlisted kind → rejected_kind, no edit ----------------
case2="$scratch/c2"
mkdir -p "$case2"
make_repo "$case2" >/dev/null
plan_abs2="$case2/$plan_rel"
findings2="$case2/findings.json"
cp "$FIXTURES_DIR/plan-prose_typo-accept.md" "$plan_abs2"
# Build a non-allowlisted-kind fixture inline.
cat >"$findings2" <<EOF
{"schema_version":2,"findings":[{"lens":"prose","severity":"Minor","category":"rewrite","file":"$plan_rel","line":9,"summary":"non-allowlisted kind","evidence":"","suggestion":"","auto_fix":{"kind":"prose_rewrite","before":"Some teh prose with a typo to fix.","after":"Some the prose with a typo to fix.","scope":"$plan_rel:9"},"auto_fix_status":"would_apply"}]}
EOF
git -C "$case2" add "$plan_rel"
git -C "$case2" commit -q -m "add plan"
before2="$(head_sha "$case2")"

run_plan_applier "$case2" "$findings2"

after2="$(head_sha "$case2")"
if [[ "$after2" != "$before2" ]]; then
	fail "prose_rewrite: HEAD advanced on rejected kind"
else
	pass "prose_rewrite: HEAD preserved"
fi
if grep -Fq "Some teh prose with a typo to fix." "$plan_abs2"; then
	pass "prose_rewrite: plan untouched"
else
	fail "prose_rewrite: plan modified despite rejected_kind"
fi
manifest2="$(find "$case2/.review-plan" -name 'auto-fix-*.json' -print -quit 2>/dev/null || true)"
if [[ -n "${manifest2:-}" ]] && grep -q "rejected_kind" "$manifest2"; then
	pass "prose_rewrite: manifest status=rejected_kind"
else
	fail "prose_rewrite: manifest missing status=rejected_kind"
	[[ -n "${manifest2:-}" ]] && sed 's/^/  /' "$manifest2"
fi

# --- Case 3: allowlisted symbol_rename in ordinary prose applies ----------
case3="$scratch/c3"
mkdir -p "$case3"
make_repo "$case3" >/dev/null
plan_abs3="$case3/$plan_rel"
findings3="$case3/findings.json"
instantiate_plan_fixture \
	plan-symbol_rename-accept.md "$plan_abs3" \
	plan-symbol_rename-accept.jsonl "$findings3" \
	"$plan_rel"
git -C "$case3" add "$plan_rel"
git -C "$case3" commit -q -m "add plan"

run_plan_applier "$case3" "$findings3"

if grep -Fq "_compute_cross_runtime_plan_id" "$plan_abs3"; then
	pass "symbol_rename-accept: rename propagated through plan prose"
else
	fail "symbol_rename-accept: rename did not propagate"
fi

summary_and_exit
