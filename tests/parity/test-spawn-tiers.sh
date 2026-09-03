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
# This census walks plugins/skein/skills/*/SKILL.md and
# plugins/skein-codex/skills/*/SKILL.md, then asserts PINNED per-file
# expected-tier counts, not a bare "does the string appear" check —
# a bare presence check passes on one match while three are missing. Each
# assertion here is falsifiable: removing any one `effort: high` or
# `opus/high:` why-comment from the tree makes this script exit 1.
#
# Exit codes: 0 all assertions pass, 1 any assertion fails.

set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
SKILLS_DIR="$ROOT_DIR/plugins/skein/skills"
CODEX_SKILLS_DIR="$ROOT_DIR/plugins/skein-codex/skills"

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

# assert_present_flat FILE PATTERN LABEL
# Flattens the file (newlines -> spaces) before matching, so PATTERN may span
# what were originally multiple lines. Needed for co-location/wrapper
# predicates that a per-line grep cannot express.
#
# Uses perl, not `tr | grep -E`, deliberately: these patterns use bounded
# intervals up to {0,400} (see the "testable definitions" co-location rule),
# and stock BSD/macOS grep (grep (BSD grep, GNU compatible) 2.6.0-FreeBSD)
# caps ERE interval repetition at 255 — `{0,400}` fails there with
# "maximum repetition exceeds 255" and grep -q silently reports no-match.
# perl's regex engine has no such cap and is present on both macOS and Linux.
assert_present_flat() {
	local file="$1" pattern="$2" label="$3"
	if [[ ! -f "$file" ]]; then
		fail "$label: file missing: $file"
		return
	fi
	if perl -0777 -e '
		my ($file, $pat) = @ARGV;
		open(my $fh, "<", $file) or exit 1;
		local $/;
		my $content = <$fh>;
		$content =~ tr/\n/ /;
		exit($content =~ /$pat/ ? 0 : 1);
	' "$file" "$pattern" 2>/dev/null; then
		pass "$label ($file): present (flattened)"
	else
		fail "$label ($file): NOT present (flattened)"
	fi
}

# assert_order FILE PATTERN_A PATTERN_B LABEL
# Asserts the first `grep -n` match line for PATTERN_A is strictly less than
# the first match line for PATTERN_B. Fails if either pattern is absent.
assert_order() {
	local file="$1" pattern_a="$2" pattern_b="$3" label="$4"
	local line_a line_b
	if [[ ! -f "$file" ]]; then
		fail "$label: file missing: $file"
		return
	fi
	line_a=$(grep -nE -- "$pattern_a" "$file" 2>/dev/null | head -1 | cut -d: -f1 || true)
	line_b=$(grep -nE -- "$pattern_b" "$file" 2>/dev/null | head -1 | cut -d: -f1 || true)
	if [[ -z "$line_a" ]]; then
		fail "$label ($file): pattern A not present"
		return
	fi
	if [[ -z "$line_b" ]]; then
		fail "$label ($file): pattern B not present"
		return
	fi
	if [[ "$line_a" -lt "$line_b" ]]; then
		pass "$label ($file): A precedes B ($line_a < $line_b)"
	else
		fail "$label ($file): A does not precede B ($line_a >= $line_b)"
	fi
}

# contradiction_pass_excerpt FILE
# Extracts the Contradiction Pass section (from its h4 header to the next
# "### " heading, inclusive) into a temp file and echoes its path. Some
# wrapper/co-location assertions must be scoped to this excerpt rather than
# the whole SKILL.md — the five roster lenses also wrap {{PLAN_CONTENT}} in
# <untrusted-content>, so an unscoped check would still pass even if the
# Contradiction Pass's own block never wrapped it at all.
CONTRADICTION_EXCERPT_TMPFILES=()
trap 'rm -f "${CONTRADICTION_EXCERPT_TMPFILES[@]}"' EXIT

contradiction_pass_excerpt() {
	local file="$1"
	local tmp
	tmp=$(mktemp)
	CONTRADICTION_EXCERPT_TMPFILES+=("$tmp")
	awk '/^#### Contradiction Pass/{p=1} p{print} p && /^### / && !/^#### Contradiction Pass/{exit}' "$file" >"$tmp"
	echo "$tmp"
}

echo "=== R2 tier census: plugins/skein-codex/skills/*/SKILL.md ==="
echo

# --- (7) Codex per-skill reasoning_effort counts ---
# These counts intentionally use Codex's prose-hint idiom (`reasoning_effort=X`)
# rather than Claude `model:`/`effort:` fields. They cover all Codex SKILL.md
# spawns/lenses that declare a tier in the mirror, including the R6 fan-out
# test-writer intended topology, even though that topology is gated/inactive
# until the nested-spawn runtime gate is confirmed.
CODEX_HIGH_RE='reasoning_effort=high'
CODEX_MEDIUM_RE='reasoning_effort=medium'
CODEX_LOW_RE='reasoning_effort=low'

assert_count "$CODEX_SKILLS_DIR/review-plan/SKILL.md" "$CODEX_HIGH_RE" 5 \
	"codex review-plan reasoning_effort=high judgment lens count (4 parallel lenses + 1 post-reconciliation Contradiction Pass)"
assert_count "$CODEX_SKILLS_DIR/review-plan/SKILL.md" "$CODEX_LOW_RE" 1 \
	"codex review-plan reasoning_effort=low factual lens count"
assert_count "$CODEX_SKILLS_DIR/deep-review/SKILL.md" "$CODEX_HIGH_RE" 4 \
	"codex deep-review reasoning_effort=high review lens count"
assert_count "$CODEX_SKILLS_DIR/deep-review/SKILL.md" "$CODEX_LOW_RE" 1 \
	"codex deep-review reasoning_effort=low documentation lens count"
assert_count "$CODEX_SKILLS_DIR/spec-compliance/SKILL.md" "$CODEX_HIGH_RE" 1 \
	"codex spec-compliance reasoning_effort=high count"
assert_count "$CODEX_SKILLS_DIR/conduct/SKILL.md" "$CODEX_MEDIUM_RE" 5 \
	"codex conduct reasoning_effort=medium lifecycle count"
assert_count "$CODEX_SKILLS_DIR/conduct/SKILL.md" "$CODEX_HIGH_RE" 2 \
	"codex conduct reasoning_effort=high reviewer lifecycle count"
assert_count "$CODEX_SKILLS_DIR/dev-plan/SKILL.md" "$CODEX_MEDIUM_RE" 1 \
	"codex dev-plan reasoning_effort=medium Explore count"
assert_count "$CODEX_SKILLS_DIR/plan-view/SKILL.md" "$CODEX_LOW_RE" 2 \
	"codex plan-view reasoning_effort=low rich-render spawn count"
assert_count "$CODEX_SKILLS_DIR/fan-out/SKILL.md" "$CODEX_MEDIUM_RE" 2 \
	"codex fan-out reasoning_effort=medium test-writer gated-topology count"
assert_count "$CODEX_SKILLS_DIR/review-gauntlet/SKILL.md" "$CODEX_MEDIUM_RE" 1 \
	"codex review-gauntlet reasoning_effort=medium fixer lifecycle count"
assert_count "$CODEX_SKILLS_DIR/content-draft/SKILL.md" "$CODEX_LOW_RE" 1 \
	"codex content-draft reasoning_effort=low count"
assert_count "$CODEX_SKILLS_DIR/content-review/SKILL.md" "$CODEX_LOW_RE" 1 \
	"codex content-review reasoning_effort=low count"
assert_count "$CODEX_SKILLS_DIR/update-docs/SKILL.md" "$CODEX_LOW_RE" 1 \
	"codex update-docs reasoning_effort=low count"
assert_count "$CODEX_SKILLS_DIR/rfc-finder/SKILL.md" "$CODEX_LOW_RE" 1 \
	"codex rfc-finder reasoning_effort=low count"

assert_count_total "$CODEX_SKILLS_DIR/*/SKILL.md" "$CODEX_HIGH_RE" 12 \
	"codex total reasoning_effort=high occurrences across SKILL.md"
assert_count_total "$CODEX_SKILLS_DIR/*/SKILL.md" "$CODEX_MEDIUM_RE" 9 \
	"codex total reasoning_effort=medium occurrences across SKILL.md"
assert_count_total "$CODEX_SKILLS_DIR/*/SKILL.md" "$CODEX_LOW_RE" 8 \
	"codex total reasoning_effort=low occurrences across SKILL.md"

# --- (8) Codex review-tier rationale / R3 why coverage ---
assert_present "$CODEX_SKILLS_DIR/deep-review/SKILL.md" 'reasoning_effort=high.*Deep reasoning' \
	"codex deep-review Logic high-effort rationale"
assert_present "$CODEX_SKILLS_DIR/deep-review/SKILL.md" 'reasoning_effort=high.*High-impact findings' \
	"codex deep-review Security high-effort rationale"
assert_present "$CODEX_SKILLS_DIR/deep-review/SKILL.md" 'reasoning_effort=high.*Cross-referencing standards' \
	"codex deep-review Spec high-effort rationale"
assert_present "$CODEX_SKILLS_DIR/deep-review/SKILL.md" 'reasoning_effort=high.*Review-tier architecture judgment' \
	"codex deep-review Architecture high-effort rationale"
assert_present "$CODEX_SKILLS_DIR/review-plan/SKILL.md" 'reasoning_effort=high.*Patterns, coupling, integration seams' \
	"codex review-plan Architecture high-effort rationale"
assert_present "$CODEX_SKILLS_DIR/review-plan/SKILL.md" 'reasoning_effort=high.*Task order, hidden dependencies' \
	"codex review-plan Sequencing high-effort rationale"
assert_present "$CODEX_SKILLS_DIR/review-plan/SKILL.md" 'reasoning_effort=high.*Review Focus, RFC/spec references' \
	"codex review-plan Spec-and-testing high-effort rationale"
assert_present "$CODEX_SKILLS_DIR/review-plan/SKILL.md" 'reasoning_effort=high.*Unverifiable claims stated as fact' \
	"codex review-plan Assumptions high-effort rationale"
assert_present "$CODEX_SKILLS_DIR/review-plan/SKILL.md" 'reasoning_effort=high.*Plan-internal and cross-lens logical conflicts' \
	"codex review-plan Contradiction Pass high-effort rationale"
assert_present "$CODEX_SKILLS_DIR/spec-compliance/SKILL.md" 'R3 why: normative spec compliance is judgment work' \
	"codex spec-compliance R3 why-comment"
assert_present "$CODEX_SKILLS_DIR/conduct/SKILL.md" 'Code review is judgment work, so the advisory reviewer gets the review tier' \
	"codex conduct reviewer rationale"

# --- (9) Codex R6 and dispatch-idiom guards ---
assert_present "$CODEX_SKILLS_DIR/fan-out/SKILL.md" 'reasoning_effort=medium.*fork_context=false' \
	"codex fan-out R6 intended test-writer spawn carries medium effort and fork_context=false"
assert_present "$ROOT_DIR/plugins/skein-codex/skills/fan-out/agent-prompt.md" 'reasoning_effort=medium' \
	"codex fan-out agent-prompt documents gated test-writer reasoning_effort=medium"
assert_present "$ROOT_DIR/plugins/skein-codex/skills/fan-out/test-writer-prompt.md" 'reasoning_effort=medium' \
	"codex fan-out test-writer-prompt documents medium effort"
assert_present "$CODEX_SKILLS_DIR/fan-out/SKILL.md" 'Codex does not pin model names' \
	"codex fan-out documents no default model pin"
assert_present "$ROOT_DIR/plugins/skein-codex/skills/fan-out/fan-out.sh" 'FANOUT_EFFORT' \
	"codex fan-out.sh FANOUT_EFFORT support present"
assert_present "$ROOT_DIR/plugins/skein-codex/skills/fan-out/fan-out.sh" 'command_supports_effort' \
	"codex fan-out.sh first-class --effort detection present"

echo
echo "=== R2 tier census: plugins/skein/skills/*/SKILL.md ==="
echo

# --- (1) Pinned total of opus/high why-comments across all skills ---
# deep-review 4 (logic/security/spec/architecture) + spec-compliance 1 +
# conduct 1 (reviewer) = 6. review-plan's four judgment lenses moved to
# fable/high (opus fallback) — see (1b) — so they no longer count here.
assert_count_total "$SKILLS_DIR/*/SKILL.md" 'opus/high:' 6 \
	"pinned total opus/high why-comments across plugins/skein/skills/*/SKILL.md"

# --- (1b) Pinned total of fable/high why-comments (review-plan judgment
# lenses + the Step 3 sub-step 2.5 Contradiction Pass, which also dispatches
# at model: fable, effort: high with opus fallback — see Architecture
# Decisions, "Decision (grilled): Step 3.5 is a non-roster 'Contradiction
# Pass'" in the contradiction-step dev plan) ---
assert_count "$SKILLS_DIR/review-plan/SKILL.md" 'fable/high:' 5 \
	"review-plan fable/high why-comment count"
assert_count_total "$SKILLS_DIR/*/SKILL.md" 'fable/high:' 5 \
	"pinned total fable/high why-comments across plugins/skein/skills/*/SKILL.md"

# --- (1c) review-plan judgment-lens headers actually carry model: fable ---
# The why-comment count above (1b) only pins the `<!-- fable/high: ... -->`
# rationale marker, not the `#### <Lens> Lens (model: fable, ...)` header
# itself — mirroring the explicit MODEL_HAIKU_RE check at (4), which does
# the same for the haiku lens. Without this, a header left at `model: opus`
# while its why-comment said `fable/high:` would slip past (1b) undetected.
assert_count "$SKILLS_DIR/review-plan/SKILL.md" '^#### .* Lens \(model: fable,' 4 \
	"review-plan judgment-lens headers carry model: fable"

# --- (2) Per-skill expected effort:high counts (both quoting styles) ---
# Trailing ([^/]|$) excludes prose like "effort: high/low" (a generic doc
# sentence describing both tiers, not a per-lens annotation) from the count.
EFFORT_HIGH_RE='effort:[[:space:]]*"?high"?([^/]|$)'
assert_count "$SKILLS_DIR/review-plan/SKILL.md" "$EFFORT_HIGH_RE" 5 \
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

# --- (6) R6: fan-out test-writer spawn documented at sonnet/medium ---
# The test-writer topology is currently gated (see CODEX_MIRROR_BACKLOG.md,
# 2026-07-04 entry) but its intended tier must still be documented in
# agent-prompt.md so the annotation survives once the gate is confirmed. This
# does not change the pinned opus/high total above (6) — sonnet/medium is a
# mechanical tier, not a judgment tier.
FANOUT_AGENT_PROMPT="$SKILLS_DIR/fan-out/agent-prompt.md"
assert_present "$FANOUT_AGENT_PROMPT" 'model: sonnet, effort: medium' \
	"fan-out agent-prompt.md test-writer spawn documented at model: sonnet, effort: medium"

# --- (6b) R6 anti-cheat semantics floor (both mirrors) ---
# scripts/check-prompt-parity.sh excises the R6 idiom spans (the anti-cheat
# paragraph and the gated-topology block) before byte-comparing the two fan-out
# prompt mirrors, so byte-parity no longer guards R6's load-bearing "contract
# wins" anti-cheat rule. Assert its presence here in BOTH mirrors so the excised
# span keeps an automated floor (deep-review Architecture finding, 2026-07-04).
for tree in "$SKILLS_DIR" "$CODEX_SKILLS_DIR"; do
	assert_present "$tree/fan-out/agent-prompt.md" 'contract wins' \
		"fan-out agent-prompt.md ($tree) carries the R6 anti-cheat 'contract wins' rule"
	# The parity normalizer's excision ranges end on these anchors; if a future
	# edit drops an anchor in one mirror the sed range would run to EOF and
	# over-excise, masking real drift (Logic finding, 2026-07-04). Pin them.
	assert_present "$tree/fan-out/agent-prompt.md" '^### Phase 5' \
		"fan-out agent-prompt.md ($tree) retains the '### Phase 5' excision anchor"
	assert_present "$tree/fan-out/agent-prompt.md" '^If your task has an applicable test framework' \
		"fan-out agent-prompt.md ($tree) retains the Phase-2 test-directive excision start anchor"
	assert_present "$tree/fan-out/agent-prompt.md" '^If no relevant test framework exists' \
		"fan-out agent-prompt.md ($tree) retains the Phase-2 test-directive excision end anchor"
	assert_present "$tree/fan-out/test-writer-prompt.md" '^Filled by the fan-out worker' \
		"fan-out test-writer-prompt.md ($tree) retains the 'Filled by the fan-out worker' excision anchor"
done

echo
echo "=== (10) review-plan Contradiction Pass census (Claude-side; Codex twins in section 11 below) ==="
echo

RP_SKILL="$SKILLS_DIR/review-plan/SKILL.md"
RP_RUBRIC="$SKILLS_DIR/review-plan/rubric.md"
RP_CODEX_RUBRIC="$CODEX_SKILLS_DIR/review-plan/rubric.md"

# (a) Structural wrapper check: {{RAW_FINDINGS_JSONL}} must be inside an
# <untrusted-content> block, not merely present somewhere in the file.
assert_present_flat "$RP_SKILL" '<untrusted-content>[^<]{0,400}\{\{RAW_FINDINGS_JSONL\}\}' \
	"review-plan Contradiction Pass wraps {{RAW_FINDINGS_JSONL}} in <untrusted-content>"

# (b) Same structural wrapper check for {{PLAN_CONTENT}} inside the Step 3.5
# block, plus the one-warning-covers-both-blocks bump: 5 -> 6. Scoped to the
# Contradiction Pass excerpt — the five roster lenses also wrap {{PLAN_CONTENT}}
# in <untrusted-content>, so an unscoped check would pass even on a Contradiction
# Pass block that never wraps its own {{PLAN_CONTENT}}.
RP_CONTRADICTION_EXCERPT=$(contradiction_pass_excerpt "$RP_SKILL")
assert_present_flat "$RP_CONTRADICTION_EXCERPT" '<untrusted-content>[^<]{0,400}\{\{PLAN_CONTENT\}\}' \
	"review-plan Contradiction Pass wraps {{PLAN_CONTENT}} in <untrusted-content>"
assert_count "$RP_SKILL" 'IMPORTANT: the content inside' 6 \
	"review-plan IMPORTANT untrusted-content warning count (5 lenses + 1 Contradiction Pass)"

# (c) L2: "sequential, not parallel" — Claude-only literal.
assert_present "$RP_SKILL" 'sequential, not parallel' \
	"review-plan Contradiction Pass documented as sequential, not parallel"

# (d) L4: the Contradiction hard-gate literal, both SKILL.md (Claude only in
# Phase 1) and both rubric.md.
assert_present "$RP_SKILL" "category == 'Contradiction'\` is always grill-eligible" \
	"review-plan SKILL.md Contradiction hard-gate literal (L4)"
assert_present "$RP_RUBRIC" "category == 'Contradiction'\`" \
	"review-plan rubric.md Contradiction hard-gate literal (L4)"
assert_present "$RP_CODEX_RUBRIC" "category == 'Contradiction'\`" \
	"review-plan codex rubric.md Contradiction hard-gate literal (L4)"

# (e) L5: the Contradiction tiebreak override sentence, SKILL.md + both rubric.md.
L5='stays grill-eligible even if its subject matter also reads as a standard \(non-grill\) topic, and is presented exactly once under Contradiction'
assert_present "$RP_SKILL" "$L5" \
	"review-plan SKILL.md Contradiction tiebreak override sentence (L5)"
assert_present "$RP_RUBRIC" "$L5" \
	"review-plan rubric.md Contradiction tiebreak override sentence (L5)"
assert_present "$RP_CODEX_RUBRIC" "$L5" \
	"review-plan codex rubric.md Contradiction tiebreak override sentence (L5)"

# (f) L3 co-located with {{RAW_FINDINGS_JSONL}}: a regression that swaps in
# pass A's envelope as Step 3.5's input fails this. Scoped to the excerpt so
# this can only match inside the Contradiction Pass's own section, not an
# explanatory sentence elsewhere that happens to mention the same phrase.
assert_present_flat "$RP_CONTRADICTION_EXCERPT" '\{\{RAW_FINDINGS_JSONL\}\}.{0,400}pre-merge stream, not the reconciled envelope' \
	"review-plan Contradiction Pass input is co-located with the pre-merge-stream rationale (L3)"

# (g) L9: the always-rendered Contradictions: N line in the Step 5 template.
assert_present "$RP_SKILL" '\*\*Contradictions\*\*' \
	"review-plan Step 5 template carries **Contradictions**: N (L9)"

# (h) L7: the pass-A-fallback behaviour literal.
assert_present "$RP_SKILL" "falls back to pass A's envelope" \
	"review-plan Contradiction Pass documents the pass-A fallback (L7)"

# (i) L1: the full anchored Contradiction Pass header.
assert_present "$RP_SKILL" '^#### Contradiction Pass \(model: fable, effort: high; opus fallback on usage-limit\)$' \
	"review-plan anchored Contradiction Pass header (L1)"

# (j) Ordering: the Contradiction hard-gate rule must precede the Borderline
# tiebreak bullet. Plus L14 ("hard gate applied first"), already-shipped text.
assert_order "$RP_SKILL" 'always grill-eligible' 'Borderline tiebreak' \
	"review-plan Contradiction hard-gate precedes Borderline tiebreak (SKILL.md)"
assert_present "$RP_SKILL" 'hard gate applied first' \
	"review-plan SKILL.md states the hard-gate-applied-first ordering (L14)"

# (j-r) Rubric ordering twin, keyed on L12 vs the tiebreak literal at :79,
# both rubric copies.
L12="or any finding whose \`category == 'Contradiction'\`"
TIEBREAK_LINE='A borderline finding resolves to exactly one lane'
assert_order "$RP_RUBRIC" "$L12" "$TIEBREAK_LINE" \
	"review-plan rubric.md Contradiction hard-gate precedes tiebreak bullet"
assert_order "$RP_CODEX_RUBRIC" "$L12" "$TIEBREAK_LINE" \
	"review-plan codex rubric.md Contradiction hard-gate precedes tiebreak bullet"

# (k) L6 count = 5 in SKILL.md — one per amended Step 3 sentence.
assert_count "$RP_SKILL" 'except Step 3 sub-step 2\.5 \(the Contradiction Pass\)' 5 \
	"review-plan five Step 3 sentences carve out sub-step 2.5 verbatim (L6)"

# (l) The two bare, uncarved Forbidden bullets must no longer exist in that form.
assert_absent "$RP_SKILL" '^- LLM calls of any kind\.$' \
	"review-plan bare 'LLM calls of any kind.' Forbidden bullet is gone"
assert_absent "$RP_SKILL" '^- Free-text similarity matching across lens summaries\. Lenses run in fresh context' \
	"review-plan bare 'Free-text similarity matching' Forbidden bullet is gone"

# (m) L12 in both rubric.md copies (the :74 scope-line amendment).
assert_present "$RP_RUBRIC" "$L12" \
	"review-plan rubric.md :74 scope line admits the Contradiction gate (L12)"
assert_present "$RP_CODEX_RUBRIC" "$L12" \
	"review-plan codex rubric.md :74 scope line admits the Contradiction gate (L12)"

# (n) L13 in both rubric.md copies (:44 "if all six passes are empty").
assert_present "$RP_RUBRIC" 'if all six passes are empty' \
	"review-plan rubric.md :44 covers the contradiction pass (L13)"
assert_present "$RP_CODEX_RUBRIC" 'if all six passes are empty' \
	"review-plan codex rubric.md :44 covers the contradiction pass (L13)"

# (o) L11 in both rubric.md copies (the :25 reservation clause).
assert_present "$RP_RUBRIC" 'reserved for the Step 3 sub-step 2\.5 contradiction pass' \
	"review-plan rubric.md :25 Contradiction reservation clause (L11)"
assert_present "$RP_CODEX_RUBRIC" 'reserved for the Step 3 sub-step 2\.5 contradiction pass' \
	"review-plan codex rubric.md :25 Contradiction reservation clause (L11)"

# (p) L10 count = 4 per SKILL.md (four lens Output blocks), = 1 per rubric.md.
assert_count "$RP_SKILL" 'Nonexistent Reference, Contradiction}' 4 \
	"review-plan SKILL.md four lens Output blocks carry the Contradiction enum value (L10)"
assert_count "$RP_RUBRIC" 'Nonexistent Reference, Contradiction}' 1 \
	"review-plan rubric.md enum line carries the Contradiction value (L10)"
assert_count "$RP_CODEX_RUBRIC" 'Nonexistent Reference, Contradiction}' 1 \
	"review-plan codex rubric.md enum line carries the Contradiction value (L10)"

# (q) reconcile-findings.sh --skill review-plan invoked twice per run
# (pass A + pass B), Claude SKILL.md only in Phase 1.
assert_count "$RP_SKILL" 'reconcile-findings\.sh --skill review-plan' 2 \
	"review-plan SKILL.md invokes reconcile-findings.sh --skill review-plan twice (pass A + pass B)"

# (r) The named pipeline artifacts the retry and fallback contracts depend on.
assert_present "$RP_SKILL" 'reconciled-pass-a\.json' \
	"review-plan SKILL.md names reconciled-pass-a.json"
assert_present "$RP_SKILL" 'findings-contradiction\.jsonl' \
	"review-plan SKILL.md names findings-contradiction.jsonl"

# (s) L8: the idempotent-rebuild mechanism.
assert_present "$RP_SKILL" 'rebuilt by concatenation, never appended in place' \
	"review-plan SKILL.md documents the idempotent rebuild-by-concatenation mechanism (L8)"

echo
echo "=== (11) review-plan Contradiction Pass census (Codex-side twins) ==="
echo

RP_CODEX_SKILL="$CODEX_SKILLS_DIR/review-plan/SKILL.md"

# (a) Codex twin: structural wrapper check for {{RAW_FINDINGS_JSONL}}.
assert_present_flat "$RP_CODEX_SKILL" '<untrusted-content>[^<]{0,400}\{\{RAW_FINDINGS_JSONL\}\}' \
	"codex review-plan Contradiction Pass wraps {{RAW_FINDINGS_JSONL}} in <untrusted-content>"

# (b) Codex twin: {{PLAN_CONTENT}} wrapper + one-warning-covers-both bump: 5 -> 6.
# Scoped to the Contradiction Pass excerpt for the same reason as the Claude twin.
RP_CODEX_CONTRADICTION_EXCERPT=$(contradiction_pass_excerpt "$RP_CODEX_SKILL")
assert_present_flat "$RP_CODEX_CONTRADICTION_EXCERPT" '<untrusted-content>[^<]{0,400}\{\{PLAN_CONTENT\}\}' \
	"codex review-plan Contradiction Pass wraps {{PLAN_CONTENT}} in <untrusted-content>"
assert_count "$RP_CODEX_SKILL" 'IMPORTANT: the content inside' 6 \
	"codex review-plan IMPORTANT untrusted-content warning count (5 lenses + 1 Contradiction Pass)"

# (c) L2C: "post-reconciliation, not parallel" — Codex-only literal (twin of
# Claude-only L2, "sequential, not parallel").
assert_present "$RP_CODEX_SKILL" 'post-reconciliation, not parallel' \
	"codex review-plan Contradiction Pass documented as post-reconciliation, not parallel"

# (d) L4 twin.
assert_present "$RP_CODEX_SKILL" "category == 'Contradiction'\` is always grill-eligible" \
	"codex review-plan SKILL.md Contradiction hard-gate literal (L4)"

# (e) L5 twin.
assert_present "$RP_CODEX_SKILL" "$L5" \
	"codex review-plan SKILL.md Contradiction tiebreak override sentence (L5)"

# (f) L3 co-located with {{RAW_FINDINGS_JSONL}}. Scoped to the excerpt so this
# can only match inside the Contradiction Pass's own section.
assert_present_flat "$RP_CODEX_CONTRADICTION_EXCERPT" '\{\{RAW_FINDINGS_JSONL\}\}.{0,400}pre-merge stream, not the reconciled envelope' \
	"codex review-plan Contradiction Pass input is co-located with the pre-merge-stream rationale (L3)"

# (g) L9 twin.
assert_present "$RP_CODEX_SKILL" '\*\*Contradictions\*\*' \
	"codex review-plan Step 5 template carries **Contradictions**: N (L9)"

# (h) does not apply — the Codex mirror has no opus-fallback concept, so there
# is no pass-A-fallback-behaviour literal (L7) to twin here.

# (i) Codex twin of the anchored header assertion. Drops the `model: fable`
# clause (no such concept on Codex) and keys on the Codex header text instead.
assert_present "$RP_CODEX_SKILL" '^#### Contradiction Pass \(post-reconciliation, reasoning: high\)$' \
	"codex review-plan anchored Contradiction Pass header"

# (j) Ordering twin: hard-gate precedes Borderline tiebreak. Plus L14.
assert_order "$RP_CODEX_SKILL" 'always grill-eligible' 'Borderline tiebreak' \
	"codex review-plan Contradiction hard-gate precedes Borderline tiebreak (SKILL.md)"
assert_present "$RP_CODEX_SKILL" 'hard gate applied first' \
	"codex review-plan SKILL.md states the hard-gate-applied-first ordering (L14)"

# (k) L6 count = 5 twin.
assert_count "$RP_CODEX_SKILL" 'except Step 3 sub-step 2\.5 \(the Contradiction Pass\)' 5 \
	"codex review-plan five Step 3 sentences carve out sub-step 2.5 verbatim (L6)"

# (l) Twin: the two bare, uncarved Forbidden bullets must no longer exist.
assert_absent "$RP_CODEX_SKILL" '^- LLM calls of any kind\.$' \
	"codex review-plan bare 'LLM calls of any kind.' Forbidden bullet is gone"
assert_absent "$RP_CODEX_SKILL" '^- Free-text similarity matching across lens summaries\. Lenses run in fresh context' \
	"codex review-plan bare 'Free-text similarity matching' Forbidden bullet is gone"

# (m)-(o) are rubric-only assertions (L11, L12, L13) — already covered above
# against both rubric.md copies; no separate Codex SKILL.md twin applies.

# (p) L10 count = 4 twin (four lens Output blocks in the Codex mirror).
assert_count "$RP_CODEX_SKILL" 'Nonexistent Reference, Contradiction}' 4 \
	"codex review-plan SKILL.md four lens Output blocks carry the Contradiction enum value (L10)"

# (q) reconcile-findings.sh --skill review-plan invoked twice per run, Codex twin.
assert_count "$RP_CODEX_SKILL" 'reconcile-findings\.sh --skill review-plan' 2 \
	"codex review-plan SKILL.md invokes reconcile-findings.sh --skill review-plan twice (pass A + pass B)"

# (r) Named pipeline artifacts, Codex twin.
assert_present "$RP_CODEX_SKILL" 'reconciled-pass-a\.json' \
	"codex review-plan SKILL.md names reconciled-pass-a.json"
assert_present "$RP_CODEX_SKILL" 'findings-contradiction\.jsonl' \
	"codex review-plan SKILL.md names findings-contradiction.jsonl"

# (s) L8 twin.
assert_present "$RP_CODEX_SKILL" 'rebuilt by concatenation, never appended in place' \
	"codex review-plan SKILL.md documents the idempotent rebuild-by-concatenation mechanism (L8)"

echo
echo "=== Summary: $pass_count passed, $fail_count failed ==="

if [[ "$fail_count" -gt 0 ]]; then
	exit 1
fi

exit 0
