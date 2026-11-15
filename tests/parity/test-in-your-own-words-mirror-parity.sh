#!/usr/bin/env bash
# in-your-own-words: the Claude and Codex gate blocks differ only on harness-tagged lines.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLAUDE_SKILL="$REPO_ROOT/plugins/skein/skills/in-your-own-words/SKILL.md"
CODEX_SKILL="$REPO_ROOT/plugins/skein-codex/skills/in-your-own-words/SKILL.md"
BEGIN='<!-- BEGIN IN-YOUR-OWN-WORDS GATE -->'
END='<!-- END IN-YOUR-OWN-WORDS GATE -->'

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

for f in "$CLAUDE_SKILL" "$CODEX_SKILL"; do
	rc=0
	[ -f "$f" ] || rc=1
	check "file exists: ${f#"$REPO_ROOT/"}" "$rc"
done
if [ "$FAIL" -ne 0 ]; then
	echo "Passed: $PASS  Failed: $FAIL"
	exit 1
fi

# gate_block <file>: the anchored block with harness-tagged lines removed.
gate_block() {
	awk -v b="$BEGIN" -v e="$END" '
		$0 == b { inside = 1; next }
		$0 == e { inside = 0; next }
		inside { print }
	' "$1" | sed '/ <!-- harness-tokens -->$/d'
}

claude_block="$(gate_block "$CLAUDE_SKILL")"
codex_block="$(gate_block "$CODEX_SKILL")"

rc=0
[ -n "$claude_block" ] || rc=1
check "Claude gate block is non-empty after normalisation" "$rc"

rc=0
[ "$claude_block" = "$codex_block" ] || rc=1
check "gate blocks are byte-identical after removing harness-tagged lines" "$rc"
if [ "$rc" -ne 0 ]; then
	diff <(echo "$claude_block") <(echo "$codex_block") >&2 || true
fi

# The harness-tagged lines carry the whole tool policy, so compare their harness-neutral
# class markers in both mirrors (tool names differ by design and are pinned per harness).
tagged_line() { # tagged_line <file> <prefix>
	grep -F ' <!-- harness-tokens -->' "$1" | grep -F -- "- $2" | head -n 1
}
forbidden_markers=(
	'file edits via'
	'notebook changes'
	'state-changing use of'
	'(commits, installs, deletes, writes, POST/PUT/DELETE)'
	'spawning subagents via'
	'and any agent dispatch'
	'sending messages to other agents or sessions via'
	'write-capable MCP tools (create, update, delete, send, publish)'
)
# shellcheck disable=SC2016 # literal backticks are the pinned text
allowed_markers=(
	'Allowed before confirmation, including when re-mirroring a correction:'
	'reading files and search'
	'read-only'
	'(`cat`, `rg`, `ls`, `git status|diff|log|show`, `gh … view`) without redirection, `rg --pre`, `--web`, `git -c`, `--ext-diff` or `--textconv`'
	'read-only fetches of supplied links with'
	'read-only MCP resource reads.'
)
for mirror in claude codex; do
	if [ "$mirror" = claude ]; then skill="$CLAUDE_SKILL"; else skill="$CODEX_SKILL"; fi
	forbidden_line="$(tagged_line "$skill" 'Forbidden:')"
	allowed_line="$(tagged_line "$skill" 'Allowed before')"
	for marker in "${forbidden_markers[@]}"; do
		rc=0
		grep -qF -- "$marker" <<<"$forbidden_line" || rc=1
		check "$mirror forbidden line carries class marker: $marker" "$rc"
	done
	for marker in "${allowed_markers[@]}"; do
		rc=0
		grep -qF -- "$marker" <<<"$allowed_line" || rc=1
		check "$mirror allowed line carries class marker: $marker" "$rc"
	done
done

name_of() { awk -F': *' '/^name:/ { print $2; exit }' "$1"; }
rc=0
[ "$(name_of "$CLAUDE_SKILL")" = "in-your-own-words" ] && [ "$(name_of "$CODEX_SKILL")" = "in-your-own-words" ] || rc=1
check "both mirrors declare name: in-your-own-words" "$rc"

rc=0
[ "$(grep -cF ' <!-- harness-tokens -->' "$CLAUDE_SKILL" || true)" -eq "$(grep -cF ' <!-- harness-tokens -->' "$CODEX_SKILL" || true)" ] || rc=1
check "both mirrors carry the same number of harness-tagged lines" "$rc"

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
