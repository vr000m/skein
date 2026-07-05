#!/usr/bin/env bash
# run-seeded-divergence.sh — R6 gating fixture (DIRECT MODE).
#
# DIRECT MODE, not a real fan-out/nested-spawn run: the Phase-5 live gate could
# not confirm that a non-interactive `codex exec` worker can initialize its
# in-process app-server client and spawn a nested `spawn_agent` test-writer with
# `fork_context=false` and `reasoning_effort=medium` in this environment. The
# gate was attempted without unsafe bypass flags and failed before nested tools
# could be exercised; see docs/dev_plans/CODEX_MIRROR_BACKLOG.md, 2026-07-04
# Codex-track divergence entry.
#
# Rather than fake an end-to-end fan-out invocation, this runner drives the R6
# CONTRACT MECHANISM directly: it runs the same contract test
# (contract_test_adder.py, authored from the fixture-plan.md Integration Seams
# Writer row) against two fixture implementations — one that honors the
# contract, one that deliberately violates it — and asserts the divergent
# implementation's contract test FAILS while the conformant one PASSES.
#
# Exit 0 only if BOTH hold: conformant slice passes, divergent slice fails.
# Exit 1 otherwise, with a clear message about which slice misbehaved.

set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
FIXTURE_DIR="$ROOT_DIR/plugins/skein-codex/skills/fan-out/tests/seeded-divergence"
CONTRACT_TEST="$FIXTURE_DIR/contract_test_adder.py"
CONFORMANT_DIR="$FIXTURE_DIR/slice_conformant"
DIVERGENT_DIR="$FIXTURE_DIR/slice_divergent"

for p in "$CONTRACT_TEST" "$CONFORMANT_DIR" "$DIVERGENT_DIR"; do
	if [[ ! -e "$p" ]]; then
		echo "FAIL: fixture path missing: $p" >&2
		exit 1
	fi
done

PYTHON_BIN="${PYTHON_BIN:-python3}"

use_pytest=0
if "$PYTHON_BIN" -c "import pytest" >/dev/null 2>&1; then
	use_pytest=1
fi

RUN_LOG="$(mktemp)"
trap 'rm -f "$RUN_LOG"' EXIT

# run_contract_test SLICE_DIR
# Returns 0 if the contract test passes against that slice, non-zero if it fails.
# `python3 -B` + PYTHONDONTWRITEBYTECODE=1 keep the run deterministic: no `.pyc`
# is written, so a stale __pycache__ from a prior run can never mask current source.
run_contract_test() {
	local slice_dir="$1"
	if [[ "$use_pytest" -eq 1 ]]; then
		PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$slice_dir" "$PYTHON_BIN" -B -m pytest -p no:cacheprovider "$CONTRACT_TEST" -q >"$RUN_LOG" 2>&1
	else
		PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$slice_dir" "$PYTHON_BIN" -B "$CONTRACT_TEST" >"$RUN_LOG" 2>&1
	fi
}

contract_failed_by_assertion() {
	local rc="$1"
	[[ "$rc" -eq 1 ]] && grep -Eq 'AssertionError|^[[:space:]]*E[[:space:]]+assert|^FAILED .*::test_' "$RUN_LOG"
}

echo "=== Codex R6 seeded-divergence direct-mode runner ==="
if [[ "$use_pytest" -eq 1 ]]; then
	echo "Mode: python3 -m pytest"
else
	echo "Mode: plain python3 script (pytest not importable)"
fi
echo

conformant_ok=0
if run_contract_test "$CONFORMANT_DIR"; then
	conformant_ok=1
	echo "PASS: conformant slice (slice_conformant) — contract test passed as expected"
else
	echo "FAIL: conformant slice (slice_conformant) — contract test unexpectedly FAILED"
	cat "$RUN_LOG" 2>/dev/null || true
fi

divergent_failed=0
if run_contract_test "$DIVERGENT_DIR"; then
	echo "FAIL: divergent slice (slice_divergent) — contract test unexpectedly PASSED (should have failed)"
else
	divergent_rc=$?
	if contract_failed_by_assertion "$divergent_rc"; then
		divergent_failed=1
		echo "PASS: divergent slice (slice_divergent) — contract assertion failed as expected"
	else
		echo "FAIL: divergent slice (slice_divergent) — contract test failed for a non-assertion reason (exit $divergent_rc)"
	fi
	cat "$RUN_LOG" 2>/dev/null || true
fi

echo

if [[ "$conformant_ok" -eq 1 && "$divergent_failed" -eq 1 ]]; then
	echo "=== Codex R6 mechanism verified: divergent slice FAILED, conformant slice PASSED ==="
	exit 0
else
	echo "=== Codex R6 mechanism NOT verified — see failures above ===" >&2
	exit 1
fi
