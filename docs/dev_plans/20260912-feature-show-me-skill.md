# show-me Skill

| Field | Value |
|-------|-------|
| **Status** | In Progress |
| **Component** | meta |
| **Priority** | Low |
| **Branch** | `feat/show-me-skill` |
| **Created** | 2026-09-12 |
| **Review Gates** | full |
| **Objective** | Add a `show-me` skill that governs when to reach for a visual (pseudocode, call tree, component tree, file tree, mermaid diagram, diff, HTML artifact) instead of prose, modeled on `humanlayer/skills`' `show-me` plugin |

## Context

User asked how skein's skills compare to [`humanlayer/skills`](https://github.com/humanlayer/skills/tree/main/plugins) — a `WebFetch` survey of that repo's `plugins/` found five plugins, of which `show-me` (a Claude system-prompt for visual-format selection: pseudocode/call-tree/component-tree/file-tree/mermaid/diffs/HTML-artifacts, "smallest view that makes the key point clear") had no analogue anywhere in skein. Skein's closest adjacent surfaces are the built-in `artifact-diagramming`/`dataviz` skills (diagram *mechanics*) and `skein:plan-view` (a corpus-scoped renderer with its own widget toolkit) — neither makes the general judgment call of *when* a diagram beats prose for an arbitrary explanation.

Confirmed distinct scope from `plan-view` before starting: `plan-view` renders `docs/dev_plans/*.md` into HTML dashboards/rich views with drift-guard caching and a fixed widget set; `show-me` is a freeform, uncached format-selection heuristic for any answer (code explanations, architecture questions, PR descriptions), not just dev plans.

## Requirements

1. New skill at `plugins/skein/skills/show-me/SKILL.md` (and Codex mirror) covering: when to reach for each of the seven visual formats, how to pick the smallest useful view, and format-specific rendering notes (mermaid renders in GitHub/artifacts, HTML artifacts don't render in GitHub markdown).
2. No subagents, no tool calls, no scripts — pure judgment/prose skill, so the Codex mirror should be near-identical to the Claude mirror (unlike tool-delegating skills like `rfc-finder`).
3. Codex mirror drafted via `codex:rescue` per the mirror-editing convention (Codex reviews AND implements its own half; Claude edits only the Claude mirror + harness-neutral files).
4. Wire `show-me` into `update-docs`'s PR-description step (Phase 4, step 8, both mirrors) so PR-description drafting considers a mermaid diagram or file tree over prose-only — scoped to markdown-safe formats, since GitHub PR bodies strip `<script>`/`<style>`.
5. Add "Composing with other skills" notes cross-referencing `plan-view` (don't route its `--rich` output through `show-me` — different determinism contract) and `dev-plan` (its `## Architecture & Call Flow` section already does what `show-me` recommends).

## Implementation Checklist

### Phase 1: Skill creation
- [x] Draft `plugins/skein/skills/show-me/SKILL.md` (Claude mirror)
- [x] Delegate Codex mirror creation to `codex:rescue`; fresh-context self-review for parity (38/40 lines identical; only Claude Code-artifact-specific prose adapted)
- [x] Add "Composing with other skills" section referencing `update-docs`, `plan-view`, `dev-plan`

### Phase 2: update-docs integration
- [x] Claude mirror: `update-docs` Phase 4 step 8 now consults `skein:show-me`'s format menu before writing PR-description prose
- [x] Codex mirror: same edit via `codex:rescue`, preserving the Codex-specific confirmation-gate clause the Claude mirror doesn't have; fresh-context parity check passed

### Phase 3: Validation
- [x] `just check-prompt-parity` — passed
- [x] `just ci` (backgrounded) — passed
- [x] `/code-review xhigh --fix` (Claude mirror) + Codex review of the Codex mirror — 5 fixes applied (skill unregistered in `MANAGED_SKILLS`/`EXPECTED_SKILL_COUNT`, `update-docs` step 8 content drift, missing artifact-mechanics cross-reference, missing `**Review Gates:**` header); re-verified with `just ci`
- [ ] `skein:review-gauntlet`
- [ ] `/update-docs` — sync this plan's status/PR link, README index, CHANGELOG

## Technical Specifications

### Files Created
- `plugins/skein/skills/show-me/SKILL.md`
- `plugins/skein-codex/skills/show-me/SKILL.md`
- `docs/dev_plans/20260912-feature-show-me-skill.md` (this plan)

### Files Modified
- `plugins/skein/skills/update-docs/SKILL.md` — PR-description step references `skein:show-me`
- `plugins/skein-codex/skills/update-docs/SKILL.md` — same, with Codex's existing confirmation-gate clause preserved

## Testing Notes

- `just check-prompt-parity`: passed after both mirror edits.
- `just ci`: passed (backgrounded per project convention; full run exceeds the 2-minute foreground timeout).
- No skill-specific automated tests were added — `show-me` has no scripts or executable logic to unit-test; parity between mirrors is the only verifiable invariant, and `check-prompt-parity` covers it.

## Issues & Solutions

| Issue | Solution |
|-------|----------|
| Risk of collapsing `show-me` into the existing `plan-view` skill since both are "render a plan/answer visually" | Confirmed via inspection of `plan-view/SKILL.md` that it's a distinct corpus-scoped renderer with its own drift-guard/caching contract; kept `show-me` standalone rather than extending `plan-view` |
| Codex mirror could drift from Claude mirror without a tool-delegation seam to anchor the divergence | Delegated Codex-side authorship to `codex:rescue` per the mirror-editing convention, with an explicit fresh-context parity self-review after each edit |

## Final Results

_Pending merge — PR [#41](https://github.com/vr000m/skein/pull/41) open. Update this section, the Status header above, and `docs/dev_plans/README.md` via `/update-docs` after review gates converge and the PR merges._
