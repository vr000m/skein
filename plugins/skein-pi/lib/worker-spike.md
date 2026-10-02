# Phase 2 worker spike — parent-profile launch rejected

**Historical baseline:** the stop below applied to reuse of the parent's profile. The maintainer subsequently approved a disposable private-profile design; see `worker-profile.md` and `tests/pi/test_private_profile.py` for its scoped retest. The original counterexample tests remain as regression controls. No dispatcher or additional skill has been registered.

Runtime examined: Pi 0.87.1. These are CLI observations, not a production worker, a security sandbox, or a portability approval. `package.json` still exposes only `skein-show-me`.

## Reproduce

```sh
uv run --with pytest python -m pytest tests/pi -q
```

`tests/pi/test_worker.py` and `tests/pi/test_model_policy.py` use the real Pi executable, a deterministic loopback OpenAI-compatible SSE endpoint, a disposable home/agent directory and an allowlisted environment without personal credentials. Requests and JSON events stay in test memory; no raw prompt/event log is committed. The package-command probe uses a local Python stand-in that only writes a marker and fails; it neither installs packages nor contacts a registry. The extension probe's only effect is writing a disposable marker and registering a benign dummy tool. A positive control confirms that extension can actually load.

The fixture model/provider names are test-only, not shipped model policy. No paid model calls, personal settings edits, or public service requests are required. Passing the observation tests does **not** mean the isolation gate passed.

## Tested launch

The candidate is an argv launch, with the task supplied on stdin:

```text
pi --mode json --no-session --no-skills --no-extensions
   --no-context-files --no-approve --no-tools
   --no-prompt-templates --no-themes --offline
   --provider <explicit-provider> --model <explicit-model> --thinking <level>
```

The process uses the requested working directory. The tool-specific probe substitutes `--tools bash`; it asks only for the three non-secret session-identity variables. Runtime/model flags must come from validated configuration, never task text.

## Observations

| Boundary | Result | Consequence |
|---|---|---|
| Project/user AGENTS files, ambient skills | Excluded by the candidate flags | Necessary but insufficient context isolation |
| Ambient user/project extension | Not loaded with disable/trust flags; positive control loads user extension when enabled | No ambient nested-dispatch tool in the tested no-tools launch |
| User SYSTEM.md and APPEND_SYSTEM.md | Both still enter the model request | **Isolation blocker** for reuse of the parent's agent directory |
| Explicit system and append-system prompts | Override both discovered user prompt files | Closes that prompt leak only |
| User settings packages | Still resolved with all resource-disable flags, explicit prompts and offline mode; configured npmCommand is executed | **Startup execution blocker** for reuse of the parent's settings |
| Fresh session | Declared cwd preserved; no session directory persisted | `--no-session` is useful but not isolation |
| JSON completion | Authoritative assistant message and agent_settled observed | Require terminal event, final success stop reason and validated result, not merely exit 0 |
| HTTP 401 | Assistant stopReason is error, but process exits 0 | Must surface authentication/runtime failure, never success |
| Missing credential | No request reaches endpoint | Must stop, not select another model |
| No usage in provider response | CLI emits a usage object with zero tokens/cost | Presence of a usage object is not evidence of measurement; report unknown conservatively |
| Usage supplied | Token counts preserved; cost calculated from configured rates | Label reported token usage and catalog-estimated cost; not a billing receipt |
| Hung request | Process-group SIGTERM terminates tested Pi process | Basic cancellation works; descendant cleanup and bounded streaming still need implementation/testing |
| Parent PI_* vars inherited by child | CLI ignores them for selection and uses configured default | Dispatcher must require approved identity before launching; never rely on implicit inheritance |
| LLM-callable bash identity | Replaces deliberately stale inherited provider/model/reasoning with current session values | Valid at that tool boundary; arbitrary shell env strings carry no proof of provenance |
| Model pattern | `fixture` resolves to `fixture-model` | CLI `--model` is not an exact-name validator |
| Unknown model ID on configured provider | Forwarded as a custom model ID with a warning | Exact model availability needs preflight validation; warning/exit 0 is insufficient |
| Unknown provider | Fails without contacting endpoint | Preserve explicit failure, no fallback |

The coordinating session's own shell exposed a provider/model/reasoning tuple. No credential or full environment dump was read. That is an observation of this session, not an authentication mechanism for arbitrary dispatcher callers; the values are deliberately not pinned into the package.

## Original stop decision and recommended continuation

**Stop before implementing the dispatcher or registering dependent skills**, as required by Phase 2's isolation gate. The proposed flags alone are disproven as a complete ambient-startup boundary; this does not establish that every possible CLI strategy is impossible.

Recommended amendment: retain the CLI subprocess strategy but give every worker a **disposable private profile**, not the person's agent directory:

1. Set private `HOME` and `PI_CODING_AGENT_DIR`, explicit system/append prompts, curated rules and role-required tools. Do not copy settings, packages, extensions, hooks, or executable credential commands. Use a controlled environment rather than inheriting everything.
2. Provision only an explicitly approved provider/model configuration and credential channel. Define API-key versus OAuth refresh/writeback semantics; copying the whole `auth.json` or `models.json` is not an acceptable shortcut. Cloud credentials and extension-backed providers need their own verified route or an explicit unsupported result.
3. Accept explicit operator-approved model/tier mappings initially. Missing approved identity must fail closed. Optional tiers are factual, mechanical and judgment; fallback may use only the approved selected model, never an unrelated CLI default. Do not treat provider thinking levels as uniform. Environment-only automatic parent identity requires a separately established provenance protocol.
4. Test a contaminated parent profile against the clean child, including package-manager execution markers, credential commands, project settings, prompt files and nested-dispatch tools. Tool allowlisting is not an OS sandbox; unrestricted bash would still permit arbitrary subprocesses. Define how role-required filesystem/network access avoids handing out nested orchestration capability.
5. Then implement streaming validation, conservative unknown usage, process-group timeout/cancellation, concurrency and output caps, guarded one-writer attempt persistence, typed failures and tier tests. These are **not yet implemented** by the spike harness.
6. Only after that gate passes, port the five single-worker skills and plan-view and update the exact manifest allowlist and readiness tests.

Alternative: an SDK child with in-memory settings and an explicit `ResourceLoader` (Pi's shipped `examples/sdk/12-full-control.ts` demonstrates the shape). This gives a more explicit loading boundary but adds an SDK/runtime dependency and still requires credential and tool-permission decisions. It is not implemented or selected here.

The subsequent approved choice is the private CLI profile, documented in `worker-profile.md`; the plan has been revised and needs re-review rather than a fabricated fresh review marker. Phase 2 remains incomplete and the six dependent skill ports remain blocked. No all-provider, full-isolation or live-model quality claim follows from these tests.
