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
# shellcheck disable=SC2329  # invoked indirectly via trap cleanup EXIT
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

# Repo root, for the G3 golden-corpus gate below (HEAD baseline + the
# in-repo .gauntlet/*/ reconciled artifacts it hashes).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

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

# --- 14. G3: a NON-STRING file/category/summary is SKIPPED, not coerced ---
# `//` substitutes only null/false, so a number in .file used to reach jq's
# string concat, abort the filter, and leave the NUL-delimited read loop with
# nothing -- every field resolved to empty and EVERY malformed finding
# collapsed onto ONE shared key (also the key of a genuinely empty finding).
# A shared key is precisely the false-`regression` failure this identity is
# biased against: a claimed fix on malformed finding A promotes the shared
# key, so malformed finding B next round fires the terminal stop.
#
# The fix is a TYPE GATE, not `tostring` coercion: coercing would fabricate
# an identity for output that is malformed at the source. So both lines are
# skipped with a warning naming the field and its type, neither emits a key,
# and neither can collide with the empty-object key because neither exists.
# The skip must be per-line (exit 0), because the documented consumer runs
# this under `pipefail`.

g3_err="$(mktemp)"
set +e
g3_nonstring_out="$(printf '%s\n%s\n' \
	'{"file":123,"category":"Logic","summary":"boom"}' \
	'{"file":456,"category":"Logic","summary":"boom"}' |
	bash "$FINDING_KEY_SCRIPT" - 2>"$g3_err")"
g3_nonstring_rc=$?
set -e

g3_nonstring_count="$(printf '%s' "$g3_nonstring_out" | grep -c . || true)"
assert_eq "$g3_nonstring_count" "0" "G3: non-string .file findings emit NO key (never a shared fabricated one)"
assert_eq "$g3_nonstring_rc" "0" "G3: a non-string field is skipped per-line, not fatal (exit 0)"

g3_warn_count="$(grep -c 'non-string field' "$g3_err" || true)"
assert_eq "$g3_warn_count" "2" "G3: each non-string line gets its own stderr warning"
if grep -q 'file is number' "$g3_err"; then
	pass "G3: the warning names the offending field and its type"
else
	fail "G3: the warning must name the field and its type (stderr: $(tr '\n' ' ' <"$g3_err"))"
fi

# A good line must survive a bad one -- the whole point of skipping per line.
g3_mixed="$(printf '%s\n%s\n' \
	'{"file":123,"category":"L","summary":"x"}' \
	'{"file":"a.md","category":"Logic","summary":"a"}' |
	bash "$FINDING_KEY_SCRIPT" - 2>/dev/null)"
g3_mixed_count="$(printf '%s' "$g3_mixed" | grep -c . || true)"
assert_eq "$g3_mixed_count" "1" "G3: a good line still yields its key when a malformed line precedes it"

# A non-string CATEGORY and a non-string SUMMARY are gated too, not just file.
for g3_field in category summary; do
	g3_field_err="$(mktemp)"
	set +e
	g3_field_out="$(printf '{"file":"a.md","%s":42}\n' "$g3_field" |
		bash "$FINDING_KEY_SCRIPT" - 2>"$g3_field_err")"
	set -e
	g3_field_count="$(printf '%s' "$g3_field_out" | grep -c . || true)"
	assert_eq "$g3_field_count" "0" "G3: a non-string .$g3_field emits no key either"
	if grep -q "$g3_field is number" "$g3_field_err"; then
		pass "G3: the .$g3_field warning names the field and its type"
	else
		fail "G3: the .$g3_field warning must name the field and its type"
	fi
	rm -f "$g3_field_err"
done

# An ABSENT or explicitly null field is NOT malformed -- it is the "" default.
g3_null_key="$(printf '%s\n' '{"file":null,"category":null,"summary":null}' |
	bash "$FINDING_KEY_SCRIPT" - 2>/dev/null)"
g3_empty_key="$(printf '%s\n' '{}' | bash "$FINDING_KEY_SCRIPT" - 2>/dev/null)"
assert_eq "$g3_null_key" "$g3_empty_key" "G3: explicit nulls are the documented \"\" default, not a non-string field"

if grep -qi 'jq: error' "$g3_err"; then
	fail "G3: a non-string field must not raise a jq error on stderr (stderr: $(tr '\n' ' ' <"$g3_err"))"
else
	pass "G3: a non-string field raises no jq error on stderr"
fi
rm -f "$g3_err"

# --- 15. Codex addendum: an embedded NUL must not TRUNCATE the key ---------
# A bash string cannot hold a NUL, so the NUL-delimited field reader stopped
# at the first one: summary "a<NUL>b" keyed identically to summary "a".
# Any in-band delimiter has this defect; the fix removes the bash round-trip
# entirely, so the digest is fed the whole field.

g3_nul_line="$(printf '{"file":"f.md","category":"Logic","summary":"a\\u0000b"}')"
g3_prefix_line='{"file":"f.md","category":"Logic","summary":"a"}'
g3_nul_key="$(printf '%s\n' "$g3_nul_line" | bash "$FINDING_KEY_SCRIPT" -)"
g3_prefix_key="$(printf '%s\n' "$g3_prefix_line" | bash "$FINDING_KEY_SCRIPT" -)"
assert_ne "$g3_nul_key" "$g3_prefix_key" "addendum: summary \"a<NUL>b\" and summary \"a\" produce DISTINCT keys (no NUL truncation)"

# --- 16. Codex addendum: extraction failure exits NON-ZERO, emits no key ---
# The old loop swallowed a failed extraction and printed the all-empty key.
# Fail closed instead: no key, and a non-zero exit the caller can see. Forced
# with a jq shim that fails ONLY the key-extraction invocation (identified by
# `utf8bytelength` in its filter) and delegates every other call to real jq,
# so the one-object shape gate still behaves normally.

g3_real_jq="$(command -v jq)"
g3_shim_dir="$WORKDIR/jq-shim"
mkdir -p "$g3_shim_dir"
cat >"$g3_shim_dir/jq" <<SHIM
#!/usr/bin/env bash
for a in "\$@"; do
	case "\$a" in
	*utf8bytelength*)
		echo "jq shim: simulated extraction failure" >&2
		exit 1
		;;
	esac
done
exec "$g3_real_jq" "\$@"
SHIM
chmod +x "$g3_shim_dir/jq"

g3_fail_err="$(mktemp)"
set +e
g3_fail_out="$(printf '%s\n%s\n' \
	'{"file":"a.md","category":"Logic","summary":"x"}' \
	'{"file":"b.md","category":"Logic","summary":"y"}' |
	PATH="$g3_shim_dir:$PATH" bash "$FINDING_KEY_SCRIPT" - 2>"$g3_fail_err")"
g3_fail_rc=$?
set -e
# Skip-and-warn, NOT a non-zero exit: the documented consumer is
# `finding-key.sh - > "$present_keys_file"` under `pipefail`, so aborting on
# one bad line would discard every good key in the round -- the same
# convergence-abort class this diff removes elsewhere.
assert_eq "$g3_fail_rc" "0" "G3: a failed key extraction is skipped per-line, not fatal (exit 0)"
g3_fail_count="$(printf '%s' "$g3_fail_out" | grep -c . || true)"
assert_eq "$g3_fail_count" "0" "G3: a failed key extraction emits NO key (never the all-empty key)"
g3_fail_warns="$(grep -c 'key extraction failed' "$g3_fail_err" || true)"
assert_eq "$g3_fail_warns" "2" "G3: each failed extraction is reported on stderr, one warning per line"
rm -f "$g3_fail_err"

# --- 17. Control: the shim is not itself the cause -- with real jq the same
# input still yields a key and exit 0.

g3_control="$(printf '%s\n' '{"file":"a.md","category":"Logic","summary":"x"}' |
	bash "$FINDING_KEY_SCRIPT" -)"
if [[ "$g3_control" =~ ^[0-9a-f]{40}$ ]]; then
	pass "addendum(control): the same input under real jq yields a key and exit 0"
else
	fail "addendum(control): the same input under real jq must yield a key (got '$g3_control')"
fi

# --- 18. G3: a literal US (0x1F) inside a summary must not shift a field ---
# The pre-image joins fields with 0x1F. The length prefixes are what make the
# encoding injective, but that claim was never tested against the separator
# byte itself -- so a summary containing one is the sharpest available probe.
# The byte is built with jq (`[31]|implode`), never typed into this source.

g3_us_line="$(jq -nc '{file:"f.md",category:"Logic",summary:("x"+([31]|implode)+"y")}')"
g3_us_key="$(printf '%s\n' "$g3_us_line" | bash "$FINDING_KEY_SCRIPT" - 2>/dev/null)"
g3_us_plain="$(printf '%s\n' '{"file":"f.md","category":"Logic","summary":"xy"}' |
	bash "$FINDING_KEY_SCRIPT" - 2>/dev/null)"
assert_ne "$g3_us_key" "$g3_us_plain" "G3: a literal 0x1F in a summary keys differently from the same summary without it"
if [[ "$g3_us_key" =~ ^[0-9a-f]{40}$ ]]; then
	pass "G3: a 0x1F-bearing summary still yields a well-formed sha1 key"
else
	fail "G3: a 0x1F-bearing summary must still yield a key (got '$g3_us_key')"
fi

# --- 19. G3 acceptance gate: golden corpus, old key == new key ------------
# `fixed_keys` in existing .gauntlet/*/ledger.json were computed by the OLD
# code. If this port changes the key for any WELL-FORMED finding, every
# stored key silently stops matching: regressions are missed (safe) and
# `pending_claimed` never clears (not safe -- it accumulates). So byte
# identity against the HEAD implementation is a hard gate, not a nicety.
# Corpus: 122 real gate findings already in-repo.

g3_baseline="$WORKDIR/finding-key-head.sh"
if git -C "$REPO_ROOT" show "HEAD:scripts/finding-key.sh" >"$g3_baseline" 2>/dev/null; then
	g3_corpus="$WORKDIR/corpus.jsonl"
	: >"$g3_corpus"
	g3_corpus_files=0
	for g3_src in .gauntlet/r1/reconciled.json .gauntlet/r2/reconciled.json .gauntlet/r3/prior-findings.json; do
		if [[ -f "$REPO_ROOT/$g3_src" ]]; then
			g3_corpus_files=$((g3_corpus_files + 1))
			jq -c '[.. | objects
				| select(has("file") and has("category") and has("summary"))
				| select((.file | type) == "string" and (.category | type) == "string" and (.summary | type) == "string")][]' \
				"$REPO_ROOT/$g3_src" >>"$g3_corpus"
		fi
	done
	g3_corpus_n="$(grep -c . "$g3_corpus" || true)"
	if [[ "$g3_corpus_files" -eq 0 || "$g3_corpus_n" -eq 0 ]]; then
		echo "SKIP: G3 golden corpus (no .gauntlet/*/ reconciled artifacts in this checkout)"
	else
		g3_old_keys="$(bash "$g3_baseline" "$g3_corpus" 2>/dev/null || true)"
		g3_new_keys="$(bash "$FINDING_KEY_SCRIPT" "$g3_corpus" 2>/dev/null || true)"
		g3_old_n="$(printf '%s' "$g3_old_keys" | grep -c . || true)"
		g3_new_n="$(printf '%s' "$g3_new_keys" | grep -c . || true)"
		assert_eq "$g3_new_n" "$g3_corpus_n" "G3(corpus): every well-formed corpus finding yields a key ($g3_corpus_n findings)"
		assert_eq "$g3_new_n" "$g3_old_n" "G3(corpus): the port yields exactly as many keys as HEAD"
		if [[ "$g3_old_keys" == "$g3_new_keys" ]]; then
			pass "G3(corpus): old key == new key, byte-identical, for all $g3_corpus_n well-formed findings"
		else
			fail "G3(corpus): key churn detected -- stored ledger fixed_keys would stop matching ($(diff <(printf '%s\n' "$g3_old_keys") <(printf '%s\n' "$g3_new_keys") | grep -c '^[<>]' || true) differing lines)"
		fi
	fi
else
	echo "SKIP: G3 golden corpus (HEAD:scripts/finding-key.sh unavailable)"
fi

# ---------------------------------------------------------------------------
# G4 (r4 F15) — an ALL-EMPTY finding key never reaches the ledger.
#
# FK_TYPE_GATE rejects a present-but-non-string identity field, but an ABSENT
# or null one falls through `// ""`. So `{}` and `{"severity":"Minor"}` -- two
# findings with nothing in common -- hashed to the SAME key: exactly the
# shared-key false-`regression` the identity is biased against, and the case
# the header's "a truncated or all-empty key can never reach the ledger"
# claimed was already closed.
#
# The filter now emits nothing when file, category and summary are all empty
# after normalisation, and the script takes its existing malformed-line path:
# warn on stderr, emit no key. A PARTIALLY empty finding still hashes and
# stays injective via the length prefixes, so well-formed input is untouched.
# ---------------------------------------------------------------------------

g4_in="$WORKDIR/g4-allempty.jsonl"
{
	printf '%s\n' '{}'
	printf '%s\n' '{"severity":"Minor"}'
	printf '%s\n' '{"file":"","category":"","summary":"   "}'
} >"$g4_in"

set +e
g4_out="$(bash "$FINDING_KEY_SCRIPT" "$g4_in" 2>"$WORKDIR/g4.err")"
g4_rc=$?
set -e
g4_keys="$(printf '%s' "$g4_out" | grep -c . || true)"
g4_warns="$(grep -c . "$WORKDIR/g4.err" || true)"

if [[ "$g4_rc" -eq 0 && "$g4_keys" -eq 0 && "$g4_warns" -ge 3 ]]; then
	pass "G4: three all-empty findings emit NO key and warn on stderr (rc=0)"
else
	fail "G4: rc=$g4_rc keys=$g4_keys warns=$g4_warns out='$g4_out'"
fi

# Control 1: a well-formed finding's key is unchanged by the guard.
g4_wf="$WORKDIR/g4-wellformed.jsonl"
printf '%s\n' '{"file":"a.sh","category":"logic","summary":"boom"}' >"$g4_wf"
g4_wf_key="$(bash "$FINDING_KEY_SCRIPT" "$g4_wf")"
if [[ -n "$g4_wf_key" && "$g4_wf_key" =~ ^[0-9a-f]{40}$ ]]; then
	pass "G4(control): a well-formed finding still hashes to a key"
else
	fail "G4(control): well-formed key='$g4_wf_key'"
fi

# Control 2: PARTIALLY empty findings stay DISTINCT -- the length prefixes,
# not a presence check, are what make the identity injective.
g4_part="$WORKDIR/g4-partial.jsonl"
{
	printf '%s\n' '{"file":"a.sh"}'
	printf '%s\n' '{"category":"a.sh"}'
	printf '%s\n' '{"summary":"a.sh"}'
} >"$g4_part"
g4_part_keys="$(bash "$FINDING_KEY_SCRIPT" "$g4_part" 2>/dev/null)"
g4_part_n="$(printf '%s\n' "$g4_part_keys" | grep -c . || true)"
g4_part_u="$(printf '%s\n' "$g4_part_keys" | sort -u | grep -c . || true)"
if [[ "$g4_part_n" -eq 3 && "$g4_part_u" -eq 3 ]]; then
	pass "G4(control): three partially-empty findings still hash to three DISTINCT keys"
else
	fail "G4(control): partial keys n=$g4_part_n unique=$g4_part_u"
fi

echo ""
echo "Results: $pass_count passed, $fail_count failed"

if [[ "$fail_count" -gt 0 ]]; then
	exit 1
fi

exit 0
