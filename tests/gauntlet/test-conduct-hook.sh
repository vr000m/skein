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

# --- /update-docs pointer: healthy terminal handback only ---------------

# section FILE HEADING — the exact heading line through the line before the
# next heading of the same or a higher level.
section() {
	awk -v h="$2" '
		$0 == h { on = 1; split(h, p, " "); level = length(p[1]); print; next }
		on && /^#+ / { split($0, q, " "); if (length(q[1]) <= level) exit }
		on
	' "$1"
}

# assert_section_lacks FILE HEADING LABEL — the section exists and has no pointer.
assert_section_lacks() {
	local file="$1" heading="$2" label="$3"
	local text
	text="$(section "$file" "$heading")"
	if [[ -z "$text" ]]; then
		fail "$label (section not found: $heading)"
	elif grep -q '/update-docs' <<<"$text"; then
		fail "$label (/update-docs found in: $heading)"
	else
		pass "$label"
	fi
}

completion="$(section "$SKILL_MD" '## Completion Handback')"
pointer='Next: run /update-docs to sync the docs and offer decision-record promotion.'
if grep -qxF "$pointer" <<<"$completion"; then
	pass "healthy terminal path: the completion handback carries the /update-docs pointer"
else
	fail "healthy terminal path: the completion handback lacks the line: $pointer"
fi
if grep -q 'status = complete' <<<"$completion" && grep -q 'review-gauntlet` auto-chain has returned clean' <<<"$completion"; then
	pass "healthy terminal path: the pointer is gated on status = complete after a clean gauntlet"
else
	fail "healthy terminal path: the pointer is not gated on status = complete after a clean gauntlet"
fi
if grep -q 'conduct never invokes the update-docs skill itself' <<<"$completion"; then
	pass "the pointer is text only, never an invocation"
else
	fail "the completion handback does not say the pointer is text only"
fi

# Placement: the pointer appears nowhere outside the completion section, and
# that section follows the auto-chain, so it comes after any gauntlet run.
outside="$(awk '$0 == "## Completion Handback" { skip = 1; next } skip && /^## / { skip = 0 } !skip' "$SKILL_MD" | grep -c '/update-docs' || true)"
if [[ "$outside" -eq 0 ]]; then
	pass "/update-docs appears only in the completion handback"
else
	fail "/update-docs appears $outside time(s) outside the completion handback"
fi
chain_line="$(grep -n '^## Review Gauntlet Auto-Chain$' "$SKILL_MD" | cut -d: -f1)"
done_line="$(grep -n '^## Completion Handback$' "$SKILL_MD" | cut -d: -f1)"
if [[ -n "$chain_line" && -n "$done_line" && "$done_line" -gt "$chain_line" ]]; then
	pass "the completion handback follows the review-gauntlet auto-chain"
else
	fail "the completion handback does not follow the review-gauntlet auto-chain"
fi

assert_section_lacks "$SKILL_MD" '#### Step 9a — Phase success transition (autonomous-aware)' \
	"intermediate route: the Step 9a phase summary has no /update-docs pointer"
assert_section_lacks "$SKILL_MD" '#### Step 9b — Hard-stop handback' \
	"blocked route: the Step 9b hard-stop handback has no /update-docs pointer"
assert_section_lacks "$SKILL_MD" '## CI Parity Gate' \
	"CI-failed route: the ci_failed handback has no /update-docs pointer"
assert_section_lacks "$SKILL_MD" '## Review Gauntlet Auto-Chain' \
	"non-clean gauntlet route: the non-clean gauntlet handback has no /update-docs pointer"
# shellcheck disable=SC2016  # backticks are literal skill text
for route in 'Step 9a intermediate phase summary' 'Step 9b hard-stop handback' '`ci_failed` handback' 'non-clean `review-gauntlet` handback'; do
	if grep -qF "$route" <<<"$completion"; then
		pass "the completion handback excludes the route: $route"
	else
		fail "the completion handback does not exclude the route: $route"
	fi
done

CODEX_SKILL_MD="$ROOT_DIR/plugins/skein-codex/skills/conduct/SKILL.md"
require_file "$CODEX_SKILL_MD" || exit 1
codex_chain="$(section "$CODEX_SKILL_MD" '## Review Gauntlet Auto-Chain')"
codex_completion="$(section "$CODEX_SKILL_MD" '### Completion Handback')"

if grep -qxF '### Completion Handback' <<<"$codex_chain" &&
	[[ "$(grep -cF '/update-docs' "$CODEX_SKILL_MD")" -eq 1 ]] &&
	grep -qxF "$pointer" <<<"$codex_completion"; then
	pass "Codex: the pointer appears only in the auto-chain's terminal completion"
else
	fail "Codex: the pointer must appear once inside the auto-chain's completion handback"
fi

# shellcheck disable=SC2016  # backticks are literal skill text
for route in \
	'Absent field or `none`: once CI parity resolves, with no gauntlet run.' \
	'`quick`: once the gate 1 review returns clean.' \
	'`full`: once the Codex gate matrix returns clean.'; do
	if grep -qxF -- "- $route" <<<"$codex_completion" &&
		grep -qxF "$pointer" <<<"$codex_completion"; then
		pass "Codex healthy completion includes the pointer for $route"
	else
		fail "Codex healthy completion lacks the pointer for $route"
	fi
done

assert_section_lacks "$CODEX_SKILL_MD" '#### Step 9a — Successful Phase Boundary' \
	"Codex intermediate route: Step 9a has no pointer"
assert_section_lacks "$CODEX_SKILL_MD" '#### Step 9b — Hard-Stop Handback' \
	"Codex blocked route: Step 9b has no pointer"
assert_section_lacks "$CODEX_SKILL_MD" '## CI Parity Gate' \
	"Codex CI-failed route: the CI parity gate has no pointer"
assert_section_lacks "$CODEX_SKILL_MD" '### Dispatch' \
	"Codex non-clean gauntlet route: the auto-chain dispatch has no pointer"

# Plan A's comment-notice handback stays intact.
assert_grep "$SKILL_MD" '^\*\*Comment notices\.\*\* The implementer' \
	"Step 9a keeps the comment-notice handback"

# Sanity: guard against a gross truncation of the file passing the above
# greps vacuously.
if [[ -s "$SKILL_MD" ]]; then
	pass "$(basename "$SKILL_MD") is non-empty"
else
	fail "$(basename "$SKILL_MD") is empty"
fi

line_count=$(wc -l <"$SKILL_MD")
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
