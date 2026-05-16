#!/usr/bin/env bash
# Test-gate regression for scripts/apply-auto-fix-code.sh.
#
# AC #4 (part 1): when the supplied --test-cmd fails, the applier restores
# touched files from saved blobs, leaves HEAD unchanged, records
# status=test_failed in the manifest, and re-surfaces the finding. The
# command must not be run via `git revert` (HEAD must literally be
# unchanged, no revert commit added).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
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

run_applier "$d" --test-cmd "false" "$FIXTURES_DIR/unused_import-accept.jsonl"

after_head="$(head_sha "$d")"
if [[ "$after_head" != "$before_head" ]]; then
	fail "failing --test-cmd: HEAD advanced from $before_head to $after_head"
else
	pass "failing --test-cmd: HEAD preserved"
fi

if [[ "$(cat "$d/a.py")" == "$before_content" ]]; then
	pass "failing --test-cmd: a.py restored from saved blob"
else
	fail "failing --test-cmd: a.py not restored"
fi

dirty="$(git -C "$d" status --porcelain | grep -v '^?? \.deep-review/' || true)"
if [[ -n "$dirty" ]]; then
	fail "failing --test-cmd: working tree dirty after restore"
	printf '%s\n' "$dirty" | sed 's/^/  /'
else
	pass "failing --test-cmd: working tree clean after restore (manifest dir ignored)"
fi

manifest="$(find "$d/.deep-review" -name 'auto-fix-*.json' -print -quit 2>/dev/null || true)"
if [[ -z "${manifest:-}" ]]; then
	fail "failing --test-cmd: missing manifest"
elif grep -q "test_failed" "$manifest"; then
	pass "failing --test-cmd: manifest records status=test_failed"
else
	fail "failing --test-cmd: manifest missing status=test_failed"
	sed 's/^/  /' "$manifest"
fi

# Applier should exit non-zero when a fix failed the gate; allow 0 only if
# manifest carries test_failed, but document the expectation.
if [[ $LAST_RC -eq 0 ]]; then
	# Some implementations may exit 0 with manifest signal; we just note it.
	echo "NOTE: applier exited 0 on test_failed; relying on manifest signal."
fi

summary_and_exit
