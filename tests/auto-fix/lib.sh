#!/usr/bin/env bash
# Shared helpers for tests/auto-fix/* — sets REPO_ROOT, APPLIER, makes a
# scratch git repo, and exposes pass/fail counters.
set -euo pipefail

TESTS_AUTO_FIX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_AUTO_FIX_DIR/../.." && pwd)"
APPLIER="$REPO_ROOT/scripts/apply-auto-fix-code.sh"
PLAN_APPLIER="$REPO_ROOT/scripts/apply-auto-fix-plan.sh"
PLAN_SCOPE_DETECT="$REPO_ROOT/scripts/plan-scope-detect.sh"
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

require_plan_applier() {
	if [[ ! -f "$PLAN_APPLIER" ]]; then
		fail "preflight: plan applier missing at $PLAN_APPLIER"
		summary_and_exit
	fi
}

require_plan_scope_detect() {
	if [[ ! -f "$PLAN_SCOPE_DETECT" ]]; then
		fail "preflight: plan-scope-detect missing at $PLAN_SCOPE_DETECT"
		summary_and_exit
	fi
}

# instantiate_plan_fixture <md-fixture-name> <plan-md-dest> <jsonl-fixture-name> <jsonl-dest>
# Copies the .md fixture verbatim and rewrites the literal token PLAN_PATH in
# the JSONL fixture to the destination plan path (relative to the repo root,
# computed by the caller). Output JSONL is written to <jsonl-dest>.
instantiate_plan_fixture() {
	local md_fix="$1" md_dest="$2" jsonl_fix="$3" jsonl_dest="$4" plan_rel="$5"
	cp "$FIXTURES_DIR/$md_fix" "$md_dest"
	# Use awk for portable in-place substitution (avoids sed -i differences).
	awk -v repl="$plan_rel" '{ gsub(/PLAN_PATH/, repl); print }' \
		"$FIXTURES_DIR/$jsonl_fix" >"$jsonl_dest"
}

# run_plan_applier <repo> <args...>
run_plan_applier() {
	local repo="$1"
	shift
	set +e
	LAST_OUT="$(cd "$repo" && bash "$PLAN_APPLIER" "$@" 2>&1)"
	LAST_RC=$?
	set -e
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
