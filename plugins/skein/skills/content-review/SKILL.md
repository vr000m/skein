---
name: content-review
description: Reviews written markdown content (blog posts, TILs, technical docs, Notion docs) against style guidelines and returns a structured report with Critical / Important / Suggestion findings plus inline diff-style fixes. Use when the user says "/content-review" or asks to "review a blog post", "proofread my content", "check my TIL", "edit this doc", "review content", or "check this draft".
argument-hint: [file-path] [--type blog|til|technical-doc|notion|general]
---

# Content Review Skill

Review written content against style guidelines and produce a structured report with inline fix suggestions.

## Usage

- `/content-review path/to/post.md` — Review a file (auto-detects content type)
- `/content-review path/to/post.md --type blog` — Review with explicit content type
- `/content-review` — Review content pasted into the conversation

## Phase 1: Detect Content Type

Determine the content type using these signals, in priority order:

1. **Explicit `--type` flag** overrides all detection.
2. **YAML frontmatter fields — blog only**:
   - Has `slug`, `excerpt`, `category`, `authors` fields -> `blog`
   - Other frontmatter combinations -> continue to step 3 (do NOT classify as TIL here — frontmatter with `title` + `published_date` is common in docs too)
3. **File path heuristics** (run before TIL inference to avoid misclassifying docs):
   - Path contains `/docs/` or `/documentation/` or `/guides/` -> `technical-doc`
   - Path contains `/til/` or `/tils/` -> `til`
   - Path contains `/blog/` or `/posts/` -> `blog`
4. **Frontmatter — TIL inference** (only if path didn't match):
   - Has `title` and `published_date` but lacks `slug`/`excerpt`/`category` -> `til`
5. **Content heuristics**:
   - Under 500 words, single focused topic, learning-oriented -> `til`
   - Multiple code blocks, API references, architecture content -> `technical-doc`
   - Notion-specific artefacts (toggle syntax, database mentions, callout blocks) -> `notion`
6. **Fallback**: `general`

Print the detected type and ask for confirmation before proceeding:
```
Detected content type: blog post
Applying full blog guidelines (style + structure + SEO/meta).
Proceed? (y/n/change type)
```

## Phases 2–4: Load Rules, Perform Review, Output Report (Subagent)

These phases involve reading reference files, applying dozens of rules against the content, and producing a structured report — delegate them to a subagent to keep the main context lean.

### Pre-flight (main context)

Before spawning the subagent, read the content to review (from file or conversation) and capture it along with the detected content type from Phase 1.

### Subagent delegation

**Use the Agent tool** with `subagent_type: "general-purpose"` and `model: "sonnet"` to spawn a single subagent. Pass it the following self-contained prompt (fill in `{{PLACEHOLDERS}}`):

````
You are reviewing written content against style guidelines and producing a structured report.

## Inputs

- **Content type**: {{CONTENT_TYPE}} (one of: blog, til, technical-doc, notion, general)
- **Content to review**:
```
{{CONTENT}}
```
- **File path** (if any): {{FILE_PATH}}

## Phase 2: Load Applicable Rules

Read the appropriate reference files based on content type:

| Content Type    | Style Rules | Structure Rules | SEO/Meta Rules | Checklist |
|----------------|-------------|-----------------|----------------|-----------|
| `blog`         | Full        | Full            | Full           | Full blog checklist |
| `til`          | Full        | TIL-specific    | Frontmatter only | TIL checklist |
| `technical-doc`| Style only  | Headings + code | Skip           | Style subset |
| `notion`       | Style only  | Skip            | Skip           | Style subset |
| `general`      | Style only  | Skip            | Skip           | Style subset |

For `blog` and `til`: read `references/content-guidelines.md` (relative to this skill's directory) for the full rule set.
For `technical-doc`, `notion`, and `general`: read `references/writing-style-rules.md` (relative to this skill's directory) for the universal style subset.

## Phase 3: Perform Review

Evaluate the content against each applicable rule category. Collect findings with severity levels.

### Review Categories

**Style** (all content types):
- British English spellings in body text (flag American spellings: optimize, realize, behavior, color, etc.). **Exception**: Do not flag American spellings in frontmatter `slug` or `filename` fields — these intentionally use American English for SEO.
- Oxford comma usage in lists
- Active voice (flag passive constructions)
- Conciseness (flag filler phrases, unnecessary adverbs, superlatives)
- Comma splices (two independent clauses joined by just a comma)
- Repetition (same information presented twice in different forms)
- Missing words (dropped articles, missing subjects, missing relative pronouns)
- Incorrect verb forms after auxiliaries
- Typos and misspellings (transposed letters, dropped characters, stray spaces)
- Technical terms not in backticks (filenames, functions, CLI commands, env vars, HTML elements)
- AI-signalling template phrases and assistant-meta residue (`in this post`, `delve`, `it is worth noting`, `I hope this helps`, placeholder scaffolding)
- Hedge-heavy or abstraction-only prose (paragraphs that lack evidence, decision, or outcome)
- Overused formatting tics (excessive em dashes, boldface, repeated "rule of three" cadence)

**Structure** (blog, TIL, and technical-doc — adapted by type):
- TL;DR present and bolded (blog only)
- Hero image referenced (blog only)
- Hook/opening paragraph quality — not overloaded with links and details
- Heading hierarchy (H2 for sections, H3 for subsections)
- Code blocks have language identifiers
- Code-prose consistency (variable names in code match references in text)
- Cross-block identifier consistency (shared labels/filenames/paths match across code blocks)
- Code example completeness (self-contained or omissions marked)
- Code comments accurate (no stale comments from prior refactors)
- Consistent command syntax throughout (don't mix invocation forms)
- Word count vs. content-type target range
- Bullet list rules (no lists in body except intro, summary, tutorials, TIL collections)
- Forward-looking close (blog and TIL — TILs must not end on bare code block, bullet list, or link)
- Post-publication update format if applicable (`**Updated (YYYY-MM)**:`)

**Content Quality** (blog and TIL):
- Title-body alignment — body fulfils the promise the title makes
- Result/outcome shown, not just process described
- Rough edges or limitations acknowledged (not all-positive)
- Source attribution — quotes and references linked
- Best lines given room to breathe (not buried mid-paragraph)
- Concrete anchors included in each major section (command/path/metric/error/decision)
- At least one explicit trade-off (`chose X instead of Y`, including downside)
- At least one failed attempt or rough-edge adjustment described
- Avoidance of formulaic contrast patterns (`not just X, but Y`; `not only X, but Y`)
- Includes one non-obvious, evidence-backed judgement (not just neutral recap)

**SEO/Meta** (blog only, frontmatter check for TIL):
- Blog frontmatter completeness: title, slug, excerpt, published_date, status, category, tags, authors
- TIL frontmatter completeness: title, published_date, status (optional: audio_url)
- Excerpt length: 150-160 characters
- Slug uses American English (not British)
- Tags: 3-5 present
- Category is valid (`Industry` or `Engineering`)
- Image alt text is descriptive

### Severity Levels

- **Critical**: Violates a hard rule. Must fix before publishing. Examples: missing TL;DR on blog post, comma splices, American spellings in body text, missing required frontmatter fields, code-prose identifier mismatch, templated AI-signalling phrasing, missing concrete anchors/trade-offs/failure notes.
- **Important**: Weakens quality. Should fix. Examples: passive voice in key sections, missing code language identifiers, no forward-looking close, bullet lists in body, stale code comments, inconsistent command syntax, excessive hedge-heavy filler.
- **Suggestion**: Polish items. Nice to have. Examples: could be more concise, alternative word choice, structural reordering, line that deserves its own paragraph.

## Phase 4: Return Structured Report

Return your findings in exactly this format (no other output):

```
## Content Review Report

**Content type**: [detected type]
**Word count**: [N] words ([within range / X words under minimum / X words over maximum])
**Overall**: [N] Critical, [N] Important, [N] Suggestion

### Critical Issues
1. **[Category]**: [Description]
   - Line/section: [location reference]
   - Rule: [brief rule citation]
   - Fix: [specific suggested fix]

### Important Issues
1. **[Category]**: [Description]
   - Line/section: [location reference]
   - Fix: [specific suggested fix]

### Suggestions
1. **[Category]**: [Brief recommendation]

### Checklist Status
[Render the applicable checklist (blog or TIL) with pass/fail marks]
```

For `technical-doc`: report Style findings plus the Structure subset (heading hierarchy, code block language identifiers, code-prose consistency, code example completeness). Skip Content Quality and SEO/Meta.

For `notion` and `general`: report Style findings only. Skip Structure, Content Quality, and SEO/Meta.
````

### After the subagent returns

Present the structured report to the user, then continue with Phase 5 (inline fixes) and Phase 6 (next steps) in the main context.

## Phase 5: Inline Suggestions

After the report, provide diff-style inline fix suggestions for all Critical and Important items:

```
### Inline Fixes

**Fix 1** (Critical — Style): American spelling on line 12
> Original: "...to optimize the pipeline..."
> Fixed:    "...to optimise the pipeline..."

**Fix 2** (Important — Structure): Missing code language identifier
> Original: ```\n  const x = 1\n  ```
> Fixed:    ```javascript\n  const x = 1\n  ```
```

For Suggestions, do not produce inline fixes unless the user requests them.

## Phase 6: Offer Next Steps

After the report, offer these options:
1. "Apply all Critical fixes" (only if reviewing a file, not pasted content)
2. "Apply all Critical + Important fixes"
3. "Review another file"
4. "Explain a specific finding in more detail"

Only apply changes if the user explicitly asks. Never auto-edit.

## Edge Cases

- **Multiple files**: If given a directory or glob, review each file separately with its own report.
- **Non-Markdown content**: For plain text or Notion exports, skip frontmatter and code-block checks.
- **Very short content** (under 100 words): Flag as potentially incomplete but still review applicable rules.
- **Content with no detectable type**: Default to `general` and apply style rules only.

## Additional Resources

### Reference Files

- **`references/content-guidelines.md`** — Full blog and TIL guidelines including quality checklists, structure requirements, content approach, SEO rules, and voice/tone guidelines. Load for `blog` and `til` content types.
- **`references/writing-style-rules.md`** — Universal writing style rules (British English, Oxford comma, active voice, conciseness, proofreading, code formatting). Load for `technical-doc`, `notion`, and `general` content types.
