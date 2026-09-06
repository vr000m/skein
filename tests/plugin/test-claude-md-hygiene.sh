#!/usr/bin/env bash
# Phase 4 acceptance test: assert the four insights-report hygiene failures
# each have a written rule or a mechanical guard.
#
#  1. Repo .claude/CLAUDE.md unconditionally carries the three H2 headings:
#     ## Testing, ## Facts vs Inference, ## Security & Diff Reviews.
#  2. The global ~/.claude/CLAUDE.md (owned by the sync-computer repo, not
#     skein) is checked only via GLOBAL_CLAUDE_MD: unset/absent -> explicit
#     SKIP (the norm when the operator has not synced the global file); set+present -> same
#     three headings asserted there too.
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

# assert_heading <file> <heading-text> <label>
assert_heading() {
	local file="$1"
	local heading="$2"
	local label="$3"
	if grep -q -F -- "$heading" "$file"; then
		pass "$label carries heading: $heading"
	else
		fail "$label missing heading: $heading"
	fi
}

REQUIRED_HEADINGS=(
	"## Testing"
	"## Facts vs Inference"
	"## Security & Diff Reviews"
)

# --- 1. Repo .claude/CLAUDE.md: unconditional --------------------------------
REPO_CLAUDE_MD=".claude/CLAUDE.md"
if [[ ! -f "$REPO_CLAUDE_MD" ]]; then
	fail "repo file missing: $REPO_CLAUDE_MD"
else
	for heading in "${REQUIRED_HEADINGS[@]}"; do
		assert_heading "$REPO_CLAUDE_MD" "$heading" "$REPO_CLAUDE_MD"
	done
fi

# --- 2. Global ~/.claude/CLAUDE.md: gated on GLOBAL_CLAUDE_MD ---------------
if [[ -z "${GLOBAL_CLAUDE_MD:-}" ]]; then
	skip "GLOBAL_CLAUDE_MD not set — global CLAUDE.md hygiene check skipped (norm when the global file is not synced)"
elif [[ ! -f "$GLOBAL_CLAUDE_MD" ]]; then
	skip "GLOBAL_CLAUDE_MD set to '$GLOBAL_CLAUDE_MD' but file does not exist — skipped"
else
	for heading in "${REQUIRED_HEADINGS[@]}"; do
		assert_heading "$GLOBAL_CLAUDE_MD" "$heading" "$GLOBAL_CLAUDE_MD"
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
