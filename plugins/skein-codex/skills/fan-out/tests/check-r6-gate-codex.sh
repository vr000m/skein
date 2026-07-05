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
# honors the requested reasoning_effort=medium. Evidence must include both the
# worker's success sentinel and real JSONL usage/billing data for a distinct
# nested/test-writer-labelled child run. Parent-side spawn_agent tool-call usage
# is explicitly excluded. Merely seeing the prompt text, spawn_agent text,
# fork_context=false text, or child sentinel echoed in output is not acceptance.
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
# Exit 0: gate confirmed — the ONLY pass path requires the worker success
#         sentinel AND real per-child billed usage at the requested effort. Note:
#         codex exec --json (CLI 0.142.5) does not expose per-child billing/effort,
#         so this path cannot fire on that CLI; it is kept for a future CLI that does.
# Exit 1: gate NOT confirmed — the worker reported a failed spawn, or no nested
#         spawn/usage evidence was found (echoed text alone is never acceptance).
#         Keep the R6 topology gated; use the single-context fallback.
# Exit 2: inconclusive — preconditions missing (codex/jq absent), invalid effort
#         config key, app-server init blocked by sandbox, OR the nested spawn
#         demonstrably ran (a distinct child thread was created via spawn_agent and
#         the success sentinel fired) but this codex exec --json output exposes no
#         per-child billing/effort to confirm the child's tier. That last case is
#         the observed reality on Codex CLI 0.142.5: topology runs, tier unverifiable.

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
	if grep -Fq "$FAILED_SENTINEL" "$err" 2>/dev/null; then
		echo "FAIL: worker reported ${FAILED_SENTINEL} without usable JSONL output (exit $worker_rc)." >&2
		tail -20 "$err" >&2 2>/dev/null || true
		exit 1
	fi
	echo "INCONCLUSIVE: worker produced no JSONL output (exit $worker_rc)." >&2
	echo "              No nested-spawn topology failure was observed; this may be auth/network/runtime setup." >&2
	tail -20 "$err" >&2 2>/dev/null || true
	exit 2
fi

worked="$(grep -Eo "${WORKED_SENTINEL}|${FAILED_SENTINEL}" "$raw" 2>/dev/null | sort -u | tr '\n' ' ')"
worked_ok=0
if grep -Fq "$WORKED_SENTINEL" "$raw" && ! grep -Fq "$FAILED_SENTINEL" "$raw"; then
	worked_ok=1
fi
child_sentinel_seen="no"
if grep -Fq "$CHILD_SENTINEL" "$raw"; then
	child_sentinel_seen="yes"
fi

# Definitive signal: a distinct nested/test-writer child JSON object with real
# token usage and an explicit medium effort marker. This intentionally excludes
# parent-side spawn_agent tool-call turns; if Codex JSONL does not expose child
# billing separately, the gate remains unconfirmed instead of passing on weak evidence.
nested_usage_evidence="$(
	jq -c --arg effort "$CHILD_EFFORT_REQUEST" '
		def token_total:
			[.. | objects | .usage? // empty | objects | .. | numbers] | add // 0;
		def effort_values:
			[.. | objects | (.reasoning_effort?, .model_reasoning_effort?, .effort?) | select(. != null) | tostring];
		def child_labels:
			[.. | objects
			 | (.agent_type?, .subagent_type?, .agent_name?, .worker_type?, .name?, .label?)
			 | select(. != null)
			 | tostring
			 | select(test("test-writer|subagent|child"; "i"))];
		def child_ids:
			[.. | objects
			 | (.agent_id?, .subagent_id?, .child_agent_id?, .child_run_id?, .run_id?, .session_id?)
			 | select(. != null)
			 | tostring];
		select(type == "object")
		| select(token_total > 0)
		| select(effort_values | index($effort))
		| select(child_labels | length > 0)
		| select(child_ids | length > 0)
		| {type, billed_tokens: token_total, efforts: effort_values, child_labels: child_labels, child_ids: child_ids}
	' "$raw" 2>/dev/null | head -1
)"

# Structural nested-spawn evidence: a real spawn_agent tool call that created a
# DISTINCT child thread (receiver_thread_ids populated and not just the sender).
# This is actual runtime inter-agent thread activity, not echoed prompt text —
# enough to prove the nested spawn happened, but NOT enough to confirm the child
# ran at the requested effort tier, because codex exec --json (CLI 0.142.5)
# exposes no per-child billing/effort (usage is reported only at turn level).
spawn_thread_evidence="$(
	jq -c '
		[.. | objects
		 | select((.tool? // "") == "spawn_agent")
		 | select(((.receiver_thread_ids? // []) - [(.sender_thread_id? // "")]) | length > 0)
		 | {tool, sender_thread_id, receiver_thread_ids}]
		| .[0] // empty
	' "$raw" 2>/dev/null | head -1
)"

echo "worker exit: $worker_rc"
echo "nested-spawn sentinel(s): ${worked:-<none>}"
echo "nested-spawn success sentinel gate: $worked_ok"
echo "child sentinel present anywhere in JSONL: $child_sentinel_seen"
echo "distinct child-thread spawn evidence: ${spawn_thread_evidence:-<none>}"
echo "billed nested medium child evidence: ${nested_usage_evidence:-<none>}"

# 1. Full confirmation (future-proof): success sentinel AND real per-child billed
#    usage at the requested effort. codex exec --json (CLI 0.142.5) does not emit
#    per-child billing/effort, so this path does not fire today — it is kept for a
#    future Codex CLI that exposes child usage, and is the ONLY path that exits 0.
if [[ "$worked_ok" -eq 1 && -n "$nested_usage_evidence" ]]; then
	echo "PASS: nested spawn worked AND produced billed nested-child usage at reasoning_effort=${CHILD_EFFORT_REQUEST}."
	echo "      R6 topology is confirmed live on the Codex harness."
	exit 0
fi

# 2. Genuine failure: the worker itself reported the nested spawn failed.
if grep -Fq "$FAILED_SENTINEL" "$raw" 2>/dev/null; then
	echo "FAIL: worker reported ${FAILED_SENTINEL} — the nested spawn genuinely failed." >&2
	echo "      Keep the R6 topology gated; use the single-context fallback." >&2
	echo "--- stderr tail ---" >&2
	tail -20 "$err" >&2 2>/dev/null || true
	exit 1
fi

# 3. Unverifiable-but-ran: the nested spawn demonstrably executed (a distinct
#    child thread was created via spawn_agent AND the worker success sentinel
#    fired), but this codex exec --json output carries no per-child billing or
#    reasoning_effort, so the child's tier cannot be verified from JSONL. This is
#    INCONCLUSIVE, not a topology failure — do NOT auto-confirm the gate on it.
if [[ "$worked_ok" -eq 1 && -n "$spawn_thread_evidence" ]]; then
	echo "INCONCLUSIVE: the nested spawn ran (a distinct child thread was created via spawn_agent" >&2
	echo "              and ${WORKED_SENTINEL} fired), but this codex exec --json output exposes no" >&2
	echo "              per-child billing or reasoning_effort, so the child's tier (=${CHILD_EFFORT_REQUEST})" >&2
	echo "              cannot be verified from JSONL. Topology NOT auto-confirmed; keep it gated until a" >&2
	echo "              Codex CLI exposes per-child usage. See docs/dev_plans/CODEX_MIRROR_BACKLOG.md." >&2
	exit 2
fi

# 4. No usable evidence: no clean success sentinel, or the sentinel fired without
#    any real child-thread spawn (echoed text alone is never acceptance).
if [[ "$worked_ok" -ne 1 ]]; then
	echo "FAIL: nested-spawn success sentinel was not observed cleanly." >&2
	echo "      Required: ${WORKED_SENTINEL} present and ${FAILED_SENTINEL} absent." >&2
fi
echo "FAIL: no nested-child spawn or usage evidence at reasoning_effort=${CHILD_EFFORT_REQUEST} was found." >&2
echo "      Echoed spawn text or child sentinel text is not enough to confirm the gate." >&2
echo "      Keep the R6 topology gated; use the single-context fallback." >&2
echo "--- stderr tail ---" >&2
tail -20 "$err" >&2 2>/dev/null || true
exit 1
