#!/usr/bin/env bash
# Guards the no-silent-degradation contract for --auto-fix across SKILL.md
# mirrors:
#   1. Anchored mirrors invoke the bundled applier via "$SKILL_DIR"/scripts/
#      and carry the hard-fail-on-missing-bundle sentence.
#   2. No mirror authorizes a manual/direct apply fallback.
#   3. A skill install without a bundled scripts/ subtree leaves nothing to run
#      at the anchored path (the runtime hard-fail the prose mandates).
#
# .codex mirrors are anchored Codex-side (Phase 0 decision + .codex SKILL.md
# prose). Until then they live in PENDING and are checked only for rule 2.
# When Codex anchors them, move the two .codex entries from PENDING to ANCHORED.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# entry: <mirror-dir>|<skill>|<applier-basename>
ANCHORED=(
	".claude|deep-review|apply-auto-fix-code.sh"
	".claude|review-plan|apply-auto-fix-plan.sh"
)
PENDING=(
	".codex|deep-review|apply-auto-fix-code.sh"
	".codex|review-plan|apply-auto-fix-plan.sh"
)

HARD_FAIL_SENTENCE='never fall back to applying fixes by hand'

pass_count=0
fail_count=0
fail() {
	echo "FAIL: $1"
	fail_count=$((fail_count + 1))
}
pass() {
	echo "PASS: $1"
	pass_count=$((pass_count + 1))
}

skill_md() { printf '%s/%s/skills/%s/SKILL.md' "$ROOT_DIR" "$1" "$2"; }

# --- Rule 2: no manual/direct-apply fallback phrasing in ANY mirror ----------
# Match "apply/applied/applying ... directly|by hand|manually|without" but
# exclude the hard-fail sentence, which legitimately says "never ... by hand".
for entry in "${ANCHORED[@]}" "${PENDING[@]}"; do
	IFS='|' read -r mirror skill _ <<<"$entry"
	file="$(skill_md "$mirror" "$skill")"
	[[ -f "$file" ]] || {
		fail "no-fallback ($mirror/$skill: missing SKILL.md)"
		continue
	}
	if grep -inE '(apply|applied|applying)[^.]*(directly|by hand|by-hand|manually|without the)' "$file" | grep -iv 'never' | grep -q .; then
		fail "no-fallback ($mirror/$skill authorizes a manual/direct apply)"
		grep -inE '(apply|applied|applying)[^.]*(directly|by hand|by-hand|manually|without the)' "$file" | grep -iv 'never' | sed 's/^/    /'
	else
		pass "no-fallback ($mirror/$skill)"
	fi
done

# --- Rule 1: anchored mirrors invoke the bundled applier + hard-fail prose ---
for entry in "${ANCHORED[@]}"; do
	IFS='|' read -r mirror skill applier <<<"$entry"
	file="$(skill_md "$mirror" "$skill")"
	[[ -f "$file" ]] || {
		fail "anchored ($mirror/$skill: missing SKILL.md)"
		continue
	}
	if grep -qF "\"\$SKILL_DIR\"/scripts/$applier" "$file"; then
		pass "anchored invocation ($mirror/$skill -> \$SKILL_DIR/scripts/$applier)"
	else
		fail "anchored invocation ($mirror/$skill missing \$SKILL_DIR/scripts/$applier)"
	fi
	if grep -qF "$HARD_FAIL_SENTENCE" "$file"; then
		pass "hard-fail sentence ($mirror/$skill)"
	else
		fail "hard-fail sentence ($mirror/$skill missing: $HARD_FAIL_SENTENCE)"
	fi
done

# --- Rule 3: an install without bundled scripts/ has nothing to run ----------
empty_install="$(mktemp -d)"
trap 'rm -rf "$empty_install"' EXIT
mkdir -p "$empty_install/deep-review"
: >"$empty_install/deep-review/SKILL.md"
if [[ ! -x "$empty_install/deep-review/scripts/apply-auto-fix-code.sh" ]]; then
	pass "missing-bundle (no bundled applier to run -> anchored path fails)"
else
	fail "missing-bundle (unexpected applier present in bundle-less install)"
fi

echo ""
echo "Summary: $pass_count passed, $fail_count failed"
[[ "$fail_count" -eq 0 ]]
