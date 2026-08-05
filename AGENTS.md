# skein

Namespaced skill plugin for Claude Code and OpenAI Codex CLI agents. All skills load under the `skein:` namespace per harness.

## Commands

```bash
just check-sync                  # canonical scripts/ <-> bundled skill scripts byte-identity
just check-prompt-parity         # Claude vs Codex SKILL.md prompt parity (bundle skills)
just check-trunk-snippet-parity  # trunk-resolution snippet parity
just bundle-appliers             # Regenerate the bundled auto-fix pipeline inside each skill
just parity-tests                # Bundle + allowlist + orchestration-contract + no-fallback + marker + managed-skill/cleanup-boundary regression coverage
just gauntlet-tests               # review-gauntlet suite: goal-field schema/injection/docs + skill-shape + convergence-ledger + run-gate + reuse-wiring + marker + conduct/fan-out hooks + Codex capability-gap
just reconciliation-tests        # Reconciliation parity + fixture + renderer + determinism suite + review-plan state persistence + report-template lint
just lint-scripts                # shellcheck + shfmt on scripts/
```

Requires: `brew install just jq shellcheck shfmt`

## Architecture

```
plugins/skein/skills/        Claude Code skills (SKILL.md per skill; deep-review/review-plan/review-gauntlet also carry a generated scripts/ subtree)
plugins/skein-codex/skills/  Codex CLI skills (mirrored structure; same generated scripts/ subtree; per-harness dispatch idiom retained)
.claude-plugin/marketplace.json   Claude marketplace entry (name: skein)
.agents/plugins/marketplace.json  Codex marketplace entry (name: skein)
plugins/skein/.claude-plugin/plugin.json       Claude plugin manifest
plugins/skein-codex/.codex-plugin/plugin.json  Codex plugin manifest
scripts/                     Canonical shell scripts for check-sync/reconcile/parity/render/auto-fix/bundle
scripts/lib/                 Shared bash helpers sourced by appliers (auto-fix-common.sh) and by the two persist-*.sh state-file scripts (persist-common.sh)
tests/                       Reconciliation, parity, and auto-fix test harnesses
docs/dev_plans/              Development plans
docs/skills_architecture/    Skills architecture design docs (source; rendered via /plan-view --rich)
justfile                     Task runner config
.deep-review/                Gitignored runtime state and auto-fix manifests for /deep-review (per-run)
.review-plan/                Gitignored auto-fix manifests + latest-<harness>.json reconciled-envelope state for /review-plan (per-run)
docs/_plan_view/             Gitignored generated HTML output from /plan-view (default out dir; sibling of docs/dev_plans/)
_rich_manifest.json          /plan-view `--rich` manifest of plans needing LLM re-render (written inside the output dir)
                             Deterministic and rich pages are cross-linked: forward links (plain → `.rich.html`) are emitted unconditionally; back-links (rich → plain/index, breadcrumb) are injected idempotently by `relink_rich_pages()` on every plain run, back-filling pre-existing rich pages.
```

### Path-resolution idiom (harness-divergent)

- **Claude mirror** (`plugins/skein/skills/<name>/SKILL.md`): bundled-script anchors use `${CLAUDE_PLUGIN_ROOT}/skills/<name>/scripts/...`. Resolution is **template substitution at SKILL.md render time** — `$SKILL_DIR` is not exported on Claude.
- **Codex mirror** (`plugins/skein-codex/skills/<name>/SKILL.md`): anchors use `"$SKILL_DIR"/scripts/...`. Codex env-exports `$SKILL_DIR` to the bundled-script subprocess.

This divergence is intentional and parallels the existing dispatch-idiom split (`Agent` on Claude vs `spawn_agent` on Codex).

### Model/Effort Policy (target policy, not yet fully enforced)

Every subagent spawn should declare its own model/effort tier rather than inheriting the parent session's — this is the policy of record the tree is converging to. It is being rolled out in phases (see `docs/dev_plans/20260704-chore-model-effort-explicit-spawns.md`): as of this doc, an enforcing cross-skill census and full spawn compliance have not yet landed, so the presence of this section is **not** proof that every spawn below is already tiered. Treat it as the target, verify compliance against the actual `SKILL.md` files.

The two-tier policy, harness-independent:

- **Judgment work → strongest model, high effort.** Plan review, code review, and planning reasoning (e.g. `review-plan`'s judgment lenses, `deep-review`'s logic/security/spec/architecture lenses, `spec-compliance`, `conduct`'s advisory reviewer) bet on a strong reviewer at high effort catching the details. On the Claude side, `review-plan`'s four judgment lenses (`architecture`, `sequencing`, `spec-and-testing`, `assumptions`) are the one skill currently pinned to `model: fable` rather than `opus`, with an automatic single-lens retry at `opus` if a fable dispatch errors out on a usage-limit/quota condition (the retry trigger is plan-agnostic — it reacts to the quota-error text, not to which plan is active; see `plugins/skein/skills/review-plan/SKILL.md` Cost section for the current plan-dependent cap/credit figures) — this is a deliberate, skill-scoped exception, not a blanket "strongest model" redefinition; every other judgment-tier spawn listed here (`deep-review`, `spec-compliance`, `conduct`'s advisory reviewer) stays on `opus` until re-evaluated.
- **Mechanical work → cheaper model, lower effort.** Implementation and testing (e.g. `conduct`'s implementer/test-writer, `fan-out`'s worker, `plan-view` render, `dev-plan`'s Explore, `content-draft`, `content-review`, `update-docs`, `rfc-finder`) execute an already-reviewed plan and don't need heavy reasoning.
- **Factual lookups stay cheapest regardless of the skill they live in** (e.g. `review-plan`'s `codebase-claims` lens, `deep-review`'s `documentation` lens) — checking whether a path/API exists or a doc is stale is a lookup, not reasoning.
- **`review-gauntlet`'s gate tiers follow the same split, not a uniform tier.** The gates it chains keep their own native model/effort policy unchanged — adversarial Codex review via `codex exec review`, `skein:deep-review`'s four judgment lenses at high effort/opus plus its cheap documentation lens, `/security-review` at whatever tier that skill declares. `/code-review` is not a gate on the Claude side — the harness blocks Claude from invoking it on its own; run `/code-review xhigh --fix` yourself when you want that pass. The gauntlet does not override any gate's tier; only the **fixer** batch is a gauntlet-owned spawn, and it is mechanical-tier (implementation work applying already-decided fixes), matching `conduct`'s implementer tier rather than the judgment-lens tier of the gates that found the issues.

The inheritance invariant: every spawn declares its own tier; no spawn inherits the session tier for mechanical work. A strong main loop (e.g. a top-tier default model) must push work down to cheaper tiers explicitly, not silently run mechanical work at its own expensive tier by omission.

Per-harness idiom (the split itself is sanctioned, not drift — see `docs/dev_plans/CODEX_MIRROR_BACKLOG.md`):

- **Claude**: set `model:` and `effort:` explicitly on the `Agent` tool call.
- **Codex**: inherit the harness-selected model; request `reasoning_effort=high|medium|low` in prose when the target skill/tool supports it, rather than pinning a model name.

### Auto-fix tier (opt-in)

`/deep-review` and `/review-plan` accept `--auto-fix=trivial` to apply a hard-coded allowlist of mechanical fixes from lens-emitted `auto_fix` blocks. The default tier is advisory-only.

- Single source of truth for allowed kinds: `scripts/auto-fix-allowlist.json`. Cited byte-identical in all four `SKILL.md` mirrors; enforced by `scripts/check-prompt-parity.sh` and `tests/parity/test-allowlist-byte-identity.sh`.
- Pipeline: lens emits v2 envelope → `scripts/reconcile-findings.sh --skill <s>` merges → `scripts/audit-auto-fix-eligibility.sh` annotates `auto_fix_status` → `scripts/render-reconciled-report.sh` renders → `scripts/apply-auto-fix-code.sh` (deep-review) or `scripts/apply-auto-fix-plan.sh` (review-plan) commits.
- `/review-plan` persists its Step 3 reconciled envelope (extended with `plan_path`/`plan_hash`/`run_id`) to `.review-plan/latest-<harness>.json` via the canonical `scripts/persist-review-state.sh`, invoked from the bundled per-harness path anchor the same way the auto-fix pipeline is; every rendered report ends with a `**Full findings JSON**:` footer pointing at that file. `scripts/check-report-templates.sh` is a repo-level lint that greps both skills' `SKILL.md`/`rubric.md` mirrors for the literal tokens the compact-Minor rendering contract depends on (the `(file:line)` grammar, the `**Full findings JSON**:` marker, the rubric's "restored with `--verbose`" phrase) — run via `just reconciliation-tests`, alongside `tests/reconciliation/test-review-plan-state.sh`, which covers `persist-review-state.sh`'s write/overwrite/failure paths.
- `/deep-review` (Claude mirror) persists the RAW per-lens status/findings object assembled after Step 2 — a deliberately different schema from review-plan's reconciled envelope — to `.deep-review/latest-<harness>.json` via the canonical `scripts/persist-deep-review-state.sh`, wrapping the input under a `lenses` key alongside `schema_version: 1`, `run_id`, `base_commit`, `head_commit`, `diff_hash`, and `review_focus_hash`. Same exit-code contract (0/1/2) as `persist-review-state.sh`, and both scripts now share their root-anchoring, CLI required-value check, and symlink-guarded atomic-write logic via `scripts/lib/persist-common.sh` (bundled alongside each of them, not into `review-gauntlet`'s mirrors). Covered by `tests/reconciliation/test-deep-review-state.sh`, wired into `just reconciliation-tests`. **Both mirrors are wired.** The Codex mirror (`plugins/skein-codex/skills/deep-review/SKILL.md`) invokes the same `scripts/persist-deep-review-state.sh` via its own `"$SKILL_DIR"` anchor and prose idiom and branches on the identical exit-code contract, authored via `codex:rescue` and independently verified by a second, fresh-thread `codex:rescue` review pass (verdict: PASS, no defects) per Requirement 11's authoring convention.
- Bundled for portability: `scripts/bundle-appliers.sh` copies the pipeline byte-for-byte into each skill's `scripts/` subtree (preserving `scripts/lib/`), so SKILL.md invokes it via the harness-appropriate path anchor (see Path-resolution idiom above) and `--auto-fix` resolves from any cwd — not just the repo. The appliers self-locate via `BASH_SOURCE`; the lib's `../..` walk requires the bundled layout depth be preserved. Canonical `scripts/` wins; bundled copies are generated artifacts whose byte-identity is enforced by `tests/parity/test-applier-bundle-parity.sh` and the `check-sync` canonical↔bundle gate. Run `just bundle-appliers` after editing any canonical applier. If the bundled `scripts/` is absent at runtime the skill hard-fails (`tests/parity/test-no-manual-apply-fallback.sh`) — it never falls back to hand-applying.
- `review-gauntlet` (`BUNDLE_SKILLS` in `scripts/lib/bundle-map.sh`) gets its own bundled copy of the same pipeline — reusing `apply-auto-fix-code.sh` (hardcoded `SKILL="deep-review"` internally, so it applies the deep-review trivial allowlist regardless of which skill bundles it) rather than forking a fourth allowlist. The gauntlet's fixer routes trivial/allowlisted findings through this bundled applier and makes substantive logic/security fixes as direct edits; it never reaches into `deep-review/scripts/` by relative path.
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

**Versioning and releases:** skein follows SemVer; changes are recorded in [`CHANGELOG.md`](CHANGELOG.md) (Keep a Changelog format). Tags v0.1.0 through v0.5.1 are cut; pin an install to a specific tag with `--ref vX.Y.Z` instead of `--ref main` if you want a stable version rather than tracking `main`.

**Cutting a release:** for a single release-worthy change set, fold the CHANGELOG promotion and version bump into the feature PR itself (no separate release PR needed); the tag and GitHub release are created post-merge on `main`. (1) In the PR, rename the `[Unreleased]` section in `CHANGELOG.md` to `[X.Y.Z] - YYYY-MM-DD`, start a fresh `[Unreleased]` above it, and update the compare-link footer; (2) in the same PR, bump `version` in `plugins/skein/.claude-plugin/plugin.json` and `plugins/skein-codex/.codex-plugin/plugin.json`; (3) merge to `main` (regular merge, no squash); (4) update local `main`, then invoke `skein:release X.Y.Z`; the skill owns the annotated-tag creation/push and GitHub release creation or re-sync, and presents the exact target, title, and body for confirmation before mutating remote state. Do not hand-run the old `git tag` + `gh release create` sequence. When **batching several merged change sets** into one release, instead keep accumulating under `[Unreleased]` and cut a dedicated `release: vX.Y.Z` commit (or release PR) on `main` for steps 1–2 before invoking the skill.

**Cleaning up pre-plugin flat copies:** the older flat layout (`~/.claude/skills/<name>/` and `~/.codex/skills/<name>/` populated by the deleted `promote-skills.sh` / `bootstrap-skills.sh`) is removed via `scripts/delete-skills.sh`. Its destructive target is the immutable 11-skill migration-era set (`conduct`, `content-draft`, `content-review`, `deep-review`, `dev-plan`, `fan-out`, `plan-view`, `review-plan`, `rfc-finder`, `spec-compliance`, `update-docs`); post-migration `grill`, `release`, and `review-gauntlet` directories are deliberately preserved. Back up first per the repo's destructive-ops rule. Regression command: `uvx pytest tests/parity/test_delete_skills.py -q`.

## Skill Workflow

Recommended development workflow using skills:

1. `skein:dev-plan create feature xyz` — Create the plan; on `create` only, dispatches one fresh-context Explore subagent that returns structured codebase facts (verified paths, observed patterns, dependency versions, verified git refs) which land above the review marker. For plans with 2+ independently-executing components, `create` also drafts a conditional `## Architecture & Call Flow` section (component graph + sequence diagram + context-lifecycle table) and confirms it at a gate before writing phases. `update` and `complete` do not re-explore.
2. `skein:review-plan` — Audit the plan by dispatching five parallel fresh-context lens agents (`architecture`, `sequencing`, `spec-and-testing`, `assumptions`, `codebase-claims`), plus one additional pass after reconciliation — the Contradiction Pass — that flags plan-internal contradictions (one section states X, another assumes not-X) and cross-lens contradictions (two lenses imply mutually exclusive fixes); the architecture lens also reconstructs the implied call-flow and flags negative-space topology gaps; reconciles findings by structural `(file, line, category)` signature and surfaces same-location-different-category findings as cross-references. A default-on triage-and-clarify elicitation loop then records decisions into the plan (via `/dev-plan update` above the marker; waivers below it) before the review marker footer (consumed by `skein:conduct`) is written; pass `--batch` to skip the loop for unattended/CI runs. Findings classified as grill-eligible (architecture/component-boundary, third-party integration, security, rate-limiting decisions, or any `Contradiction` finding — always grill-eligible regardless of subject matter) are delegated inline to `skein:grill` — also a standalone, user-invocable skill in its own right — for its interview protocol (fact/decision split, one recommendation each, blocking accept/override/waive) rather than resolved with the loop's usual fixed-option picker. Cost: five high-reasoning lenses plus one cheap factual lens per run — four parallel judgment lenses plus one additional pass after reconciliation.
3. Address review findings, update plan as needed.
4. `skein:conduct` — Walk a reviewed linear plan phase by phase, delegating implementation + tests per phase to harness-native clean-context subagents while preserving the shared review-marker, phase-slot (`**Impl files:**`, `**Test files:**`, `**Test command:**`, optional `**Validation cmd:**`, optional `**Goal:**` — a 1-2 line per-phase design intent injected into implementer/test-writer prompts as `{{PHASE_GOAL}}`), report-schema, and handback contracts. On `--resume`, a stale review marker is auto-refreshed in place; initial runs and missing markers still hard-stop. Pair with `skein:fan-out` at the outer layer when phases themselves fan out.
5. `skein:fan-out` — Fan out independent tasks to parallel agents (or implement manually).
6. `skein:deep-review` — Run a multi-lens code review after implementation and before merge. Reconciles findings by structural signature to suppress false-positive amplification across lenses.
7. `skein:review-gauntlet` — Chain the review gates (adversarial Codex review, deep-review, security-review) into one convergence loop, applying fixes via isolated fixer subagents until findings stop appearing. `/code-review` is not a gate here — the Claude Code harness blocks Claude from invoking it on its own; run `/code-review xhigh --fix` yourself. Opt-in via a plan's `**Review Gates:** full` header field (default `none`); `conduct`'s terminal step and `fan-out`'s Phase 6 auto-chain into it when the plan opts in. Standalone and auto-chain invocation both run the up-to-10-loop convergence algorithm with structural-restart, single-confirming-pass, and non-convergence-bail stop conditions — there is no single-pass mode. `--resume`/`--fresh` (mirroring `conduct`'s own `--resume` convention above) pick an interrupted run back up from a target-keyed ledger (`gc_ledger_path`, under repo-root `.gauntlet/`) instead of restarting the gate corpus; `conduct`/`fan-out` auto-chain invocations are self-resuming by construction (peek the ledger first) and never pass either flag.

Skills delegate heavy phases (research, analysis, report generation) to subagents and return only the structured result to the main context. This keeps main context lean and preserves token budgets on long sessions. User-facing I/O (confirmations, applying edits, presenting results) stays in the main context.

**Dual-harness plans need both harnesses to review.** If a plan touches files under `plugins/skein/skills/<skill>/` AND `plugins/skein-codex/skills/<skill>/` (or any harness-specific runtime path), run `skein:review-plan` once in Claude AND once in Codex against the same plan, in separate sessions. Each harness only knows its own runtime — Claude uses the `Agent` tool and `subagent_type: general-purpose`; Codex uses `spawn_agent` / `wait_agent` / `close_agent` with `fork_context: false`; each side has runtime-specific SKILL.md sections (e.g. Codex's "Delegation Availability"). A single-harness review will miss the other side's invariants. Reconcile findings before starting implementation.

**Delegation depth: one level per orchestrator tree.** A skill (the orchestrator) may spawn workers — Claude `Agent`-tool subagents and Codex `spawn_agent` workers in `deep-review`, `review-plan`, and `conduct`, plus worktree processes in `fan-out` — but those workers must not themselves spawn further workers within the same tree. Workers launched in a fresh subprocess/session (for example via `fan-out.sh spawn`) start a new orchestrator/worker tree and may themselves act as orchestrators; the one-level rule applies per-tree. Keeping a flat orchestrator/worker tree makes context isolation, result aggregation, and (for fan-out) merge accounting tractable.

## Review Checklist

Use this section for project-specific won't-fix and analysis-error patterns that deep review should suppress on future runs. Keep entries stable, specific, and dated.
Format: `- **[Category] disposition**: description (YYYY-MM-DD)`

- **[Architecture] won't-fix**: two skill copies per harness (`plugins/skein/skills/` and `plugins/skein-codex/skills/`) retained for dispatch-idiom divergence (2026-03-17, scope updated 2026-05-26 for plugin layout)
- **[Architecture] won't-fix**: harness-divergent path-resolution idiom (Claude `${CLAUDE_PLUGIN_ROOT}` substitution vs Codex `$SKILL_DIR` env-export) is the working contract — do not collapse to a single anchor form (2026-05-25)
- **[Security] won't-fix**: `scripts/audit-auto-fix-eligibility.sh`'s `resolve_path` accepts absolute paths from the untrusted finding envelope (used only for a read-only line-content drift check, never a write); tightening it to the applier's stricter `resolve_repo_path` containment guard breaks `tests/reconciliation/test-renderer.sh`'s `audit-then-render-end-to-end` test, which intentionally audits fixture files living outside the repo tree via absolute path. Residual risk is a low-value file-read oracle — the applier independently re-verifies with its own strict guard before any write, so no write-path exposure exists (2026-07-10)
- **[Architecture] won't-fix**: no automated test enumerates `SKILL.md` files carrying `disable-model-invocation: true` and asserts no other skill's prose references them by `/name`/`skein:name` (would harden the Axis-1 chaining invariant from `docs/dev_plans/20260711-chore-skill-invocation-mode-audit.md`). A naive grep-based version was deliberately not built: the plan's own Phase 0 raw-grep pass found ~30 hits per mirror, most of them descriptive cross-references rather than real chaining edges (e.g. `dev-plan/SKILL.md`'s prose mentions of `/plan-view`), so a hard-fail grep test would false-positive on exactly the kind of reference the audit already triaged as safe. A correct version needs an allowlist of known-descriptive references, which is out of scope until a second skill is proposed for `disable-model-invocation` (2026-07-12)

## Gotchas

- **Repo invariants are orthogonal to install mechanism.** `just check-sync` / `check-prompt-parity` / `check-trunk-snippet-parity` / `parity-tests` / `reconciliation-tests` operate inside the plugin tree (canonical `scripts/` ↔ bundled skill `scripts/`, Claude-mirror ↔ Codex-mirror SKILL.md parity, and `conduct/marker.py` byte-identity across both mirrors). Run them after editing canonical scripts or either mirror's SKILL.md.
- **The review marker has one hashing authority: canonical `scripts/marker.py`.** Both `/conduct` (its own `conduct/marker.py` copy) and `/review-plan` (the bundled `review-plan/scripts/marker.py` + the `write-review-marker.py` CLI it ships) compute the byte-faithful marker hash from the same code; `tests/parity/test-marker-parity.sh` anchors every copy byte-identical to `scripts/marker.py`. **Never hand-compute the marker hash in SKILL.md prose** — an LLM following a prose recipe wrote `b'\n'.join(lines[:idx])`, dropped the newline above the marker, and produced false `/conduct` drift (the 0.2.3 fix). `/review-plan` Step 7 invokes the bundled `write-review-marker.py` and aborts if it is absent or if the plan has no divider; it does not append the marker at EOF.
- **Do not edit `~/.claude/CLAUDE.md` or `~/.codex/AGENTS.md` from skein** — those globals are owned by the `skills.md` repo.
- **Re-install after edits.** A `git pull` or local edit in this repo does not propagate to a live plugin install until you re-run `/plugin install skein@skein` (Claude) or `codex plugin add skein@skein` (Codex). If installed from GitHub, re-`marketplace add` first to refresh the cached commit.
- **Bundled scripts are generated.** Edit the canonical files under `scripts/` (and `scripts/lib/`), then run `just bundle-appliers` to refresh each skill's `scripts/` subtree. `just check-sync` enforces canonical↔bundle byte-identity.
- **Path anchors differ per mirror.** When editing `deep-review/SKILL.md` or `review-plan/SKILL.md`, keep the Claude mirror on `${CLAUDE_PLUGIN_ROOT}/skills/<name>/scripts/...` and the Codex mirror on `"$SKILL_DIR"/scripts/...`. The prompt-parity check tolerates this specific divergence.
