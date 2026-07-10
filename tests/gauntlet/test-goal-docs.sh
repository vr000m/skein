#!/usr/bin/env bash
# test-goal-docs.sh — Phase 3 acceptance: the wiring/docs deliverables for the
# `**Goal:**` / `{{PHASE_GOAL}}` feature are in place: a `gauntlet-tests`
# justfile recipe, AGENTS.md's phase-slot list documents the optional
# `**Goal:**` slot, CHANGELOG.md carries an entry, and docs/dev_plans/README.md
# cross-links the goal-field plan in its task table.
#
# Plan: docs/dev_plans/20260707-feature-conduct-phase-goal-field.md, Phase 3
# "Tests, docs, cross-links". Acceptance criteria under test:
#   1. `justfile` has a `gauntlet-tests` recipe.
#   2. `AGENTS.md` documents the optional `**Goal:**` phase-contract slot.
#   3. `CHANGELOG.md` has an entry mentioning the `**Goal:**`/`{{PHASE_GOAL}}`
#      feature.
#   4. `docs/dev_plans/README.md` references the goal-field plan (task-table
#      row).
#
# This is a documentation/wiring check, matching the Phase 1/2 tests'
# approach (tests/gauntlet/test-goal-field-schema.sh,
# tests/gauntlet/test-goal-injection.sh) — no runtime behaviour is exercised.
#
# Exit codes: 0 all assertions pass, 1 any assertion fails.

set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
JUSTFILE="$ROOT_DIR/justfile"
AGENTS_MD="$ROOT_DIR/AGENTS.md"
CHANGELOG_MD="$ROOT_DIR/CHANGELOG.md"
DEV_PLANS_README="$ROOT_DIR/docs/dev_plans/README.md"

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
# PATTERN is passed to `grep -Eq` (extended regex) against the whole file.
assert_grep() {
	local file="$1" pattern="$2" label="$3"
	if grep -Eq -- "$pattern" "$file"; then
		pass "$label"
	else
		fail "$label (pattern not found: $pattern in $file)"
	fi
}

require_file "$JUSTFILE" || exit 1
require_file "$AGENTS_MD" || exit 1
require_file "$CHANGELOG_MD" || exit 1
require_file "$DEV_PLANS_README" || exit 1

# --- Criterion 1: justfile gauntlet-tests recipe ------------------------

assert_grep "$JUSTFILE" '^gauntlet-tests:' \
	"justfile has a \`gauntlet-tests\` recipe"

assert_grep "$JUSTFILE" 'tests/gauntlet/test-goal-field-schema\.sh' \
	"justfile's \`gauntlet-tests\` recipe runs test-goal-field-schema.sh"

assert_grep "$JUSTFILE" 'tests/gauntlet/test-goal-injection\.sh' \
	"justfile's \`gauntlet-tests\` recipe runs test-goal-injection.sh"

# --- Criterion 2: AGENTS.md documents the optional **Goal:** slot ------

assert_grep "$AGENTS_MD" '\*\*Goal:\*\*' \
	"AGENTS.md mentions \`**Goal:**\`"

assert_grep "$AGENTS_MD" '\{\{PHASE_GOAL\}\}' \
	"AGENTS.md mentions the \`{{PHASE_GOAL}}\` injection"

assert_grep "$AGENTS_MD" 'optional.*\*\*Goal:\*\*|\*\*Goal:\*\*.*optional' \
	"AGENTS.md documents \`**Goal:**\` as an optional phase-contract slot"

assert_grep "$AGENTS_MD" 'skein:conduct' \
	"AGENTS.md's \`**Goal:**\` mention is anchored in the skein:conduct entry"

# --- Criterion 3: CHANGELOG.md entry ------------------------------------

assert_grep "$CHANGELOG_MD" '\*\*Goal:\*\*' \
	"CHANGELOG.md mentions \`**Goal:**\`"

assert_grep "$CHANGELOG_MD" '\{\{PHASE_GOAL\}\}' \
	"CHANGELOG.md mentions \`{{PHASE_GOAL}}\`"

assert_grep "$CHANGELOG_MD" 'gauntlet-tests' \
	"CHANGELOG.md's entry mentions the new \`gauntlet-tests\` recipe"

assert_grep "$CHANGELOG_MD" '### Added' \
	"CHANGELOG.md retains an \`### Added\` section"

# --- Criterion 4: docs/dev_plans/README.md cross-link ------------------

assert_grep "$DEV_PLANS_README" '20260707-feature-conduct-phase-goal-field' \
	"docs/dev_plans/README.md's task table links the goal-field plan"

assert_grep "$DEV_PLANS_README" 'conduct-phase-goal-field' \
	"docs/dev_plans/README.md's task table names the goal-field task"

# Sanity: guard against a gross truncation of any file passing the above
# greps vacuously.
for f in "$JUSTFILE" "$AGENTS_MD" "$CHANGELOG_MD" "$DEV_PLANS_README"; do
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
