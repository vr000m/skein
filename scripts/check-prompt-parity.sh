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
	# Safelist parser: `source .env` is unsafe (executes arbitrary shell), and
	# `eval` would execute embedded $(...) / backticks. Pull only the
	# MANAGED_SKILLS key, strip the prefix, strip surrounding quotes, and
	# export the literal value. The per-skill regex validator further down
	# remains the defence-in-depth check on the value's contents.
	raw="$(grep -E '^MANAGED_SKILLS=' "$ROOT_DIR/.env" | head -n1 || true)"
	if [[ -n "$raw" ]]; then
		val="${raw#MANAGED_SKILLS=}"
		# Strip surrounding double or single quotes if present.
		val="${val#\"}"
		val="${val%\"}"
		val="${val#\'}"
		val="${val%\'}"
		export MANAGED_SKILLS="$val"
	fi
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

# --- *-prompt.md parity per managed skill ------------------------------
#
# Phase 3 (autonomous-mode plan) extension: for every skill in
# MANAGED_SKILLS, diff each *-prompt.md file between
# `.claude/skills/<skill>/` and `.codex/skills/<skill>/`.
#
# Lagging-mirror override: ``CONDUCT_LAGGING_MIRROR_OK`` is a comma- or
# whitespace-separated list of ``<skill>/<prompt-file>`` paths whose drift is
# known-in-flight (a mirror commit is expected to follow). When set:
#   * If ALL detected drift is enumerated in the override → exit zero AND
#     print ``expected lagging-mirror drift: <files> (CONDUCT_LAGGING_MIRROR_OK)``
#     to stderr for visibility.
#   * If ANY drift is NOT in the override → exit non-zero AND print
#     ``prompt parity drift: <file>`` for each unknown file (annotated
#     expected drift is still echoed alongside).
# Without the override, any drift exits non-zero with the generic message.

PROMPT_EXPECTED_DRIFT="${CONDUCT_LAGGING_MIRROR_OK:-}"
# Normalise commas to whitespace so users can write either separator.
PROMPT_EXPECTED_DRIFT="${PROMPT_EXPECTED_DRIFT//,/ }"

declare -a prompt_expected_drift_arr=()
if [[ -n "$PROMPT_EXPECTED_DRIFT" ]]; then
	read -r -a prompt_expected_drift_arr <<<"$PROMPT_EXPECTED_DRIFT"
fi

is_expected_drift() {
	local full_key="$1"
	local basename="$2"
	local item
	# Guard against ``set -u`` aborting on empty-array expansion when no
	# CONDUCT_LAGGING_MIRROR_OK override is set.
	if [[ ${#prompt_expected_drift_arr[@]} -eq 0 ]]; then
		return 1
	fi
	for item in "${prompt_expected_drift_arr[@]}"; do
		if [[ "$item" == "$full_key" ]]; then
			return 0
		fi
		if [[ "$item" == "$basename" ]]; then
			echo "warning: CONDUCT_LAGGING_MIRROR_OK basename entry '$item' is deprecated; use '$full_key'" >&2
			return 0
		fi
	done
	return 1
}

prompt_files_match() {
	local skill="$1"
	local prompt_file="$2"
	local claude_file="$3"
	local codex_file="$4"
	if [[ "$skill/$prompt_file" == "fan-out/agent-prompt.md" ]]; then
		diff -q \
			<(sed \
				-e 's/spawned Claude agent/spawned Codex agent/g' \
				-e 's/{{CLAUDE_MD_CONTENT}}/{{AGENTS_MD_CONTENT}}/g' \
				"$claude_file") \
			"$codex_file" >/dev/null 2>&1
		return
	fi
	diff -q "$claude_file" "$codex_file" >/dev/null 2>&1
}

declare -a prompt_drift_expected_observed=()
declare -a prompt_drift_unknown_observed=()

for skill in "${managed_skills[@]}"; do
	if [[ ! "$skill" =~ ^[A-Za-z0-9_-]+$ ]]; then
		# Already reported in the rubric loop; skip silently here.
		continue
	fi
	claude_skill_dir="$ROOT_DIR/.claude/skills/$skill"
	codex_skill_dir="$ROOT_DIR/.codex/skills/$skill"
	# Build the union of prompt files on either side. ``shopt -s nullglob``
	# would be cleaner but we keep the script POSIX-flexible.
	prompt_files=()
	if [[ -d "$claude_skill_dir" ]]; then
		while IFS= read -r f; do
			[[ -n "$f" ]] && prompt_files+=("$(basename "$f")")
		done < <(find "$claude_skill_dir" -maxdepth 1 -type f -name '*-prompt.md' 2>/dev/null)
	fi
	if [[ -d "$codex_skill_dir" ]]; then
		while IFS= read -r f; do
			[[ -n "$f" ]] && prompt_files+=("$(basename "$f")")
		done < <(find "$codex_skill_dir" -maxdepth 1 -type f -name '*-prompt.md' 2>/dev/null)
	fi
	# Dedupe.
	if [[ ${#prompt_files[@]} -gt 0 ]]; then
		IFS=$'\n' read -r -d '' -a prompt_files < <(printf '%s\n' "${prompt_files[@]}" | sort -u && printf '\0')
	fi
	if [[ ${#prompt_files[@]} -eq 0 ]]; then
		continue
	fi
	for pf in "${prompt_files[@]}"; do
		claude_pf="$claude_skill_dir/$pf"
		codex_pf="$codex_skill_dir/$pf"
		drifted=0
		drift_reason=""
		if [[ -f "$claude_pf" && ! -f "$codex_pf" ]]; then
			drifted=1
			drift_reason="$skill/$pf present on .claude, missing on .codex"
		elif [[ ! -f "$claude_pf" && -f "$codex_pf" ]]; then
			drifted=1
			drift_reason="$skill/$pf present on .codex, missing on .claude"
		elif [[ -f "$claude_pf" && -f "$codex_pf" ]]; then
			if ! prompt_files_match "$skill" "$pf" "$claude_pf" "$codex_pf"; then
				drifted=1
				drift_reason="$skill/$pf differs between .claude and .codex"
			fi
		fi
		if [[ $drifted -eq 1 ]]; then
			full_key="$skill/$pf"
			if is_expected_drift "$full_key" "$pf"; then
				prompt_drift_expected_observed+=("$full_key")
				echo "expected lagging-mirror drift: $drift_reason (CONDUCT_LAGGING_MIRROR_OK)" >&2
			else
				prompt_drift_unknown_observed+=("$full_key")
				echo "prompt parity drift: $drift_reason" >&2
			fi
		fi
	done
done

if [[ ${#prompt_drift_unknown_observed[@]} -gt 0 ]]; then
	PARITY_DIFF=1
elif [[ ${#prompt_drift_expected_observed[@]} -gt 0 ]]; then
	# All drift is expected → annotate on stderr (already emitted above) but
	# do not flip PARITY_DIFF. Print a summary line for human consumers.
	printf 'expected lagging-mirror drift: %s (CONDUCT_LAGGING_MIRROR_OK)\n' \
		"$(printf '%s ' "${prompt_drift_expected_observed[@]}" | sed 's/ $//')" >&2
fi

# --- GENERIC FINDING SCHEMA AND MERGE block parity ---------------------
#
# The reconciliation contract block (delimited by HTML-comment markers
# inside SKILL.md) is the single point of contact between SKILL.md prose
# and `scripts/reconcile-findings.sh`. The same block content MUST exist
# byte-identically in both deep-review and review-plan, on both the
# Claude and Codex sides. Modelled on
# `scripts/check-trunk-snippet-parity.sh`'s extraction approach.

# The GENERIC block is intentionally duplicated across deep-review and
# review-plan SKILL.md (Claude + Codex = 4 copies). The duplication is
# enforced byte-identical by this parity check rather than transcluded
# from a shared file. Future divergence between deep-review and
# review-plan would require breaking this check intentionally and
# replacing it with per-skill blocks.
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

# --- scripts/reconcile-findings.sh existence + executable bit ----------
#
# The GENERIC FINDING SCHEMA AND MERGE block in every SKILL.md cites
# `scripts/reconcile-findings.sh` as the single source of truth for the
# merge rule. If the script is missing or non-executable, the prose
# contract is broken. Surface it here rather than waiting for a runtime
# failure inside `/deep-review` or `/review-plan`.

reconciler="$ROOT_DIR/scripts/reconcile-findings.sh"
if [[ ! -f "$reconciler" || ! -x "$reconciler" ]]; then
	echo "drift: scripts/reconcile-findings.sh missing or non-executable"
	PARITY_DIFF=1
fi

if [[ "$PARITY_DIFF" -eq 1 ]]; then
	echo "check-prompt-parity failed"
	exit 1
fi

echo "check-prompt-parity passed"
