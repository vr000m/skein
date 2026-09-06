#!/usr/bin/env bash
# Guards the Codex review-gauntlet convergence contract: permanent capability
# gaps stay honest in the report but do not keep --unresolved above zero.

set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
SKILL_MD="$ROOT_DIR/plugins/skein-codex/skills/review-gauntlet/SKILL.md"

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

assert_grep() {
	local file="$1" pattern="$2" label="$3"
	if grep -Eq -- "$pattern" "$file"; then
		pass "$label"
	else
		fail "$label (pattern not found: $pattern in $file)"
	fi
}

assert_not_grep() {
	local file="$1" pattern="$2" label="$3"
	if grep -Eq -- "$pattern" "$file"; then
		fail "$label (forbidden pattern found: $pattern in $file)"
	else
		pass "$label"
	fi
}

if [[ ! -f "$SKILL_MD" ]]; then
	fail "file missing: $SKILL_MD"
	echo ""
	echo "Results: $pass_count passed, $fail_count failed"
	exit 1
fi

assert_grep "$SKILL_MD" 'Security-review gate.*permanent capability gap' \
	"security-review slot is documented as a permanent capability gap"

assert_grep "$SKILL_MD" 'skein:deep-review.*permanent capability gap for the current topology evidence' \
	"deep-review slot is documented as permanent while topology evidence is unconfirmed"

assert_grep "$SKILL_MD" 'error` always counts as unresolved' \
	"errors always count toward --unresolved"

assert_grep "$SKILL_MD" 'known permanent capability gaps do not count' \
	"permanent capability gaps are excluded from --unresolved"

assert_grep "$SKILL_MD" 'gate 4.*security-review.*always.*gate 3.*skein:deep-review.*nested-spawn topology/tier evidence remains unconfirmed' \
	"the permanent deferred gate list names gate 4 always and gate 3 while nested-spawn evidence is unconfirmed"

# shellcheck disable=SC2016  # literal grep/regex pattern text, not shell expansion
assert_grep "$SKILL_MD" 'full pass at count 0 with `--unresolved 0` may resolve to success even when those permanent gaps are present' \
	"clean Codex pass can succeed with only permanent capability gaps present"

assert_grep "$SKILL_MD" 'terminal report must distinguish "ran and passed" from "deferred \(permanent capability gap\)"' \
	"terminal report must honestly distinguish native passes from permanent gaps"

assert_grep "$SKILL_MD" 'Permanent capability gaps are omitted from that integer and listed in the terminal report' \
	"failure-handling section keeps permanent gaps out of the ledger integer"

assert_not_grep "$SKILL_MD" 'every gate produced a clean review this round' \
	"Codex convergence no longer requires every logical slot to run cleanly"

echo ""
echo "Results: $pass_count passed, $fail_count failed"

if [[ "$fail_count" -gt 0 ]]; then
	exit 1
fi

exit 0
