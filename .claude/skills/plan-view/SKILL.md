---
name: plan-view
description: Generates a self-contained HTML dashboard and per-plan drill-down pages from a directory of markdown dev plans. Surfaces status, cross-references, and git-derived timeline so corpus-level drift is visible. Use when the user says "plan view", "render dev plans", "render plan dashboard", "/plan-view", or asks for a visual index of dev_plans/.
argument-hint: <plans-dir> [--out <dir>] [--force] [--stale-days N] [--gitignore]
---

# Plan View — HTML Dashboard for Dev-Plan Corpora

Distills a directory of markdown dev plans into a navigable HTML dashboard plus one drill-down page per plan. The artefact is a derived view: the markdown remains the source of truth. Inspired by the Anthropic blog post on the [unreasonable effectiveness of HTML in Claude Code](https://claude.com/blog/using-claude-code-the-unreasonable-effectiveness-of-html) — markdown can't render colour-coded status chips, typed cross-reference pills, or commit-history strips that make corpus-level drift visible at a glance.

## When to use

- The user has a `docs/dev_plans/` (or equivalent) directory with 10+ plans and wants a visual overview.
- Drift is suspected — plans referencing each other, some shipped, some stranded, some superseded.
- After a `/dev-plan` or `/review-plan` cycle, to see how the new plan fits into the existing corpus.

## Invocation

```bash
python3 .claude/skills/plan-view/generate.py <plans-dir> [options]
```

Options:

| Flag | Default | Meaning |
|------|---------|---------|
| `--out <dir>` | `<plans-dir>/../_plan_view/` | Output directory. Sibling of plans dir by default. |
| `--force` | off | Overwrite outputs even if the drift guard detects a hand-edit. |
| `--stale-days N` | `30` | An `In Progress` plan whose last git-touch is > N days becomes a red **Stranded** chip. |
| `--gitignore` | off | Write a `.gitignore` containing `*` in the output dir (opt-in). |

The skill expects:
- A directory of `.md` files (one per plan).
- The directory is inside a git repository (`git log --follow` is used to build the commit-history strip).
- Plans roughly follow the convention `yyyymmdd-type-name.md` — the date prefix and `type` slug (`feature`, `bug`, `fix`, `design`, `chore`, `refactor`) drive component grouping.

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

On regeneration, if a generated file's embedded sha256 doesn't match what the generator would produce now AND the source markdown's sha hasn't changed since the last run, the skill refuses to overwrite — that's evidence someone hand-edited the HTML. Pass `--force` to overwrite anyway.

## Reading order for maintainers

- `parser.md` — regex catalogue and status lexicon. Edit when plan conventions evolve.
- `generate.py` — single-file generator. Functions are ordered: arg parsing → plan parsing → git collection → drift guard → HTML rendering → main.
- `template.html` / `plan-template.html` — HTML scaffolds with `{{PLACEHOLDER}}` substitution points. CSS is inline (single-file constraint).

## Design notes

- **Renderer, not planner.** This skill does not modify markdown. To edit a plan, edit the `.md` and rerun.
- **No subagent calls.** Pure regex + git CLI + string templating. ~51 plans render in well under a second.
- **Stdlib only.** No `jinja2`, no `markdown` lib. `markdown` → HTML conversion is minimal (headings, lists, code blocks, links) and lives in `generate.py::render_markdown`. If a plan uses exotic markdown, the rendered output falls back to a `<pre>` block.
- **README grouping wins.** When the plans dir has a README with the koda-style status tables, those are authoritative — per-plan status parsing fills in only what the README omits.

## What's deferred to v2

- SVG cross-reference graph (v1 uses typed-edge pills).
- Timeline lane widget (v1 sorts cards by last-touched within component).
- Tabbed per-plan pages (v1 uses single scroll with sticky nav).
- `.plan-view.yml` config for component overrides (v1 is heuristic-only; config file is read silently if present, undocumented).
- Review-round inference beyond checkbox counting.

## Composing with other skills

- **`/dev-plan`** — creates plans. `/plan-view` consumes them.
- **`/review-plan`** — audits a single plan. `/plan-view` shows where that plan sits in the corpus.
- **`/update-docs`** — keeps READMEs/CHANGELOGs in sync with code. Future versions could read `plan-view-source-sha256` meta tags to flag stale views.
- **`/playground`** — different contract (interactive single-file with controls). Do not compose.
