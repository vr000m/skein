#!/usr/bin/env bash
# test-goal-field-schema.sh — Phase 1 acceptance: the optional `**Goal:**`
# phase-contract slot is documented in dev-plan/SKILL.md (Required Sections
# item 4) and present in dev-plan/template.md's phase block.
#
# Plan: docs/dev_plans/20260707-feature-conduct-phase-goal-field.md, Phase 1
# "**Goal:** schema in dev-plan". Acceptance criteria under test:
#   - Optional `**Goal:**` slot exists in dev-plan schema + template.
#   - Documented as optional (absent -> current/no-op behaviour).
#   - Documented as the dual-consumer design-intent source (conduct
#     implementer/test-writer injection + review-gauntlet fixer Guardrail 1).
#   - Documented above the marker with the immutability consequence
#     (adding/editing it on an already-reviewed plan invalidates the marker
#     hash and forces re-review).
#
# This is a pure documentation/schema check — no runtime substitution is
# exercised here (that is Phase 2's `{{PHASE_GOAL}}` injection, covered by
# tests/gauntlet/test-goal-injection.sh).
#
# Exit codes: 0 all assertions pass, 1 any assertion fails.

set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
SKILL_MD="$ROOT_DIR/plugins/skein/skills/dev-plan/SKILL.md"
TEMPLATE_MD="$ROOT_DIR/plugins/skein/skills/dev-plan/template.md"

pass_count=0
fail_count=0

pass() {
	echo "PASS: $1"
	pass_count=$((pass_count + 1))
}

fail() {
	echo "FAIL: $1"
	fail_count=$((fail_count + 1))
}

require_file() {
	local file="$1"
	if [[ ! -f "$file" ]]; then
		fail "file missing: $file"
		return 1
	fi
	return 0
}

# assert_grep FILE PATTERN LABEL
# PATTERN is passed to `grep -Eq` (extended regex, case-sensitive) against
# the whole file. Fails loudly with the pattern so a missing doc line is
# easy to diagnose.
assert_grep() {
	local file="$1" pattern="$2" label="$3"
	if grep -Eq -- "$pattern" "$file"; then
		pass "$label"
	else
		fail "$label (pattern not found: $pattern in $file)"
	fi
}

require_file "$SKILL_MD" || exit 1
require_file "$TEMPLATE_MD" || exit 1

# --- dev-plan/SKILL.md: Required Sections item 4 -----------------------

assert_grep "$SKILL_MD" '\*\*Goal:\*\*' \
	"SKILL.md Required Sections mentions \`**Goal:**\`"

assert_grep "$SKILL_MD" '\*\*Goal:\*\*[^.]*\(optional\)' \
	"SKILL.md documents \`**Goal:**\` as optional"

assert_grep "$SKILL_MD" 'design.intent' \
	"SKILL.md documents \`**Goal:**\` as design intent"

assert_grep "$SKILL_MD" 'conduct.*\{\{PHASE_GOAL\}\}|\{\{PHASE_GOAL\}\}.*conduct' \
	"SKILL.md cross-references conduct's \`{{PHASE_GOAL}}\` injection as a consumer"

assert_grep "$SKILL_MD" 'review-gauntlet' \
	"SKILL.md cross-references review-gauntlet's fixer as a consumer"

assert_grep "$SKILL_MD" 'invalidate' \
	"SKILL.md notes the marker-hash invalidation consequence"

# --- dev-plan/template.md: phase-block prose + example -----------------

assert_grep "$TEMPLATE_MD" '\*\*Goal:\*\*.*\(optional\)' \
	"template.md documents \`**Goal:**\` as optional in the phase-contract prose"

assert_grep "$TEMPLATE_MD" 'above the review marker' \
	"template.md places \`**Goal:**\` above the review marker"

assert_grep "$TEMPLATE_MD" '\*\*Goal:\*\*.*invalidat' \
	"template.md notes editing \`**Goal:**\` after review invalidates the marker hash"

assert_grep "$TEMPLATE_MD" 'no-op' \
	"template.md documents absent \`**Goal:**\` as a no-op (current behaviour unchanged)"

assert_grep "$TEMPLATE_MD" '\{\{PHASE_GOAL\}\}' \
	"template.md cross-references the \`{{PHASE_GOAL}}\` injection consumer"

# Example phase block should show a literal `**Goal:**` line so authors can
# copy it directly (Phase 1's example is optional-by-omission on Phase 2/3,
# but at least one phase block in the template must demonstrate the slot).
assert_grep "$TEMPLATE_MD" '^\*\*Goal:\*\*' \
	"template.md's example phase block includes a literal \`**Goal:**\` line"

# --- Marker line above must still be present in both docs unmodified ---
# (sanity: this test targets doc content, not the marker mechanics test,
# but a gross truncation of either file would otherwise pass the above
# greps vacuously if patterns were too loose — guard file non-emptiness.)
for f in "$SKILL_MD" "$TEMPLATE_MD"; do
	if [[ -s "$f" ]]; then
		pass "$(basename "$f") is non-empty"
	else
		fail "$(basename "$f") is empty"
	fi
done

echo ""
echo "Results: $pass_count passed, $fail_count failed"

if [[ "$fail_count" -gt 0 ]]; then
	exit 1
fi

exit 0
