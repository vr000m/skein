#!/usr/bin/env bash
# Determinism harness for scripts/reconcile-findings.sh.
#
# Contract under test (from
# docs/dev_plans/20260508-feature-cross-lens-finding-reconciliation.md,
# Review Focus #2 -- canonical-ordering invariant):
#
#   Identical lens-output strings, in any arrival order, MUST produce
#   byte-identical reconciled output. The output sort key is
#   severity -> category -> file -> line -> sorted lenses.
#
# Method:
#   For each tests/reconciliation/fixtures/*.jsonl file, run the
#   reconciler 5 times with the input lines shuffled (shuf / gshuf)
#   on each run. Capture each run's stdout. Assert:
#     1. All 5 shuffled runs produce byte-identical output.
#     2. That byte-identical output also matches
#        tests/reconciliation/expected/<basename>.md (so determinism
#        is anchored to the canonical expected file -- it is not enough
#        for the runs to merely agree with each other).
#
# Trivial inputs:
#   Fixtures with 0 or 1 lines permute trivially to themselves and
#   carry no shuffling signal. They are reported as "trivial-skip"
#   in the summary rather than counted as PASS or FAIL.
#
# Shuffle implementation:
#   GNU `shuf` if available, then `gshuf` (Homebrew coreutils), else a
#   portable awk+sort shuffler keyed on `awk rand()` seeded from `$RANDOM`
#   and the run index. The portable fallback works on stock macOS without
#   any extra install.
#
# Exit 0 on all-pass, 1 on any failure (including tooling preflight).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/reconcile-findings.sh"
FIXTURES_DIR="$REPO_ROOT/tests/reconciliation/fixtures"
EXPECTED_DIR="$REPO_ROOT/tests/reconciliation/expected"

TMPDIR_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

pass_count=0
fail_count=0
skip_count=0

# ---------------------------------------------------------------------------
# Preflight: locate a shuffler.
#   Prefer GNU shuf, then gshuf (Homebrew coreutils), else fall back
#   to a portable awk+sort shuffler. The fallback works on stock macOS.
# ---------------------------------------------------------------------------

SHUF_MODE=""
if command -v shuf >/dev/null 2>&1; then
	SHUF_MODE="shuf"
elif command -v gshuf >/dev/null 2>&1; then
	SHUF_MODE="gshuf"
else
	SHUF_MODE="portable"
fi

# shuffle_file SRC DST RUN_INDEX
#   Shuffle SRC into DST. RUN_INDEX (an integer) seeds the portable fallback
#   so each of the SHUFFLE_RUNS invocations produces a distinct permutation.
shuffle_file() {
	local src="$1" dst="$2" idx="$3"
	case "$SHUF_MODE" in
	shuf | gshuf)
		"$SHUF_MODE" "$src" >"$dst"
		;;
	portable)
		# Seed awk with bash's $RANDOM xor'd with the run index so seeds
		# are unique within the run AND across reruns of the harness.
		local seed=$(((RANDOM << 8) ^ idx ^ $$))
		awk -v seed="$seed" 'BEGIN{srand(seed)} {print rand() "\t" $0}' "$src" |
			sort -k1,1n |
			cut -f2- >"$dst"
		;;
	esac
}

if [[ ! -f "$SCRIPT" ]]; then
	echo "FAIL: preflight (scripts/reconcile-findings.sh not found at $SCRIPT)"
	echo ""
	echo "Summary: 0 passed, 1 failed, 0 trivial-skip"
	exit 1
fi

if [[ ! -d "$FIXTURES_DIR" ]]; then
	echo "FAIL: preflight (fixtures dir missing: $FIXTURES_DIR)"
	echo ""
	echo "Summary: 0 passed, 1 failed, 0 trivial-skip"
	exit 1
fi

shopt -s nullglob
fixtures=("$FIXTURES_DIR"/*.jsonl)
shopt -u nullglob

if [[ ${#fixtures[@]} -eq 0 ]]; then
	echo "FAIL: preflight (no fixtures found in $FIXTURES_DIR)"
	echo ""
	echo "Summary: 0 passed, 1 failed, 0 trivial-skip"
	exit 1
fi

# ---------------------------------------------------------------------------
# Per-fixture determinism check.
# ---------------------------------------------------------------------------

SHUFFLE_RUNS=5

for fixture in "${fixtures[@]}"; do
	name="$(basename "$fixture" .jsonl)"
	expected="$EXPECTED_DIR/${name}.md"

	# Count non-empty lines. Inputs with 0 or 1 lines permute to themselves.
	line_count="$(grep -c '.' "$fixture" 2>/dev/null || true)"
	line_count="${line_count:-0}"

	if [[ "$line_count" -le 1 ]]; then
		echo "SKIP: $name (trivial-skip: $line_count line(s), no permutation signal)"
		skip_count=$((skip_count + 1))
		continue
	fi

	if [[ ! -f "$expected" ]]; then
		echo "FAIL: $name (missing expected file: $expected)"
		fail_count=$((fail_count + 1))
		continue
	fi

	case_dir="$(mktemp -d "$TMPDIR_ROOT/case.XXXXXX")"
	failed_this_case=0

	for i in $(seq 1 "$SHUFFLE_RUNS"); do
		shuffled_input="$case_dir/shuffled.$i.jsonl"
		run_output="$case_dir/run.$i.out"
		run_stderr="$case_dir/run.$i.err"

		if ! shuffle_file "$fixture" "$shuffled_input" "$i" 2>"$run_stderr"; then
			echo "FAIL: $name (shuffle run $i failed)"
			echo "  stderr: $(cat "$run_stderr")"
			failed_this_case=1
			break
		fi

		if ! bash "$SCRIPT" <"$shuffled_input" >"$run_output" 2>"$run_stderr"; then
			echo "FAIL: $name (script exited non-zero on shuffle run $i)"
			echo "  stderr: $(cat "$run_stderr")"
			failed_this_case=1
			break
		fi
	done

	if [[ "$failed_this_case" -ne 0 ]]; then
		fail_count=$((fail_count + 1))
		continue
	fi

	# Check 1: all SHUFFLE_RUNS outputs are byte-identical to each other.
	pairwise_ok=1
	first_output="$case_dir/run.1.out"
	for i in $(seq 2 "$SHUFFLE_RUNS"); do
		other_output="$case_dir/run.$i.out"
		if ! diff -q "$first_output" "$other_output" >/dev/null 2>&1; then
			echo "FAIL: $name (shuffle run 1 vs run $i differ -- non-deterministic)"
			diff -u "$first_output" "$other_output" | sed 's/^/    /' || true
			pairwise_ok=0
			break
		fi
	done

	if [[ "$pairwise_ok" -ne 1 ]]; then
		fail_count=$((fail_count + 1))
		continue
	fi

	# Check 2: that byte-identical output matches the canonical expected file.
	if ! diff -q "$expected" "$first_output" >/dev/null 2>&1; then
		echo "FAIL: $name (deterministic across shuffles, but does not match expected)"
		echo "--- expected: $expected"
		echo "+++ actual (shuffle run 1, byte-identical to runs 2..$SHUFFLE_RUNS)"
		diff -u "$expected" "$first_output" | sed 's/^/    /' || true
		fail_count=$((fail_count + 1))
		continue
	fi

	echo "PASS: $name (${SHUFFLE_RUNS} shuffles byte-identical, matches expected)"
	pass_count=$((pass_count + 1))
done

# ---------------------------------------------------------------------------
# Final tally
# ---------------------------------------------------------------------------

echo ""
echo "Summary: $pass_count passed, $fail_count failed, $skip_count trivial-skip"

if [[ $fail_count -ne 0 ]]; then
	exit 1
fi
exit 0
