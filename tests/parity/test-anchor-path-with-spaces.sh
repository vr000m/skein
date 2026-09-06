#!/usr/bin/env bash
# test-anchor-path-with-spaces.sh — the Claude-twin SKILL.md final state-persistence
# commands must survive a plugin root AND a repository root whose paths contain
# spaces.
#
# Why: the Claude mirror spells every bundled-script invocation through the
# `${CLAUDE_PLUGIN_ROOT}` anchor. An unquoted expansion splits a plugin install
# path containing spaces into several shell words, so the final
# `--from-collector` write in deep-review (and the review-plan state writer)
# silently fails and `.deep-review/latest-claude.json` is never updated.
#
# Covers:
#   (a) static: no operative `${CLAUDE_PLUGIN_ROOT}/skills/<skill>/scripts/<x>`
#       invocation is left unquoted in the deep-review / review-plan /
#       review-gauntlet SKILL.md (lib/ and scripts/ paths).
#   (b) runtime: the deep-review Step 5 collector -> persist pipeline, taken
#       VERBATIM from SKILL.md, runs under a plugin root and repo root with
#       spaces and writes .deep-review/latest-claude.json.
#   (c) runtime: the review-plan final state writer, taken verbatim from
#       SKILL.md up to its placeholder arguments, runs under the same roots and
#       writes .review-plan/latest-claude.json.
#
# Exit 0 on all-pass, 1 on any failure.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DR_SKILL="$REPO_ROOT/plugins/skein/skills/deep-review/SKILL.md"
RP_SKILL="$REPO_ROOT/plugins/skein/skills/review-plan/SKILL.md"

TMPDIR_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

pass_count=0
fail_count=0
pass() {
	echo "PASS: $*"
	pass_count=$((pass_count + 1))
}
fail() {
	echo "FAIL: $*"
	fail_count=$((fail_count + 1))
}

# --- (a) static: no unquoted operative anchor -------------------------------
for skill in deep-review review-plan review-gauntlet; do
	file="$REPO_ROOT/plugins/skein/skills/$skill/SKILL.md"
	# An operative invocation starts a line / follows a pipe or space and names a
	# script file. Prose mentions wrapped in backticks are not invocations.
	bad="$(grep -nE '(^|[ |])\$\{CLAUDE_PLUGIN_ROOT\}/skills/(deep-review|review-plan|review-gauntlet)/(scripts|lib)/[a-z-]+\.(sh|py)' "$file" || true)"
	if [[ -z "$bad" ]]; then
		pass "(a) $skill: every operative \${CLAUDE_PLUGIN_ROOT} invocation is quoted"
	else
		fail "(a) $skill: unquoted operative \${CLAUDE_PLUGIN_ROOT} invocation"
		printf '%s\n' "$bad" | sed 's/^/    /'
	fi
done

# --- fixture: plugin root and repo root with spaces --------------------------
PLUGIN_ROOT="$TMPDIR_ROOT/plugin root with spaces"
mkdir -p "$PLUGIN_ROOT/skills"
cp -R "$REPO_ROOT/plugins/skein/skills/deep-review" "$PLUGIN_ROOT/skills/deep-review"
cp -R "$REPO_ROOT/plugins/skein/skills/review-plan" "$PLUGIN_ROOT/skills/review-plan"

SCRATCH="$TMPDIR_ROOT/repo with spaces"
mkdir -p "$SCRATCH"
(
	cd "$SCRATCH"
	git init -q
	git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
)

# --- (b) deep-review final persist pipeline, verbatim from SKILL.md ---------
# The Step 5 block is the fenced pair of lines ending in `--from-collector`.
# Strip only the bracketed optional flags, which are documentation placeholders.
dr_cmd="$(grep -B1 -- '--from-collector$' "$DR_SKILL" | grep -v '^--$' |
	sed -E 's/ \[--attempts "<lens>:<n>" \.\.\.\] \[--running "<lens>:<n>" \.\.\.\]//')"
if [[ "$(printf '%s\n' "$dr_cmd" | wc -l | tr -d ' ')" != "2" ]]; then
	fail "(b) could not extract the deep-review Step 5 persist block from SKILL.md"
else
	RUN_ID="spaces-run"
	mkdir -p "$SCRATCH/.deep-review/lenses/$RUN_ID"
	printf '%s' '{"logic":["u1"]}' >"$SCRATCH/.deep-review/lenses/$RUN_ID/expected.json"
	if (
		cd "$SCRATCH"
		# shellcheck disable=SC2030  # intentionally scoped to this eval subshell only
		export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
		# shellcheck disable=SC2034 # consumed by the eval'd SKILL.md command line
		REPO_ROOT="$SCRATCH" BASE_COMMIT=aaa HEAD_COMMIT=bbb DIFF_HASH=ccc REVIEW_FOCUS_HASH=""
		eval "$dr_cmd"
	) >"$TMPDIR_ROOT/dr.out" 2>"$TMPDIR_ROOT/dr.err" &&
		[[ -f "$SCRATCH/.deep-review/latest-claude.json" ]] &&
		jq -e '.run_id == "spaces-run" and (.lenses | has("logic"))' "$SCRATCH/.deep-review/latest-claude.json" >/dev/null; then
		pass "(b) deep-review Step 5 pipeline writes latest-claude.json under paths with spaces"
	else
		fail "(b) deep-review Step 5 pipeline failed under paths with spaces"
		sed 's/^/    /' "$TMPDIR_ROOT/dr.err"
	fi
fi

# --- (c) review-plan final state writer, verbatim prefix from SKILL.md ------
rp_prefix="$(grep -E '^"\$\{CLAUDE_PLUGIN_ROOT\}"/skills/review-plan/scripts/persist-review-state.sh --harness claude ' "$RP_SKILL" |
	head -1 | sed -E 's/ --plan-path .*$//')"
if [[ -z "$rp_prefix" ]]; then
	fail "(c) could not extract the review-plan state-writer invocation from SKILL.md"
else
	plan="$SCRATCH/plan.md"
	printf '# plan\n' >"$plan"
	if (
		cd "$SCRATCH"
		# shellcheck disable=SC2030,SC2031  # intentionally scoped to and read within this eval subshell only
		export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
		printf '%s' '{"schema_version":2,"summary":{},"findings":[],"related":[]}' |
			eval "$rp_prefix --plan-path \"\$plan\" --plan-hash deadbeef --run-id spaces-run -"
	) >"$TMPDIR_ROOT/rp.out" 2>"$TMPDIR_ROOT/rp.err" &&
		[[ -f "$SCRATCH/.review-plan/latest-claude.json" ]] &&
		jq -e '.run_id == "spaces-run"' "$SCRATCH/.review-plan/latest-claude.json" >/dev/null; then
		pass "(c) review-plan state writer writes latest-claude.json under paths with spaces"
	else
		fail "(c) review-plan state writer failed under paths with spaces"
		sed 's/^/    /' "$TMPDIR_ROOT/rp.err"
	fi
fi

echo ""
echo "Summary: $pass_count passed, $fail_count failed"
[[ "$fail_count" -eq 0 ]]
