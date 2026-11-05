# Task: Refresh AI-writing-signs guidance in the content skills

**Status**: In Progress
**Component**: content-skills
**Assigned to**: Claude (Claude mirror, shared files, tests); Codex (Codex mirror, via `codex:rescue`)
**Priority**: Medium
**Branch**: feature/ai-writing-signs-refresh
**Created**: 2026-11-04
**Review Gates**: none

## Objective

Replace the dated, triplicated "anti-LLM" rules in `content-draft` and `content-review` with one shared, dated reference derived from Wikipedia's [Signs of AI writing](https://en.wikipedia.org/wiki/Wikipedia:Signs_of_AI_writing), and point the other skills that emit human-read prose (`update-docs`, `release`) at it.

## Context

- The anti-LLM rules exist as three hand-copied lists (`content-draft/SKILL.md`, `content-review/SKILL.md`, `content-review/references/content-guidelines.md`), across three mirrors (Claude, Codex, Pi). They drift independently.
- The banned-word list is 2023-era ("delve", "seamless", "leverage", "ever-evolving"). The Wikipedia page dates tells in buckets: 2023 to mid-2024 ("delve", "tapestry", "testament"); mid-2024 to mid-2025 ("align with", "enhance", "fostering", "showcasing"); mid-2025 to mid-2026 ("emphasizing", "highlighting"); mid-2026 onward ("challenge", "leverage", "multifaceted", "prioritize", "universally").
- Em dashes are handled inconsistently: `content-guidelines.md:21` and `writing-style-rules.md:18` recommend an em dash as a comma-splice fix, while `content-guidelines.md:48` says not to overuse them. The page says the em-dash tell is fading (newer models suppress it; uniform commas and periods are becoming the signal).
- Whole categories are missing today: significance inflation, trailing "-ing" analyses, copulative avoidance ("serves as", "boasts"), vague attribution and "associated with", the "Challenges / Future outlook" formula, hedging disclaimers and mid-2026 corrective framings, and style tells (emoji, inline-bold-header lists, Title Case headings, curly quotes, stray markdown).
- Mechanism per the page: LLM text regresses to the statistically generic, replacing specific facts with positive filler. A fix must restore the specific fact or delete the sentence; swapping synonyms only makes the text harder to detect.
- The page is Wikipedia-specific and descriptive, not prescriptive. It also warns that detectors and human judgment are unreliable, and lists poor indicators (perfect grammar, "bland" prose, transition words alone). Wikipedia-only sections (citations, edit summaries, wikitext, AfC) are out of scope.

## Requirements

- One shared reference, `ai-writing-signs.md`, in `content-review/references/`. Byte-identical in the Claude, Codex, and Pi `content-review` mirrors, and in Pi `content-draft/references/` (Pi's extension loads references from its own package; see Observed patterns).
- Reference sections: content tells, language tells, style tells, assistant residue, dated vocabulary, false-positive caveats.
- Fix principle stated once, in the reference: restore the specific fact or delete the sentence; never swap synonyms. When the specific fact is unknown to the reviewer, the finding says "needs author input" and does not invent one.
- Signs are signals, not bans. One hit is weak; density across distinct sign types is the finding.
- Output is style feedback, not an AI-detection verdict. The skills never claim a piece "is AI-written".
- Em dashes: stop treating them as a tell on their own. Flag only spaced or comma-substitute use. Remove "or em dash" as a comma-splice fix in `content-guidelines.md:21` and `writing-style-rules.md:18`; resolve the contradiction with `content-guidelines.md:48`.
- `content-review` gains an "AI-writing signs" finding category with fixed severities: **Critical** = assistant residue (placeholders, "I hope this helps", "as of my last update", leaked markdown); **Important** = 3 or more distinct sign types in one paragraph, or a repeated structural formula; **Suggestion** = a single hit. Every finding carries a concrete rewrite or "needs author input".
- `content-draft` gets a short "write it right" block in the drafting-subagent prompt (use "is/has", name the specific thing, no trailing "-ing" analysis, no conclusion formula) and a Phase 4 pass driven by the reference.
- `update-docs` and `release` get a one-line rule plus a pointer to the reference. No new review step, no PR-description review.
- Keep the `### Anti-LLM Authenticity Rules` heading in `content-guidelines.md`; `tests/pi/test_extension.py:195` pins it.
- Codex-mirror edits go through `codex:rescue`, Codex half first, then the Claude half aligned, one commit per mirror pair.
- Out of scope: a deterministic scanner script (`scripts/ai-signs-scan.sh` with a JSON lexicon). Defer to a later plan; record in `docs/BACKLOG.md`.

## Review Focus

- Mirror parity: `scripts/check-prompt-parity.sh:742-757` runs `diff -r` on the Claude and Codex `content-review/references/` directories, so a file added to one side alone fails. Pi is checked by an explicit filename list in `tests/pi/test_single_worker_skills.py:96-104`, so a new Pi file is not covered unless that list is extended.
- Em-dash edits touch lines mirrored across three trees; a partial edit leaves an inconsistent rule. Verify the invariant (no mirror still recommends an em dash as a comma-splice fix) with a grep across all mirrors, not by reading one.
- The reference must not over-flag. A reviewer that flags every "additionally" or every em dash is worse than none. Check the severity rules against the page's "ineffective indicators".
- `release/SKILL.md` carries workflow-parity and contract pins (`check-prompt-parity.sh:261-290`, `tests/parity/test_release_skill_contract.py`). The pointer line must land outside pinned regions.

## Implementation Checklist

### Phase 1: Shared reference file

**Impl files:** `plugins/skein-codex/skills/content-review/references/ai-writing-signs.md, plugins/skein/skills/content-review/references/ai-writing-signs.md, plugins/skein-pi/skills/content-review/references/ai-writing-signs.md, plugins/skein-pi/skills/content-draft/references/ai-writing-signs.md`
**Test files:** `tests/pi/test_single_worker_skills.py`
**Test command:** `uv run --with pytest python -m pytest tests/pi/test_single_worker_skills.py -q && ./scripts/check-prompt-parity.sh`
**Goal:** The reference is the single source of the sign taxonomy and the fix principle; every mirror copy is byte-identical to the Codex canonical.

- Author the Codex copy first via `codex:rescue`, then copy byte-for-byte to the other three locations.
- Content: the six sections in Requirements; each sign has a short pattern name, 2 to 4 example phrases, and a "usually fixed by" line (restore the fact / delete / use "is" or "has").
- Dated-vocabulary section lists the four era buckets as approximate, not hard cutoffs, with a "last reviewed" date so refreshes are visible.
- Caveats section: signs are descriptive; detectors and human judgment are unreliable; do not flag perfect grammar, blandness, or transition words alone; a word can be literal ("underscore" in its plain sense).
- Extend the explicit filename list at `tests/pi/test_single_worker_skills.py:100-103` to include `ai-writing-signs.md` (content-review and content-draft Pi copies).

### Phase 2: Rewrite the Anti-LLM rules and fix the em-dash contradiction

**Impl files:** `plugins/skein-codex/skills/content-review/references/content-guidelines.md, plugins/skein/skills/content-review/references/content-guidelines.md, plugins/skein-pi/skills/content-review/references/content-guidelines.md, plugins/skein-pi/skills/content-draft/references/content-guidelines.md, plugins/skein-codex/skills/content-review/references/writing-style-rules.md, plugins/skein/skills/content-review/references/writing-style-rules.md, plugins/skein-pi/skills/content-review/references/writing-style-rules.md`
**Test files:** `tests/parity/test-ai-writing-signs-contract.sh, tests/pi/test_extension.py`
**Test command:** `bash tests/parity/test-ai-writing-signs-contract.sh && uv run --with pytest python -m pytest tests/pi -q`
**Goal:** No mirror recommends an em dash as a comma-splice fix, and the Anti-LLM section points at the reference instead of carrying its own word list.

- In `content-guidelines.md`, keep the `### Anti-LLM Authenticity Rules` heading. Keep the structural rules (concrete-first opener, evidence density, decision with trade-off, failure and adjustment, original stance, no abstraction-only paragraphs, no assistant residue). Replace the template-phrase ban (`:45`), the contrast-pattern and variation bullets, and the formatting-tics bullet (`:48`) with a short pointer to `ai-writing-signs.md` and the signals-not-bans rule.
- Update the checklist items at `:156/:186` (comma splices) and `:176/:198` (AI-signalling phrases) to match.
- Drop "or em dash" from `content-guidelines.md:21` and `writing-style-rules.md:18`; the alternatives become full stop, semicolon, or conjunction.
- Add `tests/parity/test-ai-writing-signs-contract.sh`: asserts byte-identity of `ai-writing-signs.md` across the four locations, asserts the Anti-LLM heading and the pointer exist in every `content-guidelines.md` copy, and asserts no mirror's comma-splice line still offers an em dash. Register it in the `parity-tests` recipe in `justfile`.

### Phase 3: `content-review` finding category

**Impl files:** `plugins/skein-codex/skills/content-review/SKILL.md, plugins/skein/skills/content-review/SKILL.md, plugins/skein-pi/skills/content-review/SKILL.md`
**Test files:** `tests/parity/test-ai-writing-signs-contract.sh`
**Test command:** `bash tests/parity/test-ai-writing-signs-contract.sh && ./scripts/check-prompt-parity.sh`
**Goal:** A reviewer applies the same three severities and the "restore the fact or needs author input" rule on all harnesses, and never presents the result as AI detection.

- Replace the two AI-signalling checklist lines (Claude `:110`, `:112`; Codex `:111`, `:113`) with a single "AI-writing signs" item that reads `references/ai-writing-signs.md`.
- Add the severity mapping next to the existing severity definitions (Claude `:153`, Codex `:154`): Critical = residue, Important = 3 or more distinct sign types in a paragraph or a repeated formula, Suggestion = single hit.
- Add the framing line: style feedback, not a detection verdict.
- Check Pi `SKILL.md` for the equivalent checklist and update it; Pi `:46` only mentions comma splices, so confirm where its AI-signs guidance lives before editing.
- Extend the contract test to assert the severity tokens and "needs author input" appear in all three `SKILL.md` files.

### Phase 4: `content-draft` drafting and Phase 4 pass

**Impl files:** `plugins/skein-codex/skills/content-draft/SKILL.md, plugins/skein/skills/content-draft/SKILL.md, plugins/skein-pi/skills/content-draft/SKILL.md`
**Test files:** `tests/parity/test-ai-writing-signs-contract.sh, tests/parity/test-spawn-tiers.sh, tests/pi/test_extension.py`
**Test command:** `bash tests/parity/test-ai-writing-signs-contract.sh && bash tests/parity/test-spawn-tiers.sh && uv run --with pytest python -m pytest tests/pi -q`
**Goal:** The drafting subagent writes plainly by construction, and the Phase 4 pass checks against the shared reference rather than a private list.

- In the subagent prompt, add a "write it right" block: prefer "is/has" over "serves as/boasts"; name the specific thing; no trailing "-ing" analysis; no "Challenges and outlook" closing formula; no hedging disclaimers; straight quotes and sentence-case headings unless the target site differs.
- Replace the "Anti-LLM Authenticity Constraints" template-phrase ban (Claude `:134`, Codex `:138`) with a pointer to the reference; keep the structural constraints.
- Rewrite Phase 4 (Claude `:138`, Codex `:142`) as a checklist driven by the reference: scan for residue first, then density per paragraph, then repair by restoring the fact or deleting. Where a fact is missing, leave a visible `[needs author input: ...]`-style note for the author instead of inventing one.
- Update the reference pointer at the end (Claude `:178`, Codex `:182`) to name `ai-writing-signs.md`.
- Pi: the extension loads `references/` from its own package; confirm `ai-writing-signs.md` is picked up and, if the loader enumerates files, register it. Leave `test_spawn_tiers.sh` pins (`:234-237`, `:776-829`) untouched; they pin delegation strings, not this text.

### Phase 5: Pointers in `update-docs` and `release`

**Impl files:** `plugins/skein-codex/skills/update-docs/SKILL.md, plugins/skein/skills/update-docs/SKILL.md, plugins/skein-pi/skills/update-docs/SKILL.md, plugins/skein-codex/skills/release/SKILL.md, plugins/skein/skills/release/SKILL.md, plugins/skein-pi/skills/release/SKILL.md`
**Test files:** `tests/parity/test-ai-writing-signs-contract.sh`
**Test command:** `bash tests/parity/test-ai-writing-signs-contract.sh && ./scripts/check-prompt-parity.sh && uv run --with pytest python -m pytest tests/parity/test_release_skill_contract.py -q`
**Goal:** Skills that write human-read prose (changelog entries, README and PR text, release notes) apply the same plain-writing rule without gaining a new review step.

- Add one line to `update-docs` where changelog, README, and PR-description text is written, and one line to `release` where release notes or the GitHub release body are written: "Write plainly; avoid the sign patterns in `content-review/references/ai-writing-signs.md`." Exact wording identical across mirrors except path-anchor idiom.
- Locate each insertion point outside regions pinned by `check-prompt-parity.sh:261-290` and `test_release_skill_contract.py`. If no unpinned region fits, stop and surface it rather than editing a pinned one.
- `dev-plan`, `AGENTS.md`, and review reports are agent-read and unchanged.

### Phase 6: Docs, changelog, and end-to-end verification

**Impl files:** `AGENTS.md, CHANGELOG.md, docs/BACKLOG.md, docs/dev_plans/README.md, plugins/skein/.claude-plugin/plugin.json, plugins/skein-codex/.codex-plugin/plugin.json`
**Test files:** `tests/parity/test-ai-writing-signs-contract.sh`
**Test command:** `just ci`
**Validation cmd:** `uv run --with pytest python -m pytest tests/pi -q`
**Goal:** Everything shipped is documented, the deferred scanner is recorded, and a real review run behaves as specified.

- `AGENTS.md:119`: add `ai-writing-signs.md` to the content-guidelines authority note (Codex canonical, other mirrors byte-copies).
- `CHANGELOG.md` under `[Unreleased]`: `### Changed` entry for the refreshed guidance; mention the new reference and the em-dash rule change.
- `docs/BACKLOG.md`: add the deferred scanner (`scripts/ai-signs-scan.sh` plus JSON lexicon) with the reason it was deferred.
- Manual check: run `content-review` on two fixtures (one LLM-styled, one plain human draft). Expected: the first yields Important or Critical findings with concrete rewrites or "needs author input"; the second yields at most Suggestions. Record the result in Testing Notes.
- Run `tests/pi` explicitly: it is not wired into `just ci` (see Technical Specifications).

## Technical Specifications

### Files to Modify

- `plugins/skein-codex/skills/content-review/references/content-guidelines.md` (`:21` em-dash splice fix; `:35` Anti-LLM heading kept; `:45` phrase ban; `:48` formatting tics; checklists `:156/:176/:186/:198`). Repo-canonical per `AGENTS.md:119`. Byte-identical copies in `plugins/skein/skills/content-review/references/`, `plugins/skein-pi/skills/content-review/references/`, and `plugins/skein-pi/skills/content-draft/references/`.
- `writing-style-rules.md` (`:18` "full stop, semicolon, em dash, or conjunction") in the three `content-review/references/` dirs.
- `content-review/SKILL.md` in three mirrors (checklist lines Claude `:110/:112`, Codex `:111/:113`; severity definitions Claude `:153`, Codex `:154`).
- `content-draft/SKILL.md` in three mirrors (Claude `:119/:127/:134/:138/:178`; Codex `:123/:131/:138/:142/:182`).
- `update-docs/SKILL.md` and `release/SKILL.md` in three mirrors (one line each).
- `tests/pi/test_single_worker_skills.py:100-103` (extend filename list); `justfile` (register new parity test in `parity-tests`).
- `AGENTS.md`, `CHANGELOG.md`, `docs/BACKLOG.md`, `docs/dev_plans/README.md`.
- Added during review (not in the original plan): `plugins/skein-pi/extension.ts` (reference appended to both prompts; review input cap 100000 to 90000), `scripts/check-prompt-parity.sh` and `tests/parity/test-prompt-parity-extended.sh` (anchored `release` reference path), `tests/pi/test_extension.py`, `tests/pi/test_single_worker_skills.py`, `tests/pi/test_package.py`, `tests/pi/test_private_profile.py`, and both plugin manifests (0.11.0).

### New Files to Create

- `plugins/*/skills/content-review/references/ai-writing-signs.md` (3 mirrors) and `plugins/skein-pi/skills/content-draft/references/ai-writing-signs.md`: the shared taxonomy.
- `tests/parity/test-ai-writing-signs-contract.sh`: byte-identity, heading, pointer, severity-token, and em-dash invariants across mirrors.

### Architecture Decisions

- One reference plus pointers, not a fourth copied list. Rationale: the current triplication is why the rules went stale unevenly.
- The reference lives under `content-review/references/`. Claude and Codex `content-draft` already cite `content-review/references/content-guidelines.md` by that path (`content-draft/SKILL.md:178` and Codex `:182`), so there is precedent. Pi cannot, so it gets its own byte-copy.
- Signals, not bans, with density-based severity. Rationale: the source page states individual signs are weak, human writing is converging on LLM style, and detectors are unreliable; per-word bans produce false positives.
- Em dash demoted from a tell to a spaced or comma-substitute-use check. Rationale: tell is fading as models suppress it; the repo's own guidance recommending it was contradictory.
- Scanner deferred. Rationale: it adds a second surface (lexicon plus script) to keep in parity; the taxonomy should settle first.

### Dependencies

- None new. Tests use `uv run --with pytest` and bash, as existing recipes do. `ruff.toml`: py312, line-length 88; ruff 0.16.6 pinned.

### Integration Seams

| Seam | Writer (task) | Caller (task) | Contract |
|------|---------------|---------------|----------|
| Reference file path | Phase 1 | Phases 2 to 5 | Path `references/ai-writing-signs.md` is the same string in every pointer; Pi uses its package-local copy |
| Severity mapping | Phase 3 | Phase 4 (self-check pass) | Draft's self-check uses the same Critical/Important/Suggestion meaning as the reviewer |
| Contract test | Phase 2 | Phases 3 to 6 | Each later phase extends the same test; it must stay green at every phase boundary |

## Testing Notes

### Test Approach

- [x] Byte-identity of `ai-writing-signs.md` across four locations (new contract test)
- [x] Grep-level invariants: Anti-LLM heading kept, pointer present, no mirror offers an em dash as a comma-splice fix, severity tokens and "needs author input" present in all `content-review` mirrors
- [x] Existing parity (`./scripts/check-prompt-parity.sh`, `tests/parity/*`) and Pi pytest (`tests/pi`) pass
- [~] Manual: reference applied to one LLM-styled and one plain fixture by a clean-context reviewer (done); full `content-review` skill run and `content-draft` Phase 4 run not exercised end to end

### Test Results

- [x] `just ci` passes (exit 0)
- [x] `uv run --with pytest python -m pytest tests/pi -q` passes, 168 (not covered by `just ci`)
- [~] Fixture result: LLM-styled fixture yielded Critical (residue) plus Important cluster with `needs author input` fixes. The plain fixture initially yielded a false-positive Suggestion for sentence-initial "Additionally"; the 2026-11-04 review correction now exempts transition words in isolation, with the focused contract test pinning that rule. An end-to-end fixture rerun remains outstanding.

### Edge Cases Tested

- [~] A literal use of a flagged word ("underscore" as a verb meaning "draw a line under") is not flagged
- [x] Plain human draft with perfect grammar and transition words yields no Important or Critical findings (fixture B)
- [x] Missing fact yields "needs author input", not an invented fact (fixture A)

## Acceptance Criteria

- `ai-writing-signs.md` exists in four locations, byte-identical, covering the six sections.
- No mirror's `content-guidelines.md` or `writing-style-rules.md` recommends an em dash as a comma-splice fix; verified by grep across all mirrors, enforced by the contract test.
- `content-review` reports AI-writing signs with the specified severities, concrete rewrites or "needs author input", and the style-feedback framing, in all three mirrors.
- `content-draft` prompt contains the "write it right" block and a reference-driven Phase 4 in Claude and Codex; Pi loads the reference.
- `update-docs` and `release` each carry the one-line pointer in all three mirrors, outside pinned regions.
- `just ci` green; `tests/pi` green.
- `AGENTS.md`, `CHANGELOG.md`, `docs/BACKLOG.md`, and the plan index are updated.
- Code reviewed and approved.

<!-- reviewed: YYYY-MM-DD @ <hash> -->
<!-- /review-plan writes the marker line above. Everything below is the workspace: edits here do NOT invalidate the marker. -->

## Progress

- [x] Phase 1: Shared reference file
- [x] Phase 2: Rewrite the Anti-LLM rules and fix the em-dash contradiction
- [x] Phase 3: `content-review` finding category
- [x] Phase 4: `content-draft` drafting and Phase 4 pass
- [x] Phase 5: Pointers in `update-docs` and `release`
- [x] Phase 6: Docs, changelog, and end-to-end verification

## Findings

- Explore (2026-11-04): `tests/pi/*` is not referenced by any `justfile` recipe or `.github/workflows/ci.yml`, so `just ci` does not run it; Phase 6 runs it explicitly. Worth a separate fix.
- Explore: `update-docs` and `release` `SKILL.md` contain no existing anti-LLM text; the release em dashes found are title-format literals.
- Explore: `CODEX_MIRROR_BACKLOG.md` has no content-guidelines entries.
- Discovered during Phase 3: Pi workers have no tools and receive rules as inline prompt text from `plugins/skein-pi/extension.ts`, which loaded only `content-guidelines.md` / `writing-style-rules.md`. The "read `ai-writing-signs.md`" pointer would have been dead there. Fixed by appending the reference to both the draft and review prompts (not in the original plan; covered by the contract test).
- Phase 4: `content-draft` headings "Phase 4: De-LLM Authenticity Pass" and "Phases 3–4: Draft Content and De-LLM Pass" renamed to "Authenticity Pass" in both mirrors (the Codex "Phases 3–4" heading was missed at first and fixed by the 2026-11-05 review); Codex checked `tests/` and `scripts/` for a pin on the old heading and found none.
- Phase 5: `update-docs` pointer lands as item 1 of "Apply Updates" in both mirrors (read before any edit; originally appended as item 9 / item 10, moved by the 2026-11-05 review); `release` pointer is one sentence appended to the Step 4 "`## What's New` inclusion" bullet, both mirrors. Pi `update-docs` is an audit-only worker and got no pointer; Pi `release` got a plain-writing clause without a path.
- Review correction (2026-11-04): delegated `content-draft` and `content-review` now load references through the harness anchor in the main context and inline the exact rule text into worker prompts. The other new `update-docs` and `release` cross-skill pointers are harness-anchored too. Sentence-initial transition words are supporting evidence only and cannot produce a standalone finding.
- Code review 2026-11-05: user-run `/code-review xhigh --fix` on the Claude skills returned 13 findings. Fixed: Pi input cap vs the larger prompt; bare cross-skill paths in delegated prompts; marker vs placeholder rule in `content-draft`; `Fixed:` line for AI-sign findings; `update-docs` ordering; stale heading; residue exemption; required-close exemption; severity gaps and hedge wording; vocabulary weighting and spelling; Wikipedia attribution; contract-test `pipefail` weakness. Not changed: the fix principle is restated in about 7 places (low severity).
- Pi review (clean-context subagent): no blocking findings. Fixed the tool-less "read in this directory" wording (Codex canonical first, then three byte copies), added tests that both prompts embed the reference and that the worst-case ASCII review prompt fits 128 KiB, and documented the character and byte limits. Non-ASCII text can still exceed the byte cap and fails closed with `task_too_large`.
- Pi real-pi tests (7 failures, also on `main`): the tests passed the managed-install shell launcher to `node`. `resolve_pi_cli()` in `tests/pi/test_package.py` now resolves `install/releases/<version>/node_modules/.bin/pi`. Production (`extension.ts`) already passes `realpathSync(process.argv[1])`.
- Licence (2026-11-05): a source comparison found no run of 6 or more shared words but a shared taxonomy, order and era word lists ("partly derivative"). Decision: keep the attribution and CC BY-SA 4.0 note on the source and leave the repo MIT; no relicensing or rewrite.
- Version: bumped both plugin manifests to 0.11.0 and promoted `[Unreleased]` in this PR, per AGENTS.md "Cutting a release". Tag and GitHub release go through `skein:release 0.11.0` after merge.
- Not run: `/review-plan` (marker stays the template placeholder; plan has `Review Gates: none`), `review-gauntlet`, a full `content-review` / `content-draft` end-to-end run, and a live Pi worker run. A confirming user-run `/code-review xhigh` is pending.

## Issues & Solutions

## Final Results

### Summary

The three skill mirrors share one AI-writing-signs reference (four byte-identical copies, Codex canonical) instead of three drifting phrase-ban lists. `content-review` reports signs with density-based severities and `needs author input` fixes; `content-draft` runs a reference-driven Phase 4; Pi workers get the reference appended to their prompts.

### Outcomes

`just ci` exit 0; `tests/pi` 168 passed; contract test 65 checks; `check-prompt-parity.sh` passes.

### Learnings

### Follow-up Work

- Deterministic scanner (`scripts/ai-signs-scan.sh` plus JSON lexicon), deferred.
- Wire `tests/pi` into `just ci`.
