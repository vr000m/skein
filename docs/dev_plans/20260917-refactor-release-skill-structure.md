# Task: skein:release — progressive disclosure, script extraction, audit split, test anchor fragility

**Status**: Draft
**Component**: meta
**Assigned to**: Claude
**Priority**: Medium
**Branch**: TBD
**Created**: 2026-09-17
**Review Gates**: full

## Objective

Reduce `plugins/skein/skills/release/SKILL.md` (244K, 454 lines, ~35% of the plugin's skill-corpus context budget) from a monolithic always-loaded prose spec into a structure that matches every other complex skein skill (`deep-review`, `review-plan`, `review-gauntlet`, all of which ship a `scripts/` directory and keep `SKILL.md` as the orchestration layer, not the mechanism). This is a structural refactor, not a behavior change: the untemplated `/release` cut (the common case, including every skein release to date) must not regress, and every templated-branch behavior currently documented in prose must be preserved exactly, just relocated.

## Context

`/code-review xhigh --fix` against `feature/release-repo-template` (2026-09-17, findings recorded in `docs/dev_plans/20260914-feature-release-repo-template.md`) surfaced 15 findings, nearly all of them spec self-contradictions or coverage gaps *within* the template subsystem added by that plan. Reviewing the pattern across findings (#2, #5, #6, #9, #11, #14 in particular) shows the underlying cause isn't isolated prose bugs — it's that deterministic validation logic (template read, jq gate sequence, marker resolution, commit-precondition checks) is re-specified in English at roughly 5 call sites across 2 mirrors (~10 near-duplicate copies), with no single source of truth an editor or reviewer can check for consistency. Every other complex skein skill avoids this by extracting the deterministic parts into `scripts/`, leaving `SKILL.md` to orchestrate.

Three further structural issues surfaced in follow-up review (2026-09-17, this session):

1. **No progressive disclosure.** The template subsystem (schema, jq gates, Audit Mode's dual-anchor scheme, A2.5 inference) is only relevant on the templated branch, yet lives inline in `SKILL.md` and is loaded on every invocation — including the untemplated case, which is the norm today (skein's own repo carries no template).
2. **A2.5 circularly coupled to A2.** Audit Mode's template-inference step (A2.5) proposes a template from release history but must reason about which candidates A2 could/couldn't classify to avoid proposing a canonical template against a repo that deliberately removed one — coupling a read-only classifier to a generative inference step inside the same mode.
3. **Parity tests anchor on prose headings.** `tests/parity/test_release_skill_contract.py`'s region helpers locate sections via `text.index("### Step 1: ...")`-style literal heading lookups; an editorial heading rename raises `ValueError` instead of a meaningful test failure, making the test suite fragile to exactly the kind of copy-editing this refactor will do.

This plan is scoped to structure only. It does not attempt to resolve the 14 unfixed content findings from the xhigh review (marker match-count precedence, Step 6 recompose ordering, jq-pin authorization for new call sites, CRLF/Unicode gate gaps, etc.) — those are logic bugs in the current prose and are out of scope here, though several should get materially easier to fix once the duplicated prose collapses into a single script. See "Related Work" below for the explicit link back to those findings.

## Related Work

- `docs/dev_plans/20260914-feature-release-repo-template.md` — the plan that introduced the template subsystem this refactor restructures. Its `/code-review xhigh --fix` run (2026-09-17) findings #1–#12, #14–#15 (finding #13 already fixed) are the concrete symptom list motivating this plan; see its Findings/changelog section for the full list. This plan does not re-litigate those findings' resolutions — it changes where the logic they point at lives, and Phase 2/3 below should close several of them as a side effect (tracked per-phase, not claimed as a batch fix).
- `AGENTS.md` "Mirrors" section — governs the Codex-mirror-first edit order this plan must follow throughout.

## Requirements

- `/release <version>` and `/release audit` behavior is byte-for-byte unchanged for every untemplated repo (including skein's own repo) before and after this refactor — this is a structural move, not a behavior change, and must be provable via the existing `tests/parity/test_release_skill_contract.py` suite passing unmodified in its assertions (only its anchoring mechanism changes, per Phase 4).
- Deterministic template-read/validate/jq-gate logic currently re-specified in prose at the ~5 call sites identified in the xhigh review is extracted into `plugins/skein/skills/release/scripts/read-release-template.sh` (plus whatever sibling scripts the jq-gate sequence and marker-resolution logic need), following the shape of `plugins/skein/skills/deep-review/scripts/` (a `lib/` for shared helpers, single-purpose top-level scripts, `SKILL.md` reduced to "call script X, interpret its output").
- Codex mirror (`plugins/skein-codex/skills/release/scripts/`) gets an equivalent script set, edited via `codex:rescue` per `AGENTS.md`'s mirror convention (Codex half first, Claude half aligned in the same commit).
- The template subsystem (schema definition, jq validation gate sequence, Audit Mode's dual-anchor marker resolution, A2.5 inference) is split out of the always-loaded body of `SKILL.md` into a `references/` file loaded only on the templated branch (repo has `.release-template.json`, or Audit Mode reaches a marker-bearing release) — following the harness's progressive-disclosure convention already used elsewhere in the codebase (name the concrete precedent found during Phase 1 exploration). An untemplated `/release` cut must not pay context cost for this file at all.
- Audit Mode's A2.5 template-inference is split from A2's read-only drift classification into its own subcommand/step so A2 never depends on A2.5's proposal state, closing the circular-coupling risk (A2.5 proposing a canonical template against a repo that deliberately removed one). A2 remains a pure read-only classifier.
- `tests/parity/test_release_skill_contract.py`'s region-boundary helpers are re-anchored on stable, machine-readable markers (e.g. `<!-- skein:step N -->`-style HTML comments, invisible in rendered prose) instead of literal `### Step N: <title>` heading text, so an editorial heading rename produces a clear test failure (or no failure) instead of an opaque `ValueError` from a failed `.index()` lookup. Both mirrors carry the same markers.
- Both mirrors change together per commit per `AGENTS.md`; `scripts/check-prompt-parity.sh` must keep passing throughout, including against the new `references/` and `scripts/` files if that check's scope covers them (confirm during Phase 1 exploration — extend the check if it currently only looks at `SKILL.md`).
- `just ci` green at the end of every phase, per this repo's Gauntlet fixer discipline.

## Review Focus

- **No behavior drift**: the refactor must not change what a templated or untemplated `/release` run does, only where the logic lives and how much of it loads per invocation. Diff the composed confirmation output (Step 4) and audit classification output before/after on a representative templated + untemplated fixture repo, not just "tests pass."
- **Progressive disclosure boundary correctness**: verify the untemplated path genuinely never reads the `references/` file — a lazy "load it anyway at the top of SKILL.md" defeats the point. Check via the harness's actual load mechanism, not just structural intent.
- **Mirror parity**: `scripts/check-prompt-parity.sh` and `test_release_skill_contract.py` both continue to assert what they assert today; confirm the new test-anchor mechanism (Phase 4) doesn't silently narrow what's covered while making the suite passing look identical.
- **A2/A2.5 split correctness**: after the split, confirm A2's classification for a marker-absent, no-current-template repo doesn't change (this is exactly finding #9/#11's territory from the xhigh review — verify the split doesn't paper over them or make them harder to find).

## Implementation Checklist

### Phase 1: Explore precedent and inventory the ~10 duplicate-logic call sites

**Impl files:** none (exploration only)
**Test files:** none
**Test command:** n/a
**Validation cmd:** n/a
**Goal:** a concrete, line-numbered inventory of every call site re-specifying template-read/jq-gate/marker-resolution logic in both mirrors, plus the confirmed harness mechanism for lazy-loaded `references/` files (cite the existing skein skill or Claude Code doc that establishes the pattern — do not assume one exists without checking).

- Grep both mirrors for every prose reference to the jq gate sequence, template schema validation, and marker (`release-template-sha`) resolution; tabulate call site, line range, and which of the xhigh findings (if any) it corresponds to.
- Confirm how (or whether) an existing skein skill already does conditional/lazy file loading from `SKILL.md`, to establish the `references/` pattern this plan should follow rather than inventing one.
- Confirm `scripts/check-prompt-parity.sh`'s current scope (does it already walk non-`SKILL.md` files under a skill directory, or does it need extending in Phase 2/3).

### Phase 2: Extract scripts/ (deterministic logic)

**Impl files:** `plugins/skein/skills/release/scripts/read-release-template.sh` (+ siblings as Phase 1 inventory dictates), `plugins/skein-codex/skills/release/scripts/` equivalents, `plugins/skein/skills/release/SKILL.md`, `plugins/skein-codex/skills/release/SKILL.md`
**Test files:** `tests/parity/test_release_skill_contract.py`
**Test command:** `python3 -m pytest tests/parity/test_release_skill_contract.py -v`
**Validation cmd:** `scripts/check-prompt-parity.sh`
**Goal:** every call site from the Phase 1 inventory calls the same script instead of re-deriving the logic in prose; `SKILL.md` shrinks by roughly the amount of prose extracted; behavior is unchanged.

- Port the jq gate sequence (empty/shape/enum/unknown-key/duplicate-key checks, per `SKILL.md`'s existing `## Canonical Format` schema section) into `read-release-template.sh`, following `deep-review/scripts/persist-common.sh`'s `persist_validate_json_shape` pattern already cited as precedent in the template plan.
- Port the commit-precondition check (tracked, matches HEAD) and marker resolution (dual-anchor scheme, Audit Mode's A2 matching) into sibling scripts.
- Rewrite each Phase-1-inventoried call site in both `SKILL.md`s to invoke the relevant script and interpret its output/exit code, removing the duplicated prose.
- Codex mirror edits go through `codex:rescue` first per `AGENTS.md`; Claude mirror aligned in the same commit.
- Add script-level unit coverage (not just the existing prose-contract parity tests) for the extracted scripts, matching the pattern in `deep-review/scripts/` if one exists there.

### Phase 3: Progressive disclosure split + A2/A2.5 separation

**Impl files:** `plugins/skein/skills/release/references/template-subsystem.md` (name TBD from Phase 1 precedent), `plugins/skein/skills/release/SKILL.md`, Codex mirror equivalents
**Test files:** `tests/parity/test_release_skill_contract.py`
**Test command:** `python3 -m pytest tests/parity/test_release_skill_contract.py -v`
**Validation cmd:** `scripts/check-prompt-parity.sh`
**Goal:** an untemplated `/release` cut loads no template-subsystem content; A2.5 is a separate step/subcommand that A2 does not depend on.

- Move the template schema definition, jq-gate-sequence *documentation* (the scripts now carry the logic; this is the remaining prose description), Audit Mode's dual-anchor marker resolution, and A2.5 inference prose into the new `references/` file, loaded only on the templated branch per the Phase 1 precedent mechanism.
- Split A2.5 into its own subcommand/step (`/release audit --infer-template` or similar — confirm naming against existing skein subcommand conventions) that runs independently of A2's classification, consuming A2's already-published classification results as read-only input rather than being interleaved with it.
- Re-verify Audit Mode's marker-absent fallback (xhigh findings #9, #11 territory) against the split structure — do not silently resolve or paper over those findings; if the split makes the fix obvious, fix it as a named follow-up commit referencing the finding number, not folded silently into the structural move.

### Phase 4: Re-anchor parity tests on stable markers

**Impl files:** `plugins/skein/skills/release/SKILL.md`, `plugins/skein-codex/skills/release/SKILL.md`, `tests/parity/test_release_skill_contract.py`
**Test files:** `tests/parity/test_release_skill_contract.py`
**Test command:** `python3 -m pytest tests/parity/test_release_skill_contract.py -v`
**Validation cmd:** `scripts/check-prompt-parity.sh`
**Goal:** an editorial heading rename in either mirror produces a clear, named test failure (or none, if content is unaffected) instead of an opaque `ValueError` from a failed `.index()` lookup.

- Add stable machine-readable anchors (e.g. `<!-- skein:step-1 -->`) at each region boundary the test suite currently locates via literal heading text, in both mirrors.
- Rewrite the test suite's region-helper functions to key off the anchors, with a clear assertion message on anchor-not-found (not a bare `ValueError`).
- Confirm this survives the heading-text changes Phases 2–3 will have already made, and would survive a future rename that Phase 2/3 didn't anticipate — add a regression test that renames a heading in a scratch copy and asserts the suite still locates the region correctly.

## Findings

(populated during implementation/review — do not pre-fill)
