---
name: skein-content-draft
description: Drafts a TIL or blog post from confirmed session facts using an explicitly approved isolated worker, British English, concrete evidence, trade-offs, and rough edges. Use when asked to turn the current work into a TIL or blog draft.
---

# Skein Content Draft

Invoke with `/skill:skein-content-draft [--type til|blog] [--title "optional title"]`.

This skill uses the package's `skein_content_draft_worker` tool. It supports only the worker lane that the tool reports as available; never substitute the main model, another model, or an unapproved credential when the tool refuses. The worker has no tools and receives no parent conversation automatically.

## 1. Confirm format and source facts

Default to `til` unless the user requests a blog or the work clearly has enough evidence for 800–1,500 useful words. Suggest a title and ask the user to confirm the type and title.

In the main session, extract a compact factual summary:

- problem and intended audience;
- tools/technologies and concrete anchors (commands, paths, errors, metrics, dates);
- approach, decisions, rejected alternatives, and downsides;
- observed outcome, not an inferred result;
- one failed attempt or rough edge and the adjustment;
- non-obvious learning and unresolved limitations.

Show that summary and ask the user to correct or confirm it. Do not dispatch before confirmation. Do not invent missing facts merely to satisfy the writing template; explicitly label unavailable evidence.

## 2. Prepare the bounded request

The trusted extension loads `references/content-guidelines.md` from this installed skill package and deterministically builds the worker prompt and output contract. Do not fetch rules, use another harness's cache, or reproduce an alternate prompt. Supply only the confirmed `type`, `title`, current ISO date, audience, and summary. The extension JSON-encodes these as untrusted source data and fails rather than silently truncating when the resulting task or selected model context is too small.

## 3. Dispatch exactly one worker

Call `skein_content_draft_worker` once with exactly `type`, `title`, `date`, `audience`, and `summary`. It dispatches internally with the mechanical role and requires the standard worker result object:

```json
{
  "schema_version": 1,
  "status": "ok",
  "summary": "one-sentence description of the returned draft",
  "findings": [],
  "artifact": {"format": "markdown", "content": "complete draft including frontmatter"}
}
```

Require the draft to:

- use `status: 'draft'` frontmatter;
- use British English in prose and American English only for slug/filename SEO;
- start concrete-first and include evidence, outcome, a trade-off with downside, and a failure/adjustment;
- avoid assistant residue, placeholders, stock AI phrases, abstraction-only paragraphs, and repetitive cadence;
- keep TILs concise with `title`, `published_date`, and `status` frontmatter and a forward-looking close;
- give blogs complete frontmatter, bold TL;DR, H2/H3 hierarchy, 800–1,500 words unless evidence justifies another range, and a forward-looking close;
- preserve code/prose identifiers and use language-tagged fences and backticks for technical terms;
- return no commentary outside the structured object and never claim to have written a file.

The extension will show the exact worker task, model, and endpoint for user approval. If approval is declined or the tool returns an error/non-completed status, stop and report that no draft was accepted. Never reconstruct a draft from a failed worker's diagnostics.

## 4. Present and refine

Accept only `artifact.format == "markdown"` with non-empty content. Present the complete draft in a fenced block. Do not write it to disk unless the user explicitly asks after seeing it.

Offer: revise tone/focus; convert TIL/blog; run `/skill:skein-content-review` only because that skill is registered with this package; or save to an agreed path. Suggested paths are `content/til/<tag>/<slug>.md` and `content/blog/YYYY/<slug>.md`, but ask for the tag/path and never overwrite without permission.
