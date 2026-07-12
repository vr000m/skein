# Task: `skein:release` — sync/cut GitHub releases from CHANGELOG.md

**Status**: Complete
**Component**: meta
**Assigned to**: Claude
**Priority**: Medium
**Branch**: feature/skein-release-skill
**Created**: 2026-07-12

## Objective

Add a new, user-invoked-only `skein:release` skill (both Claude and Codex mirrors) that derives a GitHub release's title and body from a `## [X.Y.Z] - date` section in `CHANGELOG.md` (Keep a Changelog format), in a single canonical shape, and either creates a new tag+release or edits an existing one to match. This replaces today's ad hoc, hand-typed `gh release create`/`edit` invocations, which have drifted into at least three visibly different title/body shapes across skein's own 11 releases (retrofitted to the canonical shape in this same session, prior to this plan).

## Context

Observed today while auditing `github.com/vr000m/skein/releases`: three release-note shapes coexisted — bare `skein vX.Y.Z` titles with the CHANGELOG header still embedded in the body (`v0.5.0`), `vX.Y.Z — <highlight>` titles with a stripped body plus a `**Full diff:**` compare link (`v0.4.1`/`v0.4.0`/`v0.3.0`), and early releases (`v0.2.x`, `v0.1.0`) with GitHub's auto-generated empty notes and no highlight at all. Root cause: no script or skill owns this — every release was a manually composed `gh release create --notes "..."` call.

**Canonical format** (established and manually applied to all 11 existing releases as the worked example for this plan):
- **Title**: `<repo> vX.Y.Z — <highlight>`, where `<highlight>` is a short (under ~60 chars) one-line summary of the version's single biggest change, authored fresh per release (not mechanically derived — it requires reading the section and judging what matters).
- **Body**: the CHANGELOG section's content *below* its `## [X.Y.Z] - date` header (the `### Added`/`### Changed`/etc. subsections verbatim, header stripped since GitHub already surfaces the tag/date), followed by a blank line and `**Full diff:** https://github.com/<owner>/<repo>/compare/vPREV...vNEW`. The first-ever release (no PREV tag) omits the compare line entirely.

**Existing conventions this skill must follow** (from `AGENTS.md` and sibling skills):
- Every skein skill ships in two mirrors: `plugins/skein/skills/<name>/SKILL.md` (Claude) and `plugins/skein-codex/skills/<name>/SKILL.md` (Codex), with path-anchor divergence (`${CLAUDE_PLUGIN_ROOT}` template substitution on Claude vs `$SKILL_DIR` env-export on Codex) — see `rfc-finder`/`update-docs` as simple single-Sonnet-call precedents (no bundled `scripts/` subtree; those are reserved for `deep-review`/`review-plan`/`review-gauntlet`).
- Two tracking lists must include every new skill name or presence/parity tooling silently misses it: `scripts/check-prompt-parity.sh`'s `MANAGED_SKILLS` default (line 46) and `tests/parity/test_skill_md_presence.py`'s `MANAGED_SKILLS` list. Both currently enumerate 13 skills; this plan makes it 14.
- `README.md`'s skill table and `docs/skills_architecture/20260522-design-claude-skills-architecture.md`'s Skill Catalogue table (with its Invocation Mode column, added in `docs/dev_plans/20260711-chore-skill-invocation-mode-audit.md`) both need a new row.
- `disable-model-invocation: true` is a **Claude-only** front-matter field (confirmed in the skill-invocation-mode-audit plan above); the Codex mirror has no equivalent and must instead carry a one-line HTML-comment documenting the divergence, placed immediately after the front-matter close.
- This skill mutates external, hard-to-reverse state (pushes a git tag, publishes a GitHub release) — per this repo's own `CLAUDE.md` (Executing Actions With Care), it must confirm the version, computed title, and full body with the user before pushing/publishing, not act silently.

## Requirements

1. Given a version argument (an explicit `X.Y.Z`, or `latest`/`unreleased` meaning the top dated section in `CHANGELOG.md`), parse that section's body out of `CHANGELOG.md`, stripping the `## [X.Y.Z] - date` header line and any leading/trailing blank lines.
2. Determine the previous released version by reading the **existing tag list** (`git tag --list --sort=v:refname`), computed **before** any new tag from this run is created — tags are the canonical ordering source, not CHANGELOG section order, because the two can disagree (a CHANGELOG section can exist before its tag is pushed, and older tags may predate CHANGELOG coverage — see the v0.2.x/v0.1.0 case). PREV is the highest existing tag strictly below the target version; append the `**Full diff:**` compare link — omitted only when no such tag exists (first-ever release).
3. On re-sync (a release for the target version already exists), first try to recover the highlight from the existing release's title (`gh release view vX.Y.Z --json title`, text after the em dash) rather than re-drafting blind — this is the only persisted source of truth for the highlight and is what makes re-sync reproducible in practice. Only draft a fresh highlight by reading the section body when there is no existing release, or the existing title doesn't match the `vX.Y.Z — <highlight>` shape. Either way, echo the highlight to the user at the confirmation step (Requirement 7) and let them override it.
4. If the git tag `vX.Y.Z` does not exist locally, create it and push it (with user confirmation per this repo's destructive/external-state-change policy); if it exists, reuse it.
5. If a GitHub release for that tag does not exist, `gh release create`; if it exists, `gh release edit` — same canonical title/body in both cases, so re-running the skill on an already-published release re-syncs it (the retrofit use case).
6. The **body** is fully deterministic (parsed from CHANGELOG + computed compare link) and must be byte-identical across repeated runs against the same version. The **title** is deterministic only insofar as the highlight input is stable — the highlight itself is a fresh per-run judgment call (Requirement 3), not derived or stored state, so title idempotency is conditional on the caller supplying the same highlight text again, not an automatic guarantee.
7. User-invoked only: `disable-model-invocation: true` on the Claude mirror (Codex gets the documented-divergence comment, per Requirement above) — this is an externally-visible, hard-to-reverse action and should never fire autonomously off conversational context.
8. Dual-mirrored under `plugins/skein/skills/release/` and `plugins/skein-codex/skills/release/`, registered in both `MANAGED_SKILLS` lists and both catalogue docs (`README.md`, skills-architecture doc).

## Implementation Checklist

### Phase 1: Author the Claude mirror SKILL.md

**Impl files:** `plugins/skein/skills/release/SKILL.md`
**Test files:** none (doc-only skill, no bundled scripts)
**Test command:** n/a

- [ ] Write frontmatter: `name: release`, `description` describing the CHANGELOG→GitHub-release sync behavior with explicit trigger phrases ("cut a release", "publish this release", "sync release notes", "/release"), `argument-hint: "[version|latest|unreleased]"`, `disable-model-invocation: true`.
- [ ] Write the workflow: parse CHANGELOG section (Requirement 1), determine PREV tag + compare link (Requirement 2), draft highlight (Requirement 3), confirm title+body+tag-push with the user before any git/gh mutation (Requirement 7 / repo CLAUDE.md), then tag+push if missing, then `gh release create` or `gh release edit` (Requirement 5).
- [ ] Include the worked example from this session (v0.5.1's title/body) as a concrete illustration.

### Phase 2: Author the Codex mirror SKILL.md

**Impl files:** `plugins/skein-codex/skills/release/SKILL.md`
**Test files:** none
**Test command:** n/a

- [ ] Mirror Phase 1's content with Codex's dispatch idiom and `$SKILL_DIR` path anchor (no bundled scripts, so this is mostly moot, but keep the anchor convention consistent with sibling skills for any future script needs).
- [ ] No `disable-model-invocation` field (doesn't exist on Codex); add the one-line HTML-comment documenting the permanent Claude/Codex divergence, placed immediately after the frontmatter close.

### Phase 3: Register in tracking lists and docs

**Impl files:** `scripts/check-prompt-parity.sh`, `tests/parity/test_skill_md_presence.py`, `README.md`, `docs/skills_architecture/20260522-design-claude-skills-architecture.md`, `scripts/delete-skills.sh`
**Test files:** `tests/parity/test_skill_md_presence.py` (itself, once updated)
**Test command:** `just check-prompt-parity && python3 -m pytest tests/parity/test_skill_md_presence.py -q`

- [ ] Add `release` to `MANAGED_SKILLS` default in `scripts/check-prompt-parity.sh`.
- [ ] Add `"release"` to the `MANAGED_SKILLS` list in `tests/parity/test_skill_md_presence.py`.
- [ ] Add a row to `README.md`'s skill table.
- [ ] Add a row to the Skill Catalogue table in `docs/skills_architecture/20260522-design-claude-skills-architecture.md`, with Invocation Mode `user-invoked` (Claude) and a note on the Codex divergence — following the same reasoning discipline as the skill-invocation-mode-audit plan (Axis 1: nothing chains into `release`; Axis 2: "cut a release"/"publish this release" are command-name-adjacent, someone who says this already knows a release-cutting tool exists, so `release` is a genuine `disable-model-invocation` candidate on the same grounds as `plan-view`).
- [ ] Add `release` to the `SKEIN` array in `scripts/delete-skills.sh` (the surgical-uninstall helper) — leave its pre-existing `review-gauntlet` omission alone, that's a separate gap out of this plan's scope.
- [ ] `.env.example`'s documented `MANAGED_SKILLS` override example is already stale (11 names, missing `grill`/`review-gauntlet`) — out of this plan's scope to fully reconcile, but do not add to the staleness: leave it as-is rather than adding a 12th/13th/14th name to an already-incomplete example.

## Technical Specifications

### Files to Create
- `plugins/skein/skills/release/SKILL.md`
- `plugins/skein-codex/skills/release/SKILL.md`

### Files to Modify
- `scripts/check-prompt-parity.sh` — `MANAGED_SKILLS` default (line 46), add `release`.
- `tests/parity/test_skill_md_presence.py` — `MANAGED_SKILLS` list, add `"release"`.
- `README.md` — skill table row.
- `docs/skills_architecture/20260522-design-claude-skills-architecture.md` — Skill Catalogue row + Invocation Mode note.

### Integration Seams
- No bundled `scripts/` subtree — `release` follows the `rfc-finder`/`update-docs` precedent of doc-only skills with no bundled scripts subtree (`check-sync.sh`/`bundle-map.sh` registration not needed). **Execution model differs from those two precedents**, though: `rfc-finder`/`update-docs` are read-only and delegate their fact-gathering to a subagent; `release` performs an irreversible external mutation (tag push, release publish) gated on explicit user confirmation, so it runs entirely inline in the main agent context — a subagent cannot hold that confirmation gate.
- No inbound or outbound **chaining** edges to any other skein skill (confirmed by inspection — no other SKILL.md references release-cutting behavior). It does have a **data-contract** dependency, not a call edge: it parses the exact Keep a Changelog `## [X.Y.Z] - date` shape that `skein:update-docs` produces/maintains — if either skill's format assumption drifts, `release` silently mis-parses.

## Testing Notes

- `just check-prompt-parity` — confirms `MANAGED_SKILLS` entries stay parity-clean (no `*-prompt.md`/schema-block divergence; `release` has neither, so this is a presence-only pass-through).
- `python3 -m pytest tests/parity/test_skill_md_presence.py -q` — confirms both mirrors' `SKILL.md` exist.
- Manual: re-run the skill against the already-published `v0.5.1` release (the retrofit case) supplying the same highlight text used this session, and confirm it produces a byte-identical body always, and a byte-identical title when the same highlight is supplied (title idempotency is conditional on highlight stability, per Requirement 6 — not an automatic guarantee).

## Issues & Solutions

(filled in during implementation)

## Acceptance Criteria

- Both mirrors' `SKILL.md` exist, dual-mirrored per repo convention, Claude carries `disable-model-invocation: true`, Codex carries the documented-divergence comment.
- Both `MANAGED_SKILLS` lists and both catalogue docs include `release`.
- `just check-prompt-parity` and `tests/parity/test_skill_md_presence.py` pass.
- Skill correctly reproduces this session's manually-applied v0.5.1 body byte-for-byte when run against the existing release (retrofit re-sync case), and reproduces the title when supplied the same highlight text; the skill can also create a new tag+release for a version that has neither yet.

## Final Results

(filled in on completion)

## Progress

- [x] Phase 1: Author the Claude mirror SKILL.md
- [x] Phase 2: Author the Codex mirror SKILL.md
- [x] Phase 3: Register in tracking lists and docs

## Findings

### Review (2026-07-12, scaled-down single-lens architecture review — see note)

Ran a single Opus architecture-lens review (not the full 5-lens `/review-plan` gauntlet) given this is a doc-only skill addition with no runtime code and no bundled scripts — judged disproportionate to run 4 more high-reasoning Opus lenses on a markdown change. The architecture lens surfaced two real Important findings, both fixed before implementation:
1. **Idempotency vs. non-persisted highlight** — the plan originally claimed byte-identical title/body on re-sync, but the `<highlight>` is a fresh per-run human judgment with no persisted source of truth. Fixed by having the skill recover the existing release's highlight (`gh release view vX.Y.Z --json title`) on re-sync rather than re-drafting blind, and by scoping the idempotency guarantee to the body (always deterministic) vs. the title (deterministic only when the highlight is recovered/stable).
2. **Dual source-of-truth for PREV version** — Requirement 2 originally said "tag list *or* CHANGELOG ordering," an unresolved ambiguity. Fixed by making the tag list canonical, computed before any new tag this run creates.

A separate Explore pass found two additional registration points beyond the plan's original four: `scripts/delete-skills.sh`'s `SKEIN` array (added `release`) and `.env.example`'s `MANAGED_SKILLS` documentation (left untouched — already stale/incomplete for `grill`/`review-gauntlet`, and touching it would be scope creep beyond this plan).

### Code review (2026-07-12, `/code-review`, scaled to a single correctness-focused Sonnet pass given the doc-only diff)

One finder pass (git/gh command correctness against both new `SKILL.md` files) surfaced three real issues, all fixed in both mirrors:
1. **"Step 4" mislabel** — Step 2's parenthetical said tag creation happens "in Step 4" (the confirmation gate); it actually happens in Step 5. Fixed the cross-reference.
2. **PREV-tag self-link gap (the more serious one)** — the workflow never told the agent to exclude the target version's own tag from the sorted tag list before picking PREV, so a re-sync run (where `vX.Y.Z`'s tag already exists) could naively take the last sorted entry — the target tag itself — as PREV, producing a self-referential `compare/vX.Y.Z...vX.Y.Z` link. Fixed by adding an explicit exclusion instruction plus a worked example (`v0.5.1` excluded from the tag list → PREV resolves to `v0.5.0`).
3. **No whitespace-drift tolerance on header matching** — Step 1 required an exact `## [X.Y.Z] - date` match with no fallback for hand-edited formatting drift. Added a tolerant-retry-then-report-and-stop instruction.

Verified after fixes: `just check-prompt-parity` and `uvx pytest tests/parity/test_skill_md_presence.py -q` (14/14) both pass; the two mirrors remain semantically aligned (only the expected prose/idiom divergence the repo's parity convention allows).

### Phase 3 (2026-07-12)

Registered `release` in `scripts/check-prompt-parity.sh` (`MANAGED_SKILLS` default), `tests/parity/test_skill_md_presence.py` (`MANAGED_SKILLS` list), `README.md` (skill table row), `scripts/delete-skills.sh` (`SKEIN` array), and `docs/skills_architecture/20260522-design-claude-skills-architecture.md` (Skill Catalogue row, Output Contracts git-side-effects note, Invocation Mode section's `release` classification rationale, Trigger Phrases slash-command list). Verified: `just check-prompt-parity` passes; `uvx pytest tests/parity/test_skill_md_presence.py -q` passes 14/14 (13 existing + `release`).
