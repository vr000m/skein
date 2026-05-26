---
name: fan-out
description: Fans out independent tasks from a dev-plan to parallel Claude agents running in isolated git worktrees, then merges and verifies the results. Use after planning when 2+ tasks can run independently, or when the user says "fan out", "parallelize this", or "/fan-out".
argument-hint: "[plan-file | status | logs N | cancel [N] | merge | cleanup] [--dry-run] [--max-agents N] [--model MODEL]"
---

# Fan Out: Parallel Agent Orchestration

Dispatch independent tasks to parallel Claude agents, each in an isolated git worktree with its own branch.

## Delegation Depth

Spawned agents are one level deep — they implement their assigned task and must not themselves invoke `/fan-out` or spawn further parallel agents. This keeps the worktree/process model and merge accounting tractable. Agents may still use the `Agent` tool for in-process subagent delegation within their own task (e.g., calling `/review-plan` on a file), but they cannot start a new fan-out tier.

A fan-out-spawned Claude subprocess may invoke `/conduct` as its top-level skill — the subprocess boundary in `fan-out.sh` starts a new orchestrator tree, so `fan-out → (subprocess) → conduct → {implementer, test-writer}` stays within the per-tree one-level rule. `/conduct` itself does not fan out; keep parallelism at the outer layer.

## Usage

- `/fan-out docs/dev_plans/20260206-feature-xyz.md` -- Parse plan, fan out independent tasks
- `/fan-out --dry-run docs/dev_plans/...` -- Show what would happen without executing
- `/fan-out status` -- Check progress of running agents
- `/fan-out logs N` -- Tail agent N's log
- `/fan-out cancel [N]` -- Kill all agents or agent N
- `/fan-out merge` -- Merge completed branches into current branch
- `/fan-out cleanup` -- Remove worktrees and state

## Prerequisites

Before fanning out:
1. A dev-plan must exist (created via `/dev-plan`)
2. You must be on a feature branch (not main/master)
3. The working tree must be clean (no uncommitted changes)
4. The plan should have an "Implementation Checklist" with phases/tasks

## Workflow

When invoked, follow these phases in order:

### Phase 1: Parse Plan

1. Determine the plan file:
   - If a path argument is provided, use it
   - Otherwise, find the most recent `In Progress` plan in `docs/dev_plans/`
   - If none found, ask the user
2. Read the plan file
3. Extract tasks from the **Implementation Checklist** section (lines matching `- [ ] ...`)
4. Extract file mappings from the **Technical Specifications > Files to Modify** section
5. Extract any architecture context from the plan

### Phase 2: Dependency Analysis

For each task, determine which files it likely touches (from Technical Specifications or by inferring from the task description). Classify tasks:

- **Independent**: Touch different files, no logical dependency
- **Potentially conflicting**: Modify the same files
- **Sequential**: One depends on output of another

If the plan has an **Integration Seams** table, include those seams in the analysis. If it doesn't, warn the user that the table is missing, infer seams from the task descriptions (any case where one task produces an interface, method, or resource that another task consumes), and recommend filling the table in the dev plan before proceeding.

Present the analysis to the user:

```
Dependency Analysis for: [plan-file]

Independent tasks (safe to parallelize):
  [1] Add API endpoint           (touches: src/api/routes.ts)
  [2] Add database migration     (touches: db/migrations/...)
  [3] Add unit tests             (touches: tests/api/...)

Potentially conflicting (should run sequentially):
  [4] Update shared types        (touches: src/types.ts — shared by 1,2,3)

Sequential (must run after others):
  [5] Integration tests          (depends on 1-3)

Integration seams (verify after merge):
  - Task 1 writes UserService.create() / Task 3 calls it from tests
  - Task 2 adds migration / Task 1 assumes schema exists at runtime

Fan out tasks [1], [2], [3] in parallel? (y/n/edit)
```

If the user says "edit", let them adjust. If `--dry-run` was specified, stop here.

### Phase 3: Setup Worktrees and Spawn Agents

For each approved task, run these steps using `fan-out.sh`.

First, locate the skill directory and get repo info:
```bash
SKILL_DIR="$(find ~/.claude/skills -maxdepth 1 -name 'fan-out' -type d | head -1)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
BASE_BRANCH="$(git branch --show-current)"
```

Then for each task:

1. **Create worktree**:
   ```bash
   WORKTREE=$("${SKILL_DIR}/fan-out.sh" setup "$BASE_BRANCH" "<task-id>-<task-slug>" "$REPO_ROOT")
   ```
   Always prefix the slug with the task ID (e.g., `"1-add-api-endpoint"`, `"2-add-migration"`) to prevent collisions when different tasks slugify to the same string.

   This creates branch `fanout/<base-slug>-<slug>` and worktree at `../<repo>-fanout-<slug>`, where `<slug>` is the `<task-id>-<task-slug>` string passed by the caller.

2. **Build agent prompt**: Read the template from `agent-prompt.md` in this skill directory. Replace placeholders:
   - `{{TASK_DESCRIPTION}}` — Full task text from the plan
   - `{{TASK_NAME}}` — Short task name
   - `{{TECHNICAL_SPECIFICATIONS}}` — Files to modify, architecture decisions from plan
   - `{{WORKTREE_PATH}}` — Absolute path to worktree
   - `{{BRANCH_NAME}}` — Git branch for this agent
   - `{{BASE_BRANCH}}` — The base branch
   - `{{CLAUDE_MD_CONTENT}}` — Contents of `CLAUDE.md` and `AGENTS.md` if they exist
   - `{{TOOLCHAIN_CONTEXT}}` — Contents of the appropriate `toolchains/<language>.md` file.
     Detect the language from the project:
     - `pyproject.toml` or `setup.py` → `toolchains/python.md`
     - `package.json` → `toolchains/typescript.md` (or `node.md`)
     - `Cargo.toml` → `toolchains/rust.md`
     - `go.mod` → `toolchains/go.md`
     - If no toolchain file exists for the detected language, omit this section and
       let the agent infer setup/test commands from project config files.

   Write the filled prompt to a temp file in the worktree.

3. **Spawn agent**:
   ```bash
   PID=$("${SKILL_DIR}/fan-out.sh" spawn "$WORKTREE" "$PROMPT_FILE" "$WORKTREE/fan-out.log" --model opus)
   ```

4. **Record state**: After spawning all agents, write `.fan-out-state.json` in the repo root:
   ```json
   {
     "plan_file": "<path>",
     "base_branch": "<branch>",
     "base_commit": "<sha>",
     "repo_root": "<path>",
     "started_at": "<ISO timestamp>",
     "agents": [
       {
         "task_id": 1,
         "task_name": "<name>",
         "branch": "<branch>",
         "worktree": "<path>",
         "pid": 12345,
         "log_file": "<path>/fan-out.log",
         "status": "running"
       }
     ]
   }
   ```

5. **Print summary**:
   ```
   Fan-out active: N agents spawned

   Agent 1: <task-name>
     Branch:   <branch>
     Worktree: <path>
     Log:      <path>/fan-out.log
     PID:      <pid>

   To check status:  /fan-out status
   To view logs:     /fan-out logs 1
   To cancel:        /fan-out cancel
   ```

### Phase 4: Monitor (on `/fan-out status`)

Run:
```bash
"${SKILL_DIR}/fan-out.sh" status .fan-out-state.json
```

Also check each worktree for `.fan-out-result.md` to see if agents wrote their summaries.

### Phase 5: Collect Results (on `/fan-out status` when all finished, or `/fan-out merge`)

When all agents have finished (no PIDs running):

1. For each agent, read `.fan-out-result.md` from the worktree
2. Check if commits were made: `git -C <worktree> log <base>..HEAD --oneline`
3. Push unpushed branches: `git -C <worktree> push -u origin <branch>`
4. Present summary:

```
Fan-out complete: N/N agents finished

Task 1: Add API endpoint        -- SUCCESS (3 commits, pushed)
Task 2: Add database migration  -- SUCCESS (2 commits, pushed)
Task 3: Add unit tests          -- FAILED  (see log)

Options:
1. Merge successful branches into current branch
2. Create individual PRs for each branch
3. Review each agent's work first
4. Keep branches as-is (manual)
```

### Phase 6: Merge (on `/fan-out merge` or user choosing option 1)

For each successful task branch, in order:
```bash
git merge --no-ff <task-branch> -m "Merge fan-out task: <name>"
```
- Run tests after each merge if a test command is known
- Stop and report if merge conflicts arise
- Never squash (per global CLAUDE.md preferences)

**After all branches are merged**, verify integration seams:
1. Read each agent's `.fan-out-result.md` **Integration Seams** section.
2. For every method one agent wrote that another agent (or orchestration code) must call, confirm the call site exists and the contract is honored (arguments, error handling, cleanup).
3. Look for dead code at boundaries — methods that were written but never wired into the calling code.
4. Check resource lifecycle — every open/connect/init should have a corresponding close/cleanup.
5. Run the full test suite once more after all merges. Individual agents tested in isolation; this run catches integration failures.

For option 2 (PRs):
```bash
gh pr create --base <base-branch> --head <task-branch> \
  --title "Fan-out: <task-name>" \
  --body "<summary from .fan-out-result.md>"
```

### Phase 7: Cleanup (on `/fan-out cleanup`)

Run:
```bash
"${SKILL_DIR}/fan-out.sh" cleanup .fan-out-state.json
```

This removes worktrees, deletes merged branches, and removes the state file.

### Viewing Logs (on `/fan-out logs N`)

Read the log file for agent N:
```bash
tail -100 <worktree>/fan-out.log
```

### Canceling (on `/fan-out cancel [N]`)

```bash
"${SKILL_DIR}/fan-out.sh" cancel .fan-out-state.json [N]
```

## Defaults

- **Model**: opus (override with `--model sonnet`)
- **Max agents**: 5 (override with `--max-agents 3`)
- **Worktree location**: `../<repo-name>-fanout-<slug>` (sibling to repo)
- **Branch naming**: `fanout/<base-slug>-<task-slug>`

## Integration Seams

An **integration seam** is any boundary where one agent's output feeds into another's input — a method signature, a shared resource, a data contract. Agents test in isolation, so these seams are where bugs hide.

Common patterns to watch for:
- A method exists but the calling code never invokes it (dead code at the boundary)
- A protocol or interface is only partially satisfied by the implementer
- Resources (connections, file handles) are opened but never closed by orchestration
- Error/cleanup paths that one agent assumed another would handle
- Idempotency violations when operations run more than once

Integration seams are surfaced at three points in the workflow:
1. **Dependency analysis** — identified from the plan and listed alongside file conflicts
2. **Agent self-review** — each agent flags seams in its result file
3. **Post-merge verification** — the orchestrator audits all seams after merging

## Constraints

- Agents run non-interactively with `--dangerously-skip-permissions` — only use on trusted code
- Agents cannot ask clarifying questions — task descriptions must be self-contained
- No shared state between agents — if task B needs output from task A, they cannot be parallelized
- `.fan-out-state.json` should be in `.gitignore`

## Integration with `/dev-plan`

Recommended workflow:
1. `/dev-plan create feature auth-system` — Create the plan
2. `/review-plan` — Audit the plan for gaps before implementation (blocks until complete)
3. Complete prerequisite/sequential tasks manually
4. `/fan-out docs/dev_plans/20260206-feature-auth-system.md` — Fan out independent tasks
5. `/fan-out status` — Monitor progress
6. `/fan-out merge` — Merge when all agents complete
7. `/fan-out cleanup` — Remove worktrees
8. Continue with remaining sequential tasks
9. After all work is done, update the plan checkboxes
