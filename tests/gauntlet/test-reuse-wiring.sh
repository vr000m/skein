#!/usr/bin/env bash
# test-reuse-wiring.sh — Phase 2 acceptance: run-gate.sh / convergence-ledger.sh
# / lib/gauntlet-common.sh reuse the *existing* shared script bundle
# (reconciler + appliers) rather than forking it.
#
# Plan: docs/dev_plans/20260707-feature-review-gauntlet-skill.md, Phase 2
# "Gate-runner + convergence bundled scripts (Claude)", Review Focus
# "Reuse integrity" and Testing Notes "Reuse wiring".
#
# These are static/grep-level assertions over the three implementation
# scripts (no runtime execution) — the shape-level counterpart to the
# convergence-ledger.sh behavioural suite. Bundling into BUNDLE_SKILLS
# (scripts/lib/bundle-map.sh) and the byte-parity tests are Phase 6 concerns
# and are intentionally out of scope here.
#
# Exit codes: 0 all assertions pass, 1 any assertion fails.

set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
GAUNTLET_LIB_DIR="$ROOT_DIR/plugins/skein/skills/review-gauntlet/lib"
RUN_GATE="$GAUNTLET_LIB_DIR/run-gate.sh"
LEDGER="$GAUNTLET_LIB_DIR/convergence-ledger.sh"
COMMON="$GAUNTLET_LIB_DIR/gauntlet-common.sh"

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

# extract_function FILE NAME — prints the body of a `NAME() {` ... `}` bash
# function (first match, closing brace alone on its own line), for targeted
# assertions without depending on a fixed line-count window.
extract_function() {
	local file="$1" name="$2"
	awk -v n="$name" '
		$0 ~ "^" n "\\(\\) \\{" { flag = 1; print; next }
		flag && /^}/ { print; exit }
		flag { print }
	' "$file"
}

# code_lines FILE — strips comment-only lines (first non-whitespace char is
# `#`) so grep-based assertions about actual invocations are not tripped by
# prose/comments that merely *mention* a forbidden pattern (this script's
# header comments and run-gate.sh's own doc-comments deliberately describe
# what NOT to do, e.g. "never ../../deep-review/scripts", "invoked WITHOUT
# --skill" — those must not themselves count as violations).
code_lines() {
	local file="$1"
	grep -Ev '^[[:space:]]*#' "$file"
}

# assert_grep FILE PATTERN LABEL — whole-file grep (comments count; used for
# checks where the assertion is about documentation/anchors, not "does the
# forbidden fork actually run").
assert_grep() {
	local file="$1" pattern="$2" label="$3"
	if grep -Eq -- "$pattern" "$file"; then
		pass "$label"
	else
		fail "$label (pattern not found: $pattern in $file)"
	fi
}

# assert_not_grep_in_code FILE PATTERN LABEL — asserts PATTERN is absent from
# the file's non-comment (code) lines specifically, so a negative-example
# mention in a comment doesn't cause a false failure.
assert_not_grep_in_code() {
	local file="$1" pattern="$2" label="$3"
	if code_lines "$file" | grep -Eq -- "$pattern"; then
		fail "$label (forbidden pattern found in CODE, not just comments: $pattern in $file)"
	else
		pass "$label"
	fi
}

# assert_not_used_as_path FILE PATTERN LABEL — asserts PATTERN never appears
# as part of an actual path resolution (variable assignment / cd / source
# target) on a non-comment line. Diagnostic `echo`/`printf` strings that
# merely *name* the forbidden path in a "never fall back to X" error message
# are not themselves a fork and must not trip this check (gauntlet-common.sh
# legitimately prints that path in its abort message).
assert_not_used_as_path() {
	local file="$1" pattern="$2" label="$3"
	if code_lines "$file" | grep -Ev '\becho\b|\bprintf\b' | grep -Eq -- "$pattern"; then
		fail "$label (forbidden pattern found used as an actual path, not just in a diagnostic message: $pattern in $file)"
	else
		pass "$label"
	fi
}

require_file "$RUN_GATE" || exit 1
require_file "$LEDGER" || exit 1
require_file "$COMMON" || exit 1

# --- Bundled-dir resolution anchors via ${CLAUDE_PLUGIN_ROOT}, never a ---
# --- relative-parent path into ../../deep-review/scripts -----------------

assert_grep "$COMMON" '\$\{CLAUDE_PLUGIN_ROOT\}' \
	"gauntlet-common.sh resolves the bundled scripts dir via \${CLAUDE_PLUGIN_ROOT} anchor"

assert_not_grep_in_code "$RUN_GATE" '\.\./\.\./deep-review/scripts' \
	"run-gate.sh's actual code never references ../../deep-review/scripts (only its doc-comments describe this as forbidden)"

assert_not_used_as_path "$COMMON" '\.\./\.\./deep-review/scripts' \
	"gauntlet-common.sh never resolves a bundled path via ../../deep-review/scripts (the string appears only in its own abort/diagnostic message, not as an actual fallback path)"

assert_not_grep_in_code "$LEDGER" '\.\./\.\./deep-review/scripts' \
	"convergence-ledger.sh's actual code never references ../../deep-review/scripts"

# --- Reconciler invoked WITHOUT --skill -----------------------------------
# The actual invocation is via a resolved variable ("$reconciler"), not the
# literal basename, so assert directly on the invocation line rather than
# grepping for the literal "reconcile-findings.sh ... --skill" pair (which
# would never match real code and would vacuously pass). Model on
# test-gauntlet-skill-shape.sh's forbidden-pattern phrasing, but scoped to
# code lines only since run-gate.sh's own doc-comments legitimately discuss
# "--skill" (e.g. "the reconciler requires --skill only when auto_fix is
# present", "invoked WITHOUT --skill") without that being a violation.

assert_grep "$RUN_GATE" 'gc_bundled_script reconcile-findings\.sh' \
	"run-gate.sh resolves reconcile-findings.sh via the bundled-script helper (not a hand-copied fork)"

if code_lines "$RUN_GATE" | grep -E '\$\{?reconciler\}?' | grep -Eq -- '--skill'; then
	fail "run-gate.sh's reconciler invocation line carries --skill (forbidden: it rejects any skill other than deep-review/review-plan)"
else
	pass "run-gate.sh's reconciler invocation line does not carry --skill"
fi

# --- auto_fix stripped before the reconcile stage -------------------------

assert_grep "$COMMON" 'gc_normalize_finding' \
	"gauntlet-common.sh defines the finding-normalization helper used to strip auto_fix before reconcile"

if code_lines "$COMMON" | grep -A8 'gc_normalize_finding()' | grep -q 'auto_fix'; then
	fail "gc_normalize_finding's emitted schema still includes an auto_fix key (should be stripped, not passed through)"
else
	pass "gc_normalize_finding's emitted schema omits auto_fix (findings reaching reconcile are auto_fix-free)"
fi

assert_grep "$RUN_GATE" 'gc_normalize_finding' \
	"run-gate.sh's normalize command routes findings through gc_normalize_finding before pooling for reconcile"

# --- No duplicated allowlist logic: reference the bundled appliers, don't -
# --- re-list the allowlist categories as an inline decision table ---------

assert_grep "$RUN_GATE" 'gc_bundled_script audit-auto-fix-eligibility\.sh' \
	"run-gate.sh delegates eligibility classification to the bundled audit-auto-fix-eligibility.sh"

for category in docstring_typo unused_import unused_var mechanical_replace import_sort; do
	if code_lines "$RUN_GATE" | grep -Fq -- "$category"; then
		fail "run-gate.sh re-lists allowlist category '$category' inline (duplicated allowlist logic instead of delegating to audit-auto-fix-eligibility.sh)"
	else
		pass "run-gate.sh does not re-list allowlist category '$category' inline"
	fi
done

# apply-auto-fix-code.sh is referenced (by name, in the documented contract)
# even though this Phase's run-gate.sh only performs the `route`
# classification step — the actual apply is documented as the caller's next
# step onto the bundled applier, never a reimplementation.
assert_grep "$RUN_GATE" 'apply-auto-fix-code\.sh' \
	"run-gate.sh references the bundled apply-auto-fix-code.sh as the trivial-fix applier (not reimplemented)"

# --- gauntlet-common.sh aborts (never silently falls back) when the ------
# --- bundled dir/script is absent -----------------------------------------

assert_grep "$COMMON" 'never falling back to a hand copy' \
	"gauntlet-common.sh documents that it never falls back to a hand copy when the bundled dir is missing"

if extract_function "$COMMON" "gc_bundled_scripts_dir" | grep -q 'return 3'; then
	pass "gc_bundled_scripts_dir aborts with a non-zero return when the bundled dir is absent"
else
	fail "gc_bundled_scripts_dir does not appear to abort (expected a non-zero 'return' guarded by a directory-existence check)"
fi

if extract_function "$COMMON" "gc_bundled_script" | grep -q 'return 3'; then
	pass "gc_bundled_script aborts with a non-zero return when the bundled script/asset is absent"
else
	fail "gc_bundled_script does not appear to abort (expected a non-zero 'return' guarded by a file-existence check)"
fi

# Behavioural corroboration of the abort contract: sourcing gauntlet-common.sh
# with CLAUDE_PLUGIN_ROOT pointed at a directory that has no
# review-gauntlet/scripts subdirectory must fail closed, not silently print a
# fallback path.
fake_root="$(mktemp -d)"
trap 'rm -rf "$fake_root"' EXIT
if (
	set +e
	export CLAUDE_PLUGIN_ROOT="$fake_root"
	# shellcheck disable=SC1090
	source "$COMMON"
	gc_bundled_scripts_dir >/dev/null 2>&1
); then
	fail "gc_bundled_scripts_dir returned success against a CLAUDE_PLUGIN_ROOT with no bundled scripts dir (expected abort)"
else
	pass "gc_bundled_scripts_dir fails closed (non-zero) when CLAUDE_PLUGIN_ROOT has no review-gauntlet/scripts dir"
fi

# --- shebang + set -euo pipefail on the executable scripts ---------------

for f in "$RUN_GATE" "$LEDGER" "$COMMON"; do
	name="$(basename "$f")"
	if head -n1 "$f" | grep -Eq '^#!.*\b(bash|sh)\b'; then
		pass "$name has a bash/sh shebang"
	else
		fail "$name is missing a bash/sh shebang on line 1"
	fi

	if grep -Eq '^set -euo pipefail$' "$f"; then
		pass "$name declares 'set -euo pipefail'"
	else
		fail "$name is missing 'set -euo pipefail'"
	fi
done

for f in "$RUN_GATE" "$LEDGER"; do
	name="$(basename "$f")"
	if [[ -x "$f" ]]; then
		pass "$name is executable"
	else
		fail "$name is not executable (chmod +x expected on a directly-invoked script)"
	fi
done

echo ""
echo "Results: $pass_count passed, $fail_count failed"

if [[ "$fail_count" -gt 0 ]]; then
	exit 1
fi

exit 0
