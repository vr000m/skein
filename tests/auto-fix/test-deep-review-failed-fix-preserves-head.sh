#!/usr/bin/env bash
# AC #4 (part 2): starting from a repo with a real prior commit, force a
# test failure and assert HEAD still points to the prior commit. Files are
# restored from saved blobs (NOT by `git revert HEAD`) — verified by
# checking that HEAD's parent is still the init commit and no revert commit
# was added.
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
printf 'from os import path\nx = 1\n' >"$d/a.py"
git -C "$d" add a.py
git -C "$d" commit -q -m "real prior commit"
prior_head="$(head_sha "$d")"
prior_log_count="$(git -C "$d" rev-list --count HEAD)"
prior_content="$(cat "$d/a.py")"

run_applier "$d" --test-cmd "false" "$FIXTURES_DIR/unused_import-accept.jsonl"

now_head="$(head_sha "$d")"
now_log_count="$(git -C "$d" rev-list --count HEAD)"

if [[ "$now_head" == "$prior_head" ]]; then
	pass "HEAD unchanged after failed test gate"
else
	fail "HEAD moved from $prior_head to $now_head"
fi

if [[ "$now_log_count" == "$prior_log_count" ]]; then
	pass "no new commits added (revert path NOT taken)"
else
	fail "commit count changed: $prior_log_count -> $now_log_count (suggests git revert was used)"
	git -C "$d" log --oneline | sed 's/^/  /'
fi

if [[ "$(cat "$d/a.py")" == "$prior_content" ]]; then
	pass "a.py restored to prior content from saved blob"
else
	fail "a.py not restored"
	diff <(printf '%s' "$prior_content") "$d/a.py" | sed 's/^/  /' || true
fi

dirty="$(git -C "$d" status --porcelain | grep -v '^?? \.deep-review/' || true)"
if [[ -z "$dirty" ]]; then
	pass "working tree clean after restore (manifest dir ignored)"
else
	fail "working tree dirty after restore"
	printf '%s\n' "$dirty" | sed 's/^/  /'
fi

manifest="$(find "$d/.deep-review" -name 'auto-fix-*.json' -print -quit 2>/dev/null || true)"
if [[ -n "${manifest:-}" ]] && grep -q "test_failed" "$manifest"; then
	pass "manifest records status=test_failed"
else
	fail "manifest missing status=test_failed"
	[[ -n "${manifest:-}" ]] && sed 's/^/  /' "$manifest"
fi

summary_and_exit
