---
name: skein-show-me
description: Picks a visual format instead of prose when it makes an explanation clearer. Use for algorithms, runtime calls, UI structure, architecture, data flow, diffs, or PR descriptions; chooses pseudocode, a tree, Mermaid, a diff, or a standalone HTML file.
---

# Show Me

Invoke with `/skill:skein-show-me [topic or question to visualize]`. Treat the appended request as the topic. If neither it nor the conversation identifies a topic, ask what to visualise.

Prefer the smallest visual that answers the question, with a short explanation next to it. When a sentence or two works better, use prose. This is a standalone format-selection skill: work in the current Pi session with the user's selected model; no worker, other skill, renderer, or package script is required.

## Format menu

| Question | Format |
|---|---|
| Algorithm or branching logic | Pseudocode |
| What calls what at runtime | Call tree |
| UI state, props, and boundaries | Component tree |
| File responsibility or architecture | File tree |
| Interactions or data flow | Mermaid diagram |
| What changed | Diff |
| Complex layout or multidimensional comparison | Standalone HTML file, only when requested |

## Smallest useful view

- Include only the relevant files, states, props, steps, or edges, not the whole system.
- Ground code-specific claims in the supplied material or inspect the relevant files with Pi's read tool. Label hypothetical examples; do not invent observed relationships.
- Prefer plain fenced pseudocode, trees, or diffs over elaborate HTML. Use a table if that is clearer.
- A proposed diff is illustrative, not evidence that files have changed. Do not apply it unless asked.

## Output boundaries

- **Plain fenced blocks** work in the terminal and Markdown documents. Use these when rendering support is uncertain.
- **Mermaid** belongs in a fenced `mermaid` block. Pi rendering depends on the runtime and the user's Markdown settings; do not assume every terminal or destination renders it. Include a short text explanation or tree fallback. GitHub Markdown supports Mermaid; keep PR bodies Markdown-safe.
- **HTML** is not an in-chat artifact API. Only when the user requests a file, write a self-contained `.html` file at an agreed path using Pi's write tool, then report its path for opening in a browser. Do not overwrite an existing file without permission. Escape embedded source text, use inline styles, and avoid remote assets, scripts, and network requests. Do not open a browser or publish automatically. If file writing is unavailable, offer the HTML source in a fenced block instead.
- Do not put HTML artifacts in PR bodies (GitHub strips scripts/styles). Use a tree, diff, or Mermaid there instead.

No cross-skill invocation is needed. Do not route the request to unported plan, review, or artifact-design skills.
