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

echo "== renderer: empty findings =="
run_r --envelope "$FIX/envelope-empty.json" --root "$R" --out "$OUT"
assert_eq "$RC" "0" "findings: [] exits 0"
assert_has "$OUT" 'None.' "empty severity bucket renders None."

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
assert_has "$OUT" 'ROUND-TWO-ONLY' "severity section shows the highest PRESENT round"
assert_lacks "$OUT" 'ROUND-ONE-ONLY' "earlier round findings are not rendered"
assert_has "$OUT" 'Round 2 (latest round with an envelope)' "the rendered round is named"
assert_has "$OUT" 'branch:fixture' "ledger target shown"

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
KEYS="$SANDBOX/keys.tsv"
printf 'a.py\t10\tlogic\nc.md\t\tdocs\nd.md\t\tdocs\n' >"$KEYS"
run_r --envelope "$FIX/envelope-severities.json" --suppress-keys "$KEYS" --root "$R" --out "$OUT"
assert_eq "$RC" "0" "suppress render exits 0"
assert_lacks "$OUT" 'crit-one' "exact 3-field match drops the finding"
assert_lacks "$OUT" 'minor-null-line' "empty line field matches a null line"
assert_lacks "$OUT" 'minor-neg-line' "empty line field matches the -1 sentinel"
assert_has "$OUT" 'imp-one' "unmatched finding kept"
assert_has "$OUT" '3 finding(s) omitted.' "omitted count reported in envelope mode"

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
SKEIN_REPORT_NOW="2026-02-03T04:05:06Z" python3 "$RENDERER" --ledger "$FIX/ledger.json" --root "$R2" --out "$A"
SKEIN_REPORT_NOW="2026-02-03T04:05:06Z" python3 "$RENDERER" --ledger "$FIX/ledger.json" --root "$R2" --out "$B"
assert_eq "$(hash_file "$A")" "$(hash_file "$B")" "same inputs and SKEIN_REPORT_NOW give byte-identical reports"
assert_has "$A" '2026-02-03T04:05:06Z' "the fixed timestamp is rendered"

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
SKEIN_REPORT_RENDERER="$SANDBOX/not-an-executable" run_h --root "$REPO" --out "$HOUT" --ledger "$FIX/ledger.json"
assert_eq "$HRC" "0" "nonexistent renderer path: exit 0"

echo "== hook: python3 absent =="
NOPY="$(new_dir)"
for tool in bash dirname git mktemp date rm cat head sed tr cut; do
	p="$(command -v "$tool" 2>/dev/null || true)"
	[[ -n "$p" && "$p" == /* ]] && ln -s "$p" "$NOPY/$tool"
done
HRC=0
PATH="$NOPY" "$NOPY/bash" "$HOOK" --root "$REPO" --out "$HOUT" --ledger "$FIX/ledger.json" >"$HSTDOUT" 2>"$HERR" || HRC=$?
assert_eq "$HRC" "0" "python3 absent: exit 0"
assert_has "$HERR" 'python3 not found' "python3 absent: warning"
if [[ ! -e "$HOUT" ]]; then pass "python3 absent: no report"; else fail "python3 absent: report written"; fi

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
