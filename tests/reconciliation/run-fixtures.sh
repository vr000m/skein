#!/usr/bin/env bash
# Fixture harness for scripts/reconcile-findings.sh.
#
# For each tests/reconciliation/fixtures/*.jsonl file, pipe the contents
# through scripts/reconcile-findings.sh and diff stdout against the
# corresponding tests/reconciliation/expected/*.md file.
#
# Contract: expected/*.md files are the canonical JSON output of
# scripts/reconcile-findings.sh. Rendering to the human-readable
# markdown report template lives in deep-review/review-plan SKILL.md
# Step 3.5 (orchestrator prose, not a script) and is therefore not
# exercised by this harness. The .md extension is retained for
# continuity with the Phase 2 fixtures; it does not imply the file
# contains rendered markdown.
#
# Additional invariant asserted here: shuffled-order.jsonl (input
# reversed relative to two-lens-merge.jsonl) MUST produce byte-identical
# output to two-lens-merge.md. This guards the canonical-sort contract
# inside this phase, before Phase 3's dedicated determinism harness
# lands.
#
# Exit 0 on all-pass, 1 on any mismatch.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/reconcile-findings.sh"
FIXTURES_DIR="$REPO_ROOT/tests/reconciliation/fixtures"
EXPECTED_DIR="$REPO_ROOT/tests/reconciliation/expected"

TMPDIR_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

pass_count=0
fail_count=0

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

if [[ ! -x "$SCRIPT" && ! -f "$SCRIPT" ]]; then
	echo "FAIL: preflight (scripts/reconcile-findings.sh not found at $SCRIPT)"
	echo ""
	echo "Summary: 0 passed, 1 failed"
	exit 1
fi

if [[ ! -d "$FIXTURES_DIR" ]]; then
	echo "FAIL: preflight (fixtures dir missing: $FIXTURES_DIR)"
	echo ""
	echo "Summary: 0 passed, 1 failed"
	exit 1
fi

shopt -s nullglob
fixtures=("$FIXTURES_DIR"/*.jsonl)
shopt -u nullglob

if [[ ${#fixtures[@]} -eq 0 ]]; then
	echo "FAIL: preflight (no fixtures found in $FIXTURES_DIR)"
	echo ""
	echo "Summary: 0 passed, 1 failed"
	exit 1
fi

# ---------------------------------------------------------------------------
# Per-fixture diff
# ---------------------------------------------------------------------------

for fixture in "${fixtures[@]}"; do
	name="$(basename "$fixture" .jsonl)"
	expected="$EXPECTED_DIR/${name}.md"

	if [[ "$name" == auto-fix-v2-malformed-* ]]; then
		case_dir="$(mktemp -d "$TMPDIR_ROOT/case.XXXXXX")"
		actual_file="$case_dir/actual.json"
		stderr_file="$case_dir/stderr"

		if bash "$SCRIPT" --skill deep-review <"$fixture" >"$actual_file" 2>"$stderr_file"; then
			echo "FAIL: $name (script exited zero; expected malformed auto_fix rejection)"
			fail_count=$((fail_count + 1))
			continue
		fi

		if grep -Fq "auto_fix block malformed" "$stderr_file"; then
			echo "PASS: $name (malformed auto_fix rejected clearly)"
			pass_count=$((pass_count + 1))
		else
			echo "FAIL: $name (stderr missing malformed auto_fix error)"
			echo "  stderr: $(cat "$stderr_file")"
			fail_count=$((fail_count + 1))
		fi
		continue
	fi

	if [[ ! -f "$expected" ]]; then
		echo "FAIL: $name (missing expected file: $expected)"
		fail_count=$((fail_count + 1))
		continue
	fi

	case_dir="$(mktemp -d "$TMPDIR_ROOT/case.XXXXXX")"
	actual_file="$case_dir/actual.json"
	diff_file="$case_dir/diff.txt"

	if ! bash "$SCRIPT" --skill deep-review <"$fixture" >"$actual_file" 2>"$case_dir/stderr"; then
		echo "FAIL: $name (script exited non-zero)"
		echo "  stderr: $(cat "$case_dir/stderr")"
		fail_count=$((fail_count + 1))
		continue
	fi

	if diff -u "$expected" "$actual_file" >"$diff_file"; then
		echo "PASS: $name"
		pass_count=$((pass_count + 1))
	else
		echo "FAIL: $name"
		echo "--- expected: $expected"
		echo "+++ actual"
		sed 's/^/    /' "$diff_file"
		fail_count=$((fail_count + 1))
	fi
done

# ---------------------------------------------------------------------------
# Cross-fixture invariant: shuffled-order vs two-lens-merge byte-identical
# ---------------------------------------------------------------------------

shuffled_expected="$EXPECTED_DIR/shuffled-order.md"
canonical_expected="$EXPECTED_DIR/two-lens-merge.md"

if [[ -f "$shuffled_expected" && -f "$canonical_expected" ]]; then
	if diff -q "$shuffled_expected" "$canonical_expected" >/dev/null 2>&1; then
		echo "PASS: shuffled-order-matches-two-lens-merge (canonical sort invariant)"
		pass_count=$((pass_count + 1))
	else
		echo "FAIL: shuffled-order-matches-two-lens-merge"
		echo "  Expected fixtures shuffled-order.md and two-lens-merge.md to be byte-identical."
		diff -u "$canonical_expected" "$shuffled_expected" | sed 's/^/    /' || true
		fail_count=$((fail_count + 1))
	fi
fi

# ---------------------------------------------------------------------------
# Final tally
# ---------------------------------------------------------------------------

echo ""
echo "Summary: $pass_count passed, $fail_count failed"

if [[ $fail_count -ne 0 ]]; then
	exit 1
fi
exit 0
