#!/usr/bin/env bash
# check-prompt-parity.sh
#
# Verify that prompt-contract artefacts (currently `rubric.md`) are
# byte-identical between `plugins/skein/skills/<skill>/` and
# `plugins/skein-codex/skills/<skill>/` for every entry in MANAGED_SKILLS.
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

MANAGED_SKILLS="${MANAGED_SKILLS:-conduct content-draft content-review deep-review dev-plan fan-out plan-view review-plan rfc-finder spec-compliance update-docs}"

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

	claude_rubric="$ROOT_DIR/plugins/skein/skills/$skill/rubric.md"
	codex_rubric="$ROOT_DIR/plugins/skein-codex/skills/$skill/rubric.md"

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
# `plugins/skein/skills/<skill>/` and `plugins/skein-codex/skills/<skill>/`.
#
# Note (20260707-feature-conduct-phase-goal-field, Phase 3): the new
# `{{PHASE_GOAL}}` placeholder added to conduct's implementer-prompt.md and
# test-writer-prompt.md needs no dedicated assertion here — it is already
# within scope of the wholesale per-skill diff below. Until the Codex mirror
# phases (C1/C2) land, expect drift on conduct/implementer-prompt.md and
# conduct/test-writer-prompt.md; set CONDUCT_LAGGING_MIRROR_OK to acknowledge
# it during that lagging-mirror window.
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
	done
	return 1
}

# fan-out R6 idiom-divergence normalizer.
#
# The R6 clean-context test-writer graft (see
# docs/dev_plans/20260704-chore-model-effort-explicit-spawns.md, R4) makes
# fan-out/agent-prompt.md and fan-out/test-writer-prompt.md diverge between the
# .claude and .codex mirrors ONLY inside four harness-divergent spans:
#   - the R6 design/status block (Claude `model:`/`effort:` + `Agent`-in-
#     `claude -p` vs Codex `reasoning_effort`/`fork_context=false` + `spawn_agent`
#     in a `codex exec` worker), carried as an HTML comment in agent-prompt.md and
#     as a "Status note (read first)" paragraph in test-writer-prompt.md;
#   - the Phase-2 "If your task has an applicable test framework" directive, which
#     now diverges by CONFIRMED-LIVE status too, not just idiom: the Claude gate
#     passed (2026-07-04, see fan-out/tests/check-r6-gate.sh) so the Claude worker
#     spawns a separate clean-context test-writer, while the Codex worker keeps the
#     single-context fallback (its gate is still unconfirmed); and
#   - the anti-cheat-rule paragraph (same rule, harness-tuned wording).
# This divergence is sanctioned per R4 / CODEX_MIRROR_BACKLOG.md:15 (idiom, not
# drift). This normalizer excises exactly those spans between stable structural
# anchors and byte-compares the entire remainder, so any real (non-idiom) drift
# elsewhere in the files is still caught.
#
# The excised spans are NOT left unguarded: tests/parity/test-spawn-tiers.sh
# guards the test-writer *tier* annotation, the R6 anti-cheat "contract wins"
# rule, and the presence of the excision anchors themselves (`### Phase 5`,
# `Filled by the fan-out worker`) in BOTH mirrors — so a dropped anchor or a
# weakened anti-cheat rule fails the census even though byte-parity here would
# still pass. Deeper R4 semantic alignment of the span wording is the plan's
# Phase 6 manual enumeration.
normalize_fanout_prompt() {
	sed \
		-e 's/spawned Claude agent/spawned Codex agent/g' \
		-e 's/{{CLAUDE_MD_CONTENT}}/{{AGENTS_MD_CONTENT}}/g' \
		"$1" \
		| perl -0pe 's/^<!--\n(?:R6 status:|INTENDED DESIGN \(currently GATED, not active\):).*?^-->\n//msg; s/Filled by the fan-out worker before spawning the test-writer \(once the nested-spawn\ngate is confirmed\)\. The filled prompt is passed as the full subagent input — the\nsubagent has no prior conversation history and never receives the worker'\''s diff\./Filled by the fan-out worker before spawning the test-writer. The filled prompt is\npassed as the full subagent input — the subagent has no prior conversation history\nand never receives the worker'\''s diff./msg' \
		| sed \
			-e '/^If your task has an applicable test framework/,/^If no relevant test framework exists/{/^If no relevant test framework exists/!d;}' \
			-e '/^\*\*Anti-cheat rule/,/^### Phase 5/{/^### Phase 5/!d;}' \
			-e '/^Anti-cheat rule/,/^### Phase 5/{/^### Phase 5/!d;}' \
			-e '/\*\*Status note (read first):\*\*/,/^Filled by the fan-out worker/{/^Filled by the fan-out worker/!d;}'
}

prompt_files_match() {
	local skill="$1"
	local prompt_file="$2"
	local claude_file="$3"
	local codex_file="$4"
	case "$skill/$prompt_file" in
	fan-out/agent-prompt.md | fan-out/test-writer-prompt.md)
		diff -q \
			<(normalize_fanout_prompt "$claude_file") \
			<(normalize_fanout_prompt "$codex_file") >/dev/null 2>&1
		return
		;;
	esac
	diff -q "$claude_file" "$codex_file" >/dev/null 2>&1
}

declare -a prompt_drift_expected_observed=()
declare -a prompt_drift_unknown_observed=()

for skill in "${managed_skills[@]}"; do
	if [[ ! "$skill" =~ ^[A-Za-z0-9_-]+$ ]]; then
		# Already reported in the rubric loop; skip silently here.
		continue
	fi
	claude_skill_dir="$ROOT_DIR/plugins/skein/skills/$skill"
	codex_skill_dir="$ROOT_DIR/plugins/skein-codex/skills/$skill"
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
			if is_expected_drift "$full_key"; then
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
	"$ROOT_DIR/plugins/skein/skills/deep-review/SKILL.md"
	"$ROOT_DIR/plugins/skein/skills/review-plan/SKILL.md"
	"$ROOT_DIR/plugins/skein-codex/skills/deep-review/SKILL.md"
	"$ROOT_DIR/plugins/skein-codex/skills/review-plan/SKILL.md"
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

# --- auto-fix allowlist citations -------------------------------------
#
# scripts/auto-fix-allowlist.json is the single source of truth for
# trivial auto-fix kinds. The compact JSON arrays must be cited verbatim
# inside every SKILL.md mirror that shares the GENERIC finding contract.

allowlist_json="$ROOT_DIR/scripts/auto-fix-allowlist.json"
if [[ ! -f "$allowlist_json" ]]; then
	echo "drift: scripts/auto-fix-allowlist.json missing"
	PARITY_DIFF=1
else
	# Use jq for structural extraction (compact, sorted-key-stable). The
	# previous sed approach silently truncated if any kind string ever
	# contained a `]` and created a second parser for the same JSON file
	# (the tests/parity/test-allowlist-byte-identity.sh check uses Python's
	# json.load — having jq here keeps both parsers semantic).
	if ! command -v jq >/dev/null 2>&1; then
		echo "warn: jq not available — skipping allowlist byte-identity citation check"
		deep_review_allowlist=""
		review_plan_allowlist=""
	else
		deep_review_allowlist="$(jq -c '."deep-review"' "$allowlist_json")"
		review_plan_allowlist="$(jq -c '."review-plan"' "$allowlist_json")"
	fi
	if [[ -n "$deep_review_allowlist" && ("$deep_review_allowlist" == "null" || "$review_plan_allowlist" == "null") ]]; then
		echo "drift: scripts/auto-fix-allowlist.json missing deep-review or review-plan key"
		PARITY_DIFF=1
	elif [[ -z "$deep_review_allowlist" ]]; then
		: # jq unavailable; citation check skipped above
	else
		for path in "${GENERIC_TARGETS[@]}"; do
			if [[ ! -f "$path" ]]; then
				continue
			fi
			if ! grep -Fq "$deep_review_allowlist" "$path"; then
				echo "drift: deep-review auto-fix allowlist not cited verbatim in $path"
				PARITY_DIFF=1
			fi
			if ! grep -Fq "$review_plan_allowlist" "$path"; then
				echo "drift: review-plan auto-fix allowlist not cited verbatim in $path"
				PARITY_DIFF=1
			fi
		done
	fi
fi

# --- content-review references parity ---------------------------------
#
# The content-review skill ships shared style guidelines under
# `references/`. Pre-migration, `check-sync.sh` axis (a) compared the
# `.codex` canonical against the `.claude` mirror; that axis was deleted
# when the install flow moved to plugin marketplaces. Keep the cross-
# mirror byte-identity guard here so a future edit to one side cannot
# silently drift without tripping `just check-prompt-parity`.

cr_claude="$ROOT_DIR/plugins/skein/skills/content-review/references"
cr_codex="$ROOT_DIR/plugins/skein-codex/skills/content-review/references"
if [[ -d "$cr_claude" || -d "$cr_codex" ]]; then
	if ! diff -r "$cr_claude" "$cr_codex" >/dev/null 2>&1; then
		echo "drift: content-review/references differs between .claude and .codex mirrors"
		diff -r "$cr_claude" "$cr_codex" || true
		PARITY_DIFF=1
	fi
fi

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
