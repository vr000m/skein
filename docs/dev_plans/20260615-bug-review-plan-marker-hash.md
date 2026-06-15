# Task: Deterministic review marker — make /review-plan reuse conduct's marker.py

**Status**: Not Started
**Component**: review-skills
**Assigned to**: Claude
**Priority**: High
**Branch**: fix/review-plan-deterministic-marker-hash
**Created**: 2026-06-15
**Completed**: (fill when done)

## Objective

Make `/review-plan` write its review marker via deterministic, byte-faithful code — the same hashing authority `/conduct` already uses (`plugins/skein/skills/conduct/marker.py`) — instead of an LLM hand-following a prose recipe at Step 7. Eliminate the class of false "plan drift" caused by an agent normalizing bytes the validator preserves.

## Context

**The bug, empirically confirmed.** A `/conduct` run flagged a freshly-reviewed plan as stale. Correlating the `gamealerts` session transcripts (`~/.claude/projects/-Users-vr000m-Code-vr000m-gamealerts/*.jsonl`) proved:

- Both `/review-plan` and `/conduct` ran on **skein v0.2.2** — every session path is `cache/skein/skein/0.2.2`; no 0.2.0/0.2.1 involved. This is not a version skew.
- The `/review-plan` session had the **correct byte-faithful prose in context** ("preserve any trailing blank line… do not trim or normalize", `review-plan/SKILL.md:562-564`).
- The agent nonetheless **hand-rolled** the hash in Python: `above = b'\n'.join(lines[:idx])`. `str.join` inserts separators only *between* elements, so the newline preceding the marker is silently dropped — an rstrip-equivalent. Recorded hash: `9fa0989…`.
- `conduct/marker.py` computes the hash with a **byte-faithful slice** (`strip_marker_for_hashing` → `plan_text[:span[0]]`, `marker.py:107-136`), which keeps that newline. Computed hash: `df8d891…`. Mismatch → false staleness.

**Root cause.** The v0.2.2 fix hardened conduct's *code* and review-plan's *prose words*, but `/review-plan` still computes the marker hash by **LLM hand-following prose** — there is no bundled deterministic entrypoint. Prose cannot prevent the `splitlines`/`join` newline-eating trap. Only shared deterministic code can. `/conduct` already does this correctly via `marker.py`; `/review-plan` must do the same.

This fits the existing direction of the repo: `20260523-feature-bundle-auto-fix-appliers.md` (Component `review-skills`) already moved review-plan's auto-fix edits off hand-application onto a **bundled, abort-if-absent applier** delivered by `scripts/bundle-appliers.sh`. This plan extends that *same canonical-source bundler* to the marker write — the one remaining hand-computed step.

## Requirements

- `/review-plan` Step 7 must write the marker by invoking a **bundled deterministic entrypoint**, never by hand-computing the hash.
- The entrypoint's hashing behaviour must be **identical** to `conduct/marker.py` (`strip_marker_for_hashing` / `write_marker` / `_hash_stripped`) — single source of truth, not a re-implementation.
- The single source of truth is a **canonical `scripts/marker.py`** delivered into review-plan's mirrors by the existing `scripts/bundle-appliers.sh` pipeline (the proven idempotency-against-canonical idiom), **not** a free-floating hand-copy guarded by a mutual diff. Conduct's two existing copies are anchored to the same canonical file by the parity guard.
- Step 7 must adopt the **same "abort if absent, never hand-compute" contract** the auto-fix applier already uses (`review-plan/SKILL.md:399`, codex `:408`).
- **No-divider case:** if the plan has no marker line *and* no placeholder divider, `write-review-marker.py` must **abort with a clear error**, never silently append. (Shared `marker.py`'s EOF-append behaviour is unchanged for conduct; the abort guard lives in the review-plan CLI wrapper.) The dev-plan template always emits the placeholder, so normal flow is unaffected.
- The change must be mirrored into **skein-codex** with the `$SKILL_DIR` path anchor (never `${CLAUDE_PLUGIN_ROOT}`); Codex SKILL.md edits go through `codex:rescue`. The bundled scripts land in both mirrors *together* (the bundler fans out to both), so no commit leaves one mirror's SKILL.md referencing a script absent from that mirror.
- Marker-write logic must remain **byte-identical across all copies** (canonical `scripts/marker.py`; conduct skein/codex; review-plan skein/codex), anchored to the canonical file and guarded by the bundle parity test.
- Behavioural parity must be proven on the edge cases that triggered the bug: trailing blank line before marker, no trailing newline at EOF, CRLF line endings, and first-review placeholder divider. The behavioural assertion must run the **round-trip the real system performs** (write then recompute on the post-write file), not hash a pristine fixture twice.
- Both plugin manifests bumped (`0.2.2` → `0.2.3`); docs updated in the same pass.

## Review Focus

- **Invariant to verify:** for any plan content, the hash `/review-plan` records at Step 7 equals the hash `/conduct`'s `marker.py` recomputes at preflight. The test must assert this as a **round-trip**: `sha_written = write_marker(plan); sha_recompute = compute_plan_hash(plan)`, both reading the **post-write** on-disk bytes — across trailing-blank, no-EOF-newline, CRLF, and placeholder-divider cases. Show byte-level evidence (equal sha), not just "tests pass". (Hashing a pristine fixture on both sides would spuriously fail the no-EOF-newline case, since `write_marker` appends `\n` — `marker.py:209-211`.)
- **Single-source-of-truth check:** the fix must not leave a hashing implementation that can drift. The canonical `scripts/marker.py` is the only source; every copy (conduct ×2, review-plan ×2) is anchored to it by the bundle parity guard.
- **Regression naming:** the "blank line immediately above marker" fixture is the named regression for the dropped-newline bug (`9fa0989` vs `df8d891`). Assert that the byte-faithful slice and an rstripped slice **diverge** on that fixture, and that `write_marker` records the byte-faithful one — so the test proves it would have caught the original bug, not merely that the new path is internally consistent.
- **Prose-removal is tested:** a negative assertion (grep, precedent `tests/parity/test-no-manual-apply-fallback.sh`) must confirm no hand-compute hashing recipe survives in either review-plan SKILL.md — otherwise a future edit could reintroduce it with all other tests still green.
- **Abort contract is tested:** an explicit assertion that (a) an absent entrypoint and (b) a plan with no divider both abort without writing a marker.
- **Path-anchor discipline:** skein uses `${CLAUDE_PLUGIN_ROOT}`, codex uses `$SKILL_DIR` — never collapsed (see `feedback_harness_divergent_path_anchors`).
- **Placeholder semantics:** first-review replaces the template placeholder divider in place (`MARKER_PLACEHOLDER_RE`, `marker.py:32`; `include_placeholder=True`, `marker.py:99`). For the placeholder fixture, additionally assert the post-write "no `MARKER_PLACEHOLDER_RE` line survives" validation (`SKILL.md:567`), separate from the sha assertion.
- **Workspace normalization is named, not "verbatim":** `_split_around_marker` drops leading/trailing blank lines of the workspace (`marker.py:251-254`). This is harmless (below-marker is never hashed) but the SKILL.md "preserved verbatim" prose overstates it — soften it.

## Implementation Checklist

### Phase 1: Canonical marker.py + CLI, wired into the bundler

**Impl files:** `scripts/marker.py, scripts/write-review-marker.py, scripts/lib/bundle-map.sh, scripts/bundle-appliers.sh, scripts/check-sync.sh`
**Test files:** `tests/parity/test-marker-parity.sh`
**Test command:** `bash tests/parity/test-applier-bundle-parity.sh && bash tests/parity/test-marker-parity.sh`

- Add `scripts/marker.py` as the **canonical** copy, byte-identical to `plugins/skein/skills/conduct/marker.py` (stdlib-only; no harness-divergent imports). This becomes the single source.
- Add `scripts/write-review-marker.py`: a thin CLI that (1) bootstraps import via `sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))` then `from marker import write_marker, _marker_line_span`; (2) **aborts non-zero** if the plan has no marker line and no placeholder divider (`_marker_line_span(text) is None`) — "no review-marker divider; cannot place marker safely"; (3) otherwise calls `write_marker(plan_path)` and prints the sha. No hashing logic of its own.
- Extend `scripts/lib/bundle-map.sh` with a **per-skill extras** mechanism (e.g. `bundle_extra_for <skill>` returning `marker.py write-review-marker.py` for `review-plan`, empty for `deep-review`) so the two files land in review-plan's mirrors only — preserving the "bundled == operative" invariant (do **not** add them to `BUNDLE_SHARED`, which would copy them into deep-review uselessly).
- Update `scripts/bundle-appliers.sh` to stage the per-skill extras; update `scripts/check-sync.sh` if it enumerates the bundle set. Run the bundler so the review-plan mirrors receive byte-identical copies in this phase (both mirrors together).
- Add `tests/parity/test-marker-parity.sh`: (a) assert canonical `scripts/marker.py` is byte-identical to all four copies (conduct skein/codex, review-plan skein/codex) using `scripts/marker.py` as the **named anchor**; (b) behavioural round-trip — for each edge-case fixture, `write_marker(plan)` then `compute_plan_hash(plan)` on the post-write file, assert equal sha.

### Phase 2: Rewire review-plan Step 7 + fix prose (skein)

**Impl files:** `plugins/skein/skills/review-plan/SKILL.md`
**Test files:** `tests/auto-fix/test-review-plan-marker-write.sh`
**Test command:** `bash tests/auto-fix/test-review-plan-marker-write.sh`

- Replace the hand-computed hashing recipe (Step 7 procedure, `SKILL.md:558-569`) with an invocation of `${CLAUDE_PLUGIN_ROOT}/skills/review-plan/scripts/write-review-marker.py <plan>`, plus the abort-if-absent / never-hand-compute contract mirroring `SKILL.md:399`.
- Update the no-marker prose (`SKILL.md:571`) to state the new contract: a plan with no divider **aborts**, it is not appended at EOF.
- Soften the "preserved verbatim" workspace prose to acknowledge edge blank-line normalization (harmless; below-marker is unhashed).
- Keep the auto-fix interaction (Step 6.5 `marker_pending`, marker written once at Step 7) intact; the rewired Step 7 calls `write_marker` exactly once, post-acceptance.
- Add `tests/auto-fix/test-review-plan-marker-write.sh`: (a) negative assertion — no hand-compute hashing recipe remains in the skein SKILL.md (grep, precedent `test-no-manual-apply-fallback.sh`); (b) abort contract — entrypoint absent → abort, no marker; no-divider plan → abort, no marker; (c) placeholder fixture — after write, no `MARKER_PLACEHOLDER_RE` line survives.

### Phase 3: Mirror SKILL.md into skein-codex (scripts already bundled in Phase 1)

**Impl files:** `plugins/skein-codex/skills/review-plan/SKILL.md`
**Test files:** `tests/auto-fix/test-review-plan-marker-write.sh`
**Test command:** `bash tests/parity/test-applier-bundle-parity.sh && bash scripts/check-prompt-parity.sh`

- The bundled `marker.py` + `write-review-marker.py` already landed in the codex mirror in Phase 1 (the bundler fans to both). This phase only updates codex `review-plan/SKILL.md` Step 7 to invoke `"$SKILL_DIR"/scripts/write-review-marker.py` with the `$SKILL_DIR` anchor and abort contract (codex `:408,:416,:423`), plus the same no-divider-abort and verbatim-prose corrections. **SKILL.md edit goes through `codex:rescue`** per repo convention.
- Extend the negative assertion in `test-review-plan-marker-write.sh` to cover the codex SKILL.md too.

### Phase 4: Consolidated regression + edge-case proof

**Impl files:** `tests/parity/test-marker-parity.sh, tests/auto-fix/test-review-plan-marker-write.sh`
**Test command:** `bash tests/parity/test-marker-parity.sh && bash tests/auto-fix/test-review-plan-marker-write.sh && bash tests/parity/test-conduct-marker-parity.sh`

- Add the named **`9fa0989`-vs-`df8d891` regression**: on the "blank line immediately above marker" fixture, assert `git hash-object` of the byte-faithful slice ≠ hash of the rstripped (`b'\n'.join`) slice, and that `write_marker` records the byte-faithful one. This proves the fix would have caught the original bug.
- Ensure all listed edge cases are exercised by the round-trip assertion: trailing blank line, no EOF newline, CRLF, placeholder divider, no-divider (abort).
- Confirm `test-conduct-marker-parity.sh` still passes (conduct copies unchanged, now also anchored to canonical via `test-marker-parity.sh`).

### Phase 5: Docs + manifest bump

**Impl files:** `CHANGELOG.md, AGENTS.md, README.md, docs/dev_plans/README.md, plugins/skein/.claude-plugin/plugin.json, plugins/skein-codex/.codex-plugin/plugin.json`
**Test command:** `bash tests/parity/test-applier-bundle-parity.sh && bash tests/parity/test-marker-parity.sh`

- Bump BOTH manifests `0.2.2` → `0.2.3` (update cache key — see `project_skein_release_dual_manifest_bump`).
- CHANGELOG entry describing the deterministic-marker fix and the empirical root cause.
- Update AGENTS.md marker/hashing notes: review-plan now shares the canonical `scripts/marker.py` via the bundler (no hand-computed hash); document the no-divider-abort contract.
- Update README and `docs/dev_plans/README.md` task table (Component `review-skills`).
- Add a `CODEX_MIRROR_BACKLOG.md` entry only if the SKILL.md prose legitimately diverges between mirrors.

## Technical Specifications

### Files to Modify
- `scripts/lib/bundle-map.sh` — add per-skill extras mechanism (`marker.py`, `write-review-marker.py` → review-plan only).
- `scripts/bundle-appliers.sh` — stage the per-skill extras into each mirror.
- `scripts/check-sync.sh` — include the new bundled files if it enumerates the set.
- `plugins/skein/skills/review-plan/SKILL.md` — replace hand-computed Step 7 recipe (`:558-569`) with bundled-entrypoint invocation + abort contract; fix no-marker prose (`:571`); soften "verbatim".
- `plugins/skein-codex/skills/review-plan/SKILL.md` — same, `$SKILL_DIR` anchor, via `codex:rescue`.
- `tests/parity/test-conduct-marker-parity.sh` — unchanged behaviourally, but conduct copies are now additionally anchored to canonical by `test-marker-parity.sh`.
- `CHANGELOG.md`, `AGENTS.md`, `README.md`, `docs/dev_plans/README.md` — docs sync.
- `plugins/skein/.claude-plugin/plugin.json`, `plugins/skein-codex/.codex-plugin/plugin.json` — version `0.2.2` → `0.2.3`.

### New Files to Create
- `scripts/marker.py` — **canonical** copy of conduct's `marker.py` (single hashing authority; bundled into review-plan mirrors).
- `scripts/write-review-marker.py` — thin CLI: import-bootstrap, no-divider abort guard, `write_marker(plan)` → print sha.
- `tests/parity/test-marker-parity.sh` — anchored byte-identity (all copies == `scripts/marker.py`) + behavioural round-trip across edge cases.
- `tests/auto-fix/test-review-plan-marker-write.sh` — negative assertion (no hand-compute recipe), abort contract (absent entrypoint + no divider), placeholder no-placeholder-validation.
- *(Generated, not hand-authored)* `plugins/{skein,skein-codex}/skills/review-plan/scripts/marker.py` and `…/write-review-marker.py` — produced by `bundle-appliers.sh`; byte-identical artifacts, not edited directly.

### Architecture Decisions
- **Canonical-source bundler over free-floating copy.** review-plan's `scripts/` is already a `bundle-appliers.sh` target (`BUNDLE_SKILLS=(deep-review review-plan)`, `bundle-map.sh:25`). The bundler's `test-applier-bundle-parity.sh` verifies **idempotency against a named canonical source** — stronger than a mutual `diff`, which would pass even if all copies drifted together. So `marker.py` lives canonically in `scripts/` and is fanned out; the parity test anchors conduct's existing two copies to the same canonical file. (Rejected: a 4-way mutual diff with no canonical anchor — the original draft's approach.)
- **Per-skill bundle extras, not `BUNDLE_SHARED`.** `marker.py`/`write-review-marker.py` are review-plan-specific; adding them to `BUNDLE_SHARED` would copy them into deep-review, violating the "bundled == operative" invariant documented at `bundle-map.sh:9-13`. A `bundle_extra_for <skill>` hook keeps them scoped.
- **Abort guard in the CLI, not in shared `marker.py`.** Decision: a plan with no divider aborts (matches the abort-contract philosophy; never silently buries the marker below the workspace). To keep `marker.py` byte-identical with conduct — which legitimately EOF-appends — the no-divider check lives in `write-review-marker.py`, not in the shared module.
- **Round-trip is the real invariant.** `write_marker` *mutates* the file (appends `\n` to `above` when absent, `marker.py:209-211`); the test must recompute `compute_plan_hash` on the **post-write** bytes, exactly as `/conduct` preflight does (precedent: `tests/auto-fix/test-review-plan-conduct-preflight.sh`). Hashing a pristine fixture on both sides would spuriously fail the no-EOF-newline case.
- **Reuse `write_marker`'s placeholder handling.** `write_marker` → `_split_around_marker` → `_marker_line_span` includes the placeholder (`include_placeholder=True`, `marker.py:99`), so first-review placeholder replacement positions the marker where the placeholder was (after the final immutable-contract heading) and preserves the workspace. The template's second comment line is not a `MARKER_PLACEHOLDER_RE` match, so the post-write no-placeholder validation still passes.
- **stdlib-only, no new deps.** `marker.py` shells to `git hash-object`; no `pyproject.toml` at repo root.

### Dependencies
- None new. Python 3 stdlib + `git` (already required by `marker.py`).

### Integration Seams

| Seam | Writer (task) | Caller (task) | Contract |
|------|---------------|---------------|----------|
| canonical marker authority | `scripts/marker.py` | `bundle-appliers.sh`, conduct (anchored) | Byte-faithful slice `plan_text[:span[0]]`; trailing newline before marker preserved; all copies anchored byte-identical to canonical (parity-guarded) |
| bundle fan-out | `bundle-map.sh` extras + `bundle-appliers.sh` | review-plan mirrors | `marker.py` + `write-review-marker.py` delivered to review-plan only, both mirrors together; idempotent against canonical |
| Step 7 marker write | `write-review-marker.py` | `review-plan/SKILL.md` Step 7 | Invoke bundled entrypoint; abort if absent; abort if no divider; never hand-compute; post-write no-placeholder validation holds; called exactly once post-acceptance |
| cross-mirror SKILL parity | Claude SKILL.md (`${CLAUDE_PLUGIN_ROOT}`) | Codex SKILL.md (`$SKILL_DIR`) | Anchor divergence is the only permitted difference; codex edit via `codex:rescue` |

## Testing Notes

### Test Approach
- [ ] Anchored byte-identity: all `marker.py` copies == canonical `scripts/marker.py` (`test-marker-parity.sh` + `test-applier-bundle-parity.sh` idempotency)
- [ ] Behavioural round-trip: `write_marker(plan)` sha == `compute_plan_hash(plan)` on post-write file, per edge case
- [ ] Named regression: byte-faithful slice ≠ rstripped slice on the trailing-blank fixture; `write_marker` records the byte-faithful one
- [ ] Negative assertion: no hand-compute hashing recipe in either review-plan SKILL.md
- [ ] Abort contract: absent entrypoint → abort; no-divider plan → abort; neither writes a marker

### Test Results
- [ ] All existing tests pass (`tests/parity/`, `tests/auto-fix/`, conduct tests)
- [ ] New parity + write tests added and passing
- [ ] `scripts/check-prompt-parity.sh` and `test-applier-bundle-parity.sh` clean

### Edge Cases Tested
- [ ] Trailing blank line immediately above marker (named regression)
- [ ] No trailing newline at EOF
- [ ] CRLF line endings
- [ ] First-review placeholder divider replacement (+ no-placeholder-survives validation)
- [ ] No divider at all → abort (not append)

## Acceptance Criteria

- `/review-plan` writes the marker only via the bundled entrypoint; the SKILL.md prose recipe for hand-computing the hash is removed in both mirrors — **enforced by a negative-assertion test**.
- For every edge-case plan, the sha recorded by `write-review-marker.py` equals `conduct`'s `compute_plan_hash` on the post-write file — demonstrated by a passing round-trip assertion (the invariant, with evidence).
- All `marker.py` copies are byte-identical to canonical `scripts/marker.py`, enforced by `test-marker-parity.sh` + `test-applier-bundle-parity.sh`.
- review-plan aborts (does not hand-compute, does not append) when the bundled entrypoint is absent **or** when the plan has no divider — **enforced by an abort-contract test**.
- The named `9fa0989`-vs-`df8d891` regression test demonstrates the byte-faithful and rstripped slices diverge on the trailing-blank fixture.
- Both manifests at `0.2.3`; CHANGELOG/AGENTS/README updated.
- Code reviewed and approved; tests passing; documentation updated.

<!-- reviewed: 2026-06-15 @ 3054b55136ffd10c7e57c0695805bfc95079a997 -->

<!-- /review-plan writes the marker line above. Everything below is the workspace: edits here do NOT invalidate the marker. -->

## Progress

- [ ] Phase 1: Canonical marker.py + CLI, wired into the bundler
- [ ] Phase 2: Rewire review-plan Step 7 + fix prose (skein)
- [ ] Phase 3: Mirror SKILL.md into skein-codex
- [ ] Phase 4: Consolidated regression + edge-case proof
- [ ] Phase 5: Docs + manifest bump

## Findings

- 2026-06-15 `/review-plan` audit (dogfood): 3 Criticals resolved into the plan — (1) wrong code-sharing idiom → canonical bundler with conduct anchored; (2) behavioural test couldn't prove its invariant → restated as post-write round-trip; (3) `write_marker` EOF-appends on no-marker, contradicting SKILL.md:571 → CLI aborts on no-divider. Important/Minor findings (sys.path bootstrap, prose-removal negative test, abort-contract test, "verbatim" prose softening, placeholder no-placeholder assertion, Objective path typo) all folded in. codebase-claims lens clean (26/26).

## Issues & Solutions

### Issue 1: [Brief description]
- **Problem**: [What went wrong]
- **Solution**: [How it was resolved]
- **Files affected**: [List files]

## Final Results

[Fill this section when the work is complete]

### Summary
[Brief summary of what was accomplished]

### Outcomes
- Outcome 1

### Learnings
- [Any insights or lessons learned during implementation]

### Follow-up Work
- [Any related work identified for future plans]
