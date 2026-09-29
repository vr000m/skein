---
name: skein-content-review
description: Reviews confirmed Markdown or pasted prose with an explicitly approved isolated worker, returning severity-ranked findings and precise inline fixes against bundled writing rules. Use for blog posts, TILs, technical docs, Notion exports, or general prose.
---

# Skein Content Review

Invoke with `/skill:skein-content-review [file-path] [--type blog|til|technical-doc|notion|general]` or paste content in the conversation.

This skill uses the package's `skein_content_review_worker` tool. The worker has no tools: the main session must read the target and bundled rules, and the exact text sent is shown for user approval. Never substitute an unapproved model or treat a refused/degraded worker as a completed review.

## 1. Acquire content and confirm type

For a file path, read that one file in the main session. Do not accept a directory/glob in this port; ask the user to invoke one file at a time. For pasted content, use exactly the confirmed text. Never edit during review.

Choose type in this order: explicit flag; blog frontmatter (`slug`, `excerpt`, `category`, `authors`); path (`docs|documentation|guides`, `til|tils`, `blog|posts`); TIL frontmatter (`title` + `published_date` without blog fields); content signals; otherwise `general`. Explain the detected type and applicable scope, then ask the user to confirm/change it.

## 2. Prepare only the applicable bundled rules

The trusted extension selects and loads the installed reference deterministically: `content-guidelines.md` for blog/TIL, otherwise `writing-style-rules.md`. Do not fetch rules, use another harness's install/cache, or construct an alternate prompt. Supply only the confirmed `type`, optional display `path`, and full `content`. The extension JSON-encodes path/content as untrusted data and fails rather than silently truncating if the task or selected model context is too small.

## 3. Dispatch exactly one worker

Call `skein_content_review_worker` once with exactly `type`, optional `path`, and `content`. It dispatches internally with the mechanical role and requires this standard result:

```json
{
  "schema_version": 1,
  "status": "ok",
  "summary": "overall assessment with finding counts and word-count range",
  "findings": [
    {
      "severity": "critical|important|suggestion",
      "location": "line or section",
      "summary": "specific defect",
      "evidence": "short exact excerpt and violated bundled rule",
      "recommendation": "precise fix; include Original/Fixed text for critical and important items"
    }
  ],
  "artifact": {"format": "markdown", "content": "checklist/status report without duplicating every finding"}
}
```

Review scope:

- all types: British English body text (not American-English slug/filename), Oxford commas, active/direct prose, comma splices, repetition, missing words/typos, technical backticks, code/prose consistency, AI-template language, assistant residue, hedging, and formatting tics;
- blog/TIL: title alignment, concrete anchors, shown outcome, limitations, attribution, an explicit trade-off/downside, and a failed attempt/adjustment;
- blog: required metadata, 150–160 character excerpt, 3–5 tags, valid category, bold TL;DR, hero image reference, hook, hierarchy, code fences, and target range;
- TIL: required frontmatter, concise focus, code fences, and a non-abrupt forward-looking close;
- technical docs: style plus headings, language-tagged fences, code/prose consistency, and complete/marked examples;
- Notion/general: style only; skip irrelevant SEO/structure findings.

Severity means: critical = hard rule/publication blocker; important = material quality weakness; suggestion = optional polish. Findings must cite actual content. Do not fabricate line numbers, sources, or a failure/trade-off requirement for content types where it is out of scope. Return at most 100 findings and no prose outside the object.

The extension will present the exact task/model/endpoint for approval. On decline, tool error, invalid output, or non-completed status, stop and say no review was accepted; do not salvage partial diagnostics.

## 4. Present without changing content

Render the validated summary, severity-grouped findings, and artifact checklist. Preserve each finding's evidence and recommendation; do not inflate severity in the main session. Critical and important recommendations already carry inline Original/Fixed suggestions. Suggestions need no inline rewrite unless requested.

Offer to explain a finding, review another single file, or apply selected fixes. Apply nothing until the user explicitly chooses fixes. Before any edit, re-read the current file and verify the quoted original still matches; otherwise report drift and ask how to proceed. Never auto-commit.
