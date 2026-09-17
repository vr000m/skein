# Task: skein:release — progressive disclosure, script extraction, audit split, test anchor fragility

**Status**: Draft
**Component**: meta
**Assigned to**: Claude
**Priority**: Medium
**Branch**: TBD
**Created**: 2026-09-17
**Review Gates**: full

## Objective

Reduce `plugins/skein/skills/release/SKILL.md` (244K, 454 lines — roughly a third of the plugin's Claude-mirror skill-corpus byte total, though skills contribute only name+description until invoked, so the real cost is the ~247KB paid per `/release` invocation, not a standing context tax) from a monolithic always-loaded prose spec into a structure that matches every other complex skein skill (`deep-review`, `review-plan`, `review-gauntlet`, all of which ship a generated `scripts/` bundle and keep `SKILL.md` as the orchestration layer, not the mechanism). This is a structural refactor: behavior changes are limited to the two explicit exceptions named in Requirements below (A2.5's additional `--infer-template` entry point, and the test suite's assertion *targets* moving alongside the prose they check) — the untemplated `/release` cut (the common case, including every skein release to date) must not regress, and every templated-branch behavior currently documented in prose must be preserved, whether verbatim or via a named, reviewed equivalent.

## Context

`/code-review xhigh --fix` against `feature/release-repo-template` (2026-09-17, findings recorded in `docs/dev_plans/20260914-feature-release-repo-template.md`) surfaced 15 findings, nearly all of them spec self-contradictions or coverage gaps *within* the template subsystem added by that plan. Reviewing the pattern across findings (#2, #5, #6, #9, #11, #14 in particular) shows the underlying cause isn't isolated prose bugs — it's that deterministic validation logic (template read, jq gate sequence, marker resolution, commit-precondition checks) is re-specified in English at roughly 5 call sites across 2 mirrors (~10 near-duplicate copies), with no single source of truth an editor or reviewer can check for consistency. Every other complex skein skill avoids this by extracting the deterministic parts into `scripts/`, leaving `SKILL.md` to orchestrate.

Three further structural issues surfaced in follow-up review (2026-09-17, this session):

1. **No progressive disclosure.** The template subsystem (schema, jq gates, Audit Mode's dual-anchor scheme, A2.5 inference) is only relevant on the templated branch, yet lives inline in `SKILL.md` and is loaded on every invocation — including the untemplated case, which is the norm today (skein's own repo carries no template).
2. **A2.5 circularly coupled to A2.** Audit Mode's template-inference step (A2.5) proposes a template from release history but must reason about which candidates A2 could/couldn't classify to avoid proposing a canonical template against a repo that deliberately removed one — coupling a read-only classifier to a generative inference step inside the same mode.
3. **Parity tests anchor on prose headings.** `tests/parity/test_release_skill_contract.py`'s region helpers locate sections via `text.index("### Step 1: ...")`-style literal heading lookups; an editorial heading rename raises `ValueError` instead of a meaningful test failure, making the test suite fragile to exactly the kind of copy-editing this refactor will do.

This plan is scoped to structure only. It does not attempt to resolve the 14 unfixed content findings from the xhigh review (marker match-count precedence, Step 6 recompose ordering, jq-pin authorization for new call sites, CRLF/Unicode gate gaps, etc.) — those are logic bugs in the current prose and are out of scope here, though several should get materially easier to fix once the duplicated prose collapses into a single script. This includes findings #9 and #11 specifically (Audit Mode's marker-absent fallback): even if this refactor's A2/A2.5 split makes a fix to #9/#11 obvious, it is **not** folded into this branch — log it as a separate, standalone plan/finding instead, so this plan's own behavior-invariance requirement stays a meaningful check rather than a moving target. See "Related Work" below for the explicit link back to the xhigh findings.

**Grilled decisions (2026-09-17, review-plan Step 6.4, all accepted as recommended):**

1. **Script distribution model**: bundled, not hand-authored per mirror. New scripts are authored canonically at repo-root `scripts/`, `release` is registered in `scripts/lib/bundle-map.sh`'s `BUNDLE_SKILLS`, and `scripts/bundle-appliers.sh` fans them into both mirrors — matching `deep-review`/`review-plan`/`review-gauntlet`, all of which are generated bundles with no hand-authored-per-mirror precedent in this repo.
2. **A2.5 stays default-on** inside `/release audit` — the new `--infer-template` entry point is *additional*, not a replacement, so plain `/release audit` keeps emitting the inference proposal exactly as today. No behavior change on this axis.
3. **A2→A2.5 interface**: A2's existing human-readable classification output stays the interface. No new persistence artifact, no change to A2's emission — A2.5 parses the same output a human reads today (exact fields named in Phase 3 below).
4. **xhigh findings #9/#11 stay out of scope** for this plan, full stop — no follow-up-commit clause, even if the A2/A2.5 split makes a fix obvious mid-implementation.
5. **Phase sequencing**: a new Phase 1.5 lands the stable-anchor markers *before* any prose moves (trivially green), so Phases 2–3 move prose against already-stable anchors instead of racing Phase 4 to fix what they just broke.

## Related Work

- `docs/dev_plans/20260914-feature-release-repo-template.md` — the plan that introduced the template subsystem this refactor restructures. Its `/code-review xhigh --fix` run (2026-09-17) findings #1–#12, #14–#15 (finding #13 already fixed) are the concrete symptom list motivating this plan; see its Findings/changelog section for the full list. This plan does not re-litigate those findings' resolutions — it changes where the logic they point at lives, and Phases 2–3 below should close several of them as a side effect (tracked per-phase, not claimed as a batch fix). Findings #9 and #11 are explicitly excluded from that side-effect closure per the grilled decision above.
- `AGENTS.md` — mirror-editing convention is documented across its "### Path-resolution idiom (harness-divergent)" and "### review-gauntlet `lib/` (authored, mirror-parity-enforced)" subsections (there is no single top-level `## Mirrors` heading in `AGENTS.md` itself; the project's `.claude/CLAUDE.md` does carry one). Both govern the Codex-mirror-first edit order this plan follows throughout.
- `scripts/lib/bundle-map.sh`, `scripts/bundle-appliers.sh`, `scripts/check-sync.sh` — the canonical-source/bundle/drift-guard machinery every existing skill `scripts/` directory goes through; this plan's Phase 2 registers `release` into it rather than hand-authoring per mirror (grilled decision 1).

## Requirements

- `/release <version>` and `/release audit` behavior is unchanged for every untemplated repo (including skein's own repo) before and after this refactor, and the templated branch's documented behavior is preserved — either verbatim or via a named, reviewed equivalent when an assertion's *source of text* necessarily moves (SKILL.md prose → `scripts/` behavior or `references/` content). This is a structural move, not a behavior change, with two explicit, deliberate exceptions: (a) `/release audit --infer-template` is a new additional entry point (A2.5 stays default-on inside plain `/release audit` — grilled decision 2); (b) the parity suite's assertion *targets* relocate alongside the prose they check (Phase 2/3 each ship a mapping table, see below) — the suite's *coverage* must not narrow, proven by a superset-of-test-ids check (Phase 4), not byte-for-byte prose equality.
- Each phase that moves an assertion's source of text (Phase 2, Phase 3) ships a **mapping table** as part of its own deliverable: old assertion (test name + line) → new assertion (script behavior test, or `references/`-content test). No assertion is deleted without a named replacement in the same commit.
- Deterministic template-read/validate/jq-gate logic currently re-specified in prose at the ~5 call sites identified in the xhigh review is extracted into scripts following the shape of `plugins/skein/skills/deep-review/scripts/` (a `lib/` for shared helpers, single-purpose top-level scripts). Per grilled decision 1, these are authored canonically at repo-root `scripts/` (not hand-authored inside `plugins/skein/skills/release/scripts/`), with `release` registered in `scripts/lib/bundle-map.sh`'s `BUNDLE_SKILLS` so `scripts/bundle-appliers.sh` fans them into both mirrors identically. `codex:rescue` is used for the Codex-mirror `SKILL.md` prose and path-anchor edits only, per `AGENTS.md`'s existing convention — not for script authoring, since scripts are single-source canonical and bundle-copied, not independently written per mirror.
- The template subsystem (schema definition, jq validation gate sequence *documentation* — the scripts now carry the logic — Audit Mode's dual-anchor marker resolution, and A2.5 inference prose) is split out of the always-loaded body of `SKILL.md` into a `references/` file loaded only on the templated branch (repo has `.release-template.json`, or Audit Mode reaches a marker-bearing release), following the existing `content-review/references/content-guidelines.md` precedent (a plain prose "read `references/...`" instruction — the only conditional/lazy-load precedent in this codebase; there is no harness-enforced lazy-load mechanism, so this is a model-discretion contract, not a hard guarantee, and Phase 3's verification (below) is scoped accordingly). An untemplated `/release` cut must not pay context cost for this file at all.
- Audit Mode's A2.5 template-inference is split from A2's read-only drift classification into its own subcommand/step (`/release audit --infer-template`) so A2 never depends on A2.5's proposal state, closing the circular-coupling risk (A2.5 proposing a canonical template against a repo that deliberately removed one). A2 remains a pure read-only classifier with **unchanged emission** (grilled decision 3): A2.5 parses the same human-readable classification output A2 already produces today — Phase 3 names the exact fields A2.5 reads from it. A2.5 stays default-on inside plain `/release audit` (grilled decision 2); `--infer-template` is an additional standalone entry point for re-running inference alone, not a replacement for the default behavior.
- `tests/parity/test_release_skill_contract.py`'s region-boundary helpers are re-anchored on stable, machine-readable markers (e.g. `<!-- skein:step N -->`-style HTML comments, invisible in rendered prose) instead of literal `### Step N: <title>` heading text **and** the other literal body-text anchors the suite currently uses (e.g. `"1. Read \`CHANGELOG.md\`"`, `"3. **Releases (list only)**"` — not all fragile anchors are headings), so an editorial rename or rewording produces a clear test failure (or none, if content is unaffected) instead of an opaque `ValueError`. Both mirrors carry the same markers. Per grilled decision 5, this markers-first work lands in a new **Phase 1.5**, before Phase 2 moves any prose — not in Phase 4, which now covers only the rename-resilience regression test and the coverage-narrowing check.
- Both mirrors change together per commit per `AGENTS.md`; each phase's commit is understood to atomically carry the Codex `SKILL.md`/`scripts/` half, the Claude `SKILL.md`/`scripts/` half, any `check-prompt-parity.sh`/lint-glob/pre-commit-config changes that phase needs, and the retargeted test assertions — with no intermediate commit between the Codex half and the Claude half. `scripts/check-prompt-parity.sh` must keep passing at the end of every phase (via `just ci`, see below), including against the new `scripts/` and `references/` files: Phase 2 extends `normalize_release_workflow()` with a path-anchor substitution rule (the release mirrors currently carry zero `${CLAUDE_PLUGIN_ROOT}`/`$SKILL_DIR` anchor lines, so this normalizer has no existing rule for them) and a `scripts/` byte-parity check (via the bundle registration in grilled decision 1, not a hand-rolled diff); Phase 3 extends it with a `references/` byte-parity arm modeled on the existing `content-review/references` block.
- New scripts (`scripts/*.sh` at repo-root, bundled per grilled decision 1) are added to the `justfile`'s `lint-scripts` recipe globs and `.pre-commit-config.yaml`'s matching `files:` patterns in the same commit that introduces them, and get script-level unit test coverage registered in the `justfile`'s test runner (matching `deep-review/scripts/`'s pattern if one exists there) — not just the prose-contract parity tests, which cover behavior-as-documented but not the scripts' own edge cases.
- `just ci` (backgrounded per this repo's testing convention) is each phase's actual Validation cmd — not the narrower `pytest tests/parity/test_release_skill_contract.py` + `check-prompt-parity.sh` pairing alone, which is a strict subset and would let a `check-sync`/lint/other-pytest-file regression go unnoticed. The targeted pytest run stays as each phase's fast inner-loop Test command.

## Review Focus

- **No behavior drift**: the refactor must not change what a templated or untemplated `/release` run does (except the two named exceptions above), only where the logic lives and how much of it loads per invocation. Phase 2 and Phase 3 each include a task that diffs the composed confirmation output (Step 4) and audit classification output before/after on a representative templated + untemplated fixture repo, not just "tests pass" — this fixture-diff task has an owning phase and command now (it had neither in the prior draft).
- **Progressive disclosure boundary correctness**: verify the untemplated path genuinely never reads the `references/` file. Since no harness-enforced lazy-load mechanism exists (only the `content-review` prose-instruction precedent — see Requirements above), this is verified via a static assertion (exactly one reference to `references/template-subsystem.md`, textually inside the templated-branch region of `SKILL.md`) plus one manual transcript check, not an automated harness-level guarantee.
- **Mirror parity**: `scripts/check-prompt-parity.sh` and `test_release_skill_contract.py` both continue to assert what they assert today or a named, reviewed equivalent (per the mapping-table requirement above); confirm the new test-anchor mechanism (Phase 1.5) and the retargeted assertions (Phase 2/3) don't silently narrow what's covered while making the suite pass — Phase 4's coverage-narrowing check (superset-of-test-ids, not byte-length tolerance) is the actual gate for this.
- **A2/A2.5 split correctness**: after the split, confirm A2's classification for a marker-absent, no-current-template repo doesn't change (this is exactly finding #9/#11's territory from the xhigh review, and per the grilled decision above, any fix to that territory is explicitly out of scope here — this Review Focus item is about *not regressing* it, not fixing it). Phase 3 adds a characterization test for this exact case *before* the split lands, so the split's effect on it is measurable rather than asserted.

## Architecture & Call Flow

This refactor touches five independently-executing components; their contracts:

1. **Claude/Codex `SKILL.md` mirrors** (`plugins/skein/skills/release/SKILL.md`, `plugins/skein-codex/skills/release/SKILL.md`) — the orchestration layer. Post-refactor, each invokes the extracted scripts (below) for deterministic work and reads `references/template-subsystem.md` only when the templated branch is reached.
2. **Extracted scripts** (`scripts/read-release-template.sh` + siblings, canonical at repo-root per grilled decision 1, bundled into both mirrors' `scripts/` subdirectories byte-identically) — argv-in, exit-code-and-stdout-out. Each script's contract (arguments, exit codes, stdout shape) is documented in Phase 2 as part of the mapping table, so `SKILL.md` prose has a concrete interface to call rather than re-deriving the logic.
3. **`references/template-subsystem.md`** — read by `SKILL.md` only on the templated branch (repo has `.release-template.json`, or Audit Mode reaches a marker-bearing release). Trigger condition and reader are both named explicitly in Phase 3; this is a model-discretion read (see Requirements above), not a harness-enforced gate.
4. **A2 → A2.5 handoff** — A2's existing human-readable classification output (unchanged emission, per grilled decision 3) is the medium; A2.5 parses named fields from it. No new persistence artifact.
5. **`tests/parity/test_release_skill_contract.py`** — reads both `SKILL.md` mirrors' prose (pre- and post-Phase-1.5-anchor) and, from Phase 2 onward, also exercises the extracted scripts directly (script-level unit coverage, per Requirements) rather than only asserting on prose.

## Implementation Checklist

### Phase 1: Explore precedent and inventory the ~10 duplicate-logic call sites

**Impl files:** `docs/dev_plans/20260917-refactor-release-skill-structure.md` (Findings section — the inventory itself is a committed deliverable, not left in agent context only)
**Test files:** none
**Test command:** n/a
**Validation cmd:** n/a
**Goal:** a concrete, line-numbered inventory of every call site re-specifying template-read/jq-gate/marker-resolution logic in both mirrors, committed to this plan's Findings section so a dropped session or `conduct --resume` doesn't lose it, plus the confirmed harness mechanism for lazy-loaded `references/` files (the `content-review/references/content-guidelines.md` precedent, already cited above — confirm no stronger mechanism exists before assuming this one).

- Grep both mirrors for every prose reference to the jq gate sequence, template schema validation, and marker (`release-template-sha`) resolution; tabulate call site, line range, and which of the xhigh findings (if any) it corresponds to. Commit this table into this plan's `## Findings` section.
- Confirm the `content-review/references/` precedent is in fact the only conditional/lazy-load mechanism in this codebase (no `scripts/`, `tests/`, or justfile gate observes or enforces it) — record this explicitly so Phase 3's verification approach isn't silently assuming a stronger guarantee than exists.
- Confirm `scripts/check-prompt-parity.sh`'s current scope: it walks `rubric.md`, `*-prompt.md` (maxdepth 1), and per-skill normalizer rules (release's is a 5-divergence-line count on `SKILL.md` only) — it does not yet cover `scripts/` or arbitrary `references/` subtrees for `release`. Confirm the `content-review/references` block (lines ~563-577) is the copyable precedent for Phase 3's extension.
- Confirm `scripts/lib/bundle-map.sh`'s `BUNDLE_SKILLS` enumeration and `bundle_applier_for`'s dispatch shape, to scope Phase 2's `release` registration precisely (grilled decision 1).

### Phase 1.5: Land stable test anchors before any prose moves

**Impl files:** `plugins/skein/skills/release/SKILL.md`, `plugins/skein-codex/skills/release/SKILL.md`, `tests/parity/test_release_skill_contract.py`
**Test files:** `tests/parity/test_release_skill_contract.py`
**Test command:** `uv run --with pytest python -m pytest tests/parity/test_release_skill_contract.py -v`
**Validation cmd:** `just ci` (backgrounded)
**Goal:** stable, machine-readable anchors exist at every region boundary the suite currently locates via literal heading or body text, in both mirrors, with zero prose movement — trivially green, so Phases 2–3 move prose against already-stable anchors instead of racing to fix what they just broke (grilled decision 5).

- Add `<!-- skein:step-N -->`-style anchors at each region boundary currently reached via `text.index("### Step N: ...")` or literal body-text lookups (e.g. `"1. Read \`CHANGELOG.md\`"`, `"3. **Releases (list only)**"`, `"2. Resolve and validate"`) — both the heading anchors and the body-text anchors the assumptions lens flagged as not-headings. Inconsistent heading spellings noted in review (some region helpers use truncated vs. full heading text) are normalized as part of this pass.
- Rewrite the suite's ~15 affected region-helper functions to key off the anchors, with a clear assertion message on anchor-not-found (never a bare `ValueError`).
- Add a scratch-copy rename regression test: rename a heading in a scratch copy of `SKILL.md`, assert the suite still locates the region correctly via the anchor (not the now-stale heading text).
- No jq-gate, schema, or template logic moves in this phase — `SKILL.md` prose content is otherwise byte-identical before/after except for the inserted anchor comments. This is what makes `just ci` green here a real signal, not a coincidence.

### Phase 2: Extract scripts/ (deterministic logic)

**Impl files:** `scripts/read-release-template.sh` (+ siblings per Phase 1's inventory) at repo-root, `scripts/lib/bundle-map.sh` (register `release` in `BUNDLE_SKILLS`), `scripts/bundle-appliers.sh` (bundle-extra arm for `release` if needed), `scripts/check-sync.sh` (drift guard picks up the new bundle registration), `scripts/check-prompt-parity.sh` (path-anchor normalizer rule + `scripts/` byte-parity check), `justfile` (`lint-scripts` globs), `.pre-commit-config.yaml` (matching `files:` patterns), `plugins/skein/skills/release/SKILL.md`, `plugins/skein-codex/skills/release/SKILL.md`
**Test files:** `tests/parity/test_release_skill_contract.py` (retargeted per the mapping table below), new script-level unit tests
**Test command:** `uv run --with pytest python -m pytest tests/parity/test_release_skill_contract.py -v`
**Validation cmd:** `just ci` (backgrounded)
**Goal:** every call site from the Phase 1 inventory calls the same bundled script instead of re-deriving the logic in prose; `SKILL.md` shrinks by roughly the amount of prose extracted; behavior is unchanged; the suite's coverage of the extracted logic moves to script-level tests with an explicit mapping table, not silently dropped.

- Port the jq gate sequence (empty/shape/enum/unknown-key/duplicate-key checks, per `SKILL.md`'s existing `## Canonical Format` schema section) into `read-release-template.sh`, following `deep-review/scripts/persist-common.sh`'s `persist_validate_json_shape` pattern.
- Port the commit-precondition check (tracked, matches HEAD) and marker resolution (dual-anchor scheme, Audit Mode's A2 matching) into sibling scripts.
- Register `release` in `scripts/lib/bundle-map.sh`'s `BUNDLE_SKILLS`; run `scripts/bundle-appliers.sh` to populate both mirrors' `scripts/` subdirectories byte-identically; confirm `scripts/check-sync.sh` picks up the new bundle with no drift.
- Extend `scripts/check-prompt-parity.sh`'s `normalize_release_workflow()` with a path-anchor substitution rule (`${CLAUDE_PLUGIN_ROOT}` vs `$SKILL_DIR`, same cardinality discipline as its existing four sanctioned divergences) so the new script-invocation lines in `SKILL.md` don't register as unexplained mirror drift; add a `scripts/` byte-parity assertion (via the bundle registration, not a hand-rolled diff).
- Rewrite each Phase-1-inventoried call site in both `SKILL.md`s to invoke the relevant script and interpret its output/exit code, removing the duplicated prose.
- Write the Phase 2 mapping table (old assertion name/line on `SKILL.md` prose → new script-behavior test) as this phase's own deliverable, in this plan's Findings section; retarget each listed assertion in `tests/parity/test_release_skill_contract.py` in the same commit.
- Add script-level unit test coverage for every new script, registered in the `justfile`'s test runner (not just referenced conditionally — a registered, always-run suite).
- Add the templated + untemplated fixture-repo diff task named in Review Focus: capture Step 4's composed confirmation output and audit classification output before this phase's changes, re-capture after, assert byte-identical (or named-equivalent per the mapping table) on both a templated and an untemplated fixture repo.
- Add new scripts to `justfile`'s `lint-scripts` globs and `.pre-commit-config.yaml`'s matching `files:` patterns in this same commit.
- Codex mirror `SKILL.md` prose edits go through `codex:rescue` first per `AGENTS.md`; Claude mirror `SKILL.md` aligned in the same commit; the bundled `scripts/` themselves are not independently authored per mirror (grilled decision 1), so `codex:rescue` applies to the Codex `SKILL.md` half only, not the scripts.
- Replace `python3 -m pytest` with this repo's convention, `uv run --with pytest python -m pytest`, in every phase's Test command (done here and retroactively noted for Phase 1.5 above).

### Phase 3: Progressive disclosure split + A2/A2.5 separation

**Impl files:** `plugins/skein/skills/release/references/template-subsystem.md`, `plugins/skein/skills/release/SKILL.md`, `plugins/skein-codex/skills/release/references/template-subsystem.md`, `plugins/skein-codex/skills/release/SKILL.md`, `scripts/check-prompt-parity.sh` (`references/` byte-parity arm), `docs/skills_architecture/20260522-design-claude-skills-architecture.md` (invocation-mode catalogue entry for `--infer-template`), release skill's frontmatter/README subcommand listing
**Test files:** `tests/parity/test_release_skill_contract.py` (retargeted per the mapping table below), a new characterization test for the marker-absent/no-current-template audit path
**Test command:** `uv run --with pytest python -m pytest tests/parity/test_release_skill_contract.py -v`
**Validation cmd:** `just ci` (backgrounded)
**Goal:** an untemplated `/release` cut loads no template-subsystem content; A2.5 is reachable both as part of `/release audit`'s default run (grilled decision 2) and standalone via `--infer-template`, consuming A2's unchanged existing output (grilled decision 3) rather than a new artifact.

- Move the template schema definition, jq-gate-sequence *documentation* (the scripts now carry the logic; this is the remaining prose description), Audit Mode's dual-anchor marker resolution, and A2.5 inference prose into `references/template-subsystem.md` (both mirrors), read by `SKILL.md` only on the templated branch per the `content-review` precedent named in Phase 1.
- Add `/release audit --infer-template` as an **additional** standalone entry point that re-runs A2.5 alone — A2.5 keeps running by default inside plain `/release audit` (grilled decision 2). Name A2's exact output fields A2.5 parses (grilled decision 3) as part of this task's deliverable.
- Update the invocation-mode catalogue test's hard-coded assertions (`test_invocation_mode_count_matches_release_catalogue`) and the corresponding doc/frontmatter entries for the new `--infer-template` flag.
- Add a characterization test for the marker-absent, no-current-template audit path *before* making any A2/A2.5 structural change in this phase, so the split's effect on it (regression or not) is measurable. Per Context above, do not fix xhigh findings #9/#11 in this phase even if the characterization test makes a fix obvious — log it separately.
- Add the progressive-disclosure boundary check named in Review Focus: a static assertion that `references/template-subsystem.md` is referenced exactly once, textually inside the templated-branch region of `SKILL.md`, plus a manual transcript check recorded in this plan's Findings section.
- Extend `scripts/check-prompt-parity.sh` with a `references/` byte-parity arm modeled on the existing `content-review/references` block (lines ~563-577), so the new `references/` files are mirror-drift-guarded from the moment they're introduced — they are not covered by any existing check otherwise.
- Write the Phase 3 mapping table (old assertion name/line on `SKILL.md` prose → new `references/`-content test) as this phase's own deliverable; retarget each listed assertion in `tests/parity/test_release_skill_contract.py` in the same commit.
- Add the templated-fixture-repo diff task named in Review Focus for this phase's changes specifically (references/ split + A2.5 entry point), same pattern as Phase 2's.
- Codex mirror `SKILL.md` and `references/` prose edits go through `codex:rescue` first per `AGENTS.md`; Claude mirror aligned in the same commit; no intermediate commit between the two halves.

### Phase 4: Coverage-narrowing check and rename-resilience regression

**Impl files:** `tests/parity/test_release_skill_contract.py`
**Test files:** `tests/parity/test_release_skill_contract.py`
**Test command:** `uv run --with pytest python -m pytest tests/parity/test_release_skill_contract.py -v`
**Validation cmd:** `just ci` (backgrounded)
**Goal:** prove the suite's *coverage* did not narrow across Phases 1.5–3, using a check compatible with the refactor's own goal of shrinking `SKILL.md` (a byte-length tolerance would fail by construction on intentional shrinkage, so this phase uses a coverage-preservation check instead).

- Add a superset-of-test-ids check: the post-refactor collected pytest test-id set (across `test_release_skill_contract.py` and the new script-level unit tests from Phase 2) must be a superset of the pre-refactor (pre-Phase-1.5) set, proving no assertion was dropped without a named replacement per the Requirements mapping-table rule — not a byte-length tolerance against the pre-refactor region sizes, which would be mutually exclusive with the Objective's shrinkage goal.
- The Phase 1.5 scratch-copy rename regression test already proves anchor robustness in isolation; this phase's coverage check is the complementary proof that the anchors still bound the *same logical regions* (non-empty, not silently shrunk to a vacuous substring match) after Phases 2–3's real prose movement.
- Confirm this phase's own checks pass cleanly given Phases 1.5–3 have already landed the anchor and prose changes they depend on — by construction, since Phase 1.5 now runs first, this phase adds no new anchor-stability risk, only the coverage-narrowing proof.

## Findings

(populated during implementation/review — do not pre-fill; Phase 1's committed inventory and Phase 2/3's mapping tables land here as they're produced)

### review-plan disposition (2026-09-17)

Full 44-finding review-plan report (13 Critical, 22 Important, 9 Minor, 12 Contradiction) is persisted at `.review-plan/latest-claude.json` from that run. Disposition:

- **5 genuine design decisions**, grilled and accepted as recommended (see "Grilled decisions" under Context above): script distribution model (bundled), A2.5 default-on, A2→A2.5 interface (existing output, unchanged), xhigh #9/#11 out of scope, Phase 1.5 sequencing insertion.
- **All other findings** (Missing Task, Testing Gap, Risk, Constraint, Ambiguity, Sequencing, Nonexistent Reference, and the remaining Contradiction findings that were downstream of the 5 decisions above) had a single clear fix and are incorporated directly into the Requirements/Review Focus/Architecture & Call Flow sections and the phase checklists above — not left as open findings.
