# Task: Compact default `/deep-review` and `/review-plan` reports — Minor findings collapse to one line, `--verbose` restores full detail

**Status**: Not Started
**Component**: review-skills
**Assigned to**: Claude
**Priority**: Medium
**Branch**: feature/deep-review-compact-output
**Created**: 2026-07-12
**Review Gates**: none

## Objective

Make both `/deep-review`'s and `/review-plan`'s default rendered reports less verbose without losing any data: Critical and Important findings keep full detail (Severity/Category/Location/Evidence/Suggestion); Minor findings render as a single compact line (Severity/Category/Location/one-line summary only). A new `--verbose` flag (on both skills) restores today's full-detail rendering for every severity including Minor. Every `/deep-review` report — compact or verbose — ends with an explicit pointer to the persisted per-harness JSON state file, so the user can `jq`/grep the full underlying data instead of asking for a re-summary. `/review-plan` has no equivalent per-run JSON persistence (see Requirements/Architecture Decisions below), so its closing line differs: it states plainly that the annotated envelope is transient and re-running with `--verbose` is the way to see full detail again, rather than pointing at a file that doesn't exist.

## Context

Today's Step 5 (`plugins/skein/skills/deep-review/SKILL.md:514-542`) / `## Output` (`plugins/skein-codex/skills/deep-review/SKILL.md:475-504`) report template prints Evidence + Suggestion prose for every finding at every severity tier. The full per-lens findings are already persisted structurally: the reconciliation pass (Step 3.5) writes the annotated v2 envelope, and the orchestrator's run state is stored at `.deep-review/latest-claude.json` / `.deep-review/latest-codex.json` (Review State section, `plugins/skein/skills/deep-review/SKILL.md:28-33`). Nothing is actually lost by trimming the rendered Minor tier — only the *default rendering* is verbose, forcing users to ask for a summary after nearly every run. This plan changes the rendering contract only; the reconciliation schema, merge rules, and JSON persistence are untouched.

**Confirmed via Explore**: the GENERIC FINDING SCHEMA AND MERGE block (`plugins/skein/skills/deep-review/SKILL.md:397-425`, byte-identity-checked across 4 targets by `scripts/check-prompt-parity.sh`'s `GENERIC_TARGETS` array — both skills, both mirrors) sits entirely above and separate from the Step 5 / `## Output` report template (`SKILL.md:514-542` in skein, `:475-504` in skein-codex). Editing the report template does not touch the GENERIC block and does not require touching `scripts/reconcile-findings.sh` or the v2 envelope schema.

**Scope expansion (2026-07-12): `/review-plan` has the identical verbosity problem.** `plugins/skein/skills/review-plan/SKILL.md`'s Step 5 "Present Findings" template (lines 476-505) prints the same full `Lenses:`/`Evidence:`/`Suggestion:`/`Related findings:` block for every finding at every severity, with the identical Critical/Important/Minor heading structure as deep-review's pre-change template. The two skills' Step 5 templates are near-identical (`review-plan` additionally renders a `**Dispatch**:` line on the Codex mirror only — see Phase 5), so the same compact-Minor / `--verbose` design applies directly, subject to one confirmed asymmetry:

- **`/review-plan` persists no per-run findings JSON.** Read in full: `plugins/skein/skills/review-plan/SKILL.md` has no `## Review State` section and no `.review-plan/latest-*.json` file analogous to deep-review's. Its only on-disk artefacts are (a) the review marker — a single HTML-comment line written into the plan file itself at Step 7, and (b) transient auto-fix manifests at `.review-plan/auto-fix-<unix>-<pid>.json`, written **only** when `--auto-fix=trivial` was passed. The reconciled v2 envelope that Step 3/Step 5 render from is an in-memory/in-session artefact — it is piped through `scripts/reconcile-findings.sh` and `scripts/audit-auto-fix-eligibility.sh` but never written to a stable `latest-*.json` path the way deep-review's orchestrator does. `/review-plan` also has no `--continue` flag and no continuation-mode report template — the two skills diverge here, not just on persistence. Consequently: **`/review-plan`'s compact report footer cannot name a JSON state-file path** (Requirement 8 below) — a different closing line is used instead, and Open Question 2 (`render-reconciled-report.sh` scope) already covers `review-plan`'s reference-renderer status as shared infrastructure, unaffected by this asymmetry.

`scripts/check-prompt-parity.sh` confirmed (re-verified for this expansion): its rubric-diff loop (lines 60-92) compares `.claude`/`.codex` rubric.md **per skill**, not cross-skill — `deep-review/rubric.md` need never match `review-plan/rubric.md`; only each skill's own `.claude` vs `.codex` copy must be byte-identical. The GENERIC block check (`GENERIC_TARGETS`, lines 285-326) already spans all 4 targets (both skills × both mirrors) and requires no new script work for this expansion — the Step 5 templates being edited live entirely outside that block's `BEGIN`/`END` markers in all four files.

## Requirements

### `/deep-review` (Phases 1-4)

1. **Step 5 default rendering change** (both mirrors): Critical and Important findings render exactly as today (full `Lenses`/`Evidence`/`Suggestion` sub-bullets). Minor findings render as a single line: `- **[Category]**: [Location] — [one-line summary]` (no `Evidence:`/`Suggestion:` sub-bullets, no `Lenses:` sub-bullet expansion beyond what fits inline — see Technical Specifications for the exact compact-line format). The underlying data still carries all five fields (Severity, Category, Location, Evidence, Suggestion); only the *rendered* Minor tier omits Evidence/Suggestion prose from display.
2. **`--verbose` flag** (both mirrors): added to `argument-hint` and to Input Resolution / "What This Skill Reviews" as a modifier flag (composable with `--full`, `--pr`, `--continue`, `--auto-fix=trivial` — it changes only rendering, not scope resolution or lens dispatch). When passed, every finding at every severity renders with full Evidence/Suggestion detail — i.e., today's current behavior, unconditionally.
3. **JSON pointer footer** (both mirrors, both compact and verbose modes): every rendered report — Step 5's normal template and the continuation-mode template — ends with an explicit line naming the per-harness state file path (`.deep-review/latest-claude.json` on Claude, `.deep-review/latest-codex.json` on Codex) so the user can inspect the full per-lens findings directly (e.g. `jq '.lenses' .deep-review/latest-claude.json`) instead of asking for a re-summary.
4. **Four-file symmetry**: `plugins/skein/skills/deep-review/SKILL.md`, `plugins/skein/skills/deep-review/rubric.md`, `plugins/skein-codex/skills/deep-review/SKILL.md`, `plugins/skein-codex/skills/deep-review/rubric.md` all move together. `rubric.md` must stay byte-identical between the two mirrors (enforced by `scripts/check-prompt-parity.sh`'s rubric-diff loop, lines 60-92).
5. **Reconcile rubric wording**: `rubric.md`'s "Finding Quality" section currently states "Each finding has all five fields: Severity, Category, Location, Evidence, Suggestion" (line 14). This must be reworded so it is still true of the *underlying reconciled data* (all five fields always exist) while being explicit that the *default rendered report*'s Minor tier intentionally omits Evidence/Suggestion from display — the rubric and the SKILL.md report template must not contradict each other. See Technical Specifications for exact proposed wording.

### `/review-plan` (Phases 5-8) — same design, mirrored requirements

6. **Step 5 default rendering change** (both mirrors): identical rule to Requirement 1, applied to `plugins/skein/skills/review-plan/SKILL.md` Step 5 (lines 476-505) and `plugins/skein-codex/skills/review-plan/SKILL.md` Step 5 (lines 473-504). Critical/Important unchanged; Minor compact one-line by default; the underlying reconciled envelope (Step 3's `findings.jsonl` → `reconcile-findings.sh` output) still carries all five fields regardless of rendering. The Codex mirror's extra `**Dispatch**:` line (spawned-worker vs sequential-fallback label) is untouched by this change — it sits above the per-severity sections and is not part of the Minor-tier rendering rule.
7. **`--verbose` flag** (both mirrors): added to `argument-hint` (currently `"[path/to/plan.md] [--auto-fix=trivial] [--batch]"`) and documented as a rendering-only modifier, composable with `--auto-fix=trivial` and `--batch`. It does not change lens dispatch (still all five lenses, always), Step 6.4's interactive triage loop, or the review-marker write in Step 7 — those consume the full reconciled data regardless of how Step 5 renders it.
8. **Closing-line asymmetry (no JSON pointer footer)**: `/review-plan` has no per-run JSON state file to point to (see Context). Its report footer instead states the envelope is not persisted and that `--verbose` re-renders full detail from the same run's already-reconciled data (no re-dispatch needed) — see Technical Specifications for exact wording. This is a deliberate, confirmed asymmetry, not an oversight: implementing a `.review-plan/latest-*.json` persistence layer to give `/review-plan` a footer parallel to deep-review's is explicitly **out of scope** for this plan (it would be new functionality, not a rendering change).
9. **Four-file symmetry**: `plugins/skein/skills/review-plan/SKILL.md`, `plugins/skein/skills/review-plan/rubric.md`, `plugins/skein-codex/skills/review-plan/SKILL.md`, `plugins/skein-codex/skills/review-plan/rubric.md` all move together, mirroring Requirement 4. `rubric.md` must stay byte-identical between the two `review-plan` mirrors — this is checked independently of deep-review's rubric pair (per-skill loop in `check-prompt-parity.sh`, confirmed above).
10. **Reconcile rubric wording**: `review-plan/rubric.md`'s "Finding Quality" section (lines 21-28) states "Each finding has all five fields: `category`, `severity`, `finding`, `evidence`, `suggestion`" — reword identically in spirit to Requirement 5: data-completeness vs. rendering-conditional display. `review-plan/rubric.md` has no `Continuation Safety` or `Dispatch Preflight` sections to reconcile (those are deep-review-only, confirmed above) — only `Finding Quality` needs the wording split.

### Shared across both skills

11. **Authoring route** (per project convention, given — unchanged from the original plan, now applied identically to `review-plan`'s four files): `plugins/skein/skills/{deep-review,review-plan}/*` is edited directly by Claude. `plugins/skein-codex/skills/{deep-review,review-plan}/SKILL.md` content must be authored via the `codex:rescue` skill (not hand-edited), followed by a second fresh-thread `codex:rescue` call that independently reviews that edit. `rubric.md` on both skills is treated as a **repo-level data file** — Claude edits it directly on both mirrors and copies it byte-for-byte, no `codex:rescue` pass required (this is now a settled decision, not an open question — see Architecture Decisions).
12. **Test coverage decision**: decide, and act on, whether `tests/reconciliation/` needs new fixtures for compact-Minor / `--verbose` rendering (for either skill) and whether `scripts/render-reconciled-report.sh` (the repo-only reference renderer, shared by both skills) needs updating to match — see Open Question 1 (renumbered) and the shared final phase.

## Open Questions (for human decision before/at review-plan time)

1. **`scripts/render-reconciled-report.sh` scope** (this is the former Open Question 2 — renumbered to 1 now that the rubric-ownership question is settled, see below): this script is confirmed (via Explore) to be a *shared* reference renderer — its header comment states it encodes the report template for **both** `deep-review` and `review-plan`, it is invoked only by tests (`tests/reconciliation/test-renderer.sh`, `test-renderer-v1-rejects-v2.sh`), and it is deliberately **not bundled** into either installed skill (`scripts/lib/bundle-map.sh`) — the running review always renders "by hand" from the SKILL.md prose template, never by invoking this script live. This is now shared infrastructure for **both** in-scope skills (deep-review and review-plan), not deep-review alone — the resolution below applies uniformly to both. Two options:
   - **(a) Leave the script rendering full Evidence/Suggestion for all severities, unchanged.** Neither `deep-review`'s nor `review-plan`'s new compact-Minor rendering gets golden-file coverage from this script; the script's own doc comment ("all fields... MUST be preserved") becomes slightly stale for both skills' new default behavior (though still accurate as a description of the *underlying data*, and still accurate for whichever skill's rendering the tests still exercise against full-detail mode). Cheapest, no shared-script risk, but leaves both new compact-rendering paths without automated regression coverage beyond a manual walkthrough.
   - **(b) Add a `--compact-minor` (or `--verbose`) flag to the script itself**, mirroring the SKILL.md flag on both skills, so both skills' compact and verbose paths get golden-file coverage. Higher fidelity, but changes a script two skills already share, doubling the fixture surface (deep-review compact/verbose + review-plan compact/verbose).
   This plan recommends **(a)** uniformly for both skills in this PR (documented as a follow-up in Findings/Testing Notes) to keep the shared script's current behavior untouched and avoid the doubled fixture surface — but flags it for explicit confirmation since "no automated regression coverage for either compact renderer" is a real trade-off the human should sign off on, not one this plan should decide unilaterally.

## Findings / Architecture Decisions (settled — not open questions)

- **`rubric.md` is a repo-level data file, for both skills.** This was Open Question 1 in the original (deep-review-only) plan; the user has since confirmed the resolution, and it now applies identically to `review-plan/rubric.md`: Claude authors `plugins/skein/skills/{deep-review,review-plan}/rubric.md` directly, then copies the identical bytes to `plugins/skein-codex/skills/{deep-review,review-plan}/rubric.md`. No `codex:rescue` pass is required for either skill's rubric — the precedent is `20260711-feature-review-plan-grill-step.md`'s Phase 3, which copied `rubric.md` verbatim reasoning "not Codex-specific prose" (a gradeable-criteria checklist, not harness-tuned instructional prose). **Whatever the file, both `.claude`/`.codex` copies must end up byte-identical** — `scripts/check-prompt-parity.sh`'s per-skill rubric loop fails otherwise. This decision is recorded here as settled; do not re-litigate it during implementation.

## Architecture & Call Flow

Two independent single-component changes (prose-driven markdown skills, no new execution component, no new script, no cross-skill runtime coupling) — per `skein:dev-plan`'s own gate ("omit the section entirely for single-component changes"), this section is omitted for both `deep-review` and `review-plan`. The two skills do not call each other and share no runtime state; the only thing they share is prose-level convention (the GENERIC block, the reconciliation script, and now this rendering design), which is a documentation/authoring concern, not a call-flow one.

## Implementation Checklist

### Phase 1: `deep-review` Claude mirror — SKILL.md report template + flag (Claude, direct edit)

**Impl files:** `plugins/skein/skills/deep-review/SKILL.md`
**Test files:** (none — prose-only; parity/presence tests run in Phase 4)
**Test command:** `bash scripts/check-prompt-parity.sh`
**Goal:** The default rendered report is compact for Minor findings without dropping any underlying data; `--verbose` is a pure rendering-mode switch that does not alter scope resolution, lens dispatch, or the reconciliation contract.

- `argument-hint` (line 4): append `[--verbose]` — `"[path/to/review-target|PR] [--full] [--continue] [--auto-fix=trivial] [--verbose]"`.
- Input Resolution (`## Input Resolution`, lines 17-26): add a line noting `--verbose` is a rendering-mode modifier, composable with any of the six resolution rules above it (it does not change which diff range or target is resolved).
- Step 5 (`### 5. Present Findings`, lines 514-542): rewrite the template so the `### Minor` section's bullet format is compact by default:
  - Critical / Important: unchanged — `- **[Category]**: [Finding]` + `Lenses:`/`Evidence:`/`Suggestion:`/optional `Related findings:` sub-bullets.
  - Minor (default, no `--verbose`): `- **[Category]**: [file:line] — [one-line summary]` — a single line, no sub-bullets. The one-line summary is the finding's existing `summary` field (already present in the v2 envelope per the GENERIC block, `SKILL.md:398`), not a re-derived paraphrase.
  - Minor (`--verbose` passed): render identically to Critical/Important — full `Lenses:`/`Evidence:`/`Suggestion:`/`Related findings:` sub-bullets, i.e. today's unconditional behavior.
  - Append a footer line after `**Next steps**:` (or immediately before it — pick one position and match it in both mirrors) pointing at the state file: `**Full findings JSON**: .deep-review/latest-claude.json` (this is a literal, harness-specific path — do not templatize it, matching how the Review State section already hardcodes it per-harness).
- Update the prose paragraph immediately after the template (`SKILL.md:542`) to describe the new compact-Minor default, the `--verbose` override, and the JSON footer — this paragraph currently only documents the `Reconciliation:`/`dropped=`/`Lenses:`/`Related findings:` rendering rules; extend it, don't replace it.
- `## Deep Review Rules` (line 566 area): add one bullet — "Default rendering: Minor findings render compact (no Evidence/Suggestion); `--verbose` restores full detail for all severities. This is a display-only switch — it does not change lens dispatch, reconciliation, or suppression."
- Continuation report format (`SKILL.md:546-564`): confirm whether the compact-Minor rule applies to the continuation template's `#### Minor` subsections too (it should — the same Step 5 rendering rule governs both "New findings" and any Minor entries there) and note this explicitly rather than leaving it ambiguous.

### Phase 2: `deep-review` Claude mirror — rubric.md reconciliation (Claude, direct edit)

**Impl files:** `plugins/skein/skills/deep-review/rubric.md`
**Test files:** (none)
**Test command:** `bash scripts/check-prompt-parity.sh` (expected to still show rubric drift until Phase 4 copies the codex side — see note)
**Goal:** The rubric never contradicts the SKILL.md report template — "all five fields exist in the data" and "the rendered Minor tier omits two of them by design" are both stated, not left to collide.

- "Finding Quality" section (`rubric.md:12-18`): reword the "all five fields" bullet to separate data-completeness from rendering, e.g.: "Each reconciled finding carries all five fields (Severity, Category, Location, Evidence, Suggestion) in the underlying data; the default rendered report shows all five for Critical/Important and Severity+Category+Location+one-line-summary for Minor (full detail restored with `--verbose`)."
- Add a new gradeable criterion (a new bullet, or a small "Output Structure" addition, matching the existing section granularity) covering: "Minor findings render compact by default (no Evidence/Suggestion sub-bullets); `--verbose` restores full detail for every severity; the report always ends with the per-harness JSON state file path."
- Do not touch any other rubric section (Coverage, Suppression Discipline, Scope Discipline, Reconciliation, Auto-Fix Lens Emission, Continuation Safety, Dispatch Preflight) — this is a Finding Quality / Output Structure wording change only, not a new gradeable domain.

### Phase 3: `deep-review` Codex mirror — SKILL.md via `codex:rescue`, then independent `codex:rescue` review

**Impl files:** `plugins/skein-codex/skills/deep-review/SKILL.md`
**Test files:** (none)
**Test command:** `bash scripts/check-prompt-parity.sh`
**Goal:** The Codex mirror gains semantically equivalent compact-Minor / `--verbose` / JSON-footer behavior, expressed in the Codex mirror's own idiom (its `## Output` heading depth, its `"$SKILL_DIR"` path anchors, its `.deep-review/latest-codex.json` state path) — authored through `codex:rescue`, not hand-copied from Phase 1's Claude wording.

- Invoke `codex:rescue` with the Phase 1 diff as reference context and an explicit instruction to adapt (not transliterate) the same three behavior changes into `plugins/skein-codex/skills/deep-review/SKILL.md`: `argument-hint` (line 4), Input Resolution numbered list (lines 25-40), the `## Output` template (lines 475-504) with its `### Critical`/`### Important`/`### Minor` structure, the continuation template's Minor handling, and the `.deep-review/latest-codex.json` footer line.
- Confirm the Codex-side `argument-hint` gets `--verbose` appended consistently with its existing (already slightly divergent) wording style — note the Explore finding that the Codex `argument-hint` says `path/to/plan.md` (likely a copy-paste artifact from review-plan) rather than `path/to/review-target|PR`; do not silently "fix" that pre-existing drift as part of this change unless the `codex:rescue` pass flags it as in-scope — if it does, note the fix separately in Findings so it's not conflated with this plan's actual scope.
- After the first `codex:rescue` authoring pass lands, run a **second, fresh-thread `codex:rescue` call** whose only job is to independently review that edit — no shared context with the authoring call — checking: (a) the three behavior changes are present and semantically equivalent to Phase 1, (b) no unrelated wording drift was introduced, (c) the `"$SKILL_DIR"` anchors are preserved where they already existed and no new one was invented without justification, (d) the harness-divergent path anchors (`.deep-review/latest-codex.json`, `"$SKILL_DIR"`) are correct per the existing memory note on this repo (Claude uses `${CLAUDE_PLUGIN_ROOT}`, Codex uses `$SKILL_DIR` — never collapse the two).
- Apply any fixes the second `codex:rescue` review surfaces before moving to Phase 4.

### Phase 4: `deep-review` rubric.md parity

**Impl files:** `plugins/skein-codex/skills/deep-review/rubric.md`
**Test files:** (none)
**Test command:** `bash scripts/check-prompt-parity.sh`
**Goal:** `deep-review`'s `rubric.md` is byte-identical across mirrors per the settled Findings decision (rubric.md is a repo-level data file).

- Copy `plugins/skein/skills/deep-review/rubric.md` to `plugins/skein-codex/skills/deep-review/rubric.md` byte-for-byte. No `codex:rescue` pass — per the settled decision in Findings/Architecture Decisions.

### Phase 5: `review-plan` Claude mirror — SKILL.md report template + flag (Claude, direct edit)

**Impl files:** `plugins/skein/skills/review-plan/SKILL.md`
**Test files:** (none — prose-only; parity/presence tests run in Phase 8)
**Test command:** `bash scripts/check-prompt-parity.sh`
**Goal:** The default rendered `/review-plan` report is compact for Minor findings without dropping any underlying data; `--verbose` is a pure rendering-mode switch identical in spirit to deep-review's, adapted for review-plan's lack of JSON persistence and its Step 6.4/6.5/7 downstream steps that must keep consuming full data regardless of Step 5's rendering.

- `argument-hint` (line 4): append `[--verbose]` — `"[path/to/plan.md] [--auto-fix=trivial] [--batch] [--verbose]"`.
- Add a short note near "Path Resolution" or at the top of "Execution" documenting `--verbose` as a rendering-mode modifier, composable with `--auto-fix=trivial` and `--batch` — it does not change lens dispatch (Step 2 still always runs all five lenses), the Step 3 reconciliation output, the Step 6.4 triage/clarify loop's finding set, or the Step 7 marker-write logic.
- Step 5 (`### Step 5: Present Findings`, lines 476-505): rewrite the template so the `### Minor` section's bullet format is compact by default, mirroring Phase 1's rule exactly:
  - Critical / Important: unchanged — `- **[Category]**: [Finding]` + `Lenses:`/`Evidence:`/`Suggestion:`/optional `Related findings:` sub-bullets.
  - Minor (default, no `--verbose`): `- **[Category]**: [file:line] — [one-line summary]` — a single line, no sub-bullets, using the finding's existing `summary` field from the reconciled v2 envelope.
  - Minor (`--verbose` passed): render identically to Critical/Important — full detail, i.e. today's unconditional behavior.
  - Append a footer line after `**Next steps**:` (match the position chosen in Phase 1) stating the closing-line text from Requirement 8 — no JSON path, since none is persisted. Suggested wording: `**Full findings**: not persisted to disk (review-plan does not write a per-run state file); re-run with --verbose to see full Evidence/Suggestion for every finding from this same reconciled data.`
  - Preserve the Codex-only `**Dispatch**:` line unaffected — it is not part of the per-finding rendering rule and both mirrors' Step 5 already diverge slightly on it (Claude's Step 5 template has no `**Dispatch**:` line at all; only the Codex mirror does, per its parallel/fallback dispatch-path framing).
- Update the prose paragraph immediately after the template (`SKILL.md:505`) to describe the new compact-Minor default, the `--verbose` override, and the no-JSON closing line — extend the existing paragraph about `Reconciliation:`/`dropped=`/`Lenses:`/`Related findings:` rendering rules, don't replace it.
- Step 6.4 (Interactive Triage-and-Clarify loop): confirm — and note explicitly, don't leave implicit — that the loop's numbered-list presentation (`Present the reconciled findings as a numbered list (the Step 5 ordering)`, line 526) operates on the full reconciled finding set regardless of how Step 5 rendered it (compact or verbose); the loop must not lose Evidence/Suggestion detail for Minor findings just because the default render omitted it from display. This is the one place review-plan's design differs meaningfully from deep-review's: deep-review has no analogous "present every finding to the user for individual triage" step, so this note has no Phase-1 counterpart.
- `## Constraints` section (end of file): add one bullet mirroring deep-review's new Rules bullet — "Default rendering: Minor findings render compact (no Evidence/Suggestion); `--verbose` restores full detail for all severities. This is a display-only switch — it does not change lens dispatch, reconciliation, the Step 6.4 triage loop's finding set, or the Step 7 marker write."

### Phase 6: `review-plan` Claude mirror — rubric.md reconciliation (Claude, direct edit)

**Impl files:** `plugins/skein/skills/review-plan/rubric.md`
**Test files:** (none)
**Test command:** `bash scripts/check-prompt-parity.sh` (expected to still show rubric drift until Phase 8 copies the codex side — see note)
**Goal:** `review-plan`'s rubric never contradicts its SKILL.md report template, mirroring Phase 2's goal exactly.

- "Finding Quality" section (`rubric.md:21-28`): reword the "all five fields" bullet (`- Each finding has all five fields: category, severity, finding, evidence, suggestion`) to separate data-completeness from rendering, mirroring Phase 2's wording: "Each reconciled finding carries all five fields (`category`, `severity`, `finding`, `evidence`, `suggestion`) in the underlying data; the default rendered report shows all five for Critical/Important and category+severity+location+one-line-finding for Minor (full detail restored with `--verbose`)."
- Add a new gradeable criterion under "Finding Quality" or "Merge Output" (matching existing section granularity) covering: "Minor findings render compact by default (no Evidence/Suggestion sub-bullets); `--verbose` restores full detail for every severity; the report states plainly that no per-run JSON is persisted (unlike deep-review)."
- Do not touch any other rubric section (Coverage, Lens Scope Discipline, Severity Discipline, Merge Output's other bullets, Reconciliation, Auto-Fix Lens Emission, Prompt-Injection Posture, Grill Discipline, Review Marker) — Finding Quality wording change only.

### Phase 7: `review-plan` Codex mirror — SKILL.md via `codex:rescue`, then independent `codex:rescue` review

**Impl files:** `plugins/skein-codex/skills/review-plan/SKILL.md`
**Test files:** (none)
**Test command:** `bash scripts/check-prompt-parity.sh`
**Goal:** The Codex `review-plan` mirror gains semantically equivalent compact-Minor / `--verbose` / no-JSON-footer behavior, expressed in its own idiom (`"$SKILL_DIR"` anchors, the `**Dispatch**:` line, its `spawn_agent` vs sequential-fallback framing) — authored through `codex:rescue`, not hand-copied from Phase 5's Claude wording.

- Invoke `codex:rescue` with the Phase 5 diff as reference context and an explicit instruction to adapt (not transliterate) the same behavior changes into `plugins/skein-codex/skills/review-plan/SKILL.md`: `argument-hint` (line 4, currently `"[path/to/plan.md] [--auto-fix=trivial] [--batch]"`), a `--verbose` composability note near Step 2's dispatch-path announcement, the Step 5 template (lines 473-504) including its Codex-only `**Dispatch**:` line (preserve unchanged), the Step 6.4 loop's "operates on full data regardless of rendering" note, and the `## Constraints` bullet.
- Confirm the closing-line wording is adapted to the Codex mirror's voice (its Step 5 prose already differs slightly from Claude's, e.g. "Present the merged findings to the user. Format them clearly:" vs Claude's "Return findings in a structured report:") rather than byte-copied from Phase 5.
- After the first `codex:rescue` authoring pass lands, run a **second, fresh-thread `codex:rescue` call** whose only job is to independently review that edit — no shared context with the authoring call — checking: (a) the behavior changes are present and semantically equivalent to Phase 5, (b) no unrelated wording drift was introduced elsewhere in the file (particularly Step 6.4's grill-delegation prose and Step 7's marker-write procedure, which must remain byte-for-byte untouched by this rendering-only change), (c) the `"$SKILL_DIR"` anchors are preserved where they already existed and no new one was invented without justification, (d) the no-JSON closing line does not accidentally invent a `.review-plan/latest-*.json` path that doesn't exist in this codebase.
- Apply any fixes the second `codex:rescue` review surfaces before moving to Phase 8.

### Phase 8: `review-plan` rubric.md parity + shared test-coverage decision + version/changelog

**Impl files:** `plugins/skein-codex/skills/review-plan/rubric.md`, `scripts/render-reconciled-report.sh` (no code change expected — verification only, unless Open Question 1 resolves to option (b)), `plugins/skein/.claude-plugin/plugin.json`, `plugins/skein-codex/.codex-plugin/plugin.json`, `CHANGELOG.md`, `README.md`, `docs/dev_plans/README.md`
**Test files:** `tests/reconciliation/` (new fixtures, only if Open Question 1 resolves to option (b))
**Test command:** `bash scripts/check-prompt-parity.sh && bash tests/reconciliation/run-fixtures.sh && bash tests/reconciliation/test-renderer.sh`
**Validation cmd:** `jq -r .version plugins/skein/.claude-plugin/plugin.json plugins/skein-codex/.codex-plugin/plugin.json | sort -u | wc -l` — must print `1`
**Goal:** Both skills' `rubric.md` pairs are byte-identical across mirrors and the parity script passes for both; the shared `render-reconciled-report.sh` scope decision (Open Question 1) is actually acted on rather than left implicit, uniformly for both skills; both manifests, CHANGELOG, README, and the dev-plans index reflect the shipped change for both skills in one release.

- Copy `plugins/skein/skills/review-plan/rubric.md` to `plugins/skein-codex/skills/review-plan/rubric.md` byte-for-byte — per the settled Findings decision (rubric.md is a repo-level data file for both skills), no `codex:rescue` pass.
- Resolve Open Question 1 with the user (or carry the plan's default of option (a) if the user doesn't override it). If **(a)** (recommended default): add a one-line note to this plan's Testing Notes / Findings stating `scripts/render-reconciled-report.sh` intentionally still renders full detail for all severities for both skills; neither `deep-review`'s nor `review-plan`'s compact-Minor path has golden-file coverage, covered by manual walkthrough only — no script or fixture changes for either skill. If **(b)**: add a `--compact-minor`/`--verbose` flag to `scripts/render-reconciled-report.sh`'s argument parsing (net-new — Explore confirmed no existing `case $1`/flag loop in the script), add new fixtures for **both** skills under `tests/reconciliation/fixtures/` and `expected/` (e.g. `deep-review-compact-minor-default.jsonl`/`.rendered.md`, `deep-review-compact-minor-verbose.rendered.md`, `review-plan-compact-minor-default.jsonl`/`.rendered.md`, `review-plan-compact-minor-verbose.rendered.md`), and update `tests/reconciliation/test-renderer.sh`'s fixture list for both.
- Bump both manifests `0.5.0` → `0.5.1` (behavior refinement to two existing skills, not a new skill — patch bump, consistent with the repo's semver-ish convention observed in `CHANGELOG.md`'s `[0.2.1]`–`[0.2.4]` patch entries for skein-only wording/behavior fixes). One bump covers both skills' changes in the same release — do not bump twice.
- Add a `## [0.5.1] - <date>` entry to `CHANGELOG.md` describing the compact Minor rendering, `--verbose`, and the JSON-footer pointer for `/deep-review` **and** the equivalent compact rendering / `--verbose` / no-JSON closing-line change for `/review-plan`, in one entry covering both skills; add the corresponding `[0.5.1]: .../compare/v0.5.0...v0.5.1` footer link and update the `[Unreleased]` compare link.
- No `README.md` skills-table change needed for either skill (no new skill, no new row) — confirm neither the `deep-review` nor the `review-plan` row description reads misleadingly stale without a one-clause mention of the compact default; add one only if it does.
- Update `docs/dev_plans/README.md`'s Planned table entry (line 21) for this plan: the Name cell currently reads `deep-review-compact-output`; broaden it to `deep-review-review-plan-compact-output` (or similar) to reflect the now-dual-skill scope, since the file's title changed. Keep the filename (`20260712-feature-deep-review-compact-output.md`), branch (`feature/deep-review-compact-output`), and Date columns unchanged — only the Name cell's descriptive text needs updating; renaming the file or branch is out of scope and would break the existing link/branch already in use for this work.

## Technical Specifications

### Files to Modify

**`/deep-review` (4 files):**
- `plugins/skein/skills/deep-review/SKILL.md` — `argument-hint`, Input Resolution, Step 5 template (Minor compact-by-default, `--verbose` full-detail override, JSON-footer pointer), Deep Review Rules bullet, continuation-template clarification.
- `plugins/skein/skills/deep-review/rubric.md` — Finding Quality wording reconciliation + new Output Structure criterion.
- `plugins/skein-codex/skills/deep-review/SKILL.md` — semantically equivalent update, authored via `codex:rescue` + independent `codex:rescue` review pass.
- `plugins/skein-codex/skills/deep-review/rubric.md` — byte-identical copy of the Claude rubric.md edit.

**`/review-plan` (4 files):**
- `plugins/skein/skills/review-plan/SKILL.md` — `argument-hint`, Execution/Step 2 composability note, Step 5 template (Minor compact-by-default, `--verbose` full-detail override, no-JSON closing line), Step 6.4 full-data note, Constraints bullet.
- `plugins/skein/skills/review-plan/rubric.md` — Finding Quality wording reconciliation + new criterion.
- `plugins/skein-codex/skills/review-plan/SKILL.md` — semantically equivalent update, authored via `codex:rescue` + independent `codex:rescue` review pass.
- `plugins/skein-codex/skills/review-plan/rubric.md` — byte-identical copy of the Claude rubric.md edit.

**Shared:**
- `plugins/skein/.claude-plugin/plugin.json`, `plugins/skein-codex/.codex-plugin/plugin.json` — version bump `0.5.0` → `0.5.1` (one bump for both skills' changes).
- `CHANGELOG.md` — new entry (covering both skills) + compare-link footer.
- `docs/dev_plans/README.md` — Planned table Name cell update (line 21) reflecting the dual-skill scope.
- `scripts/render-reconciled-report.sh`, `tests/reconciliation/*` — only if Open Question 1 resolves to option (b), for both skills.

### New Files to Create
- (conditional) `tests/reconciliation/fixtures/{deep-review,review-plan}-compact-minor-*.jsonl` and `tests/reconciliation/expected/{deep-review,review-plan}-compact-minor-*.rendered.md` — only if Open Question 1 resolves to option (b).

### Architecture Decisions
- **Rendering-only change, no schema change, for both skills.** The v2 envelope (`schema_version: 2`), the GENERIC FINDING SCHEMA AND MERGE block, `scripts/reconcile-findings.sh`, and (for deep-review) the `.deep-review/latest-*.json` persistence format are all untouched. Confirmed via Explore that the GENERIC block is structurally and textually separate from each skill's Step 5 / `## Output` report template in all four `SKILL.md` files — no byte-parity collision between this change and `check-prompt-parity.sh`'s `GENERIC_TARGETS` check.
- **`--verbose` is a pure display switch, on both skills.** It composes with deep-review's `--full`/`--pr`/`--continue`/`--auto-fix=trivial` and with review-plan's `--auto-fix=trivial`/`--batch`, rather than replacing or conflicting with any of them — it changes nothing about scope resolution, lens dispatch, reconciliation, suppression, the Step 6.4 triage loop's finding set, or the Step 7 marker write, only how the already-reconciled findings are printed.
- **`review-plan` has no JSON state-file footer, by design, not by omission.** Confirmed via full read of `plugins/skein/skills/review-plan/SKILL.md`: there is no `## Review State` section and no `.review-plan/latest-*.json` persistence analogous to deep-review's. The only on-disk artefacts are the in-plan review marker (Step 7) and transient `--auto-fix=trivial` manifests. Building a parallel persistence layer so `/review-plan` could have a footer symmetrical to deep-review's is explicitly out of scope — it would be new functionality, not a rendering change, and this plan's Objective is scoped to rendering only. `/review-plan`'s footer instead states plainly that the envelope is not persisted and that `--verbose` re-renders from the same run's already-reconciled data.
- **`render-reconciled-report.sh` is out of this plan's default scope for both skills** (Open Question 1, defaulting to option (a)) because it is confirmed shared between `deep-review` and `review-plan`, and confirmed not to be the runtime rendering path for either skill (both skills render "by hand" from their respective SKILL.md prose; the script exists solely as a golden-file test fixture target). Changing it for one skill without the other would be inconsistent; changing it for both doubles the fixture surface this PR would need to review.
- **`rubric.md` is treated as a repo-level data file for both skills** (formerly Open Question 1 in the deep-review-only version of this plan; now settled — see Findings/Architecture Decisions above), following the `20260711-feature-review-plan-grill-step.md` Phase 3 precedent, which explicitly reasoned rubric.md is "not Codex-specific prose" and copied it byte-identically without a `codex:rescue` pass. This applies uniformly to `deep-review/rubric.md` and `review-plan/rubric.md`.

### Dependencies
- None (no new runtime dependency; prose/rubric/version changes only, plus an optional test-fixture addition).

### Integration Seams

| Seam | Writer (task) | Caller (task) | Contract |
|------|---------------|---------------|----------|
| `deep-review` Step 5 template → rendered report | Phase 1 (`SKILL.md`) | End user reading `/deep-review` output | Critical/Important unchanged; Minor compact by default; `--verbose` restores full Minor detail; JSON state-file path always present in the footer |
| `deep-review` rubric.md → SKILL.md consistency | Phase 2 (`rubric.md`) | Self-check step (`SKILL.md`'s "Self-Check Rubric" section, unchanged) | Rubric's Finding Quality wording must not claim the rendered report always shows Evidence/Suggestion for Minor — it must say the *data* always has five fields and the *rendering* is severity-conditional |
| `deep-review` rubric.md parity | Phase 2 (`.claude` edit) | Phase 4 (`.codex` copy) + `scripts/check-prompt-parity.sh` | `.codex` `rubric.md` must be byte-identical to `.claude` `rubric.md` after Phase 4 lands, in the same commit as the `.claude` edit, or the per-skill parity check fails at any intermediate working-tree state |
| `deep-review` Codex mirror semantic parity | Phase 3 (`codex:rescue` authoring + independent `codex:rescue` review) | Human/PR reviewer | Codex `SKILL.md` must express the same behavior changes in its own idiom (heading depth, `"$SKILL_DIR"`, `.deep-review/latest-codex.json`) — not a byte-copy of the Claude wording, and not silently fixing the pre-existing `argument-hint` copy-paste drift unless explicitly called out |
| `review-plan` Step 5 template → rendered report | Phase 5 (`SKILL.md`) | End user reading `/review-plan` output, and the Step 6.4 triage loop consuming the underlying data | Critical/Important unchanged; Minor compact by default; `--verbose` restores full Minor detail; no-JSON closing line present in every variant; Step 6.4's numbered list still operates on full reconciled data regardless of Step 5's rendering mode |
| `review-plan` rubric.md → SKILL.md consistency | Phase 6 (`rubric.md`) | Self-check step (Step 4's rubric self-check, unchanged) | Same contract as deep-review's rubric/SKILL.md seam, applied to `review-plan`'s Finding Quality section |
| `review-plan` rubric.md parity | Phase 6 (`.claude` edit) | Phase 8 (`.codex` copy) + `scripts/check-prompt-parity.sh` | `.codex` `review-plan/rubric.md` must be byte-identical to `.claude` `review-plan/rubric.md` after Phase 8 lands — checked independently of the `deep-review` rubric pair (per-skill loop, confirmed) |
| `review-plan` Codex mirror semantic parity | Phase 7 (`codex:rescue` authoring + independent `codex:rescue` review) | Human/PR reviewer | Codex `SKILL.md` must express the same behavior changes in its own idiom (`"$SKILL_DIR"`, `**Dispatch**:` line preserved unchanged, `spawn_agent`/sequential-fallback framing), and must not invent a `.review-plan/latest-*.json` path that doesn't exist |
| GENERIC block byte-parity (both skills, both mirrors) | Pre-existing, unmodified by this plan | `scripts/check-prompt-parity.sh`'s `GENERIC_TARGETS` loop | Confirmed the Step 5 template edits in Phases 1, 3, 5, 7 all live outside the `<!-- BEGIN/END GENERIC FINDING SCHEMA AND MERGE -->` markers in all four `SKILL.md` files — no risk of breaking this check |

## Testing Notes

### Test Approach
- [ ] `scripts/check-prompt-parity.sh` passes (both skills' `rubric.md` byte-identity after Phases 4 and 8 respectively; GENERIC block unaffected across all 4 targets — this change does not touch it)
- [ ] Existing `tests/reconciliation/`, `tests/parity/`, `tests/plugin/` suites pass unchanged (regression check — this plan does not touch `reconcile-findings.sh`, the v2 envelope schema, or either skill's auto-fix pipeline)
- [ ] Manual walkthrough (`deep-review`, Claude mirror): run `/deep-review --full` against a synthetic diff seeded with at least one Critical, one Important, and two Minor findings; confirm Critical/Important render full detail, both Minor findings render as single compact lines with no Evidence/Suggestion sub-bullets, and the report ends with `.deep-review/latest-claude.json` named explicitly
- [ ] Manual walkthrough (`deep-review`, Claude mirror, `--verbose`): re-run with `--verbose` against the same seeded findings; confirm all four findings (including both Minor) render full Evidence/Suggestion detail
- [ ] Manual walkthrough (`deep-review`, Codex mirror): repeat both walkthroughs above against the Codex-authored `SKILL.md`, confirming `.deep-review/latest-codex.json` is named and the rendering rule is equivalent
- [ ] `deep-review` continuation-mode check: confirm the `(continuation)` report template's `#### Minor` subsection under "New findings" also renders compact by default and respects `--verbose`
- [ ] Manual walkthrough (`review-plan`, Claude mirror): run `/review-plan <plan-path>` against a plan seeded (or a real plan) that produces at least one Critical, one Important, and two Minor findings across the five lenses after reconciliation; confirm Critical/Important render full detail, both Minor findings render compact, and the report ends with the no-JSON closing line (not a fabricated path)
- [ ] Manual walkthrough (`review-plan`, Claude mirror, `--verbose`): re-run with `--verbose`; confirm all findings render full detail, and confirm Step 6.4's triage loop presents the same finding set (with full Evidence/Suggestion available for clarification) regardless of whether Step 5 rendered compact or verbose
- [ ] Manual walkthrough (`review-plan`, Codex mirror): repeat both walkthroughs above against the Codex-authored `SKILL.md`, confirming the `**Dispatch**:` line is unaffected and the no-JSON closing line reads correctly in the Codex mirror's voice
- [ ] Confirm the footer/closing-line appears in **every** report variant exercised above, for both skills (deep-review: full run, `--verbose`, continuation; review-plan: full run, `--verbose`) — not just the default full-run template
- [ ] Non-duplication / consistency check, both skills: confirm each skill's `rubric.md` reworded Finding Quality bullet and its SKILL.md Step 5 prose describe the same rendering rule (no contradiction) — manual reviewer check
- [ ] If Open Question 1 resolves to (b): `tests/reconciliation/run-fixtures.sh` and `tests/reconciliation/test-renderer.sh` pass with the new compact-Minor fixtures for both skills

### Test Results
- [ ] All existing tests pass
- [ ] Manual verification complete

### Edge Cases Tested
- [ ] Zero Minor findings (only Critical/Important), both skills — confirm no empty `### Minor` header is emitted (existing "omit header if empty" behavior, unchanged by this plan)
- [ ] Only Minor findings (no Critical/Important), both skills — confirm the report still renders coherently with just the compact list plus the footer/closing-line
- [ ] `deep-review --verbose` combined with `--continue` and with `--pr <N>` — confirm the flag composes without altering scope resolution
- [ ] `review-plan --verbose` combined with `--auto-fix=trivial` and with `--batch` — confirm the flag composes without altering lens dispatch, the Step 6.4 loop's applicability (`--batch` still skips 6.4; `--verbose` never does), or the Step 7 marker write
- [ ] A Minor finding that also appears in the `related` cross-reference block, both skills — confirm the compact one-line format does not silently drop the "Related findings" cross-reference signal entirely; decide (as part of Phases 1 and 5) whether the compact line keeps a terse related-finding note or omits it by design, and document whichever choice is made, consistently across both skills

## Acceptance Criteria

- Default `/deep-review` output renders Critical/Important findings in full and Minor findings as a single compact line each (no Evidence/Suggestion prose inline).
- Default `/review-plan` output renders Critical/Important findings in full and Minor findings as a single compact line each, identically to `/deep-review`'s rule.
- `--verbose` restores full Evidence/Suggestion detail for every severity, on both mirrors of both skills.
- Every `/deep-review` report — compact or verbose, full-run or continuation — ends with the per-harness JSON state file path.
- Every `/review-plan` report — compact or verbose — ends with the no-JSON closing line (review-plan persists no per-run findings JSON; this is a confirmed, documented asymmetry, not a gap).
- Both skills' `rubric.md` Finding Quality sections are reconciled: each states the underlying data always has five fields, and that the default rendering is severity-conditional.
- All eight target files (`plugins/skein/skills/{deep-review,review-plan}/{SKILL.md,rubric.md}`, `plugins/skein-codex/skills/{deep-review,review-plan}/{SKILL.md,rubric.md}`) are updated symmetrically within each skill; each skill's `rubric.md` is byte-identical between its own two mirrors (checked independently per skill).
- Both Codex mirror `SKILL.md` files are authored via `codex:rescue` and independently reviewed by a second, fresh-thread `codex:rescue` call before merge.
- Open Question 1 (`render-reconciled-report.sh` scope, shared by both skills) is explicitly resolved (by the user or by this plan's stated default) and the resolution is recorded in Findings before implementation is marked complete. The former rubric-ownership open question is already settled (see Findings/Architecture Decisions) and does not need re-resolution.
- `scripts/check-prompt-parity.sh` passes.
- Both plugin manifests bumped in lockstep to `0.5.1` (one bump covering both skills); `CHANGELOG.md` updated with one entry covering both skills.
- `docs/dev_plans/README.md`'s Planned table entry for this plan reflects the dual-skill scope.
- Code reviewed and approved.
- Tests passing (parity script + existing reconciliation/parity/plugin regression suites, plus any new fixtures from Open Question 1(b)).
- Documentation updated.

<!-- /review-plan writes the marker line above. Everything below is the workspace: edits here do NOT invalidate the marker. -->

## Progress

- [ ] Phase 1: `deep-review` Claude mirror SKILL.md report template + flag
- [ ] Phase 2: `deep-review` Claude mirror rubric.md reconciliation
- [ ] Phase 3: `deep-review` Codex mirror SKILL.md via codex:rescue + independent review
- [ ] Phase 4: `deep-review` rubric.md parity
- [ ] Phase 5: `review-plan` Claude mirror SKILL.md report template + flag
- [ ] Phase 6: `review-plan` Claude mirror rubric.md reconciliation
- [ ] Phase 7: `review-plan` Codex mirror SKILL.md via codex:rescue + independent review
- [ ] Phase 8: `review-plan` rubric.md parity + shared test-coverage decision + version/changelog

## Findings

- **2026-07-12**: Scope expanded from `/deep-review`-only to also cover `/review-plan`, per user decision. Confirmed via full reads of both skills' `SKILL.md`/`rubric.md` (both mirrors) and `scripts/check-prompt-parity.sh` that: (1) `review-plan`'s Step 5 template has the identical verbosity problem; (2) `review-plan` has no `.review-plan/latest-*.json` persistence analogous to deep-review's `.deep-review/latest-*.json` — its only per-run artefacts are the in-plan review marker and transient `--auto-fix=trivial` manifests — so `review-plan`'s report footer cannot name a JSON state-file path and uses a different closing line instead; (3) `check-prompt-parity.sh`'s rubric-diff loop is per-skill, not cross-skill, so `deep-review/rubric.md` and `review-plan/rubric.md` never need to match each other; (4) the GENERIC FINDING SCHEMA AND MERGE block's byte-parity check already spans all 4 targets (both skills × both mirrors) and needs no new work, since both skills' Step 5 templates live entirely outside that block in all four files.
- **rubric.md ownership (formerly Open Question 1)**: settled as "repo-level data file, Claude edits both mirrors directly on both skills" — applied uniformly to `deep-review/rubric.md` and `review-plan/rubric.md`. Recorded in Architecture Decisions above; not carried forward as an open question.

## Issues & Solutions

(none yet)

## Final Results

(pending)
