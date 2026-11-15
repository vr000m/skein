#!/usr/bin/env bash
# Phase 3 (in-your-own-words): docs and invocation-mode record.
# Asserts the README row, AGENTS.md workflow line, CHANGELOG entry,
# dev-plan index row, and the architecture-doc count strings and catalogue row.
# shellcheck disable=SC2016 # backticks and $ in single quotes are literal match text
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
README="$REPO_ROOT/README.md"
AGENTS="$REPO_ROOT/AGENTS.md"
CHANGELOG="$REPO_ROOT/CHANGELOG.md"
INDEX="$REPO_ROOT/docs/dev_plans/README.md"
ARCH="$REPO_ROOT/docs/skills_architecture/20260522-design-claude-skills-architecture.md"

PASS=0
FAIL=0
pass() {
	PASS=$((PASS + 1))
	echo "PASS: $*"
}
fail() {
	FAIL=$((FAIL + 1))
	echo "FAIL: $*" >&2
}
check() { # check <desc> <status>
	if [ "$2" -eq 0 ]; then pass "$1"; else fail "$1"; fi
}

for f in "$README" "$AGENTS" "$CHANGELOG" "$INDEX" "$ARCH"; do
	[ -f "$f" ] || {
		echo "FAIL: missing $f" >&2
		exit 1
	}
done

# has_line <desc> <file> <ERE>: some single line matches the pattern.
has_line() {
	local rc=0
	grep -qE -- "$3" "$2" || rc=$?
	check "$1" "$rc"
}
# has_fixed <desc> <file> <literal>
has_fixed() {
	local rc=0
	grep -qF -- "$3" "$2" || rc=$?
	check "$1" "$rc"
}

# README: skill-table row (Claude Yes / Codex Yes / Pi No) and invocation notes.
has_line "README row: Claude Yes, Codex Yes, Pi No" "$README" \
	'^\| in-your-own-words \| Yes[^|]*\| Yes[^|]*\| No \(excluded\) \|'
has_fixed "README documents namespaced invocation" "$README" '/skein:in-your-own-words'
has_fixed "README documents Codex invocation" "$README" '$in-your-own-words'
has_fixed "README notes the bare-name collision caveat" "$README" 'may collide'
has_fixed "README states tested Codex version 0.169.0" "$README" '0.169.0'

# AGENTS.md: Skill Workflow line.
has_line "AGENTS.md workflow line places skill before grill/review-plan" "$AGENTS" \
	'^Optional steering step .*`skein:in-your-own-words`'

# CHANGELOG: entry in [Unreleased] or in the release that ships it (0.12.0), above the 0.11.1 section.
shipping="$(awk '
	/^## \[0\.11\.1\]/ { exit }
	{ print }
' "$CHANGELOG")"
rc=0
printf '%s\n' "$shipping" | grep -qF '`in-your-own-words` skill' || rc=$?
check "CHANGELOG has the in-your-own-words entry above [0.11.1]" "$rc"

# Dev-plan index row.
has_line "plan index row (2026-11-14, feature, planning-skills)" "$INDEX" \
	'^\| 2026-11-14 \| feature \| in-your-own-words \| planning-skills \| — \| feature/in-your-own-words \| \[plan\]\(20261114-feature-in-your-own-words\.md\) \|'

# Architecture doc: counts and catalogue row.
has_fixed "architecture: first count string" "$ARCH" \
	'3 of 16 skills — `plan-view`, `release` and `in-your-own-words` — clear both'
has_fixed "architecture: second count string" "$ARCH" \
	'3 of 16 skills clear both axes for Claude'
has_line "architecture: catalogue row is user-invoked" "$ARCH" \
	'^\| `in-your-own-words` \|.*user-invoked'
rc=0
grep -qF '2 of 15 skills' "$ARCH" && rc=1
check "architecture: no stale '2 of 15 skills'" "$rc"

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
