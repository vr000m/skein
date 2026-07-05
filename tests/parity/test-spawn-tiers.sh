#!/usr/bin/env bash
# test-spawn-tiers.sh — cross-skill R2 tier census.
#
# R2 (the inheritance invariant) says every subagent spawn declares its own
# tier; no spawn inherits the session tier for mechanical work. This is a
# fresh, mandatory census — NOT an extension of the conduct-scoped mention
# guard `plugins/skein/skills/conduct/tests/test_skill_spawn_grep.sh` (that
# file only forbids stray skill-name mentions inside the conduct directory
# and cannot read the other ten skills or assert tiers).
#
# This census walks plugins/skein/skills/*/SKILL.md and asserts PINNED,
# per-file expected-tier counts, not a bare "does the string appear" check —
# a bare presence check passes on one match while three are missing. Each
# assertion here is falsifiable: removing any one `effort: high` or
# `opus/high:` why-comment from the tree makes this script exit 1.
#
# Exit codes: 0 all assertions pass, 1 any assertion fails.

set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
SKILLS_DIR="$ROOT_DIR/plugins/skein/skills"

pass_count=0
fail_count=0

pass() {
	echo "PASS: $1"
	pass_count=$((pass_count + 1))
}

fail() {
	echo "FAIL: $1"
	fail_count=$((fail_count + 1))
}

# assert_count FILE PATTERN EXPECTED LABEL
# PATTERN is an extended regex passed to `grep -oE`; count is the number of
# matched occurrences (not matching lines) across the whole file.
assert_count() {
	local file="$1" pattern="$2" expected="$3" label="$4"
	local actual
	if [[ ! -f "$file" ]]; then
		fail "$label: file missing: $file"
		return
	fi
	actual=$(grep -oE -- "$pattern" "$file" 2>/dev/null | wc -l | tr -d ' ' || true)
	if [[ "$actual" -eq "$expected" ]]; then
		pass "$label ($file): expected=$expected actual=$actual"
	else
		fail "$label ($file): expected=$expected actual=$actual"
	fi
}

# assert_count_glob PATTERN_GLOB GREP_PATTERN EXPECTED LABEL
# Sums occurrences of GREP_PATTERN across every file matching PATTERN_GLOB.
assert_count_total() {
	local glob="$1" pattern="$2" expected="$3" label="$4"
	local actual=0
	local f
	local n
	shopt -s nullglob
	for f in $glob; do
		n=$(grep -oE -- "$pattern" "$f" 2>/dev/null | wc -l | tr -d ' ' || true)
		actual=$((actual + n))
	done
	shopt -u nullglob
	if [[ "$actual" -eq "$expected" ]]; then
		pass "$label: expected=$expected actual=$actual"
	else
		fail "$label: expected=$expected actual=$actual"
	fi
}

# assert_min FILE PATTERN MIN LABEL
assert_min() {
	local file="$1" pattern="$2" min="$3" label="$4"
	local actual
	if [[ ! -f "$file" ]]; then
		fail "$label: file missing: $file"
		return
	fi
	actual=$(grep -oE -- "$pattern" "$file" 2>/dev/null | wc -l | tr -d ' ' || true)
	if [[ "$actual" -ge "$min" ]]; then
		pass "$label ($file): expected>=$min actual=$actual"
	else
		fail "$label ($file): expected>=$min actual=$actual"
	fi
}

# assert_present FILE PATTERN LABEL
assert_present() {
	local file="$1" pattern="$2" label="$3"
	if [[ ! -f "$file" ]]; then
		fail "$label: file missing: $file"
		return
	fi
	if grep -qE -- "$pattern" "$file" 2>/dev/null; then
		pass "$label ($file): present"
	else
		fail "$label ($file): NOT present"
	fi
}

# assert_absent FILE PATTERN LABEL
assert_absent() {
	local file="$1" pattern="$2" label="$3"
	if [[ ! -f "$file" ]]; then
		fail "$label: file missing: $file"
		return
	fi
	if grep -qE -- "$pattern" "$file" 2>/dev/null; then
		fail "$label ($file): unexpectedly present"
	else
		pass "$label ($file): absent as expected"
	fi
}

echo "=== R2 tier census: plugins/skein/skills/*/SKILL.md ==="
echo

# --- (1) Pinned total of opus/high why-comments across all skills ---
# review-plan 4 + deep-review 4 (logic/security/spec/architecture) +
# spec-compliance 1 + conduct 1 (reviewer) = 10
assert_count_total "$SKILLS_DIR/*/SKILL.md" 'opus/high:' 10 \
	"pinned total opus/high why-comments across plugins/skein/skills/*/SKILL.md"

# --- (2) Per-skill expected effort:high counts (both quoting styles) ---
# Trailing ([^/]|$) excludes prose like "effort: high/low" (a generic doc
# sentence describing both tiers, not a per-lens annotation) from the count.
EFFORT_HIGH_RE='effort:[[:space:]]*"?high"?([^/]|$)'
assert_count "$SKILLS_DIR/review-plan/SKILL.md" "$EFFORT_HIGH_RE" 4 \
	"review-plan effort:high count"
assert_count "$SKILLS_DIR/deep-review/SKILL.md" "$EFFORT_HIGH_RE" 4 \
	"deep-review effort:high count"
assert_count "$SKILLS_DIR/spec-compliance/SKILL.md" "$EFFORT_HIGH_RE" 1 \
	"spec-compliance effort:high count"

# --- (3) deep-review architecture lens is opus, not sonnet ---
arch_line=$(grep -nE '^#### Architecture Lens' "$SKILLS_DIR/deep-review/SKILL.md" || true)
if [[ -z "$arch_line" ]]; then
	fail "deep-review Architecture Lens header not found"
elif echo "$arch_line" | grep -q 'model: opus'; then
	pass "deep-review Architecture Lens header carries model: opus"
elif echo "$arch_line" | grep -q 'model: sonnet'; then
	fail "deep-review Architecture Lens header still carries model: sonnet (must be opus)"
else
	fail "deep-review Architecture Lens header has neither model: opus nor model: sonnet: $arch_line"
fi

# --- (4) Factual-tier lenses present: effort:low + model:haiku ---
EFFORT_LOW_RE='effort:[[:space:]]*"?low"?([^/]|$)'
MODEL_HAIKU_RE='model:[[:space:]]*"?haiku"?([^/]|$)'
assert_min "$SKILLS_DIR/review-plan/SKILL.md" "$EFFORT_LOW_RE" 1 \
	"review-plan codebase-claims effort:low present"
assert_min "$SKILLS_DIR/review-plan/SKILL.md" "$MODEL_HAIKU_RE" 1 \
	"review-plan codebase-claims model:haiku present"
assert_min "$SKILLS_DIR/deep-review/SKILL.md" "$EFFORT_LOW_RE" 1 \
	"deep-review documentation effort:low present"
assert_min "$SKILLS_DIR/deep-review/SKILL.md" "$MODEL_HAIKU_RE" 1 \
	"deep-review documentation model:haiku present"

# --- (5) fan-out.sh default flip + --effort support ---
FANOUT_SH="$SKILLS_DIR/fan-out/fan-out.sh"
assert_present "$FANOUT_SH" 'DEFAULT_MODEL="sonnet"' "fan-out.sh DEFAULT_MODEL=sonnet"
assert_absent "$FANOUT_SH" 'DEFAULT_MODEL="opus"' "fan-out.sh DEFAULT_MODEL=opus (must be gone)"
assert_present "$FANOUT_SH" 'DEFAULT_EFFORT' "fan-out.sh DEFAULT_EFFORT present"
assert_present "$FANOUT_SH" '\-\-effort' "fan-out.sh --effort flag handling present"

echo
echo "=== Summary: $pass_count passed, $fail_count failed ==="

if [[ "$fail_count" -gt 0 ]]; then
	exit 1
fi

exit 0
