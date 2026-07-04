# Make Model/Effort Explicit and Intentional on Every Subagent Spawn

**Status**: Not Started
**Component**: meta
**Assignee**: Varun
**Priority**: Medium
**Branch**: `feature/explicit-model-effort-policy`
**Created**: 2026-07-04
**Updated**: 2026-07-04

**Objective**: Make delegation intentional across Skein skills on two fronts. (1) Every subagent spawn must name its own model/effort (Claude) or reasoning-effort hint (Codex) rather than inheriting the parent session's tier, under a two-tier policy — reviews/planning get the strongest model at high effort; implementation/testing get cheaper models — so a top-tier main loop (e.g. Fable/Opus) delegates mechanical work *down* instead of silently burning its own tier on it. (2) Give `/fan-out`'s worker the clean-context robustness that makes `/conduct` valuable: have the worker delegate test authoring to a **separate clean-context test-writer subagent** so implementation and tests no longer share one context, surfacing contract-vs-implementation inconsistencies instead of papering over them.

---

## Context

Skein skills spawn subagents to do review, planning, implementation, and rendering work. Today the model/effort of those spawns is applied inconsistently:

- **Model is explicit in 9 of 11 spawning skills**, but **inherited in 2** — `conduct` (implementer/test-writer/reviewer spawn with `subagent_type: general-purpose` and no model) and `plan-view` (uncapped `--rich` section-render fan-out, no model on either mirror).
- **Effort is inherited everywhere on the Claude side** — the string `effort` appears in zero Claude `SKILL.md` files.
- The **Codex mirror is already ahead**: it separates `reasoning_effort=high/medium/low` hints from model names (e.g. `deep-review` codex `SKILL.md:90-98`), with a documented convention. The Claude side is catching up to this idiom.

The failure this fixes: a spawn that omits its tier inherits the parent session model. If the main conversation is defaulted to a top-tier model, an inherited spawn runs mechanical implementation/testing on that expensive tier. The whole point of the orchestrator→worker pattern is that a strong main loop delegates *down*; an unannotated spawn defeats it.

This is a documentation/annotation change plus one one-line default flip (`fan-out.sh`), **plus one deliberate composition change** (the fan-out worker test-writer graft, R6). Apart from that graft it does not change orchestration logic, spawn topology, or the report/handback contracts (Requirement 2).

**Why the fan-out graft (R6).** `/conduct`'s robustness comes from context separation: its implementer and test-writer run in clean, non-shared contexts, so the test-writer validates the *contract*, and an implementation that diverges from the contract fails tests instead of being silently ratified. `/fan-out`'s worker already has phases (agent-prompt.md: Phase 1 Implement → 2 Test → 3 Self-Review → 4 Fix → 5 Verify), but they **all run in one worker context** — the same agent that writes the code writes and runs its own tests, so it cannot surface that class of inconsistency. Full `/conduct` nesting inside each worker was rejected: conduct hard-requires a `/review-plan` marker (`conduct/SKILL.md:78`) and a phased sub-plan, which fan-out workers don't have, and auto-minting markers would bypass the human review gate conduct exists to enforce. Grafting only the clean-context test-writer captures the robustness benefit within the one-level in-process delegation that fan-out already permits (`fan-out/SKILL.md:13`), with no sub-plan or marker prerequisite. Full `/conduct` per slice remains available opt-in for genuinely multi-phase slices (`fan-out/SKILL.md:15`).

Prior art: `CODEX_MIRROR_BACKLOG.md:54` logs PR `chore/codex-skill-model-routing` (merge `03364a2`), a Codex-originated model-routing cleanup across 8 codex skills — the same shape of change, Codex-side.

---

## Requirements

### R1 — The two-tier policy (generalised guidance, harness-independent)

This is the policy of record. Both harnesses map it to their own knobs.

- **Judgment work → strongest model, high effort.** Plan review, code review, and planning reasoning bet on a strong reviewer at high effort catching the details. Applies to: `review-plan` (4 judgment lenses), `deep-review` (logic, security, spec, **architecture**), `spec-compliance`, `conduct`'s advisory reviewer.
- **Mechanical work → cheaper model, lower effort.** Implementation and testing receive good information from the reviewed plan and don't need heavy reasoning. Applies to: `conduct` implementer + test-writer, `fan-out` worker, `plan-view` render, `dev-plan` Explore, `content-draft`, `content-review`, `update-docs`, `rfc-finder`.
- **Factual sub-lenses stay cheap regardless of the skill they live in.** Path/API existence and doc-staleness checks are lookups, not reasoning → cheapest tier. Applies to: `review-plan` `codebase-claims`, `deep-review` `documentation`.

### R2 — The inheritance invariant

Every spawn declares its own tier. No spawn inherits the session tier for mechanical work. This is the invariant to verify at the end (Phase 6), not just that tests pass — and it is enforced by a **new, mandatory** cross-skill tier-census test (Phase 3), not left optional. **This is a new test, not an extension of `conduct/tests/test_skill_spawn_grep.sh`**: that existing file is a forbidden-skill-*mention* guard scoped to the conduct skill directory only (`SKILL_DIR="$(dirname "$0")/.."`), so it can neither read the other ten skills nor assert tiers. The census is authored fresh at `tests/parity/test-spawn-tiers.sh`, walking `plugins/skein/skills/*/SKILL.md`; the mention guard is left intact and untouched.

### R3 — Why-comments on expensive spawns

Every judgment/expensive spawn carries a one-line comment stating why it earns the strong tier (e.g. `# opus/high: adversarial security lens needs deep reasoning`) so a future cost-optimization pass does not silently regress it. This is the guard your own `deep-review` architecture rationale asks for.

### R4 — Mirror alignment, per-harness idiom

The Claude and Codex mirrors stay **semantically aligned** (same tier intent per spawn) but keep their own idioms:
- Claude: `model:` + `effort:` on the `Agent` call.
- Codex: "Inherit the harness-selected model; request `reasoning_effort=X` when supported" (the established codex prose idiom — **not** a literal `reasoning:` field).

`CODEX_MIRROR_BACKLOG.md:15` already declares model-name / dispatch-idiom differences to be *not* drift, so the annotation-idiom split is sanctioned. Codex `SKILL.md` content edits go through `codex:rescue` per repo convention.

### R5 — Policy captured in docs

Add a short two-tier-policy section to `AGENTS.md` (near the model/dispatch-divergence discussion, ~line 46) so future skills follow it by default.

### R6 — fan-out worker: clean-context test-writer

The fan-out worker's Test phase delegates to a **separate clean-context test-writer subagent** rather than the worker testing its own code. Constraints:

- **Contract source (grounded, not vague).** The test-writer receives a precisely-defined slice contract: the worker's `{{TASK_DESCRIPTION}}` plus the rows of the Integration Seams table where **this worker is the Writer** — including concrete interface signatures (import paths, symbol names, function signatures) named there. It does **not** receive the implementer's diff or internal code. **The seams rows are not injected today** — `{{TECHNICAL_SPECIFICATIONS}}` is currently populated by the orchestrator with only "Files to modify, architecture decisions" (`fan-out/SKILL.md:106-109`), and `agent-prompt.md:86-91` merely *references* a seams table in Phase-3 self-review prose rather than containing it. So Phase 4 must (a) extend the `{{TECHNICAL_SPECIFICATIONS}}` injection at `fan-out/SKILL.md:106-109` to include the Integration Seams rows **with per-row Writer designations**, and (b) define the mechanical "rows where this worker is Writer" extraction the test-writer prompt performs. Of the placeholders in agent-prompt.md today (`{{TASK_DESCRIPTION}}`, `{{TECHNICAL_SPECIFICATIONS}}`, and several worktree/context placeholders such as `{{WORKTREE_PATH}}`, `{{BRANCH_NAME}}`, `{{CLAUDE_MD_CONTENT}}`, `{{TOOLCHAIN_CONTEXT}}`), **none is a "public interface" artifact** — so the contract is defined as exactly the `{{TASK_DESCRIPTION}}` + Writer-seam-rows extract, not a standing interface file. Slices whose seam under-specifies signatures produce noisy tests, not signal — acknowledged in Integration Seams below.
- **Anti-cheat rule (hard).** The worker may **not** relax, delete, or rewrite the test-writer's assertions to make them pass. When implementation and test disagree, the **contract wins**: the worker fixes the implementation, or escalates the divergence in its result file for the merge/reconciliation phase. Without this rule the worker — which owns both files — could paper over the exact inconsistency the graft exists to surface (agent-prompt.md:96-98 "fix every issue"), defeating R6 entirely. This rule is the load-bearing invariant of R6.
- **Conditional spawn (preserve the escape hatch).** The test-writer is spawned **only when the slice has an applicable test framework**. A doc/prose slice with no framework keeps the current "note it and continue" behavior (agent-prompt.md:43-44,66-71); it must **not** spawn a test-writer with nothing to test.
- **Authoritative runner: the worker (implementer) runs the tests.** The test-writer *authors* the test files and returns them (and may report its own one-shot run result as a sanity signal), but the binding pass/fail that drives the Phase 3/4 fix loop is the worker re-running the test-writer's files **verbatim** — it may not edit the assertions (see anti-cheat rule). The existing Phase 3/4 self-review + fix loop consumes those failures **subject to the anti-cheat rule**. The worker→test-writer spawn is **one level of in-process `Agent` delegation**, sanctioned in doctrine by `fan-out/SKILL.md:13` (though the nested-spawn-in-`-p` behavior is an assumption gated by the live run — see R2/Claude section); it does **not** start a new fan-out tier and does **not** invoke full `/conduct`.
- The test-writer spawn is tiered: mechanical → `model: sonnet, effort: medium` (Claude) / `reasoning_effort=medium` (Codex).
- **Gating acceptance:** a seeded-divergence fixture (Phase 4) — a two-slice fixture plan where one slice's implementation deliberately diverges from its contract — must show the test-writer's tests **fail** on the divergent slice and **pass** on a conformant one. Presence of the spawn is not sufficient.
- Full `/conduct` per slice stays available opt-in for multi-phase slices (unchanged `fan-out/SKILL.md:15` path). This graft is the default, lightweight robustness; conduct nesting is the heavyweight opt-in.

---

## Generalised Guidance (both harnesses)

> Reviews and planning are judgment work — spend the strong model and high effort there. Implementation and testing are execution of an already-reviewed plan — delegate them to cheaper tiers. Factual lookups (does this path/API exist, is this doc stale) are the cheapest tier wherever they appear. Never let a spawn inherit the session tier for mechanical work: a strong main loop must push work down, not do it.

## Claude-Specific Section

- Knob: `model:` and `effort:` on the `Agent` tool call.
- Judgment: `model: opus`, `effort: high`.
- Mechanical: `model: sonnet`, `effort: medium` (or `low` for pure transforms/lookups).
- Factual: `model: haiku`, `effort: low`.
- `fan-out`'s worker is a full `claude -p` subprocess launched by `fan-out.sh`, so its knobs are the CLI flags `--model` **and** `--effort` (verified: `claude --effort <level>` exists; `fan-out.sh:92-94` execs `claude -p … --model "$model"` and can pass `--effort` alongside). The worker is mechanical → `--model sonnet --effort medium`. The worker's **in-process** test-writer spawn (R6) is a normal `Agent` call and also takes `model: sonnet, effort: medium`.
- **Assumption to verify (not a settled fact):** that a `claude -p --dangerously-skip-permissions` subprocess (with `CLAUDECODE` unset, `fan-out.sh:91`) can spawn a *nested* `Agent` subagent that honors per-call `model:`/`effort:` — and, more basically, that `claude -p` print mode even exposes the `Agent`/Task tool. `fan-out/SKILL.md:13` permits one-level in-process delegation in doctrine, but this harness behavior is not demonstrated in code — the R6 live-run (Phase 4) is the gating check. It is a **gate that can fail**, not a foregone conclusion.
- **Claude-track fallback if the gate fails (symmetric to the Codex fallback at Phase 5):** if the Phase-4 live run shows a `claude -p` worker cannot spawn a nested `Agent` (or cannot honor its tier), do **not** fake the graft. Instead: (a) keep the worker's existing single-context Test phase but retain the anti-cheat framing (the worker still may not weaken assertions it wrote to the contract), (b) record the limitation in `docs/dev_plans/CODEX_MIRROR_BACKLOG.md` as a dated Claude-side note, and (c) amend the R6 Acceptance-Criteria item to require the logged limitation rather than the mirrored clean-context graft. R6's other deliverables (anti-cheat rule text, contract definition) still land; only the *separate-subagent* topology is conditional on the gate.
- Every `opus`/`high` spawn gets a `# opus/high: <reason>` comment (R3).

## Codex-Specific Section

- Knob: prose hint "Inherit the harness-selected model; request `reasoning_effort=X` when supported" — Codex does not pin model names.
- Judgment: `reasoning_effort=high`. Mechanical: `reasoning_effort=medium`. Factual/transform: `reasoning_effort=low`.
- The Codex mirror already implements this for `review-plan` and `deep-review`; the gaps are the same as Claude's: `conduct`, `plan-view`, and the `deep-review` **architecture** bump (currently `medium`, must go to `high` to match R1/R4).
- R6 test-writer graft mirrors into Codex `fan-out/agent-prompt.md` with `reasoning_effort=medium`.
- All edits via `codex:rescue`; log any remaining intentional divergence in `CODEX_MIRROR_BACKLOG.md`.

---

## Implementation Checklist

> **Track ownership.** Phase 1 (docs) and Phase 6 (verify) are shared. Phases 2–4 are the **Claude track** — authored and reviewed from the Claude harness (`model:`/`effort:`/`Agent`/`subagent_type`). Phase 5 is the **Codex track** — the section below is a *bounded brief*; the authoritative Codex phases and instructions are authored by Codex itself (via `codex:rescue`) after it reviews this plan, using its own idioms (`reasoning_effort`, `spawn_agent`, `fork_context`). **Sequencing: Phase 5 depends on Phases 2–4 being complete** (its "semantic alignment" is only checkable against the finalized Claude source) — do not parallelize the two tracks.

### Phase 1 — Encode the policy of record (docs)

**Impl files:** `AGENTS.md`, `README.md`, `docs/dev_plans/CODEX_MIRROR_BACKLOG.md`
**Test files:** (none — prose)
**Test command:** `rg -n "two-tier|judgment work|reasoning_effort" AGENTS.md`

- Add a "Model/Effort Policy" subsection to `AGENTS.md` (~line 46, near the intentional-divergence discussion) with the R1 two-tier policy + R2 inheritance invariant + the per-harness idiom split. Phrase it as the **target policy** the tree is converging to — the enforcing census (Phase 3) and full spawn compliance (Phases 2–4) land after this doc, and Phase 6 is the verification that the invariant actually holds; a reader between Phase 1 and Phase 6 should not read this as proof of current compliance.
- Add a one-line pointer from `README.md` where the skills' cost model is described (`README.md:14,84`).
- Note the upcoming annotation changes in `CODEX_MIRROR_BACKLOG.md` (not drift; per R4).

### Phase 2 — Claude: add effort + why-comments to already-model'd review/plan spawns

**Impl files:** `plugins/skein/skills/deep-review/SKILL.md`, `plugins/skein/skills/review-plan/SKILL.md`, `plugins/skein/skills/spec-compliance/SKILL.md`, `plugins/skein/skills/dev-plan/SKILL.md`
**Test files:** (none — prose)
**Test command:** `rg -n "effort:" plugins/skein/skills/{deep-review,review-plan,spec-compliance,dev-plan}/SKILL.md`

- `deep-review`: logic/security/spec → add `effort: high` + why-comment (SKILL.md:165,209,252). **Architecture → bump `model: sonnet`→`opus`, `effort: high`** + why-comment (SKILL.md:292); update the lens table (SKILL.md:75-79) and the sample state JSON (SKILL.md:60-64). Documentation → `haiku` + `effort: low` (SKILL.md:335). Rewrite the "diff-level architecture is cheaper, don't re-align" rationale that the bump overrides.
- `review-plan`: 4 judgment lenses → add `effort: high` + why-comment (SKILL.md:76,139,199,261); `codebase-claims` → `effort: low` (SKILL.md:327). Update the tier table (SKILL.md:23-27) and Cost section.
- `spec-compliance`: add `effort: high` + why-comment (SKILL.md:45).
- `dev-plan`: Explore → add `effort: medium` + comment (SKILL.md:84,98,237).
- **Atomic-commit constraint:** within each file, the lens/spawn header, its tier table, and its sample-state JSON must land in **one commit** — a partial commit (header bumped, table not) leaves the file self-contradictory. Applies to `deep-review` (header:292 + table:75-79 + JSON:60-64) and `review-plan` (headers + table:23-27 + Cost).

### Phase 3 — Claude: fill the unannotated spawns + fan-out default

**Impl files:** `plugins/skein/skills/conduct/SKILL.md`, `plugins/skein/skills/plan-view/SKILL.md`, `plugins/skein/skills/fan-out/SKILL.md`, `plugins/skein/skills/fan-out/fan-out.sh`, `plugins/skein/skills/content-draft/SKILL.md`, `plugins/skein/skills/content-review/SKILL.md`, `plugins/skein/skills/update-docs/SKILL.md`, `plugins/skein/skills/rfc-finder/SKILL.md`, new `tests/parity/test-spawn-tiers.sh`, `Justfile` (register the census in `parity-tests`)
**Test files:** new `tests/parity/test-spawn-tiers.sh` (cross-skill tier census — see below); `conduct/tests/test_skill_spawn_grep.sh` left untouched
**Test command:** `bash tests/parity/test-spawn-tiers.sh`

- `conduct`: implementer → `model: sonnet, effort: medium`; test-writer → `model: sonnet, effort: medium`; advisory reviewer → `model: opus, effort: high` + why-comment (SKILL.md:36,168, reviewer at :231). Keep `subagent_type: general-purpose`.
- `plan-view`: annotate the `--rich` single + sections spawns with `model: sonnet, effort: low` (SKILL.md:134-135,156,172).
- `fan-out`: flip `DEFAULT_MODEL="opus"`→`"sonnet"` (`fan-out.sh:7`); **add `--effort` support** to the spawn (`fan-out.sh:66-70,92-94`) defaulting to `medium`, and to the `FANOUT_MODEL`/usage doc (`fan-out.sh:15,22`); update SKILL.md Model line (`SKILL.md:247`) + spawn example (`SKILL.md:127`) to show `--model sonnet --effort medium` default, `--model opus` override for hard tasks + why-comment. **(C1 correction: `claude -p` accepts `--effort`; the earlier "model-only, no effort flag" framing was factually wrong.)**
- `content-draft`/`content-review` → `effort: medium`; `update-docs`/`rfc-finder` → `effort: low` (SKILL.md:46,54,29,33).
- **Mandatory (not optional) R2 guard — a NEW test, `tests/parity/test-spawn-tiers.sh`:** author a fresh cross-skill census (do **not** try to bend the conduct-scoped mention guard `test_skill_spawn_grep.sh`, whose scan root and forbidden-mention semantics are wrong for this job — widening its root would collide with legitimate sibling-skill mentions in fan-out/conduct). The census walks `plugins/skein/skills/*/SKILL.md` and asserts every documented spawn carries a tier annotation via a per-spawn/per-lens **expected-tier-count** assertion (e.g. review-plan has exactly 4 `effort: high` + 1 `effort: low`; deep-review architecture is `opus` not `sonnet`), not a bare `rg "effort:"` presence check (which passes on one match while three are missing). Also assert a **pinned total** of `opus`/`high` spawns (R1-derived: review-plan 4 + deep-review logic/security/spec 3 + deep-review architecture 1 + spec-compliance 1 + conduct reviewer 1 = **10**) each with an adjacent `# opus/high:` why-comment (R3 guard) — pinning the count makes the check falsifiable, so it cannot silently pass while checking zero spawns if the tier-detection regex misfires. Wire the new test into `just parity-tests`. This is the enforcing test for the R2 invariant — it is a required deliverable of this phase.

### Phase 4 — Claude: fan-out worker clean-context test-writer graft (R6)

**Impl files:** `plugins/skein/skills/fan-out/agent-prompt.md`, `plugins/skein/skills/fan-out/SKILL.md` (both the R6 graft **and** the `{{TECHNICAL_SPECIFICATIONS}}` injection at `SKILL.md:106-109` — add the Integration Seams rows with Writer designations), new `plugins/skein/skills/fan-out/test-writer-prompt.md`, new fixture + runner under `plugins/skein/skills/fan-out/tests/`, and `tests/parity/test-spawn-tiers.sh` (extend the Phase-3 census to include the new test-writer spawn)
**Test files:** `plugins/skein/skills/fan-out/tests/` (seeded-divergence fixture plan + `run-seeded-divergence.sh` runner + assertion); `tests/parity/test-spawn-tiers.sh` (updated count)
**Test command:** `rg -n "test-writer|contract wins|may not" plugins/skein/skills/fan-out/agent-prompt.md` (presence only — **not acceptance**) **plus** `bash tests/parity/test-spawn-tiers.sh` (census now expects the fan-out test-writer at sonnet/medium) **plus** the seeded-divergence runner below
**Validation cmd:** `bash plugins/skein/skills/fan-out/tests/run-seeded-divergence.sh` — drives a two-slice fixture plan where one slice's impl deliberately diverges from its contract; the runner asserts the test-writer's tests **fail on the divergent slice and pass on the conformant one** (exit non-zero otherwise). **Runner mode depends on the nested-spawn gate:** if the Phase-4 live run confirms a `claude -p` worker can spawn a nested `Agent` honoring its tier, the runner is a real end-to-end fan-out invocation; if that behavior is unavailable (see the Claude-track fallback in the Claude-Specific Section), the runner instead drives the test-writer prompt directly against the fixture contract and the corresponding Acceptance-Criteria item is marked **manual-verify**. Presence of the spawn text is never acceptance.

- **Isolate this phase to its own commit** — R6 is the only runtime/topology change; keeping it a single self-contained commit means the zero-risk annotation work (Phases 1–3) is not entangled with it and can be reverted/landed independently.
- **Make the contract source actually exist first (prerequisite for the graft).** Extend the `{{TECHNICAL_SPECIFICATIONS}}` injection at `fan-out/SKILL.md:106-109` so the orchestrator embeds the plan's Integration Seams rows **with an explicit per-row Writer column**, and define the mechanical extraction ("select rows where Writer == this slice") the test-writer prompt performs. Without this, the contract the graft depends on is not present in the worker prompt. (Corrects the earlier claim that the seams table already lives at `agent-prompt.md:86-91` — that line only *references* the table in self-review prose.)
- Rewrite agent-prompt.md **Phase 2 (Test)**: the worker spawns a **separate clean-context test-writer subagent** (`model: sonnet, effort: medium` + why-comment) **when the slice has an applicable test framework** (else keep the current "note it and continue" path, agent-prompt.md:43-44,66-71). The test-writer receives the **defined slice contract** — `{{TASK_DESCRIPTION}}` + the Writer-designated Integration Seams rows (with concrete signatures) now injected via `{{TECHNICAL_SPECIFICATIONS}}` — and **not** the implementer's diff.
- Add `test-writer-prompt.md` stating: write tests to the contract; do **not** read the implementation internals; return test files + its own one-shot run result (advisory — the worker re-runs them as the authoritative pass/fail).
- **Extend the Phase-3 tier census** (`tests/parity/test-spawn-tiers.sh`) to include the new fan-out test-writer spawn (expect `model: sonnet, effort: medium`), so R2 stays enforced for the exact spawn R6 introduces. This test edit lands in **this** commit alongside the graft.
- **Encode the anti-cheat rule in agent-prompt.md Phase 4:** the worker may not relax/delete/rewrite the test-writer's assertions; on impl-vs-test disagreement the **contract wins** — fix the implementation or escalate the divergence in the result file. This is R6's load-bearing invariant.
- **Add the seeded-divergence fixture + its runner** (gating acceptance): a two-slice fixture plan plus `plugins/skein/skills/fan-out/tests/run-seeded-divergence.sh` that asserts the divergent slice's contract tests **fail** and the conformant slice's **pass** (non-zero exit otherwise). Presence of the spawn text is not acceptance. The fixture's seam must be **well-specified** so the divergence is real signal, not import-naming noise — use a concrete example row, e.g. `Writer: slice-A | Interface: from fixture_pkg.adder import add | Signature: add(a: int, b: int) -> int`, with the divergent slice returning `a - b` (contract-violating) and the conformant slice returning `a + b`. Wire the runner into Phase 6's Test command (already added there).
- Update `fan-out/SKILL.md` to document the graft (one level in-process, `SKILL.md:13`; full `/conduct` per slice stays opt-in, `SKILL.md:15`). **Note:** `fan-out/SKILL.md` is also edited in Phase 3 — sequence Phase 4's edit onto Phase 3's version so they don't clobber.
- Confirm depth invariant: worker → test-writer is one in-process level; no new fan-out tier, no `/conduct` invocation. The nested-spawn-in-`-p` harness behavior is **to be confirmed by the live run (a gate that can fail)** — if it does not hold, take the Claude-track fallback in the Claude-Specific Section rather than assuming success.

### Phase 5 — Codex track (authored by Codex via codex:rescue)

> **Authoritative Codex phase.** This phase is authored from the Codex harness after reading the live Codex mirror. **Depends on Phases 2-4 being complete**: do not start until the Claude track has landed, because semantic alignment is only checkable against the finalized Claude source.

**Codex-perspective review findings to address in this phase:**
- The bounded brief's `conduct` line targets were not specific enough for Codex: the live mirror documents `spawn_agent`, `wait_agent`, and `close_agent` directly, with mandatory `fork_context=false` (`plugins/skein-codex/skills/conduct/SKILL.md:30,36,180`), but it currently has no role-tier hints for implementer, test-writer, or reviewer at the spawn decision points (`plugins/skein-codex/skills/conduct/SKILL.md:165-180,224,228`).
- `fan-out` is currently model-only: `fan-out.sh` defaults `DEFAULT_MODEL=""`, accepts only `[--model MODEL]`, parses only `--model`, and appends only `--model` to the `codex -p` command (`plugins/skein-codex/skills/fan-out/fan-out.sh:11,19,31,78,80-85,112-114`). Phase 5 must add an explicit effort/default story rather than only updating SKILL.md prose.
- R6 can mirror topologically on Codex if the `codex -p` worker runtime exposes the same delegation tools that this session and `/conduct` require: `/conduct` already treats Codex worker delegation as direct `spawn_agent` lifecycle calls with `fork_context=false` (`plugins/skein-codex/skills/conduct/SKILL.md:30,36,180`). Keep the effort part in the established Codex prose idiom — "request `reasoning_effort=medium` when supported" — rather than depending on a literal prompt field. Depth framing is equivalent to Claude: worker -> test-writer is one in-process delegation level inside the worker's current orchestrator tree; the process/worktree boundary simply re-baselines that tree when a fan-out-spawned Codex session invokes a top-level skill (`plugins/skein-codex/skills/fan-out/SKILL.md:13,15`). This is a mirrored graft unless the live runner proves the worker runtime lacks delegation support.
- Mirror parity is semantic, not wording-parity: `CODEX_MIRROR_BACKLOG.md:15` sanctions Agent-vs-`spawn_agent` wording differences, while `review-plan` requires the same lens roster and finding contract across mirrors (`plugins/skein-codex/skills/review-plan/SKILL.md:89,439-467`). Do not change the roster/schema while adding tier hints.

**Impl files:** `plugins/skein-codex/skills/deep-review/SKILL.md`, `plugins/skein-codex/skills/conduct/SKILL.md`, `plugins/skein-codex/skills/plan-view/SKILL.md`, `plugins/skein-codex/skills/fan-out/SKILL.md`, `plugins/skein-codex/skills/fan-out/fan-out.sh`, `plugins/skein-codex/skills/fan-out/agent-prompt.md`, new `plugins/skein-codex/skills/fan-out/test-writer-prompt.md`, `tests/parity/test-spawn-tiers.sh`, new `plugins/skein-codex/skills/fan-out/tests/run-seeded-divergence.sh` plus its fixture files, and, only if implementation discovers a non-mirrorable Codex runtime limitation, `docs/dev_plans/CODEX_MIRROR_BACKLOG.md`.
**Test files:** extend the new Phase-3 cross-skill tier census `tests/parity/test-spawn-tiers.sh` with Codex `reasoning_effort` expectations; add Codex-side fan-out seeded-divergence fixture coverage plus a runner equivalent to the Claude `run-seeded-divergence.sh`.
**Test command:** `bash tests/parity/test-spawn-tiers.sh` plus `bash plugins/skein-codex/skills/fan-out/tests/run-seeded-divergence.sh` (or the documented manual/direct-prompt mode if the Codex worker delegation gate fails). Keep the lightweight presence probe `rg -n "reasoning_effort=(high|medium|low)|contract wins|--effort|FANOUT_EFFORT" plugins/skein-codex/skills/{deep-review,conduct,plan-view,fan-out}` as a diagnostic only, not acceptance.

- `deep-review`: bump Architecture from `reasoning_effort=medium` to `reasoning_effort=high` in the live routing table (`plugins/skein-codex/skills/deep-review/SKILL.md:92-98`), the sample state JSON (`plugins/skein-codex/skills/deep-review/SKILL.md:286-306`), and the run summary (`plugins/skein-codex/skills/deep-review/SKILL.md:469-472`). Update the rationale text from "balanced reasoning cost" to the R1 review-tier rationale. Keep the generic finding schema untouched (`plugins/skein-codex/skills/deep-review/SKILL.md:330-358`).
- `conduct`: add Codex-native role routing prose near Delegation Pattern / Step 3 stating implementer = harness-selected model with `reasoning_effort=medium`, test-writer = harness-selected model with `reasoning_effort=medium`, and optional reviewer = harness-selected model with `reasoning_effort=high`; spawn all three with `fork_context=false`. Ground the edit at the current spawn lifecycle lines (`plugins/skein-codex/skills/conduct/SKILL.md:30,36,165-180,224,228`). Preserve the existing hard-stop when delegation tools are unavailable (`plugins/skein-codex/skills/conduct/SKILL.md:38-46`).
- `plan-view`: annotate both rich-render spawn shapes as mechanical/transform work with `reasoning_effort=low`: single-page rich render at `plugins/skein-codex/skills/plan-view/SKILL.md:133-135` and section-fragment rich render at `plugins/skein-codex/skills/plan-view/SKILL.md:172-180`. Do not add concrete Codex model names.
- `fan-out` default worker tier: add `DEFAULT_MODEL`/`FANOUT_MODEL` alignment to the Claude-side flip only if the finalized Claude Phase 3 changed the default to `sonnet`; otherwise keep the Codex default model inherited/empty and document why. Add explicit effort handling to the Codex launcher either as first-class `--effort`/`FANOUT_EFFORT` if Codex CLI supports that flag, or as `FANOUT_EXTRA_ARGS`-documented pass-through if the CLI has no dedicated flag. Update the current model-only script/doc sites (`plugins/skein-codex/skills/fan-out/fan-out.sh:11,19,31,78,80-85,112-114`; `plugins/skein-codex/skills/fan-out/SKILL.md:4,125-128,245-253`).
- `fan-out` contract-injection prerequisite: before the R6 graft, extend the `{{TECHNICAL_SPECIFICATIONS}}` injection so the Codex fan-out orchestrator embeds the plan's Integration Seams rows with explicit per-row Writer designations. The live Codex mirror currently injects only "Files to modify, architecture decisions from plan" (`plugins/skein-codex/skills/fan-out/SKILL.md:106-109`), while `agent-prompt.md` only references a seams table in self-review prose (`plugins/skein-codex/skills/fan-out/agent-prompt.md:86-91`). Define the mechanical extraction: the test-writer receives only rows where `Writer == this slice`, including concrete import paths, symbol names, and signatures.
- `fan-out` R6 graft: rewrite `agent-prompt.md` Phase 2 at `plugins/skein-codex/skills/fan-out/agent-prompt.md:65-71` so the worker conditionally spawns a clean-context test-writer subagent only when the slice has an applicable test framework; leave the no-framework note path intact. The test-writer receives `{{TASK_DESCRIPTION}}` plus the Writer-designated Integration Seams rows now injected through `{{TECHNICAL_SPECIFICATIONS}}` (`plugins/skein-codex/skills/fan-out/SKILL.md:106-114`; placeholders appear in `plugins/skein-codex/skills/fan-out/agent-prompt.md:15-21`), and must not receive the implementer's diff. The spawn uses `fork_context=false` and requests `reasoning_effort=medium` when supported.
- `fan-out` anti-cheat rule: extend Phase 4 at `plugins/skein-codex/skills/fan-out/agent-prompt.md:96-98` with the hard rule that the worker may not relax, delete, or rewrite test-writer assertions to make them pass; when implementation and tests disagree, the contract wins, so the worker fixes the implementation or escalates the divergence in `.fan-out-result.md`.
- Add `plugins/skein-codex/skills/fan-out/test-writer-prompt.md` mirroring the Claude contract in Codex wording: write tests to the supplied contract, do not read implementation internals, return changed test files and command results. Add/port the seeded-divergence fixture **and its runner** under `plugins/skein-codex/skills/fan-out/tests/`: use the same concrete seam shape as Claude (`from fixture_pkg.adder import add`, `add(a: int, b: int) -> int`, divergent `a - b`, conformant `a + b`) and make `run-seeded-divergence.sh` exit non-zero unless the divergent slice fails and the conformant slice passes. If the Codex worker runtime cannot spawn the test-writer, the runner must fall back to a documented direct-prompt/manual-verify mode and Phase 5 must log the limitation instead of claiming mirrored topology.
- Extend `tests/parity/test-spawn-tiers.sh` with Codex expectations rather than adding an untracked ad hoc grep. It must walk `plugins/skein-codex/skills/*/SKILL.md`, assert per-spawn/per-lens `reasoning_effort` expected counts (including the new fan-out test-writer), assert high-effort Codex review spawns carry their R3 why-comments or documented rationale, and be wired through `just parity-tests` alongside the Claude census (`justfile:26-33`). There is no existing Codex cross-skill tier census today (`tests/parity/` contains no `test-spawn-tiers.sh` in the live tree), so this is a required Phase-5 deliverable.
- Preserve review/deep-review shared contracts: do not alter the `review-plan` lens roster/routing identities except explicit tier text already aligned (`plugins/skein-codex/skills/review-plan/SKILL.md:30-38,91,154,214,276,342`), and do not alter the generic finding schema (`plugins/skein-codex/skills/review-plan/SKILL.md:439-467`).
- If implementation later proves `codex -p` workers cannot access `spawn_agent`/`fork_context=false` despite this session/runtime and `/conduct` support, or cannot request `reasoning_effort=medium` for that nested worker, do not fake parity. Keep the contract injection, anti-cheat wording, and direct/manual seeded-divergence runner; leave the clean-context Codex graft unimplemented; add a dated `Codex-track divergence` entry to `docs/dev_plans/CODEX_MIRROR_BACKLOG.md` using the backlog format (`docs/dev_plans/CODEX_MIRROR_BACKLOG.md:5-15`); and update this plan's Acceptance Criteria to require the logged divergence rather than mirrored R6.

### Phase 6 — Verify the invariant + docs sync

**Impl files:** (verification only)
**Test files:** all touched test files
**Test command:** `uvx pytest plugins/skein/skills/conduct/tests/ -q && bash plugins/skein/skills/conduct/tests/test_skill_spawn_grep.sh && bash tests/parity/test-spawn-tiers.sh && bash plugins/skein/skills/fan-out/tests/run-seeded-divergence.sh` (the last is the R6 gating fixture — see Phase 4; if the nested-spawn live behavior forces it to be a manual run, invoke it manually and record the result instead)

- Enumerate every spawn across both trees and assert each names a tier (R2 invariant — show the grep evidence, not just green tests). This manual enumeration is the authoritative R4 alignment check, since `check-prompt-parity.sh` does not cover SKILL.md tier bodies (see Phase 5 caveat).
- Confirm Claude↔Codex semantic alignment per spawn (same tier intent); confirm the deep-review architecture bump landed on both sides.
- Confirm the R6 seeded-divergence fixture passes (divergent slice fails, conformant passes) — the gating acceptance for R6.
- Run `/update-docs`; run `/deep-review` before merge.

---

## Technical Specifications

### Files to Modify

| File | Change |
|---|---|
| `AGENTS.md` | New Model/Effort Policy subsection (~L46) |
| `README.md` | Pointer to the policy (L14/L84) |
| `deep-review/SKILL.md` (both trees) | +effort/reasoning; **architecture opus/high** bump; table + state JSON |
| `review-plan/SKILL.md` (both trees) | +effort/reasoning on 5 lenses; table + Cost |
| `spec-compliance/SKILL.md` (both trees) | +effort/reasoning high |
| `dev-plan/SKILL.md` (both trees) | +effort/reasoning medium on Explore |
| `conduct/SKILL.md` (both trees) | fill implementer/test-writer (sonnet/med), reviewer (opus/high) |
| `plan-view/SKILL.md` (both trees) | annotate rich spawns sonnet/low |
| `fan-out/SKILL.md` + `fan-out.sh` | default `--model sonnet` + **add `--effort medium`**; docs; document R6 graft |
| `fan-out/SKILL.md` (both trees) — `{{TECHNICAL_SPECIFICATIONS}}` injection (`:106-109`) | **R6 prerequisite**: embed Integration Seams rows with per-row Writer designation so the test-writer contract source exists |
| `fan-out/agent-prompt.md` (both trees) | **R6**: Phase 2 delegates to clean-context test-writer (sonnet/medium); Phase 4 anti-cheat rule; conditional spawn |
| `fan-out/test-writer-prompt.md` (new, both trees) | **R6**: test-writer contract — write to contract, don't read impl |
| `fan-out/tests/` + `run-seeded-divergence.sh` (new, Claude tree) | **R6**: seeded-divergence gating fixture **plus its runner** (asserts divergent fails / conformant passes) |
| `tests/parity/test-spawn-tiers.sh` (new, Claude tree) + `Justfile` | **R2**: new cross-skill tier census walking `skills/*/SKILL.md`; wired into `just parity-tests`. Replaces the mistaken "extend the mention guard" plan |
| `content-draft`/`content-review`/`update-docs`/`rfc-finder` SKILL.md (both trees) | +effort/reasoning |
| `CODEX_MIRROR_BACKLOG.md` | log the annotation-idiom alignment + R6 mirror |

### Architecture Decisions

- **deep-review architecture lens bumped sonnet→opus/high** (user decision): under a blanket "code reviews use the strong model" policy the diff-vs-plan-level distinction no longer justifies a cheaper tier. Both mirrors move together (Codex `medium`→`high`).
- **fan-out worker → `--model sonnet --effort medium`** (user decision): the worker executes an already-scoped task; hard tasks opt up via `--model opus`. **Both** knobs are set — the earlier "model-only, no effort flag" claim was factually wrong; `claude -p` accepts `--effort` (C1 correction), so honoring the mechanical tier means setting effort too.
- **conduct reviewer is opus/high** (user decision) despite being the "lightweight" advisory check — it reviews code, so it gets the review tier.
- **fan-out worker gets a clean-context test-writer, not full conduct** (R6, user decision — Option C): grafts conduct's context-separation robustness without conduct's review-marker prerequisite; conduct-per-slice stays opt-in. This is the one deliberate topology addition (one new in-process spawn inside the worker); everything else is annotation-only.
- **R6 is kept folded into this plan but isolated** (user decision): it lands as its own phase + commit with a seeded-divergence gating fixture, so the zero-risk annotation work is not entangled with the one runtime change. The alternative (split into a separate PR) was considered and declined in favor of isolation-within-one-branch.
- **R6's contract-wins anti-cheat is load-bearing** (user decision — hard rule): the worker may not weaken the test-writer's assertions; divergence fixes the implementation or escalates. Without it, the worker owning both files could paper over the inconsistency R6 exists to surface.
- **Annotations + one default + one graft** — no other orchestration/topology change. No `## Architecture & Call Flow` section: the graft adds a single in-process delegation edge (worker → test-writer), not a new multi-component call flow.

### Integration Seams

- Claude `model:`/`effort:` ↔ Codex `reasoning_effort=` hint: semantically aligned, idiom-divergent by sanctioned convention (`CODEX_MIRROR_BACKLOG.md:15`).
- `deep-review`/`review-plan` per-lens tables, sample state JSON, and Cost prose must stay consistent with the per-lens annotations changed in the same file.
- **R6 test-writer contract (precisely defined)**: the test-writer receives `{{TASK_DESCRIPTION}}` + the Writer-designated Integration Seams rows (with concrete signatures), injected via `{{TECHNICAL_SPECIFICATIONS}}` — never the implementer's diff. agent-prompt.md carries several placeholders (`{{TASK_DESCRIPTION}}`, `{{TECHNICAL_SPECIFICATIONS}}`, plus worktree/context ones like `{{WORKTREE_PATH}}`/`{{BRANCH_NAME}}`/`{{CLAUDE_MD_CONTENT}}`/`{{TOOLCHAIN_CONTEXT}}`), but **none is a "public interface" artifact**, so the contract is exactly the `{{TASK_DESCRIPTION}}` + Writer-seam-rows extract. **Injection is a Phase-4 prerequisite** (the seams rows are not injected today, `fan-out/SKILL.md:106-109`). **Contract precision is a dependency**: a seam that under-specifies signatures yields noisy tests (false import failures), not signal — the seeded-divergence fixture must use a well-specified seam (see the concrete example in Phase 4) so it exercises real divergence, not naming noise.
- **R6 anti-cheat seam**: the worker owns both impl and test files; the contract-wins rule (worker may not weaken assertions) is what keeps the test-writer's verdict authoritative. This is the seam a reviewer must check — remove the rule and R6 is decorative.
- **Depth invariant**: fan-out worker → test-writer is exactly one in-process `Agent` level (permitted in doctrine, `fan-out/SKILL.md:13`; nested-spawn-in-`-p` behavior is a **gate to confirm at the live fixture run**, not an assumption to bake in — see the Claude-track fallback if it fails); it must not invoke `/fan-out` or `/conduct`.

---

## Review Focus

- **The invariant (R2), not just green tests**: prove every spawn in both trees names a tier. Enumerate them.
- **Mirror semantic alignment (R4)**: each spawn's tier intent matches across `skein` and `skein-codex`; the architecture bump landed on *both* sides.
- **Table/JSON/prose consistency** within `deep-review` and `review-plan` after per-lens edits — a bumped lens must be reflected in its tier table, sample state, and Cost section, not just the header.
- **R6 test-writer isolation**: verify the graft passes the test-writer the *contract*, not the implementer's diff — the robustness win depends entirely on this. Confirm the worker→test-writer edge is one in-process level and never calls `/conduct` or `/fan-out`.
- **Scope of topology change**: confirm the *only* topology addition is the R6 graft; every other change is annotation + the one `fan-out.sh` default. Spawn counts elsewhere, `subagent_type`, and handback contracts untouched.
- **Codex edits via `codex:rescue`** and any residual divergence logged.

---

## Testing Notes

Most changes are markdown; validation is (1) the **new, mandatory** cross-skill census `tests/parity/test-spawn-tiers.sh` asserting per-spawn expected tiers + a pinned total of 10 opus/high why-comments (the R2 enforcing test — a fresh test walking `plugins/skein/skills/*/SKILL.md`, **not** an extension of the conduct-scoped mention guard `test_skill_spawn_grep.sh`, which stays as-is), (2) the existing conduct `pytest tests/`, and (3) the Phase 6 manual enumeration for cross-tree R4 alignment (the parity script covers `rubric.md` + `agent-prompt.md` only, not SKILL.md tier bodies).

Three runtime behavior changes: fan-out's default worker `--model` (opus→sonnet) and new `--effort medium`, and the R6 test-writer graft. R6 is validated by a **gating seeded-divergence fixture with a runner** (`plugins/skein/skills/fan-out/tests/run-seeded-divergence.sh`) — a two-slice fixture plan where one slice's implementation deliberately diverges from its contract; acceptance requires the test-writer's tests to **fail on the divergent slice and pass on the conformant one** (the runner exits non-zero otherwise). Presence of the spawn text is not acceptance. The live run is also the **gate** for the one unverified behavioral assumption — whether a `claude -p` subprocess can spawn a nested `Agent` that honors its tier. If that gate fails, take the Claude-track fallback (single-context Test phase + anti-cheat + logged limitation) and mark the R6 fixture AC item **manual-verify**; do not assume success.

## Acceptance Criteria

- [ ] Every documented spawn in `plugins/skein/skills/**` names `model:` (and `effort:` where the harness supports it).
- [ ] Every documented spawn in `plugins/skein-codex/skills/**` names a `reasoning_effort` hint (or documents why not).
- [ ] Every opus/high (Claude) and reasoning_effort=high (Codex) spawn carries a why-comment (R3).
- [ ] deep-review architecture is opus/high on Claude and reasoning_effort=high on Codex; tables + sample state updated.
- [ ] fan-out worker default is `--model sonnet --effort medium`; `--model opus` override documented; `--effort` supported by `fan-out.sh`.
- [ ] The `{{TECHNICAL_SPECIFICATIONS}}` injection (`fan-out/SKILL.md:106-109`) is extended to embed the Integration Seams rows with per-row Writer designations, so the test-writer contract source actually exists in the worker prompt (R6 prerequisite).
- [ ] fan-out worker Phase 2 delegates to a clean-context test-writer (sonnet/medium) that receives the contract, not the implementer's diff (R6); conditional on a test framework; mirrored on Codex (or divergence logged per M4). **If the nested-spawn gate fails, the Claude-track fallback is taken and this item is satisfied by the logged limitation instead** (symmetric to Codex M4).
- [ ] R6 anti-cheat rule present: worker may not weaken test-writer assertions; contract wins. (Lands regardless of the nested-spawn gate.)
- [ ] R6 seeded-divergence fixture + `run-seeded-divergence.sh` runner passes: divergent slice fails contract tests, conformant slice passes — **or**, if the nested-spawn gate fails, this item is marked manual-verify and the runner drives the test-writer prompt directly against the fixture contract.
- [ ] New `tests/parity/test-spawn-tiers.sh` census (walking `plugins/skein/skills/*/SKILL.md`, wired into `just parity-tests`) asserts per-spawn expected-tier counts + a pinned total of 10 opus/high why-comments; it passes and would fail if a spawn were un-tiered (R2 enforcing test, not optional). The conduct-scoped `test_skill_spawn_grep.sh` mention guard is left intact.
- [ ] `AGENTS.md` states the two-tier policy + inheritance invariant.
- [ ] Phase 6 manual enumeration demonstrates R2/R4 across both trees (parity script does not cover SKILL.md tiers).

<!-- reviewed: 2026-07-04 @ 5f8fbe5edb954b00fbe3cbecc62e645b984a1eeb -->

<!-- /review-plan writes the marker line above. Everything below is the workspace: edits here do NOT invalidate the marker. -->

## Progress

_(per-phase completion recorded here by /conduct — below the marker, not part of the hashed contract)_

## Findings

_(durable findings recorded during implementation, below the marker)_

## Issues & Solutions

_(to be filled during implementation)_

## Final Results

_(to be filled on completion)_
