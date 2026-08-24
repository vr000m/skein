#!/usr/bin/env bash
# test-lens-skill-shape.sh — Phase 2 acceptance: both mirrors of
# deep-review AND review-plan SKILL.md document the streamed-lens protocol.
#
# Plan: docs/dev_plans/20260823-feature-review-skills-resilience.md, Phase 2
# checklist ("new shape test tests/lenses/test-lens-skill-shape.sh asserts
# both mirrors reference persist-lens-result.sh --type start, --attempt 2,
# collect-lens-results.sh, lens-budget.sh, the --continue re-run clause
# (timed_out|errored|partial|absent), and the Codex sequential-mode
# clause").
#
# Pure documentation/shape check over the four SKILL.md files (Claude +
# Codex mirrors, deep-review + review-plan) — no runtime behaviour, in the
# style of tests/gauntlet/test-gauntlet-skill-shape.sh.
#
# Exit codes: 0 all assertions pass, 1 any assertion fails.

set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"

SKILLS=(
	"$ROOT_DIR/plugins/skein/skills/deep-review/SKILL.md"
	"$ROOT_DIR/plugins/skein-codex/skills/deep-review/SKILL.md"
	"$ROOT_DIR/plugins/skein/skills/review-plan/SKILL.md"
	"$ROOT_DIR/plugins/skein-codex/skills/review-plan/SKILL.md"
)

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

require_file() {
	local file="$1"
	if [[ ! -f "$file" ]]; then
		fail "file missing: $file"
		return 1
	fi
	return 0
}

# assert_grep FILE PATTERN LABEL
# PATTERN is passed to `grep -Eq` (extended regex) against the whole file.
assert_grep() {
	local file="$1" pattern="$2" label="$3"
	if grep -Eq -- "$pattern" "$file"; then
		pass "$label ($file)"
	else
		fail "$label ($file)"
	fi
}

for skill_md in "${SKILLS[@]}"; do
	if ! require_file "$skill_md"; then
		continue
	fi

	assert_grep "$skill_md" 'persist-lens-result\.sh' \
		"references persist-lens-result.sh"

	# G1: the lens-facing contract moved to --json-stdin, so `--type start`
	# survives only in the orchestrator-authored (closed-enum) invocations.
	# Either spelling of "there is a start record" satisfies this leg.
	if grep -Eq -- '--type[[:space:]]+start' "$skill_md" ||
		grep -Eq -- '"type"[[:space:]]*:[[:space:]]*"start"' "$skill_md"; then
		pass "references a start record ($skill_md)"
	else
		fail "references a start record ($skill_md)"
	fi

	# --- G1 (findings 1/3): untrusted text must not reach the lens's argv ---

	assert_grep "$skill_md" '\-\-json-stdin' \
		"references --json-stdin (payload off argv)"

	assert_grep "$skill_md" "<<'SKEIN_JSON'" \
		"uses the quoted heredoc delimiter <<'SKEIN_JSON' (no shell expansion)"

	# NEGATIVE assertion: the old argv-carrying template must be GONE, not
	# merely supplemented. `--evidence "` is the exact shape that let a lens's
	# own shell expand $(...)/backticks out of reviewed code.
	if grep -Eq -- '\-\-evidence[[:space:]]*"' "$skill_md"; then
		fail "no --evidence \"...\" on a command line (old injectable template still present) ($skill_md)"
		grep -nE -- '\-\-evidence[[:space:]]*"' "$skill_md" | sed 's/^/    /'
	else
		pass "no --evidence \"...\" on a command line ($skill_md)"
	fi

	assert_grep "$skill_md" '--attempt[[:space:]]+2' \
		"references --attempt 2 (the respawn variant)"

	assert_grep "$skill_md" 'collect-lens-results\.sh' \
		"references collect-lens-results.sh"

	assert_grep "$skill_md" 'lens-budget\.sh' \
		"references lens-budget.sh"

	# The --continue re-run clause: all four re-run statuses must appear
	# somewhere in the file. "absent" is checked loosely (the plan's own
	# prose sometimes phrases it as "absent"/"missing" interchangeably --
	# R4: "absent = missing" -- so either token satisfies this leg).
	if grep -Fq "timed_out" "$skill_md" \
		&& grep -Fq "errored" "$skill_md" \
		&& grep -Fq "partial" "$skill_md" \
		&& (grep -Fq "absent" "$skill_md" || grep -Fq "missing" "$skill_md"); then
		pass "documents the --continue re-run clause (timed_out|errored|partial|absent) ($skill_md)"
	else
		fail "documents the --continue re-run clause (timed_out|errored|partial|absent) ($skill_md)"
	fi

	# Codex sequential-mode clause: the orchestrator emits typed lines
	# itself and skips respawn, but the collector still runs. Checked
	# loosely (case-insensitive "sequential" near "Codex"), since exact
	# phrasing is not pinned down by the plan beyond R4's prose.
	if grep -Eiq 'codex' "$skill_md" && grep -Eiq 'sequential' "$skill_md"; then
		pass "documents the Codex sequential-mode clause ($skill_md)"
	else
		fail "documents the Codex sequential-mode clause ($skill_md)"
	fi

	# --- Phase 2 fix-spec additions (finding 3/5/6/C1/C2/C3 prose) ---

	assert_grep "$skill_md" '\-\-attempts' \
		"references --attempts (respawn-count flag)"

	assert_grep "$skill_md" '\-\-findings-jsonl' \
		"references --findings-jsonl (D-7/C3 collector normalizer flag)"

	# D-2 (finding 5): attempt-3+ on --continue must be documented -- reusing
	# --attempt 2 forever would put two writers on one file. Checked loosely
	# (either phrasing the fix-spec's clause text uses).
	if grep -Fq "attempt 3" "$skill_md" || grep -Eiq 'next unused attempt' "$skill_md"; then
		pass "documents the attempt-3+ --continue re-run clause ($skill_md)"
	else
		fail "documents the attempt-3+ --continue re-run clause ($skill_md)"
	fi

	# D-6 (C2/D3): per-lens deadlines, not one global wake.
	if grep -Eiq 'own deadline' "$skill_md" || grep -Eiq 'per-lens deadline' "$skill_md"; then
		pass "documents the per-lens-deadline wake clause ($skill_md)"
	else
		fail "documents the per-lens-deadline wake clause ($skill_md)"
	fi

	# D-5 (C1): every generic persistence-contract value placeholder is
	# delimited so a multi-word value cannot split. Under G1's --json-stdin
	# contract the argv-splitting hazard is structurally gone, so the JSON
	# spelling (`"severity":"<...>"`) satisfies this leg as well as the old
	# quoted-flag spelling.
	if (grep -Fq -- '--severity "' "$skill_md" && grep -Fq -- '--category "' "$skill_md") ||
		(grep -Fq -- '"severity":"' "$skill_md" && grep -Fq -- '"category":"' "$skill_md"); then
		pass "delimits severity/category value placeholders ($skill_md)"
	else
		fail "delimits severity/category value placeholders ($skill_md)"
	fi
done

# D-1/D-3/D-4 (finding 4==C4, finding 6, finding 7): deep-review-only prose
# -- the final persist step must pipe collect | persist --from-collector
# (never the hand-assembled positional lenses.json), and the orchestrator
# must document writing `done --status skipped` on a deliberately-skipped
# lens's behalf.
DEEP_REVIEW_SKILLS=(
	"$ROOT_DIR/plugins/skein/skills/deep-review/SKILL.md"
	"$ROOT_DIR/plugins/skein-codex/skills/deep-review/SKILL.md"
)
for skill_md in "${DEEP_REVIEW_SKILLS[@]}"; do
	if ! require_file "$skill_md"; then
		continue
	fi

	assert_grep "$skill_md" '\-\-from-collector' \
		"final persist block uses --from-collector ($skill_md)"

	assert_grep "$skill_md" '\-\-status[[:space:]]+skipped' \
		"documents the orchestrator-emitted 'done --status skipped' clause ($skill_md)"

	# No positional lenses.json placeholder left in the final-persist prose
	# -- the fix-spec explicitly says to delete this wording when switching
	# to the collector pipe.
	if grep -Fq "assembled after Step 2" "$skill_md" || grep -Fq "assembled by hand" "$skill_md"; then
		fail "final persist block has no leftover hand-assembled-JSON wording ($skill_md)"
	else
		pass "final persist block has no leftover hand-assembled-JSON wording ($skill_md)"
	fi
done

echo ""
echo "Summary: $pass_count passed, $fail_count failed"

if [[ $fail_count -ne 0 ]]; then
	exit 1
fi
exit 0
