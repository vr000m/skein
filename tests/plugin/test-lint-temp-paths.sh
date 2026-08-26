#!/usr/bin/env bash
# test-lint-temp-paths.sh — regression suite for scripts/lint-temp-paths.sh.
#
# WHY THIS FILE EXISTS (round 9, F6). The lint is a REPO-WIDE hygiene rule, but
# its only regression case (`R8-G6a`) lived inside
# tests/gauntlet/test-gate-timeout.sh — a suite whose stated subject is
# gate_run_bounded's timeout/envelope contract — purely because the offending
# fixture happened to be in that file. Test placement followed the BUG's
# location rather than the ASSERTION's subject, and `just lint-scripts` (the
# recipe that actually runs the lint) had no test at all. The invariant now
# stated and held: a repo-wide hygiene lint's regression test lives in a file
# whose subject is that lint, reached by a suite recipe that does not depend on
# the review-gauntlet feature suite (`just plugin-tests`, whose subject is
# plugin-level/repo-wide guards).
#
# EVERY banned literal below is assembled from two string pieces
# (`"/tmp""/name"`) so the FIXTURES contain the shape while this file does not
# — otherwise the lint under test would flag its own regression test. The lint
# anchors on its own location (`cd <script dir>/..`), so each case copies it
# into a scratch tree and runs it there.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

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

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# lint_root <name> — make a scratch tree with the lint copied in, echo its path.
lint_root() {
	local root="$WORKDIR/$1"
	mkdir -p "$root/scripts" "$root/tests" "$root/plugins"
	cp "$REPO_ROOT/scripts/lint-temp-paths.sh" "$root/scripts/"
	printf '%s\n' "$root"
}

# run_lint <root> — echo rc on line 1, output on the rest.
run_lint() {
	local out rc
	set +e
	out="$(bash "$1/scripts/lint-temp-paths.sh" 2>&1)"
	rc=$?
	set -e
	printf '%s\n%s\n' "$rc" "$out"
}

TMP_PREFIX="/tmp"
VARTMP_PREFIX="/var/tmp"

# ---------------------------------------------------------------------------
# R9-G3a (moved verbatim from tests/gauntlet/test-gate-timeout.sh's R8-G6a) —
# the temp-path lint must see a FULLY STATIC /tmp path (round 8, F10).
#
# The pre-round-8 regex encoded "predictable = literal PLUS `$$`/`$RANDOM`", so
# a static `/tmp/<name>/x` — strictly MORE predictable — was invisible to the
# lint whose stated rule is "refuse predictable temp paths". That is how a
# security fixture in the gauntlet suite came to use a static `/tmp/<name>`
# directory as a guard input with an expected verdict of "accepted": any local
# user could pre-create that directory as a symlink and flip the verdict.
r9g3a_root="$(lint_root r9g3a)"
r9g3a_static_path="$TMP_PREFIX""/staticname/x"
printf '%s\n' '#!/usr/bin/env bash' "p=\"$r9g3a_static_path\"" >"$r9g3a_root/tests/static.sh"
r9g3a_res="$(run_lint "$r9g3a_root")"
r9g3a_rc="$(printf '%s' "$r9g3a_res" | head -1)"
r9g3a_out="$(printf '%s' "$r9g3a_res" | tail -n +2)"

if [[ "$r9g3a_rc" -eq 1 && "$r9g3a_out" == *"$r9g3a_static_path"* ]]; then
	pass "R9-G3a: lint-temp-paths.sh refuses a fully STATIC temp path"
else
	fail "R9-G3a: static rc=$r9g3a_rc out='$r9g3a_out'"
fi

# ---------------------------------------------------------------------------
# R9-G2a — the `$$`/`$RANDOM`/`${var}` shapes must still be refused (round 9,
# F4). The round-8 widening REPLACED the `$`-bearing alternative with
# `[A-Za-z0-9._-]` instead of ORing it, so the three shapes this lint was
# ORIGINALLY written for — the ones the header still claimed to cover — all
# passed clean. The class is now the UNION of both.
r9g2a_root="$(lint_root r9g2a)"
r9g2a_expect=(
	"$TMP_PREFIX""/\$\$.json"
	"$TMP_PREFIX""/\$RANDOM/x"
	"$VARTMP_PREFIX""/\$\$-foo"
	"$TMP_PREFIX""/\${n}.json"
)
{
	printf '%s\n' '#!/usr/bin/env bash'
	printf 'a="%s"\n' "$TMP_PREFIX""/\$\$.json"
	printf 'b="%s"\n' "$TMP_PREFIX""/\$RANDOM/x"
	printf 'c="%s"\n' "$VARTMP_PREFIX""/\$\$-foo"
	printf 'd="%s"\n' "$TMP_PREFIX""/\${n}.json"
} >"$r9g2a_root/tests/expansions.sh"
r9g2a_res="$(run_lint "$r9g2a_root")"
r9g2a_rc="$(printf '%s' "$r9g2a_res" | head -1)"
r9g2a_out="$(printf '%s' "$r9g2a_res" | tail -n +2)"

r9g2a_missing=""
for r9g2a_p in "${r9g2a_expect[@]}"; do
	[[ "$r9g2a_out" == *"$r9g2a_p"* ]] || r9g2a_missing="$r9g2a_missing $r9g2a_p"
done

if [[ "$r9g2a_rc" -eq 1 && -z "$r9g2a_missing" ]]; then
	pass "R9-G2a: lint-temp-paths.sh refuses the \$\$ / \$RANDOM / \${var} temp-path shapes"
else
	fail "R9-G2a: rc=$r9g2a_rc missing='$r9g2a_missing' out='$r9g2a_out'"
fi

# ---------------------------------------------------------------------------
# R9-G2b — a `#` elsewhere on the line must NOT exempt it (round 9, F5). The
# old `^[^#]*` prefix class exempted any line carrying a `#` anywhere to the
# left of the path — inside a string, in a `jq` filter, in a `${v#pfx}`
# expansion, or as a trailing comment — so appending ` # ok` to an offending
# line silently disabled the lint for it. The exemption is a LINE predicate
# now: first non-blank character is `#`, or nothing.
r9g2b_root="$(lint_root r9g2b)"
r9g2b_path="$TMP_PREFIX""/hashline/x"
{
	printf '%s\n' '#!/usr/bin/env bash'
	printf 'x="a#b"; p="%s"\n' "$r9g2b_path"
	printf 'q="%s" # trailing comment\n' "$r9g2b_path"
} >"$r9g2b_root/tests/hash.sh"
r9g2b_res="$(run_lint "$r9g2b_root")"
r9g2b_rc="$(printf '%s' "$r9g2b_res" | head -1)"
r9g2b_out="$(printf '%s' "$r9g2b_res" | tail -n +2)"
r9g2b_hits="$(printf '%s\n' "$r9g2b_out" | grep -c 'hash\.sh' || true)"

if [[ "$r9g2b_rc" -eq 1 && "$r9g2b_hits" -eq 2 ]]; then
	pass "R9-G2b: a '#' inside a string or as a trailing comment exempts nothing"
else
	fail "R9-G2b: rc=$r9g2b_rc hits=$r9g2b_hits out='$r9g2b_out'"
fi

# ---------------------------------------------------------------------------
# R9-G2c — the two carve-outs still hold (carried over from R8-G6a): bare
# `/tmp` as a CWD stays legal (it names no file, and the cwd-invariance matrix
# in tests/gauntlet/test-gate-timeout.sh requires it), and a WHOLE-LINE comment
# naming a banned path is prose, not the banned shape. Narrowing the exemption
# in R9-G2b must not have narrowed it past this line.
r9g2c_root="$(lint_root r9g2c)"
{
	printf '%s\n' '#!/usr/bin/env bash'
	printf '%s\n' 'cd /tmp || exit 1'
	printf '# a comment mentioning %s\n' "$TMP_PREFIX""/staticname/x"
	printf '\t#  an INDENTED comment mentioning %s\n' "$VARTMP_PREFIX""/\$\$-foo"
} >"$r9g2c_root/tests/cwd.sh"
r9g2c_res="$(run_lint "$r9g2c_root")"
r9g2c_rc="$(printf '%s' "$r9g2c_res" | head -1)"
r9g2c_out="$(printf '%s' "$r9g2c_res" | tail -n +2)"

if [[ "$r9g2c_rc" -eq 0 ]]; then
	pass "R9-G2c: bare '/tmp' as a cwd and whole-line (incl. indented) comment prose stay legal"
else
	fail "R9-G2c: carve-out rc=$r9g2c_rc out='$r9g2c_out'"
fi

# ---------------------------------------------------------------------------
# R10-B1a — the comment exemption must be a predicate over the LINE'S OWN
# TEXT, never over `grep -rn`'s `path:line:` prefix (round 10, F7). The old
# exemption regex `^[^:]*:[0-9]+:[[:space:]]*#` was applied to a string whose
# first field is the FILENAME, so a source file named `a:9:#.sh` satisfied the
# exemption in its own PATH and every offending line in it was dropped. The
# lint now greps each file individually (`grep -n` emits `lineno:content`, no
# path) and re-attaches the path with `printf` purely for the report.
r10b1a_root="$(lint_root r10b1a)"
r10b1a_path="$TMP_PREFIX""/predictable/x"
printf '%s\n' '#!/usr/bin/env bash' "p=\"$r10b1a_path\"" >"$r10b1a_root/tests/a:9:#.sh"
r10b1a_res="$(run_lint "$r10b1a_root")"
r10b1a_rc="$(printf '%s' "$r10b1a_res" | head -1)"
r10b1a_out="$(printf '%s' "$r10b1a_res" | tail -n +2)"

if [[ "$r10b1a_rc" -eq 1 && "$r10b1a_out" == *"$r10b1a_path"* ]]; then
	pass "R10-B1a: a filename containing ':<digits>:#' cannot exempt its own lines"
else
	fail "R10-B1a: rc=$r10b1a_rc out='$r10b1a_out'"
fi

# ---------------------------------------------------------------------------
# R10-B1b — a QUOTED first component must be in the class (round 10, F6). The
# round-9 class `[A-Za-z0-9._$-]` answered "what can start a filename or an
# expansion" and never asked what appears in a shell SOURCE line, where the
# first character after `/tmp/` is very often a quote (`/tmp/"$v"/f` — the
# spelling shellcheck pushes authors toward). The second half of this case is
# the anti-regression control: widening the class must not have swept in bare
# `/tmp` as a cwd or whole-line comment prose.
r10b1b_root="$(lint_root r10b1b)"
r10b1b_dq="$TMP_PREFIX""/\"\$v\"/f"
r10b1b_sq="$TMP_PREFIX""/'lit'"
{
	printf '%s\n' '#!/usr/bin/env bash'
	printf 'w=%s\n' "$r10b1b_dq"
	printf 'x=%s\n' "$r10b1b_sq"
} >"$r10b1b_root/tests/quoted.sh"
{
	printf '%s\n' '#!/usr/bin/env bash'
	printf '%s\n' 'cd /tmp || exit 1'
	printf '# prose naming %s\n' "$r10b1b_dq"
} >"$r10b1b_root/tests/exempt.sh"
r10b1b_res="$(run_lint "$r10b1b_root")"
r10b1b_rc="$(printf '%s' "$r10b1b_res" | head -1)"
r10b1b_out="$(printf '%s' "$r10b1b_res" | tail -n +2)"
r10b1b_exempt_hits="$(printf '%s\n' "$r10b1b_out" | grep -c 'exempt\.sh' || true)"

if [[ "$r10b1b_rc" -eq 1 &&
	"$r10b1b_out" == *"$r10b1b_dq"* &&
	"$r10b1b_out" == *"$r10b1b_sq"* &&
	"$r10b1b_exempt_hits" -eq 0 ]]; then
	pass "R10-B1b: quoted first components are refused; bare '/tmp' cwd and comment prose stay exempt"
else
	fail "R10-B1b: rc=$r10b1b_rc exempt_hits=$r10b1b_exempt_hits out='$r10b1b_out'"
fi

# --- Summary -----------------------------------------------------------------
echo
echo "test-lint-temp-paths.sh: $PASS_COUNT passed, $FAIL_COUNT failed"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
	exit 1
fi

exit 0
