#!/usr/bin/env bash
# Phase 5 kind-specific gates for scripts/apply-auto-fix-code.sh.
#
# These cases are stricter than allowlist membership: allowlisted kinds still
# need kind-specific proof before the applier may edit code.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

require_applier

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

manifest_for() {
	find "$1/.deep-review" -name 'auto-fix-*.json' -print -quit 2>/dev/null || true
}

assert_applied() {
	local label="$1" repo="$2" before_head="$3"
	local after_head manifest
	after_head="$(head_sha "$repo")"
	if [[ $LAST_RC -eq 0 ]]; then
		pass "$label: applier exited 0"
	else
		fail "$label: applier exited $LAST_RC"
		echo "$LAST_OUT" | sed 's/^/  /'
	fi
	if [[ "$after_head" != "$before_head" ]]; then
		pass "$label: HEAD advanced"
	else
		fail "$label: HEAD did not advance"
	fi
	manifest="$(manifest_for "$repo")"
	if [[ -n "${manifest:-}" ]] && grep -q '"applied"' "$manifest"; then
		pass "$label: manifest status=applied"
	else
		fail "$label: manifest missing status=applied"
		[[ -n "${manifest:-}" ]] && sed 's/^/  /' "$manifest"
	fi
}

assert_rejected() {
	local label="$1" repo="$2" before_head="$3" expected_status="$4"
	local after_head manifest
	after_head="$(head_sha "$repo")"
	if [[ "$after_head" == "$before_head" ]]; then
		pass "$label: HEAD preserved"
	else
		fail "$label: HEAD advanced"
	fi
	if git -C "$repo" log -1 --format=%s | grep -q '^auto-fix(deep-review):'; then
		fail "$label: auto-fix commit was created"
	else
		pass "$label: no auto-fix commit"
	fi
	manifest="$(manifest_for "$repo")"
	if [[ -n "${manifest:-}" ]] && grep -q "\"$expected_status\"" "$manifest"; then
		pass "$label: manifest status=$expected_status"
	else
		fail "$label: manifest missing status=$expected_status"
		[[ -n "${manifest:-}" ]] && sed 's/^/  /' "$manifest"
	fi
}

# docstring_typo accept: edit is inside a docstring.
d1="$scratch/docstring-accept"
mkdir -p "$d1"
make_repo "$d1" >/dev/null
cat >"$d1/a.py" <<'PY'
def f():
    """recieve a value"""
    return 1
PY
git -C "$d1" add a.py
git -C "$d1" commit -q -m "add docstring"
before="$(head_sha "$d1")"
run_applier "$d1" --test-cmd "true" "$FIXTURES_DIR/docstring_typo-accept.jsonl"
assert_applied "docstring_typo-accept" "$d1" "$before"
if grep -Fq '"""receive a value"""' "$d1/a.py"; then
	pass "docstring_typo-accept: docstring rewritten"
else
	fail "docstring_typo-accept: docstring not rewritten"
fi

# docstring_typo reject: claimed typo would edit executable code.
d2="$scratch/docstring-reject-code"
mkdir -p "$d2"
make_repo "$d2" >/dev/null
printf 'x = 1\n' >"$d2/a.py"
git -C "$d2" add a.py
git -C "$d2" commit -q -m "add code"
before="$(head_sha "$d2")"
run_applier "$d2" --test-cmd "true" "$FIXTURES_DIR/docstring_typo-reject-code-edit.jsonl"
assert_rejected "docstring_typo-reject-code-edit" "$d2" "$before" "rejected_kind_scope"
if [[ "$(cat "$d2/a.py")" == "x = 1" ]]; then
	pass "docstring_typo-reject-code-edit: code line untouched"
else
	fail "docstring_typo-reject-code-edit: code line changed"
fi

# import_sort accept: pure reorder with identical imported symbols.
d3="$scratch/import-sort-accept"
mkdir -p "$d3"
make_repo "$d3" >/dev/null
printf 'import sys\nimport os\n' >"$d3/a.py"
git -C "$d3" add a.py
git -C "$d3" commit -q -m "add imports"
before="$(head_sha "$d3")"
run_applier "$d3" --test-cmd "true" "$FIXTURES_DIR/import_sort-accept.jsonl"
assert_applied "import_sort-accept" "$d3" "$before"
if [[ "$(cat "$d3/a.py")" == $'import os\nimport sys' ]]; then
	pass "import_sort-accept: imports reordered only"
else
	fail "import_sort-accept: imports not reordered as expected"
fi

# import_sort reject: after adds/removes an imported symbol.
d4="$scratch/import-sort-reject"
mkdir -p "$d4"
make_repo "$d4" >/dev/null
printf 'import sys\nimport os\n' >"$d4/a.py"
git -C "$d4" add a.py
git -C "$d4" commit -q -m "add imports"
before="$(head_sha "$d4")"
run_applier "$d4" --test-cmd "true" "$FIXTURES_DIR/import_sort-reject-symbol-change.jsonl"
assert_rejected "import_sort-reject-symbol-change" "$d4" "$before" "rejected_semantic_change"
if ! grep -Fq "import socket" "$d4/a.py"; then
	pass "import_sort-reject-symbol-change: symbol set preserved"
else
	fail "import_sort-reject-symbol-change: new import was added"
fi

# unused_import accept: delete a single unreferenced import line.
d5="$scratch/unused-import-accept"
mkdir -p "$d5"
make_repo "$d5" >/dev/null
printf 'from os import path\n' >"$d5/a.py"
git -C "$d5" add a.py
git -C "$d5" commit -q -m "add import"
before="$(head_sha "$d5")"
run_applier "$d5" --test-cmd "true" "$FIXTURES_DIR/unused_import-accept.jsonl"
assert_applied "unused_import-accept" "$d5" "$before"
if [[ ! -s "$d5/a.py" ]]; then
	pass "unused_import-accept: import removed"
else
	fail "unused_import-accept: file not emptied"
fi

# unused_import reject: imported name is still referenced in code.
d6="$scratch/unused-import-reject"
mkdir -p "$d6"
make_repo "$d6" >/dev/null
printf 'from os import path\nprint(path)\n' >"$d6/a.py"
git -C "$d6" add a.py
git -C "$d6" commit -q -m "add referenced import"
before="$(head_sha "$d6")"
run_applier "$d6" --test-cmd "true" "$FIXTURES_DIR/unused_import-reject-still-referenced.jsonl"
assert_rejected "unused_import-reject-still-referenced" "$d6" "$before" "rejected_revar"
if grep -Fq "from os import path" "$d6/a.py"; then
	pass "unused_import-reject-still-referenced: import preserved"
else
	fail "unused_import-reject-still-referenced: import deleted"
fi

# unused_var reject: references from tests count as blocking reads.
d7="$scratch/unused-var-test-read"
mkdir -p "$d7/src_pkg" "$d7/tests"
make_repo "$d7" >/dev/null
printf 'my_var = 1\n' >"$d7/src_pkg/a.py"
printf 'from src_pkg.a import my_var\nassert my_var == 1\n' >"$d7/tests/test_a.py"
git -C "$d7" add src_pkg/a.py tests/test_a.py
git -C "$d7" commit -q -m "add var and test read"
before="$(head_sha "$d7")"
run_applier "$d7" --test-cmd "true" "$FIXTURES_DIR/unused_var-reject-test-file-read.jsonl"
assert_rejected "unused_var-reject-test-file-read" "$d7" "$before" "rejected_revar"
if grep -Fq "my_var = 1" "$d7/src_pkg/a.py"; then
	pass "unused_var-reject-test-file-read: variable preserved"
else
	fail "unused_var-reject-test-file-read: variable deleted"
fi

summary_and_exit
