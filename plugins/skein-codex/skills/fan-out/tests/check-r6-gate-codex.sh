#!/usr/bin/env bash
# check-r6-gate-codex.sh - MANUAL Codex R6 nested-spawn gate check (NOT a CI test).
#
# This is deliberately NOT wired into `just parity-tests` / the deterministic
# test suite: it launches a real non-interactive `codex exec` worker (network +
# a nested spawn_agent request), which cannot run in CI and must be opted into
# by hand when you want to (re)confirm the R6 topology gate on the Codex harness.
#
# What it proves: a non-interactive Codex worker, launched with the same
# fan-out worker idiom (in a git worktree, inherited model by default, Codex
# session markers unset, no sandbox-bypass flag unless the caller explicitly
# supplies one through FANOUT_PERMS_FLAG/FANOUT_EXTRA_ARGS), can spawn exactly
# one nested test-writer via spawn_agent with fork_context=false AND that child
# honors the requested reasoning_effort=medium. Evidence must come from real
# JSONL usage/billing data for a nested/test-writer-labelled child run. Merely
# seeing the prompt text, spawn_agent text, fork_context=false text, or child
# sentinel echoed in output is not acceptance.
#
# Codex CLI 0.142.5 has no first-class `codex exec --effort` flag. The effort
# request for the worker is applied with the validated config key:
# `-c model_reasoning_effort="medium"` under `--strict-config`; a stale or
# unsupported key fails before the probe can be mistaken for a pass.
#
# Known sandbox caveat: in this repository's managed sandbox, the worker can
# fail before any nested spawn is possible:
# `failed to initialize in-process app-server client: Operation not permitted`.
# That is INCONCLUSIVE, not a genuine gate failure. Run this probe from a
# permitted shell (externally sandboxed, or with an explicit bypass flag you
# chose to provide) to confirm the topology.
#
# Exit 0: gate confirmed (nested child ran and had billed usage at medium).
# Exit 1: gate NOT confirmed (spawn failed, or no billed nested medium child was
#         observed) - keep the R6 topology gated and use the single-context fallback.
# Exit 2: preconditions missing or inconclusive environment (codex/jq absent,
#         invalid effort config key, or app-server init blocked by sandbox).

set -uo pipefail

CHILD_EFFORT_REQUEST="medium"
CHILD_SENTINEL="SENTINEL_OK_R6_CODEX_CHILD"
WORKED_SENTINEL="NESTED_SPAWN_WORKED"
FAILED_SENTINEL="NESTED_SPAWN_FAILED"

for bin in codex jq; do
	if ! command -v "$bin" >/dev/null 2>&1; then
		echo "INCONCLUSIVE: '$bin' not found on PATH - cannot run the Codex gate check." >&2
		exit 2
	fi
done

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$repo_root" ]]; then
	echo "INCONCLUSIVE: not inside a git worktree; fan-out workers run from git worktrees." >&2
	exit 2
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
raw="$workdir/raw.jsonl"
err="$workdir/err.log"

prompt="Use spawn_agent to spawn exactly ONE test-writer child with fork_context=false and request reasoning_effort=${CHILD_EFFORT_REQUEST}. The child must do no tool work and reply with only ${CHILD_SENTINEL}. Wait for that child to finish and close it. After it returns, output exactly one final line: ${WORKED_SENTINEL} if the child returned ${CHILD_SENTINEL}, otherwise ${FAILED_SENTINEL}:<reason>. Do not spawn more than one child. Do not merely echo these instructions."

cmd="${FANOUT_CMD:-codex}"
model="${FANOUT_MODEL:-}"
perms_flag="${FANOUT_PERMS_FLAG:-}"
extra_args="${FANOUT_EXTRA_ARGS:-}"

cmd_args=(
	"$cmd" exec
	--json
	--ephemeral
	--strict-config
	-c "model_reasoning_effort=\"${CHILD_EFFORT_REQUEST}\""
)

if [[ -n "$perms_flag" ]]; then
	read -r -a perms_split <<< "$perms_flag"
	cmd_args+=("${perms_split[@]}")
fi

if [[ -n "$model" ]]; then
	cmd_args+=(--model "$model")
fi

if [[ -n "$extra_args" ]]; then
	read -r -a extra_split <<< "$extra_args"
	cmd_args+=("${extra_split[@]}")
fi

cmd_args+=("$prompt")

echo "=== Codex R6 gate check (manual; launches codex exec) ==="
echo "Requesting exactly one nested spawn_agent test-writer with fork_context=false and reasoning_effort='${CHILD_EFFORT_REQUEST}'."
echo "Acceptance requires billed nested-child usage evidence; echoed spawn text or sentinel text is ignored."
echo "Command shape: ${cmd_args[*]}"

(
	cd "$repo_root" || exit
	unset CODEX_SHELL CODEX_THREAD_ID CODEX_INTERNAL_ORIGINATOR_OVERRIDE
	exec "${cmd_args[@]}" </dev/null
) >"$raw" 2>"$err"
worker_rc=$?

if grep -qiE 'failed to initialize in-process app-server client: Operation not permitted|Operation not permitted.*app-server' "$err" "$raw" 2>/dev/null; then
	echo "INCONCLUSIVE: Codex worker could not initialize the in-process app-server client in this shell." >&2
	echo "              This sandbox blocked the probe before nested spawn_agent could be attempted." >&2
	echo "              Run from a permitted shell or opt into an explicit sandbox-bypass flag to test the gate." >&2
	echo "worker exit: $worker_rc"
	echo "--- stderr tail ---"
	tail -20 "$err" 2>/dev/null || true
	exit 2
fi

if grep -qiE 'unknown configuration field.*model_reasoning_effort|model_reasoning_effort.*unknown configuration field' "$err" "$raw" 2>/dev/null; then
	echo "INCONCLUSIVE: this Codex CLI rejected -c model_reasoning_effort; effort key needs re-verification." >&2
	echo "worker exit: $worker_rc"
	echo "--- stderr tail ---"
	tail -20 "$err" 2>/dev/null || true
	exit 2
fi

if [[ ! -s "$raw" ]]; then
	echo "FAIL: worker produced no JSONL output (exit $worker_rc)." >&2
	tail -20 "$err" >&2 2>/dev/null || true
	exit 1
fi

worked="$(grep -Eo "${WORKED_SENTINEL}|${FAILED_SENTINEL}" "$raw" 2>/dev/null | sort -u | tr '\n' ' ')"
child_sentinel_seen="no"
if grep -Fq "$CHILD_SENTINEL" "$raw"; then
	child_sentinel_seen="yes"
fi

# Definitive signal: a nested/test-writer-labelled JSON object with real token
# usage and an explicit medium effort marker. This intentionally ignores plain
# prompt echoes; if Codex JSONL does not expose child billing separately, the
# gate remains unconfirmed instead of passing on weak evidence.
nested_usage_evidence="$(
	jq -c --arg effort "$CHILD_EFFORT_REQUEST" '
		def token_total:
			[.. | objects | .usage? // empty | objects | .. | numbers] | add // 0;
		def effort_values:
			[.. | objects | (.reasoning_effort?, .model_reasoning_effort?, .effort?) | select(. != null) | tostring];
		def nested_labels:
			[.. | objects
			 | (.agent_type?, .subagent_type?, .agent_name?, .worker_type?, .name?, .label?, .tool_name?)
			 | select(. != null)
			 | tostring
			 | select(test("test-writer|spawn_agent|subagent"; "i"))];
		select(type == "object")
		| select(token_total > 0)
		| select(effort_values | index($effort))
		| select(nested_labels | length > 0)
		| {type, billed_tokens: token_total, efforts: effort_values, nested_labels: nested_labels}
	' "$raw" 2>/dev/null | head -1
)"

echo "worker exit: $worker_rc"
echo "nested-spawn sentinel(s): ${worked:-<none>}"
echo "child sentinel present anywhere in JSONL: $child_sentinel_seen"
echo "billed nested medium child evidence: ${nested_usage_evidence:-<none>}"

if [[ -n "$nested_usage_evidence" ]]; then
	echo "PASS: nested spawn worked AND produced billed nested-child usage at reasoning_effort=${CHILD_EFFORT_REQUEST}."
	echo "      R6 topology is confirmed live on the Codex harness."
	exit 0
fi

echo "FAIL: no billed nested-child usage evidence at reasoning_effort=${CHILD_EFFORT_REQUEST} was found." >&2
echo "      Echoed spawn text or child sentinel text is not enough to confirm the gate." >&2
echo "      Keep the R6 topology gated; use the single-context fallback." >&2
echo "--- stderr tail ---" >&2
tail -20 "$err" >&2 2>/dev/null || true
exit 1
