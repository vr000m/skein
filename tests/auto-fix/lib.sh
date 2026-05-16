#!/usr/bin/env bash
# Shared helpers for tests/auto-fix/* — sets REPO_ROOT, APPLIER, makes a
# scratch git repo, and exposes pass/fail counters.
set -euo pipefail

TESTS_AUTO_FIX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_AUTO_FIX_DIR/../.." && pwd)"
APPLIER="$REPO_ROOT/scripts/apply-auto-fix-code.sh"
FIXTURES_DIR="$TESTS_AUTO_FIX_DIR/fixtures"

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

summary_and_exit() {
	echo ""
	echo "Summary: $pass_count passed, $fail_count failed"
	if [[ $fail_count -ne 0 ]]; then
		exit 1
	fi
	exit 0
}

require_applier() {
	if [[ ! -f "$APPLIER" ]]; then
		fail "preflight: applier missing at $APPLIER"
		summary_and_exit
	fi
}

make_repo() {
	local dir="$1"
	(
		cd "$dir"
		git init -q
		git config user.email "test@example.com"
		git config user.name "Test"
		git commit --allow-empty -q -m "init"
	)
	echo "$dir"
}

head_sha() {
	git -C "$1" rev-parse HEAD
}

# run_applier <repo> <args...>
# Captures combined output in LAST_OUT, exit code in LAST_RC.
run_applier() {
	local repo="$1"
	shift
	set +e
	LAST_OUT="$(cd "$repo" && bash "$APPLIER" "$@" 2>&1)"
	LAST_RC=$?
	set -e
}
