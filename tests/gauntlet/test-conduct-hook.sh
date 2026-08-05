#!/usr/bin/env bash
# test-conduct-hook.sh — Phase 4 acceptance: conduct's terminal auto-chain
# hook into `review-gauntlet` is documented in conduct/SKILL.md.
#
# Plan: docs/dev_plans/20260707-feature-review-gauntlet-skill.md, Phase 4
# "conduct terminal hook (Claude)". Acceptance criteria under test:
#   1. After the CI-parity gate, when status would become `complete`,
#      SKILL.md documents reading the plan's `**Review Gates:**` field and
#      invoking `review-gauntlet --plan <plan>` when that field is `full`.
#   2. `full` = all logical gate slots; there is no Claude-side `quick`
#      mode (the code-review gate was removed).
#   3. Strict opt-in: absent field or `none` -> no gauntlet, current
#      behaviour unchanged (documented explicitly, not just implied).
#   4. Commit-ownership reconciliation: the gauntlet lands its own single
#      commit after the final phase boundary, and conduct treats it as an
#      absorbed follow-up rolled into `resume_base_sha` (not a rogue
#      commit, not by rewriting a frozen phase `commit_sha`).
#   5. The handback prose references the automated review-gauntlet path,
#      not only the manual `/deep-review` narrative.
#
# This is a documentation/shape check, matching the Phase 3 marker test's
# approach (tests/gauntlet/test-review-gates-marker.sh) — no runtime
# behaviour is exercised.
#
# Exit codes: 0 all assertions pass, 1 any assertion fails.

set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
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

# --- Criterion 1: terminal hook reads the marker and invokes the gauntlet

assert_grep "$SKILL_MD" '\*\*Review Gates:\*\*' \
	"SKILL.md documents reading the \`**Review Gates:**\` field"

assert_grep "$SKILL_MD" 'review-gauntlet' \
	"SKILL.md documents invoking \`review-gauntlet\`"

assert_grep "$SKILL_MD" 'review-gauntlet[^.\n]*--plan|--plan[^.\n]*review-gauntlet' \
	"SKILL.md documents the \`review-gauntlet --plan <plan>\` invocation form"

assert_grep "$SKILL_MD" 'CI.Parity Gate|CI.parity gate' \
	"SKILL.md anchors the hook after the CI-parity gate"

assert_grep "$SKILL_MD" 'complete' \
	"SKILL.md still documents the \`complete\` status transition"

# --- Criterion 2: no quick mode; full = all gate slots -------------------

assert_not_grep "$SKILL_MD" 'quick.*scoped to the code-review gate|code-review gate only' \
	"SKILL.md does not document a \`quick\` = code-review gate mapping (removed)"

assert_grep "$SKILL_MD" 'full.*(all|logical) gate slots' \
	"SKILL.md documents \`full\` = all logical gate slots"

assert_grep "$SKILL_MD" 'unrecognized value' \
	"SKILL.md documents the unrecognized-value guard (retired \`quick\`/typo -> treated as \`none\`, with a warning)"

# --- Criterion 3: strict opt-in -----------------------------------------

assert_grep "$SKILL_MD" '(absent|none)[^.\n]*(no gauntlet|unchanged|opt.in)|opt.in[^.\n]*(absent|none)' \
	"SKILL.md documents strict opt-in: absent/\`none\` -> no gauntlet, unchanged behaviour"

# --- Criterion 4: commit-ownership reconciliation -----------------------

assert_grep "$SKILL_MD" 'resume_base_sha' \
	"SKILL.md's reconciliation prose references \`resume_base_sha\`"

assert_grep "$SKILL_MD" 'one or more commits' \
	"SKILL.md documents the gauntlet landing one or more commits (not a false single-commit claim)"

assert_grep "$SKILL_MD" 'not.*rogue|rogue.*not' \
	"SKILL.md states the gauntlet's own commit is not flagged as a rogue commit"

assert_grep "$SKILL_MD" '(not|without).*rewrit(e|ing).*commit_sha|commit_sha.*(not|without).*rewrit' \
	"SKILL.md states the reconciliation does not rewrite a frozen phase \`commit_sha\`"

# --- Criterion 5: handback prose references the automated path ---------

assert_grep "$SKILL_MD" 'review-gauntlet' \
	"SKILL.md's handback/terminal prose references \`review-gauntlet\` (automated path)"

# Sanity: guard against a gross truncation of the file passing the above
# greps vacuously.
if [[ -s "$SKILL_MD" ]]; then
	pass "$(basename "$SKILL_MD") is non-empty"
else
	fail "$(basename "$SKILL_MD") is empty"
fi

line_count=$(wc -l < "$SKILL_MD")
if [[ "$line_count" -gt 100 ]]; then
	pass "$(basename "$SKILL_MD") has substantial content (>100 lines, not truncated)"
else
	fail "$(basename "$SKILL_MD") looks truncated ($line_count lines, expected >100)"
fi

echo ""
echo "Results: $pass_count passed, $fail_count failed"

if [[ "$fail_count" -gt 0 ]]; then
	exit 1
fi

exit 0
