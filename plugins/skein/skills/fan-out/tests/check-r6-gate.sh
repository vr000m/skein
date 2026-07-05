#!/usr/bin/env bash
# check-r6-gate.sh — MANUAL R6 nested-spawn gate check (NOT a CI test).
#
# This is deliberately NOT wired into `just parity-tests` / the deterministic
# test suite: it launches a real `claude -p --dangerously-skip-permissions`
# worker (network + an unsandboxed nested agent), which cannot run in CI and
# requires you to opt into the skip-permissions flag yourself. Run it by hand
# when you want to (re)confirm the R6 topology gate on the Claude harness.
#
# What it proves: a `claude -p --dangerously-skip-permissions` worker (with
# CLAUDECODE unset, exactly as fan-out.sh launches it) can spawn a nested Task
# subagent AND that subagent honors a per-call `model`. Evidence is the run's
# `result.modelUsage`: if the requested child model (haiku) shows real billed
# tokens there — not merely echoed in the Task request — the child actually ran
# on that tier. First confirmed 2026-07-04 (child ran on claude-haiku-4-5).
#
# Caveat this check also surfaces: the Task tool has no per-call `effort`
# argument, so a nested subagent inherits the worker session's effort. fan-out.sh
# launches the worker at `--effort medium`, so the test-writer runs sonnet/medium
# (model per-call, effort inherited). This script asserts model-honoring only.
#
# Exit 0: gate confirmed (nested spawn worked and honored the per-call model).
# Exit 1: gate NOT confirmed (spawn failed, or child did not run on the requested
#         model) — keep the R6 topology gated and take the single-context fallback.
# Exit 2: preconditions missing (claude/jq absent) — inconclusive, not a failure.

set -uo pipefail

CHILD_MODEL_REQUEST="haiku"
CHILD_MODEL_MATCH="haiku" # substring expected in result.modelUsage keys

for bin in claude jq; do
	if ! command -v "$bin" >/dev/null 2>&1; then
		echo "INCONCLUSIVE: '$bin' not found on PATH — cannot run the gate check." >&2
		exit 2
	fi
done

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
raw="$workdir/raw.jsonl"

prompt="Use the Task tool to spawn exactly ONE general-purpose subagent with model ${CHILD_MODEL_REQUEST}. Instruct it to reply with only the string SENTINEL_OK_R6. After it returns, output one line: NESTED_SPAWN_WORKED or NESTED_SPAWN_FAILED:<reason>."

echo "=== R6 gate check (manual; launches claude -p --dangerously-skip-permissions) ==="
echo "Requesting a nested subagent on model '${CHILD_MODEL_REQUEST}'; will verify via result.modelUsage."

(
	cd "$workdir"
	unset CLAUDECODE
	exec claude --dangerously-skip-permissions -p "$prompt" \
		--model sonnet --effort medium \
		--output-format stream-json --verbose --include-partial-messages
) >"$raw" 2>"$workdir/err.log"
worker_rc=$?

if [[ ! -s "$raw" ]]; then
	echo "FAIL: worker produced no stream output (exit $worker_rc)." >&2
	tail -5 "$workdir/err.log" >&2 2>/dev/null || true
	exit 1
fi

# The definitive signal: did the child model actually accrue token usage?
child_ran=$(jq -r --arg m "$CHILD_MODEL_MATCH" '
	select(.type=="result") | .modelUsage // {}
	| to_entries[] | select(.key|test($m)) | .key' "$raw" 2>/dev/null | head -1)

worked=$(grep -Eo 'NESTED_SPAWN_(WORKED|FAILED)' "$raw" 2>/dev/null | sort -u | tr '\n' ' ')

echo "worker exit: $worker_rc"
echo "nested-spawn sentinel(s): ${worked:-<none>}"
echo "child model with billed tokens in result.modelUsage: ${child_ran:-<none>}"

if [[ -n "$child_ran" ]]; then
	echo "PASS: nested spawn worked AND ran on the requested per-call model ($child_ran)."
	echo "      R6 topology is confirmed live on the Claude harness."
	exit 0
fi

echo "FAIL: no child model matching '$CHILD_MODEL_MATCH' accrued tokens in result.modelUsage." >&2
echo "      The nested spawn did not honor the per-call model (or did not run)." >&2
echo "      Keep the R6 topology gated; take the single-context fallback." >&2
exit 1
