---
name: plan-view
description: Generates a self-contained HTML dashboard and per-plan drill-down pages from a directory of markdown dev plans. Surfaces status, cross-references, and git-derived timeline so corpus-level drift is visible. Also produces opinionated LLM-rendered "rich" single-plan views via `--rich` (with parallel section-fanout for large plans). Use when the user says "plan view", "render dev plans", "render plan dashboard", "render rich plan view", "/plan-view", or asks for a visual index of dev_plans/.
argument-hint: <plans-dir> [--out <dir>] [--force] [--stale-days N] [--gitignore] [--rich] [--rich-assemble]
---

# Plan View — HTML Dashboard for Dev-Plan Corpora

Distills a directory of markdown dev plans into a navigable HTML dashboard plus one drill-down page per plan. The artefact is a derived view: the markdown remains the source of truth. Inspired by HTML-first agent workflows — markdown can't render colour-coded status chips, typed cross-reference pills, or commit-history strips that make corpus-level drift visible at a glance.

## When to use

- The user has a `docs/dev_plans/` (or equivalent) directory with 10+ plans and wants a visual overview.
- Drift is suspected — plans referencing each other, some shipped, some stranded, some superseded.
- After a `/dev-plan` or `/review-plan` cycle, to see how the new plan fits into the existing corpus.

## Invocation

```bash
python3 .codex/skills/plan-view/generate.py <plans-dir> [options]
```

Options:

| Flag | Default | Meaning |
|------|---------|---------|
| `--out <dir>` | `<plans-dir>/../_plan_view/` | Output directory. Sibling of plans dir by default. |
| `--force` | off | Overwrite outputs even if the drift guard detects a hand-edit. |
| `--stale-days N` | `30` | An `In Progress` plan whose last git-touch is > N days becomes a red **Stranded** chip. |
| `--gitignore` | off | Write a `.gitignore` containing `*` in the output dir (opt-in). |
| `--rich` | off | Emit `_rich_manifest.json` listing plans whose LLM-rendered rich view needs regeneration. Large plans get `strategy: "sections"` with one entry per H2 — Codex spawns N subagents in parallel. See `--rich workflow` below. |
| `--rich-assemble` | off | After fragments exist, stitch them into final `plan-<slug>.rich.html` for `strategy: "sections"` plans using `tabs.html`. |

The skill expects:
- A directory of `.md` files (one per plan).
- The directory is inside a git repository (`git log --follow` is used to build the commit-history strip).
- Plans roughly follow the convention `yyyymmdd-type-name.md` — the `type` slug (`feature`, `bug`, `fix`, `design`, `chore`, `refactor`) drives the `bug` tag for red-state logic. Component grouping comes from each plan's `**Component**` field, not the slug.

A `<plans-dir>/README.md` is treated as **authoritative** for status grouping if it contains tables under headings `In Progress / Partially Shipped`, `Planned`, `Shipped`, `Paused / Abandoned`. Per-plan `**Status:**` parsing is the fallback.

## Output

```
<out>/
├── index.html                  # dashboard
├── plan-<slug>.html            # one per plan
└── _assets/                    # inline-only; this dir is empty in v1
```

Each generated HTML file embeds drift-guard meta tags:

```html
<meta name="plan-view-source-sha256" content="...">
<meta name="plan-view-git-head" content="...">
<meta name="plan-view-generated-at" content="...">
```

The `plan-view-source-sha256` value is a **render sha**, not just `sha256(markdown)`. It composes the plan's own markdown sha with corpus-derived state that affects its rendered HTML: backfilled `edges_in` (other plans referencing it), `fixed_by` pointer, and the (possibly stranded-recoloured) status bucket. The index page stores an aggregate of all per-plan render shas. This means a change to plan B that affects plan A's render (e.g. B starts referencing A, or B ships as a `structural-fix-of` A) invalidates A's stored sha, and A regenerates without a spurious "hand-edit suspected" refusal.

On regeneration, if a generated file's embedded sha doesn't match the new render sha → overwrite freely (something that affects this plan's render changed). If the embedded sha matches but the rendered stable content differs → hand-edit suspected; refuse unless `--force`.

## `--rich` workflow

The deterministic dashboard and per-plan pages cover corpus-level questions ("what's shipped, what's stranded, who references whom"). `--rich` adds an opinionated single-plan view for each plan that distils its content into tabs, SVG diagrams (state machines, today-vs-proposed comparisons), searchable tables, and findings timelines — the things markdown can't render. This applies the same HTML-first workflow to a single dense document.

Rich rendering is **not** done by `generate.py`. The Python generator is deterministic; rich rendering is interpretive and uses an LLM. There are two strategies per plan, chosen at manifest emit time based on plan size:

- **`strategy: "single"`** — small plans (< 25 KB markdown AND ≤ 10 H2s). One subagent renders the whole plan to `plan-<slug>.rich.html`.
- **`strategy: "sections"`** — larger plans (> 25 KB OR > 10 H2s). The generator splits the markdown on `## H2` boundaries; one subagent renders each section in parallel to a fragment file under `_fragments/`; Codex then runs `--rich-assemble` to stitch fragments into final HTML.

**There is no cap on how many subagents render a plan.** For a 100 KB plan with 12 H2s, Codex dispatches 12 `spawn_agent` workers in parallel, each operating in its own context window.

### Flow

1. **Generator emits a manifest** (`python3 .codex/skills/plan-view/generate.py <plans-dir> --rich`).
   `_rich_manifest.json` schema:
   ```jsonc
   {
     "schema_version": 2,
     "generated_at": "...",
     "git_head": "...",
     "widget_catalogue": "<skill_dir>/_widgets",
     "fragments_dir": "<out>/_fragments",
     "entries": [
       {
         "slug": "...",
         "strategy": "single",
         "title": "...",
         "status": "pending|cached",
         "source_path": "...",
         "source_md_sha": "...",
         "output_path": "<out>/plan-<slug>.rich.html",
         "widget_catalogue": "<skill_dir>/_widgets/README.md",
         "bucket": "...",
         "existing_rich_sha": null
       },
       {
         "slug": "...",
         "strategy": "sections",
         "title": "...",
         "aggregate_status": "cached|partial|pending",
         // cached  — all fragments fresh AND assembled .rich.html embeds matching sha
         // partial — some fragments still pending; Codex renders them, then runs --rich-assemble
         // pending — all fragments fresh, but assembled .rich.html missing/stale; Codex runs --rich-assemble only
         "source_path": "...",
         "source_md_sha": "...",
         "output_path": "<out>/plan-<slug>.rich.html",
         "fragments_dir": "<out>/_fragments",
         "widget_catalogue": "<skill_dir>/_widgets/README.md",
         "bucket": "...",
         "existing_rich_sha": null,
         "sections": [
           {
             "section_id": "context",
             "title": "Context",
             "section_md_sha": "...",
             "markdown_excerpt": "first 200 chars...",
             "fragment_path": "<out>/_fragments/<slug>__context.html",
             "status": "pending|cached",
             "existing_section_sha": null
           }
         ]
       }
     ]
   }
   ```

2. **Codex consumes the manifest.**
   - For each `strategy: "single"` pending entry: dispatch one Codex `spawn_agent` worker with the plan markdown + widget catalogue + output contract. The worker writes a full HTML page to `output_path`, embedding `<meta name="plan-view-rich-source-sha256" content="<source_md_sha>">`.
   - For each `strategy: "sections"` entry: if `aggregate_status == "partial"`, dispatch one Codex `spawn_agent` worker per `pending` section **in parallel** (no cap) with `fork_context=false` — each writes an HTML **fragment** (not a full page) to `section.fragment_path`, prefixed with `<!-- plan-view-rich-section-sha256: <section_md_sha> -->`. If `aggregate_status == "pending"`, all fragments are already fresh — skip directly to step 3.

3. **Run `--rich-assemble`** (`python3 .codex/skills/plan-view/generate.py <plans-dir> --rich-assemble`). The generator reads each `strategy: "sections"` plan, verifies all fragments exist with current per-section shas, and stitches them into the final `plan-<slug>.rich.html` using the `tabs.html` scaffold (one tab per section, page chrome + base CSS inlined). Plans missing fragments are skipped with a "have/need" diff in the output.

4. **Caching.**
   - Single-strategy pages regenerate only when the plan's own markdown sha changes.
   - Sections-strategy fragments regenerate only when **their own section's** sha changes. Editing one phase of a 100 KB plan = one fragment re-render, not 12.
   - Neither depends on corpus state (`edges_in` / `fixed_by`) — those affect the deterministic per-plan page, not the rich view.

The widget toolkit in `_widgets/` is the constraint surface. Widgets:
- `base.css` — shared variables, chip/card/section primitives, tab scaffold.
- `tabs.html` — CSS-only tab container (radio + `:checked` + `~`).
- `state-machine.svg.html` — finite-state machine with kind-coloured states and curved transitions.
- `compare.svg.html` — today-vs-proposed side-by-side comparison.
- `timeline.html` — unified history / findings timeline.
- `table.html` — searchable + chip-filterable table.

Subagents pick widgets when the source has matching content (an ASCII state machine → `state-machine.svg.html`; a "Today vs Proposed" section → `compare.svg.html`) and fall back to rendered markdown for sections that don't map. Two runs against the same source produce visually-similar output, not byte-identical — drift guard accepts this and gates on source-sha only.

### Codex delegation pattern

For the `--rich` workflow, Main Codex is the orchestrator. It reads `_rich_manifest.json`, dispatches the required rich-rendering workers via `spawn_agent` with `fork_context=false`, waits with `wait_agent`, then closes completed workers with `close_agent`. This is the same clean-context parallel-dispatch primitive used by Codex `/deep-review` and `/conduct`: the subagent prompt is self-contained, parent conversation history is not shared, and workers must not spawn further subagents.

The deterministic generator itself never calls `spawn_agent`. It is pure stdlib Python plus git CLI, and the manifest is the cross-runtime contract between the deterministic pass and the Codex rich-rendering orchestration.

### Suggested subagent prompt shapes

**Single-strategy (whole plan):**
```
Source: {plan markdown at source_path}
Widget catalogue: {_widgets/README.md plus each widget file}
Output: single self-contained HTML at {output_path}.
Constraints:
  - Use widgets where source has matching content; render markdown for the rest.
  - Embed <meta name="plan-view-rich-source-sha256" content="{source_md_sha}">.
  - Inline all CSS (Inter font CDN link is fine).
  - One tab per H2 in source, plus a final "Source" tab with rendered markdown.
  - tabs.html uses :has() selectors — emit the rules exactly as documented.
Return: {"output_path": "...", "widgets_used": [...], "fallback_sections": [...]}.
```

**Sections-strategy (one subagent per section, spawned in parallel):**
```
Section: {section_title} (id: {section_id})
Source: {plan markdown at source_path, sliced to this H2's body}
Widget catalogue: {_widgets/README.md plus each widget file}
Output: HTML FRAGMENT (not a full page — no <html>/<head>/<body>) at {fragment_path}.
Constraints:
  - Start the fragment with: <!-- plan-view-rich-section-sha256: {section_md_sha} -->
  - Use widgets if this section's content matches one (ASCII state machine →
    state-machine.svg.html; today-vs-proposed → compare.svg.html; tabular content →
    table.html; commit/finding timeline → timeline.html). Otherwise render markdown.
  - No <style> blocks — the assembler inlines base.css globally.
  - Self-contained: don't reference other sections; don't include the page header/footer.
Return: {"fragment_path": "...", "widgets_used": [...]}.
```

Cost note: rich rendering costs one LLM call per plan (single) or per section (sections) that changed. If the dev-plan corpus is kept in sync with the work, this is roughly "one call per shipped plan or edited section", amortised across long stretches of cached regens.

## Reading order for maintainers

- `parser.md` — regex catalogue and status lexicon. Edit when plan conventions evolve.
- `generate.py` — single-file generator. Functions are ordered: arg parsing → plan parsing → git collection → drift guard → HTML rendering → main.
- `template.html` / `plan-template.html` — HTML scaffolds for deterministic dashboard + per-plan pages. CSS is inline (single-file constraint).
- `_widgets/` — widget toolkit consumed by the `--rich` workflow. Each file has an HTML comment at the top documenting its input shape; `_widgets/README.md` is the catalogue.

## Design notes

- **Renderer, not planner.** This skill does not modify markdown. To edit a plan, edit the `.md` and rerun.
- **No subagent calls inside the generator.** Pure regex + git CLI + string templating. ~51 plans render in well under a second.
- **Stdlib only.** No `jinja2`, no `markdown` lib. `markdown` → HTML conversion is minimal (headings, lists, code blocks, links) and lives in `generate.py::render_markdown`. If a plan uses exotic markdown, the rendered output falls back to a `<pre>` block.
- **README grouping wins.** When the plans dir has a README with the koda-style status tables, those are authoritative — per-plan status parsing fills in only what the README omits.
- **Deterministic output is escaped; `--rich` output is not.** The dashboard and per-plan pages route all plan-derived content through `html.escape`. The `--rich` path is different: section fragments are LLM subagent output and are inlined verbatim by `--rich-assemble` (they intentionally carry SVG and inline `<script>`). Untrusted plan markdown could steer a rendering subagent into emitting active content, so open `*.rich.html` only for plan corpora you trust.

## What's deferred to v2

- SVG cross-reference graph (v1 uses typed-edge pills).
- Timeline lane widget (v1 sorts cards by last-touched within component).
- Tabbed per-plan pages (v1 uses single scroll with sticky nav).
- ~~`.plan-view.yml` config for component overrides~~ — dropped. Components are declared per-plan in a `**Component**` field (read by the parser, grouped by exact string); there is no slug heuristic and no config file. The plan is the source of truth.
- Review-round inference beyond checkbox counting.

## Composing with other skills

- **`/dev-plan`** — creates plans. `/plan-view` consumes them.
- **`/review-plan`** — audits a single plan. `/plan-view` shows where that plan sits in the corpus.
- **`/update-docs`** — keeps READMEs/CHANGELOGs in sync with code. Future versions could read `plan-view-source-sha256` meta tags to flag stale views.
- **`/playground`** — different contract (interactive single-file with controls). Do not compose: `--rich` deliberately uses its own constrained widget toolkit rather than routing through `playground`, because `--rich` needs deterministic-up-to-LLM-variance output gated on source-sha, while `playground` is exploratory and user-prompted.
