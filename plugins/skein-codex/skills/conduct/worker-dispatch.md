# Codex Worker Dispatch Template

Use this request shape for each fresh implementer, test-writer, fix-loop retry, or advisory reviewer. The role prompt templates remain harness-neutral; this file supplies the Codex runtime arguments.

```json
{
  "task_name": "{{TASK_NAME}}",
  "fork_turns": "none",
  "reasoning_effort": "{{REASONING_EFFORT}}",
  "message": "{{FILLED_WORKER_PROMPT}}"
}
```

Call `spawn_agent` with a structured argument object. Choose a unique `task_name` for this dispatch, set `message` to the full rendered role prompt, and let argument serialization escape its newlines and quotes. Never interpolate a prompt into JSON text or include parent conversation history. Keep `fork_turns` set to `"none"` on every fresh dispatch.

Inherit the harness-selected model. Set `reasoning_effort` to `"medium"` for implementers and test-writers, or `"high"` for the advisory reviewer, when the runtime supports that field; otherwise omit only that optional field.

Use `wait_agent` while reports are outstanding. Its return value signals mailbox updates or a timeout; worker messages arrive separately. Collect each worker's delivered final message and terminal status before validating its JSON report. An update summary alone is not completion. No additional lifecycle operation is required after the terminal report.

If a dispatch fails, including a runtime capacity limit, wait for any already-started workers to deliver their final reports and reach terminal status before handing back with the actual error. Preserve existing phase state. Do not run the worker's phase inline or reuse a prior worker's conversation as a fresh dispatch.
