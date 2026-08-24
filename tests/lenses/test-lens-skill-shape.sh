#!/usr/bin/env bash
# test-lens-skill-shape.sh — Phase 2 acceptance: both mirrors of
# deep-review AND review-plan SKILL.md document the streamed-lens protocol.
#
# Plan: docs/dev_plans/20260823-feature-review-skills-resilience.md, Phase 2
# checklist ("new shape test tests/lenses/test-lens-skill-shape.sh asserts
# both mirrors reference persist-lens-result.sh --type start, --attempt 2,
# collect-lens-results.sh, lens-budget.sh, the --continue re-run clause
# (timed_out|errored|partial|absent), and the Codex sequential-mode
# clause").
#
# Pure documentation/shape check over the four SKILL.md files (Claude +
# Codex mirrors, deep-review + review-plan) — no runtime behaviour, in the
# style of tests/gauntlet/test-gauntlet-skill-shape.sh.
#
# Exit codes: 0 all assertions pass, 1 any assertion fails.

set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"

SKILLS=(
	"$ROOT_DIR/plugins/skein/skills/deep-review/SKILL.md"
	"$ROOT_DIR/plugins/skein-codex/skills/deep-review/SKILL.md"
	"$ROOT_DIR/plugins/skein/skills/review-plan/SKILL.md"
	"$ROOT_DIR/plugins/skein-codex/skills/review-plan/SKILL.md"
)

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
		pass "$label ($file)"
	else
		fail "$label ($file)"
	fi
}

for skill_md in "${SKILLS[@]}"; do
	if ! require_file "$skill_md"; then
		continue
	fi

	assert_grep "$skill_md" 'persist-lens-result\.sh' \
		"references persist-lens-result.sh"

	assert_grep "$skill_md" -- '--type[[:space:]]+start' \
		"references --type start"

	assert_grep "$skill_md" -- '--attempt[[:space:]]+2' \
		"references --attempt 2 (the respawn variant)"

	assert_grep "$skill_md" 'collect-lens-results\.sh' \
		"references collect-lens-results.sh"

	assert_grep "$skill_md" 'lens-budget\.sh' \
		"references lens-budget.sh"

	# The --continue re-run clause: all four re-run statuses must appear
	# somewhere in the file. "absent" is checked loosely (the plan's own
	# prose sometimes phrases it as "absent"/"missing" interchangeably --
	# R4: "absent = missing" -- so either token satisfies this leg).
	if grep -Fq "timed_out" "$skill_md" \
		&& grep -Fq "errored" "$skill_md" \
		&& grep -Fq "partial" "$skill_md" \
		&& (grep -Fq "absent" "$skill_md" || grep -Fq "missing" "$skill_md"); then
		pass "documents the --continue re-run clause (timed_out|errored|partial|absent) ($skill_md)"
	else
		fail "documents the --continue re-run clause (timed_out|errored|partial|absent) ($skill_md)"
	fi

	# Codex sequential-mode clause: the orchestrator emits typed lines
	# itself and skips respawn, but the collector still runs. Checked
	# loosely (case-insensitive "sequential" near "Codex"), since exact
	# phrasing is not pinned down by the plan beyond R4's prose.
	if grep -Eiq 'codex' "$skill_md" && grep -Eiq 'sequential' "$skill_md"; then
		pass "documents the Codex sequential-mode clause ($skill_md)"
	else
		fail "documents the Codex sequential-mode clause ($skill_md)"
	fi
done

echo ""
echo "Summary: $pass_count passed, $fail_count failed"

if [[ $fail_count -ne 0 ]]; then
	exit 1
fi
exit 0
