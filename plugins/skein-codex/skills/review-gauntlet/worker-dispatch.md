# Codex Fixer Dispatch Template

Use this request for every fresh fixer batch, quick-mode fix, resumed batch or retry. Review gates remain in the main conductor.

```json
{
  "task_name": "{{TASK_NAME}}",
  "fork_turns": "none",
  "reasoning_effort": "{{REASONING_EFFORT}}",
  "message": "{{FILLED_FIXER_PROMPT}}"
}
```

Call `spawn_agent` with a structured argument object, a unique task name and the entire filled fixer prompt as `message`. Let argument serialization escape quotes and newlines; do not interpolate prompt text into JSON source. Inherit the harness-selected model. Set `reasoning_effort` to `"medium"` when supported; otherwise omit only that optional field. Always keep `fork_turns` set to `"none"`.

Use `wait_agent` for wakeups while the fixer is outstanding. Mailbox updates and timeouts do not prove completion. Collect the delivered final message and terminal status before validating the existing report schema, verifying live edits and advancing the convergence ledger. Final output without terminal status is incomplete. Terminal failure or malformed output hands back the actual error without claiming a fixed batch.

If dispatch fails, drain any already-started workers and capture their final reports before handing back the original error. Preserve the ledger. Every retry starts a fresh worker; no prior conversation is reused, and no additional lifecycle operation is required after terminal completion. Missing spawn/wait support never falls back to inline fixing.
