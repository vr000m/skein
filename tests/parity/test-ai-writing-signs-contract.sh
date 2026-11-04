#!/usr/bin/env bash
# AI-writing-signs contract: the shared reference is byte-identical in every
# location that ships it, every content-guidelines.md copy keeps the pinned
# Anti-LLM heading and points at the reference, and no mirror recommends an
# em dash as a comma-splice fix.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
P="$REPO_ROOT/plugins"
CANON="$P/skein-codex/skills/content-review/references"

SIGNS=(
	"$CANON/ai-writing-signs.md"
	"$P/skein/skills/content-review/references/ai-writing-signs.md"
	"$P/skein-pi/skills/content-review/references/ai-writing-signs.md"
	"$P/skein-pi/skills/content-draft/references/ai-writing-signs.md"
)
GUIDELINES=(
	"$CANON/content-guidelines.md"
	"$P/skein/skills/content-review/references/content-guidelines.md"
	"$P/skein-pi/skills/content-review/references/content-guidelines.md"
	"$P/skein-pi/skills/content-draft/references/content-guidelines.md"
)
STYLE_RULES=(
	"$CANON/writing-style-rules.md"
	"$P/skein/skills/content-review/references/writing-style-rules.md"
	"$P/skein-pi/skills/content-review/references/writing-style-rules.md"
)

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

# 1. ai-writing-signs.md exists and is byte-identical to the Codex canonical.
for f in "${SIGNS[@]}"; do
	rel="${f#"$REPO_ROOT"/}"
	if [ ! -f "$f" ]; then
		fail "missing $rel"
	elif cmp -s "$CANON/ai-writing-signs.md" "$f"; then
		pass "byte-identical: $rel"
	else
		fail "differs from Codex canonical: $rel"
	fi
done

# 2. content-guidelines.md keeps the pinned heading and points at the reference.
for f in "${GUIDELINES[@]}"; do
	rel="${f#"$REPO_ROOT"/}"
	if grep -q '^### Anti-LLM Authenticity Rules$' "$f"; then
		pass "heading kept: $rel"
	else
		fail "Anti-LLM heading missing: $rel"
	fi
	if grep -q 'ai-writing-signs\.md' "$f"; then
		pass "pointer present: $rel"
	else
		fail "no pointer to ai-writing-signs.md: $rel"
	fi
done

# 3. No comma-splice line offers an em dash as a fix.
for f in "${GUIDELINES[@]}" "${STYLE_RULES[@]}"; do
	rel="${f#"$REPO_ROOT"/}"
	if grep -i 'comma splice' "$f" | grep -qi 'em dash\|—'; then
		fail "comma-splice rule still offers an em dash: $rel"
	else
		pass "no em-dash splice fix: $rel"
	fi
done

# 4. The old fixed phrase-ban list is gone from the guidelines.
for f in "${GUIDELINES[@]}"; do
	rel="${f#"$REPO_ROOT"/}"
	if grep -q 'ever-evolving' "$f"; then
		fail "old phrase-ban list still present: $rel"
	else
		pass "phrase-ban list removed: $rel"
	fi
done

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
