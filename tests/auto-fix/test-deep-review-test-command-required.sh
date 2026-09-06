#!/usr/bin/env bash
# AC #3: the applier exits non-zero with a clear error before any edits
# when neither --test-cmd nor AUTO_FIX_TEST_CMD is supplied.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/auto-fix/lib.sh disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_applier

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

d="$scratch/repo"
mkdir -p "$d"
make_repo "$d" >/dev/null
printf 'from os import path\n' >"$d/a.py"
git -C "$d" add a.py
git -C "$d" commit -q -m "add a.py"
before_head="$(head_sha "$d")"
before_content="$(cat "$d/a.py")"

cp "$FIXTURES_DIR/unused_import-accept.jsonl" "$d/findings.json"

# Explicitly unset AUTO_FIX_TEST_CMD and do NOT pass --test-cmd.
set +e
LAST_OUT="$(
	cd "$d" && unset AUTO_FIX_TEST_CMD
	bash "$APPLIER" "$d/findings.json" 2>&1
)"
LAST_RC=$?
set -e

if [[ $LAST_RC -eq 0 ]]; then
	fail "missing --test-cmd: applier returned 0 (expected non-zero)"
else
	pass "missing --test-cmd: applier exited non-zero ($LAST_RC)"
fi

if [[ "$(head_sha "$d")" != "$before_head" ]]; then
	fail "missing --test-cmd: HEAD advanced before validation"
else
	pass "missing --test-cmd: HEAD preserved"
fi

if [[ "$(cat "$d/a.py")" != "$before_content" ]]; then
	fail "missing --test-cmd: a.py modified before validation"
else
	pass "missing --test-cmd: a.py untouched"
fi

# Error message must reference the missing test command requirement.
if grep -Eqi 'test[-_ ]cmd|AUTO_FIX_TEST_CMD|test command' <<<"$LAST_OUT"; then
	pass "missing --test-cmd: error mentions test command requirement"
else
	fail "missing --test-cmd: error did not mention test-cmd / AUTO_FIX_TEST_CMD"
	# shellcheck disable=SC2001  # per-line prefix over a multiline var; param expansion cannot anchor ^ per-line
	echo "$LAST_OUT" | sed 's/^/  /'
fi

summary_and_exit
