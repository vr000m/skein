# Design: Architecture map of .claude/skills/

**Status**: Draft (architecture overview, not implementation)
**Assigned to**: documentation
**Priority**: N/A
**Branch**: feat/plan-view-skill
**Date**: 2026-05-22

## Objective

Provide a single immersive view of the 11 user-defined skills under `.claude/skills/` — what each one consumes and produces, which subagents it spawns, and how they compose into end-to-end workflows. Test-target for `plan-view --rich` section fanout against architecture content rather than a dev plan.

## Context

The repo accumulated 11 skills as the author iterated on the dev-plan → review → conduct → fan-out → docs loop. Each skill has a `SKILL.md` whose front-matter trigger phrases land in `<system-reminder>` blocks at conversation start, but the *relationships* between skills — who calls whom, what marker files survive between invocations, where subagents are spawned — are not captured anywhere. The relationships matter because they form a pipeline: `/dev-plan` writes a marker, `/review-plan` consumes and updates that marker, `/conduct` reads it, `/fan-out` parses the same plan, `/update-docs` syncs against the result. A broken link in the pipeline — say a marker schema change — silently degrades every downstream skill. This document surfaces the contracts.

A second motivation: testing `plan-view --rich` against non-plan content. The skill was designed for dev-plan markdown corpora, but the section-fanout strategy is content-agnostic — anything with H2 boundaries fans out. If this document renders cleanly with widgets, the rich workflow generalises beyond its original brief.

## Skill Catalogue

| Skill | Role | Cost per run | Invocation Mode |
|---|---|---|---|
| `dev-plan` | Plan author — writes structured markdown with phases, Review Focus, Acceptance Criteria. | 1 Sonnet on `create` only. | model-invoked |
| `review-plan` | Pre-implementation auditor — 4 parallel lenses against a plan. | 3 Opus + 1 Haiku. | model-invoked |
| `conduct` | Phase-by-phase implementer dispatcher. | 2–3 subagents per phase. | model-invoked |
| `fan-out` | Parallel-task dispatcher across git worktrees. | 1 Opus per independent task (cap 5). | model-invoked |
| `deep-review` | Code review with 5 parallel lenses. | 3 Opus + 1 Sonnet + 1 Haiku. | model-invoked |
| `plan-view` | Dashboard + per-plan rich HTML renderer. | 0 for deterministic; 1 per plan or section for `--rich`. | **user-invoked** (`disable-model-invocation: true`, Claude only) |
| `update-docs` | Doc-vs-code drift auditor. | 1 Sonnet. | model-invoked |
| `content-draft` | TIL/blog drafter from session context. | 1 Sonnet. | model-invoked |
| `content-review` | Style/content reviewer for markdown. | 1 Sonnet. | model-invoked |
| `spec-compliance` | RFC 2119 normative-requirement mapper. | 1 Opus. | model-invoked |
| `rfc-finder` | RFC/draft locator with annotated links. | 1 Sonnet. | model-invoked |
| `grill` | One-question-at-a-time interview over a plan/design, splitting facts from decisions. | Same session, no subagent spawn (or one lens call if inlined by a caller). | model-invoked |
| `review-gauntlet` | Chains code-review/deep-review/security-review gates into one convergence loop with fixer subagents. | Up to 10 loop iterations, each spawning its own gate subagents. | model-invoked |
| `release` | Derives a GitHub release title+body (with an optional `## What's New` summary paragraph) from a `CHANGELOG.md` section and creates/re-syncs the git tag and release to match; `audit` mode scans every tag/CHANGELOG version repo-wide for missing tags, missing releases, or drift before fixing anything. | 0 subagent spawns — runs inline, no delegation (owns a user-confirmation gate before irreversible tag push / release publish). | **user-invoked** (`disable-model-invocation: true`, Claude only) |

Each skill is a single `SKILL.md` plus optional helper scripts. Skills are loaded by the Claude Code harness on session start; trigger phrases in their `description:` front-matter drive automatic activation — **unless** `disable-model-invocation: true` is set, in which case the skill is reachable only via explicit `/skill-name` invocation and its `description:` is excluded from per-turn context (see [Invocation Mode](#invocation-mode) below). This is a Claude-only mechanism; Codex CLI has no equivalent opt-out (see that section for the classification methodology and the one skill currently affected).

## Input Contracts

Inputs partition cleanly into four shapes:

- **Plan-file consumers** — `review-plan`, `conduct`, `fan-out`, `plan-view`, `update-docs` all take a markdown plan path (or a directory of them). Each reads the same `docs/dev_plans/yyyymmdd-type-name.md` schema produced by `dev-plan`.
- **Code-file consumers** — `deep-review`, `spec-compliance`, `content-review` take a code file path (or PR number / branch). Output is independent of plan state.
- **Session-context consumers** — `content-draft` reads the live conversation transcript. No file input.
- **Free-text consumers** — `rfc-finder` takes a topic, RFC number, code snippet, or protocol family as a string.

Cross-cutting CLI patterns: `--apply` (commit edits automatically), `--dry-run` (show what would happen), `--auto-fix=trivial` (apply allowlisted mechanical edits — `review-plan` and `deep-review` only), `--continue` / `--resume` (recover from a prior partial run — `deep-review` and `conduct`).

## Output Contracts

Outputs partition by *persistence model*:

- **Markdown writes into the repo** — `dev-plan` writes new plan files; `review-plan` appends a review marker; `conduct` updates Progress checkboxes and Findings; `update-docs` patches sibling docs.
- **HTML writes into a derived directory** — `plan-view` writes `docs/_plan_view/*.html` and `_fragments/*.html`. Drift-guarded by `plan-view-source-sha256` meta tags.
- **State files under hidden dirs** — `.conduct/state-<plan-id>.json`, `.deep-review/latest-claude.json`, `.review-plan/*.json`, `.fan-out-state.json`, `_rich_manifest.json`. These are resume points and audit trails — not committed.
- **Console-only reports** — `content-review`, `spec-compliance`, `rfc-finder` return structured findings to the conversation. No files written unless the user explicitly requests it.
- **Git side effects** — `conduct` commits at phase boundaries (`conduct: phase <n> — <title>`); `fan-out` creates branches and worktrees, then merges; `update-docs` may commit when run with `--apply`; `release` pushes a git tag (`vX.Y.Z`) and creates/edits a GitHub release — the only skill that mutates state outside the repo itself.

The **review marker** `<!-- reviewed: YYYY-MM-DD @ <sha1> -->` is the single most-load-bearing cross-skill artefact: written by `review-plan`, consumed by `conduct` (refuses to run if absent or stale), referenced by `update-docs` (flags plans where code changed after the marker SHA).

## Subagent Topology

Skills divide into four subagent-shape buckets:

- **Single Sonnet** — `dev-plan create`, `content-draft`, `content-review`, `update-docs`, `rfc-finder`. One call per invocation, mostly to gather facts (Explore) or draft prose.
- **Single Opus** — `spec-compliance`. RFC 2119 mapping benefits from the harder model on a single shot.
- **Parallel lens panel** — `review-plan` (5 lenses: architecture / sequencing / spec-and-testing / assumptions / codebase-claims), `deep-review` (5 lenses: logic / security / spec / architecture / documentation). Lenses run in fresh-context subagents and a reconciler folds duplicates.
- **Iterative dispatcher** — `conduct` spawns 2–3 subagents *per phase* (implementer, test-writer, optional reviewer) and loops the phase until tests pass or `--max-iterations` is hit. `fan-out` spawns one subagent per *independent task* (cap `--max-agents`, default 5), each in its own git worktree.

`plan-view` is the outlier: deterministic Python by default (0 subagent calls), with an opt-in `--rich` workflow that emits a manifest the *parent* agent consumes — the skill itself does not dispatch. This is the contract being tested by this document.

The model tier is not arbitrary: lens panels mix tiers because cheap lenses (Haiku for codebase-claims, documentation) absorb verbose factual checks while expensive lenses (Opus for architecture, security) handle judgement calls. `deep-review` lands at 5 lenses because code review has more orthogonal axes than plan review.

### Model / Thinking-Level Routing

Each skill subagent/lens is assigned a model + reasoning tier. The Claude and Codex mirrors express the **same intent** in different forms: Claude pins a concrete `model:` (`opus` / `sonnet` / `haiku`), while Codex inherits the harness-selected model and expresses tier as a `reasoning:` / `reasoning_effort:` level (`high` / `medium` / `low`). The two columns therefore differ in **form, not intent** — `opus ≈ reasoning: high`, `sonnet ≈ reasoning_effort: medium`, `haiku ≈ reasoning: low`.

| Skill | Subagent / lens | Claude | Codex |
|-------|-----------------|--------|-------|
| dev-plan | Explore | `model: sonnet` | `reasoning_effort: medium` |
| review-plan | architecture | `model: opus` | `reasoning: high` |
| review-plan | sequencing | `model: opus` | `reasoning: high` |
| review-plan | spec-and-testing | `model: opus` | `reasoning: high` |
| review-plan | assumptions | `model: opus` | `reasoning: high` |
| review-plan | codebase-claims | `model: haiku` | `reasoning: low` |
| plan-view | (none — deterministic Python) | — | — |
| conduct | per-phase subagents | (per phase) | (per phase) |

`conduct` does not pin a tier: its per-phase implementer / test-writer / reviewer subagents inherit the conductor's model, and the phase contract (not this table) governs their work. `plan-view` dispatches no subagents by default.

**Maintenance note.** This table MUST be updated whenever any skill/lens model or reasoning-effort assignment changes — the same discipline applied to the dual-manifest version bump (a routing change that lands in only one mirror is a silent drift). The source of truth is each skill's `SKILL.md` dispatch annotation: Claude `#### <Lens> Lens (model: …)` headers, Codex `#### <Lens> Lens (reasoning: …)` headers, and the dev-plan Explore routing hint. A lightweight check that diffs this table against those annotations is a possible follow-up, not in scope here.

## Composition Graph

```
dev-plan ──writes──▶ plan.md ──┬──▶ review-plan ──appends marker──▶ plan.md
                                ├──▶ plan-view (deterministic) ──▶ index.html + plan-<slug>.html
                                ├──▶ plan-view --rich ──▶ plan-<slug>.rich.html
                                ├──▶ conduct ──reads marker──▶ commits per phase
                                ├──▶ fan-out ──parses Checklist──▶ N worktrees ──▶ merge
                                └──▶ update-docs ──audits──▶ sibling doc edits

deep-review ──reads──▶ code + PR + optional plan Review Focus
spec-compliance ──reads──▶ code + RFC section ◀──referenced by── rfc-finder
content-draft ──reads──▶ session transcript ──suggests──▶ content-review
```

Explicit composition handoffs:

- `dev-plan` → `review-plan` → `conduct`: the canonical pipeline. Each step refuses to run if the prior step's artefact is absent.
- `dev-plan` → `fan-out`: alternative to conduct for tasks with disjoint file scopes.
- `review-plan` ↔ `deep-review`: mirror architectures; share the lens-reconciliation infrastructure (`scripts/reconcile-findings.sh`).
- `rfc-finder` → `spec-compliance`: discovery → conformance.
- `content-draft` → `content-review`: draft → polish.
- `dev-plan` ↔ `update-docs`: bidirectional — update-docs audits dev plans, dev-plan creates the plans it audits.

## Workflow Scenarios

**Feature implementation (full pipeline).** `/dev-plan create feature X` → human edits → `/review-plan` (4 lenses, fix Critical/Important) → `/plan-view --rich` (verify shape) → `/conduct` (phase 1, phase 2, …) → `/deep-review --pr N` (5 lenses on the resulting diff) → `/update-docs --apply` → PR merge.

**Independent parallel work.** `/dev-plan create feature Y` (multiple disjoint checklist phases) → `/review-plan` → `/fan-out` (5 worktrees, 5 subagents) → `/fan-out merge` → `/deep-review` → `/update-docs`.

**Drift audit.** `/plan-view docs/dev_plans/` (deterministic dashboard, no LLM cost) → identify stranded `In Progress` plans → for each, `/update-docs --pr N` to see what shipped without doc updates.

**Spec work.** `/rfc-finder "WebRTC ICE restart"` → user picks RFC 8839 §4.4.1 → `/spec-compliance src/ice.ts RFC8839 4.4.1` → MUST/SHOULD/MAY mapping.

**Writing about the work.** Mid-session, `/content-draft til` → drafted markdown → `/content-review` → polished TIL.

## Cost Model

Per-run subagent token spend, rough order of magnitude:

- **Cheap** (1 Sonnet/Haiku call): `dev-plan` (create only), `content-draft`, `content-review`, `update-docs`, `rfc-finder`, `plan-view --rich` per section.
- **Single hard call** (1 Opus): `spec-compliance`.
- **Lens panel** (3–4 Opus + 1 Haiku/Sonnet in parallel): `review-plan`, `deep-review`. These are intentionally expensive — the value is catching things a single pass misses, and the lenses do not share context.
- **Open-ended dispatch** (N parallel, N depends on plan shape): `conduct` (2–3 per phase × phases), `fan-out` (1 per independent task, cap 5 by default).

The pipeline cost is *not* additive: `review-plan` runs once before implementation; `conduct` runs once during; `deep-review` runs once on the resulting PR. A feature with 5 phases ships for roughly: 1× `dev-plan` + 1× `review-plan` (~4 lenses) + 5× `conduct` phases (~3 subagents each) + 1× `deep-review` (~5 lenses) + 1× `update-docs` ≈ 27 subagent calls. Long-running implementation work amortises the planning cost across multiple phases.

## Trigger Phrases

Triggers fall into three classes:

- **Slash commands** — `/dev-plan`, `/review-plan`, `/conduct`, `/fan-out`, `/deep-review`, `/plan-view`, `/update-docs`, `/content-draft`, `/content-review`, `/spec-compliance`, `/rfc-finder`, `/release`. Exact, unambiguous.
- **Imperative phrases** — `"plan this"`, `"audit plan"`, `"thorough review"`, `"step through plan"`, `"fan out"`, `"render plan dashboard"`, `"draft a TIL"`, `"check compliance"`. Surface in the `description:` front-matter; the harness fuzz-matches.
- **Implicit keywords** — `"RFC"`, `"IETF"`, `"WebRTC"`, `"QUIC"` for `rfc-finder`; `"MUST"` / `"SHOULD"` / RFC 2119 vocabulary for `spec-compliance`. These prime activation but the user typically still has to express intent.

Triggers are aggressive on purpose — a missed slash command costs a user a turn; a false-positive slash command is recoverable. `description:` strings explicitly enumerate the colloquial phrasings the author types, learned by iterating with real sessions.

## Invocation Mode

Every skill's `description:` is loaded into per-turn context by default so the harness can fire it autonomously (**model-invoked**). Claude Code's `disable-model-invocation: true` front-matter flag opts a skill out of that: its `description:` is excluded from per-turn context, and it becomes reachable only via explicit `/skill-name` invocation (**user-invoked**). This is a Claude-only mechanism — Codex CLI has no equivalent opt-out as of this writing; a skill marked user-invoked on Claude stays autonomously invocable on Codex regardless, documented as a permanent, harness-imposed divergence via a one-line comment on the Codex `SKILL.md`.

**Classification discipline for new skills.** Before writing a new skill's `description:`, check it against two axes — a skill must stay model-invoked if *either* is true:

- **Axis 1 — chained-into.** Does any other skill's `SKILL.md` invoke this one by literal `/name`, `skein:name`, or bare-backticked-name text as a mandatory, autonomous step in its own procedure (not merely a suggestion offered to the user)? If yes, disabling breaks that caller — this is a hard exclusion, not a judgment call.
- **Axis 2 — independently content-triggered.** Does the skill's own `description:` fire on content the user didn't have to name the skill to produce (e.g. `rfc-finder`'s RFC/protocol keywords) — genuine natural-language intent, not command-name-adjacent phrasing only someone who already knows the skill would say?

A skill is only a real `disable-model-invocation` candidate if it clears **both** axes. As of the 2026-07-12 audit (`docs/dev_plans/20260711-chore-skill-invocation-mode-audit.md`), 1 of 13 skills — `plan-view` — clears both; the other 12 are either chained into (`conduct`, `dev-plan`, `review-plan`, `review-gauntlet`, `deep-review`) or carry a genuine Axis 2 trigger (`content-draft`, `content-review`, `fan-out`, `grill`, `rfc-finder`, `spec-compliance`, `update-docs`). Re-run this same two-axis check whenever a skill is added or its chaining relationships change — don't default to leaving new skills model-invoked out of habit; that's exactly the drift this audit corrected.

**`release` (added 2026-07-12, `docs/dev_plans/20260712-feature-release-skill.md`) is classified `user-invoked` at birth**, using the same two-axis test rather than defaulting to model-invoked: Axis 1 — nothing chains into it, no other `SKILL.md` invokes `/release` or `skein:release`; Axis 2 — its trigger phrases ("cut a release", "publish this release", "sync release notes") are command-name-adjacent, the kind of thing only someone who already knows a release-cutting tool exists would say, the same character as `plan-view`'s cleared Axis 2. It also mutates external, hard-to-reverse state (git tag push, public GitHub release) — an independent reason it must never fire off conversational context alone, reinforcing rather than substituting for the two-axis result. 2 of 14 skills now clear both axes.

## Failure Modes

Each skill has explicit guards that refuse to run rather than produce a degraded artefact:

- **`review-plan`** refuses on a plan with no `## Objective` or no `## Implementation Checklist` — these are the lens input contract.
- **`conduct`** refuses on a plan with no review marker, a marker SHA that doesn't match the current plan content, or no `## Acceptance Criteria` per phase.
- **`fan-out`** refuses on tasks that share file paths in `Integration Seams` — those are not independent.
- **`deep-review`** refuses on a dirty working tree (commits not pushed), an unknown PR base, or a lens that returns an unparseable envelope.
- **`plan-view`** refuses to overwrite a generated file whose embedded `plan-view-source-sha256` matches the recomputed render sha but whose rendered HTML differs — implies a hand-edit. `--force` overrides.
- **`update-docs`** refuses to commit if the diff scope doesn't match the branch base (catches local-worktree confusion noted in the user's CLAUDE.md).
- **`spec-compliance`** refuses on a spec URL it cannot fetch or parse for normative language.
- **`content-draft`** / **`content-review`** refuse on empty session context (nothing to draft) or empty input files.
- **`rfc-finder`** returns "no matching RFC" rather than guessing.

The pattern is consistent: skills prefer empty/refusal output over plausible-looking wrong output. This is what makes them safe to chain.

## Extension Points

Several skills are designed to be reused as primitives by other skills:

- **`scripts/reconcile-findings.sh`** — shared by `review-plan` and `deep-review` for cross-lens dedup; envelope schema versioned.
- **Review marker contract** (`<!-- reviewed: YYYY-MM-DD @ <sha1> -->`) — the integration point between `review-plan` and `conduct`; could be consumed by any skill needing "has this been audited recently."
- **Plan-view manifest** (`_rich_manifest.json`) — declarative description of work to fan out; consumable by any agent harness that wants to spawn parallel subagents against H2 sections.
- **Auto-fix manifest** (`.review-plan/auto-fix-<unix>-<pid>.json` / `.deep-review/auto-fix-<unix>-<pid>.json`) — append-only audit trail of automated edits with `kind`, evidence path, and revertible patch.
- **Widget toolkit** (`.claude/skills/plan-view/_widgets/`) — `base.css`, `tabs.html`, `state-machine.svg.html`, `compare.svg.html`, `timeline.html`, `table.html`. Currently scoped to `plan-view --rich` but the widget shapes generalise to any LLM-rendered single-page artefact (this document, for instance).

The deliberate constraint surface in each extension point is what allows the skills to compose without leaking implementation. A skill consumes another skill's *artefact*, never its *internal state*.

## Glossary

- **Lens** — a fresh-context subagent with a single review axis (e.g. "security"). Lenses do not share context; a reconciler folds outputs.
- **Reconciler** — `scripts/reconcile-findings.sh`; merges lens envelopes into one report with raw/merged/unique/related counts.
- **Review marker** — markdown HTML comment written by `review-plan` containing date and content SHA. Required by `conduct`.
- **Render sha** — `plan-view`-specific composite of plan markdown SHA + corpus-derived edges + status bucket. Distinct from plain markdown SHA so that corpus changes invalidate the rendered HTML.
- **Auto-fix tier** — currently only `trivial`: hard-coded allowlist of semantics-preserving fixes. Opt-in via `--auto-fix=trivial` on `review-plan` and `deep-review`.
- **Worktree** — git worktree created by `fan-out` for one independent task; isolated branch + filesystem; merged on `fan-out merge`.
- **Phase** — `conduct`-recognised `### Phase N` subsection inside `## Implementation Checklist`, with its own Impl files, Test files, Test command.
- **Strategy: sections** — `plan-view --rich` mode for large plans; one subagent per H2 in parallel; stitched by `--rich-assemble`.
- **Envelope** — JSON contract returned by lenses to the reconciler; versioned (`ENVELOPE_SCHEMA_VERSION`).
- **Drift guard** — `plan-view`'s detection of hand-edited generated HTML; compares stored vs recomputed render sha.
