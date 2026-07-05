#!/usr/bin/env bash
# run-seeded-divergence.sh — R6 gating fixture (DIRECT MODE).
#
# DIRECT MODE — the deterministic, CI-safe half of R6 acceptance. It validates
# the R6 CONTRACT MECHANISM (a contract-derived test surfaces a divergent impl)
# without launching real workers, so it can live in `just parity-tests`.
#
# The other half — that a `claude -p --dangerously-skip-permissions` worker can
# spawn a nested test-writer honoring its per-call model — is now CONFIRMED on the
# Claude harness (gate passed 2026-07-04; the child actually ran on haiku per
# result.modelUsage). That topology gate is NOT run here: it needs skip-permissions
# + network and cannot be deterministic in CI. Re-confirm it out-of-band with the
# manual `check-r6-gate.sh` in this directory. The Codex mirror's equivalent gate
# is still unconfirmed (see docs/dev_plans/CODEX_MIRROR_BACKLOG.md, 2026-07-04).
#
# So this runner drives the R6 CONTRACT MECHANISM directly: it runs the same contract test
# (contract_test_adder.py, authored from the fixture-plan.md Integration Seams
# Writer row) against two fixture implementations — one that honors the
# contract, one that deliberately violates it — and asserts the divergent
# implementation's contract test FAILS while the conformant one PASSES.
#
# This deterministically validates the mechanism R6 depends on: that a
# contract-derived test surfaces an implementation which diverges from its
# contract, rather than being silently ratified. It does not exercise the
# separate-subagent spawn topology itself (gated, see above) — presence of
# spawn text elsewhere is never acceptance for that; this script is the
# acceptance evidence for the underlying mechanism.
#
# Exit 0 only if BOTH hold: conformant slice passes, divergent slice fails.
# Exit 1 otherwise, with a clear message about which slice misbehaved.

set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
FIXTURE_DIR="$ROOT_DIR/plugins/skein/skills/fan-out/tests/seeded-divergence"
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
# is written, so a stale __pycache__ from a prior run (e.g. a slice whose source
# was edited between runs) can never mask the current source. Without this a
# leftover bytecode file can make a divergent slice appear conformant.
run_contract_test() {
	local slice_dir="$1"
	if [[ "$use_pytest" -eq 1 ]]; then
		PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$slice_dir" "$PYTHON_BIN" -B -m pytest -p no:cacheprovider "$CONTRACT_TEST" -q >"$RUN_LOG" 2>&1
	else
		PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$slice_dir" "$PYTHON_BIN" -B "$CONTRACT_TEST" >"$RUN_LOG" 2>&1
	fi
}

echo "=== R6 seeded-divergence direct-mode runner ==="
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
	divergent_failed=1
	echo "PASS: divergent slice (slice_divergent) — contract test failed as expected"
fi

echo

if [[ "$conformant_ok" -eq 1 && "$divergent_failed" -eq 1 ]]; then
	echo "=== R6 mechanism verified: divergent slice FAILED, conformant slice PASSED ==="
	exit 0
else
	echo "=== R6 mechanism NOT verified — see failures above ===" >&2
	exit 1
fi
