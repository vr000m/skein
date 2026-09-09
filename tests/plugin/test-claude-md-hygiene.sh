#!/usr/bin/env bash
# Phase 4 acceptance test: assert the four insights-report hygiene failures
# each have a written rule or a mechanical guard.
#
# Ownership split (see AGENTS.md): the global ~/.claude/CLAUDE.md is owned by
# the sync-computer repo, which since its PR #27 enforces the three
# cross-project hygiene rules in its OWN CI (.github/workflows/ci.yml +
# scripts/check-claude-md-hygiene.sh there). This file therefore no longer
# asserts anything about the global file -- that block was removed rather
# than left as a duplicate that only ran when an operator set an env var.
#
#  1. Repo .claude/CLAUDE.md unconditionally carries its skein-specific rules
#     (release via skein:release, the review gates, backgrounded `just ci`).
#     It is NOT required to restate the global hygiene rules.
#  1b. AGENTS.md unconditionally carries the contributor rules that must stay
#     repo-tracked (sweeping-git-add ban, secrets check, feature branches,
#     ruff format alongside ruff check). Both these blocks run on a CI runner.
#  2. The ruff format-on-edit hook fix is checked only when reachable via
#     HOOK_PATH (or the default $HOME/.claude/hooks/format-on-edit.sh):
#     absent -> explicit SKIP; present -> grep the `ruff check --fix` line
#     for `--ignore RUF100`. The hook is also sync-computer-owned, so this
#     block SKIPs on a CI runner and is operator-verified only.
#
# This test does not own tests/plugin/noqa-probe.sh (a parallel implementer
# owns that reproduction script) and does not edit implementation files.

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

skip() {
	echo "SKIP: $1"
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
	"repo file names the review gates|review-gauntlet"
	"repo file backgrounds the full CI run|background.*just ci|just ci.*run_in_background"
)
if [[ ! -f "$REPO_CLAUDE_MD" ]]; then
	fail "repo file missing: $REPO_CLAUDE_MD"
else
	for entry in "${REPO_RULES[@]}"; do
		assert_rule "$REPO_CLAUDE_MD" "${REPO_CLAUDE_MD}: ${entry%%|*}" "${entry#*|}"
	done
fi

# --- 1b. AGENTS.md: contributor rules that must stay repo-tracked -----------
# These moved out of .claude/CLAUDE.md when it was trimmed to skein-specific
# rules. They are contributor-facing, so they must live in a tracked file
# rather than only in the operator's personal ~/.claude/CLAUDE.md. Unlike
# block 2, this block runs on a CI runner.
AGENTS_MD="AGENTS.md"
AGENTS_RULES=(
	"bans the sweeping git add forms|git add -A"
	"requires feature branches over commits to main|feature branches"
	"forbids squash-merging|never squash-merge|squash-merge"
	"requires a secrets check before committing|secrets before committing|private keys"
	"requires ruff format as well as ruff check before pushing|ruff format. AND .ruff check"
)
if [[ ! -f "$AGENTS_MD" ]]; then
	fail "repo file missing: $AGENTS_MD"
else
	for entry in "${AGENTS_RULES[@]}"; do
		assert_rule "$AGENTS_MD" "${AGENTS_MD}: ${entry%%|*}" "${entry#*|}"
	done
fi

# --- 2. ruff hook fix: gated on HOOK_PATH / default location ----------------
DEFAULT_HOOK_PATH="${HOME}/.claude/hooks/format-on-edit.sh"
HOOK_PATH="${HOOK_PATH:-$DEFAULT_HOOK_PATH}"

if [[ ! -f "$HOOK_PATH" ]]; then
	skip "hook not found at '$HOOK_PATH' (set HOOK_PATH to override) — ruff fix check skipped"
else
	# The `ruff check --fix` line must carry `--ignore RUF100` so the hook
	# stops stripping `# noqa` comments that select RUF100 (unused noqa).
	if grep -q -F -- "--ignore RUF100" <<<"$(grep -F -- "ruff check --fix" "$HOOK_PATH")"; then
		pass "$HOOK_PATH: ruff check --fix line carries --ignore RUF100"
	else
		fail "$HOOK_PATH: ruff check --fix line missing --ignore RUF100"
	fi
fi

# --- Summary -----------------------------------------------------------------
echo
echo "test-claude-md-hygiene.sh: $PASS_COUNT passed, $FAIL_COUNT failed"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
	exit 1
fi

exit 0
