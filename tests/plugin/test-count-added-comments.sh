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
# after herestring
echo "use <<EOF in docs"
# after quoted opener
y=$((1<<n))
# after arithmetic
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
printf '# just comment\ndefault:\n\tcat <<EOF\n\t# heredoc body in a recipe\n\tEOF\n\t# after recipe heredoc\n' >justfile
printf '<!-- BEGIN X -->\n# markdown heading\n' >notes.md
git add a.sh b.py c.jq justfile notes.md
git commit -q -m head
head1="$(git rev-parse HEAD)"

assert_eq "total over fixture" "9" "$("$COUNTER" "$base" "$head1")"
assert_eq "head defaults to HEAD" "9" "$("$COUNTER" "$base")"

verbose="$("$COUNTER" --verbose "$base" "$head1")"
case "$verbose" in
*"5 a.sh"*) pass "verbose names a.sh with 5" ;;
*) fail "verbose missing '5 a.sh': $verbose" ;;
esac
case "$verbose" in
*"1 b.py"*"1 c.jq"*"2 justfile"*) pass "verbose names py, jq and justfile" ;;
*) fail "verbose missing py/jq/justfile entries: $verbose" ;;
esac
case "$verbose" in
*"total 9") pass "verbose ends with total" ;;
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

# --- interHunkContext must not pull unchanged comments into the count ------
printf '# keep 1\necho a\n# keep 2\necho b\n' >e.sh
git add e.sh
git commit -q -m "e base"
e_base="$(git rev-parse HEAD)"
printf '# new 1\n# keep 1\necho a\n# keep 2\necho b\n# new 2\n' >e.sh
git add e.sh
git commit -q -m "e head"
assert_eq "merged hunks count only added lines" "2" \
	"$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=diff.interHunkContext GIT_CONFIG_VALUE_0=1000 \
		"$COUNTER" "$e_base" HEAD)"

# --- explicit head: HEAD has moved past $merge, so the two ranges differ ---
assert_eq "explicit head is honoured when HEAD is later" "1" "$("$COUNTER" "$head1" "$merge")"
assert_eq "same base against HEAD counts the later commits" "5" "$("$COUNTER" "$head1")"

# --- a subdirectory run sees the same repo-root paths ----------------------
mkdir -p sub
assert_eq "counts the same from a subdirectory" "1" "$(cd sub && "$COUNTER" "$merge^1" "$merge")"

# --- every heredoc body on one command is skipped --------------------------
f_base="$(git rev-parse HEAD)"
printf 'cat <<FIRST <<SECOND\nfirst body\nFIRST\n# second body, not a comment\nSECOND\n# after both\n' >f.sh
git add f.sh
git commit -q -m "two heredocs"
assert_eq "both heredoc bodies on one line are skipped" "1" "$("$COUNTER" "$f_base" HEAD)"

# --- an indented justfile recipe shebang is not a comment ------------------
j_base="$(git rev-parse HEAD)"
printf 'script:\n    #!/usr/bin/env bash\n    # recipe comment\n    echo hi\n' >>justfile
git add justfile
git commit -q -m "shebang recipe"
assert_eq "justfile recipe shebang is excluded" "1" "$("$COUNTER" "$j_base" HEAD)"

# --- a hyphenated heredoc delimiter still closes its body -------------------
h_base="$(git rev-parse HEAD)"
printf "cat <<'END-OF-TEXT'\n# heredoc body, not a comment\nEND-OF-TEXT\n# after the heredoc\n" >h.sh
git add h.sh
git commit -q -m "hyphenated heredoc"
assert_eq "a hyphenated heredoc delimiter is honoured" "1" "$("$COUNTER" "$h_base" HEAD)"

# --- a pure rename adds no comments; an edited rename counts only its edit --
r_base="$(git rev-parse HEAD)"
git mv e.sh renamed-e.sh
git commit -q -m "pure rename"
assert_eq "a pure rename counts no comment" "0" "$("$COUNTER" "$r_base" HEAD)"
r_base="$(git rev-parse HEAD)"
git mv renamed-e.sh renamed-again.sh
printf '# added on rename\n' >>renamed-again.sh
git add renamed-again.sh
git commit -q -m "rename with an edit"
assert_eq "a rename with an added comment counts only that comment" "1" "$("$COUNTER" "$r_base" HEAD)"

# --- a rename into a counted file type counts only its edit ----------------
printf '# kept 1\n# kept 2\necho a\n' >notes.txt
git add notes.txt
git commit -q -m "uncounted type"
t_base="$(git rev-parse HEAD)"
git mv notes.txt notes.sh
printf '# added on type rename\n' >>notes.sh
git add notes.sh
git commit -q -m "rename into a counted type"
assert_eq "a rename into a counted type counts only its added comment" "1" "$("$COUNTER" "$t_base" HEAD)"

# --- a numeric heredoc delimiter still closes its body ---------------------
n_base="$(git rev-parse HEAD)"
printf "cat <<'123'\n# heredoc body, not a comment\n123\n# after the heredoc\n" >n.sh
git add n.sh
git commit -q -m "numeric heredoc"
assert_eq "a numeric heredoc delimiter is honoured" "1" "$("$COUNTER" "$n_base" HEAD)"

# --- argument handling ------------------------------------------------------
if "$COUNTER" >/dev/null 2>&1; then
	fail "missing base argument must fail"
else
	pass "missing base argument fails"
fi
rc=0
out="$("$COUNTER" no-such-ref-xyz 2>/dev/null)" || rc=$?
assert_eq "invalid base exits 2" "2" "$rc"
assert_eq "invalid base prints no count" "" "$out"
rc=0
out="$("$COUNTER" "$base" no-such-ref-xyz 2>/dev/null)" || rc=$?
assert_eq "invalid head exits 2" "2" "$rc"
rc=0
"$COUNTER" "--output=$tmp/pwned" >/dev/null 2>&1 || rc=$?
assert_eq "dash-prefixed base is rejected" "2" "$rc"
if compgen -G "$tmp/pwned*" >/dev/null; then
	fail "dash-prefixed base reached git as an option and wrote a file"
else
	pass "dash-prefixed base is never parsed as a git option"
fi

echo "---"
echo "passed: $PASS_COUNT failed: $FAIL_COUNT"
[[ "$FAIL_COUNT" -eq 0 ]]
