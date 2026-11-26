#!/usr/bin/env bash
# Fixture test for scripts/check-decisions.sh: a good record graph passes and
# each way a graph can be broken fails with its own message (invariant I2).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
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

# record <root> <name> <status> <applies> <supersedes> <superseded_by> <plan>
record() {
	local root="$1" name="$2"
	mkdir -p "$root/docs/decisions"
	cat >"$root/docs/decisions/$name" <<EOF
# Decision $name

**Status**: $3
**Date**: 2026-11-24
**Applies to**: $4
**Supersedes**: $5
**Superseded by**: $6
**Source plan**: $7

## Decision
Keep it.
## Why
Because.
## Alternatives rejected
None.
## Consequences
None.
EOF
}

# fresh <label>: a root holding the source plan every record points at.
fresh() {
	local root="$tmp/$1"
	mkdir -p "$root/docs/dev_plans"
	: >"$root/docs/dev_plans/plan.md"
	printf '%s\n' "$root"
}

PLAN=docs/dev_plans/plan.md

# expect_ok <label> <root>
expect_ok() {
	local out rc=0
	out="$("$CHECK" "$2" 2>&1)" || rc=$?
	if [[ $rc -eq 0 && -z "$out" ]]; then
		pass "$1"
	else
		fail "$1 (exit $rc, output: $out)"
	fi
}

# expect_fail <label> <root> <message fragment>
expect_fail() {
	local out rc=0
	out="$("$CHECK" "$2" 2>&1)" || rc=$?
	if [[ $rc -eq 1 && "$out" == *"$3"* ]]; then
		pass "$1"
	else
		fail "$1 (want exit 1 naming '$3'; got exit $rc, output: $out)"
	fi
}

# Good graph: a superseded record, its active successor, and an unrelated one.
root="$(fresh good)"
record "$root" 20260101-old.md superseded 'src/*' none 20260201-new.md "$PLAN"
record "$root" 20260201-new.md active 'src/*, docs/*.md' 20260101-old.md none "$PLAN"
record "$root" 20260301-other.md active 'scripts/*' none none "$PLAN"
printf '# Decisions\n' >"$root/docs/decisions/README.md"
expect_ok "good graph passes (README.md is not parsed as a record)" "$root"
record "$root" 20260201-new.md superseded 'src/*' 20260101-old.md 20260401-latest.md "$PLAN"
record "$root" 20260401-latest.md active 'src/*' 20260201-new.md none "$PLAN"
expect_ok "a longer chain ending in an active record passes" "$root"

root="$(fresh readme-only)"
mkdir -p "$root/docs/decisions"
printf '# Decisions\n' >"$root/docs/decisions/README.md"
expect_ok "a folder holding only README.md passes" "$root"

root="$(fresh no-folder)"
expect_ok "an absent docs/decisions passes" "$root"

# Each broken case gets its own root so one fixture cannot mask another.
root="$(fresh missing-header)"
record "$root" 20260101-a.md active 'src/*' none none "$PLAN"
sed -i.bak '/^\*\*Date\*\*/d' "$root/docs/decisions/20260101-a.md"
expect_fail "missing header" "$root" "missing header Date"

root="$(fresh empty-header)"
record "$root" 20260101-a.md active '' none none "$PLAN"
expect_fail "empty header value" "$root" "missing header Applies to"

root="$(fresh bad-status)"
record "$root" 20260101-a.md draft 'src/*' none none "$PLAN"
expect_fail "invalid Status" "$root" "invalid Status 'draft'"

root="$(fresh dangling-supersedes)"
record "$root" 20260101-a.md active 'src/*' 20260909-gone.md none "$PLAN"
expect_fail "dangling Supersedes link" "$root" "Supersedes '20260909-gone.md' does not resolve"

root="$(fresh dangling-superseded-by)"
record "$root" 20260101-a.md superseded 'src/*' none 20260909-gone.md "$PLAN"
expect_fail "dangling Superseded by link" "$root" "Superseded by '20260909-gone.md' does not resolve"

root="$(fresh non-reciprocal)"
record "$root" 20260101-old.md superseded 'src/*' none none "$PLAN"
record "$root" 20260201-new.md active 'src/*' 20260101-old.md none "$PLAN"
expect_fail "non-reciprocal link" "$root" "is not reciprocal"

root="$(fresh active-superseded)"
record "$root" 20260101-old.md active 'src/*' none 20260201-new.md "$PLAN"
record "$root" 20260201-new.md active 'src/*' 20260101-old.md none "$PLAN"
expect_fail "active but superseded" "$root" "active record is superseded"

root="$(fresh dangling-plan)"
record "$root" 20260101-a.md active 'src/*' none none docs/dev_plans/nope.md
expect_fail "dangling Source plan link" "$root" "Source plan 'docs/dev_plans/nope.md' does not resolve"

root="$(fresh glob-star-star)"
record "$root" 20260101-a.md active 'src/**/x.sh' none none "$PLAN"
expect_fail "unsupported ** glob" "$root" "'**' is not supported"

root="$(fresh glob-brace)"
record "$root" 20260101-a.md active 'src/*.{sh,py}' none none "$PLAN"
expect_fail "unsupported brace glob" "$root" "braces are not supported"

# `[[ == ]]` honours extended patterns whatever `extglob` says, so each opener
# is outside the dialect.
for opener in '?' '*' '+' '@' '!'; do
	root="$(fresh "glob-ext-$(printf '%s' "$opener" | od -An -tx1 | tr -d ' ')")"
	record "$root" 20260101-a.md active "${opener}(src|lib)/x" none none "$PLAN"
	expect_fail "extended pattern ${opener}( is rejected" "$root" "extended patterns are not supported"
done
root="$(fresh glob-literal-paren)"
record "$root" 20260101-a.md active 'docs/(draft).md, src/[(]x' none none "$PLAN"
expect_ok "a parenthesis that opens no extended pattern is accepted" "$root"

# The dialect scan is the splitter's bracket scan: an operator character inside
# a bracket expression or after a backslash is a literal member, so these are
# accepted, while the same characters outside one are still rejected.
glob_scan_rows=(
	"ok|file[?(].txt"
	"ok|a[*(]b, c[+(]d, e[@(]f, g[!(]h"
	"ok|x[**]y"
	"ok|src/\\*\\(x).py"
	"ok|docs/[{]a[}].md"
	"fail|a\\[?(b|extended patterns are not supported"
	"fail|[ab]?(x)|extended patterns are not supported"
	"fail|x[*]**|'**' is not supported"
	"fail|[{]{a,b}|braces are not supported"
	"ok|lit\\[x, docs/x\\\\"
	"ok|[[:alpha:]]x, [[:upper:][:lower:]]y, [[:alpha:]-z]"
	"ok|q[\\]]r, q[a\\]r, [!]a]b, [^]a]c"
	"fail|src/*[[=a=]]|an equivalence class or collating symbol"
	"fail|x[[.a.]]|an equivalence class or collating symbol"
	"fail|x[a[=]y|an equivalence class or collating symbol"
	"fail|src/[a|an unclosed '['"
	"fail|-][:*-|an unclosed '['"
	"fail|:/[a-*b|an unclosed '['"
	"fail|[[:alpha:]|an unclosed '['"
	"fail|*\\|a trailing unpaired backslash"
	"fail|x\\\\\\|a trailing unpaired backslash"
	"fail|[[:foo:]]|is not a POSIX character class outside a range"
	"fail|[a[:b]|is not a POSIX character class outside a range"
	"fail|[a-[:digit:]]|is not a POSIX character class outside a range"
)
# Round 5: the dialect drops the shapes bash 3.2, bash 5 and the selector's
# star-splitting matcher read differently (unclosed `[`, a trailing lone
# backslash, `[=` / `[.`, a `[:` that is not a POSIX class or ends a range).
# Each row is judged by the validator under the default bash and /bin/bash.
glob_bashes=(bash)
[[ -x /bin/bash ]] && glob_bashes+=(/bin/bash)
for row in "${glob_scan_rows[@]}"; do
	verdict="${row%%|*}"
	rest="${row#*|}"
	glob="${rest%%|*}"
	root="$(fresh "glob-scan-$RANDOM")"
	record "$root" 20260101-a.md active "$glob" none none "$PLAN"
	if [[ "$verdict" == ok ]]; then
		expect_ok "bracket-aware dialect scan accepts '$glob'" "$root"
	else
		expect_fail "bracket-aware dialect scan rejects '$glob'" "$root" "${rest#*|}"
	fi
	want=0
	[[ "$verdict" == ok ]] || want=1
	for gb in "${glob_bashes[@]}"; do
		grc=0
		"$gb" "$CHECK" "$root" >/dev/null 2>&1 || grc=$?
		if [[ $grc -ne $want ]]; then
			fail "[$gb] dialect verdict for '$glob': exit $grc, want $want"
		fi
	done
done

root="$(fresh glob-empty-entry)"
record "$root" 20260101-a.md active 'src/*,,docs/*' none none "$PLAN"
expect_fail "empty entry in Applies to" "$root" "empty glob"

root="$(fresh link-escapes-folder)"
record "$root" 20260101-a.md active 'src/*' ../dev_plans/plan.md none "$PLAN"
expect_fail "a Supersedes link may not leave the folder" "$root" "does not resolve"

root="$(fresh link-to-readme)"
mkdir -p "$root/docs/decisions"
printf '# Decisions\n' >"$root/docs/decisions/README.md"
record "$root" 20260101-a.md active 'src/*' README.md none "$PLAN"
expect_fail "README.md is not a link target" "$root" "does not resolve"

root="$(fresh link-to-non-record)"
record "$root" 20260101-old.md superseded 'src/*' none successor.txt "$PLAN"
record "$root" successor.txt active 'src/*' 20260101-old.md none "$PLAN"
expect_fail "a reciprocal successor must be in the record inventory" "$root" "Superseded by 'successor.txt' does not resolve"

root="$(fresh cyclic)"
record "$root" 20260101-a.md superseded 'src/*' 20260102-b.md 20260102-b.md "$PLAN"
record "$root" 20260102-b.md superseded 'src/*' 20260101-a.md 20260101-a.md "$PLAN"
expect_fail "reciprocal links may not form a cycle" "$root" "20260101-a.md: supersession cycle"

root="$(fresh self-link)"
record "$root" 20260101-a.md superseded 'src/*' 20260101-a.md 20260101-a.md "$PLAN"
expect_fail "a record cannot supersede itself" "$root" "supersession cycle"

root="$(fresh outside-plan)"
touch "$tmp/outside-plan.md"
record "$root" 20260101-a.md active 'src/*' none none ../outside-plan.md
expect_fail "a source plan cannot traverse outside the repo" "$root" "inside the repository"
ln -s "$tmp/outside-plan.md" "$root/docs/dev_plans/outside.md"
record "$root" 20260101-a.md active 'src/*' none none docs/dev_plans/outside.md
expect_fail "a source plan symlink cannot resolve outside the repo" "$root" "inside the repository"
ln -s plan.md "$root/docs/dev_plans/local.md"
record "$root" 20260101-a.md active 'src/*' none none docs/dev_plans/local.md
expect_ok "an in-repo source plan symlink still resolves" "$root"

root="$(fresh symlink-record)"
outside="$(fresh record-target)"
record "$outside" 20260101-outside.md active 'src/*' none none "$PLAN"
mkdir -p "$root/docs/decisions"
ln -s "$outside/docs/decisions/20260101-outside.md" "$root/docs/decisions/20260101-link.md"
expect_fail "the validator rejects a symlinked record" "$root" "expected a readable, regular, non-symlink file"

# Every problem in a folder is reported in one run, not just the first.
root="$(fresh multi)"
record "$root" 20260101-a.md draft 'src/**' none none docs/dev_plans/nope.md
out="$("$CHECK" "$root" 2>&1 || true)"
count="$(grep -c '^20260101-a.md:' <<<"$out")"
if [[ "$count" -ge 3 ]]; then
	pass "all problems in a record are reported together"
else
	fail "all problems in a record are reported together (got $count lines: $out)"
fi

# --targets: the promotion write preflight. Each row is a root shape and the
# targets a promotion would write; the verdict must be 0 only when every target
# is `docs/dev_plans/<name>` or `docs/decisions/<name>` (one component matching
# the record name grammar) and each ancestor below the root is a real, in-repo
# directory. An unsafe target exits 3; a broken graph with safe targets exits 1.
# targets_case <label> <want exit> <message fragment> <root> <target>...
targets_case() {
	local label="$1" want="$2" frag="$3" root="$4" out rc=0
	shift 4
	out="$("$CHECK" "$root" --targets -- "$@" 2>&1)" || rc=$?
	if [[ $rc -eq $want && "$out" == *"$frag"* ]]; then
		pass "targets: $label"
	else
		fail "targets: $label (want exit $want naming '$frag'; got exit $rc, output: $out)"
	fi
}
SHAPE="expected docs/dev_plans/<name>.md or docs/decisions/<name>.md"
outside_dir="$tmp/targets-outside"
mkdir -p "$outside_dir/decisions"
root="$(fresh targets-first)"
targets_case "a first promotion into a real docs/ passes" 0 "" "$root" docs/decisions/README.md docs/decisions/20261125-x.md "$PLAN"
root="$(fresh targets-existing)"
record "$root" 20260101-old.md active 'src/*' none none "$PLAN"
targets_case "existing real records and plan pass" 0 "" "$root" docs/decisions/20261125-x.md docs/decisions/20260101-old.md "$PLAN"
root="$(fresh targets-linked-decisions)"
ln -s "$outside_dir/decisions" "$root/docs/decisions"
targets_case "a symlinked docs/decisions is refused" 3 "docs/decisions is a symlink" "$root" docs/decisions/20261125-x.md "$PLAN"
root="$tmp/targets-linked-docs"
mkdir -p "$root"
ln -s "$outside_dir" "$root/docs"
targets_case "a symlinked docs is refused" 3 "docs is a symlink" "$root" docs/decisions/20261125-x.md
root="$(fresh targets-linked-record)"
record "$root" 20260101-real.md active 'src/*' none none "$PLAN"
ln -s "$outside_dir/decisions/x.md" "$root/docs/decisions/20261125-x.md"
targets_case "a symlink at the new record path is refused" 3 "docs/decisions/20261125-x.md is a symlink" "$root" docs/decisions/20261125-x.md
root="$(fresh targets-linked-plan)"
ln -s plan.md "$root/docs/dev_plans/linked.md"
targets_case "a symlinked source plan is refused as a write target" 3 "docs/dev_plans/linked.md is a symlink" "$root" docs/dev_plans/linked.md
root="$(fresh targets-dotdot)"
targets_case "a '..' component is refused" 3 "may leave the repository" "$root" docs/../../escape.md
targets_case "a '..' after a missing directory is refused" 3 "may leave the repository" "$root" docs/missing/../../../escape.md
targets_case "a '..' after a missing docs/decisions is refused" 3 "may leave the repository" "$root" docs/decisions/../../../escape.md
targets_case "a trailing '..' is refused" 3 "may leave the repository" "$root" docs/missing/..
targets_case "a name that only contains dots is allowed" 0 "" "$root" docs/decisions/a..b.md
targets_case "an absolute path is refused" 3 "expected a repo-relative path" "$root" "$outside_dir/escape.md"
mkdir -p "$root/docs/decisions/sub.md"
targets_case "a directory at a record path is refused" 3 "expected a regular file" "$root" docs/decisions/sub.md
root="$(fresh targets-file-parent)"
mkdir -p "$root/docs"
: >"$root/docs/decisions"
targets_case "a file where docs/decisions should be is refused" 3 "docs/decisions is not a directory" "$root" docs/decisions/x.md
# Scope: only the two promotion directories, one name component each.
root="$(fresh targets-scope)"
mkdir -p "$root/docs/decisions"
for bad in .git/hooks/pre-commit -x.md README.md docs/decisions/-x.md docs/decisions/.x.md \
	docs/decisions/.git docs/decisions/x.txt docs/decisions/sub/x.md docs/dev_plans/sub/p.md \
	docs/other/x.md ./docs/decisions/x.md docs//decisions/x.md "docs/decisions/a b.md" \
	docs/dev_plans/.git/x.md docs/decisions/.md; do
	targets_case "a target outside the promotion scope is refused: $bad" 3 "$SHAPE" "$root" "$bad"
done
targets_case "one unsafe target fails a list of safe ones" 3 "-x.md: $SHAPE" "$root" docs/decisions/20261125-x.md -x.md "$PLAN"
root="$(fresh targets-bad-graph)"
record "$root" 20260101-a.md draft 'src/*' none none "$PLAN"
targets_case "an invalid record graph with safe targets exits 1" 1 "invalid Status" "$root" docs/decisions/20261125-x.md
targets_case "an unsafe target exits 3 even when the graph is also invalid" 3 "$SHAPE" "$root" .git/hooks/pre-commit
rc=0
"$CHECK" "$root" --targets >/dev/null 2>&1 || rc=$?
if [[ $rc -eq 2 ]]; then
	pass "--targets with no path is a usage error"
else
	fail "--targets with no path is a usage error (exit $rc)"
fi

# --targets-file: the same preflight with the targets read from a file or
# stdin, never the command line. A quoted here-document carries a hostile name
# as data: it is refused (exit 3) and nothing in it runs.
# targets_file_case <label> <want exit> <message fragment> <root> <file>
targets_file_case() {
	local label="$1" want="$2" frag="$3" root="$4" file="$5" rc=0 out
	out="$("$CHECK" "$root" --targets-file "$file" 2>&1 <"${6:-/dev/null}")" || rc=$?
	if [[ $rc -eq $want && "$out" == *"$frag"* ]]; then
		pass "targets-file: $label"
	else
		fail "targets-file: $label (want exit $want naming '$frag'; got exit $rc, output: $out)"
	fi
}
root="$(fresh targets-file)"
mkdir -p "$root/docs/decisions"
printf '%s\n' docs/decisions/20261125-x.md docs/decisions/README.md "$PLAN" >"$tmp/targets.txt"
targets_file_case "a newline-delimited file of safe targets passes" 0 "" "$root" "$tmp/targets.txt"
printf '%s\0' docs/decisions/20261125-x.md "$PLAN" >"$tmp/targets.z"
targets_file_case "a NUL-delimited file of safe targets passes" 0 "" "$root" "$tmp/targets.z"
printf '%s\n\n%s\n' docs/decisions/20261125-x.md -x.md >"$tmp/targets-bad.txt"
targets_file_case "an unsafe target in the file exits 3" 3 "-x.md: $SHAPE" "$root" "$tmp/targets-bad.txt"
: >"$tmp/targets-empty.txt"
targets_file_case "an empty targets file is a usage error" 2 "" "$root" "$tmp/targets-empty.txt"
ln -s "$tmp/targets.txt" "$tmp/targets-link.txt"
targets_file_case "a symlinked targets file is refused" 2 "cannot read" "$root" "$tmp/targets-link.txt"
targets_file_case "a missing targets file is refused" 2 "cannot read" "$root" "$tmp/no-such-file"
printf '%s\n' docs/decisions/20261125-x.md "$PLAN" >"$tmp/targets-stdin.txt"
targets_file_case "stdin (-) is read" 0 "" "$root" - "$tmp/targets-stdin.txt"
rc=0
# shellcheck disable=SC2016  # the metacharacters are the test data
out="$(
	cd "$root" && "$CHECK" --targets-file - 2>&1 <<'EOF'
docs/decisions/x$(touch pwned).md
docs/decisions/20261125-x.md
EOF
)" || rc=$?
# shellcheck disable=SC2016  # literal expected text
if [[ $rc -eq 3 && ! -e "$root/pwned" && "$out" == *'docs/decisions/x$(touch pwned).md: '"$SHAPE"* ]]; then
	pass "targets-file: a hostile name in a quoted here-document is refused as data and never runs"
else
	fail "targets-file: hostile here-document name: exit $rc, pwned $([[ -e "$root/pwned" ]] && echo yes || echo no), output $out"
fi
rc=0
"$CHECK" "$root" --targets-file >/dev/null 2>&1 || rc=$?
if [[ $rc -eq 2 ]]; then
	pass "--targets-file with no file is a usage error"
else
	fail "--targets-file with no file is a usage error (exit $rc)"
fi

# Usage errors.
rc=0
"$CHECK" --bad >/dev/null 2>&1 || rc=$?
if [[ $rc -eq 2 ]]; then
	pass "an option is a usage error (exit 2)"
else
	fail "an option is a usage error (exit $rc)"
fi

# The repo's own records, when any exist, must validate.
if "$CHECK" "$REPO_ROOT" >/dev/null 2>&1; then
	pass "this repository's docs/decisions validates"
else
	fail "this repository's docs/decisions validates"
fi

# Each mirror's shipped format reference must equal the canonical README; a
# missing copy is a failure in every mirror.
# ref_parity_problems <root>: prints one line per missing or differing copy.
ref_parity_problems() {
	local root="$1" mirror ref
	for mirror in skein skein-codex skein-pi; do
		ref="$root/plugins/$mirror/skills/update-docs/references/decision-records.md"
		if [[ ! -f "$ref" ]]; then
			printf '%s update-docs/references/decision-records.md is missing\n' "$mirror"
		elif ! cmp -s "$root/docs/decisions/README.md" "$ref"; then
			printf '%s update-docs/references/decision-records.md differs from docs/decisions/README.md\n' "$mirror"
		fi
	done
}
problems_out="$(ref_parity_problems "$REPO_ROOT")"
if [[ -z "$problems_out" ]]; then
	pass "every mirror's update-docs/references/decision-records.md is byte-identical to docs/decisions/README.md"
else
	fail "reference parity: $problems_out"
fi
# The parity check itself must fail when a Codex or Pi copy is absent.
for missing in skein-codex skein-pi; do
	scratch="$tmp/parity-$missing"
	mkdir -p "$scratch/docs/decisions"
	cp "$REPO_ROOT/docs/decisions/README.md" "$scratch/docs/decisions/README.md"
	for mirror in skein skein-codex skein-pi; do
		[[ "$mirror" == "$missing" ]] && continue
		mkdir -p "$scratch/plugins/$mirror/skills/update-docs/references"
		cp "$REPO_ROOT/docs/decisions/README.md" "$scratch/plugins/$mirror/skills/update-docs/references/decision-records.md"
	done
	if [[ "$(ref_parity_problems "$scratch")" == "$missing update-docs/references/decision-records.md is missing" ]]; then
		pass "a missing $missing reference copy fails the parity check"
	else
		fail "a missing $missing reference copy fails the parity check"
	fi
done

echo "---"
echo "passed: $PASS_COUNT, failed: $FAIL_COUNT"
[[ $FAIL_COUNT -eq 0 ]]
