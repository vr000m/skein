# Sync Global CLAUDE.md

| Field | Value |
|-------|-------|
| **Status** | Complete (PR [#2](https://github.com/vr000m/skills.md/pull/2) merged 2026-02-18) |
| **Component** | sync-infra |
| Assignee | Claude |
| Priority | Medium |
| Branch | `chore/sync-global-claude-md` |
| Created | 2026-02-17 |
| Updated | 2026-02-17 |

## Objective

Add bidirectional sync support for `~/.claude/CLAUDE.md` (the global user config) to the existing skills sync system. The file will be committed publicly and follow the same authority model as managed skills.

## Context

The sync system currently handles skills directories (`~/.claude/skills/`, `~/.codex/skills/`) and content guidelines, but ignores the global `~/.claude/CLAUDE.md`. This means user preferences aren't version-controlled or portable across machines.

## Requirements

- `sync-skills.sh`: copy `~/.claude/CLAUDE.md` -> repo (global -> repo)
- `promote-skills.sh`: copy repo -> `~/.claude/CLAUDE.md` (repo -> global)
- `bootstrap-skills.sh`: install to `~/.claude/CLAUDE.md` on new machines (non-destructive by default, `--force` to overwrite)
- `check-sync.sh`: detect drift between global and repo copy
- Repo copy stored at `.claude/CLAUDE.md` (mirrors the global path structure)
- Committed publicly (not gitignored)
- Configurable via `GLOBAL_CLAUDE_MD` env var (default: `$HOME/.claude/CLAUDE.md`)

## Implementation Checklist

### Phase 1: Config & Sync Scripts

- [x] Add `GLOBAL_CLAUDE_MD` to `.env.example`
- [x] Add `GLOBAL_CLAUDE_MD` variable to all 4 scripts
- [x] Update `sync-skills.sh`: copy global CLAUDE.md -> `.claude/CLAUDE.md`
- [x] Update `promote-skills.sh`: copy `.claude/CLAUDE.md` -> global
- [x] Update `bootstrap-skills.sh`: install `.claude/CLAUDE.md` -> global (respecting --force)
- [x] Update `check-sync.sh`: diff global vs repo CLAUDE.md

### Phase 2: Docs

- [x] Update `README.md` authority model section
- [x] Update `docs/dev_plans/README.md` task table

### Phase 3: Validate

- [x] Run `just lint-scripts`
- [x] Run `just check-sync` (expect pass after initial sync)

## Technical Specifications

### Files to Modify

| File | Change |
|------|--------|
| `scripts/sync-skills.sh` | Add CLAUDE.md copy (global -> repo) |
| `scripts/promote-skills.sh` | Add CLAUDE.md copy (repo -> global) |
| `scripts/bootstrap-skills.sh` | Add CLAUDE.md install with --force guard |
| `scripts/check-sync.sh` | Add CLAUDE.md drift detection |
| `.env.example` | Add `GLOBAL_CLAUDE_MD` |
| `README.md` | Document CLAUDE.md in authority model |
| `docs/dev_plans/README.md` | Add task entry |

### New Files

| File | Purpose |
|------|---------|
| `.claude/CLAUDE.md` | Repo copy of global user config (synced) |

### Repo path choice

Store at `.claude/CLAUDE.md` because:
- Mirrors the global `~/.claude/CLAUDE.md` path structure
- Doesn't conflict with `.claude/skills/CLAUDE.md` (which is skills-scoped)
- Natural location within the existing `.claude/` directory

### Note on `.claude/skills/CLAUDE.md`

The existing `.claude/skills/CLAUDE.md` is a skills-scoped subset of preferences. It is NOT the same as the global CLAUDE.md and is NOT managed by the sync system — it lives inside the skills directory structure. This change does not affect it.

## Acceptance Criteria

- [x] `just sync-skills` copies `~/.claude/CLAUDE.md` into `.claude/CLAUDE.md`
- [x] `just promote-skills` copies `.claude/CLAUDE.md` to `~/.claude/CLAUDE.md`
- [x] `just bootstrap-skills` installs CLAUDE.md only if missing (skips if exists)
- [x] `just bootstrap-skills-force` overwrites CLAUDE.md
- [x] `just check-sync` detects drift between global and repo CLAUDE.md
- [x] `just lint-scripts` passes
- [x] README documents the new sync target

## Final Results

- All 4 sync scripts updated to handle `~/.claude/CLAUDE.md` bidirectionally
- `GLOBAL_CLAUDE_MD` env var added (default: `$HOME/.claude/CLAUDE.md`)
- Repo copy stored at `.claude/CLAUDE.md`
- `just lint-scripts` passes
- `just check-sync` passes
