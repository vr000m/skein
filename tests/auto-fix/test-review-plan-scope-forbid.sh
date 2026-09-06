#!/usr/bin/env bash
# Scope-forbid gating for scripts/apply-auto-fix-plan.sh.
#
# Acceptance Criteria covered:
#   AC #6 — an auto-fix whose scope resolves under a forbidden heading
#           (## Requirements, ## Acceptance Criteria, ### Files to Modify,
#           ### New Files to Create, ### Architecture Decisions,
#           ### Integration Seams, or any ### Phase N:) is dropped with
#           status: rejected_scope; finding re-surfaces as advisory.
#
# Adversarial scope-evasion fixtures: indented heading, horizontal rule,
# fenced pseudo-heading, two-digit phase. Each fixture exercises a way the
# detector could be defeated by a naive parser.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

require_plan_applier
require_plan_scope_detect
require_auditor

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# --- AC #6 baseline: symbol_rename whose scope is ## Requirements ---------
case1="$scratch/c1"
mkdir -p "$case1"
make_repo "$case1" >/dev/null
plan_rel="plan.md"
plan_abs="$case1/$plan_rel"
findings="$case1/findings.json"
instantiate_plan_fixture \
	plan-symbol_rename-accept.md "$plan_abs" \
	plan-symbol_rename-reject.jsonl "$findings" \
	"$plan_rel"
git -C "$case1" add "$plan_rel"
git -C "$case1" commit -q -m "add plan"
before="$(head_sha "$case1")"

run_plan_applier "$case1" --plan "$plan_rel" "$findings"

after="$(head_sha "$case1")"
if [[ "$after" != "$before" ]]; then
	fail "scope-Requirements: HEAD advanced (should be rejected_scope)"
else
	pass "scope-Requirements: HEAD preserved"
fi
if grep -Fq -- "- Auto-fix MUST NOT edit this section." "$plan_abs"; then
	pass "scope-Requirements: forbidden section untouched"
else
	fail "scope-Requirements: forbidden section was modified"
fi
manifest="$(find "$case1/.review-plan" -name 'auto-fix-*.json' -print -quit 2>/dev/null || true)"
if [[ -n "${manifest:-}" ]] && grep -q "rejected_scope" "$manifest"; then
	pass "scope-Requirements: manifest status=rejected_scope"
else
	fail "scope-Requirements: manifest missing status=rejected_scope"
	[[ -n "${manifest:-}" ]] && sed 's/^/  /' "$manifest"
fi

# --- Helper: assert plan-scope-detect returns a forbidden heading ---------
# Usage: scope_detect_forbidden <fixture-md> <line> <expected-heading-substr>
# Runs scripts/plan-scope-detect.sh against a fixture copy and asserts the
# output contains <expected-heading-substr>.
scope_detect_resolves_to() {
	local label="$1" fixture="$2" line="$3" needle="$4"
	local d="$scratch/sd-$label"
	mkdir -p "$d"
	cp "$FIXTURES_DIR/$fixture" "$d/plan.md"
	set +e
	local out
	out="$(bash "$PLAN_SCOPE_DETECT" "$d/plan.md" "$line" 2>&1)"
	local rc=$?
	set -e
	if [[ $rc -ne 0 ]]; then
		fail "scope-detect $label: exited $rc"
		echo "$out" | sed 's/^/  /'
		return
	fi
	if grep -Fq "$needle" <<<"$out"; then
		pass "scope-detect $label: resolved to '$needle'"
	else
		fail "scope-detect $label: expected '$needle', got '$out'"
	fi
}

scope_detect_NOT_resolves_to() {
	local label="$1" fixture="$2" line="$3" needle="$4"
	local d="$scratch/sdn-$label"
	mkdir -p "$d"
	cp "$FIXTURES_DIR/$fixture" "$d/plan.md"
	set +e
	local out
	out="$(bash "$PLAN_SCOPE_DETECT" "$d/plan.md" "$line" 2>&1)"
	set -e
	if grep -Fq "$needle" <<<"$out"; then
		fail "scope-detect $label: FALSE positive '$needle' (got '$out')"
	else
		pass "scope-detect $label: correctly did NOT resolve to '$needle'"
	fi
}

# --- Evasion 1: indented pseudo-heading still resolves to Requirements ----
# Line 13 in plan-scope-evasion-indented.md sits below an indented
# "## Looks-Like-Heading-But-Indented" pseudo-heading. The deepest
# column-zero enclosing heading is still "## Requirements".
scope_detect_resolves_to indented plan-scope-evasion-indented.md 13 "## Requirements"

# --- Evasion 2: horizontal rule must not reset the enclosing heading ------
# Line 14 in plan-scope-evasion-horizontal-rule.md sits after a `---`
# rule. The detector must still report "## Requirements".
scope_detect_resolves_to hrule plan-scope-evasion-horizontal-rule.md 14 "## Requirements"

# --- Evasion 3: fenced pseudo-heading must NOT be treated as a heading ----
# Line 13 in plan-scope-evasion-fenced.md is ordinary prose after a fenced
# block containing the literal text "## Requirements". The detector must
# resolve to "## Implementation Checklist", NOT "## Requirements".
scope_detect_NOT_resolves_to fenced plan-scope-evasion-fenced.md 13 "## Requirements"
scope_detect_resolves_to fenced-impl plan-scope-evasion-fenced.md 13 "## Implementation Checklist"

# --- Evasion 3b: indented fenced pseudo-heading keeps forbidden parent ----
# CommonMark permits fences indented by up to three spaces. The column-zero
# pseudo-heading inside the fence must not clear the forbidden Requirements
# parent.
scope_detect_resolves_to indented-fence-parent plan-scope-evasion-indented-fence-parent.md 8 "## Requirements"

# --- Evasion 4: two-digit phase number matches ### Phase \d+: -------------
# Line 14 in plan-scope-evasion-two-digit-phase.md sits under
# "### Phase 10: Tenth". The detector must match the regex regardless of
# digit count and report a phase heading.
scope_detect_resolves_to two-digit plan-scope-evasion-two-digit-phase.md 14 "### Phase 10:"

# --- End-to-end: evasion fixtures fed to the applier are also rejected ---
# A prose_typo whose scope lands on the relevant line of the indented
# fixture must be dropped with rejected_scope.
e2e_rejected_scope() {
	local label="$1" fixture="$2" line="$3"
	local d="$scratch/e2e-$label"
	mkdir -p "$d"
	make_repo "$d" >/dev/null
	cp "$FIXTURES_DIR/$fixture" "$d/plan.md"
	git -C "$d" add plan.md
	git -C "$d" commit -q -m "add plan"
	# Read the target line verbatim so the applier's before-byte-match
	# does not drift the test. The auto-fix preserves the line content
	# (we just want to assert scope-forbid, not the rewrite itself).
	local target
	target="$(awk -v n="$line" 'NR==n' "$d/plan.md")"
	# Escape for JSON.
	local target_json
	target_json="$(printf '%s' "$target" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')"
	cat >"$d/findings.json" <<EOF
{"schema_version":2,"findings":[{"lens":"prose","severity":"Minor","category":"typo","file":"plan.md","line":$line,"summary":"typo","evidence":"","suggestion":"","auto_fix":{"kind":"prose_typo","before":$target_json,"after":$target_json,"scope":"plan.md:$line"},"auto_fix_status":"would_apply"}]}
EOF
	# Auditor-direct assertion: the audit-before-render preview must mark
	# this scope as rejected_scope (matches what the applier will do).
	# Without this, the e2e check below only proves the applier rejects,
	# leaving the auditor's preview unchecked for evasion-style fixtures.
	if bash "$AUDITOR" --skill review-plan --plan "$d/plan.md" "$d/findings.json" >"$d/audited.json" 2>"$d/audit.stderr" &&
		jq -e '.findings[0].auto_fix_status == "rejected_scope"' "$d/audited.json" >/dev/null; then
		pass "e2e $label: auditor status=rejected_scope"
	else
		fail "e2e $label: auditor did not reject"
		sed 's/^/  /' "$d/audit.stderr" 2>/dev/null || true
		[[ -f "$d/audited.json" ]] && sed 's/^/  /' "$d/audited.json"
	fi
	local before
	before="$(head_sha "$d")"
	run_plan_applier "$d" --plan plan.md "$d/findings.json"
	local after
	after="$(head_sha "$d")"
	if [[ "$after" != "$before" ]]; then
		fail "e2e $label: HEAD advanced (should be rejected_scope)"
		return
	fi
	pass "e2e $label: HEAD preserved"
	local manifest
	manifest="$(find "$d/.review-plan" -name 'auto-fix-*.json' -print -quit 2>/dev/null || true)"
	if [[ -n "${manifest:-}" ]] && grep -q "rejected_scope" "$manifest"; then
		pass "e2e $label: manifest status=rejected_scope"
	else
		fail "e2e $label: manifest missing status=rejected_scope"
		[[ -n "${manifest:-}" ]] && sed 's/^/  /' "$manifest"
	fi
}

e2e_rejected_scope indented plan-scope-evasion-indented.md 13
e2e_rejected_scope hrule plan-scope-evasion-horizontal-rule.md 14
e2e_rejected_scope indented-fence-parent plan-scope-evasion-indented-fence-parent.md 8
e2e_rejected_scope two-digit plan-scope-evasion-two-digit-phase.md 14

# --- Phase 5: forbidden parent heading must reject nested child scope ----
# The target line is under `### Detail`, but the enclosing stack also
# includes `## Requirements`. Both auditor and applier must reject based on
# any forbidden heading in the stack, not only the deepest heading.
parent_rejected_scope() {
	local d="$scratch/parent"
	mkdir -p "$d"
	make_repo "$d" >/dev/null
	cp "$FIXTURES_DIR/plan-scope-evasion-parent-heading.md" "$d/plan.md"
	git -C "$d" add plan.md
	git -C "$d" commit -q -m "add plan"
	local line
	line="$(awk '/Auto-fix MUST NOT edit under child detail/ { print NR; exit }' "$d/plan.md")"
	local target_json
	target_json="$(awk -v n="$line" 'NR==n { print }' "$d/plan.md" |
		python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().rstrip("\n")))')"
	cat >"$d/findings.json" <<EOF
{"schema_version":2,"findings":[{"lens":"prose","severity":"Minor","category":"typo","file":"plan.md","line":$line,"summary":"typo","evidence":"","suggestion":"","auto_fix":{"kind":"prose_typo","before":$target_json,"after":$target_json,"scope":"plan.md:$line"},"auto_fix_status":"would_apply"}]}
EOF

	if bash "$AUDITOR" --skill review-plan --plan "$d/plan.md" "$d/findings.json" >"$d/audited.json" 2>"$d/audit.stderr" &&
		jq -e '.findings[0].auto_fix_status == "rejected_scope"' "$d/audited.json" >/dev/null; then
		pass "parent-heading auditor: status=rejected_scope"
	else
		fail "parent-heading auditor: did not reject nested forbidden parent"
		sed 's/^/  /' "$d/audit.stderr" 2>/dev/null || true
		[[ -f "$d/audited.json" ]] && sed 's/^/  /' "$d/audited.json"
	fi

	local before
	before="$(head_sha "$d")"
	run_plan_applier "$d" --plan plan.md "$d/findings.json"
	local after
	after="$(head_sha "$d")"
	if [[ "$after" == "$before" ]]; then
		pass "parent-heading applier: HEAD preserved"
	else
		fail "parent-heading applier: HEAD advanced"
	fi
	local manifest
	manifest="$(find "$d/.review-plan" -name 'auto-fix-*.json' -print -quit 2>/dev/null || true)"
	if [[ -n "${manifest:-}" ]] && grep -q "rejected_scope" "$manifest"; then
		pass "parent-heading applier: manifest status=rejected_scope"
	else
		fail "parent-heading applier: manifest missing status=rejected_scope"
		[[ -n "${manifest:-}" ]] && sed 's/^/  /' "$manifest"
	fi
}
parent_rejected_scope

summary_and_exit
