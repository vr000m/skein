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

# Each mirror's shipped format reference must equal the canonical README. The
# Codex and Pi copies land in their own phases, so only theirs may be absent.
for mirror in skein skein-codex skein-pi; do
	ref="$REPO_ROOT/plugins/$mirror/skills/update-docs/references/decision-records.md"
	if [[ ! -f "$ref" ]]; then
		[[ "$mirror" == skein ]] && fail "skein update-docs/references/decision-records.md is missing"
		continue
	fi
	if cmp -s "$REPO_ROOT/docs/decisions/README.md" "$ref"; then
		pass "$mirror update-docs/references/decision-records.md is byte-identical to docs/decisions/README.md"
	else
		fail "$mirror update-docs/references/decision-records.md differs from docs/decisions/README.md"
	fi
done

echo "---"
echo "passed: $PASS_COUNT, failed: $FAIL_COUNT"
[[ $FAIL_COUNT -eq 0 ]]
