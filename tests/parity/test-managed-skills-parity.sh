#!/usr/bin/env bash
# Verify the managed-skills set stays in sync across its four hardcoded copies:
#   - scripts/check-prompt-parity.sh's MANAGED_SKILLS default (bash array)
#   - tests/parity/test_skill_md_presence.py's MANAGED_SKILLS list (python)
#   - scripts/delete-skills.sh's SKEIN array (bash array, surgical-uninstall list)
#   - .env.example's explicit MANAGED_SKILLS override
#
# The lists are intentionally duplicated (test_skill_md_presence.py's own
# docstring says so) rather than one sourcing the other, because they're a bash
# default, a python literal, and a second bash array with no shared runtime.
# That is a real drift risk, not hypothetical: this test was added after
# `review-gauntlet` was found present in the python list but missing from the
# bash default (docs/dev_plans/20260711-chore-skill-invocation-mode-audit.md,
# Phase 2 Findings) — the two copies had already diverged once. The third
# source (delete-skills.sh) was folded in after a deep-review architecture
# lens found it had independently drifted the same way, undetected because
# this test didn't cover it (docs/dev_plans/20260712-feature-release-skill.md).
#
# Exit codes: 0 clean, 1 drift / extraction failure.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

SHELL_SCRIPT="$ROOT_DIR/scripts/check-prompt-parity.sh"
PYTHON_FILE="$ROOT_DIR/tests/parity/test_skill_md_presence.py"
DELETE_SCRIPT="$ROOT_DIR/scripts/delete-skills.sh"
ENV_EXAMPLE="$ROOT_DIR/.env.example"

pass_count=0
fail_count=0

fail() {
	echo "FAIL: $1"
	fail_count=$((fail_count + 1))
}

pass() {
	echo "PASS: $1"
	pass_count=$((pass_count + 1))
}

if [[ ! -f "$SHELL_SCRIPT" ]]; then
	fail "missing $SHELL_SCRIPT"
	echo ""
	echo "Summary: $pass_count passed, $fail_count failed"
	exit 1
fi

if [[ ! -f "$PYTHON_FILE" ]]; then
	fail "missing $PYTHON_FILE"
	echo ""
	echo "Summary: $pass_count passed, $fail_count failed"
	exit 1
fi

if [[ ! -f "$DELETE_SCRIPT" ]]; then
	fail "missing $DELETE_SCRIPT"
	echo ""
	echo "Summary: $pass_count passed, $fail_count failed"
	exit 1
fi

if [[ ! -f "$ENV_EXAMPLE" ]]; then
	fail "missing $ENV_EXAMPLE"
	echo ""
	echo "Summary: $pass_count passed, $fail_count failed"
	exit 1
fi

# Extract the bash default's space-separated skill list from the line:
#   MANAGED_SKILLS="${MANAGED_SKILLS:-conduct content-draft ... update-docs}"
shell_line="$(grep -E '^MANAGED_SKILLS="\$\{MANAGED_SKILLS:-' "$SHELL_SCRIPT" || true)"
if [[ -z "$shell_line" ]]; then
	fail "could not locate MANAGED_SKILLS default line in $SHELL_SCRIPT"
	echo ""
	echo "Summary: $pass_count passed, $fail_count failed"
	exit 1
fi
shell_list="$(echo "$shell_line" | sed -E 's/^MANAGED_SKILLS="\$\{MANAGED_SKILLS:-(.*)\}"$/\1/')"
if [[ -z "$shell_list" || "$shell_list" == "$shell_line" ]]; then
	fail "could not parse MANAGED_SKILLS default value out of: $shell_line"
	echo ""
	echo "Summary: $pass_count passed, $fail_count failed"
	exit 1
fi

# Extract the python list's string entries via a small python literal-eval
# (no code execution — the module is not imported, only its MANAGED_SKILLS
# assignment is parsed as an AST literal).
python_list="$(
	PYFILE="$PYTHON_FILE" python3 - <<'PY'
import ast
import os
import sys

path = os.environ["PYFILE"]
tree = ast.parse(open(path, encoding="utf-8").read(), filename=path)
for node in ast.walk(tree):
	if isinstance(node, ast.Assign) and any(
		isinstance(t, ast.Name) and t.id == "MANAGED_SKILLS" for t in node.targets
	):
		value = ast.literal_eval(node.value)
		print("\n".join(value))
		sys.exit(0)
sys.exit(1)
PY
)" || {
	fail "could not parse MANAGED_SKILLS list out of $PYTHON_FILE"
	echo ""
	echo "Summary: $pass_count passed, $fail_count failed"
	exit 1
}

# Extract delete-skills.sh's SKEIN=( ... ) array body (multi-line, unquoted
# bare words — not a single default-value line like MANAGED_SKILLS, so this
# uses a block extraction instead of the shell_line regex above).
delete_list="$(sed -n '/^SKEIN=(/,/^)/p' "$DELETE_SCRIPT" | sed '1d;$d' | tr -s ' \t' '\n' | grep -v '^$' || true)"
if [[ -z "$delete_list" ]]; then
	fail "could not locate or parse SKEIN=( ... ) array in $DELETE_SCRIPT"
	echo ""
	echo "Summary: $pass_count passed, $fail_count failed"
	exit 1
fi

env_line="$(grep -E '^MANAGED_SKILLS=' "$ENV_EXAMPLE" || true)"
env_list="${env_line#MANAGED_SKILLS=\"}"
env_list="${env_list%\"}"
if [[ -z "$env_list" || "$env_list" == "$env_line" ]]; then
	fail "could not parse MANAGED_SKILLS override out of $ENV_EXAMPLE"
	echo ""
	echo "Summary: $pass_count passed, $fail_count failed"
	exit 1
fi

shell_sorted="$(echo "$shell_list" | tr ' ' '\n' | sort -u)"
python_sorted="$(echo "$python_list" | sort -u)"
delete_sorted="$(echo "$delete_list" | sort -u)"
env_sorted="$(echo "$env_list" | tr ' ' '\n' | sort -u)"

if [[ "$shell_sorted" == "$python_sorted" ]]; then
	pass "MANAGED_SKILLS in sync: $(echo "$shell_sorted" | wc -l | tr -d ' ') skills in both $SHELL_SCRIPT and $PYTHON_FILE"
else
	fail "MANAGED_SKILLS drift between $SHELL_SCRIPT and $PYTHON_FILE"
	echo "--- only in shell default ---"
	comm -23 <(echo "$shell_sorted") <(echo "$python_sorted") || true
	echo "--- only in python list ---"
	comm -13 <(echo "$shell_sorted") <(echo "$python_sorted") || true
fi

if [[ "$shell_sorted" == "$delete_sorted" ]]; then
	pass "SKEIN in sync: $(echo "$delete_sorted" | wc -l | tr -d ' ') skills in both $SHELL_SCRIPT and $DELETE_SCRIPT"
else
	fail "SKEIN drift between $SHELL_SCRIPT and $DELETE_SCRIPT"
	echo "--- only in shell default ---"
	comm -23 <(echo "$shell_sorted") <(echo "$delete_sorted") || true
	echo "--- only in delete-skills.sh SKEIN ---"
	comm -13 <(echo "$shell_sorted") <(echo "$delete_sorted") || true
fi

if [[ "$shell_sorted" == "$env_sorted" ]]; then
	pass "MANAGED_SKILLS in sync: $(echo "$env_sorted" | wc -l | tr -d ' ') skills in both $SHELL_SCRIPT and $ENV_EXAMPLE"
else
	fail "MANAGED_SKILLS drift between $SHELL_SCRIPT and $ENV_EXAMPLE"
	echo "--- only in shell default ---"
	comm -23 <(echo "$shell_sorted") <(echo "$env_sorted") || true
	echo "--- only in .env.example override ---"
	comm -13 <(echo "$shell_sorted") <(echo "$env_sorted") || true
fi

echo ""
echo "Summary: $pass_count passed, $fail_count failed"
if [[ "$pass_count" -eq 0 && "$fail_count" -eq 0 ]]; then
	echo "FAIL: vacuous pass — no assertions ran"
	exit 1
fi
[[ "$fail_count" -eq 0 ]]
