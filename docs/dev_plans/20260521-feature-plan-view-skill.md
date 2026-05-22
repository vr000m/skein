# Feature: `plan-view` — HTML dashboard for dev-plan corpora

**Status**: Shipped — `feat/plan-view-skill`; v1 cut as described below, plus `--rich` mode + widget toolkit added in the same pass (see "Changes from initial design" item 4 and "`--rich` workflow" below)
**Component**: planning-skills
**Assigned to**: Claude (skill author), user (design + review gates)
**Priority**: Medium
**Branch**: `feat/plan-view-skill`
**Created**: 2026-05-21
**Completed**: 2026-05-21

## Objective

Add a `/plan-view` skill that distills a directory of markdown dev plans into a self-contained HTML dashboard plus per-plan drill-down pages. Surfaces status, typed cross-references, git-derived timeline, and review-state so corpus-level drift is visible at a glance. Generic over any project with a `docs/dev_plans/`-style convention; koda-pipecat is the first concrete consumer (51 plans).

## Context

The trigger was the Anthropic blog post on the [unreasonable effectiveness of HTML in Claude Code](https://claude.com/blog/using-claude-code-the-unreasonable-effectiveness-of-html) — markdown can express *content* well but not *structure across many documents*: status chips, typed cross-reference edges, timeline strips, drift state. The user's koda-pipecat repo has 51 markdown dev plans under `docs/dev_plans/`, churning hard (last 20 doc commits are mostly "sync sibling plans", "mark phases done", "correct stale review marker hash"). That churn is the source-of-truth drift this skill is meant to make visible.

Three signals told us the skill was worth building over alternatives:

1. **The README is already authoritative for status grouping.** koda's `dev_plans/README.md` contains hand-maintained tables under `## In Progress / Partially Shipped`, `## Planned`, `## Shipped`, `## Paused / Abandoned`. A dashboard that respects that grouping (rather than reinventing it from per-plan headers) lets the human stay the source of truth.
2. **The conventions are tight enough for regex.** Status headers use one of three styles (inline bold, multi-line bold field block, YAML frontmatter); cross-references use four typed patterns (`Follows:` / `tracked in` / `superseded by` / `structurally fixed by`). 51 plans × pure regex finishes in well under a second — no subagent call per plan needed.
3. **Drift is the high-value signal.** The dashboard's job is not just to render plans but to make stale ones loud — `In Progress` plans whose last git-touch is >30 days, `bug-*` plans without a shipped `structural-fix-of` edge, and edited-HTML-without-edited-source (hand-edit detection via embedded sha256).

Not building this would leave the koda corpus reviewable only via filesystem `ls` + per-file open. The dashboard is the corpus-level lens that doesn't exist anywhere else.

## Requirements

### Invocation contract

- `/plan-view <plans-dir>` runs `python3 .claude/skills/plan-view/generate.py <plans-dir>` and is also discoverable via the skill's `description:` triggering language ("plan view", "render dev plans", "render plan dashboard").
- Flags: `--out <dir>` (default `<plans-dir>/../_plan_view/`), `--force` (overwrite drift-guard refusal), `--stale-days N` (default 30), `--gitignore` (write `*` into output dir on first run).
- Stdlib-only Python 3 — no external deps. Renderer must complete a 51-plan corpus in under one second.

### Output surface

- `index.html` — dashboard grouping plans by component, status chips, clickable filter buttons (multi-select, clear), cross-reference pills typed by edge kind.
- `plan-<slug>.html` — per-plan drill-down with status header, commit-history strip (inline SVG ticks with hover tooltips via `<title>`), cross-reference list, and the full rendered markdown body.
- Both files embed drift-guard meta tags (`plan-view-source-sha256`, `plan-view-source-path`, `plan-view-git-head`, `plan-view-generated-at`).

### Parser contract

Patterns documented in `parser.md` (regex catalogue, status lexicon, edge-typing precedence). Three status-header styles supported; four typed edge patterns plus a `references` catch-all; YAML frontmatter accepted for title/branch/created/owner/priority. README grouping wins when present.

### Status state machine

- **Green / Shipped** — status parses to Shipped / Complete / Merged, OR `Phases N-M shipped` where M ≥ total phase count.
- **Amber / In Progress / Partial** — Partially Shipped, In Progress, In Review, or `Phase N shipped` with N < total.
- **Blue / Planned** — Not Started / Planned.
- **Grey / Paused** — Paused / Abandoned.
- **Red / Stranded** — `in-progress` or `partial` AND last git-touch > `--stale-days`. This is the drift signal.
- Unparseable status → amber + "?" badge (not red — unparseable is noisy, shouldn't shout).

`bug-*` and `fix-*` plans get an additional `bug` chip and participate in the fixed-by → footer logic: a bug plan with a `structural-fix-of` edge to a shipped plan shows "fixed by → <fix>" in green.

### Drift guard

- Every output file embeds the source markdown's sha256.
- On regen, if existing output's embedded sha256 matches current source sha256 AND a *stable-content* hash differs (volatile fields like `generated-at` stripped), refuse to overwrite without `--force`. This catches hand-edits without false-positiving on legitimate idempotent regen.
- If source sha differs from embedded sha, overwrite freely (source changed).

## Architecture

### Skill layout

```
.claude/skills/plan-view/
├── SKILL.md           # trigger, contract, invocation guide
├── parser.md          # regex catalogue + status lexicon (reference doc)
├── generate.py        # stdlib-only generator (single file, ~1.1k loc)
├── template.html      # dashboard scaffold with {{PLACEHOLDER}} substitution
└── plan-template.html # per-plan drill-down scaffold
```

`generate.py` sections in order: constants (status lexicon, edge regex; component is read per-plan, not pattern-matched) → dataclasses (`Plan`, `Edge`, `Commit`) → plan parsing (frontmatter, status, fields, edges, checkboxes, phases) → README reconciliation → git collection → edge linking → stranded detection → minimal markdown renderer → HTML escape helpers → dashboard rendering → per-plan rendering → drift guard → arg parsing + main.

### Parser strategy

Pure regex on markdown — 51 plans × subagent would be wasteful. Patterns live in `parser.md` and the constants block of `generate.py`. Edge precedence: `structural-fix-of` > `supersedes` > `tracked-in` > `follows` > `references` (catch-all). Slugs may appear after bare token, backtick, bracket, paren, OR inside a markdown link `[title](slug.md)` — the `_SLUG_PREFIX` snippet handles all forms.

### Component grouping

**Each plan declares its own component** in a `**Component**` bold-field header, parsed exactly like `**Status**` (inline-bold form and field-table-row form both accepted). The dashboard groups by the exact, case-normalised string. Plans with no `**Component**` field fall into an `(uncategorized)` group.

**Ordering** is by plan count descending (busiest component first), alphabetical tiebreak, with `(uncategorized)` forced last. There is no `COMPONENT_ORDER` constant — order is derived from the corpus.

**Superseded:** the original v1 design inferred the component from a filename-slug heuristic (`COMPONENT_PATTERNS` / `COMPONENT_ORDER`) with koda-pipecat-specific token lists, and a deferred `.plan-view.yml` config override. Both were removed before this branch shipped. Rationale below.

#### Why a declared field beats inference or a config file

The skill's headline principle is "the markdown remains the source of truth." A slug heuristic encodes the component in *one renderer's* private patterns; a config file is a *second* authority that drifts from the plans it describes. Declaring the component **in the plan** keeps a single source of truth and makes the value reusable by every downstream consumer (`update-docs`, `dev-plan`, the `dev_plans/README.md` index, plain `rg`), not just plan-view. It also deletes the YAML-vs-TOML format question (and the stdlib-only-dependency tension that came with it).

#### Per-field ownership model

Metadata about a plan lives on two surfaces — the plan header and `dev_plans/README.md` (which doubles as the changelog via its Shipped tables). Each field has one canonical owner; the others derive:

| Field | Canonical source | Derived into |
|-------|------------------|--------------|
| **Component** | the plan's `**Component**` field | README column; changelog/Shipped rows |
| **Status** | README section membership (curated lifecycle judgment) | plan `**Status**` is the fallback/detail |
| Branch / Created / PR | plan header + git | README columns |

Component flips the precedence relative to status: status is a curated judgment so the README wins; component is intrinsic to the plan so the plan wins. plan-view's existing "README grouping wins" rule therefore applies to **status only**, not component.

#### Propagation pipeline (reuses existing skills)

No new machinery — three skills already form the stages:

1. **`dev-plan`** (author) — emits a `**Component**` field on `create`, inferred from the objective/slug and confirmed with the user (same as it seeds `**Status**`).
2. **`update-docs`** (reconcile) — reads each plan's `**Component**`, ensures the README row carries it, and **warns on drift rather than overwriting** (non-destructive, matching its existing stance).
3. **`plan-view`** (render) — reads the field; no slug heuristic, no config.

**Why reconcile, not regenerate:** the README has rows with no backing plan file ("Shipped without a dedicated dev-plan file"). Those can never derive a component from a plan, so the README must stay hand-curatable — it is not a pure generated view. Therefore `update-docs` reconciles the overlap and warns on mismatch; it never regenerates the README wholesale.

> **Naming note:** "component" in `20260504-feature-skill-improvements-from-usage-report.md` refers to update-docs's *file-overlap match heuristic* (a primary plan's `Files to Modify` paths searched against sibling plan bodies). That is a different concept from this `**Component**` grouping field — a homonym, not the same feature. The sibling-plan-update rule does not require changing that plan.

### Output ergonomics

Output directory defaults to `<plans-dir>/../_plan_view/` — sibling of the plans dir, doesn't pollute it. Not auto-gitignored; opt-in via `--gitignore` flag. The repo decides whether to commit the views; the skill is policy-neutral.

## Files to create

| Path | Purpose |
|------|---------|
| `.claude/skills/plan-view/SKILL.md` | Trigger language, invocation contract, design notes |
| `.claude/skills/plan-view/parser.md` | Regex catalogue + status lexicon reference |
| `.claude/skills/plan-view/generate.py` | Stdlib-only generator (~1.1k loc) |
| `.claude/skills/plan-view/template.html` | Dashboard scaffold with inline CSS + filter JS |
| `.claude/skills/plan-view/plan-template.html` | Per-plan scaffold with sticky nav + commit strip |
| `docs/dev_plans/20260521-feature-plan-view-skill.md` | This plan |
| `.gitignore` | Add `docs/_plan_view/` (generated, derived from source) |

Do **not** author under `.codex/skills/plan-view/` — that mirror is managed by sync scripts.

## Acceptance criteria

- Skill triggers from `/plan-view <plans-dir>` and from natural-language phrasing in the `description:` field.
- Runs against koda-pipecat's 51 plans in under one second with no errors.
- README-driven grouping reconciles against the four canonical buckets (In Progress / Planned / Shipped / Paused).
- Typed edges extracted: ≥3 `follows`, ≥3 `tracked-in`, ≥1 `structural-fix-of`, plus bare `references`. Edge precedence respected (higher-precedence type wins for the same target).
- Drift guard: second regen with no source changes is idempotent (no file writes); hand-edit detection refuses to overwrite without `--force` and prints the affected path.
- Stranded detection: `--stale-days 3` re-colours expected in-progress plans red; `--stale-days 30` (default) leaves a recently-refreshed corpus all-green.
- Clickable status chips filter cards; multi-select; component sections hide when empty; clear button appears only when filters are active.
- `ruff format` and `ruff check` clean.

## Verification

End-to-end against the koda-pipecat corpus:

1. `python3 .claude/skills/plan-view/generate.py ~/Code/pipecat-ai/koda-pipecat/docs/dev_plans/` — expect "50 plans · wrote 51 file(s) · refused 0".
2. Open `~/Code/pipecat-ai/koda-pipecat/docs/_plan_view/index.html`. Confirm status chips clickable, component grouping matches the README's four buckets, cross-ref pills typed correctly on representative plans.
3. Open `plan-20260506-feature-bot-harness-decoupling.html`: confirm rendered markdown, status header, commit-history strip with hover tooltips, drift-guard meta tags present.
4. **Drift-guard test**: hand-edit a generated file, rerun without `--force` — confirm refusal with path and diff hint. Rerun with `--force` — confirm overwrite.
5. **Stranded test**: run with `--stale-days 3` — confirm expected number of in-progress plans flip red.
6. **Self-host**: run the skill against this repo (`docs/dev_plans/`) and confirm the output renders the skills.md plan corpus consistently.

## Changes from initial design

The plan above reflects what shipped. Three substantive changes landed during the discussion-and-review cycle that aren't visible in the final spec but are worth documenting for future maintainers:

1. **Clickable filter chips on the dashboard** — the initial dashboard rendered status chips as decoration only. After the first review pass the user pointed out the chips read as buttons; promoted them to actual filter buttons (multi-select toggle, clear-all reset, component sections hide when all their cards are filtered out). The CSS `.summary .stat` rule and the vanilla-JS handler at the bottom of `template.html` ship as a result.

2. **Drift guard's hand-edit detection refined after the idempotent-regen footgun** — initial logic compared the full content sha of the existing output against the freshly-rendered content sha. Because every render stamps a new `generated-at` timestamp, the second regen against unchanged source flagged every file as a suspected hand-edit. Fixed by adding `_stable_content()` which strips volatile fields (`plan-view-generated-at`, `plan-view-git-head`, visible timestamp/git-head footer strings) from both sides before comparison. Idempotent regen is now a no-op; genuine hand-edits still refused.

3. **Edge-pattern regex broadened after low-recall on koda's `**Follows**:` and `tracked in [link](slug.md)` formats** — first version of the catalogue captured 0 `follows` and 1 `tracked-in` edges. Root cause: regex required `[\s\`\[]+` immediately after `**Follows**` (which doesn't match `**Follows**:` — the colon sits outside the bold), and `tracked-in` didn't recognise the markdown-link form. Replaced with a shared `_SLUG_PREFIX = (?:\[[^\]]+\]\(|[`\[(\s])*` that accepts bare tokens, backticks, brackets, parens, OR markdown-link openers. Recall went 0→3 on `follows` and 1→3 on `tracked-in`.

A fourth piece of work was scoped *out* of v1 after surfacing in the same conversation, and is parked under koda-pipecat:

4. **Rich single-document HTML — first parked, then shipped in the same pass.** Two hand-crafted prototypes (`bot-harness-decoupling.html`, `architecture.html`) landed under koda-pipecat's `docs/_rich_views/` to test whether HTML's "express things markdown can't" insight applied to single dense documents. The original parking decision was "wait for 3–4 more rich views before deciding". A follow-up conversation re-opened that decision under a different constraint: if `plan-view` will run across N repos (pipecat, vr000m-website, koda, stt) and dev plans drive the work everywhere, hand-authoring per repo doesn't scale. The right shape: extract a constrained widget toolkit from the two prototypes and add a `--rich` mode that emits a per-plan manifest the agent harness consumes (spawning an LLM subagent per plan with the toolkit as the constraint surface). LLM cost stays proportional to actual plan edits because rich pages cache by source-sha. Shipped in the same PR — see `--rich workflow` in SKILL.md and the new `_widgets/` directory.

## Out of scope / Deferred to v2

Called out explicitly in `SKILL.md` so consumers know:

- **SVG cross-reference graph** — v1 ships typed-edge pills as a `<ul>`. The graph layout is v2 once the typed-edge taxonomy proves itself.
- **Timeline lane widget** — v1 sorts cards by last-touched within each component. Dedicated timeline lane is v2.
- **Tabbed per-plan pages** — v1's deterministic per-plan view uses single-scroll layout with anchored sections. Tabbed layout is shipped in the **rich** per-plan view (`plan-<slug>.rich.html`) via the `_widgets/tabs.html` widget, which uses `<input type="radio">` + `:has()` (not `~`) for visibility because the sibling-selector pattern breaks when radios live inside a `.tab-bar` wrapper.
- ~~**`.plan-view.yml` config for component overrides**~~ — **dropped.** Components are now declared per-plan in a `**Component**` field (see "Component grouping" above), so there is no config file and no slug heuristic. The plan is the source of truth.
- **Review-round inference beyond checkbox counting** — v1 counts `- [x]` / `- [ ]` in `## Progress` and `## Acceptance Criteria` sections. Parsing "review round 3 applied" / "deep-review fixed" deferred.
- **Composition with `playground` skill** — different contract (`playground` = interactive single-file with controls; `plan-view --rich` = constrained widget-toolkit rendering gated on source-sha). `--rich` deliberately does NOT route through `playground` because the contracts conflict: `playground` is exploratory and user-prompted, `--rich` needs reproducible-enough output keyed to source-sha so the drift guard means something.

## Risks & mitigations

| Risk | Mitigation |
|------|-----------|
| README grouping diverges from per-plan `**Status:**` headers (human edits one, forgets the other). | v1 prefers README when present; this is intentional (human is the authority). Future: surface mismatches as a warning chip. |
| A plan omits the `**Component**` field. | Falls into the `(uncategorized)` group rather than being silently mis-bucketed. `dev-plan` emits the field on `create`; `update-docs` warns when a plan lacks it. |
| Output committed accidentally because not gitignored by default. | `--gitignore` flag exists; this plan adds the entry to `.gitignore` for this repo. Per-repo decision otherwise. |
| Generator hangs on a malformed plan. | Pure-regex parser with bounded patterns; no subagent calls; `git log --follow` per file is the only external call and has its own subprocess timeout via shell defaults. |
| Hand-edit detection false-positives on PostToolUse hook reformatting (ruff, prettier). | Output is HTML, not Python — no formatter in the skill's hot path. Verified across multiple regens in CI-like conditions during implementation. |

## Out of scope for this plan

- ~~The Anthropic-blog-inspired *rich single-document* HTML pattern~~ — originally parked; shipped in the same pass as `--rich` + `_widgets/` toolkit (see "Changes from initial design" item 4).
- A `/plan-view` mode that *writes back* to source markdown. The skill is strictly a renderer.
- Cross-repo aggregation (rendering plans from multiple repos into one dashboard). Single-repo scope only.
