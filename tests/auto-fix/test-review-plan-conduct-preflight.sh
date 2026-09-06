#!/usr/bin/env bash
# Conduct preflight regression after a /review-plan auto-fix run.
#
# Acceptance Criteria covered:
#   AC #5 — after a plan auto-fix records `marker_pending` and the normal
#           Step 6 marker write runs, conduct preflight (both Codex and
#           Claude harnesses) accepts the plan and `marker_is_stale(plan)`
#           returns False.
#
# Also asserts the unmarked invariant: a plan with `marker_pending` in the
# manifest but no real marker line in the plan file MUST be rejected by
# preflight as unmarked.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/auto-fix/lib.sh disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_plan_applier

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# ---- Run a preflight assertion via the harness's own marker.py -----------
# harness ∈ {.claude, .codex}. Both expose the same compute_plan_hash /
# read_marker / write_marker / marker_is_stale API; Codex uses a
# `conduct.<module>` import prefix, Claude uses bare `<module>`.
preflight_python() {
	local harness="$1" plan="$2" expect="$3" # expect ∈ {accept, reject_unmarked}
	local skill_root="$REPO_ROOT/$harness/skills/conduct"
	if [[ ! -d "$skill_root" ]]; then
		fail "preflight $harness: skill root missing at $skill_root"
		return
	fi
	# Codex tests import from `conduct.<mod>`; the package parent is the
	# `<harness>/skills/` directory.
	local pkg_parent="$REPO_ROOT/$harness/skills"
	local out
	set +e
	out="$(
		PYTHONPATH="$pkg_parent:$skill_root" \
			python3 - "$plan" "$harness" "$expect" <<'PY' 2>&1
import sys
plan_path, harness, expect = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    if harness == ".codex":
        from conduct.marker import marker_is_stale, read_marker
    else:
        from marker import marker_is_stale, read_marker
except Exception as exc:  # pragma: no cover - import failure is a test fail
    print(f"IMPORT_FAIL: {exc}")
    sys.exit(2)
m = read_marker(plan_path)
stale = marker_is_stale(plan_path)
if expect == "accept":
    if m is None:
        print(f"FAIL: expected marker, got None (stale={stale})")
        sys.exit(1)
    if stale is not False:
        print(f"FAIL: expected marker fresh, stale={stale}")
        sys.exit(1)
    print(f"OK: marker fresh, sha={m[1][:12]}")
elif expect == "reject_unmarked":
    if m is not None:
        print(f"FAIL: expected no marker, got {m}")
        sys.exit(1)
    if stale is not None:
        print(f"FAIL: expected stale=None (no marker), got {stale}")
        sys.exit(1)
    print("OK: preflight would reject (no marker)")
else:
    print(f"BAD_EXPECT: {expect}")
    sys.exit(2)
PY
	)"
	local rc=$?
	set -e
	if [[ $rc -ne 0 ]]; then
		fail "preflight $harness ($expect): $out"
	else
		pass "preflight $harness ($expect): $out"
	fi
}

write_marker_python() {
	local harness="$1" plan="$2"
	local skill_root="$REPO_ROOT/$harness/skills/conduct"
	local pkg_parent="$REPO_ROOT/$harness/skills"
	set +e
	local out
	out="$(
		PYTHONPATH="$pkg_parent:$skill_root" \
			python3 - "$plan" "$harness" <<'PY' 2>&1
import sys
plan_path, harness = sys.argv[1], sys.argv[2]
if harness == ".codex":
    from conduct.marker import write_marker
else:
    from marker import write_marker
sha = write_marker(plan_path)
print(sha)
PY
	)"
	local rc=$?
	set -e
	if [[ $rc -ne 0 ]]; then
		fail "write_marker $harness: $out"
		return 1
	fi
	return 0
}

# --- Pre-acceptance: marker_pending → preflight rejects as unmarked -------
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

run_plan_applier "$case1" --plan "$plan_rel" "$findings"

manifest="$(find "$case1/.review-plan" -name 'auto-fix-*.json' -print -quit 2>/dev/null || true)"
if [[ -n "${manifest:-}" ]] && grep -q "marker_pending" "$manifest"; then
	pass "pre-acceptance: manifest records marker_pending"
else
	fail "pre-acceptance: manifest missing marker_pending"
fi

# Both conduct mirrors must reject the plan as unmarked.
preflight_python ".claude" "$plan_abs" "reject_unmarked"
preflight_python ".codex" "$plan_abs" "reject_unmarked"

# --- Acceptance: normal Step 6 marker write → preflight accepts -----------
# Simulate the /review-plan acceptance step by calling write_marker.
if write_marker_python ".claude" "$plan_abs"; then
	pass "acceptance: write_marker (.claude) succeeded"
else
	fail "acceptance: write_marker (.claude) failed"
fi

preflight_python ".claude" "$plan_abs" "accept"
preflight_python ".codex" "$plan_abs" "accept"

summary_and_exit
