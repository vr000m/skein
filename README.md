# skills.md

Reusable skills for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) and [OpenAI Codex CLI](https://github.com/openai/codex) agents.

## Skills

| Skill | Claude | Codex | Description |
|-------|--------|-------|-------------|
| dev-plan | Yes | Yes | Generate and manage development plans; `create` runs one fresh-context Explore subagent that gathers verified paths, patterns, dependency versions, and git refs before drafting |
| fan-out | Yes | Yes | Parallel agent orchestration via worktrees |
| content-draft | Yes | Yes | Draft content following style guidelines |
| content-review | Yes | Yes | Review content against style guidelines |
| deep-review | Yes | Yes | Multi-lens code review with fresh-context subagents; reconciles findings by structural signature. Opt-in `--auto-fix=trivial` applies a hard-coded allowlist of mechanical fixes (requires `--test-cmd`) |
| review-plan | Yes | Yes | Audit a dev plan via four parallel fresh-context lenses (architecture, sequencing, spec-and-testing, codebase-claims) before implementation; reconciles findings by structural signature. Opt-in `--auto-fix=trivial` applies allowlisted prose edits outside the immutable contract sections |
| rfc-finder | Yes | Yes | Find and link to IETF RFCs and related drafts |
| spec-compliance | Yes | Yes | Check code against RFC/W3C/WHATWG requirements |
| update-docs | Yes | Yes | Audit and update stale docs against branch diffs |
| conduct | Yes | Yes | Walk a reviewed dev plan phase by phase via harness-native clean-context subagents |

## Setup

1. Install tools:

```bash
brew install just shellcheck shfmt
```

2. Create local env file:

```bash
cp .env.example .env
```

3. (Optional) restrict managed skills in `.env`:

```bash
MANAGED_SKILLS="conduct content-draft content-review deep-review dev-plan fan-out review-plan rfc-finder spec-compliance update-docs"
CLAUDE_ONLY_SKILLS=""
```

For one-off runs, prefer a command-scoped override instead of editing `.env`:

```bash
MANAGED_SKILLS="rfc-finder" just bootstrap-skills
MANAGED_SKILLS="rfc-finder" just promote-skills
```

`MANAGED_SKILLS` lists skills kept in lockstep between `.claude/` and `.codex/` mirrors. `CLAUDE_ONLY_SKILLS` remains available for skills that intentionally live only under `.claude/` and are promoted exclusively to `~/.claude/skills/` — no `.codex` read or write. `conduct` now ships in both mirrors and keeps the same review-marker, phase-slot, state-file, report-schema, and handback contracts across harnesses while using harness-native worker orchestration.

`bootstrap-skills` seeds missing global skill dirs without overwriting existing content unless `--force` is used. `promote-skills` intentionally overwrites the selected managed skills and also copies repo `.claude/CLAUDE.md` and `.codex/AGENTS.md` to the global paths.

See [AGENTS.md](AGENTS.md) for commands, architecture, authority model, and workflow details.
