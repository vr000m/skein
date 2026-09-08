# skein — project instructions

Global preferences live in `~/.claude/CLAUDE.md` (owned by sync-computer). This file holds only what is specific to skein. Architecture, mirror conventions, and the full release procedure are in `AGENTS.md`; read it before editing skills.

## Releases
- **Cut and re-sync releases through `skein:release`.** Use `/release X.Y.Z` after the release-bearing PR is merged and local `main` is current; do not hand-run `git tag` + `gh release create`. Bump the version in both plugin manifests (see AGENTS.md "Cutting a release").

## Review gates
- When the skein plugin is available, run `skein:review-gauntlet` (or set a dev-plan's **Review Gates:** field) rather than hand-running the gates. Otherwise hand-run `/code-review` and `/security-review` before merging (`/deep-review` is a skein skill and is not available either).
- `/code-review` cannot be chained by review-gauntlet (harness blocks model invocation); run `/code-review xhigh --fix` yourself before merging.
- If a `conduct` or `review-gauntlet` run is interrupted, resume via `--resume` (state lives in `.conduct/` and `.gauntlet/`); do not restart from scratch.
- Once reviews have converged, run `/update-docs` — review-gauntlet only chains the review gates.
- Every fixer brief and every fixer commit must run `just ci`; partial recipes have hidden lens-test regressions across rounds.

## Mirrors
- Claude and Codex skill mirrors use different path anchors (`${CLAUDE_PLUGIN_ROOT}` vs `"$SKILL_DIR"`); never collapse them. Codex-mirror edits go through `codex:rescue`, Codex half first, then align the Claude half in the same commit. Details in AGENTS.md.

## Testing
- Background `just ci` (`run_in_background` + Monitor); a full run can exceed the foreground Bash timeout.
