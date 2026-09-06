#!/usr/bin/env bash
# Phase 5 clean-index guard for scripts/apply-auto-fix-code.sh.
#
# The code applier must refuse to start when the working tree or index is
# dirty. Rejection must happen before edits, before commits, and without
# disturbing the pre-existing staged/unstaged/untracked state.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

require_applier

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

status_without_manifest() {
	git -C "$1" status --short | grep -v '^?? \.deep-review/' || true
}

assert_guarded() {
	local label="$1" repo="$2" before_head="$3" expected_status="$4"
	if [[ $LAST_RC -ne 0 ]]; then
		pass "$label: exited non-zero before applying"
	else
		fail "$label: exited zero despite dirty tree"
	fi
	local after_head
	after_head="$(head_sha "$repo")"
	if [[ "$after_head" == "$before_head" ]]; then
		pass "$label: HEAD preserved"
	else
		fail "$label: HEAD advanced"
	fi
	if grep -q '^auto-fix(deep-review):' <<<"$(git -C "$repo" log -1 --format=%s)"; then
		fail "$label: auto-fix commit was created"
	else
		pass "$label: no auto-fix commit"
	fi
	local actual_status
	actual_status="$(status_without_manifest "$repo")"
	if [[ "$actual_status" == "$expected_status" ]]; then
		pass "$label: dirty state preserved"
	else
		fail "$label: dirty state changed"
		printf 'expected:\n%s\nactual:\n%s\n' "$expected_status" "$actual_status" | sed 's/^/  /'
	fi
}

# Case 1: unstaged tracked change on the auto-fix target.
d1="$scratch/unstaged-target"
mkdir -p "$d1"
make_repo "$d1" >/dev/null
printf 'from os import path\n' >"$d1/a.py"
git -C "$d1" add a.py
git -C "$d1" commit -q -m "add target"
printf '# operator edit\n' >>"$d1/a.py"
before="$(head_sha "$d1")"
expected="$(status_without_manifest "$d1")"
run_applier "$d1" --test-cmd "true" "$FIXTURES_DIR/unused_import-accept.jsonl"
assert_guarded "unstaged-target" "$d1" "$before" "$expected"
if grep -Fq "from os import path" "$d1/a.py" && grep -Fq "# operator edit" "$d1/a.py"; then
	pass "unstaged-target: target content untouched"
else
	fail "unstaged-target: target content changed"
fi

# Case 2: unrelated staged file in the index.
d2="$scratch/staged-unrelated"
mkdir -p "$d2"
make_repo "$d2" >/dev/null
printf 'from os import path\n' >"$d2/a.py"
git -C "$d2" add a.py
git -C "$d2" commit -q -m "add target"
printf 'staged operator work\n' >"$d2/b.txt"
git -C "$d2" add b.txt
before="$(head_sha "$d2")"
expected="$(status_without_manifest "$d2")"
run_applier "$d2" --test-cmd "true" "$FIXTURES_DIR/unused_import-accept.jsonl"
assert_guarded "staged-unrelated" "$d2" "$before" "$expected"
if grep -Fq "+staged operator work" <<<"$(git -C "$d2" diff --cached -- b.txt)"; then
	pass "staged-unrelated: staged content preserved"
else
	fail "staged-unrelated: staged content changed"
fi

# Case 3: staged A + unstaged B + untracked C, with target otherwise clean.
d3="$scratch/mixed-dirty"
mkdir -p "$d3"
make_repo "$d3" >/dev/null
printf 'from os import path\n' >"$d3/target.py"
printf 'a base\n' >"$d3/a.txt"
printf 'b base\n' >"$d3/b.txt"
git -C "$d3" add target.py a.txt b.txt
git -C "$d3" commit -q -m "add files"
printf 'a staged\n' >"$d3/a.txt"
git -C "$d3" add a.txt
printf 'b unstaged\n' >"$d3/b.txt"
printf 'c untracked\n' >"$d3/c.txt"
cat >"$d3/findings.json" <<'JSON'
{"schema_version":2,"findings":[{"lens":"logic","severity":"Minor","category":"unused","file":"target.py","line":1,"summary":"unused import","evidence":"never referenced","suggestion":"remove import","auto_fix":{"kind":"unused_import","before":"from os import path\n","after":"","scope":"file"},"auto_fix_status":"would_apply"}]}
JSON
before="$(head_sha "$d3")"
expected="$(status_without_manifest "$d3")"
run_applier "$d3" --test-cmd "true" "$d3/findings.json"
assert_guarded "mixed-dirty" "$d3" "$before" "$expected"
if grep -Fq "+a staged" <<<"$(git -C "$d3" diff --cached -- a.txt)"; then
	pass "mixed-dirty: staged A preserved"
else
	fail "mixed-dirty: staged A changed"
fi
if grep -Fq "+b unstaged" <<<"$(git -C "$d3" diff -- b.txt)"; then
	pass "mixed-dirty: unstaged B preserved"
else
	fail "mixed-dirty: unstaged B changed"
fi
if [[ -f "$d3/c.txt" ]] && grep -Fq "c untracked" "$d3/c.txt"; then
	pass "mixed-dirty: untracked C preserved"
else
	fail "mixed-dirty: untracked C missing or changed"
fi

summary_and_exit
