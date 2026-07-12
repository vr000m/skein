---
name: release
description: "Cuts or re-syncs a GitHub release from a CHANGELOG.md section (Keep a Changelog format) in one canonical title+body shape: title `<repo> vX.Y.Z — <highlight>`, body = the section's content with its `## [X.Y.Z] - date` header stripped, plus a trailing `**Full diff:**` compare link. Use when the user says 'cut a release', 'publish this release', 'sync release notes', 'make a github release', or '/release'."
argument-hint: "[X.Y.Z|latest|unreleased]"
---

<!-- invocation-mode divergence: this skill is user-invoked-only on the Claude mirror (disable-model-invocation: true) — it pushes a git tag and publishes a public GitHub release, an externally-visible, hard-to-reverse action that should not fire off conversational context alone. Codex CLI has no equivalent front-matter suppression as of this writing, so it remains autonomously invocable here — a harness limitation, not an oversight. See docs/dev_plans/20260712-feature-release-skill.md. -->

# Release Skill

Derive a GitHub release's title and body from a `CHANGELOG.md` section, then create or re-sync the git tag and GitHub release to match. This is the single owner of skein's release-note shape — before this skill existed, every release was a hand-typed `gh release create --notes "..."` call, and skein's own 11 releases drifted into three visibly different shapes as a result (see `docs/dev_plans/20260712-feature-release-skill.md`).

Tag pushes and release publishes are external, hard-to-reverse actions — always confirm the computed title and body with the user before running any mutating `git`/`gh` command, on both harnesses.

## Usage

- `/release 0.6.0` — cut or re-sync the release for `CHANGELOG.md`'s `## [0.6.0]` section
- `/release latest` / `/release unreleased` — same, targeting the topmost dated section in `CHANGELOG.md` (skipping any `## [Unreleased]` heading, which has no release yet)
- `/release` with no argument — same as `latest`

## Canonical Format

- **Title**: `<repo> vX.Y.Z — <highlight>`. `<repo>` is the GitHub repo name (from `git remote get-url origin`). `<highlight>` is a short (under ~60 chars) one-line summary of the version's single biggest change — draft this yourself by reading the section body; do not attempt to mechanically extract it from bullet text.
- **Body**: the CHANGELOG section's content *below* its `## [X.Y.Z] - date` header — the `### Added`/`### Changed`/`### Fixed`/etc. subsections verbatim, header stripped (GitHub already shows the tag and date) — followed by a blank line and:
  ```
  **Full diff:** https://github.com/<owner>/<repo>/compare/vPREV...vNEW
  ```
  Omit the compare line entirely when there is no PREV tag (the first-ever release).

## Step 1: Resolve the Target Version and Section

1. Read `CHANGELOG.md`. Find the target `## [X.Y.Z] - date` header:
   - Explicit `X.Y.Z` argument → match that exact version.
   - `latest`/`unreleased`/no argument → the topmost `## [X.Y.Z] - date` header (skip any leading `## [Unreleased]` heading — it has no date and no release yet; if the file has no dated section at all, stop and tell the user).
2. Extract everything between that header and the next `## [` header (or EOF). Strip the header line itself and any leading/trailing blank lines. This is the raw body.
3. If the target section is empty (a version bump with no recorded changes), stop and tell the user — do not publish an empty-body release silently.
4. If no header matches exactly, retry tolerating whitespace/punctuation drift (extra spaces, en dash vs. hyphen) before giving up — this is a cross-skill format contract shared with `skein:update-docs` (see Execution Model below), and CHANGELOG.md is hand-edited, so minor formatting drift is expected. If still no match, stop and report the exact version string you searched for rather than guessing at loosely-matched boundaries.

## Step 2: Determine the Previous Version

Run `git tag --list --sort=v:refname` and take the snapshot **before** any new tag this run might create (tag creation happens in Step 5, not here — this snapshot must not include a tag this same run is about to push). Exclude the target version's own tag `vX.Y.Z` from the list if present (the re-sync case, where the tag already exists) — PREV must never resolve to the target version itself. From what remains, PREV is the highest tag by semver order that sorts below `vX.Y.Z`. Tags are the canonical ordering source, not CHANGELOG section order, because the two can disagree in either direction: a CHANGELOG section can be written before its tag is pushed, and an old tag can predate CHANGELOG coverage entirely (skein's own `v0.2.x`/`v0.1.0` had no changelog-derived notes at release time). If no such tag exists after excluding the target, this is the first-ever release — omit the compare line (Step 3).

**Worked example (re-sync case):** target `v0.5.1`, sorted tag list `v0.1.0 v0.2.0 v0.2.1 v0.2.2 v0.2.3 v0.2.4 v0.3.0 v0.4.0 v0.4.1 v0.5.0 v0.5.1`. Exclude `v0.5.1` itself → PREV is `v0.5.0`, the entry immediately before it in sorted order.

## Step 3: Compose Title and Body

1. If a release for `vX.Y.Z` already exists (re-sync case), run `gh release view vX.Y.Z --json title` first and try to recover the existing highlight from its title (the text after the em dash). Propose reusing it rather than re-drafting from scratch — this is what makes re-sync reproducible in practice, since the highlight has no other persisted source of truth. Otherwise (new release, or the existing title doesn't match the `vX.Y.Z — <highlight>` shape), read the extracted section body (Step 1) and draft the one-line highlight yourself — the version's single biggest change, in your own words. Either way, state the highlight to the user as part of the confirmation in Step 4 and let them override it. The **body** is fully deterministic and reproducible on its own; the **title** is only reproducible when the highlight is recovered or re-supplied identically.
2. Compose the title: `<repo> vX.Y.Z — <highlight>`.
3. Compose the body: the Step 1 body, then (if a PREV tag exists) a blank line and `**Full diff:** https://github.com/<owner>/<repo>/compare/vPREV...vNEW`.

## Step 4: Confirm Before Mutating

Tag pushes and release publishes are external, hard-to-reverse actions — show the user the computed title and full body, state whether this is a **new tag+release** or a **re-sync of an existing release**, and get explicit confirmation before running any `git tag`/`git push`/`gh release` command. Do not proceed silently.

## Step 5: Create or Re-Sync the Tag

- If `git rev-parse --verify --quiet "refs/tags/vX.Y.Z"` finds nothing, create the tag and push it: `git tag -a vX.Y.Z -m "<repo> vX.Y.Z"` then `git push origin vX.Y.Z`.
- If the tag already exists, reuse it — do not re-create or force-move an existing tag.

## Step 6: Create or Edit the Release

- If `gh release view vX.Y.Z` fails (no release for this tag yet), run `gh release create vX.Y.Z --title "<title>" --notes "<body>"`.
- If it succeeds (release already exists — the retrofit/re-sync case), run `gh release edit vX.Y.Z --title "<title>" --notes "<body>"` instead. This makes the skill idempotent on body content and safe to re-run against an already-published release to bring it into the canonical shape.

Report the final release URL to the user.

## Worked Example

This skill's own canonical format was established by manually retrofitting skein's `v0.5.1` release in the same session that produced this skill:

- **Title**: `skein v0.5.1 — skill invocation-mode audit`
- **Body**:
  ```
  ### Added
  - **Skill invocation-mode classification (docs, meta).** `docs/skills_architecture/20260522-design-claude-skills-architecture.md` gains an Invocation Mode column on the Skill Catalogue table (now covering all 13 skills, up from 11) and a new `## Invocation Mode` section documenting the `disable-model-invocation: true` mechanism and the two-axis (chained-into / independently content-triggered) classification discipline for future skills.

  ### Changed
  - **`skein:plan-view` is now user-invoked-only on Claude.** `disable-model-invocation: true` added to the Claude `SKILL.md` front-matter — the only skill of 13 to clear both classification axes (see `docs/dev_plans/20260711-chore-skill-invocation-mode-audit.md`). The Codex mirror has no equivalent front-matter suppression, so it gets a one-line documented-divergence comment instead and remains autonomously invocable there.

  **Full diff:** https://github.com/vr000m/skein/compare/v0.5.0...v0.5.1
  ```

## Execution Model

Unlike `rfc-finder`/`update-docs` (read-only, delegated fact-gathering), this skill runs entirely inline in the main context — no delegating subagent, even on harnesses where `spawn_agent` is available. It owns an irreversible external mutation (tag push, release publish) gated on an explicit user-confirmation step (Step 4); a subagent cannot hold that confirmation gate on the caller's behalf.

It also has one **data-contract** dependency worth naming, distinct from a call-chaining edge: it parses the exact Keep a Changelog `## [X.Y.Z] - date` shape that `skein:update-docs` produces/maintains in `CHANGELOG.md`. If either skill's format assumption drifts, this skill silently mis-parses (empty body, wrong header strip). No skill calls another here — the two only share a format contract.

## Edge Cases

- **No `CHANGELOG.md`**: stop and tell the user — this skill has no fallback source for release notes.
- **Version argument doesn't match any CHANGELOG section**: stop and report the mismatch; do not guess the nearest version.
- **`gh` not installed or not authenticated**: stop and tell the user to authenticate (`gh auth login`) before retrying.
- **Target version's tag exists but points at an unexpected commit**: flag this to the user before reusing it — do not silently move or re-tag.
