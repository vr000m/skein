# skills.md

Reusable skills repo for Claude Code and OpenAI Codex CLI agents.

## Commands

```bash
just sync-skills        # Mirror global -> repo (day-to-day)
just promote-skills     # Set repo -> global (intentional overwrite)
just bootstrap-skills   # Init missing managed skills on new machine
just bootstrap-skills-force  # Force overwrite bootstrap
just check-sync         # Validate sync state
just reconciliation-tests  # Reconciliation parity + fixture + renderer + determinism suite
just lint-scripts       # shellcheck + shfmt on scripts/
```

Requires: `brew install just shellcheck shfmt`

## Architecture

```
.claude/skills/     Claude Code skills (SKILL.md per skill)
.codex/skills/      Codex CLI skills (mirrored structure)
scripts/            Shell scripts for sync/promote/bootstrap/check/reconcile/parity/render
tests/              Reconciliation test harnesses (fixtures, determinism, renderer)
docs/dev_plans/     Development plans
justfile            Task runner config
.env.example        Template for local env overrides
```

## Authority Model

Global is authoritative, repo is a mirror:
- Global skills: `~/.claude/skills/` and `~/.codex/skills/`
- `sync-skills` copies global -> repo; `promote-skills` copies repo -> global
- `~/.claude/CLAUDE.md` syncs bidirectionally with `.claude/CLAUDE.md`
- `~/.codex/AGENTS.md` syncs bidirectionally with `.codex/AGENTS.md`
- Only skills listed in `MANAGED_SKILLS` (from `.env` or a per-command env override) are synced between `.claude/` and `.codex/` mirrors
- Skills listed in `CLAUDE_ONLY_SKILLS` are promoted and synced Claude-side only; they are never read from or written to `.codex/`. Use this for skills whose Codex equivalence is intentionally absent
- Content guidelines authority: repo-canonical file at `.codex/skills/content-review/references/content-guidelines.md`
- Repo Claude mirror: `.claude/skills/content-review/references/content-guidelines.md`
- Global mirrors: `~/.codex/skills/content-review/references/content-guidelines.md` and `~/.claude/skills/content-review/references/content-guidelines.md`

## Skill Workflow

Recommended development workflow using skills:

1. `/dev-plan create feature xyz` — Create the plan; on `create` only, dispatches one fresh-context Explore subagent that returns structured codebase facts (verified paths, observed patterns, dependency versions, verified git refs) which land above the review marker. `update` and `complete` do not re-explore
2. `/review-plan` — Audit the plan by dispatching four parallel fresh-context lens agents (`architecture`, `sequencing`, `spec-and-testing`, `codebase-claims`); reconciles findings by structural `(file, line, category)` signature and surfaces same-location-different-category findings as cross-references; blocks until complete, and on acceptance writes a review marker footer consumed by `/conduct`. Cost: three high-reasoning lenses plus one cheap factual lens per run
3. Address review findings, update plan as needed
4. `/conduct` — Walk a reviewed linear plan phase by phase, delegating implementation + tests per phase to harness-native clean-context subagents while preserving the shared review-marker, phase-slot, report-schema, and handback contracts. On `--resume`, a stale review marker is auto-refreshed in place (above-marker amendments mid-run no longer require a re-run of `/review-plan`); initial runs and missing markers still hard-stop. State-file naming and resume-guard details may vary by harness implementation (pair with `/fan-out` at the outer layer when phases themselves fan out)
5. `/fan-out` — Fan out independent tasks to parallel agents (or implement manually)
6. `/deep-review` — Run a multi-lens code review after implementation and before merge. Reconciles findings by structural signature to suppress false-positive amplification across lenses.

Skills delegate heavy phases (research, analysis, report generation) to subagents and return only the structured result to the main context. This keeps main context lean and preserves token budgets on long sessions. User-facing I/O (confirmations, applying edits, presenting results) stays in the main context.

**Dual-harness plans need both harnesses to review.** If a plan touches files under `.claude/skills/<skill>/` AND `.codex/skills/<skill>/` (or any harness-specific runtime path), run `/review-plan` once in Claude AND once in Codex against the same plan, in separate sessions. Each harness only knows its own runtime — Claude uses the `Agent` tool and `subagent_type: general-purpose`; Codex uses `spawn_agent` / `wait_agent` / `close_agent` with `fork_context: false`; `scripts/sync-skills.sh` is `global -> repo` (not a per-phase mirror); each side has runtime-specific SKILL.md sections (e.g. Codex's "Delegation Availability"). A single-harness review will miss the other side's invariants. Reconcile findings before starting implementation.

**Delegation depth: one level per orchestrator tree.** A skill (the orchestrator) may spawn workers — Claude `Agent`-tool subagents and Codex `spawn_agent` workers in `deep-review`, `review-plan`, and `conduct`, plus worktree processes in `fan-out` — but those workers must not themselves spawn further workers within the same tree. Workers launched in a fresh subprocess/session (for example via `fan-out.sh spawn`) start a new orchestrator/worker tree and may themselves act as orchestrators; the one-level rule applies per-tree. Keeping a flat orchestrator/worker tree makes context isolation, result aggregation, and (for fan-out) merge accounting tractable.

## Review Checklist

Use this section for project-specific won't-fix and analysis-error patterns that deep review should suppress on future runs. Keep entries stable, specific, and dated.
Format: `- **[Category] disposition**: description (YYYY-MM-DD)`

- **[Architecture] won't-fix**: mirrored Claude and Codex skill trees are intentional (2026-03-17)

## Sync Workflow

- Day-to-day: run `just sync-skills` to mirror `global -> repo`
- Intentional overwrite: run `just promote-skills` to set `repo -> global`
- New machine setup: run `just bootstrap-skills` (initialises missing managed skills only)
- Force bootstrap overwrite when needed: run `just bootstrap-skills-force`
- Seed or promote only a subset for one run: prefix the command with `MANAGED_SKILLS="skill-a skill-b"`
- Scope Claude-only skills similarly: prefix with `CLAUDE_ONLY_SKILLS="skill-a skill-b"` when a skill intentionally has no Codex mirror
- Validation: run `just check-sync`

Notes:
- All commands sync `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md` alongside managed skills.
- `promote-skills` and `bootstrap-skills` copy the repo-canonical `content-review/references/` directory into global skill directories when `content-review` is in `MANAGED_SKILLS`.
- `bootstrap-skills` is non-destructive unless `--force` is provided (applies to skills, reference files, CLAUDE.md, and AGENTS.md).
- `promote-skills` is destructive for the selected managed skills (`rsync --delete`) and always overwrites global `CLAUDE.md` and `AGENTS.md`.
- `sync-skills` and `check-sync` skip managed skills that do not exist yet in the global authorities and tell you to seed them with `bootstrap-skills` or `promote-skills`. The same skip rule applies to any `CLAUDE_ONLY_SKILLS`, Claude-side only.
- `sync-skills` preserves the entire repo-canonical `references/` directory for content-review (does not overwrite from global) and refreshes the repo Claude copy from the canonical codex source.
- `check-sync` requires both `content-guidelines.md` and `writing-style-rules.md` in the canonical references directory.
- `sync-skills` warns for missing global `AGENTS.md` only when repo `.codex/AGENTS.md` exists.

## Conflict Policy

Treat conflicts as policy decisions, not merge-resolution tasks.

- Repo-only drift: run `just sync-skills` (discard) or `just promote-skills` (adopt)
- Global-only drift: run `just sync-skills`
- Both changed: decide authority explicitly, then sync again

## Gotchas

- **Don't edit `.claude/CLAUDE.md` or `.codex/AGENTS.md` directly** -- they get overwritten by `sync-skills`. Edit the global files instead, then sync.
- Content guidelines are repo-canonical at `.codex/skills/content-review/references/content-guidelines.md`, mirrored to `.claude/skills/content-review/references/content-guidelines.md` and the global skill folders
- `bootstrap-skills` is non-destructive by default; use `--force` to overwrite
- Scope one command without changing `.env`: `MANAGED_SKILLS="rfc-finder" just bootstrap-skills` or `MANAGED_SKILLS="rfc-finder" just promote-skills`
- Even when you scope `MANAGED_SKILLS`, `promote-skills` still copies repo `.claude/CLAUDE.md` and `.codex/AGENTS.md` to the global paths
- `.env` is optional; copy from `.env.example` only if you want local overrides such as `MANAGED_SKILLS`
