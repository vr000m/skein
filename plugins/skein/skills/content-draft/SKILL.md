---
name: content-draft
description: Drafts TILs or blog posts from the current Claude session context, enforcing British English and anti-LLM style rules (concrete-first opener, evidence density, decision + trade-off, failure + adjustment). Use when the user says "/content-draft" or asks to "draft a TIL from this session", "write up what we just did", "turn this into a blog post", "summarise this session as a TIL", or "create a TIL from this work".
argument-hint: [--type til|blog] [--title "optional title"]
---

# Content Draft Skill

Draft a TIL or blog post from the current Claude Code session context.

## Usage

- `/content-draft` — Draft a TIL (default) from the current session
- `/content-draft --type blog` — Draft a full blog post from the current session
- `/content-draft --type til --title "Building content skills for Claude Code"` — Draft with a specific title

## Phase 1: Determine Content Type

Default to `til` unless the user specifies `--type blog` or the session clearly covered enough ground for a full blog post (multiple phases, architectural decisions, significant implementation). Print the chosen type and ask to confirm:

```
Drafting as: TIL (Today I Learned)
Title suggestion: "Creating custom Claude Code skills for content review"
Proceed? (y/n/change to blog)
```

## Phase 2 (main context): Gather Session Context and Confirm

Summarise what was accomplished in the current session. Extract:

- **Problem/goal**: What was the user trying to achieve?
- **Tools and technologies**: What was used (languages, frameworks, tools, services)?
- **Approach and key decisions**: What choices were made and why?
- **Outcome**: What was the result? Did it work? What does it look like?
- **Rough edges**: Any surprises, gotchas, limitations, or things that didn't work?
- **Learnings**: What was non-obvious or worth sharing?

Present this summary and ask the user to confirm or adjust before drafting. **This step stays in the main context** because it requires user interaction.

## Phases 3–4: Draft Content and De-LLM Pass (Subagent)

The actual drafting and authenticity pass involve reading reference files and iterative writing — delegate them to a subagent to keep the main context lean.

### Subagent delegation

**Use the Agent tool** with `subagent_type: "general-purpose"` and `model: "sonnet"` to spawn a single subagent. Pass it the following self-contained prompt (fill in `{{PLACEHOLDERS}}`):

````
You are drafting written content (a TIL or blog post) from a session summary provided below.

## Inputs

- **Content type**: {{CONTENT_TYPE}} (til or blog)
- **Title**: {{TITLE}}
- **Today's date**: {{TODAYS_DATE}}
- **Session summary** (confirmed by the user):
{{SESSION_SUMMARY}}

## Phase 3: Draft Content

Generate a draft following these rules:

### For TILs

- **Frontmatter**:
  ```yaml
  ---
  title: 'Descriptive TIL title'
  published_date: '{{TODAYS_DATE}}'
  status: 'draft'
  ---
  ```
- **Body**: Concise, focused on the learning. Use flowing prose (not bullet lists, unless it's a collection of distinct unrelated ideas).
- **Code examples**: Include relevant code snippets with language identifiers. Ensure code-prose consistency and cross-block identifier consistency.
- **Close**: End with a forward-looking sentence (not a bare code block, bullet list, or link).
- **Length**: Keep it short — TILs are quick reads.

### For Blog Posts

- **Frontmatter**:
  ```yaml
  ---
  title: 'Blog Post Title'
  slug: 'url-slug-here'
  excerpt: '150-160 character description for SEO and social sharing'
  published_date: '{{TODAYS_DATE}}'
  status: 'draft'
  category: 'Engineering'
  tags: ['tag1', 'tag2', 'tag3']
  authors: ['Varun Singh']
  ---
  ```
- **TL;DR**: Bolded, 1-2 sentences summarising the key message.
- **Hook**: Opening paragraph that sets context or presents a problem. Keep it focused — don't cram multiple links and technical details into the opener.
- **Structure**: H2 for main sections, H3 for subsections. Follow the content-type structure:
  - Technical Deep Dive: Problem -> Analysis -> Solution -> Implementation -> Results
  - Tutorial: Prerequisites -> Step-by-step -> Troubleshooting -> Next Steps
  - Industry Analysis: Context -> Trend Analysis -> Implications -> Predictions
  - Opinion: Thesis -> Supporting Evidence -> Counter-arguments -> Conclusion
- **Close**: Synthesis and forward-looking statement.
- **Length**: 800-1,500 words (or content-type-specific range).

### Style Rules (Both Types)

- **British English** for all content (optimise, realise, behaviour)
- **American English** for slugs and filenames (for SEO)
- **Oxford comma** in all lists
- **Active voice** preferred
- **No comma splices**
- **No bullet lists in body** (except intro outlines, summaries, and tutorial steps)
- **Show the result** — don't just describe process, tell the reader what happened
- **Deliver on the title** — body must fulfil the promise the title makes
- **Include rough edges** — mention limitations and caveats for credibility
- **Attribute references** — link to external sources
- **Technical terms in backticks** — filenames, functions, CLI commands, env vars

### Anti-LLM Authenticity Constraints (Hard Rules)

- **Concrete-first opener**: Start with a specific event, result, or problem from the work. Avoid framing like "In this post, I'll cover...".
- **Evidence density**: Every major section must include at least one concrete anchor (command, file path, metric, error string, timestamp, named system, or explicit decision).
- **Decision + trade-off**: When presenting a choice, include what was rejected and one downside of the chosen path.
- **Failure + adjustment**: Include at least one rough edge or failed attempt and the change that resolved (or mitigated) it.
- **No abstraction-only paragraphs**: Each paragraph should contain evidence, a decision, or an outcome.
- **Template phrase ban**: Avoid stock AI-signalling phrasing unless truly necessary (examples: "delve", "ever-evolving", "it is worth noting", "seamless", "leverage", "in conclusion", "this underscores", "this highlights", "this landscape").
- **Avoid formulaic cadence**: Do not overuse repetitive structures like "not just X, but Y", "not only X, but Y", or repeated rule-of-three rhythms.
- **No assistant residue**: Remove assistant-style meta language ("I hope this helps", "would you like me to...", "as of my last update") and placeholder text (`[X]`, `{placeholder}`, `Subject:` scaffolding).

## Phase 4: De-LLM Authenticity Pass

Before returning the draft, run a targeted rewrite pass:

1. Replace generic transitions with concrete statements.
2. Remove hedge-heavy filler unless uncertainty is material.
3. Ensure section openers are not repetitive in structure.
4. Verify the draft includes at least one trade-off and one failure/rough-edge moment.
5. Remove any banned template phrases and assistant-meta residue.

## Output

Return the complete draft as a markdown document (no other output). Include the frontmatter and full body.
````

### After the subagent returns

The main context receives the finished draft and continues to Phase 5 (present to user) and Phase 6 (offer next steps).

## Phase 5: Present Draft

Show the complete draft in the conversation as a markdown code block. Do NOT write to a file unless the user explicitly asks.

## Phase 6: Offer Next Steps

After presenting the draft, offer:

1. **Save to file** — Suggest the appropriate path:
   - TIL: `content/til/{tag}/{slug}.md` (ask which tag directory)
   - Blog: `content/blog/YYYY/{slug}.md`
2. **Run /content-review** — Chain with the review skill to check the draft against the full checklist
3. **Revise** — Adjust tone, length, focus, or structure based on feedback
4. **Change type** — Convert between TIL and blog post

## Key Principles

- The draft skill generates content; the review skill checks it. They chain naturally.
- Present the session summary for user confirmation before drafting — don't assume context is complete.
- Always produce `status: 'draft'` in frontmatter. The user publishes when ready.
- Never write to files without explicit permission.
- Use the local skill reference file `content-review/references/content-guidelines.md` as the canonical extended guideline set, including the full anti-LLM rule set. Do not fetch guidance from external repos during drafting.
