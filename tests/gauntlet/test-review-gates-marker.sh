#!/usr/bin/env bash
# test-review-gates-marker.sh — Phase 3 acceptance: the `**Review Gates:**`
# above-marker header-contract field is documented in dev-plan/SKILL.md
# (Required Sections item 1, plan Header) and present in
# dev-plan/template.md's header block.
#
# Plan: docs/dev_plans/20260707-feature-review-gauntlet-skill.md, Phase 3
# "dev-plan `**Review Gates:**` header marker field". Acceptance criteria
# under test:
#   1. SKILL.md documents `**Review Gates:**` with the two values
#      `none | full` and default `none`.
#   2. SKILL.md documents it as an above-marker contract field (plan
#      Header / Required Sections item 1) and that changing it after
#      `/review-plan` invalidates the marker hash (framed as correct /
#      intended, not a bug).
#   3. SKILL.md documents that `conduct` and `fan-out` read the field to
#      auto-chain `review-gauntlet` (full = all gate slots; there is no
#      Claude-side `quick` value, the code-review gate was removed).
#   4. template.md's header block contains a `**Review Gates**` line with
#      a default of `none`.
#   5. Coexistence guard (reciprocal ownership with the sibling Goal-field
#      plan): the pre-existing `**Goal:**` slot documentation must still be
#      present in both files — this phase must not have clobbered it.
#
# This is a documentation/shape check, matching the Goal-field plan's
# Phase 1/3 doc tests (tests/gauntlet/test-goal-field-schema.sh,
# tests/gauntlet/test-goal-docs.sh) — no runtime behaviour is exercised.
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

# assert_not_grep FILE PATTERN LABEL — asserts PATTERN is absent.
assert_not_grep() {
	local file="$1" pattern="$2" label="$3"
	if grep -Eq -- "$pattern" "$file"; then
		fail "$label (forbidden pattern found: $pattern in $file)"
	else
		pass "$label"
	fi
}

require_file "$SKILL_MD" || exit 1
require_file "$TEMPLATE_MD" || exit 1

# --- dev-plan/SKILL.md: plan Header / Required Sections item 1 ---------

assert_grep "$SKILL_MD" '\*\*Review Gates:\*\*' \
	"SKILL.md documents \`**Review Gates:**\`"

assert_grep "$SKILL_MD" 'none \| full' \
	"SKILL.md documents the two values \`none | full\`"

assert_grep "$SKILL_MD" '\*\*Review Gates:\*\*[^.]*default `none`|default `none`[^.]*\*\*Review Gates:\*\*|`none`, default' \
	"SKILL.md documents the \`none\` default"

assert_grep "$SKILL_MD" 'above.marker.*header|header.*above.marker' \
	"SKILL.md documents \`**Review Gates:**\` as an above-marker header-contract field"

assert_grep "$SKILL_MD" '\*\*Review Gates:\*\*[^.]*invalidat|invalidat[a-z]*.*marker hash' \
	"SKILL.md notes the marker-hash invalidation consequence"

assert_grep "$SKILL_MD" 'intended|correct' \
	"SKILL.md frames the invalidation consequence as intended/correct, not a bug"

assert_grep "$SKILL_MD" 'conduct.*fan-out|fan-out.*conduct' \
	"SKILL.md documents that both \`conduct\` and \`fan-out\` read the field"

assert_grep "$SKILL_MD" 'auto-chain' \
	"SKILL.md documents the auto-chain behaviour into \`review-gauntlet\`"

assert_not_grep "$SKILL_MD" 'quick.*runs the code-review gate only|code-review gate only' \
	"SKILL.md does not document a \`quick\` = code-review gate mapping (removed)"

assert_grep "$SKILL_MD" 'full.*(all|logical) gate slots' \
	"SKILL.md documents \`full\` = all logical gate slots"

# --- dev-plan/template.md: header block ---------------------------------

assert_grep "$TEMPLATE_MD" '\*\*Review Gates\*\*:? none \| full' \
	"template.md header block includes a \`**Review Gates**\` line with the two values"

assert_grep "$TEMPLATE_MD" '\*\*Review Gates\*\*[^.]*default `none`' \
	"template.md documents the \`none\` default in the header block"

# --- Coexistence guard: sibling Goal-field plan's slot must survive -----
# This phase and the Goal-field plan both edit SKILL.md + template.md.
# Ownership split: this plan owns **Review Gates:**, the Goal-field plan
# owns per-phase **Goal:**. A clobbering implementer would silently drop
# the sibling's field — guard against that here.

assert_grep "$SKILL_MD" '\*\*Goal:\*\*' \
	"SKILL.md still documents the sibling \`**Goal:**\` phase-contract slot (not clobbered)"

assert_grep "$TEMPLATE_MD" '\*\*Goal:\*\*' \
	"template.md still documents the sibling \`**Goal:**\` phase-contract slot (not clobbered)"

# Sanity: guard against a gross truncation of either file passing the
# above greps vacuously.
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
