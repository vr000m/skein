#!/usr/bin/env bash
# test-state-dir-registration.sh — the four skill -> state-directory
# registration sites must list an IDENTICAL skill set (R11/F13).
#
# The mapping (deep-review -> .deep-review, review-plan -> .review-plan) is
# spelled out in four places, deliberately NOT consolidated: they differ in
# root source ($AF_COMMON_ROOT vs an explicit argument) and in failure exit
# code (2 vs 1), so merging them would be a behaviour change at four call
# sites for no functional gain. That decision stands -- see the SKILL->
# STATE-DIR MAPPING comment in scripts/lib/lens-common.sh.
#
# What the decision never came with is a guard. Nothing failed when a new
# skill was registered in three of the four: the fourth site simply returned
# its unknown-skill error at runtime, in whichever of the four codepaths the
# operator happened to hit last. This suite is that guard. It does not
# consolidate anything; it asserts the sets agree.
#
# The four sites are NOT symmetric, and the test must not pretend they are:
#   - two are `case` arms that enumerate EVERY skill
#       scripts/lib/lens-common.sh      persist_lens_state_dir
#       scripts/lib/auto-fix-common.sh  af_manifest_dir
#   - two are single-skill scripts that each PIN exactly one skill
#       scripts/persist-deep-review-state.sh  OUT_DIR="$ROOT_DIR/.deep-review"
#       scripts/persist-review-state.sh       OUT_DIR="$ROOT_DIR/.review-plan"
# So the assertion is: the two enumerating sites agree with each other, and
# the union of the two pinned sites equals that same set. A skill added to
# the enumerating pair without its own persist-*-state.sh shows up as a
# missing pinned site, which is the real failure mode.
#
# Exit codes: 0 all assertions pass, 1 any assertion fails.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

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

# skills_from_case <file> <function-name>
# Extracts the skill labels from the `case "$skill" in` arms of one function.
# Reads the function body only (from its opening line to the first line that
# is a bare `}`), so an unrelated case statement elsewhere in the file cannot
# contribute.
skills_from_case() {
	local file="$1" fn="$2"
	awk -v fn="$fn() {" '
		index($0, fn) == 1 { inside = 1; next }
		inside && $0 == "}" { inside = 0 }
		inside && /^\t[a-z][a-z-]*\)/ {
			label = $1
			sub(/\)$/, "", label)
			print label
		}
	' "$file" | sort -u
}

# skill_from_out_dir <file> — the single skill a persist-*-state.sh pins,
# read from its OUT_DIR assignment (".deep-review" -> deep-review).
skill_from_out_dir() {
	local file="$1" dir
	dir="$(grep -E '^OUT_DIR="\$ROOT_DIR/\.[a-z-]+"$' "$file" | head -1 |
		sed -E 's|^OUT_DIR="\$ROOT_DIR/\.([a-z-]+)"$|\1|')"
	printf '%s' "$dir"
}

lens_skills="$(skills_from_case "$REPO_ROOT/scripts/lib/lens-common.sh" persist_lens_state_dir | tr '\n' ' ')"
af_skills="$(skills_from_case "$REPO_ROOT/scripts/lib/auto-fix-common.sh" af_manifest_dir | tr '\n' ' ')"

# Non-vacuous-pass guard: an extractor that silently matched nothing would
# make every set-equality below trivially true.
if [[ -z "${lens_skills// /}" || -z "${af_skills// /}" ]]; then
	fail "extractor matched no case arms (lens='$lens_skills' auto-fix='$af_skills') — layout drift, not a passing test"
	echo ""
	echo "Summary: $pass_count passed, $fail_count failed"
	exit 1
fi

if [[ "$lens_skills" == "$af_skills" ]]; then
	pass "(F13a) persist_lens_state_dir and af_manifest_dir register the same skills: $lens_skills"
else
	fail "(F13a) enumerating sites disagree: lens-common='$lens_skills' auto-fix-common='$af_skills'"
fi

deep_skill="$(skill_from_out_dir "$REPO_ROOT/scripts/persist-deep-review-state.sh")"
plan_skill="$(skill_from_out_dir "$REPO_ROOT/scripts/persist-review-state.sh")"
pinned="$(printf '%s\n%s\n' "$deep_skill" "$plan_skill" | sort -u | tr '\n' ' ')"

if [[ -z "$deep_skill" || -z "$plan_skill" ]]; then
	fail "(F13b) could not read an OUT_DIR skill (deep='$deep_skill' plan='$plan_skill')"
elif [[ "$pinned" == "$lens_skills" ]]; then
	pass "(F13b) the two pinned OUT_DIR sites cover exactly the enumerated set: $pinned"
else
	fail "(F13b) pinned OUT_DIR sites cover '$pinned' but the enumerating sites list '$lens_skills' — a skill is registered in some sites and not others"
fi

# Each pinned site must pin a DIFFERENT skill. Both pointing at the same
# state dir would still satisfy a union check while silently leaving one
# harness writing into the other harness's directory.
if [[ -n "$deep_skill" && "$deep_skill" != "$plan_skill" ]]; then
	pass "(F13c) the two persist-*-state.sh scripts pin distinct state dirs ($deep_skill / $plan_skill)"
else
	fail "(F13c) both persist-*-state.sh scripts pin '$deep_skill'"
fi

echo ""
echo "Summary: $pass_count passed, $fail_count failed"
[[ "$fail_count" -eq 0 ]]
