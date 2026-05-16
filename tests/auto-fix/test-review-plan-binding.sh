#!/usr/bin/env bash
# Phase 5 binding regressions for scripts/apply-auto-fix-plan.sh.
#
# Contract:
#   - Caller must pass --plan <reviewed-plan>.
#   - finding.file, auto_fix.scope path, and --plan must resolve to the
#     same in-repo file.
#   - auto_fix.before is byte-matched only at the exact auto_fix.scope line.
#   - Path mismatches record rejected_path; cited-line drift records
#     rejected_drift. None of these cases may create an auto-fix commit.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

require_plan_applier

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

json_string() {
	python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().rstrip("\n")))'
}

manifest_status() {
	local repo="$1"
	find "$repo/.review-plan" -name 'auto-fix-*.json' -print -quit 2>/dev/null || true
}

assert_rejected() {
	local label="$1" repo="$2" before_head="$3" expected_status="$4"
	local after_head manifest
	after_head="$(head_sha "$repo")"
	if [[ "$after_head" == "$before_head" ]]; then
		pass "$label: HEAD preserved"
	else
		fail "$label: HEAD advanced"
	fi
	if git -C "$repo" log -1 --format=%s | grep -q '^auto-fix(review-plan):'; then
		fail "$label: auto-fix commit was created"
	else
		pass "$label: no auto-fix commit"
	fi
	manifest="$(manifest_status "$repo")"
	if [[ -n "${manifest:-}" ]] && grep -q "\"$expected_status\"" "$manifest"; then
		pass "$label: manifest status=$expected_status"
	else
		fail "$label: manifest missing status=$expected_status"
		[[ -n "${manifest:-}" ]] && sed 's/^/  /' "$manifest"
	fi
}

write_plan() {
	local path="$1"
	cat >"$path" <<'EOF'
# Binding Fixture

## Implementation Checklist

Target binding text.

Safe trailing prose.
EOF
}

write_envelope() {
	local path="$1" file="$2" scope="$3" line="$4" before="$5" after="$6"
	local before_json after_json
	before_json="$(printf '%s\n' "$before" | json_string)"
	after_json="$(printf '%s\n' "$after" | json_string)"
	cat >"$path" <<EOF
{"schema_version":2,"findings":[{"lens":"prose","severity":"Minor","category":"binding","file":"$file","line":$line,"summary":"binding","evidence":"","suggestion":"","auto_fix":{"kind":"prose_typo","before":$before_json,"after":$after_json,"scope":"$scope"},"auto_fix_status":"would_apply"}]}
EOF
}

# Case 1: finding.file != auto_fix.scope.path -> rejected_path.
d1="$scratch/file-scope-mismatch"
mkdir -p "$d1"
make_repo "$d1" >/dev/null
write_plan "$d1/plan.md"
cp "$d1/plan.md" "$d1/other.md"
git -C "$d1" add plan.md other.md
git -C "$d1" commit -q -m "add plans"
line=5
write_envelope "$d1/findings.json" "other.md" "plan.md:$line" "$line" "Target binding text." "Edited binding text."
before="$(head_sha "$d1")"
run_plan_applier "$d1" --plan plan.md "$d1/findings.json"
assert_rejected "file-scope-mismatch" "$d1" "$before" "rejected_path"

# Case 2: auto_fix.scope.path != --plan -> rejected_path.
d2="$scratch/scope-plan-mismatch"
mkdir -p "$d2"
make_repo "$d2" >/dev/null
write_plan "$d2/plan.md"
cp "$d2/plan.md" "$d2/other.md"
git -C "$d2" add plan.md other.md
git -C "$d2" commit -q -m "add plans"
write_envelope "$d2/findings.json" "plan.md" "other.md:$line" "$line" "Target binding text." "Edited binding text."
before="$(head_sha "$d2")"
run_plan_applier "$d2" --plan plan.md "$d2/findings.json"
assert_rejected "scope-plan-mismatch" "$d2" "$before" "rejected_path"

# Case 3: duplicate before text must not revive v1 find-anywhere behaviour.
d3="$scratch/duplicate-before"
mkdir -p "$d3"
make_repo "$d3" >/dev/null
cat >"$d3/plan.md" <<'EOF'
# Duplicate Fixture

## Implementation Checklist

Duplicate target text.

Safe middle prose.

Duplicate target text.
EOF
git -C "$d3" add plan.md
git -C "$d3" commit -q -m "add plan"
write_envelope "$d3/findings.json" "plan.md" "plan.md:5" 5 "Duplicate target text." "Edited target text."
before="$(head_sha "$d3")"
run_plan_applier "$d3" --plan plan.md "$d3/findings.json"
assert_rejected "duplicate-before" "$d3" "$before" "rejected_drift"
if [[ "$(grep -c 'Duplicate target text.' "$d3/plan.md")" == "2" ]]; then
	pass "duplicate-before: both duplicate lines preserved"
else
	fail "duplicate-before: duplicate lines changed"
fi

# Case 4: cited line drift with a unique non-cited match elsewhere.
d4="$scratch/cited-line-drift"
mkdir -p "$d4"
make_repo "$d4" >/dev/null
cat >"$d4/plan.md" <<'EOF'
# Drift Fixture

## Implementation Checklist

Inserted line shifted the anchor.
Unique moved text.
EOF
git -C "$d4" add plan.md
git -C "$d4" commit -q -m "add plan"
write_envelope "$d4/findings.json" "plan.md" "plan.md:5" 5 "Unique moved text." "Edited moved text."
before="$(head_sha "$d4")"
run_plan_applier "$d4" --plan plan.md "$d4/findings.json"
assert_rejected "cited-line-drift" "$d4" "$before" "rejected_drift"
if grep -Fq "Unique moved text." "$d4/plan.md" && ! grep -Fq "Edited moved text." "$d4/plan.md"; then
	pass "cited-line-drift: non-cited unique match preserved"
else
	fail "cited-line-drift: non-cited line was edited"
fi

summary_and_exit
