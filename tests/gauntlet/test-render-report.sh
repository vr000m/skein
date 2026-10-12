#!/usr/bin/env bash
# test-render-report.sh — Phase 2 acceptance for the opt-in HTML report:
# scripts/render-report.py (renderer) and scripts/report-hook.sh (guarded entry
# point behind the `--report` flag of review-gauntlet and deep-review).
#
# Plan: docs/dev_plans/20261008-feature-review-output-formats.md, Phase 2.
#
# Invariants under test:
#   - the renderer only reads the files it is handed and writes ONE contained
#     HTML file; it never mutates its inputs and leaves no `<out>.tmp.<pid>`;
#   - all finding text is escaped (text AND attribute contexts); the page has
#     no script and no external reference;
#   - the hook ALWAYS exits 0, whatever fails, and writes nothing under
#     .gauntlet/ or .deep-review/ except the report.
#
# Every vector drives the real CLIs. Fixtures: tests/gauntlet/fixtures/render-report/.
# Exit codes: 0 all assertions pass, 1 any assertion fails.

set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
RENDERER="$ROOT_DIR/scripts/render-report.py"
HOOK="$ROOT_DIR/scripts/report-hook.sh"
FIX="$ROOT_DIR/tests/gauntlet/fixtures/render-report"

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

assert_eq() {
	if [[ "$1" == "$2" ]]; then
		pass "$3"
	else
		fail "$3 (expected '$2', got '$1')"
	fi
}

# assert_has FILE NEEDLE LABEL — fixed-string match.
assert_has() {
	if grep -qF -- "$2" "$1"; then
		pass "$3"
	else
		fail "$3 (missing '$2')"
	fi
}

assert_lacks() {
	if grep -qF -- "$2" "$1"; then
		fail "$3 (unexpected '$2')"
	else
		pass "$3"
	fi
}

# assert_lacks_re FILE ERE LABEL
assert_lacks_re() {
	if grep -qE -- "$2" "$1"; then
		fail "$3 (matched /$2/)"
	else
		pass "$3"
	fi
}

TMP_DIRS=()
# shellcheck disable=SC2317,SC2329  # invoked indirectly via trap cleanup EXIT
cleanup() {
	local d
	for d in "${TMP_DIRS[@]:-}"; do
		[[ -n "$d" && -d "$d" ]] && rm -rf "$d"
	done
	return 0
}
trap cleanup EXIT

# new_dir — a fresh physical (symlink-resolved) temp dir, registered for cleanup.
new_dir() {
	local d
	d="$(mktemp -d)"
	d="$(cd "$d" && pwd -P)"
	TMP_DIRS+=("$d")
	printf '%s\n' "$d"
}

if ! command -v python3 >/dev/null 2>&1; then
	echo "SKIP: python3 not available"
	exit 0
fi

SANDBOX="$(new_dir)"
ERR="$SANDBOX/stderr.txt"

# run_r ARGS... — run the renderer, record rc in $RC and stderr in $ERR.
RC=0
run_r() {
	RC=0
	python3 "$RENDERER" "$@" >"$SANDBOX/stdout.txt" 2>"$ERR" || RC=$?
}

# fresh_root — a root with a .gauntlet dir; prints the path.
fresh_root() {
	local r
	r="$(new_dir)"
	mkdir -p "$r/.gauntlet"
	printf '%s\n' "$r"
}

# no_residue ROOT_DIR — true when no *.tmp.* file exists below it.
no_residue() {
	[[ -z "$(find "$1" -name '*.tmp.*' 2>/dev/null | head -1)" ]]
}

hash_file() {
	shasum -a 256 "$1" | cut -d' ' -f1
}

hash_tree() {
	(cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 2>/dev/null)
}

# ---------------------------------------------------------------- renderer

echo "== renderer: severity buckets =="
R="$(fresh_root)"
OUT="$R/.gauntlet/r.html"
run_r --envelope "$FIX/envelope-severities.json" --root "$R" --out "$OUT"
assert_eq "$RC" "0" "envelope render exits 0"
assert_has "$OUT" '<!DOCTYPE html>' "page is a complete HTML document"
assert_has "$OUT" 'id="sev-critical"' "Critical section present"
assert_has "$OUT" 'id="sev-important"' "Important section present"
assert_has "$OUT" 'id="sev-minor"' "Minor section present"
assert_has "$OUT" 'id="sev-other"' "Other section present (unknown and missing severity)"
assert_has "$OUT" 'other-bogus' "unknown severity lands in Other"
assert_has "$OUT" 'other-missing-severity' "absent severity lands in Other"
assert_has "$OUT" 'crit-one' "Critical finding rendered"
assert_has "$OUT" 'ev-crit' "evidence rendered"
assert_has "$OUT" 'fix-crit' "suggestion rendered"
assert_has "$OUT" 'a.py:10' "location rendered as file:line"
assert_has "$OUT" 'Reconciliation:' "reconciliation summary rendered"
assert_has "$OUT" 'as reviewed; suppressed and auto-fixed findings omitted' "envelope mode carries the suppression label"

run_r --envelope "$FIX/envelope-round1.json" --root "$R" --out "$OUT"
assert_lacks "$OUT" 'id="sev-other"' "Other section absent when no finding needs it"

echo "== renderer: severity aliases (case-insensitive) =="
ALIAS_ENV="$SANDBOX/envelope-aliases.json"
cat >"$ALIAS_ENV" <<'JSON'
{"schema_version":2,"findings":[
{"severity":"high","category":"c","file":"h.py","line":1,"summary":"ALIAS-HIGH"},
{"severity":"CRITICAL","category":"c","file":"h.py","line":2,"summary":"ALIAS-CRIT-UPPER"},
{"severity":"Medium","category":"c","file":"h.py","line":3,"summary":"ALIAS-MEDIUM"},
{"severity":"important","category":"c","file":"h.py","line":4,"summary":"ALIAS-IMPORTANT-LOWER"},
{"severity":"LOW","category":"c","file":"h.py","line":5,"summary":"ALIAS-LOW"},
{"severity":"minor","category":"c","file":"h.py","line":6,"summary":"ALIAS-MINOR-LOWER"},
{"severity":"severe","category":"c","file":"h.py","line":7,"summary":"ALIAS-UNKNOWN"}
]}
JSON
run_r --envelope "$ALIAS_ENV" --root "$R" --out "$OUT"
assert_eq "$RC" "0" "alias envelope renders"
# section_of SUMMARY — the severity section id that contains SUMMARY.
section_of() {
	python3 - "$OUT" "$1" <<'PY'
import re, sys
page = open(sys.argv[1], encoding="utf-8").read()
for sec in re.findall(r'<section class="sev-[A-Za-z]+" id="(sev-[a-z]+)">(.*?)</section>', page, re.S):
    if sys.argv[2] in sec[1]:
        print(sec[0])
PY
}
assert_eq "$(section_of ALIAS-HIGH)" "sev-critical" "high maps to Critical"
assert_eq "$(section_of ALIAS-CRIT-UPPER)" "sev-critical" "CRITICAL (any case) maps to Critical"
assert_eq "$(section_of ALIAS-MEDIUM)" "sev-important" "Medium maps to Important"
assert_eq "$(section_of ALIAS-IMPORTANT-LOWER)" "sev-important" "important (lowercase) maps to Important"
assert_eq "$(section_of ALIAS-LOW)" "sev-minor" "LOW maps to Minor"
assert_eq "$(section_of ALIAS-MINOR-LOWER)" "sev-minor" "minor (lowercase) maps to Minor"
assert_eq "$(section_of ALIAS-UNKNOWN)" "sev-other" "an unknown severity stays Other"

echo "== renderer: empty findings =="
run_r --envelope "$FIX/envelope-empty.json" --root "$R" --out "$OUT"
assert_eq "$RC" "0" "findings: [] exits 0"
assert_has "$OUT" 'None.' "empty severity bucket renders None."

echo "== renderer: related finding cross-references =="
RELATED_ENV="$SANDBOX/envelope-related.json"
cat >"$RELATED_ENV" <<'JSON'
{"schema_version":2,"summary":{"raw":2,"merged":0,"unique":2,"related":1,"dropped":0},"findings":[],"related":[{"file":"src/shared.py","line":42,"categories":["security","correctness"]}]}
JSON
run_r --envelope "$RELATED_ENV" --root "$R" --out "$OUT"
assert_eq "$RC" "0" "related envelope renders"
assert_has "$OUT" 'Related findings' "related cross-reference section rendered"
assert_has "$OUT" 'src/shared.py:42' "related location rendered"
assert_has "$OUT" 'security, correctness' "related categories rendered"

echo "== renderer: escaping and injection =="
run_r --envelope "$FIX/envelope-inject.json" --root "$R" --out "$OUT"
assert_eq "$RC" "0" "injection fixture renders"
assert_lacks "$OUT" '<script' "no script element from finding text"
assert_lacks "$OUT" '<img' "no img element from finding text (attribute-context payload)"
assert_lacks "$OUT" '<b>bold</b>' "lens text escaped"
assert_has "$OUT" '&lt;script&gt;alert(&#x27;xss&#x27;)&lt;/script&gt;' "summary payload escaped in a text node"
assert_has "$OUT" '&quot;&gt;&lt;img src=x onerror=alert(1)&gt;.py' "file payload escaped incl. double quote"
assert_has "$OUT" 'onmouseover=&quot;alert(1)' "category quote escaped (cannot break out of an attribute)"
assert_lacks_re "$OUT" '<[a-zA-Z][^>]*[[:space:]]on[a-z]+=' "no tag carries an on* handler attribute"
assert_lacks_re "$OUT" '<[a-zA-Z][^>]*[[:space:]](href|src)=' "no tag carries an href/src attribute"

echo "== renderer: no script / external URL in a normal page =="
run_r --ledger "$FIX/ledger.json" --round "1=$FIX/envelope-round1.json" --round "2=$FIX/envelope-round2.json" \
	--root "$R" --out "$OUT"
assert_eq "$RC" "0" "gauntlet render exits 0"
assert_lacks "$OUT" '<script' "no script element"
assert_lacks "$OUT" 'http://' "no http:// reference"
assert_lacks "$OUT" 'https://' "no https:// reference"
assert_lacks "$OUT" '<link' "no link element"
assert_lacks "$OUT" '@import' "no CSS @import"
assert_lacks "$OUT" 'url(' "no CSS url()"
assert_has "$OUT" '<style>' "CSS is inline"

echo "== renderer: schema_version applies to envelopes only =="
for f in envelope-v1 envelope-no-version; do
	rm -f "$OUT"
	run_r --envelope "$FIX/$f.json" --root "$R" --out "$OUT"
	assert_eq "$RC" "1" "$f: schema_version mismatch exits 1"
	if [[ ! -e "$OUT" ]]; then pass "$f: no output written"; else fail "$f: output written"; fi
done
rm -f "$OUT"
run_r --ledger "$FIX/ledger.json" --root "$R" --out "$OUT"
assert_eq "$RC" "0" "ledger with schema_version 99 is never version-checked"
rm -f "$OUT"
run_r --ledger "$FIX/ledger.json" --round "1=$FIX/envelope-v1.json" --root "$R" --out "$OUT"
assert_eq "$RC" "1" "a v1 round envelope behind --round still fails"
assert_has "$ERR" 'schema_version' "failure message names schema_version"

echo "== renderer: envelope failures =="
for f in envelope-no-findings envelope-findings-notlist malformed empty-file; do
	rm -f "$OUT"
	run_r --envelope "$FIX/$f.json" --root "$R" --out "$OUT"
	assert_eq "$RC" "1" "$f: exits 1"
	if [[ ! -e "$OUT" ]]; then pass "$f: no output written"; else fail "$f: output written"; fi
done
run_r --envelope "$SANDBOX/does-not-exist.json" --root "$R" --out "$OUT"
assert_eq "$RC" "1" "missing envelope file exits 1"
run_r --ledger "$FIX/malformed.json" --root "$R" --out "$OUT"
assert_eq "$RC" "1" "malformed ledger exits 1"
run_r --ledger "$FIX/ledger-no-rounds.json" --root "$R" --out "$OUT"
assert_eq "$RC" "1" "ledger without a rounds array exits 1"
run_r --ledger "$SANDBOX/does-not-exist.json" --root "$R" --out "$OUT"
assert_eq "$RC" "1" "missing ledger file exits 1"
assert_eq "$(no_residue "$R" && echo clean)" "clean" "no temp residue after failures"

echo "== renderer: counts-only mode =="
rm -f "$OUT"
run_r --ledger "$FIX/ledger.json" --root "$R" --out "$OUT"
assert_eq "$RC" "0" "ledger alone renders"
assert_has "$OUT" 'Counts only' "counts-only notice present"
assert_has "$OUT" 'counts only' "rows are marked counts only"
assert_lacks "$OUT" 'id="sev-' "no severity sections without envelopes"
assert_lacks "$OUT" 'as reviewed; suppressed' "gauntlet mode never carries the suppression label"

echo "== renderer: rounds, missing envelope, highest-round severity =="
rm -f "$OUT"
# flag order is irrelevant; round 3 has no file
run_r --ledger "$FIX/ledger.json" --round "2=$FIX/envelope-round2.json" \
	--round "3=$SANDBOX/missing-r3.json" --round "1=$FIX/envelope-round1.json" --root "$R" --out "$OUT"
assert_eq "$RC" "0" "missing round envelope is not an error"
assert_has "$OUT" 'round 3: envelope missing' "missing round is marked"
assert_has "$OUT" 'round 3: envelope missing — findings unavailable' "highest round missing: findings section says unavailable"
assert_lacks "$OUT" 'ROUND-TWO-ONLY' "highest round missing: an older round's findings are not shown as current"
assert_lacks "$OUT" 'ROUND-ONE-ONLY' "highest round missing: round 1 findings are not shown either"
assert_lacks "$OUT" 'id="sev-' "highest round missing: no severity sections"
assert_has "$OUT" '<table>' "highest round missing: the convergence table is kept"
assert_has "$OUT" 'branch:fixture' "ledger target shown"

rm -f "$OUT"
run_r --ledger "$FIX/ledger.json" --round "2=$FIX/envelope-round2.json" --round "1=$FIX/envelope-round1.json" \
	--root "$R" --out "$OUT"
assert_has "$OUT" 'ROUND-TWO-ONLY' "severity section shows the highest round when its envelope is present"
assert_lacks "$OUT" 'ROUND-ONE-ONLY' "earlier round findings are not rendered"
assert_has "$OUT" 'Round 2 (latest round)' "the rendered round is named"

# The ledger records 2 rounds but only round 1 is supplied: round 2 is the
# highest ledger round, so its findings are unavailable (no fallback to 1).
rm -f "$OUT"
run_r --ledger "$FIX/ledger.json" --round "1=$FIX/envelope-round1.json" --root "$R" --out "$OUT"
assert_has "$OUT" 'round 2: envelope missing — findings unavailable' "highest LEDGER round without an envelope is unavailable"
assert_lacks "$OUT" 'ROUND-ONE-ONLY' "no fallback to round 1 when the ledger's highest round has no envelope"

echo "== renderer: usage errors (exit 2) =="
usage_case() {
	local label="$1"
	shift
	run_r "$@"
	assert_eq "$RC" "2" "$label: exit 2"
	assert_has "$ERR" 'usage' "$label: usage message"
}
usage_case "no input" --root "$R" --out "$OUT"
usage_case "--envelope with --round" --envelope "$FIX/envelope-round1.json" --ledger "$FIX/ledger.json" \
	--round "1=$FIX/envelope-round1.json" --root "$R" --out "$OUT"
usage_case "--round without --ledger" --round "1=$FIX/envelope-round1.json" --root "$R" --out "$OUT"
usage_case "duplicate round N" --ledger "$FIX/ledger.json" --round "1=$FIX/envelope-round1.json" \
	--round "1=$FIX/envelope-round2.json" --root "$R" --out "$OUT"
usage_case "round N=0" --ledger "$FIX/ledger.json" --round "0=$FIX/envelope-round1.json" --root "$R" --out "$OUT"
usage_case "round N non-integer" --ledger "$FIX/ledger.json" --round "abc=$FIX/envelope-round1.json" --root "$R" --out "$OUT"
usage_case "round empty path" --ledger "$FIX/ledger.json" --round "1=" --root "$R" --out "$OUT"
usage_case "round without =" --ledger "$FIX/ledger.json" --round "1" --root "$R" --out "$OUT"
usage_case "unknown flag" --ledger "$FIX/ledger.json" --bogus --root "$R" --out "$OUT"
usage_case "missing --out" --ledger "$FIX/ledger.json" --root "$R"
usage_case "missing --root" --ledger "$FIX/ledger.json" --out "$OUT"

echo "== renderer: suppress-keys =="
AUDIT_ENV="$SANDBOX/envelope-audited.json"
printf '{"schema_version":2,"findings":[{"severity":"Important","category":"logic","file":"a.py","line":9,"summary":"AUDITED-FIX","auto_fix_status":"would_apply"},{"severity":"Important","category":"logic","file":"b.py","line":10,"summary":"AUDITED-REJECT","auto_fix_status":"rejected"}]}' >"$AUDIT_ENV"
run_r --envelope "$AUDIT_ENV" --root "$R" --out "$OUT"
assert_has "$OUT" '[AUTO-FIXABLE]' "audited would_apply status is marked auto-fixable"
assert_eq "$(grep -oF '[AUTO-FIXABLE]' "$OUT" | wc -l | tr -d ' ')" "1" "only would_apply findings receive the marker"

KEYS="$SANDBOX/keys.tsv"
printf 'a.py\t10\tlogic\nc.md\t\tdocs\tminor-null-line\nd.md\t\tdocs\tminor-neg-line\n' >"$KEYS"
run_r --envelope "$FIX/envelope-severities.json" --suppress-keys "$KEYS" --root "$R" --out "$OUT"
assert_eq "$RC" "0" "suppress render exits 0"
assert_lacks "$OUT" 'crit-one' "exact 3-field match drops an anchored finding"
assert_lacks "$OUT" 'minor-null-line' "empty line field (4-field key) matches a null line"
assert_lacks "$OUT" 'minor-neg-line' "empty line field (4-field key) matches the -1 sentinel"
assert_has "$OUT" 'imp-one' "unmatched finding kept"
assert_has "$OUT" '3 finding(s) omitted.' "omitted count reported in envelope mode"

printf 'c.md\t\tdocs\nd.md\t\tdocs\n' >"$KEYS"
run_r --envelope "$FIX/envelope-severities.json" --suppress-keys "$KEYS" --root "$R" --out "$OUT"
assert_has "$OUT" 'minor-null-line' "a legacy 3-field key never drops an unanchored (null-line) finding"
assert_has "$OUT" 'minor-neg-line' "a legacy 3-field key never drops an unanchored (-1 line) finding"

printf 'a.py\t10\tlogic\tcrit-one\nb.py\t20\tlogic\tnot-the-summary\n' >"$KEYS"
run_r --envelope "$FIX/envelope-severities.json" --suppress-keys "$KEYS" --root "$R" --out "$OUT"
assert_lacks "$OUT" 'crit-one' "a 4-field key with a matching summary drops an anchored finding"
assert_has "$OUT" 'imp-one' "a 4-field key with a different summary keeps an anchored finding"

echo "== renderer: unanchored findings of one category are suppressed individually =="
UNANCH_ENV="$SANDBOX/envelope-unanchored.json"
cat >"$UNANCH_ENV" <<'JSON'
{"schema_version":2,"findings":[
{"severity":"Minor","category":"docs","file":"","line":null,"summary":"UNANCHORED-ONE"},
{"severity":"Minor","category":"docs","file":"","line":null,"summary":"UNANCHORED-TWO\twith a tab"}
]}
JSON
printf '\t\tdocs\tUNANCHORED-ONE\n' >"$KEYS"
run_r --envelope "$UNANCH_ENV" --suppress-keys "$KEYS" --root "$R" --out "$OUT"
assert_lacks "$OUT" 'UNANCHORED-ONE' "the keyed unanchored finding is dropped"
assert_has "$OUT" 'UNANCHORED-TWO' "the other unanchored finding of the same category is kept"
assert_has "$OUT" '1 finding(s) omitted.' "exactly one unanchored finding omitted"
printf '\t\tdocs\tUNANCHORED-TWO with a tab\n' >"$KEYS"
run_r --envelope "$UNANCH_ENV" --suppress-keys "$KEYS" --root "$R" --out "$OUT"
assert_lacks "$OUT" 'UNANCHORED-TWO' "a summary tab is matched as one space"
assert_has "$OUT" 'UNANCHORED-ONE' "only the keyed finding is dropped"
printf '\t\tdocs\n' >"$KEYS"
run_r --envelope "$UNANCH_ENV" --suppress-keys "$KEYS" --root "$R" --out "$OUT"
assert_has "$OUT" 'UNANCHORED-ONE' "an empty-file 3-field key does not match every unanchored finding (one)"
assert_has "$OUT" 'UNANCHORED-TWO' "an empty-file 3-field key does not match every unanchored finding (two)"

echo "== renderer: a key summary holding a Unicode line separator still matches =="
# str.splitlines() would cut this key at U+2028 / form feed and never match;
# the key file is split on LF only, because only tab, CR and LF are normalised.
SEP_ENV="$SANDBOX/envelope-linesep.json"
cat >"$SEP_ENV" <<'JSON'
{"schema_version":2,"findings":[
{"severity":"Minor","category":"docs","file":"","line":null,"summary":"SEP-ONE a b\fc"},
{"severity":"Minor","category":"docs","file":"","line":null,"summary":"SEP-TWO"}
]}
JSON
printf '\t\tdocs\tSEP-ONE a\xe2\x80\xa8b\x0cc\n' >"$KEYS"
run_r --envelope "$SEP_ENV" --suppress-keys "$KEYS" --root "$R" --out "$OUT"
assert_lacks "$OUT" 'SEP-ONE' "a summary with U+2028 and a form feed is matched by its key"
assert_has "$OUT" 'SEP-TWO' "the other unanchored finding is kept"
assert_has "$OUT" '1 finding(s) omitted.' "exactly one finding omitted for the separator key"

echo "== renderer: hostile JSON values fail cleanly, never with a traceback =="
# JSON `1e999` parses to inf (int() raises OverflowError); a lone surrogate
# escape survives html.escape but cannot be encoded as UTF-8.
INF_ENV="$SANDBOX/envelope-inf-line.json"
printf '{"schema_version":2,"findings":[{"severity":"Minor","category":"x","file":"a.py","line":1e999,"summary":"INF-LINE"}]}' >"$INF_ENV"
run_r --envelope "$INF_ENV" --root "$R" --out "$OUT"
assert_eq "$RC" "0" "an infinite line number renders instead of crashing"
assert_has "$OUT" 'INF-LINE' "the infinite-line finding is still shown"
assert_lacks_re "$ERR" 'Traceback' "no traceback for an infinite line number"
SUR_ENV="$SANDBOX/envelope-surrogate.json"
printf '{"schema_version":2,"findings":[{"severity":"Minor","category":"x","file":"a.py","line":3,"summary":"SURROGATE \\ud800 TEXT"}]}' >"$SUR_ENV"
run_r --envelope "$SUR_ENV" --root "$R" --out "$OUT"
assert_eq "$RC" "0" "a lone surrogate in finding text renders instead of crashing"
assert_has "$OUT" 'SURROGATE' "the surrogate finding is still shown"
assert_lacks_re "$ERR" 'Traceback' "no traceback for a lone surrogate"
DEEP_ENV="$SANDBOX/envelope-deep-nest.json"
python3 -c 'import sys; sys.stdout.write("[" * 200000)' >"$DEEP_ENV"
run_r --envelope "$DEEP_ENV" --root "$R" --out "$OUT"
assert_eq "$RC" "1" "a deeply nested JSON input is a clean failure"
assert_lacks_re "$ERR" 'Traceback' "no traceback for a deeply nested JSON input"

printf 'a.py\t11\tlogic\na.py\t10\tother\nb.py\t\tlogic\nbroken-no-tabs\nonly\ttwo\n' >"$KEYS"
run_r --envelope "$FIX/envelope-severities.json" --suppress-keys "$KEYS" --root "$R" --out "$OUT"
assert_has "$OUT" 'crit-one' "wrong line does not match"
assert_has "$OUT" 'imp-one' "empty line key does not match a finding that has a line"
assert_has "$OUT" 'minor-null-line' "keys with a mismatched category/line leave null-line findings alone"
assert_lacks "$OUT" 'finding(s) omitted' "nothing omitted when no key matches (and malformed lines are ignored)"

printf 'a.py\t-1\tlogic\n' >"$KEYS"
run_r --envelope "$FIX/envelope-severities.json" --suppress-keys "$KEYS" --root "$R" --out "$OUT"
assert_has "$OUT" 'crit-one' "a -1 key line is normalised to empty, so it does not match line 10"

run_r --envelope "$FIX/envelope-severities.json" --suppress-keys "$SANDBOX/no-such-keys" --root "$R" --out "$OUT"
assert_eq "$RC" "0" "missing keys file exits 0"
assert_has "$OUT" 'crit-one' "missing keys file means no filtering"

run_r --envelope "$FIX/envelope-severities.json" --suppress-keys "$FIX/suppress-keys.tsv" --root "$R" --out "$OUT"
assert_lacks "$OUT" 'crit-one' "fixture keys file drops a.py:10 logic"
assert_has "$OUT" 'imp-one' "fixture keys file (malformed lines ignored) keeps the rest"

echo "== renderer: diff scope =="
run_r --envelope "$FIX/envelope-empty.json" --root "$R" --out "$OUT"
assert_has "$OUT" 'diff scope unavailable' "absent --diff-stat renders diff scope unavailable"
run_r --envelope "$FIX/envelope-empty.json" --diff-stat "$FIX/diff-stat-failed.txt" --root "$R" --out "$OUT"
assert_eq "$RC" "0" "mode=failed header still renders"
assert_has "$OUT" 'diff scope unavailable (git diff failed)' "mode=failed header states the diff failed"
assert_lacks "$OUT" '<pre>' "mode=failed renders no stat block"
run_r --envelope "$FIX/envelope-empty.json" --diff-stat "$FIX/diff-stat-ok.txt" --root "$R" --out "$OUT"
assert_has "$OUT" '<pre>' "range diff-stat renders a pre block"
assert_has "$OUT" '1 file changed' "diff-stat text rendered"
assert_has "$OUT" 'mode=range' "diff-stat header rendered"
run_r --envelope "$FIX/envelope-empty.json" --diff-stat "$SANDBOX/no-such-stat" --root "$R" --out "$OUT"
assert_eq "$RC" "1" "a given-but-unreadable --diff-stat is a failure"

echo "== renderer: containment =="
cont_case() {
	local label="$1" rootarg="$2" outarg="$3" want_absent="${4:-}"
	run_r --envelope "$FIX/envelope-empty.json" --root "$rootarg" --out "$outarg"
	assert_eq "$RC" "1" "$label: exit 1"
	if [[ -z "$want_absent" || ! -e "$want_absent" ]]; then pass "$label: nothing written"; else fail "$label: wrote $want_absent"; fi
}
CR="$(new_dir)"
mkdir -p "$CR/.gauntlet" "$SANDBOX/outside"
cont_case "out outside root" "$CR" "$SANDBOX/outside/r.html" "$SANDBOX/outside/r.html"
cont_case "out equals root" "$CR" "$CR"
cont_case "out with .. component" "$CR" "$CR/.gauntlet/../escape.html" "$CR/escape.html"
cont_case "root with .. component" "$CR/.gauntlet/.." "$CR/r.html" "$CR/r.html"
cont_case "missing parent dir" "$CR" "$CR/no-such-dir/r.html" "$CR/no-such-dir"
ln -s "$SANDBOX/outside" "$CR/linkdir"
cont_case "symlinked directory component" "$CR" "$CR/linkdir/r.html" "$SANDBOX/outside/r.html"
ln -s "$SANDBOX/outside/leaf-target.html" "$CR/.gauntlet/leaf.html"
cont_case "symlinked leaf" "$CR" "$CR/.gauntlet/leaf.html" "$SANDBOX/outside/leaf-target.html"
mkdir -p "$CR/.gauntlet/adir.html"
cont_case "out is an existing directory" "$CR" "$CR/.gauntlet/adir.html"
assert_eq "$(no_residue "$CR" && echo clean)" "clean" "no <out>.tmp.<pid> residue under root after refusals"
assert_eq "$(no_residue "$SANDBOX/outside" && echo clean)" "clean" "no residue outside root after refusals"
# A refusal must happen before any input is read: a bad input must not mask it.
run_r --envelope "$SANDBOX/does-not-exist.json" --root "$CR" --out "$SANDBOX/outside/r.html"
assert_eq "$RC" "1" "containment refusal precedes input errors (still exit 1, nothing written)"
if [[ ! -e "$SANDBOX/outside/r.html" ]]; then pass "bad input plus bad out: nothing written"; else fail "bad input plus bad out wrote output"; fi

echo "== renderer: overwrite is atomic and read-only on inputs =="
R2="$(fresh_root)"
OUT2="$R2/.gauntlet/o.html"
printf 'OLD\n' >"$OUT2"
before="$(hash_tree "$FIX")"
run_r --ledger "$FIX/ledger.json" --round "1=$FIX/envelope-round1.json" --root "$R2" --out "$OUT2"
assert_eq "$RC" "0" "render over an existing regular file exits 0"
assert_lacks "$OUT2" 'OLD' "existing report replaced"
assert_eq "$(hash_tree "$FIX")" "$before" "renderer left every input fixture byte-identical"
assert_eq "$(no_residue "$R2" && echo clean)" "clean" "no temp residue after success"
assert_eq "$(find "$R2" -type f | wc -l | tr -d ' ')" "1" "exactly one file written"

echo "== renderer: SKEIN_REPORT_NOW determinism =="
A="$R2/.gauntlet/a.html"
B="$R2/.gauntlet/b.html"
SKEIN_REPORT_TEST=1 SKEIN_REPORT_NOW="2026-02-03T04:05:06Z" python3 "$RENDERER" --ledger "$FIX/ledger.json" --root "$R2" --out "$A"
SKEIN_REPORT_TEST=1 SKEIN_REPORT_NOW="2026-02-03T04:05:06Z" python3 "$RENDERER" --ledger "$FIX/ledger.json" --root "$R2" --out "$B"
assert_eq "$(hash_file "$A")" "$(hash_file "$B")" "same inputs and SKEIN_REPORT_NOW give byte-identical reports"
assert_has "$A" '2026-02-03T04:05:06Z' "the fixed timestamp is rendered"
SKEIN_REPORT_NOW="2026-02-03T04:05:06Z" python3 "$RENDERER" --ledger "$FIX/ledger.json" --root "$R2" --out "$A"
assert_lacks "$A" '2026-02-03T04:05:06Z' "SKEIN_REPORT_NOW is ignored without SKEIN_REPORT_TEST=1"

# ---------------------------------------------------------------- hook

echo "== hook: setup =="
mk_repo() {
	local r
	r="$(new_dir)"
	(
		cd "$r"
		git init -q .
		git config user.email t@example.invalid
		git config user.name t
		printf '.gauntlet/\n.deep-review/\n' >.gitignore
		printf 'one\n' >f.txt
		git add .gitignore f.txt
		git commit -q -m one
		printf 'two\n' >>f.txt
		git commit -q -am two
	)
	mkdir -p "$r/.gauntlet" "$r/.deep-review"
	printf '%s\n' "$r"
}
REPO="$(mk_repo)"
BASE="$(git -C "$REPO" rev-parse HEAD~1)"
HEAD_OID="$(git -C "$REPO" rev-parse HEAD)"
HOUT="$REPO/.gauntlet/ledger-x.report.html"
HSTDOUT="$SANDBOX/hook-stdout.txt"
HERR="$SANDBOX/hook-stderr.txt"

# run_h ARGS... — run the hook; asserts nothing, records HRC/stdout/stderr.
HRC=0
run_h() {
	HRC=0
	bash "$HOOK" "$@" >"$HSTDOUT" 2>"$HERR" || HRC=$?
}

# Seed .gauntlet with state the hook must never touch.
printf '{"rounds":[]}\n' >"$REPO/.gauntlet/ledger-x.json"
mkdir -p "$REPO/.gauntlet/ledger-x/round-1"
printf '{"schema_version":2,"findings":[]}\n' >"$REPO/.gauntlet/ledger-x/round-1/reconciled.json"
printf '{}\n' >"$REPO/.deep-review/latest-claude.json"
SCRATCH_TMP="$(new_dir)"

echo "== hook: success path =="
state_before="$(hash_tree "$REPO/.gauntlet" | grep -v 'report.html' || true)$(hash_tree "$REPO/.deep-review")"
TMPDIR="$SCRATCH_TMP" run_h --root "$REPO" --out "$HOUT" --ledger "$REPO/.gauntlet/ledger-x.json" \
	--round "1=$REPO/.gauntlet/ledger-x/round-1/reconciled.json" --base "$BASE" --head "$HEAD_OID"
assert_eq "$HRC" "0" "hook exits 0 on success"
assert_has "$HSTDOUT" "report written: $HOUT" "hook prints 'report written: <out>'"
if [[ -f "$HOUT" ]]; then pass "report file exists"; else fail "report file missing"; fi
assert_has "$HOUT" 'f.txt' "diff stat of the real range is in the report"
assert_has "$HOUT" 'mode=range' "diff-stat header rendered"
assert_lacks "$HERR" 'warning' "no warnings for a git-ignored report path"
state_after="$(hash_tree "$REPO/.gauntlet" | grep -v 'report.html' || true)$(hash_tree "$REPO/.deep-review")"
assert_eq "$state_after" "$state_before" "no .gauntlet/.deep-review file changed other than the report"
assert_eq "$(find "$SCRATCH_TMP" -type f | wc -l | tr -d ' ')" "0" "scratch diff-stat file removed after success"

echo "== hook: --out guard refusals still exit 0 =="
guard_case() {
	local label="$1" out="$2" root="${3:-$REPO}"
	run_h --root "$root" --out "$out" --ledger "$FIX/ledger.json"
	assert_eq "$HRC" "0" "$label: exit 0"
	assert_has "$HERR" 'report-hook: warning:' "$label: warning on stderr"
	assert_eq "$(cat "$HSTDOUT")" "" "$label: no 'report written' line"
}
guard_case "parent not .gauntlet/.deep-review" "$REPO/elsewhere.html"
if [[ ! -e "$REPO/elsewhere.html" ]]; then pass "refused out was not written"; else fail "refused out was written"; fi
guard_case "nested below .gauntlet" "$REPO/.gauntlet/sub/r.html"
guard_case ".. in out" "$REPO/.gauntlet/../r.html"
guard_case ".. in root" "$REPO/.gauntlet/r.html" "$REPO/.gauntlet/.."
guard_case "empty out" ""
mkdir -p "$SANDBOX/real-gauntlet"
SYMROOT="$(new_dir)"
ln -s "$SANDBOX/real-gauntlet" "$SYMROOT/.gauntlet"
guard_case "symlinked .gauntlet" "$SYMROOT/.gauntlet/r.html" "$SYMROOT"
if [[ ! -e "$SANDBOX/real-gauntlet/r.html" ]]; then pass "nothing written through the symlinked dir"; else fail "wrote through symlinked .gauntlet"; fi
mkdir -p "$SYMROOT/.deep-review"
ln -s "$SANDBOX/real-gauntlet/leaf-target.html" "$SYMROOT/.deep-review/report-claude.html"
guard_case "symlinked leaf" "$SYMROOT/.deep-review/report-claude.html" "$SYMROOT"
if [[ ! -e "$SANDBOX/real-gauntlet/leaf-target.html" ]]; then pass "nothing written through the symlinked leaf"; else fail "wrote through symlinked leaf"; fi
unset SYMROOT

echo "== hook: --out under .deep-review is allowed =="
DOUT="$REPO/.deep-review/report-claude.html"
run_h --root "$REPO" --out "$DOUT" --envelope "$FIX/envelope-severities.json"
assert_eq "$HRC" "0" "deep-review style invocation exits 0"
if [[ -f "$DOUT" ]]; then pass "deep-review report written"; else fail "deep-review report missing"; fi
assert_has "$DOUT" 'as reviewed; suppressed and auto-fixed findings omitted' "--envelope is forwarded"

echo "== hook: always exits 0 =="
rm -f "$HOUT"
run_h --bogus-flag --root "$REPO" --out "$HOUT"
assert_eq "$HRC" "0" "unknown flag: exit 0"
assert_has "$HERR" 'unknown argument' "unknown flag: warning"
run_h --root
assert_eq "$HRC" "0" "flag missing its value: exit 0"
assert_has "$HERR" 'needs a value' "flag missing its value: warning"
run_h
assert_eq "$HRC" "0" "no arguments: exit 0"
if [[ ! -e "$HOUT" ]]; then pass "no report from refused invocations"; else fail "report written by a refused invocation"; fi

run_h --root "$REPO" --out "$HOUT" --ledger "$SANDBOX/does-not-exist.json"
assert_eq "$HRC" "0" "renderer failure (missing ledger): exit 0"
assert_has "$HERR" 'renderer failed (exit 1)' "renderer failure: warning names the exit code"
assert_eq "$(cat "$HSTDOUT")" "" "renderer failure: no 'report written' line"
if [[ ! -e "$HOUT" ]]; then pass "renderer failure: no report"; else fail "renderer failure left a report"; fi

run_h --root "$REPO" --out "$HOUT" --ledger "$FIX/ledger.json" --round "1=$FIX/envelope-round1.json" --round "1=$FIX/envelope-round2.json"
assert_eq "$HRC" "0" "renderer usage error (exit 2): exit 0"
assert_has "$HERR" 'renderer failed (exit 2)' "renderer usage error: warning names exit 2"

echo "== hook: renderer stub via SKEIN_REPORT_RENDERER =="
STUB="$SANDBOX/stub.sh"
cat >"$STUB" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${STUB_ARGS:?}"
exit "${STUB_RC:-0}"
EOF
chmod +x "$STUB"
export SKEIN_REPORT_TEST=1
STUB_ARGS="$SANDBOX/stub-args.txt" SKEIN_REPORT_RENDERER="$STUB" run_h --root "$REPO" --out "$HOUT" \
	--ledger "$FIX/ledger.json" --suppress-keys "$KEYS"
assert_eq "$HRC" "0" "stub renderer: exit 0"
assert_has "$HSTDOUT" "report written: $HOUT" "stub success: report written line"
assert_has "$SANDBOX/stub-args.txt" '--ledger' "stub received --ledger"
assert_has "$SANDBOX/stub-args.txt" '--suppress-keys' "stub received --suppress-keys"
assert_has "$SANDBOX/stub-args.txt" "$HOUT" "stub received --out"
assert_lacks "$SANDBOX/stub-args.txt" '--diff-stat' "no --diff-stat without --base/--head"
STUB_RC=7 STUB_ARGS="$SANDBOX/stub-args.txt" SKEIN_REPORT_RENDERER="$STUB" run_h --root "$REPO" --out "$HOUT" --ledger "$FIX/ledger.json"
assert_eq "$HRC" "0" "stub exiting 7: hook still exits 0"
assert_has "$HERR" 'renderer failed (exit 7)' "stub failure: warning carries the exit code"
assert_eq "$(cat "$HSTDOUT")" "" "stub failure: no 'report written' line"
printf 'STALE-REPORT\n' >"$HOUT"
STUB_RC=7 STUB_ARGS="$SANDBOX/stub-args.txt" SKEIN_REPORT_RENDERER="$STUB" run_h --root "$REPO" --out "$HOUT" --ledger "$FIX/ledger.json"
assert_lacks "$HOUT" 'STALE-REPORT' "renderer failure invalidates stale latest-run report"
SKEIN_REPORT_RENDERER="$SANDBOX/not-an-executable" run_h --root "$REPO" --out "$HOUT" --ledger "$FIX/ledger.json"
assert_eq "$HRC" "0" "nonexistent renderer path: exit 0"
unset SKEIN_REPORT_TEST
: >"$SANDBOX/stub-args.txt"
STUB_ARGS="$SANDBOX/stub-args.txt" SKEIN_REPORT_RENDERER="$STUB" run_h --root "$REPO" --out "$HOUT" --ledger "$FIX/ledger.json"
assert_eq "$(wc -c <"$SANDBOX/stub-args.txt" | tr -d ' ')" "0" "SKEIN_REPORT_RENDERER is ignored without SKEIN_REPORT_TEST=1"
assert_has "$HOUT" '<!DOCTYPE html>' "without SKEIN_REPORT_TEST=1 the real renderer writes the report"
TMPDIR="$SCRATCH_TMP" SKEIN_REPORT_NOW="2001-01-01T00:00:00Z" run_h --root "$REPO" --out "$HOUT" \
	--ledger "$FIX/ledger.json" --base "$BASE" --head "$HEAD_OID"
assert_lacks "$HOUT" '2001-01-01T00:00:00Z' "SKEIN_REPORT_NOW is ignored by the hook without SKEIN_REPORT_TEST=1"
TMPDIR="$SCRATCH_TMP" SKEIN_REPORT_TEST=1 SKEIN_REPORT_NOW="2001-01-01T00:00:00Z" run_h --root "$REPO" --out "$HOUT" \
	--ledger "$FIX/ledger.json" --base "$BASE" --head "$HEAD_OID"
assert_has "$HOUT" 'time=2001-01-01T00:00:00Z' "SKEIN_REPORT_NOW pins the diff-stat header under SKEIN_REPORT_TEST=1"
rm -f "$HOUT"

echo "== hook: python3 absent =="
NOPY="$(new_dir)"
printf 'STALE-REPORT\n' >"$HOUT"
for tool in bash dirname git mktemp date rm cat head sed tr cut; do
	p="$(command -v "$tool" 2>/dev/null || true)"
	[[ -n "$p" && "$p" == /* ]] && ln -s "$p" "$NOPY/$tool"
done
HRC=0
PATH="$NOPY" "$NOPY/bash" "$HOOK" --root "$REPO" --out "$HOUT" --ledger "$FIX/ledger.json" >"$HSTDOUT" 2>"$HERR" || HRC=$?
assert_eq "$HRC" "0" "python3 absent: exit 0"
assert_has "$HERR" 'python3 not found' "python3 absent: warning"
if [[ ! -e "$HOUT" ]]; then pass "python3 absent: stale report invalidated"; else fail "python3 absent: stale report remains"; fi

echo "== hook: diff scope handling =="
# --base without --head
run_h --root "$REPO" --out "$HOUT" --ledger "$FIX/ledger.json" --base "$BASE"
assert_eq "$HRC" "0" "--base without --head: exit 0"
assert_has "$HERR" 'must be given together' "--base without --head: warning"
assert_has "$HOUT" 'diff scope unavailable' "--base without --head: report says diff scope unavailable"
assert_lacks "$HOUT" 'mode=' "--base without --head: no diff-stat header"
# --head without --base
run_h --root "$REPO" --out "$HOUT" --ledger "$FIX/ledger.json" --head "$HEAD_OID"
assert_has "$HERR" 'must be given together' "--head without --base: warning"
# non-hex OIDs
TMPDIR="$SCRATCH_TMP" run_h --root "$REPO" --out "$HOUT" --ledger "$FIX/ledger.json" --base 'main;touch pwned' --head 'HEAD'
assert_eq "$HRC" "0" "non-hex OID: exit 0"
assert_has "$HERR" 'must be commit ids' "non-hex OID: warning"
assert_has "$HOUT" 'mode=failed' "non-hex OID: diff-stat header mode=failed"
assert_has "$HOUT" 'diff scope unavailable (git diff failed)' "non-hex OID: report says diff failed"
if [[ ! -e "$REPO/pwned" && ! -e "$PWD/pwned" ]]; then pass "non-hex OID never reaches a shell"; else fail "non-hex OID executed"; fi
assert_eq "$(find "$SCRATCH_TMP" -type f | wc -l | tr -d ' ')" "0" "scratch file removed after mode=failed"
# git failure: well-formed hex that is not an object
TMPDIR="$SCRATCH_TMP" run_h --root "$REPO" --out "$HOUT" --ledger "$FIX/ledger.json" \
	--base deadbeefdeadbeefdeadbeefdeadbeefdeadbeef --head "$HEAD_OID"
assert_eq "$HRC" "0" "git failure: exit 0"
assert_has "$HERR" 'git diff --stat' "git failure: warning"
assert_has "$HOUT" 'mode=failed' "git failure: mode=failed header"
assert_eq "$(find "$SCRATCH_TMP" -type f | wc -l | tr -d ' ')" "0" "scratch file removed after git failure"
# root that is not a git repo at all
NOGIT="$(new_dir)"
mkdir -p "$NOGIT/.gauntlet"
run_h --root "$NOGIT" --out "$NOGIT/.gauntlet/r.html" --ledger "$FIX/ledger.json" --base "$BASE" --head "$HEAD_OID"
assert_eq "$HRC" "0" "non-git root: exit 0"
assert_has "$NOGIT/.gauntlet/r.html" 'mode=failed' "non-git root: report still written, scope unavailable"

echo "== hook: diff stat ignores color.ui=always =="
git -C "$REPO" config color.ui always
git -C "$REPO" config color.diff always
TMPDIR="$SCRATCH_TMP" run_h --root "$REPO" --out "$HOUT" --ledger "$FIX/ledger.json" --base "$BASE" --head "$HEAD_OID"
assert_has "$HOUT" 'f.txt' "color.ui=always: diff stat still captured"
if LC_ALL=C grep -q $'\x1b' "$HOUT"; then
	fail "color.ui=always: ANSI escape leaked into the report"
else
	pass "color.ui=always: no ANSI escape in the report (--no-color)"
fi
assert_lacks "$HOUT" '[m' "color.ui=always: no escaped colour reset sequence in the report"
git -C "$REPO" config --unset color.ui
git -C "$REPO" config --unset color.diff

echo "== hook: --cleanup deletes only its own scratch inputs =="
CL_TMP="$(new_dir)"
cl_env="$CL_TMP/skein-report-envelope.AAAAAA"
cl_keys="$CL_TMP/skein-report-keys.BBBBBB"
cl_seed() {
	cp "$FIX/envelope-severities.json" "$cl_env"
	printf 'a.py\t10\tlogic\n' >"$cl_keys"
}
cl_seed
TMPDIR="$CL_TMP" run_h --root "$REPO" --out "$DOUT" --envelope "$cl_env" --suppress-keys "$cl_keys" --cleanup
assert_eq "$HRC" "0" "--cleanup success: exit 0"
assert_has "$HSTDOUT" "report written: $DOUT" "--cleanup success: report written"
assert_lacks "$DOUT" 'crit-one' "--cleanup: suppress keys were applied before deletion"
if [[ ! -e "$cl_env" && ! -e "$cl_keys" ]]; then pass "--cleanup deletes envelope and keys after success"; else fail "--cleanup left scratch inputs after success"; fi
cl_seed
TMPDIR="$CL_TMP" run_h --root "$REPO" --out "$REPO/elsewhere.html" --envelope "$cl_env" --suppress-keys "$cl_keys" --cleanup
assert_eq "$HRC" "0" "--cleanup after a guard refusal: exit 0"
if [[ ! -e "$cl_env" && ! -e "$cl_keys" ]]; then pass "--cleanup deletes scratch inputs after a guard refusal"; else fail "--cleanup left scratch inputs after a guard refusal"; fi
cl_seed
printf 'not json' >"$cl_env"
TMPDIR="$CL_TMP" run_h --root "$REPO" --out "$DOUT" --envelope "$cl_env" --suppress-keys "$cl_keys" --cleanup
assert_has "$HERR" 'renderer failed' "--cleanup after a renderer failure: warning"
if [[ ! -e "$cl_env" && ! -e "$cl_keys" ]]; then pass "--cleanup deletes scratch inputs after a renderer failure"; else fail "--cleanup left scratch inputs after a renderer failure"; fi
cl_seed
TMPDIR="$CL_TMP" run_h --envelope "$cl_env" --cleanup --suppress-keys "$cl_keys" --bogus
assert_eq "$HRC" "0" "--cleanup with a bad argument: exit 0"
if [[ ! -e "$cl_env" && ! -e "$cl_keys" ]]; then pass "--cleanup deletes scratch inputs even when argument parsing stops early"; else fail "--cleanup left scratch inputs after a bad argument"; fi
cl_seed
TMPDIR="$CL_TMP" run_h --suppress-keys "$cl_keys" --cleanup
assert_eq "$HRC" "0" "--cleanup with only --suppress-keys (envelope-missing skip path): exit 0"
if [[ ! -e "$cl_keys" ]]; then pass "--cleanup removes the keys file on the envelope-missing skip path"; else fail "--cleanup left the keys file on the skip path"; fi
cl_seed
TMPDIR="$CL_TMP" run_h --root "$REPO" --out "$DOUT" --envelope "$cl_env" --suppress-keys "$cl_keys"
if [[ -e "$cl_env" && -e "$cl_keys" ]]; then pass "without --cleanup the scratch inputs are kept"; else fail "scratch inputs deleted without --cleanup"; fi
# Refusals: outside the temp dir, wrong name, nested, symlink, '..'.
CL_OUT="$(new_dir)"
printf 'keep\n' >"$CL_OUT/skein-report-keys.CCCCCC"
cp "$FIX/envelope-severities.json" "$CL_TMP/envelope.json"
mkdir -p "$CL_TMP/sub"
printf 'keep\n' >"$CL_TMP/sub/skein-report-keys.DDDDDD"
printf 'keep\n' >"$CL_OUT/target.txt"
ln -s "$CL_OUT/target.txt" "$CL_TMP/skein-report-keys.LINK"
TMPDIR="$CL_TMP" run_h --root "$REPO" --out "$DOUT" --envelope "$CL_TMP/envelope.json" \
	--suppress-keys "$CL_OUT/skein-report-keys.CCCCCC" --cleanup
assert_eq "$HRC" "0" "--cleanup refusal: exit 0"
assert_has "$HERR" '--cleanup: not deleting' "--cleanup refusal: warning"
if [[ -f "$CL_OUT/skein-report-keys.CCCCCC" ]]; then pass "--cleanup refuses a file outside the temp dir"; else fail "--cleanup deleted a file outside the temp dir"; fi
if [[ -f "$CL_TMP/envelope.json" ]]; then pass "--cleanup refuses a file not named skein-report-*"; else fail "--cleanup deleted a non-skein-report file"; fi
TMPDIR="$CL_TMP" run_h --root "$REPO" --out "$DOUT" --envelope "$cl_env" \
	--suppress-keys "$CL_TMP/sub/skein-report-keys.DDDDDD" --cleanup
if [[ -f "$CL_TMP/sub/skein-report-keys.DDDDDD" ]]; then pass "--cleanup refuses a file nested below the temp dir"; else fail "--cleanup deleted a nested file"; fi
TMPDIR="$CL_TMP" run_h --root "$REPO" --out "$DOUT" --suppress-keys "$CL_TMP/skein-report-keys.LINK" --envelope "$cl_env" --cleanup
if [[ -L "$CL_TMP/skein-report-keys.LINK" && -f "$CL_OUT/target.txt" ]]; then pass "--cleanup refuses a symlink and leaves its target"; else fail "--cleanup removed a symlink or its target"; fi
printf 'keep\n' >"$CL_TMP/skein-report-keys.EEEEEE"
TMPDIR="$CL_TMP" run_h --root "$REPO" --out "$DOUT" --suppress-keys "$CL_TMP/sub/../skein-report-keys.EEEEEE" --envelope "$cl_env" --cleanup
if [[ -f "$CL_TMP/skein-report-keys.EEEEEE" ]]; then pass "--cleanup refuses a path containing '..'"; else fail "--cleanup deleted through a '..' path"; fi

echo "== hook: check-ignore warning =="
NOIGN="$(new_dir)"
(cd "$NOIGN" && git init -q .)
mkdir -p "$NOIGN/.gauntlet"
run_h --root "$NOIGN" --out "$NOIGN/.gauntlet/r.html" --ledger "$FIX/ledger.json"
assert_eq "$HRC" "0" "un-ignored report path: exit 0"
assert_has "$HERR" 'not git-ignored' "un-ignored report path: warns not to commit it"
assert_has "$HSTDOUT" 'report written' "un-ignored report path: report is still written"
run_h --root "$REPO" --out "$HOUT" --ledger "$FIX/ledger.json"
assert_lacks "$HERR" 'not git-ignored' "ignored report path: no check-ignore warning"

echo "== hook: bundled copies behave the same =="
for hook in \
	"$ROOT_DIR/plugins/skein/skills/review-gauntlet/scripts/report-hook.sh" \
	"$ROOT_DIR/plugins/skein/skills/deep-review/scripts/report-hook.sh"; do
	name="$(basename "$(dirname "$(dirname "$hook")")")"
	rm -f "$HOUT"
	HRC=0
	bash "$hook" --root "$REPO" --out "$HOUT" --ledger "$FIX/ledger.json" >"$HSTDOUT" 2>"$HERR" || HRC=$?
	assert_eq "$HRC" "0" "$name bundle: exit 0"
	assert_has "$HSTDOUT" "report written: $HOUT" "$name bundle: report written"
	rm -f "$HOUT"
	HRC=0
	bash "$hook" --root "$REPO" --out "$REPO/elsewhere.html" --ledger "$FIX/ledger.json" >"$HSTDOUT" 2>"$HERR" || HRC=$?
	assert_eq "$HRC" "0" "$name bundle: refused out still exit 0"
	assert_has "$HERR" 'warning' "$name bundle: refused out warns"
done

echo ""
echo "Results: $pass_count passed, $fail_count failed"

if [[ "$fail_count" -gt 0 ]]; then
	exit 1
fi

exit 0
