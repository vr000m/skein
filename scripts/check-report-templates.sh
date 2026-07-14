#!/usr/bin/env bash
# check-report-templates.sh
#
# Floor-level regression guard on the shipped SKILL.md/rubric.md prose
# for `deep-review` and `review-plan` (both mirrors). The golden fixtures
# in tests/reconciliation/ exercise only the reference renderer script,
# never the SKILL.md/rubric.md templates the skills actually execute at
# runtime — this script closes that gap by asserting the compact-Minor
# rendering contract's key tokens are present in the shipped prose, and
# that per-mirror harness-path/jq-key mistakes (a Claude mirror naming
# the Codex JSON path, or vice versa; review-plan naming deep-review's
# `.lenses` jq key) are caught mechanically instead of only by review.
#
# Checks:
#   1. Each of the four SKILL.md files (deep-review x2, review-plan x2)
#      contains the compact-Minor `(file:line)` grammar and the
#      `**Full findings JSON**:` footer marker.
#   2. Each of the four rubric.md files contains the reworded "restored
#      with `--verbose`" Finding Quality criterion.
#   3. Each SKILL.md's `**Full findings JSON**:` footer line names its
#      OWN harness's state file path and never the other harness's:
#      `.deep-review/latest-claude.json` only in the Claude deep-review
#      mirror, `.deep-review/latest-codex.json` only in the Codex
#      deep-review mirror (and the analogous `.review-plan/latest-*.json`
#      pair for review-plan).
#   4. review-plan's footer example uses the `.findings` jq key, never
#      deep-review's `.lenses` key.
#
# Exit codes: 0 clean, 1 on the first missing file/pattern (message
# names exactly what's missing and where).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail_count=0

fail() {
	echo "FAIL: $1" >&2
	fail_count=$((fail_count + 1))
}

require_file() {
	local path="$1"
	if [[ ! -f "$path" ]]; then
		fail "missing file: $path"
		return 1
	fi
	return 0
}

require_pattern() {
	local path="$1" pattern="$2" label="$3"
	if ! grep -qF -- "$pattern" "$path"; then
		fail "$path missing $label (expected literal: $pattern)"
	fi
}

reject_pattern() {
	local path="$1" pattern="$2" label="$3"
	if grep -qF -- "$pattern" "$path"; then
		fail "$path unexpectedly contains $label (literal: $pattern)"
	fi
}

# ---------------------------------------------------------------------------
# 1 & 3 & 4: SKILL.md files
# ---------------------------------------------------------------------------

DEEP_REVIEW_CLAUDE="$ROOT_DIR/plugins/skein/skills/deep-review/SKILL.md"
DEEP_REVIEW_CODEX="$ROOT_DIR/plugins/skein-codex/skills/deep-review/SKILL.md"
REVIEW_PLAN_CLAUDE="$ROOT_DIR/plugins/skein/skills/review-plan/SKILL.md"
REVIEW_PLAN_CODEX="$ROOT_DIR/plugins/skein-codex/skills/review-plan/SKILL.md"

for skill_md in "$DEEP_REVIEW_CLAUDE" "$DEEP_REVIEW_CODEX" "$REVIEW_PLAN_CLAUDE" "$REVIEW_PLAN_CODEX"; do
	if ! require_file "$skill_md"; then
		continue
	fi
	require_pattern "$skill_md" '(file:line)' "the compact-Minor (file:line) grammar"
	require_pattern "$skill_md" '**Full findings JSON**:' "the **Full findings JSON**: footer marker"
done

# Footer-line harness-path assertions: extract the `**Full findings JSON**:`
# line itself (not the whole file) so the check doesn't false-positive on
# legitimate cross-references elsewhere in the prose (e.g. deep-review's
# SKILL.md mentions the Codex state-file path in its Review State section
# when documenting per-harness resume behavior).
check_footer_path() {
	local skill_md="$1" own_path="$2" other_path="$3"
	[[ -f "$skill_md" ]] || return 0
	# Match only the actual footer line (`**Full findings JSON**: .path...`
	# at line start), not prose that merely *mentions* the marker (e.g.
	# review-plan's write-failure paragraph references "the
	# `**Full findings JSON**:` footer line below" before the real line
	# appears).
	local footer_line
	footer_line="$(grep -m1 -E '^\*\*Full findings JSON\*\*: \.' "$skill_md" || true)"
	if [[ -z "$footer_line" ]]; then
		# Already reported by require_pattern above.
		return 0
	fi
	if [[ "$footer_line" != *"$own_path"* ]]; then
		fail "$skill_md footer line does not name its own harness path ($own_path): $footer_line"
	fi
	if [[ "$footer_line" == *"$other_path"* ]]; then
		fail "$skill_md footer line names the OTHER mirror's harness path ($other_path): $footer_line"
	fi
}

check_footer_path "$DEEP_REVIEW_CLAUDE" ".deep-review/latest-claude.json" ".deep-review/latest-codex.json"
check_footer_path "$DEEP_REVIEW_CODEX" ".deep-review/latest-codex.json" ".deep-review/latest-claude.json"
check_footer_path "$REVIEW_PLAN_CLAUDE" ".review-plan/latest-claude.json" ".review-plan/latest-codex.json"
check_footer_path "$REVIEW_PLAN_CODEX" ".review-plan/latest-codex.json" ".review-plan/latest-claude.json"

# review-plan's footer example must use the `.findings` jq key, never
# deep-review's `.lenses` key. Scope the `.lenses` rejection to the jq
# invocation itself (`jq '.lenses'`), not a bare `.lenses` substring,
# since review-plan's prose legitimately mentions "not deep-review's
# `.lenses`" by name when explaining the schema difference.
for review_plan_md in "$REVIEW_PLAN_CLAUDE" "$REVIEW_PLAN_CODEX"; do
	[[ -f "$review_plan_md" ]] || continue
	require_pattern "$review_plan_md" "jq '.findings'" "a jq '.findings' footer example"
	reject_pattern "$review_plan_md" "jq '.lenses'" "a jq '.lenses' footer example (that key belongs to deep-review, not review-plan)"
done

# ---------------------------------------------------------------------------
# 2: rubric.md files
# ---------------------------------------------------------------------------

for rubric_md in \
	"$ROOT_DIR/plugins/skein/skills/deep-review/rubric.md" \
	"$ROOT_DIR/plugins/skein-codex/skills/deep-review/rubric.md" \
	"$ROOT_DIR/plugins/skein/skills/review-plan/rubric.md" \
	"$ROOT_DIR/plugins/skein-codex/skills/review-plan/rubric.md"; do
	if ! require_file "$rubric_md"; then
		continue
	fi
	require_pattern "$rubric_md" 'restored with `--verbose`' "the reworded 'restored with \`--verbose\`' Finding Quality criterion"
done

if [[ "$fail_count" -gt 0 ]]; then
	echo "" >&2
	echo "check-report-templates: $fail_count check(s) failed" >&2
	exit 1
fi

echo "check-report-templates passed"
