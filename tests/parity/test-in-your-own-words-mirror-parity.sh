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
