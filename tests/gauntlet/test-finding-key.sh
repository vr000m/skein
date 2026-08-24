#!/usr/bin/env bash
# test-finding-key.sh — Phase 3 acceptance: scripts/finding-key.sh computes a
# ledger-owned REGRESSION key from a finding JSON, distinct from the
# reconciler's (file, line, category) dedup signature.
#
# Plan: docs/dev_plans/20260823-feature-review-skills-resilience.md, Phase 3,
# R5. Identity: sha1(file|category|normalised summary), normalisation is
# lowercase + whitespace-collapse ONLY (no digit-stripping, so two findings
# differing only in a number stay distinct — bias to precision). `line` is
# deliberately NOT part of the key (a finding that shifts line number across
# rounds must still match).
#
# Interface assumption (finding-key.sh does not exist at the time this test
# was written — a parallel implementer is landing it in the same phase):
# `scripts/finding-key.sh <finding.json|->`, matching the sibling bundled
# scripts' convention (audit-auto-fix-eligibility.sh, run-gate.sh — a
# positional JSON-file argument or `-` for stdin), printing the computed key
# to stdout. If the real interface differs, this suite should read as RED
# with a clear "script missing/wrong interface" signal rather than a silent
# false pass.
#
# Exit codes: 0 all assertions pass, 1 any assertion fails.

set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
FINDING_KEY_SCRIPT="$ROOT_DIR/scripts/finding-key.sh"

pass_count=0
fail_count=0

pass() {
	echo "PASS: $1"
	pass_count=$((pass_count + 1))
}

fail() {
	echo "FAIL: $1"
	fail_count=$((fail_count + 1))
}

if [[ ! -x "$FINDING_KEY_SCRIPT" ]]; then
	fail "scripts/finding-key.sh missing or not executable: $FINDING_KEY_SCRIPT"
	echo ""
	echo "Results: $pass_count passed, $fail_count failed"
	exit 1
fi

WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

# finding FILE SUMMARY CATEGORY LINE -> writes a common-schema finding JSON
# to WORKDIR/FILE and echoes its path. FILE here is the fixture basename,
# not the "file" field value (which is fixed at "src/app.py" unless a
# different value is passed as $5).
finding() {
	local basename="$1" summary="$2" category="$3" line="$4" srcfile="${5:-src/app.py}"
	local out="$WORKDIR/$basename.json"
	jq -nc --arg file "$srcfile" --argjson line "$line" --arg category "$category" \
		--arg summary "$summary" \
		'{file: $file, line: $line, category: $category, severity: "medium",
		  confidence: 0.7, summary: $summary, evidence: "n/a"}' >"$out"
	printf '%s\n' "$out"
}

key_of() {
	"$FINDING_KEY_SCRIPT" "$1"
}

assert_eq() {
	local actual="$1" expected="$2" label="$3"
	if [[ "$actual" == "$expected" ]]; then
		pass "$label"
	else
		fail "$label (expected '$expected', got '$actual')"
	fi
}

assert_ne() {
	local a="$1" b="$2" label="$3"
	if [[ "$a" != "$b" ]]; then
		pass "$label"
	else
		fail "$label (expected distinct keys, both were '$a')"
	fi
}

# --- 1. Shifted-line match: identical file/category/summary, different line

f_line10="$(finding "shift-10" "SQL injection risk in query builder" "security" 10)"
f_line55="$(finding "shift-55" "SQL injection risk in query builder" "security" 55)"
k_line10="$(key_of "$f_line10")"
k_line55="$(key_of "$f_line55")"
assert_eq "$k_line55" "$k_line10" "shifted-line match: same finding at line 10 vs line 55 -> identical key"

# --- 2. Different-summary non-match --------------------------------------

f_other_summary="$(finding "other-summary" "Missing input validation on query builder" "security" 10)"
k_other_summary="$(key_of "$f_other_summary")"
assert_ne "$k_other_summary" "$k_line10" "different-summary non-match: distinct summary text -> distinct key"

# --- 3. Two same-file same-category findings differing only in a number --
# -> DISTINCT keys (no digit-stripping; bias to precision).

f_num3="$(finding "num-3" "off-by-one error in loop iteration 3" "correctness" 20)"
f_num4="$(finding "num-4" "off-by-one error in loop iteration 4" "correctness" 20)"
k_num3="$(key_of "$f_num3")"
k_num4="$(key_of "$f_num4")"
assert_ne "$k_num4" "$k_num3" "digit-in-summary: findings differing only in a number produce DISTINCT keys (no digit-stripping)"

# --- 4. Lowercase + whitespace-collapse normalisation --------------------

f_norm_a="$(finding "norm-a" "SQL Injection Risk In Query Builder" "security" 10)"
f_norm_b="$(finding "norm-b" "sql   injection  risk in query   builder" "security" 999)"
k_norm_a="$(key_of "$f_norm_a")"
k_norm_b="$(key_of "$f_norm_b")"
assert_eq "$k_norm_b" "$k_norm_a" "lowercase+whitespace-collapse: case differences and extra whitespace normalise to the same key"

# --- 5. Category is part of the identity: same file/summary, different category

f_cat_b="$(finding "cat-b" "SQL injection risk in query builder" "style" 10)"
k_cat_b="$(key_of "$f_cat_b")"
assert_ne "$k_cat_b" "$k_line10" "category is part of the key: same file+summary but different category -> distinct key"

# --- 6. File is part of the identity: same summary/category, different file

f_file_b="$(finding "file-b" "SQL injection risk in query builder" "security" 10 "src/other.py")"
k_file_b="$(key_of "$f_file_b")"
assert_ne "$k_file_b" "$k_line10" "file is part of the key: same summary+category but different file -> distinct key"

# --- 7. Determinism: same finding hashed twice -> same key ----------------

k_line10_again="$(key_of "$f_line10")"
assert_eq "$k_line10_again" "$k_line10" "determinism: identical finding JSON hashed twice -> identical key"

# --- 8. Output shape: looks like a sha1 hex digest (40 lowercase hex chars)

if [[ "$k_line10" =~ ^[0-9a-f]{40}$ ]]; then
	pass "output shape: key is a 40-character lowercase hex sha1 digest"
else
	fail "output shape: key is a 40-character lowercase hex sha1 digest (got '$k_line10')"
fi

# --- 9. F6(a): file path is case-SENSITIVE (verbatim), unlike category ----
# Foo.md and foo.md are two genuinely different files on a case-sensitive
# filesystem / in the git index and must NOT collide into one regression key.

f_file_upper="$(finding "file-case-upper" "SQL injection risk in query builder" "security" 10 "src/Foo.md")"
f_file_lower="$(finding "file-case-lower" "SQL injection risk in query builder" "security" 10 "src/foo.md")"
k_file_upper="$(key_of "$f_file_upper")"
k_file_lower="$(key_of "$f_file_lower")"
assert_ne "$k_file_upper" "$k_file_lower" "F6(a): file path is case-sensitive -- Foo.md and foo.md produce DISTINCT keys"

# --- 10. Category remains case-INSENSITIVE (unlike file) -----------------

f_cat_upper="$(finding "cat-case-upper" "SQL injection risk in query builder" "Security" 10)"
f_cat_lower="$(finding "cat-case-lower" "SQL injection risk in query builder" "security" 10)"
k_cat_upper="$(key_of "$f_cat_upper")"
k_cat_lower="$(key_of "$f_cat_lower")"
assert_eq "$k_cat_upper" "$k_cat_lower" "F6(a): category stays case-insensitive -- 'Security' and 'security' produce the SAME key"

# --- 11. F6(b): length-prefixed digest is injective -- a '|' or record-
# separator character inside a field cannot be made to collide with a
# differently-split neighbour by shifting a field boundary.

f_split_a="$(finding "split-a" "b|c" "cat" 1 "a")"
f_split_b="$(finding "split-b" "c" "cat" 1 "a|b")"
k_split_a="$(key_of "$f_split_a")"
k_split_b="$(key_of "$f_split_b")"
assert_ne "$k_split_a" "$k_split_b" "F6(b): length-prefixed encoding -- file=\"a\",summary=\"b|c\" vs file=\"a|b\",summary=\"c\" do NOT collide"

# --- 12. G6: a final line WITHOUT a trailing newline still yields a key ---
# The keys feed convergence-ledger.sh --present-keys/--claimed-keys; a
# dropped last line silently loses a regression or a claimed fix.

no_nl_stream="$(printf '{"file":"a.md","line":1,"category":"Logic","summary":"first"}\n{"file":"b.md","line":2,"category":"Logic","summary":"second"}')"
no_nl_keys="$(printf '%s' "$no_nl_stream" | bash "$FINDING_KEY_SCRIPT" -)"
no_nl_count="$(printf '%s\n' "$no_nl_keys" | grep -c .)"
assert_eq "$no_nl_count" "2" "G6: two JSON objects with NO trailing newline yield 2 keys (last line not dropped)"

with_nl_keys="$(printf '%s\n' "$no_nl_stream" | bash "$FINDING_KEY_SCRIPT" -)"
assert_eq "$no_nl_keys" "$with_nl_keys" "G6: newline-terminated and unterminated input produce identical keys"

# --- 13. A15: two JSON documents on ONE physical line yield NO key --------
# `jq -e 'type == "object"'` without --slurp reports only the LAST document's
# exit status, so a two-object line passed the shape gate and the three field
# reads each emitted TWO lines, which `$( )` joined with a newline into a
# single fabricated key matching neither finding. These keys feed
# convergence-ledger.sh --present-keys/--claimed-keys, so a fabricated key
# corrupts regression identity. Skipping loses a key (a missed regression);
# combining fabricates one (a false terminal stop) -- skip, and warn.

a15_two_on_one_line='{"file":"a.md","line":1,"category":"Logic","summary":"first"} {"file":"b.md","line":2,"category":"Logic","summary":"second"}'
a15_err="$(mktemp)"
set +e
a15_out="$(printf '%s\n' "$a15_two_on_one_line" | bash "$FINDING_KEY_SCRIPT" - 2>"$a15_err")"
a15_rc=$?
set -e
a15_count="$(printf '%s' "$a15_out" | grep -c . || true)"
assert_eq "$a15_count" "0" "A15: a two-document physical line yields no key (no fabricated key)"
assert_eq "$a15_rc" "0" "A15: a two-document physical line is skipped, not fatal (exit 0)"
if grep -q . "$a15_err"; then
	pass "A15: the skipped line is reported on stderr"
else
	fail "A15: the skipped line must be reported on stderr (stderr was empty)"
fi
rm -f "$a15_err"

# Control: the SAME two objects on two physical lines still yield two keys.
a15_split_keys="$(printf '%s\n%s\n' \
	'{"file":"a.md","line":1,"category":"Logic","summary":"first"}' \
	'{"file":"b.md","line":2,"category":"Logic","summary":"second"}' |
	bash "$FINDING_KEY_SCRIPT" -)"
a15_split_count="$(printf '%s\n' "$a15_split_keys" | grep -c .)"
assert_eq "$a15_split_count" "2" "A15(b): the same two objects on two lines still yield 2 keys"
a15_k1="$(printf '%s\n' "$a15_split_keys" | sed -n 1p)"
a15_k2="$(printf '%s\n' "$a15_split_keys" | sed -n 2p)"
assert_ne "$a15_k1" "$a15_k2" "A15(b): the two per-line keys are distinct"

echo ""
echo "Results: $pass_count passed, $fail_count failed"

if [[ "$fail_count" -gt 0 ]]; then
	exit 1
fi

exit 0
