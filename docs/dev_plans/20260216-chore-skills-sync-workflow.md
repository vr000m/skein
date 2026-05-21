# Skills Sync Workflow Plan

**Status:** Complete (PR [#1](https://github.com/vr000m/skills.md/pull/1) merged 2026-02-16)

- Type: chore
- Priority: High
- Assignee: vr000m + codex
- Branch: chore/skills-sync-workflow
- Created: 2026-02-16
- Updated: 2026-02-16
- Objective: Define and implement an explicit authority model and operational workflow for syncing mirrored skills in this repo with global skill directories, with authoritative `content-guidelines.md` resolution.

## Context

This repo mirrors skills for both Claude and Codex. Without a defined source of truth and scripted workflow, mirrored copies drift and conflict handling becomes ad hoc. The goal is a repeatable flow where global settings are authoritative by default while preserving an explicit promotion path from repo to global when intentionally needed.

## Requirements

- Global skill directories are default authority.
- Repo supports explicit promotion to global when intended.
- New-machine bootstrap path exists.
- `content-guidelines.md` resolves from local configured path first, then remote raw URL fallback.
- Validation command fails on drift.
- Operational commands are exposed via `justfile`.
- Documentation explains policy, setup, conflict handling, and commands.

## Implementation Checklist

- [x] Add `.env.example` with authority variables and guideline sources.
- [x] Add `.gitignore` for `.env`.
- [x] Implement `scripts/sync-skills.sh` (`global -> repo`).
- [x] Implement `scripts/promote-skills.sh` (`repo -> global`, guarded by `--yes`).
- [x] Implement `scripts/bootstrap-skills.sh` (`repo -> global`, guarded by `--yes`).
- [x] Implement `scripts/check-sync.sh` drift validation.
- [x] Add `justfile` tasks for sync/promote/bootstrap/check/lint.
- [x] Update `README.md` with authority model and workflow.
- [x] Move work to feature branch `chore/skills-sync-workflow`.
- [x] Install missing local tools (`just`, `shfmt`) and run full local task validation.

## Technical Specifications

Files added/updated:

- `.env.example`
- `.gitignore`
- `justfile`
- `README.md`
- `scripts/sync-skills.sh`
- `scripts/promote-skills.sh`
- `scripts/bootstrap-skills.sh`
- `scripts/check-sync.sh`
- `docs/dev_plans/20260216-chore-skills-sync-workflow.md`
- `docs/dev_plans/README.md`

Operational design:

- Default workflow is one-way mirror from global directories into repo copies.
- Promotion path is separate and explicit to avoid accidental authority reversal.
- Drift detection compares repo mirrors against global authorities and checks that both copied content-guidelines files match the authoritative source.

## Testing Notes

Executed:

- `bash -n scripts/*.sh` (pass)
- `shellcheck scripts/*.sh` (pass)

Executed after tool install:

- `just --version` (pass)
- `shfmt -version` (pass)
- `just lint-scripts` (pass)
- `just check-sync` (pass)

## Issues & Solutions

- Issue: `check-sync` initially reported drift for non-repo-managed global skills.
- Solution: Added `MANAGED_SKILLS` allowlist so sync/promote/bootstrap/check only target repo-owned skills.
- Issue: Remote guideline fetch in a `curl | tee` pipeline could partially write target files on transfer failure.
- Solution: Updated `sync`/`promote`/`bootstrap` to download guidelines to a temporary file first, then copy to targets only on successful fetch.

## Acceptance Criteria

- [x] Authority model is documented and unambiguous.
- [x] `global -> repo` sync command exists.
- [x] Explicit `repo -> global` promote command exists and is guarded.
- [x] Bootstrap command exists for new-machine setup.
- [x] Drift check command exists.
- [x] Content guidelines precedence is implemented and documented.
- [x] Workflow is exposed through a `justfile`.
- [x] Plan file exists in `docs/dev_plans/` and references active branch.

## Final Results

Implemented a full sync workflow with explicit authority rules, promotion guardrails, managed-scope allowlisting, and drift detection. Follow-up review fixes made `bootstrap` non-destructive by default (with `--force` for overwrite), ensured `promote`/`bootstrap` both refresh authoritative content guidelines, reduced remote guideline fetches in drift checks, and hardened guideline updates to avoid partial writes by using a temp download before replacing targets. The repo is on branch `chore/skills-sync-workflow`, and the process is documented for daily use, exception handling, and new-machine bootstrap.
