#!/usr/bin/env bash
# Phase 4 acceptance test: assert that the hygiene rules THIS repo owns each
# have a written rule in a tracked file. Three of the four original
# insights-report failures travelled to sync-computer with the files they
# govern (see the ownership note below); what is asserted here is the
# skein-owned remainder.
#
# Ownership split (see AGENTS.md): files under ~/.claude/ -- CLAUDE.md and
# hooks/* alike -- are owned by the sync-computer repo, which now enforces
# their hygiene in its OWN CI. This test therefore asserts nothing about any
# file outside this repo; both cross-repo blocks it used to carry were removed
# rather than left as duplicates that only ran when a maintainer set an env
# var locally:
#   * the global ~/.claude/CLAUDE.md rules -> sync-computer's
#     scripts/check-claude-md-hygiene.sh (its PR #27)
#   * the format-on-edit hook's `--ignore RUF100` flag -> sync-computer's
#     scripts/check-format-hook-hygiene.sh (its PR #28, commit 93c959a)
#
# What remains is what skein owns, and both blocks run on a CI runner:
#
#  1. Repo .claude/CLAUDE.md unconditionally carries its skein-specific rules
#     (release via skein:release, the review gates, backgrounded `just ci`).
#     It is NOT required to restate the global hygiene rules.
#  2. AGENTS.md unconditionally carries the contributor rules that must stay
#     repo-tracked (sweeping-git-add ban, no squash-merges, secrets check,
#     feature branches, ruff format alongside ruff check, backgrounded `just ci`).
#
# tests/plugin/noqa-probe.sh stays in this repo and is NOT superseded by
# sync-computer's hook check: the probe reproduces the MECHANISM (ruff really
# does strip an unused `# noqa` without the flag), which is a different claim
# from asserting the hook source carries the flag. This test does not own that
# probe and does not edit implementation files.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

PASS_COUNT=0
FAIL_COUNT=0

pass() {
	PASS_COUNT=$((PASS_COUNT + 1))
	echo "ok: $1"
}

fail() {
	FAIL_COUNT=$((FAIL_COUNT + 1))
	echo "FAIL: $1" >&2
}

# assert_rule <file> <label> <extended-regex>
#
# Rule entries below are "<label>|<extended-regex>": the FIRST "|" separates
# the two, so the regex may itself use "|" for alternation (the label may not
# contain one). Each pattern must be specific enough that deleting the rule it
# names fails the assertion -- a bare token that also appears in a neighbouring
# rule makes the check vacuous.
assert_rule() {
	local file="$1"
	local label="$2"
	local pattern="$3"
	if grep -q -i -E -- "$pattern" "$file"; then
		pass "$label"
	else
		fail "$label (no line matching /$pattern/)"
	fi
}

# --- 1. Repo .claude/CLAUDE.md: skein-specific rules, unconditional ---------
REPO_CLAUDE_MD=".claude/CLAUDE.md"
REPO_RULES=(
	"repo file routes releases through skein:release|skein:release"
	"repo file names the review gates|skein:review-gauntlet"
	"repo file backgrounds the full CI run|background.*just ci|just ci.*run_in_background"
)
if [[ ! -f "$REPO_CLAUDE_MD" ]]; then
	fail "repo file missing: $REPO_CLAUDE_MD"
else
	for entry in "${REPO_RULES[@]}"; do
		assert_rule "$REPO_CLAUDE_MD" "${REPO_CLAUDE_MD}: ${entry%%|*}" "${entry#*|}"
	done
fi

# --- 2. AGENTS.md: contributor rules that must stay repo-tracked -----------
# These moved out of .claude/CLAUDE.md when it was trimmed to skein-specific
# rules. They are contributor-facing, so they must live in a tracked file
# rather than only in the operator's personal ~/.claude/CLAUDE.md. Like block
# 1, it runs unconditionally on a CI runner.
AGENTS_MD="AGENTS.md"
AGENTS_RULES=(
	"bans the sweeping git add forms|git add -A"
	"requires feature branches over commits to main|feature branches"
	"forbids squash-merging|never squash-merge"
	"requires a secrets check before committing|secrets before committing|private keys"
	"requires ruff format as well as ruff check before pushing|ruff format. AND .ruff check"
	"requires a backgrounded just ci before opening or updating a PR|just ci. before opening or updating a PR"
)
if [[ ! -f "$AGENTS_MD" ]]; then
	fail "repo file missing: $AGENTS_MD"
else
	for entry in "${AGENTS_RULES[@]}"; do
		assert_rule "$AGENTS_MD" "${AGENTS_MD}: ${entry%%|*}" "${entry#*|}"
	done
fi

# --- Summary -----------------------------------------------------------------
echo
echo "test-claude-md-hygiene.sh: $PASS_COUNT passed, $FAIL_COUNT failed"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
	exit 1
fi

exit 0
