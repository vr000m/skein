#!/usr/bin/env bash
# Phase 6 (review-output-formats): Codex show-me triggers and mirror contract.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CODEX_SKILL="$REPO_ROOT/plugins/skein-codex/skills/show-me/SKILL.md"
CLAUDE_SKILL="$REPO_ROOT/plugins/skein/skills/show-me/SKILL.md"
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
check() {
	if [ "$2" -eq 0 ]; then pass "$1"; else fail "$1"; fi
}

for f in "$CODEX_SKILL" "$CLAUDE_SKILL"; do
	[ -f "$f" ] || {
		echo "FAIL: missing $f" >&2
		exit 1
	}
done

for skill in "$CODEX_SKILL" "$CLAUDE_SKILL"; do
	name="${skill#"$REPO_ROOT/"}"
	nb="$(grep -cxF -- "$BEGIN" "$skill" || true)"
	ne="$(grep -cxF -- "$END" "$skill" || true)"
	rc=0
	[ "$nb" -eq 1 ] || rc=1
	check "$name: BEGIN anchor appears exactly once (got $nb)" "$rc"
	rc=0
	[ "$ne" -eq 1 ] || rc=1
	check "$name: END anchor appears exactly once (got $ne)" "$rc"
done

CODEX_BLOCK="${TMPDIR:-/tmp}/show-me-triggers-skein-codex.$$.txt"
CLAUDE_BLOCK="${TMPDIR:-/tmp}/show-me-triggers-skein.$$.txt"
trap 'rm -f "$CODEX_BLOCK" "$CLAUDE_BLOCK"' EXIT

# Extract each block explicitly for readable trigger assertions and comparison.
for pair in "codex:$CODEX_SKILL:$CODEX_BLOCK" "claude:$CLAUDE_SKILL:$CLAUDE_BLOCK"; do
	IFS=: read -r _ skill output <<<"$pair"
	awk -v b="$BEGIN" -v e="$END" '$0 == b { inside = 1; next } $0 == e { inside = 0; next } inside { print }' "$skill" >"$output"
done

CODEX_BLOCK_TEXT="$(<"$CODEX_BLOCK")"
in_block() { # in_block <description> <ERE>
	local rc=0
	printf '%s\n' "$CODEX_BLOCK_TEXT" | grep -qiE -- "$2" || rc=$?
	check "Codex anchored block: $1" "$rc"
}

in_block "review findings trigger" 'review finding'
in_block "gauntlet convergence trigger" 'gauntlet.*convergence|convergence.*gauntlet'
in_block "conduct phase progress trigger" 'conduct.*phase progress|phase progress.*conduct'
in_block "review findings names review-gauntlet and --report" 'review-gauntlet.*--report|--report.*review-gauntlet'
in_block "review findings names deep-review and --report" 'deep-review.*--report|--report.*deep-review'
in_block "convergence points to review-gauntlet --report" 'convergence.*--report.*review-gauntlet|review-gauntlet.*convergence.*--report'
in_block "conduct progress uses Mermaid" 'mermaid'
in_block "conduct progress uses a table" 'table'
in_block "conduct progress says no report flag is needed" 'no report flag is needed'

rc=0
grep -qF 'plan-view' "$CODEX_SKILL" || rc=$?
check "Codex plan-view deferral remains present" "$rc"

rc=0
grep -qF 'Mermaid' "$CODEX_SKILL" && grep -qF 'HTML artifacts' "$CODEX_SKILL" || rc=1
check "Codex Mermaid and HTML guidance remains present" "$rc"

rc=0
cmp -s "$CODEX_BLOCK" "$CLAUDE_BLOCK" || rc=$?
check "anchored trigger bullets are byte-identical to Claude" "$rc"

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
