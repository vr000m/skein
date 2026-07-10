#!/usr/bin/env bash
# test-goal-injection.sh — Phase 2 acceptance: conduct injects `{{PHASE_GOAL}}`
# into the implementer and test-writer prompt templates, and SKILL.md parses
# the phase-contract `**Goal:**` slot and substitutes it at every spawn AND
# fix-loop respawn site.
#
# Plan: docs/dev_plans/20260707-feature-conduct-phase-goal-field.md, Phase 2
# "`{{PHASE_GOAL}}` injection in conduct". Acceptance criteria under test:
#   1. `{{PHASE_GOAL}}` appears in both prompt templates as an explicit
#      design-intent directive, distinct from the existing "read the whole
#      plan" line.
#   2. The placeholder list line in each template includes `{{PHASE_GOAL}}`.
#   3. conduct SKILL.md's placeholder-substitution documentation lists
#      `{{PHASE_GOAL}}` and describes parsing it from the phase block's
#      `**Goal:**` slot at spawn AND fix-loop respawn sites.
#   4. No-regression: absent/empty goal renders the placeholder empty,
#      leaving prompts byte-identical to today (documented, not simulated —
#      the actual substitution is performed by the conductor LLM at runtime,
#      not by a script here).
#
# This is a documentation/template-content check, matching the Phase 1
# schema test's approach (tests/gauntlet/test-goal-field-schema.sh) — no
# runtime substitution engine exists to exercise directly.
#
# Exit codes: 0 all assertions pass, 1 any assertion fails.

set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
IMPLEMENTER_PROMPT="$ROOT_DIR/plugins/skein/skills/conduct/implementer-prompt.md"
TEST_WRITER_PROMPT="$ROOT_DIR/plugins/skein/skills/conduct/test-writer-prompt.md"
SKILL_MD="$ROOT_DIR/plugins/skein/skills/conduct/SKILL.md"

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

# assert_grep_i FILE PATTERN LABEL — case-insensitive variant.
assert_grep_i() {
	local file="$1" pattern="$2" label="$3"
	if grep -Eqi -- "$pattern" "$file"; then
		pass "$label"
	else
		fail "$label (pattern not found, case-insensitive: $pattern in $file)"
	fi
}

# extract_section FILE HEADING_LINE
# Prints the lines between an exact heading line (e.g. "## Your Task") and
# the next line starting with "## ", exclusive of both boundaries. Both
# templates embed literal markdown headings inside their fenced Template
# block, so a plain line-match works without needing to parse the fence.
extract_section() {
	local file="$1" heading="$2"
	awk -v h="$heading" '
		$0 == h { flag = 1; next }
		flag && /^## / { flag = 0 }
		flag { print }
	' "$file"
}

require_file "$IMPLEMENTER_PROMPT" || exit 1
require_file "$TEST_WRITER_PROMPT" || exit 1
require_file "$SKILL_MD" || exit 1

# --- Criterion 2: placeholder list line in each template ---------------

assert_grep "$IMPLEMENTER_PROMPT" '^Placeholders:.*\{\{PHASE_GOAL\}\}' \
	"implementer-prompt.md's Placeholders line includes \`{{PHASE_GOAL}}\`"

assert_grep "$TEST_WRITER_PROMPT" '^Placeholders:.*\{\{PHASE_GOAL\}\}' \
	"test-writer-prompt.md's Placeholders line includes \`{{PHASE_GOAL}}\`"

# --- Criterion 1: explicit design-intent directive, distinct from the --
# --- "read the whole plan" line -----------------------------------------

impl_task_section="$(extract_section "$IMPLEMENTER_PROMPT" "## Your Task")"
tw_task_section="$(extract_section "$TEST_WRITER_PROMPT" "## Your Task")"

if [[ -z "$impl_task_section" ]]; then
	fail "implementer-prompt.md: could not locate a '## Your Task' section in the Template block"
else
	pass "implementer-prompt.md: '## Your Task' section located"
fi

if [[ -z "$tw_task_section" ]]; then
	fail "test-writer-prompt.md: could not locate a '## Your Task' section in the Template block"
else
	pass "test-writer-prompt.md: '## Your Task' section located"
fi

if grep -Fq '{{PHASE_GOAL}}' <<<"$impl_task_section"; then
	pass "implementer-prompt.md: \`{{PHASE_GOAL}}\` appears in the Task section (the directive injection point)"
else
	fail "implementer-prompt.md: \`{{PHASE_GOAL}}\` missing from the Task section"
fi

if grep -Fq '{{PHASE_GOAL}}' <<<"$tw_task_section"; then
	pass "test-writer-prompt.md: \`{{PHASE_GOAL}}\` appears in the Task section (the directive injection point)"
else
	fail "test-writer-prompt.md: \`{{PHASE_GOAL}}\` missing from the Task section"
fi

# The read-the-plan line must still be present, unmodified in spirit, and
# the {{PHASE_GOAL}} directive's own doc bullet must call out that it is a
# distinct sentence appended to it (not folded into the same prose), so a
# reviewer cannot satisfy criterion 1 by e.g. silently overwriting the
# read-the-plan sentence with the goal text.
assert_grep "$IMPLEMENTER_PROMPT" 'Read the plan file in full' \
	"implementer-prompt.md retains the existing \"read the whole plan\" line"

assert_grep "$TEST_WRITER_PROMPT" 'Read the plan in full' \
	"test-writer-prompt.md retains the existing \"read the whole plan\" line"

assert_grep_i "$IMPLEMENTER_PROMPT" '\{\{PHASE_GOAL\}\}.*(distinct from|appended to)' \
	"implementer-prompt.md documents \`{{PHASE_GOAL}}\` as a directive distinct from the read-the-plan sentence"

assert_grep_i "$TEST_WRITER_PROMPT" '\{\{PHASE_GOAL\}\}.*(distinct from|appended to)' \
	"test-writer-prompt.md documents \`{{PHASE_GOAL}}\` as a directive distinct from the read-the-plan sentence"

assert_grep_i "$IMPLEMENTER_PROMPT" 'design intent' \
	"implementer-prompt.md's \`{{PHASE_GOAL}}\` directive is framed as design intent"

assert_grep_i "$TEST_WRITER_PROMPT" '(design intent|invariant)' \
	"test-writer-prompt.md's \`{{PHASE_GOAL}}\` directive is framed as design intent/invariant (assert the invariant, not just surface behaviour)"

# --- Criterion 4: no-regression contract documented ---------------------

assert_grep_i "$IMPLEMENTER_PROMPT" '\{\{PHASE_GOAL\}\}.*empty string' \
	"implementer-prompt.md documents that an absent \`**Goal:**\` slot substitutes \`{{PHASE_GOAL}}\` with the empty string"

assert_grep_i "$IMPLEMENTER_PROMPT" 'byte-identical' \
	"implementer-prompt.md documents byte-identical prompt output when the goal is absent (no-regression)"

assert_grep_i "$TEST_WRITER_PROMPT" '\{\{PHASE_GOAL\}\}.*empty string' \
	"test-writer-prompt.md documents that an absent \`**Goal:**\` slot substitutes \`{{PHASE_GOAL}}\` with the empty string"

assert_grep_i "$TEST_WRITER_PROMPT" 'byte-identical' \
	"test-writer-prompt.md documents byte-identical prompt output when the goal is absent (no-regression)"

# Guard the actual byte-identity invariant, not just its documentation: the
# {{PHASE_GOAL}} placeholder MUST be glued directly to the preceding sentence
# with no leading whitespace, else empty substitution leaves a trailing space.
assert_grep "$IMPLEMENTER_PROMPT" 'restate\.\{\{PHASE_GOAL\}\}' \
	"implementer-prompt.md glues {{PHASE_GOAL}} to the preceding sentence with no leading space (byte-identity invariant on empty goal)"

assert_grep "$TEST_WRITER_PROMPT" 'means\.\{\{PHASE_GOAL\}\}' \
	"test-writer-prompt.md glues {{PHASE_GOAL}} to the preceding sentence with no leading space (byte-identity invariant on empty goal)"

# --- Criterion 3: SKILL.md parses **Goal:** and substitutes at every ---
# --- spawn AND fix-loop respawn site ------------------------------------

assert_grep "$SKILL_MD" '\*\*Goal:\*\*.*\(optional\)|\*\*Goal:\*\*.*optional' \
	"SKILL.md's Step 1 phase-contract parsing documents the optional \`**Goal:**\` slot"

assert_grep "$SKILL_MD" '\*\*Goal:\*\*.*\{\{PHASE_GOAL\}\}|\{\{PHASE_GOAL\}\}.*\*\*Goal:\*\*' \
	"SKILL.md documents \`**Goal:**\` as the source parsed into \`{{PHASE_GOAL}}\`"

assert_grep "$SKILL_MD" '\|\s*`?\{\{PHASE_GOAL\}\}`?\s*\|' \
	"SKILL.md's Step 3 placeholder-substitution table includes a \`{{PHASE_GOAL}}\` row"

assert_grep_i "$SKILL_MD" '\{\{PHASE_GOAL\}\}.*(fix-loop respawn|every.*spawn)' \
	"SKILL.md documents \`{{PHASE_GOAL}}\` substitution at every spawn AND fix-loop respawn site"

assert_grep_i "$SKILL_MD" 'fix-loop respawn' \
	"SKILL.md explicitly names fix-loop respawn as a substitution site (not just the first attempt)"

# Sanity: guard against a gross truncation of any file passing the above
# greps vacuously.
for f in "$IMPLEMENTER_PROMPT" "$TEST_WRITER_PROMPT" "$SKILL_MD"; do
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
