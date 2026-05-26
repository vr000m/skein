#!/usr/bin/env bash
# Guards the no-silent-degradation contract for --auto-fix across SKILL.md
# mirrors:
#   1. Anchored mirrors invoke the bundled applier via their harness-native
#      skill-dir variable under scripts/
#      and carry the hard-fail-on-missing-bundle sentence.
#   2. No mirror authorizes a manual/direct apply fallback.
#   3. A skill install without a bundled scripts/ subtree leaves nothing to run
#      at the anchored path (the runtime hard-fail the prose mandates).
#
# Claude mirrors (plugins/skein/skills/) anchor on ${CLAUDE_PLUGIN_ROOT}/skills/<skill>/scripts/
# because the Claude Code plugin runtime exports CLAUDE_PLUGIN_ROOT at load.
# Codex mirrors (plugins/skein-codex/skills/) anchor on "$CODEX_SKILL_DIR"/scripts/
# because Codex does not currently expose a loaded-skill path in the shell
# environment and CODEX_HOME was not present in the verified Codex Desktop env probe.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# entry: <mirror-dir>|<skill>|<applier-basename>|<anchor-form>
# anchor-form is the literal prefix-up-to-/scripts/ that grep matches in SKILL.md.
ANCHORED=(
	"plugins/skein|deep-review|apply-auto-fix-code.sh|\${CLAUDE_PLUGIN_ROOT}/skills/deep-review"
	"plugins/skein|review-plan|apply-auto-fix-plan.sh|\${CLAUDE_PLUGIN_ROOT}/skills/review-plan"
	"plugins/skein-codex|deep-review|apply-auto-fix-code.sh|\"\$CODEX_SKILL_DIR\""
	"plugins/skein-codex|review-plan|apply-auto-fix-plan.sh|\"\$CODEX_SKILL_DIR\""
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
for entry in "${ANCHORED[@]}"; do
	IFS='|' read -r mirror skill _ <<<"$entry"
	file="$(skill_md "$mirror" "$skill")"
	[[ -f "$file" ]] || {
		fail "no-fallback ($mirror/$skill: missing SKILL.md)"
		continue
	}
	# Lines that look like they authorize a manual/direct apply. The ONLY
	# permitted match is the sanctioned hard-fail sentence itself; any other
	# match is a fallback authorization.
	bad="$(grep -inE '(apply|applied|applying|hand-apply|hand apply)[^.]*(directly|by hand|by-hand|manually|yourself|without the bundled)' "$file" | grep -vF "$HARD_FAIL_SENTENCE" || true)"
	if [[ -n "$bad" ]]; then
		fail "no-fallback ($mirror/$skill authorizes a manual/direct apply)"
		printf '%s\n' "$bad" | sed 's/^/    /'
	else
		pass "no-fallback ($mirror/$skill)"
	fi
done

# --- Rule 1: anchored mirrors invoke the bundled applier + hard-fail prose ---
for entry in "${ANCHORED[@]}"; do
	IFS='|' read -r mirror skill applier anchor_form <<<"$entry"
	file="$(skill_md "$mirror" "$skill")"
	[[ -f "$file" ]] || {
		fail "anchored ($mirror/$skill: missing SKILL.md)"
		continue
	}
	if grep -qF "$anchor_form/scripts/$applier" "$file"; then
		pass "anchored invocation ($mirror/$skill -> $anchor_form/scripts/$applier)"
	else
		fail "anchored invocation ($mirror/$skill missing $anchor_form/scripts/$applier)"
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
SKILL_DIR_SIM="$empty_install/deep-review"
mkdir -p "$SKILL_DIR_SIM"
: >"$SKILL_DIR_SIM/SKILL.md"
# Drive the actual anchored invocation form against an install with no bundled
# scripts/ subtree. The anchored path must fail (nothing to run) — that failure
# is what forces the SKILL.md hard-fail rather than a silent fallback. A pass
# here would mean the anchored command resolved to something runnable anyway.
if bash "$SKILL_DIR_SIM/scripts/apply-auto-fix-code.sh" --test-cmd true </dev/null >/dev/null 2>&1; then
	fail "missing-bundle (anchored applier ran despite absent bundled scripts/)"
else
	pass "missing-bundle (anchored applier path fails when bundled scripts/ absent)"
fi

echo ""
echo "Summary: $pass_count passed, $fail_count failed"
[[ "$fail_count" -eq 0 ]]
