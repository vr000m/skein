---
name: update-docs
description: Syncs project documentation with code changes on the current branch by checking dev plans, changelogs, READMEs, AGENTS.md, and PR descriptions for staleness against the actual diff, then offering targeted updates. Use after finishing implementation work, before creating or merging a PR, or when the user says "update docs" or "/update-docs".
argument-hint: "[--apply] [--pr NUMBER]"
---

# Update Docs Skill

Detect stale documentation and update it to match the current branch's code changes.

## Usage

- `/update-docs` - Audit docs, show what's stale, offer to fix
- `/update-docs --apply` - Audit and apply all updates without prompting
- `/update-docs --pr 42` - Also update the PR description for PR #42

## When to Use

Run this after finishing implementation work on a feature branch, before creating or merging a PR. It catches the docs we routinely forget:
- Dev plan checkboxes left unchecked
- Changelog missing the new version entry
- README not reflecting new commands, config, or architecture changes
- PR description that doesn't match the final state of the work

## Phases 1–3: Gather Context, Audit Documents, Report Findings (Subagent)

These phases involve heavy git diffs, file reads, and cross-referencing — delegate them to a subagent to keep the main context lean.

**Use the Agent tool** with `subagent_type: "general-purpose"` and `model: "sonnet"` to spawn a single subagent. Pass it the following self-contained prompt (fill in the `{{PLACEHOLDERS}}`):

````
You are auditing project documentation for staleness against the current branch's code changes.

## Inputs

- **Current branch**: {{CURRENT_BRANCH}}
- **Base branch**: {{BASE_BRANCH}}
- **PR number** (if any): {{PR_NUMBER or "none"}}
- **Arguments**: {{RAW_ARGS}}

## Phase 1: Gather Context

1. **Detect the diff range:**

   **If on a feature branch** (current != base):
   ```
   MERGE_BASE=$(git merge-base "{{BASE_BRANCH}}" HEAD)
   git log --oneline --no-merges "$MERGE_BASE..HEAD"
   git diff "$MERGE_BASE..HEAD" --stat
   git diff "$MERGE_BASE..HEAD"
   ```
   If `git rev-list --count "$MERGE_BASE..HEAD"` is `0`, return: "Nothing to document — branch is up to date with {{BASE_BRANCH}}."

   **If on the base branch itself**:
   Use the most recent commits since the last doc-touching commit as the diff range:
   ```
   LAST_DOC_COMMIT=$(git log --diff-filter=AMR --format='%H' -1 -- '*.md' 'docs/**')
   RANGE="${LAST_DOC_COMMIT:-HEAD~5}..HEAD"
   git log --oneline --no-merges $RANGE
   git diff $RANGE --stat
   git diff $RANGE
   ```

2. **Identify the change summary:**
   - Files added, modified, deleted
   - New CLI commands, flags, or config options
   - New/changed public APIs (classes, methods, functions)
   - New dependencies
   - Test files added or modified

3. **Discover documentation files in the project:**
   Scan for these (all optional — skip any that don't exist):
   - `docs/dev_plans/*.md` — development plans
   - `CHANGELOG.md` — changelog
   - `README.md` or `docs/README.md` — project README
   - `CLAUDE.md` — Claude Code project instructions
   - `AGENTS.md` — Codex/agent instructions
   - Active PR description (if PR number provided or branch has an open PR)

## Phase 2: Audit Each Document

For each discovered document, compare its content against the branch diff and produce findings.

### Dev Plans (`docs/dev_plans/*.md`)
Look for the plan most relevant to the current branch (match by branch name in header, or by recency).
Check:
- [ ] **Status header** — should it be updated? (e.g., "In Progress" to "Complete", version bumped)
- [ ] **Unchecked boxes** — are there checklist items that the diff shows are now done?
- [ ] **Missing items** — did the implementation add work not in the plan? (new files, phases, or decisions)
- [ ] **Stale references** — do file paths, method names, or config keys in the plan match the code?
- [ ] **Stale descriptions** — do technical-spec tables, authority decisions, and prose summaries still accurately describe what each file does in the current diff? Re-read each row/statement against the actual code, not just the path.
- [ ] **Stale "PR open" claims** — grep the plan body for lines containing `PR #\d+` together with `open`, `pending`, `in review`, or `reviews pending`, ignoring lines inside fenced code blocks. Extract the unique PR numbers from those lines into the audit's shared PR set (see below), then probe each once with `gh pr view N --json state,mergedAt`. If MERGED or CLOSED, flag it so the plan's PR-status text and primary `**Status**:` / `**Status:**` header can be refreshed. When locating the primary status header for the refresh, skip any `**Status**:` / `**Status:**` occurrence inside a fenced code block and prefer the first occurrence in normal prose near the top of the file.

### Dev Plans Index (`docs/dev_plans/README.md` if present)

Read the index **unconditionally** — it is not tied to any one branch, so the primary-plan gate above must not exclude it. Skip only if the file does not exist.

**Shared PR set:** Deduplicate PR numbers across both the per-plan "Stale PR open" check and the index "Stale PR refs" check below. Build one set of unique PR numbers from all matching lines across all audited files, then call `gh pr view N --json state,mergedAt` once per number and reuse the result.

Check:
- [ ] **Status mismatch** — for every row in lifecycle tables or sections (for example Current Tasks / Completed Tasks, In Progress / Planned / Shipped), open the linked plan file and compare the row's status text to the plan's first primary status header (`**Status**:` or `**Status:**` in normal prose near the top of the file; skip occurrences inside fenced code blocks). Flag rows where the index status no longer matches the plan header.
- [ ] **Lifecycle placement** — infer lifecycle placement from the index's existing section headings. A row whose linked plan's primary status starts with "Shipped" or "Complete" should live in the completed/shipped section; active statuses such as "In Progress", "In Review", or "Not Started" should live in the active/planned section. If the index distinguishes Planned from In Progress (three-bucket taxonomy), match the plan's status to the corresponding bucket precisely. If the index structure is unfamiliar, flag the mismatch instead of inventing new sections.
- [ ] **Stale PR refs** — for any row or status cell containing `PR #N` together with `open`, `pending`, `in review`, or `reviews pending`, add the unique PR numbers to the shared PR set above and use the probed result. If MERGED or CLOSED, flag it.
- [ ] **Broken links** — if a row points to a plan file that no longer exists or has been renamed, flag it.

#### Sibling-plan audit (extend the audit pass — do NOT add a parallel grep)

**Only run if the invocation is tied to a dev plan** (i.e., a primary plan was located above). Skip entirely otherwise.

**Audit scope:** Scan `docs/dev_plans/*.md` only (or the project's configured plans directory). **Exclude `tests/fixtures/dev_plans/` by default** — fixture trees are not real plans and must not pollute sibling matches.

**Determine the primary plan's slug:**
1. If the primary plan filename matches `YYYYMMDD-<type>-<rest>.md` (where `<type>` is one of `feature`, `bug`, `chore`, `docs`, `design`, `refactor`), strip the date prefix and the leading type token — **but only when the remainder has ≥2 hyphen-delimited tokens**. If stripping would leave fewer than two tokens (e.g. `20260504-feature-feature.md` where the second token is genuinely `feature`), keep the type token in the slug. The remaining hyphen-delimited string is the **tokenisation slug**. Example: `20260504-feature-skill-improvements-from-usage-report.md` → slug `skill-improvements-from-usage-report`, tokens `[skill, improvements, from, usage, report]`.
2. If the filename does NOT match the `YYYYMMDD-` convention (hand-named plan), use the full basename minus `.md` as the slug. Log a one-line note: `audit: filename-convention fallback used for <filename>`.

**Slug match (for each candidate sibling plan, excluding the primary):**
- Tokenise the sibling's slug by the same rule above.
- A sibling matches if: (a) its full stripped slug equals the primary's full stripped slug, OR (b) any contiguous substring of ≥3 hyphen-delimited tokens from the primary's slug appears in the sibling's token sequence.
- No stop-word filtering — every token is significant.
- **Recall trade-off (deliberate):** ≥3 contiguous tokens means siblings sharing only 2 tokens (e.g. `[skill, improvements]`) are NOT slug-matched even when they're plausibly related. This is intentional — slug match is a high-precision signal; the **component match** (primary's `Files to Modify` paths → sibling body) is the recall safety net for short-slug cases. If both miss, the relationship is genuinely tenuous and the audit's silence is the right answer.

**Component match (only when the primary plan has a `Files to Modify` section):**
- Extract all file paths listed under `Files to Modify` in the primary plan.
- For each sibling plan, do a case-insensitive substring search: check whether any of those paths appears anywhere in the sibling's body text.
- If the primary plan has no `Files to Modify` section, skip component match entirely; slug match still runs.

**Surfacing (non-blocking):**
- If any sibling matches (by slug OR component), print:
  ```
  candidate sibling plans — also touch?
    <relative-path>  [slug match | component match | both]
  ```
  Then proceed; do not halt.
- If no siblings match, print the sentinel exactly:
  ```
  audit: no sibling plans matched
  ```

**Commit-preamble:**
- For each candidate sibling that was surfaced but NOT updated in this run, append to the commit-message preamble:
  ```
  skipped: <slug> (<reason>)
  ```
  Example reason: "not updated — no related changes in this diff".
- When no candidates were surfaced, include no audit lines in the preamble.

#### Sibling-plan audit — worked example

**Primary plan:** `docs/dev_plans/20260504-feature-skill-improvements-from-usage-report.md`
- Date-prefix stripped: `feature-skill-improvements-from-usage-report`
- Type-token stripped: `skill-improvements-from-usage-report`
- Tokens: `[skill, improvements, from, usage, report]`

**Primary plan's `Files to Modify`:**
```
- .claude/skills/update-docs/SKILL.md
- .claude/skills/deep-review/SKILL.md
- .claude/skills/deep-review/rubric.md
```

**Candidate sibling A:** `docs/dev_plans/20260301-chore-usage-report-cleanup.md`
- Stripped slug: `usage-report-cleanup`, tokens: `[usage, report, cleanup]`
- Slug check: contiguous 3-token window `[usage, report]` is only 2 tokens — no 3-token window overlaps. **No slug match.**
- Component check: body of sibling A contains the string `update-docs/SKILL.md` (case-insensitive). **Component match.**

**Candidate sibling B:** `docs/dev_plans/20260210-feature-skill-improvements-deep-review.md`
- Stripped slug: `skill-improvements-deep-review`, tokens: `[skill, improvements, deep, review]`
- Slug check: primary tokens `[skill, improvements, from]` (3-token window) — not in sibling. Primary tokens `[skill, improvements]` — only 2 tokens. Try `[skill, improvements, from, usage, report]` substring in sibling's `[skill, improvements, deep, review]`: the 3-token window `[skill, improvements, from]` is not present. But `[skill, improvements]` matches the first two tokens of sibling — only 2, no match. **No slug match** (no 3-token contiguous overlap).
- Component check: body of sibling B contains the path `.claude/skills/deep-review/rubric.md`. **Component match.**

**Output printed:**
```
candidate sibling plans — also touch?
  docs/dev_plans/20260301-chore-usage-report-cleanup.md  [component match]
  docs/dev_plans/20260210-feature-skill-improvements-deep-review.md  [component match]
```

**Commit-message preamble lines appended (if neither sibling was updated):**
```
skipped: usage-report-cleanup (not updated — no related changes in this diff)
skipped: skill-improvements-deep-review (not updated — no related changes in this diff)
```

### Changelog (`CHANGELOG.md`)
Check:
- [ ] **Missing version section** — if the branch introduces a version bump (check `pyproject.toml`, `package.json`, `Cargo.toml`, `version.py`, etc.), is there a corresponding `## [x.y.z]` section?
- [ ] **Undocumented changes** — are there Added/Changed/Fixed/Removed items from the diff not reflected in the changelog?
- [ ] **Format consistency** — does the new entry follow the same style as existing entries (Keep a Changelog, bullet style, etc.)?

### README (`README.md` or `docs/README.md`)
Check:
- [ ] **New commands/flags** — if the diff adds CLI commands or flags, are they documented?
- [ ] **Architecture changes** — if the diff adds new modules, services, or significant components, does the architecture section reflect them?
- [ ] **Project structure** — if the diff adds new directories or files mentioned in a project structure tree, is the tree updated?
- [ ] **Setup/install changes** — if dependencies changed, are install instructions still correct?
- [ ] **New tools/APIs** — if new MCP tools, API endpoints, or public interfaces were added, are they listed?

### CLAUDE.md
Check:
- [ ] **New commands** — if the diff adds CLI commands or dev workflow commands, are they in the Commands section?
- [ ] **Versioning** — if version locations changed, is the Versioning section updated?
- [ ] **Project layout** — if new directories or key files were added, is the layout tree updated?

### AGENTS.md
Check:
- [ ] **New commands** — if the diff adds CLI commands, build steps, or dev workflow commands, are they documented?
- [ ] **Project layout** — if new directories or key files were added, is the layout tree updated?
- [ ] **Tool/API changes** — if new tools, endpoints, or public interfaces were added, are they listed?
- [ ] **Skill triggers and routing** — if skills were added/renamed/removed, does `AGENTS.md` reflect accurate trigger rules and skill paths?
- [ ] **Codex instruction sections** — if execution norms changed, are sections like editing constraints, formatting rules, and collaboration mode still accurate?
- [ ] **Tooling assumptions** — if commands were changed (e.g., `rg` vs alternatives, test/lint commands), does `AGENTS.md` still describe the preferred tools and fallbacks?
- [ ] **Cross-agent consistency** — if both `AGENTS.md` and `CLAUDE.md` exist, do shared command examples and project-layout statements agree?

### PR Description
Only checked if a PR number is provided or the branch has an open PR. Detect via:
```
PR_NUMBER=$(gh pr view --json number -q .number 2>/dev/null)
```
Graceful fallback:
```
PR_NUMBER=$(gh pr list --head "$(git branch --show-current)" --json number,isDraft -q '.[0].number' 2>/dev/null)
```
If `gh` is not installed or not authenticated, skip PR checks and note it in the report.
Check:
- [ ] **Summary** — does the PR summary accurately describe all commits on the branch?
- [ ] **Test plan** — does the PR mention how changes were tested?
- [ ] **Completeness** — are all significant changes mentioned (not just the last commit)?

## Phase 3: Return Structured Report

Return your findings in exactly this format (no other output):

```
## Documentation Audit

**Branch:** <branch> (<N> commits ahead of <base>)
**Files changed:** <N> files (+X, -Y)

### <Doc path>
- [ ] <finding 1>
- [ ] <finding 2>

### <Doc path>
- (up to date, no changes needed)
```

Include every discovered doc file in the report, even if it's up to date.
````

### Pre-flight (main context)

Before spawning the subagent, the main context must:

1. Detect the base branch:
   ```
   BASE=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
   if [ -z "$BASE" ]; then
     if git show-ref --verify --quiet refs/heads/main; then BASE=main
     elif git show-ref --verify --quiet refs/heads/master; then BASE=master
     else BASE=""; fi
   fi
   # If neither origin/HEAD nor a local main/master exists, leave BASE empty
   # rather than falling back to the lexicographically-first local branch
   # (which would spuriously match the current feature branch on single-branch repos).
   CURRENT=$(git branch --show-current)
   ```
2. Detect PR number (if `--pr` flag or branch has an open PR).
3. Fill in the placeholders and spawn the subagent.
4. Present the subagent's structured report to the user.

## Phase 4: Apply Updates

If `--apply` was passed, or the user confirms, apply the updates. **Always show the report (Phase 3) first**, even in `--apply` mode, so the user sees what will change.

1. Edit each document using the Edit tool (prefer surgical edits over full rewrites)
2. For dev plans: check boxes, update status, add missing items; refresh stale "PR #N open/pending" text where the PR has merged
3. For the dev-plans index (`docs/dev_plans/README.md`): move rows between the index's **existing** lifecycle sections to match each linked plan's primary `**Status**:` / `**Status:**` header, and refresh stale PR refs. If the target section doesn't exist in the current index, leave the row in place and report the mismatch — never create a new lifecycle section in `--apply` mode.
4. For changelog: insert the new version section following existing format exactly
5. For README: add missing sections/entries where appropriate
6. For CLAUDE.md: update commands, layout, or versioning sections
7. For AGENTS.md: update commands, layout, or tool/API sections
8. For PR description: use `gh pr edit --body` to update
9. **Verify each edit**: re-read the modified file after editing to confirm the change landed correctly

After applying, show a summary:
```
Updated 3 files:
  - docs/dev_plans/20260218-feature-foo.md (status + 4 checkboxes + 1 new item)
  - CHANGELOG.md (added [0.0.7] section)
  - PR #11 description (updated summary + test plan)
```

**Do NOT create new documentation files.** Only update existing ones. If a project has no CHANGELOG.md, don't create one — just note it in the report.

## Phase 5: Offer Next Steps

After the report (or after applying), offer:
1. "Apply all updates" (if not already applied)
2. "Stage and commit the doc updates"
3. "Show me the diff of what changed"

Only commit if the user explicitly asks. Use a commit message like:
```
docs: sync documentation with $(git branch --show-current) changes
```

## Edge Cases

- **No docs found**: Report "No documentation files found in this project. Consider adding a CHANGELOG.md or README.md."
- **Monorepo**: If multiple `CHANGELOG.md` or `README.md` files exist, audit the ones closest to the changed files.
- **No version bump detected**: Skip the "missing version section" changelog check. Still check for undocumented changes.
- **Merge commits**: Use `git log --no-merges` to focus on actual work commits.
- **Draft PR**: Still audit the PR description — drafts need docs too.
- **On main/master directly**: Still useful — audits recent commits for doc staleness. Uses the range since the last doc-touching commit as the comparison window.
- **Committing on base branch**: If there are direct commits on `main`/`master`, avoid broad history rewrites; only propose doc updates for the computed audit range.
