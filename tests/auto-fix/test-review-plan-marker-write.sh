#!/usr/bin/env bash
# Phase 2 contract test: review-plan Step 7 writes its marker via the bundled
# deterministic entrypoint (write-review-marker.py), never by hand-computing the
# hash in prose-following Python.
#
# Asserts:
#   (a) Negative assertion — the skein review-plan SKILL.md references the
#       bundled entrypoint AND the old hand-compute imperative is GONE.
#       (precedent: tests/parity/test-no-manual-apply-fallback.sh)
#   (b) Abort contract —
#         - no-divider plan: entrypoint aborts non-zero, file byte-unchanged.
#         - absent entrypoint: SKILL.md prose mandates abort-if-absent
#           (prose contract — the LLM, not this script, would abort).
#   (c) Placeholder happy path — template placeholder is consumed in place and
#       a real 40-hex marker is written; stdout is the recorded sha.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

SKILL_MD="$REPO_ROOT/plugins/skein/skills/review-plan/SKILL.md"
CODEX_SKILL_MD="$REPO_ROOT/plugins/skein-codex/skills/review-plan/SKILL.md"
ENTRYPOINT="$REPO_ROOT/plugins/skein/skills/review-plan/scripts/write-review-marker.py"

pass_count=0
fail_count=0
pass() {
	echo "PASS: $*"
	pass_count=$((pass_count + 1))
}
fail() {
	echo "FAIL: $*" >&2
	fail_count=$((fail_count + 1))
}

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# --- Preflight: the bundled entrypoint must exist (Phase 1 deliverable) ------
if [[ -f "$ENTRYPOINT" ]]; then
	pass "preflight: bundled entrypoint present at scripts/write-review-marker.py"
else
	fail "preflight: bundled entrypoint missing at $ENTRYPOINT"
fi
if [[ ! -f "$SKILL_MD" ]]; then
	fail "preflight: review-plan SKILL.md missing at $SKILL_MD"
fi

# ============================================================================
# (a) Negative assertion — no hand-compute recipe; bundled entrypoint referenced
# ============================================================================
if [[ -f "$SKILL_MD" ]]; then
	# Positive: SKILL.md now points at the bundled entrypoint.
	if grep -q 'write-review-marker.py' "$SKILL_MD"; then
		pass "skill references bundled entrypoint (write-review-marker.py)"
	else
		fail "skill does not reference write-review-marker.py"
	fi

	# Negative: the old hand-compute imperative is GONE. The retired prose told
	# the agent to "Compute \`git hash-object --stdin\` of \`above_marker\`".
	# Regex is tolerant of the surrounding backtick chars. This grep MUST fail.
	if grep -Eq 'Compute .git hash-object --stdin. of .above_marker.' "$SKILL_MD"; then
		fail "hand-compute recipe still present in SKILL.md (must be removed)"
	else
		pass "hand-compute recipe removed from SKILL.md (negative assertion holds)"
	fi
fi

# --- Codex mirror: same negative assertion, with the $SKILL_DIR anchor -------
if [[ -f "$CODEX_SKILL_MD" ]]; then
	if grep -q 'write-review-marker.py' "$CODEX_SKILL_MD"; then
		pass "codex mirror references bundled entrypoint (write-review-marker.py)"
	else
		fail "codex mirror does not reference write-review-marker.py"
	fi
	# Codex must use the $SKILL_DIR anchor, never the Claude ${CLAUDE_PLUGIN_ROOT}.
	if grep -Eq '"\$SKILL_DIR"/scripts/write-review-marker.py' "$CODEX_SKILL_MD"; then
		pass "codex mirror invokes entrypoint via \$SKILL_DIR anchor"
	else
		fail "codex mirror missing \$SKILL_DIR-anchored write-review-marker.py invocation"
	fi
	if grep -q 'CLAUDE_PLUGIN_ROOT' "$CODEX_SKILL_MD"; then
		fail "codex mirror leaks \${CLAUDE_PLUGIN_ROOT} (Claude anchor must not appear)"
	else
		pass "codex mirror has no \${CLAUDE_PLUGIN_ROOT} leak"
	fi
	if grep -Eq 'Compute .git hash-object --stdin. of .above_marker.' "$CODEX_SKILL_MD"; then
		fail "hand-compute recipe still present in codex SKILL.md (must be removed)"
	else
		pass "hand-compute recipe removed from codex SKILL.md (negative assertion holds)"
	fi
else
	fail "codex mirror SKILL.md missing at $CODEX_SKILL_MD"
fi

# ============================================================================
# (b) Abort contract
# ============================================================================

# --- no-divider abort: no marker, no placeholder -> non-zero, byte-unchanged --
nodivider="$scratch/no-divider.md"
printf '# Plan\n\nSome contract text.\n\n## Progress\n\n- [ ] Phase 1\n' >"$nodivider"
before_hash="$(git hash-object "$nodivider")"
set +e
out="$(python3 "$ENTRYPOINT" "$nodivider" 2>&1)"
rc=$?
set -e
after_hash="$(git hash-object "$nodivider")"
if [[ $rc -ne 0 ]]; then
	pass "no-divider abort: entrypoint exits non-zero (rc=$rc)"
else
	fail "no-divider abort: entrypoint exited 0, expected non-zero (out: $out)"
fi
if [[ "$before_hash" == "$after_hash" ]]; then
	pass "no-divider abort: plan file byte-unchanged (no marker written)"
else
	fail "no-divider abort: plan file mutated despite abort"
fi

# --- absent-entrypoint abort: prose contract in SKILL.md ---------------------
# The LLM is instructed to abort if the bundled script is absent. This is a
# prose contract, not a runtime behaviour of this test — assert the wording.
if [[ -f "$SKILL_MD" ]]; then
	if grep -Eq 'absent.*abort|abort.*absent' "$SKILL_MD" ||
		grep -qiF 'never fall back' "$SKILL_MD" ||
		grep -qiF 'never hand-compute' "$SKILL_MD"; then
		pass "absent-entrypoint abort: SKILL.md carries abort-if-absent prose contract"
	else
		fail "absent-entrypoint abort: SKILL.md missing abort-if-absent wording"
	fi
fi

# ============================================================================
# (c) Placeholder happy path
# ============================================================================
placeholder="$scratch/placeholder.md"
{
	printf '# Plan\n\n'
	printf 'Immutable contract text above the divider.\n\n'
	printf '<!-- reviewed: YYYY-MM-DD @ <hash> -->\n\n'
	printf '## Progress\n\n- [ ] Phase 1\n'
} >"$placeholder"

set +e
sha_out="$(python3 "$ENTRYPOINT" "$placeholder" 2>&1)"
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
	pass "placeholder happy path: entrypoint exits 0"
else
	fail "placeholder happy path: entrypoint exited $rc (out: $sha_out)"
fi

# stdout is a 40-hex sha
if [[ "$sha_out" =~ ^[0-9a-f]{40}$ ]]; then
	pass "placeholder happy path: stdout is a 40-hex sha"
else
	fail "placeholder happy path: stdout not a 40-hex sha (got: $sha_out)"
fi

# the template placeholder line must be consumed (no surviving placeholder)
if grep -Eq '^<!-- reviewed: YYYY-MM-DD @ <hash> -->[[:space:]]*$' "$placeholder"; then
	fail "placeholder happy path: template placeholder line survived the write"
else
	pass "placeholder happy path: no placeholder line survives (consumed in place)"
fi

# a real marker now exists
if grep -Eq '^<!-- reviewed: [0-9]{4}-[0-9]{2}-[0-9]{2} @ [0-9a-f]{40} -->' "$placeholder"; then
	pass "placeholder happy path: real review marker written"
else
	fail "placeholder happy path: no real review marker found after write"
fi

echo ""
echo "Summary: $pass_count passed, $fail_count failed"
[[ "$fail_count" -eq 0 ]]
