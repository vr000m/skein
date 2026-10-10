#!/usr/bin/env bash
# Phase 3 (review-output-formats): Claude show-me triggers.
# Asserts the anchored trigger bullets in the Claude show-me SKILL.md (three
# triggers, --report pointers, conduct-progress mermaid/table rule), the
# preserved plan-view deferral, no report file path, and the BACKLOG Pi entry.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKILL="$REPO_ROOT/plugins/skein/skills/show-me/SKILL.md"
BACKLOG="$REPO_ROOT/docs/BACKLOG.md"
BEGIN='<!-- BEGIN SHOW-ME REVIEW TRIGGERS -->'
END='<!-- END SHOW-ME REVIEW TRIGGERS -->'

PASS=0
FAIL=0
pass() {
	PASS=$((PASS + 1))
	echo "PASS: $*"
}
fail() {
	FAIL=$((FAIL + 1))
	echo "FAIL: $*" >&2
}
check() { # check <desc> <status>
	if [ "$2" -eq 0 ]; then pass "$1"; else fail "$1"; fi
}

for f in "$SKILL" "$BACKLOG"; do
	[ -f "$f" ] || {
		echo "FAIL: missing $f" >&2
		exit 1
	}
done

nb="$(grep -cxF -- "$BEGIN" "$SKILL" || true)"
ne="$(grep -cxF -- "$END" "$SKILL" || true)"
rc=0
[ "$nb" -eq 1 ] || rc=1
check "BEGIN anchor appears exactly once (got $nb)" "$rc"
rc=0
[ "$ne" -eq 1 ] || rc=1
check "END anchor appears exactly once (got $ne)" "$rc"

# Extract the anchored region (exclusive of anchor lines).
BLOCK="$(awk -v b="$BEGIN" -v e="$END" '
	$0 == e { inb = 0 }
	inb { print }
	$0 == b { inb = 1 }
' "$SKILL")"

rc=0
[ -n "$BLOCK" ] || rc=1
check "anchored region is non-empty" "$rc"

rc=0
awk -v b="$BEGIN" -v e="$END" '
	$0 == b { bl = NR } $0 == e { el = NR }
	END { exit !(bl > 0 && el > bl) }
' "$SKILL" || rc=$?
check "BEGIN precedes END" "$rc"

in_block() { # in_block <desc> <ERE>
	local rc=0
	printf '%s\n' "$BLOCK" | grep -qiE -- "$2" || rc=$?
	check "anchored block: $1" "$rc"
}

in_block "review findings trigger" 'review finding'
in_block "gauntlet convergence trigger" 'gauntlet.*convergence|convergence.*gauntlet'
in_block "conduct phase progress trigger" 'conduct.*phase progress|phase progress.*conduct'
in_block "literal --report flag" '\-\-report'
in_block "names review-gauntlet" 'review-gauntlet'
in_block "names deep-review" 'deep-review'
in_block "conduct progress mentions mermaid" 'mermaid'
in_block "conduct progress mentions table" 'table'

# Around the block: plan-view deferral preserved, no report file path given.
rc=0
grep -qF 'plan-view' "$SKILL" || rc=$?
check "plan-view deferral note still present" "$rc"

rc=0
grep -qF '.gauntlet/' "$SKILL" && rc=1
check "no .gauntlet/ path given for reports" "$rc"

# BACKLOG: loose Pi follow-up for the report/show-me work.
rc=0
grep -iE '(^|[^[:alnum:]])pi([^[:alnum:]]|$)' "$BACKLOG" | grep -qiE 'report|show-me' || rc=$?
check "BACKLOG mentions a Pi follow-up for report/show-me" "$rc"

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
