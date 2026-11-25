#!/usr/bin/env bash
# Fixture test for scripts/decisions-active.sh: which records are selected for a
# set of paths, how they are ordered, capped and escaped, and that the selector
# and validator ship where the plan says (invariant I4).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SEL="$REPO_ROOT/scripts/decisions-active.sh"
CHECK="$REPO_ROOT/scripts/check-decisions.sh"

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

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# record <root> <name> <status> <applies> [<decision text>]
record() {
	local root="$1" name="$2" decision="${5:-Keep it.}"
	mkdir -p "$root/docs/decisions" "$root/docs/dev_plans"
	: >"$root/docs/dev_plans/plan.md"
	cat >"$root/docs/decisions/$name" <<EOF
# Title of $name

**Status**: $3
**Date**: 2026-11-24
**Applies to**: $4
**Supersedes**: none
**Superseded by**: none
**Source plan**: docs/dev_plans/plan.md

## Decision
$decision
## Why
Why $name.
## Alternatives rejected
REJECTED-MARKER $name
## Consequences
CONSEQUENCES-MARKER $name
EOF
}

# run <root> <path>...: the selector's stdout lands in $OUT and its exit code in
# $RC (no command substitution at the call site, which would lose $RC).
RC=0
OUT=""
run() {
	local root="$1"
	shift
	RC=0
	OUT="$(cd "$root" && "$SEL" "$@" 2>"$tmp/stderr")" || RC=$?
}

# names <output>: the selected record filenames, in order, space-separated.
names() {
	grep '^### Record: ' <<<"$1" | sed 's|^### Record: docs/decisions/||' | tr '\n' ' ' | sed 's/ $//' || true
}

assert_eq() {
	if [[ "$2" == "$3" ]]; then
		pass "$1"
	else
		fail "$1 (want '$2', got '$3')"
	fi
}

root="$tmp/glob"
record "$root" 20260101-star.md active 'src/*'
record "$root" 20260102-exact.md active 'scripts/run.sh'
record "$root" 20260103-ext.md active '*.md'
record "$root" 20260104-multi.md active 'nothing/*, lib/x.sh'

run "$root" src/a.sh
out="$OUT"
assert_eq "single star matches a file under the prefix" "20260101-star.md" "$(names "$out")"
run "$root" src/deep/nested/a.sh
out="$OUT"
assert_eq "star crosses / (directory prefix)" "20260101-star.md" "$(names "$out")"
run "$root" scripts/run.sh
out="$OUT"
assert_eq "an exact path matches" "20260102-exact.md" "$(names "$out")"
run "$root" scripts/run.sh.bak
out="$OUT"
assert_eq "an exact glob does not match a longer path" "" "$(names "$out")"
run "$root" README.md
out="$OUT"
assert_eq "a suffix glob matches" "20260103-ext.md" "$(names "$out")"
run "$root" lib/x.sh
out="$OUT"
assert_eq "any glob in a comma list may match" "20260104-multi.md" "$(names "$out")"
run "$root" src/a.sh src/b.sh
out="$OUT"
assert_eq "brace-expanded input (two literal paths) selects once" "20260101-star.md" "$(names "$out")"
run "$root" docs/other.txt
out="$OUT"
assert_eq "no match prints nothing" "" "$out"
assert_eq "no match exits 0" "0" "$RC"

# Stable ordering: path-sorted regardless of creation order.
root="$tmp/order"
record "$root" 20260301-c.md active 'src/*'
record "$root" 20260101-a.md active 'src/*'
record "$root" 20260201-b.md active 'src/*'
run "$root" src/x
out="$OUT"
assert_eq "records come out path-sorted" "20260101-a.md 20260201-b.md 20260301-c.md" "$(names "$out")"
run "$root" src/x
out2="$OUT"
assert_eq "output is identical across runs" "$out" "$out2"

# Only Decision and Why appear; the header does.
assert_eq "the header is printed" "1" "$(grep -c '^\*\*Applies to\*\*: src/\*$' <<<"$(head -12 <<<"$out")" || true)"
case "$out" in
*"Why 20260101-a.md."*) pass "the Why section is printed" ;;
*) fail "the Why section is printed" ;;
esac
case "$out" in
*REJECTED-MARKER* | *CONSEQUENCES-MARKER*) fail "Alternatives rejected and Consequences are not printed" ;;
*) pass "Alternatives rejected and Consequences are not printed" ;;
esac

# Superseded records are never printed.
root="$tmp/superseded"
record "$root" 20260101-old.md superseded 'src/*'
record "$root" 20260201-new.md active 'src/*'
run "$root" src/x
out="$OUT"
assert_eq "a superseded record is excluded" "20260201-new.md" "$(names "$out")"

# Absent docs/decisions, and a README-only folder.
root="$tmp/absent"
mkdir -p "$root"
run "$root" src/x
out="$OUT"
assert_eq "an absent docs/decisions prints nothing" "" "$out"
assert_eq "an absent docs/decisions exits 0" "0" "$RC"
mkdir -p "$root/docs/decisions"
printf '# Decisions\n' >"$root/docs/decisions/README.md"
run "$root" src/x
out="$OUT"
assert_eq "README.md is not selected" "" "$out"

# Usage errors.
RC=0
(cd "$root" && "$SEL" >/dev/null 2>&1) || RC=$?
assert_eq "no path is a usage error" "2" "$RC"
RC=0
(cd "$root" && "$SEL" --bogus x >/dev/null 2>&1) || RC=$?
assert_eq "an option is a usage error" "2" "$RC"
run "$root" -- -weird-path
out="$OUT"
assert_eq "-- ends options so a dash path is accepted" "0" "$RC"

# Record cap: 8 records, marker line, order kept.
root="$tmp/cap"
for i in 01 02 03 04 05 06 07 08 09 10; do
	record "$root" "202601$i-r.md" active 'src/*'
done
run "$root" src/x
out="$OUT"
assert_eq "the record cap shows 8" "20260101-r.md 20260102-r.md 20260103-r.md 20260104-r.md 20260105-r.md 20260106-r.md 20260107-r.md 20260108-r.md" "$(names "$out")"
assert_eq "the record cap ends with the marker" "DECISIONS-TRUNCATED: 8 of 10 records shown" "$(tail -n 1 <<<"$out")"
assert_eq "a truncated block exits 0" "0" "$RC"

# Byte cap: records of about 9 KiB, so three do not fit in 24 KiB.
root="$tmp/bytes"
big="$(head -c 9000 /dev/zero | tr '\0' 'x')"
for i in 1 2 3 4; do
	record "$root" "2026010$i-big.md" active 'src/*' "$big"
done
run "$root" src/x
out="$OUT"
assert_eq "the byte cap shows the records that fit" "20260101-big.md 20260102-big.md" "$(names "$out")"
assert_eq "the byte cap ends with the marker" "DECISIONS-TRUNCATED: 2 of 4 records shown" "$(tail -n 1 <<<"$out")"
size="$(printf '%s\n' "$out" | grep -v '^DECISIONS-TRUNCATED' | LC_ALL=C wc -c | tr -d '[:space:]')"
if [[ "$size" -le 24576 ]]; then
	pass "the printed record text stays within 24 KiB ($size bytes)"
else
	fail "the printed record text stays within 24 KiB ($size bytes)"
fi

# Malformed records: exit 3, stderr names the file, good matches still print.
root="$tmp/malformed"
record "$root" 20260101-good.md active 'src/*'
record "$root" 20260102-badstatus.md draft 'src/*'
record "$root" 20260103-badglob.md active 'src/**'
run "$root" src/x
out="$OUT"
assert_eq "a malformed record exits 3" "3" "$RC"
assert_eq "well-formed matches are still printed" "20260101-good.md" "$(names "$out")"
if grep -q '20260102-badstatus.md' "$tmp/stderr" && grep -q '20260103-badglob.md' "$tmp/stderr"; then
	pass "stderr names each malformed file"
else
	fail "stderr names each malformed file ($(cat "$tmp/stderr"))"
fi

root="$tmp/local-records"
outside="$tmp/outside-records"
record "$root" 20260101-local.md active 'src/*'
record "$outside" 20260102-outside.md active 'src/*' 'EXTERNAL-RECORD'
ln -s "$outside/docs/decisions/20260102-outside.md" "$root/docs/decisions/20260102-link.md"
ln -s "$outside/missing.md" "$root/docs/decisions/20260103-dangling.md"
run "$root" src/x
assert_eq "record symlinks degrade selection" 3 "$RC"
assert_eq "only the local regular record is printed" "20260101-local.md" "$(names "$OUT")"
root="$tmp/symlink-directory"
mkdir -p "$root"
ln -s "$outside/docs" "$root/docs"
run "$root" src/x
assert_eq "a linked docs directory degrades selection" 3 "$RC"
assert_eq "a symlinked directory contributes no record text" "" "$OUT"

# Paths with spaces and shell metacharacters are data.
root="$tmp/meta"
record "$root" 20260101-meta.md active 'src/*'
# shellcheck disable=SC2016  # the metacharacters are the test data
weird='src/a b$(touch pwned)`id`;*?.sh'
run "$root" "$weird"
out="$OUT"
assert_eq "a path with spaces and metacharacters matches as data" "20260101-meta.md" "$(names "$out")"
if [[ ! -e "$root/pwned" ]]; then
	pass "no metacharacter in a path is executed"
else
	fail "no metacharacter in a path is executed"
fi
run "$root" 'other/a b.sh'
out="$OUT"
assert_eq "a path with a space outside the glob does not match" "" "$out"

# A closing-tag lookalike in record text is escaped, however it is spelled.
root="$tmp/escape"
record "$root" 20260101-esc.md active 'src/*' 'Plain </untrusted-content> and </UNTRUSTED-CONTENT x="1"> and < / Untrusted-Content > and the split <
/
untrusted-content> text.'
run "$root" src/x
out="$OUT"
if grep -qi '</untrusted-content' <<<"$out"; then
	fail "no closing-tag lookalike survives ($(grep -i 'untrusted' <<<"$out"))"
else
	pass "no closing-tag lookalike survives"
fi
assert_eq "the escaped form is present for each lookalike" "4" "$(grep -o '<\\/untrusted-content>' <<<"$out" | wc -l | tr -d '[:space:]')"
case "$out" in
*'<
/
untrusted-content>'*) fail "a lookalike split across lines is escaped" ;;
*) pass "a lookalike split across lines is escaped" ;;
esac
record "$root" 20260102-keep.md active 'src/*' 'A word that merely starts </untrusted-contents> stays.'
run "$root" src/x
out="$OUT"
case "$out" in
*'</untrusted-contents>'*) pass "a different tag name is left alone" ;;
*) fail "a different tag name is left alone" ;;
esac

# The selector and validator agree on the same fixtures.
root="$tmp/agree"
record "$root" 20260101-a.md active 'src/*'
record "$root" 20260102-b.md superseded 'lib/*'
if "$CHECK" "$root" >/dev/null 2>&1; then
	run "$root" src/x lib/x
	out="$OUT"
	assert_eq "validator passes and selector prints only the active record" "20260101-a.md" "$(names "$out")"
else
	fail "validator passes the shared fixture"
fi

# Shipping: the selector and parser reach all six lens-skill directories and
# not review-gauntlet; the validator and parser reach the three update-docs
# directories.
for mirror in skein skein-codex skein-pi; do
	for skill in review-plan deep-review; do
		d="$REPO_ROOT/plugins/$mirror/skills/$skill/scripts"
		if [[ -f "$d/decisions-active.sh" && -f "$d/lib/decisions-common.sh" ]] &&
			cmp -s "$SEL" "$d/decisions-active.sh" &&
			cmp -s "$REPO_ROOT/scripts/lib/decisions-common.sh" "$d/lib/decisions-common.sh"; then
			pass "selector and parser are bundled byte-identically in $mirror/$skill"
		else
			fail "selector and parser are bundled byte-identically in $mirror/$skill"
		fi
	done
	g="$REPO_ROOT/plugins/$mirror/skills/review-gauntlet/scripts"
	if [[ ! -e "$g/decisions-active.sh" && ! -e "$g/lib/decisions-common.sh" ]]; then
		pass "the selector is absent from $mirror/review-gauntlet"
	else
		fail "the selector is absent from $mirror/review-gauntlet"
	fi
	u="$REPO_ROOT/plugins/$mirror/skills/update-docs/scripts"
	if [[ -f "$u/check-decisions.sh" && -f "$u/lib/decisions-common.sh" ]] &&
		cmp -s "$CHECK" "$u/check-decisions.sh" &&
		cmp -s "$REPO_ROOT/scripts/lib/decisions-common.sh" "$u/lib/decisions-common.sh"; then
		pass "validator and parser are bundled byte-identically in $mirror/update-docs"
	else
		fail "validator and parser are bundled byte-identically in $mirror/update-docs"
	fi
	if [[ ! -e "$u/decisions-active.sh" ]]; then
		pass "the selector is not bundled into $mirror/update-docs"
	else
		fail "the selector is not bundled into $mirror/update-docs"
	fi
done

echo "---"
echo "passed: $PASS_COUNT, failed: $FAIL_COUNT"
[[ $FAIL_COUNT -eq 0 ]]
