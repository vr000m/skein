#!/usr/bin/env bash
# test-fanout-hook.sh — Phase 5 acceptance: fan-out's Phase 6 (Merge) hook
# into `review-gauntlet` is documented in fan-out/SKILL.md.
#
# Plan: docs/dev_plans/20260707-feature-review-gauntlet-skill.md, Phase 5
# "fan-out Phase 6 hook (Claude)". Acceptance criteria under test:
#   1. At the end of `### Phase 6: Merge` (before `### Phase 7: Cleanup`),
#      SKILL.md documents reading the plan's `**Review Gates:**` field and
#      invoking `review-gauntlet` on the merged feature branch when `full`.
#   2. `full` = all gate slots; there is no Claude-side `quick` mode (the
#      code-review gate was removed).
#   3. No-op on the PR-per-task exit path: the hook runs only on the
#      merged-branch path (`/fan-out merge`, option 1), and no-ops when
#      tasks exit via individual PRs (option 2).
#   4. Strict opt-in: absent field or `none` -> no gauntlet, behaviour
#      unchanged.
#   5. Non-empty / non-truncation sanity guard on fan-out SKILL.md.
#
# This is a documentation/shape check, matching the Phase 3 marker test's
# approach (tests/gauntlet/test-review-gates-marker.sh) and the Phase 4
# conduct-hook test's approach (tests/gauntlet/test-conduct-hook.sh) — no
# runtime behaviour is exercised.
#
# Exit codes: 0 all assertions pass, 1 any assertion fails.

set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
SKILL_MD="$ROOT_DIR/plugins/skein/skills/fan-out/SKILL.md"

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
# easy to diagnose. Patterns are kept simple (no spanning `[^.\n]*` character
# classes) — grep's bracket-class negation is not reliable for excluding
# multi-byte/letter content across a span, so each concept gets its own
# tolerant, self-contained assertion instead of proving adjacency.
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

# --- Criterion 1: hook location and invocation --------------------------

assert_grep "$SKILL_MD" '^### Phase 6: Merge' \
	"SKILL.md has a \`### Phase 6: Merge\` section"

assert_grep "$SKILL_MD" '^### Phase 7: Cleanup' \
	"SKILL.md has a \`### Phase 7: Cleanup\` section (hook must precede this)"

# The hook content must appear between the Phase 6 and Phase 7 headings.
phase6_to_7=$(sed -n '/^### Phase 6: Merge/,/^### Phase 7: Cleanup/p' "$SKILL_MD")

if grep -Eq -- '\*\*Review Gates:\*\*' <<<"$phase6_to_7"; then
	pass "Phase 6 section documents reading the \`**Review Gates:**\` field"
else
	fail "Phase 6 section does not document reading the \`**Review Gates:**\` field"
fi

if grep -Eq -- 'review-gauntlet' <<<"$phase6_to_7"; then
	pass "Phase 6 section documents invoking \`review-gauntlet\`"
else
	fail "Phase 6 section does not document invoking \`review-gauntlet\`"
fi

if grep -Eqi -- 'merged (feature )?branch' <<<"$phase6_to_7"; then
	pass "Phase 6 section documents running the gauntlet on the merged feature branch"
else
	fail "Phase 6 section does not document running the gauntlet on the merged feature branch"
fi

# --- Criterion 2: no quick mode; full = all gate slots -------------------

assert_not_grep "$SKILL_MD" 'quick.*scoped to the code-review gate|code-review gate only' \
	"SKILL.md does not document a \`quick\` = code-review gate mapping (removed)"

if grep -Eqi -- 'full.*gate slots?|gate slots?.*full' <<<"$phase6_to_7"; then
	pass "Phase 6 section documents \`full\` scoped to gate slots"
else
	fail "Phase 6 section does not document \`full\` scoped to gate slots"
fi

if grep -Eqi -- 'all (logical )?gate slots?' <<<"$phase6_to_7"; then
	pass "Phase 6 section documents \`full\` = all (logical) gate slots"
else
	fail "Phase 6 section does not document \`full\` = all (logical) gate slots"
fi

if grep -Eqi -- 'unrecognized value' <<<"$phase6_to_7"; then
	pass "Phase 6 section documents the unrecognized-value guard (retired \`quick\`/typo -> treated as \`none\`, with a warning)"
else
	fail "Phase 6 section does not document the unrecognized-value guard"
fi

# --- Criterion 3: no-op on the PR-per-task exit path ---------------------

if grep -Eqi -- 'option 2|individual PRs|PR-per-task' <<<"$phase6_to_7"; then
	pass "Phase 6 section references the PR-per-task / option 2 exit path"
else
	fail "Phase 6 section does not reference the PR-per-task / option 2 exit path"
fi

if grep -Eqi -- 'no.op|no op|skip' <<<"$phase6_to_7"; then
	pass "Phase 6 section documents the hook no-ops / skips on that path"
else
	fail "Phase 6 section does not document the hook no-ops / skips on that path"
fi

if grep -Eqi -- 'option 1|single merged branch|merge into' <<<"$phase6_to_7"; then
	pass "Phase 6 section documents the hook runs only on the merged-branch path (option 1)"
else
	fail "Phase 6 section does not document the hook running only on the merged-branch path"
fi

# --- Criterion 4: strict opt-in -------------------------------------------

if grep -Eqi -- 'absent|none' <<<"$phase6_to_7"; then
	pass "Phase 6 section references the absent-field / \`none\` case"
else
	fail "Phase 6 section does not reference the absent-field / \`none\` case"
fi

if grep -Eqi -- 'no gauntlet|unchanged|opt.in' <<<"$phase6_to_7"; then
	pass "Phase 6 section documents strict opt-in: no gauntlet / unchanged behaviour"
else
	fail "Phase 6 section does not document strict opt-in behaviour"
fi

# --- Sanity: guard against a gross truncation of the file passing the
# above greps vacuously. -----------------------------------------------

if [[ -s "$SKILL_MD" ]]; then
	pass "$(basename "$SKILL_MD") is non-empty"
else
	fail "$(basename "$SKILL_MD") is empty"
fi

line_count=$(wc -l <"$SKILL_MD")
if [[ "$line_count" -gt 200 ]]; then
	pass "$(basename "$SKILL_MD") has substantial content (>200 lines, not truncated)"
else
	fail "$(basename "$SKILL_MD") looks truncated ($line_count lines, expected >200)"
fi

echo ""
echo "Results: $pass_count passed, $fail_count failed"

if [[ "$fail_count" -gt 0 ]]; then
	exit 1
fi

exit 0
