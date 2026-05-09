#!/usr/bin/env bash
# check-prompt-parity.sh
#
# Verify that prompt-contract artefacts (currently `rubric.md`) are
# byte-identical between `.claude/skills/<skill>/` and
# `.codex/skills/<skill>/` for every entry in MANAGED_SKILLS.
#
# Scope: rubric.md only. Lens prompt bodies and finding schema embedded
# inside SKILL.md are not script-checkable and require manual review per
# the dev plan's Phase 6 verification step.
#
# Inputs:
#   MANAGED_SKILLS  whitespace-separated list of skill names. Sourced
#                   from .env if present; falls back to the hardcoded
#                   default below. Comma-separated values are NOT split.
#
# Per-skill behaviour:
#   - neither side has rubric.md   skip (skill ships no rubric)
#   - exactly one side has it      fail (drift)
#   - both sides have it           diff; fail on mismatch
#
# Exit codes: 0 clean, 1 drift detected.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -f "$ROOT_DIR/.env" ]]; then
	# Safelist parser: `source .env` is unsafe (executes arbitrary shell). Only
	# pull the keys this script reads, and only when they look like a plain
	# assignment to a quoted or bare value.
	while IFS= read -r line; do
		case "$line" in
		MANAGED_SKILLS=*) eval "export $line" ;;
		esac
	done < <(grep -E '^(MANAGED_SKILLS)=' "$ROOT_DIR/.env" || true)
fi

MANAGED_SKILLS="${MANAGED_SKILLS:-conduct content-draft content-review deep-review dev-plan fan-out review-plan rfc-finder spec-compliance update-docs}"

PARITY_DIFF=0

read -r -a managed_skills <<<"$MANAGED_SKILLS"
for skill in "${managed_skills[@]}"; do
	# Reject anything that isn't a plain skill name to block path traversal
	# via .env-supplied MANAGED_SKILLS (e.g. "../../etc/passwd").
	if [[ ! "$skill" =~ ^[A-Za-z0-9_-]+$ ]]; then
		echo "drift: invalid skill name in MANAGED_SKILLS: $skill"
		PARITY_DIFF=1
		continue
	fi

	claude_rubric="$ROOT_DIR/.claude/skills/$skill/rubric.md"
	codex_rubric="$ROOT_DIR/.codex/skills/$skill/rubric.md"

	if [[ ! -f "$claude_rubric" && ! -f "$codex_rubric" ]]; then
		# Skill ships no rubric on either side — nothing to compare.
		continue
	fi

	if [[ -f "$claude_rubric" && ! -f "$codex_rubric" ]]; then
		echo "drift: $skill has .claude rubric but no .codex rubric"
		PARITY_DIFF=1
		continue
	fi

	if [[ ! -f "$claude_rubric" && -f "$codex_rubric" ]]; then
		echo "drift: $skill has .codex rubric but no .claude rubric"
		PARITY_DIFF=1
		continue
	fi

	if diff_output=$(diff -u "$claude_rubric" "$codex_rubric" 2>&1); then
		: # rubrics match
	else
		diff_rc=$?
		if [[ $diff_rc -eq 1 ]]; then
			echo "drift: $skill rubric.md differs between .claude and .codex"
		else
			echo "error: diff failed for $skill rubric.md (exit $diff_rc)"
		fi
		echo "$diff_output"
		PARITY_DIFF=1
	fi
done

# --- GENERIC FINDING SCHEMA AND MERGE block parity ---------------------
#
# The reconciliation contract block (delimited by HTML-comment markers
# inside SKILL.md) is the single point of contact between SKILL.md prose
# and `scripts/reconcile-findings.sh`. The same block content MUST exist
# byte-identically in both deep-review and review-plan, on both the
# Claude and Codex sides. Modelled on
# `scripts/check-trunk-snippet-parity.sh`'s extraction approach.

GENERIC_TARGETS=(
	"$ROOT_DIR/.claude/skills/deep-review/SKILL.md"
	"$ROOT_DIR/.claude/skills/review-plan/SKILL.md"
	"$ROOT_DIR/.codex/skills/deep-review/SKILL.md"
	"$ROOT_DIR/.codex/skills/review-plan/SKILL.md"
)

extract_generic() {
	# Print the lines strictly between the BEGIN and END markers.
	awk '
		/<!-- BEGIN GENERIC FINDING SCHEMA AND MERGE -->/ { found=1; next }
		/<!-- END GENERIC FINDING SCHEMA AND MERGE -->/ { exit }
		found { print }
	' "$1"
}

generic_canonical=""
generic_canonical_path=""

for path in "${GENERIC_TARGETS[@]}"; do
	if [[ ! -f "$path" ]]; then
		echo "drift: GENERIC block target missing: $path"
		PARITY_DIFF=1
		continue
	fi
	block="$(extract_generic "$path")"
	if [[ -z "$block" ]]; then
		echo "drift: GENERIC FINDING SCHEMA AND MERGE block not found in $path"
		PARITY_DIFF=1
		continue
	fi
	if [[ -z "$generic_canonical" ]]; then
		generic_canonical="$block"
		generic_canonical_path="$path"
		continue
	fi
	if [[ "$block" != "$generic_canonical" ]]; then
		echo "drift: GENERIC block in $path differs from $generic_canonical_path"
		diff <(printf '%s\n' "$generic_canonical") <(printf '%s\n' "$block") || true
		PARITY_DIFF=1
	fi
done

if [[ "$PARITY_DIFF" -eq 1 ]]; then
	echo "check-prompt-parity failed"
	exit 1
fi

echo "check-prompt-parity passed"
