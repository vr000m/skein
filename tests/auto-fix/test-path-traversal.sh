#!/usr/bin/env bash
# Path-traversal containment regression for both appliers.
#
# Verifies that resolve_path rejects:
#   - absolute paths in finding `.file` / scope `<path>:<line>`
#   - paths containing `..` segments
# In every case HEAD stays unchanged, no target file is written, and the
# manifest records status=rejected_path.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

require_applier
require_plan_applier

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# --- Helpers ------------------------------------------------------------

# Find the most-recent manifest under the given repo's per-skill dir.
latest_manifest() {
	local repo="$1" skill_dir="$2"
	ls -t "$repo/$skill_dir"/auto-fix-*.json 2>/dev/null | head -n 1
}

# Assert no `auto_fix(...)` commit exists in the repo's history.
assert_no_apply_commit() {
	local repo="$1" tag="$2"
	if git -C "$repo" log --oneline | grep -q '^[0-9a-f]\+ auto-fix('; then
		fail "$tag: an auto-fix commit landed (expected HEAD unchanged)"
		git -C "$repo" log --oneline | sed 's/^/  /' >&2
	else
		pass "$tag: HEAD preserved (no auto-fix commit)"
	fi
}

assert_manifest_status() {
	local manifest="$1" want="$2" tag="$3"
	if [[ -z "$manifest" || ! -f "$manifest" ]]; then
		fail "$tag: no manifest at $manifest"
		return
	fi
	local got
	got="$(jq -r '.[0].status // "MISSING"' "$manifest")"
	if [[ "$got" == "$want" ]]; then
		pass "$tag: manifest status=$want"
	else
		fail "$tag: manifest status=$got (expected $want)"
		jq . "$manifest" | sed 's/^/  /' >&2
	fi
}

# --- /deep-review code applier ------------------------------------------

# absolute path in .file
case1="$scratch/code-abs"
mkdir -p "$case1"
make_repo "$case1" >/dev/null
echo "marker" >"$case1/a.py"
git -C "$case1" add a.py
git -C "$case1" commit -q -m a
sentinel="$scratch/sentinel-abs"
echo "untouched" >"$sentinel"
cat >"$case1/findings.json" <<JSON
{"schema_version":2,"findings":[{"lens":"logic","severity":"Minor","category":"unused","file":"$sentinel","line":1,"summary":"x","auto_fix":{"kind":"unused_import","before":"untouched\n","after":"","scope":"file"},"auto_fix_status":"would_apply"}]}
JSON
run_applier "$case1" --test-cmd "true" "$case1/findings.json"
assert_no_apply_commit "$case1" "code-abs"
[[ "$(cat "$sentinel")" == "untouched" ]] && pass "code-abs: out-of-repo sentinel untouched" || fail "code-abs: sentinel was written!"
assert_manifest_status "$(latest_manifest "$case1" ".deep-review")" "rejected_path" "code-abs"

# ../ traversal in .file
case2="$scratch/code-traversal"
mkdir -p "$case2"
make_repo "$case2" >/dev/null
sentinel2="$scratch/sentinel-traversal"
echo "untouched" >"$sentinel2"
# The relative path traverses out of $case2 and back to the sentinel.
rel_traversal="../$(basename "$sentinel2")"
cat >"$case2/findings.json" <<JSON
{"schema_version":2,"findings":[{"lens":"logic","severity":"Minor","category":"unused","file":"$rel_traversal","line":1,"summary":"x","auto_fix":{"kind":"unused_import","before":"untouched\n","after":"","scope":"file"},"auto_fix_status":"would_apply"}]}
JSON
run_applier "$case2" --test-cmd "true" "$case2/findings.json"
assert_no_apply_commit "$case2" "code-traversal"
[[ "$(cat "$sentinel2")" == "untouched" ]] && pass "code-traversal: out-of-repo sentinel untouched" || fail "code-traversal: sentinel was written!"
assert_manifest_status "$(latest_manifest "$case2" ".deep-review")" "rejected_path" "code-traversal"

# --- /review-plan plan applier ------------------------------------------

# absolute path in scope
case3="$scratch/plan-abs"
mkdir -p "$case3"
make_repo "$case3" >/dev/null
sentinel3="$scratch/sentinel-plan-abs.md"
printf '# heading\n\nthe wrong word\n' >"$sentinel3"
cat >"$case3/findings.json" <<JSON
{"schema_version":2,"findings":[{"lens":"review-plan","severity":"Minor","category":"prose","file":"$sentinel3","line":3,"summary":"typo","auto_fix":{"kind":"prose_typo","before":"the wrong word","after":"the right word","scope":"$sentinel3:3"},"auto_fix_status":"would_apply"}]}
JSON
run_plan_applier "$case3" "$case3/findings.json"
assert_no_apply_commit "$case3" "plan-abs"
[[ "$(grep -c 'wrong' "$sentinel3")" -eq 1 ]] && pass "plan-abs: out-of-repo plan untouched" || fail "plan-abs: out-of-repo plan was modified!"
assert_manifest_status "$(latest_manifest "$case3" ".review-plan")" "rejected_path" "plan-abs"

# ../ traversal in scope
case4="$scratch/plan-traversal"
mkdir -p "$case4"
make_repo "$case4" >/dev/null
sentinel4="$scratch/sentinel-plan-traversal.md"
printf '# heading\n\nthe wrong word\n' >"$sentinel4"
rel_plan="../$(basename "$sentinel4")"
cat >"$case4/findings.json" <<JSON
{"schema_version":2,"findings":[{"lens":"review-plan","severity":"Minor","category":"prose","file":"$rel_plan","line":3,"summary":"typo","auto_fix":{"kind":"prose_typo","before":"the wrong word","after":"the right word","scope":"$rel_plan:3"},"auto_fix_status":"would_apply"}]}
JSON
run_plan_applier "$case4" "$case4/findings.json"
assert_no_apply_commit "$case4" "plan-traversal"
[[ "$(grep -c 'wrong' "$sentinel4")" -eq 1 ]] && pass "plan-traversal: out-of-repo plan untouched" || fail "plan-traversal: out-of-repo plan was modified!"
assert_manifest_status "$(latest_manifest "$case4" ".review-plan")" "rejected_path" "plan-traversal"

summary_and_exit
