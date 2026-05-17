#!/usr/bin/env bash
# Phase 5 SKILL.md orchestration contract.
#
# All four mirrors must run the auto-fix eligibility audit before rendering,
# and review-plan mirrors must pass the reviewed plan path into that audit.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

pass_count=0
fail_count=0

pass() {
	echo "PASS: $*"
	pass_count=$((pass_count + 1))
}

fail() {
	echo "FAIL: $*" >&2
	fail_count=$((fail_count + 1))
}

line_of() {
	local file="$1" pattern="$2"
	awk -v pat="$pattern" 'index($0, pat) { print NR; exit }' "$file"
}

check_file() {
	local label="$1" file="$2" audit_literal="$3"
	if [[ ! -f "$file" ]]; then
		fail "$label: missing $file"
		return
	fi

	local audit_line render_line
	audit_line="$(line_of "$file" "$audit_literal")"
	render_line="$(line_of "$file" "Render the annotated JSON")"

	if [[ -n "$audit_line" ]]; then
		pass "$label: expected audit invocation present"
	else
		fail "$label: missing audit invocation: $audit_literal"
	fi

	if [[ -n "$render_line" ]]; then
		pass "$label: render step reference present"
	else
		fail "$label: missing render step reference"
	fi

	if [[ -n "$audit_line" && -n "$render_line" ]]; then
		if ((audit_line < render_line)); then
			pass "$label: audit step appears before render step"
		else
			fail "$label: audit step appears after render step (audit=$audit_line render=$render_line)"
		fi
	fi
}

check_file \
	"claude deep-review" \
	"$REPO_ROOT/.claude/skills/deep-review/SKILL.md" \
	"scripts/audit-auto-fix-eligibility.sh --skill deep-review <envelope>"

check_file \
	"codex deep-review" \
	"$REPO_ROOT/.codex/skills/deep-review/SKILL.md" \
	"scripts/audit-auto-fix-eligibility.sh --skill deep-review <envelope>"

check_file \
	"claude review-plan" \
	"$REPO_ROOT/.claude/skills/review-plan/SKILL.md" \
	"scripts/audit-auto-fix-eligibility.sh --skill review-plan --plan <reviewed-plan> <envelope>"

check_file \
	"codex review-plan" \
	"$REPO_ROOT/.codex/skills/review-plan/SKILL.md" \
	"scripts/audit-auto-fix-eligibility.sh --skill review-plan --plan <reviewed-plan> <envelope>"

echo ""
echo "Summary: $pass_count passed, $fail_count failed"
if [[ $fail_count -ne 0 ]]; then
	exit 1
fi
