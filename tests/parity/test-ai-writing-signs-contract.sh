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

# 1b. The reference keeps the rules that stop false positives and carries its
# source attribution (identical in every location, so the canonical suffices).
for token in 'Required structure is exempt' 'Do not flag quoted examples' \
	'Fewer than 3 distinct sign types' 'CC BY-SA 4.0' 'Signs_of_AI_writing'; do
	if grep -q -- "$token" "$CANON/ai-writing-signs.md"; then
		pass "reference carries '$token'"
	else
		fail "reference missing '$token'"
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
	# Capture the rule lines first: a missing rule must fail the check rather
	# than pass vacuously, and a pipe under pipefail can mask a match (SIGPIPE).
	splice_lines="$(grep -i 'comma splice' "$f" || true)"
	if [ -z "$splice_lines" ]; then
		fail "comma-splice rule not found (renamed?): $rel"
	elif grep -qi 'em dash\|—' <<<"$splice_lines"; then
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

# 5. content-review SKILL.md carries the severity mapping and the fix rule.
for m in skein skein-codex skein-pi; do
	f="$P/$m/skills/content-review/SKILL.md"
	rel="${f#"$REPO_ROOT"/}"
	for token in 'assistant residue' '3 or more distinct' 'needs author input' 'ai-writing-signs'; do
		if grep -q -- "$token" "$f"; then
			pass "'$token' present: $rel"
		else
			fail "'$token' missing: $rel"
		fi
	done
done

# 6. content-draft (Claude, Codex) uses the reference and the new Phase 4.
for m in skein skein-codex; do
	f="$P/$m/skills/content-draft/SKILL.md"
	rel="${f#"$REPO_ROOT"/}"
	for token in 'Write it right' 'ai-writing-signs.md' 'needs author input'; do
		if grep -q -- "$token" "$f"; then
			pass "'$token' present: $rel"
		else
			fail "'$token' missing: $rel"
		fi
	done
	if grep -q 'ever-evolving' "$f"; then
		fail "old phrase-ban list still present: $rel"
	else
		pass "phrase-ban list removed: $rel"
	fi
	# Both mirrors must rename the phase headings and keep the marker exception
	# beside the "no assistant residue" rule, or the worker strips the marker.
	if grep -q 'De-LLM' "$f"; then
		fail "stale De-LLM heading: $rel"
	else
		pass "no stale De-LLM heading: $rel"
	fi
	if grep -q 'keep it visible; never strip it' "$f"; then
		pass "marker exception beside the residue rule: $rel"
	else
		fail "residue rule lacks the needs-author-input marker exception: $rel"
	fi
done

# 7. update-docs and release carry the plain-writing pointer (Claude, Codex).
for m in skein skein-codex; do
	for s in update-docs release; do
		f="$P/$m/skills/$s/SKILL.md"
		rel="${f#"$REPO_ROOT"/}"
		if grep -q 'content-review/references/ai-writing-signs.md' "$f"; then
			pass "pointer present: $rel"
		else
			fail "pointer missing: $rel"
		fi
	done
	# update-docs must read the reference before the first edit step.
	f="$P/$m/skills/update-docs/SKILL.md"
	rel="${f#"$REPO_ROOT"/}"
	pointer_line="$(grep -n 'content-review/references/ai-writing-signs.md' "$f" | head -n 1 | cut -d: -f1 || true)"
	edit_line="$(grep -n '^[0-9]*\. Edit each document' "$f" | head -n 1 | cut -d: -f1 || true)"
	if [ -n "$pointer_line" ] && [ -n "$edit_line" ] && [ "$pointer_line" -lt "$edit_line" ]; then
		pass "reference is read before the first edit step: $rel"
	else
		fail "reference pointer (line ${pointer_line:-none}) does not precede the edit step (line ${edit_line:-none}): $rel"
	fi
done

# 8. The Pi extension loads the reference into both worker prompts.
if [ "$(grep -c 'readFileSync(join(refs, "ai-writing-signs.md")' "$P/skein-pi/extension.ts")" -ge 2 ]; then
	pass "Pi extension loads ai-writing-signs.md in draft and review prompts"
else
	fail "Pi extension does not load ai-writing-signs.md in both prompts"
fi

# 9. Transition words are supporting evidence, never standalone findings.
if grep -q 'Supporting evidence only: never report it in isolation' "$CANON/ai-writing-signs.md" &&
	grep -q 'transition words alone are exempt' "$CANON/ai-writing-signs.md"; then
	pass "transition words are exempt from standalone findings"
else
	fail "transition-word standalone-finding exemption missing"
fi
for m in skein skein-codex skein-pi; do
	f="$P/$m/skills/content-review/SKILL.md"
	rel="${f#"$REPO_ROOT"/}"
	if grep -qi 'transition words on their own are exempt; do not report them' "$f"; then
		pass "transition-word exemption present: $rel"
	else
		fail "transition-word exemption missing: $rel"
	fi
done

# 10. Delegated workers receive inline rule text loaded through harness anchors.
codex_draft="$P/skein-codex/skills/content-draft/SKILL.md"
codex_review="$P/skein-codex/skills/content-review/SKILL.md"
claude_draft="$P/skein/skills/content-draft/SKILL.md"
claude_review="$P/skein/skills/content-review/SKILL.md"
for spec in \
	"$codex_draft|\"\$SKILL_DIR\"/../content-review/references/ai-writing-signs.md|{{AI_WRITING_SIGNS_REFERENCE}}" \
	"$codex_review|\"\$SKILL_DIR\"/references/ai-writing-signs.md|{{AI_WRITING_SIGNS_REFERENCE}}" \
	"$claude_draft|\${CLAUDE_PLUGIN_ROOT}/skills/content-review/references/ai-writing-signs.md|{{AI_WRITING_SIGNS_REFERENCE}}" \
	"$claude_review|\${CLAUDE_PLUGIN_ROOT}/skills/content-review/references/ai-writing-signs.md|{{AI_WRITING_SIGNS_REFERENCE}}"; do
	IFS='|' read -r f anchor placeholder <<<"$spec"
	rel="${f#"$REPO_ROOT"/}"
	if grep -Fq -- "$anchor" "$f" && grep -Fq -- "$placeholder" "$f"; then
		pass "anchored inline worker reference: $rel"
	else
		fail "worker reference is not anchored and inlined: $rel"
	fi
done

# 11. Non-delegated cross-skill pointers also use the harness anchor.
for spec in \
	"$P/skein-codex/skills/update-docs/SKILL.md|\"\$SKILL_DIR\"/../content-review/references/ai-writing-signs.md" \
	"$P/skein-codex/skills/release/SKILL.md|\"\$SKILL_DIR\"/../content-review/references/ai-writing-signs.md" \
	"$P/skein/skills/update-docs/SKILL.md|\${CLAUDE_PLUGIN_ROOT}/skills/content-review/references/ai-writing-signs.md" \
	"$P/skein/skills/release/SKILL.md|\${CLAUDE_PLUGIN_ROOT}/skills/content-review/references/ai-writing-signs.md"; do
	IFS='|' read -r f anchor <<<"$spec"
	rel="${f#"$REPO_ROOT"/}"
	if grep -Fq -- "$anchor" "$f"; then
		pass "anchored cross-skill reference: $rel"
	else
		fail "bare cross-skill reference remains: $rel"
	fi
done

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
