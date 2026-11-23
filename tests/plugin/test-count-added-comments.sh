#!/usr/bin/env bash
# Fixture test for scripts/count-added-comments.sh: builds a throwaway git repo
# and asserts the counter's heuristic on each case the plan names (comments in
# every counted file type, shebang, each pragma, license headers, TODO link
# forms, heredoc bodies, removed lines, markdown markers, an explicit head over
# a merge commit, and --verbose output).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COUNTER="$REPO_ROOT/scripts/count-added-comments.sh"

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

assert_eq() {
	local label="$1" want="$2" got="$3"
	if [[ "$want" == "$got" ]]; then
		pass "$label"
	else
		fail "$label (want '$want', got '$got')"
	fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"
git init -q -b main .
git config user.email test@example.invalid
git config user.name test

# --- base commit: one pre-existing comment that must never count -----------
cat >a.sh <<'EOF'
#!/usr/bin/env bash
# pre-existing comment
echo hi
EOF
git add a.sh
git commit -q -m base
base="$(git rev-parse HEAD)"

# --- head commit: every case the counter must classify ---------------------
cat >a.sh <<'EOF'
#!/usr/bin/env bash
# added comment
# shellcheck disable=SC2086
# TODO: fix this
# TODO(#12): linked by number
# TODO https://example.invalid/issues/3 linked by URL
echo hi
cat <<'HEREDOC'
# heredoc body line, not a comment
HEREDOC
cat <<-INDENTED
	# indented heredoc body, not a comment
	INDENTED
x=$(cat <<<"herestring")
EOF
cat >b.py <<'EOF'
#!/usr/bin/env python3
# Copyright 2026 Example
# SPDX-License-Identifier: MIT
# noqa: E501
# type: ignore
# added py comment
x = 1
EOF
printf '# jq comment\n.\n' >c.jq
printf '# just comment\ndefault:\n\techo ok\n' >justfile
printf '<!-- BEGIN X -->\n# markdown heading\n' >notes.md
git add a.sh b.py c.jq justfile notes.md
git commit -q -m head
head1="$(git rev-parse HEAD)"

assert_eq "total over fixture" "5" "$("$COUNTER" "$base" "$head1")"
assert_eq "head defaults to HEAD" "5" "$("$COUNTER" "$base")"

verbose="$("$COUNTER" --verbose "$base" "$head1")"
case "$verbose" in
*"2 a.sh"*) pass "verbose names a.sh with 2" ;;
*) fail "verbose missing '2 a.sh': $verbose" ;;
esac
case "$verbose" in
*"1 b.py"*"1 c.jq"*"1 justfile"*) pass "verbose names py, jq and justfile" ;;
*) fail "verbose missing py/jq/justfile entries: $verbose" ;;
esac
case "$verbose" in
*"total 5") pass "verbose ends with total" ;;
*) fail "verbose missing total line: $verbose" ;;
esac

# --- removed comment line: only added lines count --------------------------
git rm -q -f c.jq
sed -i.bak '/^# added comment$/d' a.sh && rm -f a.sh.bak
git add a.sh
git commit -q -m "remove comments"
assert_eq "removed comment lines never count" "0" "$("$COUNTER" "$head1" HEAD)"

# --- explicit head over a merge commit -------------------------------------
git checkout -q -b feat
printf '#!/usr/bin/env bash\n# feature comment\n' >d.sh
git add d.sh
git commit -q -m feature
git checkout -q main
git merge -q --no-ff feat -m merge
merge="$(git rev-parse HEAD)"
assert_eq "merge commit measured as M^1 M" "1" "$("$COUNTER" "$merge^1" "$merge")"
assert_eq "explicit head differs from HEAD range" "1" "$("$COUNTER" "$head1" "$merge")"

# --- argument handling ------------------------------------------------------
if "$COUNTER" >/dev/null 2>&1; then
	fail "missing base argument must fail"
else
	pass "missing base argument fails"
fi

echo "---"
echo "passed: $PASS_COUNT failed: $FAIL_COUNT"
[[ "$FAIL_COUNT" -eq 0 ]]
