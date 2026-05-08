# Backlog

Non-blocking follow-up work deferred from merged dev plans. Items here are not promises; they are candidates for a future branch when priorities line up.

Convention: group by originating feature. When an item lands, move it to the relevant changelog or dev plan and delete the entry here.

## /conduct (from `docs/dev_plans/20260422-feature-conduct-skill.md`, merged via PR #11)

### Product / scope

- **Skill namespacing** (`workflow:dev-plan`, `workflow:conduct`, …) — evaluate after conduct proves the workflow in practice.
- **Codex delegation-unavailable policy** — if some Codex environments cannot delegate, decide whether `/conduct` should degrade to main-session execution or hard-stop with a clear diagnostic.
- **Shared helper extraction** — if Claude/Codex helper modules drift enough to become a maintenance burden, extract a shared conduct helper library in a later refactor rather than during the initial Codex port.
- **LLM-based fix-loop classifier** — current design leans on the implementer's self-reported flag. If misrouting is common in practice, consider a tiny classifier call.

### Deferred architecture refactors (from `/deep-review` 2026-04-23)

- Extract a shared `_fix_iteration(opts, state, phase, respawn_role, hook_output)` helper so `_run_phase` and `_retry_after_hook_failure` stop duplicating the spawn→parse→test→cap→reset body.
- Replace the private `_CommitHookFailure` exception-as-control-flow with a `CommitOutcome` dataclass carrying `hook_failed` + `hook_output`, so `_commit_phase`'s documented return shape matches reality.
- Encode the "reviewer role has no `flags`" asymmetry in `schema._ROLE_REQUIRED` (e.g., a `has_flags: bool`) rather than a comment.
- Add a call-site comment in `_run_phase` that the parallel/sequential strategy string is advisory for the LLM orchestrator; the harness always issues both spawns sequentially.
- Add a sweep in `scripts/check-sync.sh` (or a comment in all four sync scripts) warning when a global skill dir exists for a skill no longer listed in `MANAGED_SKILLS` / `CLAUDE_ONLY_SKILLS`.

### Deferred follow-up from final branch `deep-review` (2026-04-23)

- Wire or remove the documented Step 7 reviewer path in Codex `/conduct`; the current conductor never spawns `role="reviewer"` even though the skill contract still describes that mid-phase review step.
- Make the Codex "sequential" strategy a real two-step flow instead of spawning implementer and test-writer in the same iteration-0 pass with only a different summary label.
- Unify the main success path and hook-retry completion path so handback strategy reporting cannot drift or lie after post-hook retries.
- Route all outward-facing diagnostics through the same redaction helper; validation, lint, stalled-test, and hook-failure handbacks still bypass the scrubber.
- Return `complete` directly when `/conduct` is re-run after all phases are already finished, instead of forcing an unnecessary `--resume` handback.
