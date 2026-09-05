# Parser Reference — `plan-view`

This document is the regex catalogue and status lexicon that `generate.py` uses. Edit here when the dev-plan conventions in a consumer repo evolve.

## Status lexicon

A plan's status string is matched against this ordered lexicon; first match wins. Matching is case-insensitive on the keyword.

| Keyword pattern | Bucket | Chip colour |
|---|---|---|
| `Shipped` | shipped | green |
| `Complete` | shipped | green |
| `Merged` | shipped | green |
| `Phases? \d+(?:[-–]\d+)?\s+(?:shipped|landed|complete)` | shipped (if all phases) / partial (if range) | green / amber |
| `Partially Shipped` | partial | amber |
| `Phase \d+ shipped` | partial | amber |
| `In Progress` | in-progress | amber |
| `In Review` | in-progress | amber |
| `Not Started` | planned | blue |
| `Planned` | planned | blue |
| `Paused` | paused | grey |
| `Abandoned` | paused | grey |
| `Blocked` | blocked | red |
| (no parseable match) | unknown | amber + "?" badge |

**Stranded override.** Any `in-progress` or `partial` plan whose last git-touch is older than `--stale-days` (default 30) gets re-coloured red with a "Stranded" label. This is the drift signal.

## Status header patterns

Three styles observed in the wild (koda-pipecat). The parser tries them in this order; first hit wins.

### Style A — inline bold

```
**Status:** Shipped (PR #89, merging 2026-05-21) — Phases 1–4 implemented...
```

Regex: `^\*\*Status:?\*\*\s*(?P<status>.+?)$` (multiline, MULTILINE flag).

### Style B — multi-line field block

```
**Status**: Shipped — PR #87 merged 2026-05-19
**Assigned to**: Claude
**Priority**: High
**Branch**: `worktree-bugfix-uncategorized-lock`
```

Same regex as Style A — the `:` is optional inside the bold span. Subsequent `**Field**:` lines are picked up by individual field patterns (`**Branch**:`, `**Created**:`, etc.).

### Style C — field table

```markdown
| Field | Value |
|-------|-------|
| **Branch** | `feat/bot-harness-decoupling` |
| **Created** | 2026-05-06 |
| **Priority** | Medium |
| **Objective** | ... |
```

Field-table parsing: split lines on `|`, look for `**Field**` in column 2 and the value in column 3.

### YAML frontmatter (priority over body for `title`, `branch`, `created`, `owner`, `priority`)

```yaml
---
title: Koda Harness — Claude Agent SDK behind Ask + Cmd+K (v2 web surface)
priority: Medium-High
branch: feat/koda-harness
created: 2026-04-29
owner: Varun
---
```

Detected by a leading `^---\n` followed by a closing `\n---\n`, **or** a closing `---` as the final line with no trailing newline (including frontmatter-only files, where the body is then empty). Parsed with a tiny line-by-line `key: value` reader (no PyYAML dependency).

## PR / branch refs

- `PR #(\d+)` — captures all matches in the status header.
- `PRs?\s*#(\d+)(?:[,\s]+#(\d+))*` — handles `PRs #44, #45, #46`.
- `\*\*Branch:?\*\*\s*`?([\w/.-]+)`?` — single-line branch field.

## Cross-references (typed edges)

Four edge types. Patterns are anchored on the source plan's body; the *target* is the referenced plan slug (filename minus `.md`).

| Edge type | Pattern | Example |
|---|---|---|
| `references` | bare `(\d{8}-[\w-]+\.md)` mention (no other typing nearby) | `see 20260407-feature-scheduled-tasks.md` |
| `tracked-in` | `tracked\s+(?:as\|in)\s+[\`\[]?(\d{8}-[\w-]+)` | `tracked in 20260407-feature-scheduled-tasks` |
| `supersedes` | `(superseded\s+by\|replaces\|replaced\s+by)\s+[\`\[]?(\d{8}-[\w-]+)` | `superseded by 20260414-feature-merge-repair-workflow` |
| `structural-fix-of` | `structurally\s+(?:fixed\|addressed)\s+by\s+[\`\[]?(\d{8}-[\w-]+)` | `structurally addressed by 20260506-feature-bot-harness-decoupling` |
| `follows` | `^\*\*Follows:?\*\*\s*[\`\[]?(\d{8}-[\w-]+)` | `**Follows:** 20260422-bug-action-items-category-aware` |

Precedence: if a single mention matches multiple typed patterns, the more specific edge wins (`structural-fix-of` > `supersedes` > `tracked-in` > `follows` > `references`).

## Phase markers

- `^### Phase \d+` headings → count total phases.
- `Phases\s+(\d+)[–\-](\d+)\s+(shipped|complete|landed)` → captures a range that's done; compared against total to set amber-vs-green.
- `Phase \d+ shipped` → set partial.

## Checkbox progress

In `## Progress` and `## Acceptance Criteria` sections, count `- \[[ x]\]` lines:

- `done = count('- [x]')`
- `total = count('- [ ]') + done`

If `total > 0`, surface as a `done/total` chip on the card.

## Component grouping

Read from each plan's `**Component**` bold-field header (parsed by `_find_field_string`, the same helper used for `**Status**` — both the `**Component**: value` inline form and the `| **Component** | value |` field-table row are accepted). The value is case-normalised and whitespace-collapsed (`_normalise_component`); for a comma-separated list the first entry is the primary group (multi-membership deferred). A plan with no `**Component**` field falls into `(uncategorized)`.

There is **no slug heuristic and no config file** — the plan markdown is the source of truth. See `docs/dev_plans/20260521-feature-plan-view-skill.md` "Component grouping" for the per-field ownership model: `dev-plan` emits the field, `update-docs` reconciles it into `dev_plans/README.md`, plan-view renders it.

Group display order is derived from the corpus — plan count descending, alphabetical tiebreak, `(uncategorized)` last. There is no fixed component order.

Plans matching `bug-` or `fix-` carry an additional `bug` tag for the dashboard's red-state logic — they're shown alongside their component group but flagged.

## README reconciliation

If `<plans-dir>/README.md` exists with `##`-level headings matching:

- `In Progress / Partially Shipped` (or `In Progress`)
- `Planned`
- `Shipped`
- `Paused / Abandoned` (or `Paused`)

…then the markdown tables under each are parsed (rows with `| date | [title](slug.md) | status | branch/PR |`) and used as the **authoritative bucket** for every plan listed. Plans not in the README fall back to per-plan parsing. This lets the human maintain the canonical grouping in markdown and the dashboard just renders it.

## Drift guard

For each generated HTML file, the generator embeds:

```html
<meta name="plan-view-source-sha256" content="<render sha>">
<meta name="plan-view-source-path" content="<relative path>">
<meta name="plan-view-git-head" content="<sha at render>">
<meta name="plan-view-generated-at" content="<iso8601 UTC>">
```

The `plan-view-source-sha256` value is a **render sha** (`Plan.compute_render_sha()`), *not* a raw `sha256(markdown)`. It folds the plan's own markdown sha together with everything else that affects its rendered HTML: corpus-derived state (backfilled `edges_in`, `fixed_by`, the possibly-recoloured status bucket) the git-derived fields embedded in the page (commit list sha/date/subject, timeline SVG, `created`, `last_touched`), and the rendered path inputs `source_path`, `plans_dir_short`, and `script_path`. `source_path` and `plans_dir_short` use their home-shortened spellings where applicable. The index page embeds an aggregate (`corpus_sha`) of all per-plan render shas. See SKILL.md's render-sha section for the full composition and rationale.

On regen, for each existing HTML output:
1. Read its embedded `plan-view-source-sha256` (the previous render sha).
2. Recompute the *current* render sha for that plan (markdown + corpus + git fields).
3. If the new render sha differs — meaning the source markdown, a corpus cross-reference, or the git history that feeds the page changed — overwrite freely.
4. If the render sha is unchanged AND the existing HTML file's *content* sha256 differs from what regeneration would produce — someone hand-edited the HTML. Refuse without `--force`; print path and diff hint.

This catches the "I tweaked the HTML directly and now my edit will be wiped" foot-gun without preventing legitimate regeneration after source edits. Folding git fields into the render sha means a rebase/amend that changes a commit subject or date takes the "source changed, overwrite freely" path (step 3) rather than a spurious hand-edit refusal.

## Section splitting (`--rich` mode)

Large plans (`> 25,000` chars or `> 10` H2s) are diced into sections for parallel LLM fanout. `split_into_sections(plan)` returns an ordered list of `Section` dataclass instances:

| Field | Meaning |
|-------|---------|
| `section_id` | Stable, unique slug from the H2 title; duplicate titles get `-2`, `-3` suffixes. Content before the first H2 is `preamble`; a plan with no H2 yields a single `body` section. |
| `title` | The H2 heading text (`(preamble)` / `Body` for the synthetic sections). |
| `markdown` | The raw slice of the plan for that section. |
| `section_sha` | `sha256(markdown)` — gates per-section rich re-render so editing one section only re-renders that section. |

`Section` is **frozen** (immutable); splits are memoised in a module-level cache keyed by `(slug, sha256)`, and `split_into_sections` hands back a fresh list copy so callers can't corrupt the cached entry.

H2 boundaries are found by `_h2_spans()`, which is **fence-aware**: a `## ` line inside a fenced code block (` ``` ` or `~~~`) is not a section boundary. Fence state toggles on the fence character (a `~~~` line doesn't close a ` ``` ` block) and respects fence length (a ` ``` ` line does not close a ` ```` ` block — CommonMark). Note this scanner (`_SECTION_FENCE_RE`) is intentionally broader than the markdown renderer's own `_FENCE_RE` (which captures only a non-indented exactly-three-backtick fence's language): the splitter recognises indented and `~~~` fences too. The divergence is benign — it only shifts where a section boundary lands, never the deterministic per-plan HTML rendering.
