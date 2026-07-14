#!/usr/bin/env bash
# Regression test for scripts/check-report-templates.sh's check_footer_path
# function.
#
# Bug (round 7 of the deep-review-compact-output review-gauntlet, 2026-07-14):
# check_footer_path silently returned 0 (success) whenever it could not find
# the actual `**Full findings JSON**: .<path>` footer line (footer_line ends
# up empty), on the false assumption that the earlier require_pattern
# substring check already caught the absence. That assumption is false:
# require_pattern does an unanchored substring match for the literal marker
# text `**Full findings JSON**:`, which is satisfied by prose that merely
# *mentions* the marker (e.g. "the `**Full findings JSON**:` footer line
# below") even when the real, anchored footer line
# (`^\*\*Full findings JSON\*\*: \.`) is missing entirely. So deleting the
# real footer line while leaving mention-only prose made both checks pass,
# silently defeating the lint that exists specifically to catch a
# missing/broken footer line.
#
# This test:
#   (a) confirms check-report-templates.sh still passes cleanly against the
#       real, unmodified repo (no false positive introduced by the fix).
#   (b) reproduces the bug directly: copies the repo's deep-review Claude
#       SKILL.md into a scratch dir, deletes its real footer line while
#       leaving mention-only prose that references the marker, points a
#       scratch copy of check-report-templates.sh at the mutated file, and
#       asserts the script now exits non-zero (the fixed behavior) instead
#       of silently exiting 0 (the bug).
#
# Exit 0 on all-pass, 1 on any failure.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/check-report-templates.sh"

TMPDIR_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

pass_count=0
fail_count=0

pass() {
	echo "PASS: $*"
	pass_count=$((pass_count + 1))
}

fail() {
	echo "FAIL: $*" >&2
	fail_count=$((fail_count + 1))
}

# --- (a) real repo still passes cleanly ------------------------------------

real_repo_out="$TMPDIR_ROOT/real-repo-check.out"
if bash "$SCRIPT" >"$real_repo_out" 2>&1; then
	pass "check-report-templates.sh passes cleanly against the real, unmodified repo"
else
	fail "check-report-templates.sh unexpectedly failed against the real, unmodified repo:"
	cat "$real_repo_out" >&2
fi

# --- (b) reproduce the bug: missing footer line must now be caught ---------

SCRATCH="$TMPDIR_ROOT/scratch-repo"
mkdir -p "$SCRATCH/plugins/skein/skills/deep-review" \
	"$SCRATCH/plugins/skein-codex/skills/deep-review" \
	"$SCRATCH/plugins/skein/skills/review-plan" \
	"$SCRATCH/plugins/skein-codex/skills/review-plan" \
	"$SCRATCH/scripts"

# Mirror all four SKILL.md and four rubric.md files unmodified first, so the
# script's other checks (which iterate over all four targets) don't fail for
# unrelated reasons.
cp "$REPO_ROOT/plugins/skein/skills/deep-review/SKILL.md" "$SCRATCH/plugins/skein/skills/deep-review/SKILL.md"
cp "$REPO_ROOT/plugins/skein-codex/skills/deep-review/SKILL.md" "$SCRATCH/plugins/skein-codex/skills/deep-review/SKILL.md"
cp "$REPO_ROOT/plugins/skein/skills/review-plan/SKILL.md" "$SCRATCH/plugins/skein/skills/review-plan/SKILL.md"
cp "$REPO_ROOT/plugins/skein-codex/skills/review-plan/SKILL.md" "$SCRATCH/plugins/skein-codex/skills/review-plan/SKILL.md"
cp "$REPO_ROOT/plugins/skein/skills/deep-review/rubric.md" "$SCRATCH/plugins/skein/skills/deep-review/rubric.md"
cp "$REPO_ROOT/plugins/skein-codex/skills/deep-review/rubric.md" "$SCRATCH/plugins/skein-codex/skills/deep-review/rubric.md"
cp "$REPO_ROOT/plugins/skein/skills/review-plan/rubric.md" "$SCRATCH/plugins/skein/skills/review-plan/rubric.md"
cp "$REPO_ROOT/plugins/skein-codex/skills/review-plan/rubric.md" "$SCRATCH/plugins/skein-codex/skills/review-plan/rubric.md"
cp "$SCRIPT" "$SCRATCH/scripts/check-report-templates.sh"

TARGET="$SCRATCH/plugins/skein/skills/deep-review/SKILL.md"

# Delete the real, anchored footer line (`^\*\*Full findings JSON\*\*: \.`)
# but leave a mention-only line that satisfies require_pattern's unanchored
# substring check, reproducing the exact false-pass conditions from the
# finding.
grep -v -E '^\*\*Full findings JSON\*\*: \.' "$TARGET" >"$TARGET.tmp"
mv "$TARGET.tmp" "$TARGET"
printf '\nSee the `**Full findings JSON**:` footer line for the persisted state file path.\n' >>"$TARGET"

# Sanity: require_pattern's own substring check must still find the marker
# (proving the bug was NOT that require_pattern also failed to see anything).
if grep -qF -- '**Full findings JSON**:' "$TARGET"; then
	pass "mutated file still satisfies the unanchored require_pattern substring check (reproduces the exact false-pass precondition)"
else
	fail "mutated file unexpectedly does not contain the marker substring at all -- test setup is wrong"
fi

set +e
mutated_output="$(cd "$SCRATCH" && bash scripts/check-report-templates.sh 2>&1)"
mutated_exit=$?
set -e

if [[ "$mutated_exit" -ne 0 ]]; then
	pass "check-report-templates.sh now exits non-zero when the real footer line is missing (fix confirmed)"
else
	fail "check-report-templates.sh silently exited 0 despite the real footer line being missing -- bug still present"
fi

if echo "$mutated_output" | grep -q "no footer line matching"; then
	pass "failure message names the missing footer line explicitly"
else
	fail "failure output did not mention the missing footer line:"
	echo "$mutated_output" >&2
fi

echo ""
echo "test-check-report-templates: $pass_count passed, $fail_count failed"
[[ "$fail_count" -eq 0 ]]
