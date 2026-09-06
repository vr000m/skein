#!/usr/bin/env bash
# Phase 5 plan-scope-detect mode isolation.
#
# Existing two-argument mode must keep returning the deepest enclosing
# heading. New --stack mode must return the full enclosing heading stack,
# outermost-first, one heading per line, with a terminating newline and no
# trailing blank line. For unknown scope, --stack emits empty stdout and
# exits 0.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/auto-fix/lib.sh disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_plan_scope_detect

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

assert_output() {
	local label="$1" expected_file="$2" actual_file="$3"
	if diff -u "$expected_file" "$actual_file" >"$scratch/$label.diff"; then
		pass "$label"
	else
		fail "$label"
		sed 's/^/  /' "$scratch/$label.diff"
	fi
}

copy_fixture() {
	local fixture="$1" dest="$2"
	cp "$FIXTURES_DIR/$fixture" "$dest"
}

# Two-arg mode: exact deepest-heading outputs from the existing fixture set.
copy_fixture plan-scope-evasion-indented.md "$scratch/indented.md"
bash "$PLAN_SCOPE_DETECT" "$scratch/indented.md" 13 >"$scratch/indented.actual"
printf '## Requirements\n' >"$scratch/indented.expected"
assert_output "two-arg indented preserves deepest heading" "$scratch/indented.expected" "$scratch/indented.actual"

copy_fixture plan-scope-evasion-horizontal-rule.md "$scratch/hrule.md"
bash "$PLAN_SCOPE_DETECT" "$scratch/hrule.md" 14 >"$scratch/hrule.actual"
printf '## Requirements\n' >"$scratch/hrule.expected"
assert_output "two-arg horizontal-rule preserves deepest heading" "$scratch/hrule.expected" "$scratch/hrule.actual"

copy_fixture plan-scope-evasion-fenced.md "$scratch/fenced.md"
bash "$PLAN_SCOPE_DETECT" "$scratch/fenced.md" 13 >"$scratch/fenced.actual"
printf '## Implementation Checklist\n' >"$scratch/fenced.expected"
assert_output "two-arg fenced pseudo-heading ignored" "$scratch/fenced.expected" "$scratch/fenced.actual"

copy_fixture plan-scope-evasion-two-digit-phase.md "$scratch/phase10.md"
bash "$PLAN_SCOPE_DETECT" "$scratch/phase10.md" 14 >"$scratch/phase10.actual"
printf '### Phase 10: Tenth\n' >"$scratch/phase10.expected"
assert_output "two-arg two-digit phase preserved" "$scratch/phase10.expected" "$scratch/phase10.actual"

# Parent fixture: two-arg returns only the deepest child heading.
copy_fixture plan-scope-evasion-parent-heading.md "$scratch/parent.md"
parent_line="$(awk '/Auto-fix MUST NOT edit under child detail/ { print NR; exit }' "$scratch/parent.md")"
bash "$PLAN_SCOPE_DETECT" "$scratch/parent.md" "$parent_line" >"$scratch/parent-two-arg.actual"
printf '### Detail\n' >"$scratch/parent-two-arg.expected"
assert_output "two-arg parent fixture returns deepest child" "$scratch/parent-two-arg.expected" "$scratch/parent-two-arg.actual"

# --stack returns the full hierarchy, outermost first.
bash "$PLAN_SCOPE_DETECT" --stack "$scratch/parent.md" "$parent_line" >"$scratch/parent-stack.actual"
printf '# Parent Scope Fixture\n## Requirements\n### Detail\n' >"$scratch/parent-stack.expected"
assert_output "stack mode returns parent and child headings" "$scratch/parent-stack.expected" "$scratch/parent-stack.actual"

# --stack skips headings inside fenced blocks just like two-arg mode.
bash "$PLAN_SCOPE_DETECT" --stack "$scratch/fenced.md" 13 >"$scratch/fenced-stack.actual"
printf '# Task: Fenced Pseudo-Heading Evasion\n## Implementation Checklist\n' >"$scratch/fenced-stack.expected"
assert_output "stack mode ignores fenced pseudo-heading" "$scratch/fenced-stack.expected" "$scratch/fenced-stack.actual"

# Non-contiguous heading levels: a document jumping from # H1 directly to
# ### H3 (skipping ## H2) must NOT emit a blank line for the unset H2 slot.
# The documented schema is "one heading per line, no trailing blank line";
# awk's auto-vivify-on-read would have silently violated it.
cat >"$scratch/noncontig.md" <<'EOF'
# Top
### Skipped H2

target line under H3
EOF
bash "$PLAN_SCOPE_DETECT" --stack "$scratch/noncontig.md" 4 >"$scratch/noncontig.actual"
printf '# Top\n### Skipped H2\n' >"$scratch/noncontig.expected"
assert_output "stack mode skips unpopulated heading levels (no blank line)" "$scratch/noncontig.expected" "$scratch/noncontig.actual"

# Unknown before first heading: empty stdout, exit 0.
cat >"$scratch/unknown.md" <<'EOF'
intro before headings

# Later Heading
EOF
if bash "$PLAN_SCOPE_DETECT" --stack "$scratch/unknown.md" 1 >"$scratch/unknown.actual" 2>"$scratch/unknown.stderr"; then
	if [[ ! -s "$scratch/unknown.actual" ]]; then
		pass "stack mode unknown emits empty stdout"
	else
		fail "stack mode unknown emitted output"
		sed 's/^/  /' "$scratch/unknown.actual"
	fi
else
	fail "stack mode unknown exited non-zero"
	sed 's/^/  /' "$scratch/unknown.stderr"
fi

summary_and_exit
