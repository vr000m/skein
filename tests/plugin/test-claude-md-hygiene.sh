#!/usr/bin/env bash
# Phase 4 acceptance test: assert the four insights-report hygiene failures
# each have a written rule or a mechanical guard.
#
# Ownership split (see .claude/CLAUDE.md): the global ~/.claude/CLAUDE.md is
# owned by the sync-computer repo and carries the cross-project hygiene rules;
# the repo .claude/CLAUDE.md carries only skein-specific rules. So:
#
#  1. Repo .claude/CLAUDE.md unconditionally carries its skein-specific rules
#     (release via skein:release, the review gates, backgrounded `just ci`).
#     It is NOT required to restate the global hygiene rules.
#  2. The global ~/.claude/CLAUDE.md is checked only via GLOBAL_CLAUDE_MD:
#     unset/absent -> explicit SKIP (the norm when the operator has not synced
#     the global file); set+present -> the three hygiene rules are asserted by
#     CONTENT, not by heading, because sync-computer is free to reorganise its
#     own headings (it folded "Security & Diff Reviews" into "Review Workflow"
#     in sync-computer PR #26 without dropping the rule).
#     Blocks 2 and 3 both SKIP on a CI runner (no GLOBAL_CLAUDE_MD, no
#     ~/.claude/hooks), so `just ci` proves only block 1. The three global
#     hygiene rules and the hook fix are operator-verified: run this locally
#     with GLOBAL_CLAUDE_MD=$HOME/.claude/CLAUDE.md to exercise them.
#  3. The ruff format-on-edit hook fix is checked only when reachable via
#     HOOK_PATH (or the default $HOME/.claude/hooks/format-on-edit.sh):
#     absent -> explicit SKIP; present -> grep the `ruff check --fix` line
#     for `--ignore RUF100`.
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

# The three hygiene rules, matched by content so either file is free to
# organise its own headings. Each entry is "<label>|<extended-regex>": the
# FIRST "|" separates the two, so the regex may itself use "|" for alternation
# (the label may not contain one).
#
# Each pattern must be specific enough that deleting the rule it names fails
# the assertion -- a bare token that also appears in a neighbouring rule makes
# the check vacuous (`run_in_background` alone also matches the unrelated
# "pair background processes with a Monitor" rule).
GLOBAL_RULES=(
	"backgrounds the full test suite|full test suite.*run_in_background|run_in_background.*full test suite"
	"requires a primary source over inferred CI state|primary source|gh run view"
	"requires scope-summary-first, severity-first reviews|scope summary|severity-first"
)

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

# --- 2. Global ~/.claude/CLAUDE.md: gated on GLOBAL_CLAUDE_MD ---------------
if [[ -z "${GLOBAL_CLAUDE_MD:-}" ]]; then
	skip "GLOBAL_CLAUDE_MD not set — global CLAUDE.md hygiene check skipped (norm when the global file is not synced)"
elif [[ ! -f "$GLOBAL_CLAUDE_MD" ]]; then
	skip "GLOBAL_CLAUDE_MD set to '$GLOBAL_CLAUDE_MD' but file does not exist — skipped"
else
	for entry in "${GLOBAL_RULES[@]}"; do
		assert_rule "$GLOBAL_CLAUDE_MD" "${GLOBAL_CLAUDE_MD}: ${entry%%|*}" "${entry#*|}"
	done
fi

# --- 3. ruff hook fix: gated on HOOK_PATH / default location ----------------
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
