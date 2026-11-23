#!/usr/bin/env bash
# Comment-policy brief test: the shared comment rule reaches the conduct
# implementer and test-writer templates, stays outside every warned data block,
# leaves each template's terminal JSON report untouched, and changes the
# no-goal rendering only by the planned additions.
#
# Usage: test-comment-policy-briefs.sh [--mirror claude|codex|both]   (default both)
#
# The no-goal rendering is compared with the committed pre-change templates in
# tests/gauntlet/fixtures/conduct-templates/. A git-ref baseline would be empty
# once the branch merges, so the baseline is a fixture.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

mirror="both"
if [[ "${1:-}" == "--mirror" ]]; then
	mirror="${2:-}"
fi
case "$mirror" in
claude | codex | both) ;;
*)
	echo "usage: ${0##*/} [--mirror claude|codex|both]" >&2
	exit 2
	;;
esac

PASS_COUNT=0
FAIL_COUNT=0

pass() {
	PASS_COUNT=$((PASS_COUNT + 1))
	echo "ok: $1"
}

fail() {
	FAIL_COUNT=$((FAIL_COUNT + 1))
	echo "FAIL: $1" >&2
}

# Shared key phrases (defined once in the plan; asserted wherever the rule lives).
KEY_PHRASES=(
	"non-obvious why"
	"restates the code"
	"excuses a hack"
	"docstrings"
	"linter and type pragmas"
	"license headers"
	"TODOs that link an issue"
	"inside a hunk or function the change already touches"
)

assert_phrases() {
	local label="$1" file="$2" phrase
	for phrase in "${KEY_PHRASES[@]}"; do
		if grep -q -F -- "$phrase" "$file"; then
			pass "$label carries '$phrase'"
		else
			fail "$label missing '$phrase'"
		fi
	done
}

# render_template <file>: the dispatched Template block (the outer fence after
# '## Template'), with {{PHASE_GOAL}} replaced by the empty string.
render_template() {
	awk '
		/^## Template$/ { seen = 1; next }
		seen && !started && /^```$/ { started = 1; next }
		started { lines[++n] = $0 }
		END { for (i = 1; i < n; i++) print lines[i] }
	' "$1" | sed 's/{{PHASE_GOAL}}//g'
}

# comments_outside_data <file>: the Comments heading must sit outside every
# <untrusted-content> block.
comments_outside_data() {
	awk '
		/^<untrusted-content>$/ { depth++ }
		/^<\/untrusted-content>$/ { depth-- }
		/^## Comments$/ { found = 1; bad = (depth > 0) }
		END { exit (found && !bad) ? 0 : 1 }
	' "$1"
}

# AGENTS.md carries the policy block (mirror-independent).
assert_phrases "AGENTS.md" AGENTS.md

check_mirror() {
	local m="$1" dir
	case "$m" in
	claude) dir="plugins/skein/skills/conduct" ;;
	codex) dir="plugins/skein-codex/skills/conduct" ;;
	esac
	local role file fixture rendered_new rendered_old out diff_rc
	for role in implementer test-writer; do
		file="$dir/$role-prompt.md"
		fixture="tests/gauntlet/fixtures/conduct-templates/$role-prompt.md"
		assert_phrases "$m $role template" "$file"
		if comments_outside_data "$file"; then
			pass "$m $role Comments section sits outside warned data blocks"
		else
			fail "$m $role Comments section missing or inside a warned data block"
		fi
		if grep -q 'Add no new report keys' "$file"; then
			pass "$m $role handback guidance adds no report keys"
		else
			fail "$m $role handback guidance missing"
		fi
		case "$role" in
		implementer) key='"summary":' ;;
		*) key='"coverage_summary":' ;;
		esac
		if grep -q -F -- "$key" "$file"; then
			pass "$m $role keeps terminal JSON key $key"
		else
			fail "$m $role lost terminal JSON key $key"
		fi

		# No-goal rendering: only added lines, all belonging to the planned additions.
		rendered_old="$(render_template "$fixture")"
		rendered_new="$(render_template "$file")"
		diff_rc=0
		out="$(diff <(printf '%s\n' "$rendered_old") <(printf '%s\n' "$rendered_new"))" || diff_rc=$?
		if [[ "$diff_rc" -gt 1 ]]; then
			fail "$m $role no-goal rendering comparison did not run (diff exit $diff_rc)"
		elif grep -q '^<' <<<"$out"; then
			fail "$m $role no-goal rendering removes or rewrites existing lines"
		else
			local stray
			stray="$(grep '^>' <<<"$out" | sed 's/^> \{0,1\}//' |
				grep -v -e '^$' -e '^## Comments$' -e '^Comment only a non-obvious why' -e '^- If you leave an excuse comment' || true)"
			if [[ -z "$stray" ]]; then
				pass "$m $role no-goal rendering differs only by the Comments paragraph and handback sentence"
			else
				fail "$m $role no-goal rendering has unplanned additions: $stray"
			fi
		fi
	done

	if grep -q 'Comment notices' "$dir/SKILL.md" &&
		grep -q 'Excuse:' "$dir/SKILL.md" &&
		grep -q 'Decision candidate:' "$dir/SKILL.md"; then
		pass "$m SKILL.md handback path surfaces comment notices"
	else
		fail "$m SKILL.md handback path missing comment notices guidance"
	fi
}

case "$mirror" in
claude) check_mirror claude ;;
codex) check_mirror codex ;;
both)
	check_mirror claude
	check_mirror codex
	for role in implementer test-writer; do
		if cmp -s "plugins/skein/skills/conduct/$role-prompt.md" "plugins/skein-codex/skills/conduct/$role-prompt.md"; then
			pass "$role template is byte-identical across Claude and Codex"
		else
			fail "$role template differs between Claude and Codex"
		fi
	done
	;;
esac

echo "---"
echo "passed: $PASS_COUNT failed: $FAIL_COUNT"
[[ "$FAIL_COUNT" -eq 0 ]]
