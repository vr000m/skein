# Global Preferences

## Git
- **Never squash merge PRs.** Use regular merge (`gh pr merge --merge --delete-branch`) to preserve individual commit history.
- **Always work on feature branches** — never commit directly to main. Create branch, dev plan, update docs, then PR.
- **Cut and re-sync releases through `skein:release`.** Use `/release X.Y.Z` after the release-bearing PR is merged and local `main` is current; do not hand-run `git tag` + `gh release create`.

## Commit Hygiene
- **Never use `git add -A`, `git add --all`, or `git add .`** — they sweep untracked scratch/dev-plan files into commits. A PreToolUse hook blocks these. Stage explicit paths.
- When a multi-step task touches multiple logical changes, split into separate commits with focused scope.

## Pre-Push Checks
- For Python projects: run `ruff format` AND `ruff check` before pushing — not just `check`. (A PostToolUse hook auto-formats on Edit/Write, but verify before push.)
- Run the full test suite locally before opening or updating a PR.

## Review Workflow
- **When a review returns findings, don't patch reactively in the same pass.** Think through each reported issue first — root cause, not just the symptom. Where the fix is more than mechanical, delegate it as a sequence of clean-context subagents — architect, implement, test, verify against the original finding — rather than writing the diff inline. Reason: fixes written inline immediately after reading a finding tend to be shallow patches on the reported symptom; splitting architect/fix/test/verify across subagents forces the root-cause step instead of skipping straight to a diff.
- **Verify the invariant, not just the tests.** Before declaring a structural fix complete (hashing, dedup, parity, state-machine), state the invariant and show concrete evidence (assertion, diff, log) that it holds across all call sites. Tests passing ≠ fix correct.
- **Sweep the blast radius before finalizing a fix for a reported finding.** Don't just patch the reported line — grep every other place in the touched file(s) that uses the same mechanism (command, flag, config key, shared state), and check whether the fix's mechanism conflicts with an invariant those other call sites depend on (pay special attention to encode/decode, escape/unescape, serialize/deserialize pairs — the reverse side is often built the same naive way and breaks in reverse). State the old invariant and the new one side by side before committing, not just "does this fix the reported problem." A fix that satisfies the reported line can silently break a second call site on the same mechanism, and the second break surfaces only in a later review round.
- After applying review fixes, re-verify the review-marker / plan-file hash before delegating further phases.
- Before running adversarial / Codex / multi-lens review, confirm the diff scope: print `git diff <base>...HEAD --stat` and confirm it matches the feature branch, not the local worktree diff.

## Plan Updates
- When updating a dev plan, grep `docs/dev_plans/` (or equivalent) for sibling plans referencing the same feature/component and update them in the same pass — partial updates leave stale references.

## Workflow
- Discuss and plan before implementing non-trivial features.
- **If an approach is failing, stop and re-plan** — don't keep pushing on a broken path.
- Update docs (AGENTS.md, README.md, dev plan) alongside code changes, not after.
- When the skein plugin is available, run `skein:review-gauntlet` (or set a dev-plan's **Review Gates:** field) rather than hand-running the gates. Otherwise hand-run `/code-review` and `/security-review` before merging (`/deep-review` is a skein skill, so it is not available in that case either).
- Once reviews have converged, run `/update-docs` — review-gauntlet does not do this itself, it only chains the review gates.
- Fix all review findings before merge.
- Update PR description to reflect final state of the work.
- **Verify before marking done** — run tests, check logs, demonstrate correctness. Don't claim a task is complete without proof.

## Long-running Processes
- **Always pair background processes with a Monitor.** When starting any long-running process (dev server, ngrok, docker compose, log tail, background worker), run it with `Bash(run_in_background)` and immediately set up a `Monitor` on its output filtered for errors/warnings. This way the user can interact with the process (e.g., test in a browser) while Claude stays aware of server-side issues.
- Filter Monitor output: `grep --line-buffered -E "ERROR|WARN|Traceback|Exception|FATAL|panic"` — don't stream raw logs.

## Permissions
- Permissions are configured in `~/.claude/settings.local.json` with a broad allow list and explicit deny list (`rm`, `git rm`, `git merge`, `git reset --hard`, `git clean`, `git push --force`, package uninstalls, container deletion, `gh repo delete`, `gh pr close`).
- **Goal:** Claude should run long/overnight implementation tasks without permission prompts for non-destructive ops.
- If a safe command prompts during an autonomous run, note it — it should probably be added to the allow list.
- User has a `riskyclaude` alias for `claude --dangerously-skip-permissions` but rarely uses it. Do not suggest it.

## Bug Fixing
- When given a bug with clear signals (logs, errors, failing tests), fix it autonomously. Don't ask for hand-holding.

## Code Changes
- **Minimal impact** — only touch what's necessary. Find root causes, no temporary hacks.

## MCP Tools
- When pipecat-context-hub MCP is available, always prefer its tools (`search_docs`, `search_api`, `search_examples`, `get_example`, `get_doc`, `get_code_snippet`) for Pipecat framework questions. Do not read `.venv` source directly.
- **Multi-concept queries:** When searching for multiple topics at once, use ` + ` or ` & ` as delimiters (e.g., `search_docs("TTS + STT")`, `search_examples("idle timeout + function calling + Gemini")`). Each concept is searched independently and results are interleaved for balanced coverage. Do NOT stuff multiple concepts into a single natural-language query.

## Destructive Operations
Destructive commands are blocked by the permissions deny list — they will prompt. When the prompt appears, apply these rules before approving:
- **Back up first.** Never `rm -rf` a data directory without `cp -a <dir> <dir>.bak`. Prefer moving to a `backups/` directory over permanent deletion.
- **Check for active writers** with `lsof +D <dir>` before deleting — a directory that looks like a duplicate may have a running process writing to it. A snapshot comparison is not enough.
- **SQLite databases:** never overwrite or delete wholesale. Merge row by row, always back up first.
- Applies to runtime data, caches, and databases — not just source code.

## Context Management
After completing a major task (commit, review, PR, skill run), assess the conversation:
- **Mid-task**: "We're mid-implementation on X — let's finish before managing context."
- **More related work remains**: Suggest `/compact focus on [specific next phase]`
- **Work is done or next task is independent**: Suggest `/clear` or provide a self-contained prompt to continue in a new session. Include: the goal, what's done, what's left, relevant file paths, and the branch name.

## Tool Output Discipline
Raw Bash/Read/Grep output lands in the transcript verbatim and stays for the rest of the session. Treat context as a budget. Apply these rules in order:

**1. Narrow inline commands before running them.** For commands I run myself, return only what I'll act on:
- `git log --oneline -N`, not `git log`
- `git diff --stat` or `--name-only` first; full diff only if needed
- `grep -l` (filenames) or `grep -c` (counts) when I just need existence
- `find ... | head -N`, `ls -1` not `ls -la` unless I need metadata
- Pipe verbose tooling through `grep -E "error|fail|warn"` or `tail -50`
- For Read, pass `limit`/`offset` when I know the region

**1a. Prefer faster modern CLIs when available.** They're terser by default and respect `.gitignore`, which alone cuts a lot of noise. Probe with `command -v <tool>` once per session before relying on it; fall back to the POSIX equivalent if missing.
- `rg` over `grep -r` / `find ... -exec grep` — faster, gitignore-aware, sensible defaults. `rg -l`, `rg -c`, `rg --files -g '*.ts'` for file listing.
- `fd` over `find` — `fd pattern` instead of `find . -name '*pattern*'`. Defaults to gitignore-aware, shorter syntax.
- `bat` over `cat` only when *I* need syntax-highlighted output for a human-facing summary; for tool reads, prefer the Read tool with `limit`/`offset`. `bat -p` (plain) if used in a pipe.
- `eza`/`exa` over `ls` for tree views (`eza --tree --level=2`).
- `jq` for JSON, `yq` for YAML — never grep structured data.
- `delta` for diffs only in interactive contexts; not in tool output (it adds ANSI noise).

**2. Delegate wide reads to a subagent with a shaped output contract.** When a task needs >3 lookups, spans multiple files, or produces structurally noisy output (test runs, build logs, multi-file audits), spawn an Agent. The subagent absorbs the raw tool noise; only its final message enters my context. Always specify the output contract in the prompt:
- "Report under 150 words. Bullet list of `path:line` matches only."
- "Return JSON: `{found: bool, paths: string[], reason: string}`."
- "Yes/no with one sentence of justification. No raw output."
- "Punch list: done vs missing. Under 200 words."

For pure lookups, prefer `subagent_type: Explore`. For verification/yes-no checks, use `general-purpose` with `model: "haiku"` — the overhead is worth it when raw output would otherwise be large.

**3. Decision rule — inline vs delegate.** Run it inline when the narrowed output is small (under about 30 lines) and I will act on the detail myself. Delegate when the raw output would be large or spread across files and I only need the conclusion. Two carve-outs are not obvious from that rule: verbose-but-single-purpose output (build, test, deploy logs) stays inline behind a filter pipe unless all I want is a verdict, and anything I will re-reference later in the session stays inline, because delegating discards the detail.

**4. Reuse prior reads, but verify freshness first.** If I already read a file this session, reuse that content — *unless* it may have changed since. The Edit/Write tools track state for files **I** modified, so re-reading after my own successful Edit is wasted. But the file may have changed for other reasons:
- A subagent or parallel Agent ran and may have edited it (worktree isolation aside).
- A PostToolUse hook rewrote it (e.g., `ruff format`, `prettier`, `eslint --fix`).
- The user edited it in their editor between turns.
- A build/codegen step (`tsc`, `protoc`, `cargo build`) regenerated it.
- A `git` operation changed working tree state (checkout, stash pop, rebase, merge).

Before relying on a cached read for a non-trivial decision (an Edit, a claim about contents, a security check), do a cheap freshness probe:
- `git status --short <path>` — shows if the file is dirty vs my last view of HEAD.
- `stat -f %m <path>` (macOS) / `stat -c %Y <path>` (Linux) — mtime check.
- For files inside a subagent's likely scope, just re-Read; the round-trip is cheaper than acting on stale content.

Rule of thumb: **read-then-edit in the same turn is safe; read-then-edit across a subagent call, hook fire, or user turn is not.**

## Testing
- Background the full test suite (`run_in_background` + Monitor) rather than running it in the foreground — a full run can exceed the foreground Bash timeout and abort mid-suite.

## Facts vs Inference
- Never infer CI/approval-gate state (e.g. whether a manual-approval step still exists) from indirect signals like workflow run duration. Confirm from the primary source — `gh run view`, `gh api`, or the workflow YAML itself — before acting on it or writing it into a file.

## Security & Diff Reviews
- Post a scope summary before diving in, cap orienting exploration at 3 calls, then stream findings severity-first as they're found rather than batching to the end. A review held to the end delivers nothing at all if the session is interrupted mid-exploration.

## Security
- Before committing, check staged files for PII, private keys, secrets, and credentials. Never commit these.

## Auto-Memory Hygiene
- When writing a memory file, include a `last_verified: YYYY-MM-DD` field in the frontmatter (today's date).
- Before relying on a memory whose `last_verified` is **>14 days old**, re-verify its top claims against live state (file existence, git tags, branch HEADs) and either refresh `last_verified` or remove the memory.
- Memory snapshots of repo activity (logs, architecture summaries) are frozen in time — for "current state" questions prefer `git log` / live reads over recall.
