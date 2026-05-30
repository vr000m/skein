# skein

Namespaced skill plugin for Claude Code and OpenAI Codex CLI agents. All skills load under the `skein:` namespace per harness.

## Commands

```bash
just check-sync                  # canonical scripts/ <-> bundled skill scripts byte-identity
just check-prompt-parity         # Claude vs Codex SKILL.md prompt parity (bundle skills)
just check-trunk-snippet-parity  # trunk-resolution snippet parity
just bundle-appliers             # Regenerate the bundled auto-fix pipeline inside each skill
just parity-tests                # Bundle + allowlist + orchestration-contract + no-fallback parity
just reconciliation-tests        # Reconciliation parity + fixture + renderer + determinism suite
just lint-scripts                # shellcheck + shfmt on scripts/
```

Requires: `brew install just jq shellcheck shfmt`

## Architecture

```
plugins/skein/skills/        Claude Code skills (SKILL.md per skill; deep-review/review-plan also carry a generated scripts/ subtree)
plugins/skein-codex/skills/  Codex CLI skills (mirrored structure; same generated scripts/ subtree; per-harness dispatch idiom retained)
.claude-plugin/marketplace.json   Claude marketplace entry (name: skein)
.agents/plugins/marketplace.json  Codex marketplace entry (name: skein)
plugins/skein/.claude-plugin/plugin.json       Claude plugin manifest
plugins/skein-codex/.codex-plugin/plugin.json  Codex plugin manifest
scripts/                     Canonical shell scripts for check-sync/reconcile/parity/render/auto-fix/bundle
scripts/lib/                 Shared bash helpers sourced by appliers (auto-fix-common.sh)
tests/                       Reconciliation, parity, and auto-fix test harnesses
docs/dev_plans/              Development plans
docs/skills_architecture/    Skills architecture design docs (source; rendered via /plan-view --rich)
justfile                     Task runner config
.deep-review/                Gitignored runtime state and auto-fix manifests for /deep-review (per-run)
.review-plan/                Gitignored auto-fix manifests for /review-plan (per-run)
docs/_plan_view/             Gitignored generated HTML output from /plan-view (default out dir; sibling of docs/dev_plans/)
_rich_manifest.json          /plan-view `--rich` manifest of plans needing LLM re-render (written inside the output dir)
                             Deterministic and rich pages are cross-linked: forward links (plain → `.rich.html`) are emitted unconditionally; back-links (rich → plain/index, breadcrumb) are injected idempotently by `relink_rich_pages()` on every plain run, back-filling pre-existing rich pages.
```

### Path-resolution idiom (harness-divergent)

- **Claude mirror** (`plugins/skein/skills/<name>/SKILL.md`): bundled-script anchors use `${CLAUDE_PLUGIN_ROOT}/skills/<name>/scripts/...`. Resolution is **template substitution at SKILL.md render time** — `$SKILL_DIR` is not exported on Claude.
- **Codex mirror** (`plugins/skein-codex/skills/<name>/SKILL.md`): anchors use `"$SKILL_DIR"/scripts/...`. Codex env-exports `$SKILL_DIR` to the bundled-script subprocess.

This divergence is intentional and parallels the existing dispatch-idiom split (`Agent` on Claude vs `spawn_agent` on Codex).

### Auto-fix tier (opt-in)

`/deep-review` and `/review-plan` accept `--auto-fix=trivial` to apply a hard-coded allowlist of mechanical fixes from lens-emitted `auto_fix` blocks. The default tier is advisory-only.

- Single source of truth for allowed kinds: `scripts/auto-fix-allowlist.json`. Cited byte-identical in all four `SKILL.md` mirrors; enforced by `scripts/check-prompt-parity.sh` and `tests/parity/test-allowlist-byte-identity.sh`.
- Pipeline: lens emits v2 envelope → `scripts/reconcile-findings.sh --skill <s>` merges → `scripts/audit-auto-fix-eligibility.sh` annotates `auto_fix_status` → `scripts/render-reconciled-report.sh` renders → `scripts/apply-auto-fix-code.sh` (deep-review) or `scripts/apply-auto-fix-plan.sh` (review-plan) commits.
- Bundled for portability: `scripts/bundle-appliers.sh` copies the pipeline byte-for-byte into each skill's `scripts/` subtree (preserving `scripts/lib/`), so SKILL.md invokes it via the harness-appropriate path anchor (see Path-resolution idiom above) and `--auto-fix` resolves from any cwd — not just the repo. The appliers self-locate via `BASH_SOURCE`; the lib's `../..` walk requires the bundled layout depth be preserved. Canonical `scripts/` wins; bundled copies are generated artifacts whose byte-identity is enforced by `tests/parity/test-applier-bundle-parity.sh` and the `check-sync` canonical↔bundle gate. Run `just bundle-appliers` after editing any canonical applier. If the bundled `scripts/` is absent at runtime the skill hard-fails (`tests/parity/test-no-manual-apply-fallback.sh`) — it never falls back to hand-applying.
- Code applier requires `--test-cmd` (or `AUTO_FIX_TEST_CMD`); runs the command exactly once per fix, restores from a saved blob on failure without touching `HEAD`.
- Plan applier writes prose edits with `Auto-Fixed-By: review-plan` trailer; the real `<!-- reviewed: … -->` marker is only refreshed at the normal `/review-plan` acceptance step. `marker_pending` in the manifest does not satisfy `/conduct` preflight.
- Manifests land in `.deep-review/auto-fix-<unix>-<pid>.json` and `.review-plan/auto-fix-<unix>-<pid>.json` (gitignored). PID suffix avoids same-second collisions if the advisory mkdir lock is bypassed.

## Authority Model

The plugin tree is the authoritative source; install runs through the harness plugin CLI.

- Authored sources: `plugins/skein/skills/` (Claude) and `plugins/skein-codex/skills/` (Codex).
- Install target: each harness's plugin cache (`~/.claude/plugins/...` and `~/.codex/plugins/cache/...`), populated by the plugin CLI. The cache is not edited by hand.
- The two skill copies are **not byte-identical** — the per-harness dispatch idiom (`Agent` vs `spawn_agent`) and the path-resolution idiom above are legitimate divergences. They must not be collapsed.
- Content guidelines authority: repo-canonical file at `plugins/skein-codex/skills/content-review/references/content-guidelines.md`. Mirror at `plugins/skein/skills/content-review/references/content-guidelines.md`. Both ship inside the plugin tree on install — no separate references copy step is needed.
- `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md` are **owned by the `skills.md` repo, not skein** (one-way ownership split; the two repos are not synced). Do not edit them from skein and do not add a sync shim.

## Plugin install

Install runs through the harness plugin CLI; there are no rsync/promote/sync/bootstrap scripts in skein.

Both harnesses can install directly from the public GitHub repo; clone-first is only needed for local development.

- **Claude**: marketplace declared in `.claude-plugin/marketplace.json` (marketplace name: `skein`, plugin source: `./plugins/skein`).
  ```bash
  /plugin marketplace add vr000m/skein
  /plugin install skein@skein
  ```
- **Codex**: marketplace declared in `.agents/plugins/marketplace.json` (marketplace name: `skein`, plugin source: `./plugins/skein-codex`). Codex clones the marketplace repo first, then resolves the plugin's relative `local` source inside the clone.
  ```bash
  codex plugin marketplace add vr000m/skein --ref main
  codex plugin add skein@skein
  ```
  (The verb is `add`, not `install`.)

For local development against a clone, swap the marketplace source for a path: `/plugin marketplace add /path/to/skein` or `codex plugin marketplace add /path/to/skein`.

**Propagating repo edits to a live install:** re-run `/plugin install skein@skein` on Claude, or `codex plugin add skein@skein` on Codex, after editing the relevant mirror. If you installed from the public GitHub source, re-`marketplace add` to fetch the latest commit first. There is no sync step that runs in the background.

**Versioning and releases:** skein follows SemVer; changes are recorded in [`CHANGELOG.md`](CHANGELOG.md) (Keep a Changelog format). The first tagged release is **v0.1.0**, queued for immediately after the public-install PR merges. Until v0.1.0 ships, all install commands above resolve against `main`; once it ships, pin Codex installs with `--ref v0.1.0` (or a later tag) instead of `--ref main`.

**Cutting a release:** after merging a release-worthy commit set to `main`, (1) rename the `[Unreleased]` section in `CHANGELOG.md` to `[X.Y.Z] - YYYY-MM-DD` and start a fresh `[Unreleased]` above it; (2) bump `version` in `plugins/skein/.claude-plugin/plugin.json` and `plugins/skein-codex/.codex-plugin/plugin.json`; (3) commit as `release: vX.Y.Z`; (4) `git tag -a vX.Y.Z -m "skein vX.Y.Z"` and `git push origin vX.Y.Z`; (5) `gh release create vX.Y.Z` with the new changelog section as the body.

**Cleaning up pre-plugin flat copies:** the older flat layout (`~/.claude/skills/<name>/` and `~/.codex/skills/<name>/` populated by the deleted `promote-skills.sh` / `bootstrap-skills.sh`) is removed via `scripts/delete-skills.sh`. Back up first per the repo's destructive-ops rule.

## Skill Workflow

Recommended development workflow using skills:

1. `skein:dev-plan create feature xyz` — Create the plan; on `create` only, dispatches one fresh-context Explore subagent that returns structured codebase facts (verified paths, observed patterns, dependency versions, verified git refs) which land above the review marker. `update` and `complete` do not re-explore.
2. `skein:review-plan` — Audit the plan by dispatching four parallel fresh-context lens agents (`architecture`, `sequencing`, `spec-and-testing`, `codebase-claims`); reconciles findings by structural `(file, line, category)` signature and surfaces same-location-different-category findings as cross-references; blocks until complete, and on acceptance writes a review marker footer consumed by `skein:conduct`. Cost: three high-reasoning lenses plus one cheap factual lens per run.
3. Address review findings, update plan as needed.
4. `skein:conduct` — Walk a reviewed linear plan phase by phase, delegating implementation + tests per phase to harness-native clean-context subagents while preserving the shared review-marker, phase-slot, report-schema, and handback contracts. On `--resume`, a stale review marker is auto-refreshed in place; initial runs and missing markers still hard-stop. Pair with `skein:fan-out` at the outer layer when phases themselves fan out.
5. `skein:fan-out` — Fan out independent tasks to parallel agents (or implement manually).
6. `skein:deep-review` — Run a multi-lens code review after implementation and before merge. Reconciles findings by structural signature to suppress false-positive amplification across lenses.

Skills delegate heavy phases (research, analysis, report generation) to subagents and return only the structured result to the main context. This keeps main context lean and preserves token budgets on long sessions. User-facing I/O (confirmations, applying edits, presenting results) stays in the main context.

**Dual-harness plans need both harnesses to review.** If a plan touches files under `plugins/skein/skills/<skill>/` AND `plugins/skein-codex/skills/<skill>/` (or any harness-specific runtime path), run `skein:review-plan` once in Claude AND once in Codex against the same plan, in separate sessions. Each harness only knows its own runtime — Claude uses the `Agent` tool and `subagent_type: general-purpose`; Codex uses `spawn_agent` / `wait_agent` / `close_agent` with `fork_context: false`; each side has runtime-specific SKILL.md sections (e.g. Codex's "Delegation Availability"). A single-harness review will miss the other side's invariants. Reconcile findings before starting implementation.

**Delegation depth: one level per orchestrator tree.** A skill (the orchestrator) may spawn workers — Claude `Agent`-tool subagents and Codex `spawn_agent` workers in `deep-review`, `review-plan`, and `conduct`, plus worktree processes in `fan-out` — but those workers must not themselves spawn further workers within the same tree. Workers launched in a fresh subprocess/session (for example via `fan-out.sh spawn`) start a new orchestrator/worker tree and may themselves act as orchestrators; the one-level rule applies per-tree. Keeping a flat orchestrator/worker tree makes context isolation, result aggregation, and (for fan-out) merge accounting tractable.

## Review Checklist

Use this section for project-specific won't-fix and analysis-error patterns that deep review should suppress on future runs. Keep entries stable, specific, and dated.
Format: `- **[Category] disposition**: description (YYYY-MM-DD)`

- **[Architecture] won't-fix**: two skill copies per harness (`plugins/skein/skills/` and `plugins/skein-codex/skills/`) retained for dispatch-idiom divergence (2026-03-17, scope updated 2026-05-26 for plugin layout)
- **[Architecture] won't-fix**: harness-divergent path-resolution idiom (Claude `${CLAUDE_PLUGIN_ROOT}` substitution vs Codex `$SKILL_DIR` env-export) is the working contract — do not collapse to a single anchor form (2026-05-25)

## Gotchas

- **Repo invariants are orthogonal to install mechanism.** `just check-sync` / `check-prompt-parity` / `check-trunk-snippet-parity` / `parity-tests` / `reconciliation-tests` operate inside the plugin tree (canonical `scripts/` ↔ bundled skill `scripts/`, and Claude-mirror ↔ Codex-mirror SKILL.md parity). Run them after editing canonical scripts or either mirror's SKILL.md.
- **Do not edit `~/.claude/CLAUDE.md` or `~/.codex/AGENTS.md` from skein** — those globals are owned by the `skills.md` repo.
- **Re-install after edits.** A `git pull` or local edit in this repo does not propagate to a live plugin install until you re-run `/plugin install skein@skein` (Claude) or `codex plugin add skein@skein` (Codex). If installed from GitHub, re-`marketplace add` first to refresh the cached commit.
- **Bundled scripts are generated.** Edit the canonical files under `scripts/` (and `scripts/lib/`), then run `just bundle-appliers` to refresh each skill's `scripts/` subtree. `just check-sync` enforces canonical↔bundle byte-identity.
- **Path anchors differ per mirror.** When editing `deep-review/SKILL.md` or `review-plan/SKILL.md`, keep the Claude mirror on `${CLAUDE_PLUGIN_ROOT}/skills/<name>/scripts/...` and the Codex mirror on `"$SKILL_DIR"/scripts/...`. The prompt-parity check tolerates this specific divergence.
