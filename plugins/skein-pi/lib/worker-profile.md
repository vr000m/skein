# Disposable Pi worker profile — revised launch contract

The maintainer approved replacing reuse of the parent's agent profile with a disposable private profile, then retesting isolation **before implementing the dispatcher**. `private_profile.py` implements preparation/cleanup only; it never launches a process. The SDK alternative is not selected.

## Scope and trust boundary

The initial verified lane is deliberately narrow: **text-only `openai-completions`, a literal API key, explicitly selected provider/model/endpoint, `thinking: off`, and no tools**. This tests profile isolation without silently borrowing an OAuth login or enabling shell dispatch. Other APIs, reasoning levels, tool sets and credential types fail explicitly. It is not the completed Phase 2 worker or a two-provider portability claim.

Trusted inputs come from the operator/orchestrator, separately from task text:

- an explicit approval record for one provider/model/endpoint and its limits;
- one literal key, supplied privately in memory (never pasted into a task, passed in argv or inherited from environment);
- absolute paths to the approved Node executable and Pi CLI entrypoint;
- an explicit cwd and operator-controlled temporary parent directory;
- curated role instructions and project rules.

The `approved: true` field records an already obtained operator decision. It is **not proof of provenance**: task/model output must never construct this record, and a future caller must enforce that separation. The builder reads neither `PI_PROVIDER`/`PI_MODEL` nor any ambient auth/model/settings file. No approval, missing fields, executable/interpolated keys, unsupported credential type or invalid identity => `ProfileError`, before a profile is created. There is no automatic model fallback.

## Profile construction

1. Validate the explicit approval and key. Initially reject CLI fuzzy/suffix syntax in identifiers, arbitrary configuration fields, headers, credential-bearing URLs and HTTP except numeric loopback. HTTPS is required for a non-loopback endpoint. Approval of the exact endpoint is also approval to send that one credential there; no claim of a general network sandbox is made.
2. Create a fresh unpredictable mode-0700 temporary root; create separate mode-0700 home, agent and scratch directories. Write new mode-0600 files with exclusive creation. Never copy a user directory.
3. Generate settings with empty packages/resources/tool lists, project trust `never`, retries/compaction/cache warming disabled and telemetry off. Generate only the approved provider's single model entry. Generate `auth.json` with only the selected provider's literal key. No OAuth state, command credential, cloud profile, custom headers or provider extension is copied.
4. Write curated system and append-system text into private files and pass their absolute paths explicitly. Pin session-dir under the private root even though `--no-session` is used, avoiding the documented pre-trust project sessionDir lookup influencing storage.
5. Return an argv/environment/cwd description: invoke the **absolute Node executable and CLI entrypoint**, not a PATH-resolved `pi`/`node`; retain all resource-disable/trust flags, `--no-tools`, explicit model/provider/thinking and offline catalog mode. Supply task text separately on stdin. The builder accepts no task text and does not spawn anything.
6. Build environment from scratch: private HOME, agent/session/temp/XDG locations, a fixed system PATH and offline/version-check/telemetry controls. Do not inherit Node injection options, proxies, credentials, cloud configuration, stale session identity, shell startup settings, package overrides or caller PATH. Offline mode suppresses catalog activity; it does **not** disable requests to the approved model endpoint.
7. Caller must finish/cancel/reap its child before exiting the context. Remove only the newly created profile on normal exit or Python exception. Deletion is not secure erasure. SIGKILL, power loss or host failure can leave a mode-0700 profile requiring operator cleanup; the future dispatcher must document recovery without sweeping unrelated directories. No writeback to the parent's auth or settings is permitted.

`private_profile.py` uses only Python's standard library. This prototype is tested on POSIX with Pi 0.87.1 and a local Node runtime; Windows process/permission semantics are not verified.

## Approval shape and credential semantics

The exact record fields are `approved`, `provider`, `model`, `api`, `base_url`, `thinking`, `context_window`, `max_tokens`, and `credential_type`. The key is a separate function argument and never appears in the returned profile's repr, argv or environment. Validation diagnostics use fixed codes rather than echoing rejected values.

A record defines the selected model catalog entry; it does not prove the remote endpoint implements the model or that the key is accepted. The future dispatcher must check the terminal response's identity and error state, preserve authentication/model failures, and never substitute another provider/model. There are no approved pricing rates in this prototype: Pi's default/synthetic zero cost must remain **unknown**, not a measured free call.

OAuth, secret-manager commands, ambient cloud credentials and extension-backed providers are **unsupported**, not silently converted to API keys. No refresh or shared-token writeback is attempted. In particular, a parent session using OAuth cannot use its login through this lane merely because it has `PI_*` identity variables. Supporting that later requires a separate approved credential lifecycle and isolation test.

Tier mappings remain a dispatcher-layer task: an operator may explicitly map factual, mechanical and judgment roles, with fallback only to an approved selected model. No inherited/default selection is implemented here, and provider reasoning levels are not assumed equivalent.

## Isolation retest

`tests/pi/test_private_profile.py` runs real Pi against a deterministic loopback SSE endpoint. The endpoint requires the **approved fixture key** without returning or logging it. The tests contaminate the parent/project with:

- SYSTEM, APPEND_SYSTEM, AGENTS and conventional skill roots;
- extensions advertising a nested-dispatch tool;
- package declarations and an executable package-manager setting;
- executable credential commands, extra credentials and conflicting model defaults;
- project sessionDir/trust/tool settings;
- stale PI identity, NODE_OPTIONS/NODE_PATH, credential/cloud variables, proxies, package overrides and a poisoned PATH.

Checks cover absence of sentinels in the model request, absence of executable marker effects, exact approved identity, no offered tools, rejection of a provider-hallucinated shell tool, unchanged parent/project contents, private permissions, credential minimisation, normal/exception cleanup and separation between attempts. Invalid/unapproved inputs and unsupported lanes fail before launch. Original spike tests remain as controls demonstrating that parent-profile reuse leaks; a credential-command positive control demonstrates that its stand-in really executes when reused.

The hostile tool-call test proves the command is **not executed**, not that the whole model run should be accepted. The future dispatcher must treat unexpected tool calls/errors as invalid/degraded output even if the model later finishes with a normal stop reason.

## Decision after retest

Passing these tests closes the observed ambient-prompt and package-startup gaps **for this no-tools/API-key lane**. It does not establish same-UID filesystem isolation, provider portability, live model quality or operational readiness of any new skill. Arbitrary read/bash would expose files or nested processes; all tools are refused by this builder until role-scoped access is separately designed and tested.

## Dispatcher implementation and handoff

`dispatcher.py` now implements the bounded synchronous host library for this lane. It is not a model-invocable CLI. A trusted host constructs it once with absolute runtime/cwd/state paths, a selected capability minted by `approve_selection(...)`, and optional separately confirmed tier capabilities. `approve_selection` calls an operator-facing callback with only a frozen redacted identity tuple; direct `Selection(...)` construction is refused. This is an in-process capability boundary, not protection from arbitrary code already executing inside the trusted host. Task requests contain exactly task id, attempt, role and prompt; they cannot carry approvals, credentials, runtime paths, tools, cwd or state destinations.

The dispatcher:

- rejects nested dispatcher construction when the private profile's depth marker is present;
- bounds concurrency (including queue wait in the task deadline), wall time, prompt/result/event-line/total output sizes and finding counts;
- writes task JSON to stdin with nonblocking I/O and fails if the child closes stdin before the complete task is delivered;
- concurrently drains stdout/stderr, retaining neither raw prompts, event streams nor diagnostics;
- requires one exact selected provider/model identity, one schema-valid no-tool assistant result, agent end without retry, and final `agent_settled`; it rejects tool/error/retry/compaction/extension events, duplicate JSON keys, extra turns and post-terminal records;
- treats absent or synthetic-zero usage as `unknown`, labels positive token counts `reported`, and always leaves cost `unknown` because no approved rate provenance is supplied;
- terminates the process group on cancellation, deadline, output overflow and every exit, escalating TERM to KILL;
- persists only the bounded typed envelope to a mode-0600 immutable attempt file. A pinned directory-fd walk refuses `..`, symlinked path components, pre-existing leaves and concurrent claims; publication is atomic and never overwrites. A persistence failure returns `state_error` with no result, so an unrecorded completion cannot be reported as success.

`tests/pi/test_dispatcher.py` covers real-Pi loopback success/auth/tool/missing-usage paths plus deterministic adversarial process fixtures: malformed/truncated/duplicate JSON, wrong identity/cwd, normal-looking output after a tool event, credential-bearing output/diagnostics, early stdin close, output floods, timeout, cancellation, TERM-resistant descendants, queue cancellation/deadline, concurrency, task authority injection, shell-like prompt data, immutable/concurrent state claims and symlink escapes. These are deterministic host-boundary tests, not hosted-model quality tests.

A fresh read-only review first identified two defects: partial stdin could have been accepted after a broken pipe, and `Selection` was an ordinary caller assertion. Both were fixed and covered. A second fresh review returned **PASS within the documented in-process trusted-caller boundary**, finding no remaining concrete false-success, cancellation, output-bound, state-containment or secret-persistence defect in scope. This focused review is not a full plan re-review and does not refresh the plan marker.

### Remaining integration gate

No skill is registered through this dispatcher yet. A Pi skill runs under model control and therefore cannot safely read a key, manufacture an approval callback, or interpolate secret-bearing launch commands. A trusted package extension/operator host (or another separately reviewed integration surface) must own selection, credential acquisition and dispatcher construction, exposing only bounded role/task submission to skills. That host must preserve the no-tools/API-key lane or separately verify any broader credential/tool lane. Until it exists and skill end-to-end tests pass, the package allowlist remains `skein-show-me` only.
