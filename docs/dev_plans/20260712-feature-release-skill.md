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

- [x] Write frontmatter: `name: release`, `description` describing the CHANGELOG→GitHub-release sync behavior with explicit trigger phrases ("cut a release", "publish this release", "sync release notes", "/release"), `argument-hint: "[version|latest|unreleased]"`, `disable-model-invocation: true`.
- [x] Write the workflow: parse CHANGELOG section (Requirement 1), determine PREV tag + compare link (Requirement 2), draft highlight (Requirement 3), confirm title+body+tag-push with the user before any git/gh mutation (Requirement 7 / repo CLAUDE.md), then tag+push if missing, then `gh release create` or `gh release edit` (Requirement 5).
- [x] Include the worked example from this session (v0.5.1's title/body) as a concrete illustration.

### Phase 2: Author the Codex mirror SKILL.md

**Impl files:** `plugins/skein-codex/skills/release/SKILL.md`
**Test files:** none
**Test command:** n/a

- [x] Mirror Phase 1's content with Codex's dispatch idiom and `$SKILL_DIR` path anchor (no bundled scripts, so this is mostly moot, but keep the anchor convention consistent with sibling skills for any future script needs).
- [x] No `disable-model-invocation` field (doesn't exist on Codex); add the one-line HTML-comment documenting the permanent Claude/Codex divergence, placed immediately after the frontmatter close.

### Phase 3: Register in tracking lists and docs

**Impl files:** `scripts/check-prompt-parity.sh`, `tests/parity/test_skill_md_presence.py`, `README.md`, `docs/skills_architecture/20260522-design-claude-skills-architecture.md`, `scripts/delete-skills.sh`
**Test files:** `tests/parity/test_skill_md_presence.py` (itself, once updated)
**Test command:** `just check-prompt-parity && python3 -m pytest tests/parity/test_skill_md_presence.py -q`

- [x] Add `release` to `MANAGED_SKILLS` default in `scripts/check-prompt-parity.sh`.
- [x] Add `"release"` to the `MANAGED_SKILLS` list in `tests/parity/test_skill_md_presence.py`.
- [x] Add a row to `README.md`'s skill table.
- [x] Add a row to the Skill Catalogue table in `docs/skills_architecture/20260522-design-claude-skills-architecture.md`, with Invocation Mode `user-invoked` (Claude) and a note on the Codex divergence — following the same reasoning discipline as the skill-invocation-mode-audit plan (Axis 1: nothing chains into `release`; Axis 2: "cut a release"/"publish this release" are command-name-adjacent, someone who says this already knows a release-cutting tool exists, so `release` is a genuine `disable-model-invocation` candidate on the same grounds as `plan-view`).
- [x] Add `release` to the `SKEIN` array in `scripts/delete-skills.sh` (the surgical-uninstall helper) — leave its pre-existing `review-gauntlet` omission alone, that's a separate gap out of this plan's scope.
- [x] `.env.example`'s documented `MANAGED_SKILLS` override example is already stale (11 names, missing `grill`/`review-gauntlet`) — out of this plan's scope to fully reconcile, but do not add to the staleness: leave it as-is rather than adding a 12th/13th/14th name to an already-incomplete example.

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

Shipped in two passes on `feature/skein-release-skill`: the base skill (Single-Version Mode: cut or re-sync one named version) landed first, then a follow-on pass added Audit Mode (`/release audit` — scans all tags/CHANGELOG versions repo-wide for `missing-tag`/`missing-release`/`drifted`/`no-changelog-entry`, reports a punch list, fixes opt-in via Single-Version Mode per selected version) and a `## What's New` summary paragraph to the canonical body shape, both requested after reviewing release-note patterns from three external repos (`pipecat-ai/pipecat-context-hub`, `vr000m/pipecat-local-tts-server`, `vr000m/pipecat-local-stt-server` — read-only `gh release list`/`view` lookups only, no changes made to those repos). Those repos' own tags all had matching releases (no missed-release case to observe live), but their bodies confirmed the "intro paragraph + itemized sections" pattern was a real, generalizable convention worth adopting, not a one-off. The `What's New` paragraph — like `<highlight>` — is a fresh per-run judgment call with no persisted source of truth other than the release body itself, so Step 3 recovers it on re-sync the same way it recovers the highlight (read the existing release body's `## What's New` block first, propose reusing it).

Not done in this plan: retrofitting the 11 already-canonicalized skein releases (v0.1.0–v0.5.1) to add a `## What's New` paragraph — those were fixed to the pre-What's-New canonical shape earlier in the same session, and adding a synthesis paragraph to each retroactively would be a separate, explicitly-scoped pass (out of this plan's acceptance criteria, which only covered the skill itself).

### Code review round 2 (2026-07-12, Audit Mode addition, scaled Sonnet correctness pass)

A second correctness pass targeting only the new Audit Mode section (Steps A1–A4) surfaced five real issues, three load-bearing (Audit Mode as originally drafted could not actually run), fixed in both mirrors:
1. **Invalid `gh` syntax** — `gh release list --json ...,body,...` doesn't exist; `gh release list --json` has no `body` field (verified against the installed `gh` version's accepted field list). Fixed: Step A1's release inventory is list-only (`tagName,name,isDraft`); full title/body is fetched per-candidate in Step A2 via `gh release view` instead.
2. **Undefined drift-comparison procedure** — Step A2 said releases must "match" the CHANGELOG without saying how, which in practice requires re-running Step 1's extraction logic and Step 3's What's-New-recovery logic per candidate. Fixed by spelling out the per-candidate procedure explicitly (one `gh release view` call, re-extract the CHANGELOG section, split the body, compare each part, including the compare-link's PREV).
3. **Classification gap** — the original 4-status scheme silently folded "tag with neither release nor CHANGELOG entry" into `missing-release`, which Step A4 would then try to "fix" via Single-Version Mode — which dead-ends without a CHANGELOG section to resolve. Fixed by adding a 5th status, `untracked-tag`, explicitly excluded from Step A4's fixable set, plus an explicit 5-row (T,R,C)→status truth table replacing the prose-only enumeration.
4. **Adjacent-release staling on batch fix** — fixing a `missing-tag` version inserts a tag that can change an already-`ok` neighboring release's correct PREV, silently staling that neighbor's compare link with no mechanism to catch it. Fixed by adding an explicit re-run-audit instruction to Step A4 whenever a batch includes a `missing-tag` fix.
5. **Unstated platform invariant** — the classification table implicitly relied on "a release can't exist without its tag" (`release∃ ⇒ tag∃`) without stating it. Fixed by stating it explicitly ahead of the classification table, which also drops the truth table from 8 rows to the 5 that are actually reachable.

Verified after fixes: mirrors remain structurally identical (`diff` on heading structure, exit 0); `just check-prompt-parity` and `uvx pytest tests/parity/test_skill_md_presence.py -q` (14/14) both pass.

### Independent Codex review (2026-07-12, `codex:codex-rescue`, read-only)

At the user's request, dispatched an independent Codex review of both `SKILL.md` mirrors (no prior sight of this plan's own review history) via `codex:codex-rescue`. It surfaced 7 findings, 3 "blocker" and 4 "should-fix," all real and empirically verified before fixing (not taken on faith):

1. **`gh release view --json title` is invalid** (blocker) — `gh release view --json` exposes the title as field `name`, never `title` (`title` is only a `create`/`edit` flag). Verified live against the installed `gh` CLI: `gh release view v0.5.1 --repo vr000m/skein --json title` returns `Unknown JSON field: "title"`; `--json name` succeeds. This was a real bug in both mirrors' Step 3.1 and Audit A2 since the first draft — every re-sync and every `ok`/`drifted` audit candidate would have failed outright. Fixed: both call sites now use `--json name,body` and parse `name`.
2. **Version-string normalization gap in Audit Mode** (blocker) — A1/A2 unioned tag names (`vX.Y.Z`), release `tagName`s (`vX.Y.Z`), and CHANGELOG headers (`X.Y.Z`) without normalizing the `v` prefix, so a real release would split into a false `missing-tag` + false `untracked-tag`/`no-changelog-entry` pair instead of one `ok` row. Fixed: added an explicit normalization step (strip `v` for the union key, retain it for actual git/gh commands).
3. **Tag reuse doesn't verify remote existence** (blocker) — Step 5's "if the tag already exists, reuse it" checked only `git rev-parse` (local), never whether the tag was actually pushed to origin; Step 6 then ran `gh release create` with no `--verify-tag` safeguard. Verified live: `gh release create --help` confirms `--verify-tag` exists and "aborts in case the git tag doesn't already exist in the remote repository." Fixed: Step 5 now checks `git ls-remote --tags origin` and pushes an unpushed local tag before Step 6 runs; Step 6 adds `--verify-tag` as a defensive backstop.
4. **Local-only tag inventory contradicts the stated platform invariant** (should-fix) — Audit A1 used local `git tag --list` while claiming `release∃ ⇒ tag∃`, but a clone with stale/unfetched refs could present a release with no matching local tag, a case the classification table had no row for. Fixed: A1 now runs `git fetch --tags origin` first, and the invariant note clarifies it bounds the remote only.
5. **`isDraft` was gathered but never used** (should-fix) — a draft release with a matching tag+CHANGELOG could be silently classified `ok` and re-sync would edit-but-not-publish it, undefined behavior against the skill's stated purpose. Fixed: added a `drafted` status, checked before `ok`/`drifted`, explicitly excluded from Step A4's auto-fixable set.
6. **`gh release view` failure treated as "not found" unconditionally** (should-fix) — Step 6 didn't distinguish a genuine 404 from auth/network/permission errors, risking a duplicate-release attempt after a transient failure. Verified live: `gh release view v99.99.99` fails with stderr exactly `release not found`. Fixed: Step 6 now checks for that exact message before treating absence as confirmed; any other failure stops and reports the error.
7. **Compare-link comparison left ambiguous in Audit Mode** (should-fix) — the `ok`/`drifted` rule didn't specify how to validate the trailing compare line when no PREV exists, so a first release with a stray compare link could still read as passing. Fixed: the rule now requires the line be present-and-correct when a PREV exists, or **absent entirely** when it doesn't.

All 7 fixes applied identically to both mirrors. Verified: no stray `--json title` remains (`grep` across both files, zero hits); mirrors remain structurally identical; `just check-prompt-parity` and `uvx pytest tests/parity/test_skill_md_presence.py -q` (14/14) both pass. None of the 7 findings required a genuine judgment call from the user (all were empirically checkable facts or low-ambiguity design gaps), so fixes were applied directly rather than routed through `skein:grill`.

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

### Third review: Codex adversarial review + `/code-review` (2026-07-12, dual-lens on the finished branch)

Ran `/codex:adversarial-review` (challenge-framed, questioning design choices) and `/code-review` (medium effort, 8 finder angles + 1-vote verify) as parallel independent passes against the finished branch. Codex surfaced one no-ship-severity finding; `/code-review` surfaced three confirmed cleanup findings and one plausible-but-unactioned one. All confirmed findings fixed identically in both mirrors:

1. **[Codex, high, no-ship] Release tag target was never validated.** Step 5 created `vX.Y.Z` at whatever `HEAD` happened to be, with no check that the worktree was clean or that `HEAD` was the commit the user actually intended to release — running `/release` from an unrelated checkout could permanently tag and publish the wrong commit. Fixed: Step 4 now runs `git status --porcelain` (stops on a dirty worktree) and records `git rev-parse HEAD` plus the current branch before asking for confirmation, and shows both to the user. Step 5's tag-reuse path (existing-tag-on-origin case) now dereferences the tag (`git rev-parse "vX.Y.Z^{commit}"`) and compares it against that recorded `HEAD` SHA before reusing it, refusing silently on any mismatch (ties into the pre-existing Edge Cases bullet on unexpected tag targets).
2. **[/code-review, confirmed] Redundant `gh release view` in Step 3.1 → Step 6.** Step 3.1 already made the existence-check call (`--json name,body`) to recover title/body on re-sync; Step 6 re-ran an unqualified `gh release view` purely to decide create-vs-edit, against unchanged state. Fixed: Step 3.1 now records that outcome explicitly; Step 6 reuses it instead of re-querying.
3. **[/code-review, confirmed] Redundant `gh release view` in Audit Mode's fix pass.** Step A2's per-candidate classification fetch (`ok`/`drifted`) and Step A4's subsequent Single-Version Mode fix pass (Step 3.1) both fetched the same release data for any `drifted` version selected to fix. Fixed: A4 now instructs feeding Step 3.1 the `name`/`body` A2 already fetched for `drifted` candidates (`missing-tag`/`missing-release` still need their own call — A2 never fetches content for those).
4. **[/code-review, confirmed] Stale skill count in `scripts/delete-skills.sh`.** Header comment said "12 skein-managed skills"; the `SKEIN` array had grown to 13 with `release`'s addition. Fixed the count.
5. **[/code-review, plausible, not fixed] Audit Mode's classification logic (Step A2's truth table, draft pre-check, ok/drifted comparison) is expressed as prose rather than a bundled script**, unlike `deep-review`/`review-plan`/`review-gauntlet`'s scripted classification. Verified as only a partial match to that convention — those scripts operate on already-structured JSON with mechanical dedup, a materially different task from Audit Mode's live-`gh`-call-plus-judgment comparison — and the cited risk (an agent skipping the draft pre-check) is a generic literalness concern with no reproduced incident. Left as prose; converting it would be a structural redesign disproportionate to a PLAUSIBLE-confidence finding.

Verified after fixes: `bash scripts/check-prompt-parity.sh` passes; `diff` between the two mirrors shows only the pre-existing, documented harness-specific wording divergence (invocation-mode framing) — no new unintended drift introduced by these fixes.

### Fourth review: `/deep-review` (4 lenses) + `/security-review` (2026-07-12, before merge)

Ran before merging PR #18. Four fresh-context lenses (Logic, Security, Architecture opus/high; Documentation haiku/low) plus a separate security-review vulnerability sweep with false-positive-filter verification, all against the full `db91aa3..c62b560` branch diff.

1. **[Logic, Critical] Third review's own SHA-verification fix broke re-sync.** Step 4/5's tag-target check (added in the third review round above, to close Codex's no-ship finding) compared an *existing* tag's commit against current `HEAD` — but re-sync and any Audit-Mode fix of a historical version target a tag that legitimately points at an old commit, essentially never `HEAD`. As written, every re-sync/retrofit run — the skill's own documented primary use case and Worked Example — would falsely abort with "tag points at a different commit." Fixed by splitting the two cases in Step 4/5: a genuinely **new** tag still requires a clean worktree and HEAD-equality (closing the original Codex concern); reusing an **existing** tag now shows the user its actual commit + subject line (`git log -1 --format='%h %s'`) for their own judgment, with no mechanical HEAD comparison.
2. **[Security lens + security-review sweep, Important/confidence-7] Command injection via unescaped CHANGELOG interpolation.** Both an independent deep-review security lens and a separate security-review vulnerability-identification pass (with its own false-positive-filter verification) independently converged on the same issue: Step 5's `git tag -m "<repo> vX.Y.Z"` and Step 6's `gh release create/edit --title "<title>" --notes "<body>"` interpolated externally-derived text into double-quoted shell arguments. `<body>` is verbatim CHANGELOG.md markdown, which routinely contains backticks/`` ` ``/`$(...)` code spans (the skill's own Worked Example body does) — inside a double-quoted shell string these undergo command substitution, so a crafted CHANGELOG section could execute arbitrary code with the operator's live `gh`/`git` credentials, and even an ordinary benign code span would break the command. The security-review false-positive filter confirmed this at 7/10 confidence (just under that skill's own 8+ auto-report bar, but the mechanism is concrete: an LLM agent literally translating `<body>` into a double-quoted string it executes via a shell tool). A second candidate finding (CHANGELOG content not wrapped in `<untrusted-content>` per the `deep-review` skill's own precedent) was filtered as a **false positive** — folds entirely into this finding with no standalone exploitable impact, and echoing PR-editable content into an AI agent's context is not itself a vulnerability per the security-review skill's own precedent #14. Fixed: switched to `gh release create/edit --notes-file <path>` and `git tag -a ... -F <path>` (out-of-band, no shell re-parsing) and single-quoted `--title` (no file-based equivalent exists for it in `gh`).
3. **[Logic, Minor] PREV-tag resolution not filtered to `v*` tags** — `git tag --list --sort=v:refname` could let a stray non-version tag (e.g. `nightly`) land in an implementation-defined sort position and get picked as a garbage PREV. Fixed: `git tag --list 'v*' --sort=v:refname`. (Audit Mode's own tag inventory in Step A1 intentionally stays unfiltered — it needs to surface non-standard tags as `untracked-tag` findings, a different concern from PREV resolution.)
4. **[Logic, Minor] `## What's New` recovery boundary undefined without a trailing `###`.** The recovery rule named only "the next `###` heading" as the terminator; a body with no trailing subsections had no defined boundary, risking over-capture of the CHANGELOG content or compare link. Fixed: terminator is now the first of {next `###`, next `##`, the `**Full diff:**` line, EOF}.
5. **[Architecture, Important] `scripts/delete-skills.sh`'s `SKEIN` array had independently drifted** — missing `review-gauntlet` (13 entries vs. 14 actual skills), a gap the existing two-way parity test (`tests/parity/test-managed-skills-parity.sh`) didn't cover since it only cross-checked the other two managed-skill lists. Fixed: added the missing entry, extended the test to a three-way check (`MANAGED_SKILLS` bash default, `MANAGED_SKILLS` python list, and `SKEIN` bash array all cross-verified).
6. **[Documentation, Important] `README.md`'s skill-table entry omitted that the `## What's New` paragraph is optional**, contradicting both SKILL.md mirrors and the front-matter description. Fixed the wording.

Verified after fixes: `bash scripts/check-prompt-parity.sh`, `bash tests/parity/test-managed-skills-parity.sh` (now three-way), and `uvx pytest tests/parity/test_skill_md_presence.py -q` (14/14) all pass; `diff` between the two SKILL.md mirrors shows only the pre-existing documented wording divergence — no new unintended drift.
