---
name: show-me
description: Picks a visual format — pseudocode, call tree, component tree, file tree, mermaid diagram, diff, or HTML artifact — instead of prose when a diagram would make the answer clearer. Use when explaining logic/algorithms, runtime control flow, UI structure, architecture, data flow, what changed in a diff, or drafting a PR description — anywhere a picture would answer the question faster than paragraphs.
argument-hint: "[topic or question to visualize]"
---

# Show Me

Prefer a diagram, sketch, or artifact over prose when one communicates the point faster. This is a format-selection skill, not a rendering library — it tells you *which* visual to reach for and *how much* of it to show, not how to draw it.

## When to reach for a visual

- Explaining an algorithm or branching logic → **pseudocode**
- Explaining what calls what at runtime → **call tree**
- Explaining UI structure (state, props, boundaries) → **component tree**
- Explaining architecture or file responsibility → **file tree**
- Explaining interactions or data flow between systems/components → **mermaid diagram**
- Explaining what changed in code, config, or control flow → **diff**
- Explaining a complex layout, comparison, or concept prose can't carry → **HTML artifact**

When none of these fit better than a sentence or two, just write the sentence. Not every answer needs a picture.

## Picking the smallest useful view

- Show only what's needed to answer the current question — the files, props, states, or steps relevant to it, not the whole system.
- Place the visual next to the supporting text; don't let it replace an explanation the user actually needs in words (a diagram plus zero context is often worse than prose).
- Two runs of the same explanation don't need to look identical — pick the format that fits *this* question, not whatever was used last time.
- If several formats would work, pick the cheapest one that's unambiguous (pseudocode/file tree/diff, in plain markdown) over the most elaborate one (HTML artifact) unless the content genuinely needs a canvas — a comparison table, an interactive layout, something with more than a couple of dimensions.

## Format-specific notes

- **Mermaid** renders natively in supported markdown viewers and GitHub PR bodies — safe to reach for anywhere markdown is rendered, including PR descriptions.
- **HTML artifacts** need a design pass before publishing and don't render in GitHub markdown (PR bodies strip `<script>`/`<style>`) — use them for in-conversation explanations and artifacts, not for content destined for a PR body or a plain markdown doc.
- **Pseudocode / call tree / component tree / file tree / diff** are all plain fenced code blocks — they render everywhere markdown does, including PR descriptions, dev-plan files, and commit messages.

## Composing with other skills

- **PR descriptions** (`skein:update-docs`, or manual `gh pr edit`/`gh pr create`): when summarizing a branch's changes, consider a mermaid diagram (data/control flow that changed) or a file tree (which files own which responsibility) or a diff snippet instead of prose-only summary. Stay within the markdown-safe formats above — no HTML artifacts in a PR body.
- **`skein:plan-view`** already does this at the corpus/single-plan level with its own constrained widget toolkit (state machines, compare views, timelines) gated on source-sha caching — don't route through `show-me` for plan-view's `--rich` output; that toolkit's determinism-up-to-LLM-variance contract is deliberate and separate from this skill's freeform judgment call.
- **`skein:dev-plan`**: its `## Architecture & Call Flow` section (component graph, sequence diagram) is exactly the kind of visual this skill recommends — no need to invoke `show-me` separately when already following `dev-plan`'s own template.
