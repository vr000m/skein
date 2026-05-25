# skills.md

Reusable skills repo for Claude Code and OpenAI Codex CLI agents.

## Commands

```bash
just sync-skills        # Mirror global -> repo (day-to-day)
just promote-skills     # Set repo -> global (intentional overwrite)
just bootstrap-skills   # Init missing managed skills on new machine
just bootstrap-skills-force  # Force overwrite bootstrap
just check-sync         # Validate sync state (incl. canonical<->bundle byte-identity)
just bundle-appliers    # Regenerate the bundled auto-fix pipeline inside each skill
just parity-tests       # Bundle + allowlist + orchestration-contract + no-fallback parity
just reconciliation-tests  # Reconciliation parity + fixture + renderer + determinism suite
just lint-scripts       # shellcheck + shfmt on scripts/
```

Requires: `brew install just jq shellcheck shfmt`

## Architecture

```
.claude/skills/     Claude Code skills (SKILL.md per skill; deep-review/review-plan also carry a generated scripts/ subtree)
.codex/skills/      Codex CLI skills (mirrored structure; same generated scripts/ subtree)
scripts/            Canonical shell scripts for sync/promote/bootstrap/check/reconcile/parity/render/auto-fix/bundle
scripts/lib/        Shared bash helpers sourced by appliers (auto-fix-common.sh)
tests/              Reconciliation, parity, and auto-fix test harnesses
docs/dev_plans/     Development plans
docs/skills_architecture/  Skills architecture design docs (source; rendered via /plan-view --rich)
justfile            Task runner config
.env.example        Template for local env overrides
.deep-review/       Gitignored runtime state and auto-fix manifests for /deep-review (per-run)
.review-plan/       Gitignored auto-fix manifests for /review-plan (per-run)
docs/_plan_view/    Gitignored generated HTML output from /plan-view (default out dir; sibling of docs/dev_plans/)
_rich_manifest.json /plan-view `--rich` manifest of plans needing LLM re-render (written inside the output dir)
                    Deterministic and rich pages are cross-linked: forward links (plain → `.rich.html`) are emitted unconditionally; back-links (rich → plain/index, breadcrumb) are injected idempotently by `relink_rich_pages()` on every plain run, back-filling pre-existing rich pages.
```

### Auto-fix tier (opt-in)

`/deep-review` and `/review-plan` accept `--auto-fix=trivial` to apply a hard-coded allowlist of mechanical fixes from lens-emitted `auto_fix` blocks. The default tier is advisory-only.

- Single source of truth for allowed kinds: `scripts/auto-fix-allowlist.json`. Cited byte-identical in all four `SKILL.md` mirrors; enforced by `scripts/check-prompt-parity.sh` and `tests/parity/test-allowlist-byte-identity.sh`.
- Pipeline: lens emits v2 envelope → `scripts/reconcile-findings.sh --skill <s>` merges → `scripts/audit-auto-fix-eligibility.sh` annotates `auto_fix_status` → `scripts/render-reconciled-report.sh` renders → `scripts/apply-auto-fix-code.sh` (deep-review) or `scripts/apply-auto-fix-plan.sh` (review-plan) commits.
- Bundled for portability: `scripts/bundle-appliers.sh` copies the pipeline byte-for-byte into each skill's `scripts/` subtree (preserving `scripts/lib/`), so SKILL.md invokes it via `"$SKILL_DIR"/scripts/…` (the harness-disclosed skill base dir) and `--auto-fix` resolves from any cwd — not just the repo. The appliers already self-locate via `BASH_SOURCE`, so no script edits are needed; the lib's `../..` walk requires the bundled layout depth be preserved. Canonical `scripts/` wins; bundled copies are generated artifacts whose byte-identity is enforced by `tests/parity/test-applier-bundle-parity.sh` and the `check-sync` canonical<->bundle gate. Run `just bundle-appliers` after editing any canonical applier, then `just promote-skills` (the global→repo `sync-skills` re-bundles from canonical so a stale global copy cannot clobber the repo). If the bundled `scripts/` is absent at runtime the skill hard-fails (`tests/parity/test-no-manual-apply-fallback.sh`) — it never falls back to hand-applying.
- Code applier requires `--test-cmd` (or `AUTO_FIX_TEST_CMD`); runs the command exactly once per fix, restores from a saved blob on failure without touching `HEAD`.
- Plan applier writes prose edits with `Auto-Fixed-By: review-plan` trailer; the real `<!-- reviewed: … -->` marker is only refreshed at the normal `/review-plan` acceptance step. `marker_pending` in the manifest does not satisfy `/conduct` preflight.
- Manifests land in `.deep-review/auto-fix-<unix>-<pid>.json` and `.review-plan/auto-fix-<unix>-<pid>.json` (gitignored). PID suffix avoids same-second collisions if the advisory mkdir lock is bypassed.

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
