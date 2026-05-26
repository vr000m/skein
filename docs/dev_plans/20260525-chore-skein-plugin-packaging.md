# Task: Package managed skills as the `skein` plugin (Claude + Codex)

**Status**: Not Started
**Component**: meta
**Assigned to**: Claude
**Priority**: Medium
**Branch**: feature/skein-plugin-migration (this plan authored in `skills.md`); implementation runs in the cloned **`skein`** repo
**Created**: 2026-05-25
**Completed**: (fill when done)

## Objective

Repackage the 11 managed skills from the flat dual-mirror layout (`.claude/skills/`, `.codex/skills/` promoted into `~/.claude/skills/` and `~/.codex/skills/`) into a single distributable **`skein` plugin** per harness, so every skill is invoked namespaced as `skein:dev-plan`, `skein:plan-view`, etc. — eliminating name collisions with third-party/downloaded skills. The work is done in a **fresh `vr000m/skein` repo cloned from `skills.md`** (full history preserved); `skills.md` is left untouched for now.

## Context

The collection has grown to 11 skills installed *flat* into the global skill dirs. Flat global skills carry the original (un-prefixed) names, so a downloaded plugin shipping its own `dev-plan` or `review` would collide. Claude Code's native collision fix is the **plugin namespace** (`plugin:skill`), and research this session confirmed **Codex also has a plugin/marketplace system** whose plugin `name` supplies the namespace — so the fix is symmetric: one `skein` plugin per target, both fed from this repo.

This is the **foundation** plan. The GTM/lead-intelligence corpus, the `name-finder` skill, and any new GTM skills are explicitly **out of scope** and will slot into the `skein` namespace once it exists. Naming decision (`skein`, domain `skein.sh` registered) is locked.

**Repo strategy (decided 2026-05-25):** implementation happens in a **fresh `vr000m/skein` repo created by `git clone`-ing `skills.md`** so full commit history of every skill is preserved (no `filter-repo` needed unless we later choose to prune). `skills.md` is **left intact, not archived** — the archive-vs-keep-as-dev-lab decision is **deferred** until `skein` is proven (rationale: the skills/tooling may have value beyond the `skein` product). Consequence: because the clone starts from the flat layout, Phase 3 is still an in-place `git mv` + tooling retarget — the C4 atomic-commit constraint still applies (a from-scratch build would drop it but lose history, which we reject).

The migration is mostly structural (move files, add manifests, rework tooling). The Codex packaging surface was reported in detail by a Codex self-review (manifest format, marketplace path, CLI verbs — see Review Focus and Phase 1) and is treated as authoritative-pending-experimental-confirmation. The one genuine unknown that must be resolved before any bulk `git mv` is whether plugin-bundled skills still resolve `$SKILL_DIR` for their helper scripts on **either** harness.

## Requirements

- One flat namespace tier `skein:` per harness — **not** `skein-dev:`/`skein-gtm:` umbrellas. Plugin name = `skein` on both Claude and Codex.
- Grouping is by **skill-name prefix convention** (`content-*`, future `gtm-*`/`lead-*`), not namespace tiers. Cross-domain skills (`conduct`, `fan-out`, `plan-view`, `dev-plan`, `review-plan`) stay generically named — do not domain-tag.
- Preserve git history of moved skill assets — use `git mv`, never delete+add.
- Preserve the legitimate per-harness divergence (the dispatch idiom: `Agent` on Claude vs `spawn_agent` on Codex). The two skill copies are **not** byte-identical and must not be collapsed in this plan.
- Single source of truth maintained: promote/sync/check-sync tooling is **reworked, not bypassed**; `.codex` skills remain a managed mirror (never hand-edited — see memory `feedback_no_codex_edits`).
- Preserve bundle-parity coupling (`deep-review` + `review-plan` share 5 pipeline files via `scripts/lib/bundle-map.sh`) and the `content-review/references` canonical-source-on-`.codex` rule.
- Verify-before-done: the plugin must actually load and trigger as `skein:*` on **both** harnesses with **no duplicate** un-namespaced entries, and the sync/parity guards must pass against the new layout.
- Destructive global cleanup (removing the flat `~/.claude/skills/*` and `~/.codex/skills/*` copies) must back up first per the repo's destructive-ops rule.

## Review Focus

- **`$SKILL_DIR` resolution for bundled helper scripts on BOTH harnesses** (highest-risk seam). SKILL.md files anchor scripts as `"$SKILL_DIR"/scripts/…` (`deep-review/SKILL.md:418,421,429,436,473`; `review-plan/SKILL.md:328,336,343,446`). Codebase-claims confirmed `conduct`/`fan-out` have **no** `$SKILL_DIR` anchors (so the affected set is `deep-review`, `review-plan`, and any `plan-view` runtime path). It is unverified whether `$SKILL_DIR` is exported for plugin-bundled skills on Claude *or* Codex. Phase 1 must prove a shell child receives an absolute path on both before the Phase-3 bulk `git mv`; if not, anchors migrate to `${CLAUDE_PLUGIN_ROOT}/skills/<name>/…` (Claude) and the Codex equivalent, and the rewrite itself must be tested (a grep-guard for surviving `$SKILL_DIR` + one bundled-script smoke from the installed plugin).
- **Codex packaging facts (reported by Codex self-review; confirm experimentally in Phase 1):** manifest is **JSON** at `plugins/skein-codex/.codex-plugin/plugin.json` with fields `name`, strict-semver `version`, `description`, `author.name`, `interface.{displayName,shortDescription,longDescription,developerName,category}`, `interface.capabilities`, `interface.defaultPrompt`, `skills:"./skills/"`; marketplace file at **`.agents/plugins/marketplace.json`** (not `.claude-plugin/`) with entries `{name, source:{source:"local",path:"./plugins/skein-codex"}, policy.installation, policy.authentication, category}`; CLI verbs are `codex plugin marketplace add <path|owner/repo[@ref]|git-url>` then `codex plugin add skein@<marketplace>` — the verb is **`add`, not `install`**.
- **Bundle-parity mechanics (corrected):** `BUNDLE_SHARED` in `bundle-map.sh:15-21` holds paths **relative to canonical `scripts/`**, NOT skill roots — bundle-map needs **zero** path edits. The 5 shared files are *copied into* each skill's `scripts/` subtree and verified byte-identical against canonical `scripts/`. What changes on the move is the bundle **destination** anchor in `check-sync.sh` (~lines 180-181) and `scripts/bundle-appliers.sh`. The actual gate is `tests/parity/test-applier-bundle-parity.sh` (iterates `for mirror in .claude .codex`) — it hard-codes the old layout and **must be retargeted**, asserting it still matches >0 files (non-vacuous).
- **`check-sync` is two-axis** — (a) repo↔global `diff -ru` per skill that *excludes* `scripts/` for bundle skills (preserve the exclusion + its rationale comment), and (b) a separate canonical↔bundle byte-identity check. Both axes must be retargeted, not just (a).
- **Promote is not a single flow** — `promote-skills.sh` does three things: skill-body rsync, `content-review/references` copy to both globals, and `CLAUDE.md`/`AGENTS.md` cp. Only the skill-body promote switches to plugin-`add`; the references and doc copies **remain rsync/cp** (plugin install will not place `~/.claude/CLAUDE.md`).
- **Duplicate-skill / no-skills windows** — final state must have only `skein:*` (assert via `codex plugin list` + Claude skill-list, not just visual). Migration must never pass through a state where *neither* flat nor plugin skills load (see Phase 4 ordering).
- **Dev-time project skills** — `.claude/skills/` currently auto-loads as in-repo project skills; the migration is executed *using* these skills. Phase 1 confirms whether `plugins/skein/skills/` auto-loads in-repo; if not, `skein` must be installed (or phases run from the global install) before the move.
- **History preservation** — `git status` must show **renames** (not add/delete) across the whole move set; spot-check `git log --follow` per distinct asset type (a `.py`, a `SKILL.md`, a `references/` file).

## Implementation Checklist

### Phase 0: Establish the `skein` repo (clone with history)

**Impl files:** (operational — new GitHub repo + local clone; no file edits)
**Test files:** (none — git verification)
**Test command:** `echo "manual: confirm vr000m/skein exists and clone is intact"`
**Validation cmd:** `git -C ../skein log --oneline -1 && git -C ../skein log --follow --oneline -- .claude/skills/plan-view/generate.py | tail -1`

- Create empty GitHub repo `vr000m/skein` (private to start; flip public when ready).
- `git clone` `skills.md` locally to `skein`, set `origin` to `vr000m/skein`, push `main` (full history carried by the clone — verify `git log` depth matches and `git log --follow` traces a pre-existing skill asset).
- Leave `skills.md` untouched (no archive — deferred decision). All subsequent phases run **inside the `skein` clone**, on a `feature/plugin-restructure` branch.
- Carry this plan forward in the clone (it travels with the history); update its `**Branch**` header to the skein-repo branch.

### Phase 1: De-risk spike — confirm formats & runtime path resolution

**Impl files:** `docs/dev_plans/20260525-chore-skein-plugin-packaging.md` (record findings only; no repo restructuring)
**Test files:** (none — manual harness verification; spike output is recorded findings)
**Test command:** `echo "manual: install one-skill skein plugin on each harness, confirm trigger + script path resolution"`
**Validation cmd:** `git status --porcelain` (must show no unintended tracked-file changes from the spike)

- Read official Claude plugin docs (`code.claude.com/docs/en/plugins.md`, `plugins-reference.md`) and run `codex plugin --help`. **Experimentally confirm the Codex-reported facts** (Review Focus): manifest JSON at `.codex-plugin/plugin.json` with the full `interface.*` field set, marketplace at `.agents/plugins/marketplace.json`, and CLI verbs `codex plugin marketplace add …` + `codex plugin add skein@<marketplace>` (verb `add`, not `install`). Use the **local Codex plugin validator** (not just `jq`) to validate a sample manifest.
- Build a *throwaway* single-skill `skein` plugin (use `rfc-finder` — SKILL.md only, no internal assets) for each harness; install locally (`/plugin marketplace add` + `/plugin install skein` on Claude; `codex plugin marketplace add` + `codex plugin add skein@<marketplace>` on Codex); confirm it triggers as `skein:rfc-finder`.
- **`$SKILL_DIR` resolution (gating):** build a second throwaway plugin whose skill invokes a bundled script via `"$SKILL_DIR"/scripts/x.sh`; prove the shell child receives an absolute path on **both** Claude and Codex. Record the decision: `$SKILL_DIR` survives → no SKILL.md edits; else anchors migrate to `${CLAUDE_PLUGIN_ROOT}/skills/<name>/…` (Claude) and the Codex equivalent.
- **Project-skill auto-load check (I3):** determine whether `plugins/skein/skills/` auto-loads as in-repo *project* skills (does Claude read a repo-root `.claude-plugin`/marketplace automatically?). This decides whether the agent executing Phases 3+ must first install `skein` or run from the global install, since the move removes `.claude/skills/` mid-migration.
- **Single-repo distribution check:** confirm both harnesses install from the *same* repo without conflict — (a) the two marketplace files live at different paths (`.claude-plugin/marketplace.json` vs `.agents/plugins/marketplace.json`) so no filename clash; (b) discovery is **manifest-`source.path`-driven, not greedy repo-wide glob**, i.e. Codex loads only `plugins/skein-codex/skills/` and not `plugins/skein/skills/` (and vice versa). Codex self-review indicates (b) holds; confirm it. If (b) fails, fall back to separate per-harness repos (record decision + rationale).
- Decide and record: final repo layout, path-resolution approach, experimentally-confirmed manifest schemas + CLI verbs, project-skill auto-load behaviour, and single-vs-separate-repo distribution. **This phase gates all later phases.**

### Phase 2: Scaffold plugin + marketplace structure

**Impl files:** `.claude-plugin/marketplace.json, plugins/skein/.claude-plugin/plugin.json, .agents/plugins/marketplace.json, plugins/skein-codex/.codex-plugin/plugin.json`
**Test files:** `tests/plugin/test_manifests.sh`
**Test command:** `bash tests/plugin/test_manifests.sh`

- Claude: create root `.claude-plugin/marketplace.json` listing the `skein` plugin (`source: ./plugins/skein`) and `plugins/skein/.claude-plugin/plugin.json` = `{"name":"skein", "version", "description", "author"}`.
- Codex: create `.agents/plugins/marketplace.json` (entry `{name:"skein", source:{source:"local",path:"./plugins/skein-codex"}, policy.installation, policy.authentication, category}`) and `plugins/skein-codex/.codex-plugin/plugin.json` (JSON) with the full confirmed field set (`name`, semver `version`, `description`, `author.name`, `interface.{displayName,shortDescription,longDescription,developerName,category}`, `interface.capabilities`, `interface.defaultPrompt`, `skills:"./skills/"`).
- `test_manifests.sh`: assert each manifest is valid JSON, declares `name: skein`, and (Codex) passes the local Codex plugin validator when available; assert the two marketplace files do not collide in path.
- Leave `skills/` dirs empty at this stage (populated in Phase 3).

### Phase 3: Atomic move + tooling retarget (single boundary commit)

> **Why one phase (C4):** every promote/sync/check-sync script hard-codes `$ROOT_DIR/.{claude,codex}/skills` (`sync-skills.sh:18-19`, `check-sync.sh:44-60`). A commit *between* the `git mv` and the tooling retarget leaves `just check-sync`/`sync`/`promote` failing (`require_dir` exits 1) and the parity guards broken/vacuous. The move and the retarget therefore land in **one commit**; the phase's Test command is the green-at-boundary gate.

**Impl files:** `plugins/skein/skills/*, plugins/skein-codex/skills/* (git mv), scripts/promote-skills.sh, scripts/sync-skills.sh, scripts/check-sync.sh, scripts/bundle-appliers.sh, scripts/bootstrap-skills.sh, justfile, tests/parity/test-applier-bundle-parity.sh, tests/parity/test_skill_md_presence.py`
**Test files:** `tests/plugin/test_history_and_assets.sh, tests/plugin/test_sync_roundtrip.sh, tests/parity/test-applier-bundle-parity.sh, tests/parity/test_skill_md_presence.py`
**Test command:** `just check-sync && bash tests/plugin/test_history_and_assets.sh && bash tests/plugin/test_sync_roundtrip.sh && bash tests/parity/test-applier-bundle-parity.sh && python3 -m pytest tests/parity/test_skill_md_presence.py -q`
**Validation cmd:** `HOME="$(mktemp -d)" bash scripts/bootstrap-skills.sh && bash scripts/check-sync.sh` (bootstrap smoke in a temp HOME — M1)

- `git mv` all 11 skills: `.claude/skills/<name>/` → `plugins/skein/skills/<name>/`, `.codex/skills/<name>/` → `plugins/skein-codex/skills/<name>/`, preserving internal assets (conduct/*.py+prompts+tests, plan-view/generate.py+_widgets+templates+tests, deep-review & review-plan scripts/lib, content-review/references, dev-plan/template.md+rubric.md, fan-out scripts/toolchains, spec-compliance/rubric.md).
- Apply the Phase-1 `$SKILL_DIR` decision. If "rewrite": update anchors in `deep-review/SKILL.md` (418,421,429,436,473) and `review-plan/SKILL.md` (328,336,343,446) to the plugin-root var, and add a grep-guard asserting **no** surviving bare `"$SKILL_DIR"` anchors (I4). If "survives": no SKILL.md edits.
- Retarget `MANAGED_SKILLS` source-path assumptions in `promote-skills.sh:13`, `sync-skills.sh:13`, `check-sync.sh:16` to the `plugins/skein{,-codex}/skills/` roots.
- `promote-skills.sh`: switch only the **skill-body** promote to plugin refresh — `codex plugin add skein@<marketplace>` / Claude plugin refresh, or a safe sync into the plugin source (NOT directly into a version-managed plugin *cache* — I6). **Keep** the `content-review/references` copy (29-38) and the `CLAUDE.md`/`AGENTS.md` cp (63-79) as rsync/cp — plugin install does not place `~/.claude/CLAUDE.md` (I2).
- `check-sync.sh`: retarget **both axes** (I1) — (a) the repo↔global `diff -ru` loop, *preserving* the `scripts/`-exclusion for bundle skills and its rationale comment; (b) the canonical↔bundle byte-identity check, retargeting the destination anchor (~lines 180-181). **`scripts/lib/bundle-map.sh` is NOT edited** — `BUNDLE_SHARED` is canonical-`scripts/`-relative (C2); only `bundle-appliers.sh` and the check-sync destination anchor change.
- Retarget existing parity tests (C3): `tests/parity/test-applier-bundle-parity.sh` (`MIRRORS=(.claude .codex)` + glob) and `tests/parity/test_skill_md_presence.py` (path constants) to the new roots; add a non-vacuous assertion (the bundle glob must match >0 files, so it cannot false-pass).
- `sync-skills.sh` (global→repo) src/dest + excludes (60/66); `bootstrap-skills.sh` rsync paths; `justfile` recipes — all retargeted.

### Phase 4: Migrate the live global install (install-and-verify FIRST, then remove)

> **Ordering (C5):** install + verify the plugin loads *before* removing the flat copies, so there is never a no-skills window; if a real-install manifest mismatch surfaces, the flat skills are still live. Tolerate the brief duplicate-skill window. Keep the backup until post-removal `check-sync` passes.

**Impl files:** (operational — no repo files; backup + install + cleanup actions)
**Test files:** (none — harness verification, partly automatable)
**Test command:** `echo "manual: skein:* triggers on both harnesses"`
**Validation cmd:** `codex plugin list | grep -q 'skein@' && ! ls ~/.codex/skills/dev-plan 2>/dev/null && bash scripts/check-sync.sh`

- Back up `~/.claude/skills/` and `~/.codex/skills/` to a `backups/` dir (keep until the end).
- **Install + verify first:** `/plugin marketplace add <repo>` + `/plugin install skein` (Claude); `codex plugin marketplace add <repo>` + `codex plugin add skein@<marketplace>` (Codex). Reload; confirm `skein:*` skills trigger live.
- **Then remove** the flat managed-skill copies from `~/.claude/skills/` and `~/.codex/skills/` (`rm` will prompt per deny-list — approve only after backup + successful install verified).
- **Automated duplicate check (I5):** `codex plugin list` shows `skein@<marketplace>` enabled and no flat `~/.codex/skills/<name>` remains; run the analogous Claude skill-list check that no un-namespaced `/dev-plan` coexists with `/skein:dev-plan`. Document explicitly any invariant that has no programmatic surface.
- Run the reworked `check-sync` to confirm repo↔installed parity; only then discard the backup.

### Phase 5: Docs & references

**Impl files:** `AGENTS.md, README.md, docs/dev_plans/README.md, .claude/CLAUDE.md, .codex/AGENTS.md`
**Test files:** (none — doc review)
**Test command:** `just check-prompt-parity && just check-trunk-snippet-parity`

- Update install/promote/sync flow descriptions and skill-layout references in `AGENTS.md` (esp. the "Sync Workflow" section), `README.md`, `docs/dev_plans/README.md`. Use the correct Codex verb (`codex plugin add`, not `install`) and the `.agents/plugins/marketplace.json` path.
- Update any skill-path references in the promoted `.claude/CLAUDE.md` / `.codex/AGENTS.md`.
- Index this plan in `docs/dev_plans/README.md` task table with Component `meta`.
- Run `/update-docs` to catch residual staleness.

## Technical Specifications

> Line numbers below are anchors as of plan-authoring (codebase-claims verified them accurate); prefer the named variable/function when editing, as line numbers drift (M3).

### Files to Modify
- `scripts/promote-skills.sh` — `MANAGED_SKILLS` (line 13) → plugin roots; **only** the skill-body rsync loop (lines 40-44) switches to plugin refresh; the `content-review/references` copy (`copy_reference_files_to_global`, lines 29-38) and the `CLAUDE.md`/`AGENTS.md` cp (lines 63-79) **stay rsync/cp** (I2). Do not rsync into a version-managed plugin cache (I6).
- `scripts/sync-skills.sh` — `MANAGED_SKILLS` (line 13), `REPO_*_DIR` (lines 18-19), rsync src/dest + excludes (lines 42, 60, 66, 69).
- `scripts/check-sync.sh` — `MANAGED_SKILLS` (line 16); axis (a) repo↔global `diff -ru` loop (lines 42-60), **preserving** the bundle-skill `scripts/`-exclusion + rationale (lines 21-35); axis (b) canonical↔bundle byte-identity destination anchor (~lines 180-181) (I1).
- `scripts/bundle-appliers.sh` — bundle **destination** anchor (the skill `scripts/` write target) → new roots (C2).
- `scripts/bootstrap-skills.sh` — rsync paths (lines 52,58,69,75,94).
- `tests/parity/test-applier-bundle-parity.sh` — `MIRRORS=(.claude .codex)` + skill-`scripts/` glob → new roots; add non-vacuous (>0 files) assertion (C3).
- `tests/parity/test_skill_md_presence.py` — SKILL.md path constants → new roots (C3).
- `justfile` — recipes `sync-skills:3`, `promote-skills:6`, `bootstrap-skills:9/12`, `check-sync:15`, parity targets.
- `deep-review/SKILL.md` (418,421,429,436,473), `review-plan/SKILL.md` (328,336,343,446) — **only if** Phase 1 decides `$SKILL_DIR` must be rewritten (I4).
- `AGENTS.md`, `README.md`, `docs/dev_plans/README.md`, `.claude/CLAUDE.md`, `.codex/AGENTS.md` — layout/flow references.
- **NOT modified:** `scripts/lib/bundle-map.sh` — `BUNDLE_SHARED` (15-21) is canonical-`scripts/`-relative, not skill-root-relative; the move requires zero edits here (C2).

### New Files to Create
- `.claude-plugin/marketplace.json` — Claude local marketplace listing the `skein` plugin (`source: ./plugins/skein`).
- `plugins/skein/.claude-plugin/plugin.json` — `{"name":"skein", "version", "description", "author"}` (Claude).
- `.agents/plugins/marketplace.json` — Codex marketplace; entry `{name:"skein", source:{source:"local",path:"./plugins/skein-codex"}, policy.installation, policy.authentication, category}` (C1).
- `plugins/skein-codex/.codex-plugin/plugin.json` — Codex plugin manifest (JSON) with `name`, semver `version`, `description`, `author.name`, `interface.{displayName,shortDescription,longDescription,developerName,category}`, `interface.capabilities`, `interface.defaultPrompt`, `skills:"./skills/"` (C1).
- `tests/plugin/test_manifests.sh`, `tests/plugin/test_history_and_assets.sh`, `tests/plugin/test_sync_roundtrip.sh` — migration regression guards.

### Moved (via `git mv`, history-preserving)
- `.claude/skills/<name>/` → `plugins/skein/skills/<name>/` (11 skills + all internal assets).
- `.codex/skills/<name>/` → `plugins/skein-codex/skills/<name>/` (11 skills + all internal assets).

### Architecture Decisions
- **Fresh `vr000m/skein` repo, cloned from `skills.md` (history-preserving).** Gives the branded repo identity (`github.com/vr000m/skein`, matching the `skein.sh` domain) and makes the skills portable, without losing commit history (`git clone` carries it; `filter-repo` reserved for optional later pruning). `skills.md` is left intact; archive-vs-keep-as-lab is deferred. Rejected: naive copy (loses history, contradicts the history-preservation criterion); GitHub rename (would not leave `skills.md` available as a possible dev lab).
- **Dedicated `plugins/skein{,-codex}/` roots, not reuse of `.claude/`/`.codex/`.** Rationale: the repo's own `.claude/` is project-config (holds `settings.local.json`) and its `.claude/skills/` auto-loads as *project* skills when developing in-repo; making `.claude/` double as the distributable plugin root would re-introduce the duplicate-skill problem during development. A separate `plugins/` tree decouples distribution from repo config. (Alternative considered: add `.claude/.claude-plugin/plugin.json` in place — minimal moves but rejected for the doubling hazard.)
- **Two in-repo skill copies retained.** The Claude/Codex dispatch-idiom divergence is legitimate; collapsing to one source is out of scope.
- **Promote splits into two flows, not one (I2).** The skill-body promote becomes plugin `add`/refresh; the `content-review/references` copy and the `CLAUDE.md`/`AGENTS.md` cp **remain** rsync/cp because plugin install does not place those global files. Promote must target the plugin *source*, not a version-managed plugin *cache* (I6). Flat global skill copies are removed in Phase 4 (install-and-verify first), never leaving a no-skills window (C5).
- **Move + tooling retarget are atomic (C4).** Because all sync/check/promote scripts hard-code `.{claude,codex}/skills`, the `git mv` and the script retarget land in one boundary commit; the repo guards are green only after both, so they cannot be split across commits.
- **`bundle-map.sh` is unchanged; the move touches bundle *destinations* (C2).** `BUNDLE_SHARED` is relative to canonical `scripts/`; the bundle is copied into each skill's `scripts/` subtree, so only the destination anchors in `check-sync.sh` and `bundle-appliers.sh` change.
- **Path-resolution approach decided empirically in Phase 1** (`$SKILL_DIR` survives on both harnesses → no SKILL.md edits; else migrate anchors to the plugin-root variable and test the rewrite — I4).
- **Single repo serves both harnesses** (this repo becomes the marketplace; both install from `vr000m/skills.md`). The two harnesses key off marketplace files at **different paths** — Claude `.claude-plugin/marketplace.json`, Codex `.agents/plugins/marketplace.json` — so there is no filename clash, and each resolves skills from its own `source.path` (`plugins/skein` vs `plugins/skein-codex`), not a greedy repo-wide glob. Rationale: preserves single source of truth and lets the existing dual-mirror + sync tooling organize two subtrees rather than two remotes. Fallback to **separate per-harness repos** only if Phase-1 check (b) shows discovery is greedy and cross-loads the other harness's skills.

### Dependencies
- No new language deps. Existing tooling: `bash`, `rsync`, `jq`, `just`, `python3`/`pytest` (skill tests), `shellcheck`/`shfmt` (lint). New dependency on the harness plugin/marketplace CLIs (`/plugin …` on Claude; `codex plugin …` on Codex) — confirmed/used in Phase 1.

### Integration Seams

| Seam | Writer | Caller | Contract |
|------|--------|--------|----------|
| Skill script path | SKILL.md script anchors | harness runtime | Bundled scripts must resolve via the path var that works for plugin skills on BOTH harnesses (`$SKILL_DIR` or `${CLAUDE_PLUGIN_ROOT}` — Phase 1); affected set is `deep-review`, `review-plan` (conduct/fan-out have no anchors) |
| Managed-skill list | `MANAGED_SKILLS` (3 scripts) | promote/sync/check-sync | Single canonical list; all three must point at the new `plugins/` roots |
| Bundle destination | canonical `scripts/` (via `bundle-appliers.sh`) | each skill `scripts/` subtree; `check-sync.sh` axis (b) | Bundle copied into new skill roots and verified byte-identical to canonical; `bundle-map.sh` unchanged |
| Doc/reference promote | `.codex` content-review/references; repo `CLAUDE.md`/`AGENTS.md` | promote-skills.sh (rsync/cp, NOT plugin install) | Plugin `add` does not place global `CLAUDE.md`/references — these stay on the rsync/cp path |
| Live install ordering | plugin `add` + verify | flat-copy removal | Install + `skein:*` trigger confirmed BEFORE removing flat copies; never a no-skills window |

## Testing Notes

### Test Approach
- [ ] New `tests/plugin/` guards: manifest validity (+ Codex validator), history/asset preservation, sync round-trip.
- [ ] **Retargeted** `tests/parity/test-applier-bundle-parity.sh` (non-vacuous: matches >0 files) and `tests/parity/test_skill_md_presence.py`; `tests/reconciliation/*` pass against new layout.
- [ ] Per-skill pytest (`conduct/tests`, `plan-view/tests`) pass at new paths.
- [ ] If `$SKILL_DIR` rewritten: grep-guard finds no surviving bare `"$SKILL_DIR"` anchors, and one bundled-script smoke runs from the *installed* plugin.
- [ ] Bootstrap smoke in a temp `HOME` (Phase 3 validation cmd).
- [ ] Live duplicate check is automated where a surface exists (`codex plugin list`; Claude skill-list).

### Test Results
- [ ] All existing tests pass
- [ ] New tests added and passing
- [ ] Manual verification complete

### Edge Cases Tested
- [ ] `git status` shows **renames** (not add/delete) across the whole move set; `git log --follow` traces one file per asset type (`.py`, `SKILL.md`, `references/`) (M2)
- [ ] Retargeted bundle-parity gate still fires on intentional drift AND is non-vacuous
- [ ] No no-skills window during Phase 4; no flat `/dev-plan` alongside `/skein:dev-plan` after Phase 4

## Acceptance Criteria

- `vr000m/skein` repo exists, cloned from `skills.md` with full history (verified via `git log --follow` on a pre-existing asset); `skills.md` left intact (archive deferred).
- All 11 skills invoke as `skein:<name>` on both Claude Code and Codex; no un-namespaced duplicates remain, verified via `codex plugin list` + the Claude skill-list (not visual-only).
- `git mv` history preserved — `git status` shows renames across the move set; `git log --follow` traces a file per asset type.
- Move + tooling retarget landed in one boundary commit; `just check-sync` is green at that commit (no broken intermediate state).
- Reworked `promote`/`sync`/`check-sync`/`bootstrap` + `justfile` + retargeted `tests/parity/*` operate on the plugin layout and pass; bundle-parity check is non-vacuous.
- Bundle-parity preserved (`bundle-map.sh` unchanged; destinations retargeted); references-canon and `CLAUDE.md`/`AGENTS.md` promotion preserved on the rsync/cp path.
- Codex packaging uses confirmed facts: JSON `.codex-plugin/plugin.json`, `.agents/plugins/marketplace.json`, `codex plugin add` (not `install`).
- Live migration installed-and-verified before flat-copy removal (no no-skills window); backup retained until post-removal `check-sync` passes.
- Docs reflect the plugin layout and correct install/add flow.
- GTM/name-finder work explicitly deferred (this plan packaging-only).

<!-- reviewed: 2026-05-25 @ 0a1cb0ae5018bceabfd700933650fb58afa9a10c -->

## Progress

- [ ] Phase 0: Establish the `skein` repo (clone with history)
- [ ] Phase 1: De-risk spike — confirm formats & runtime path resolution
- [ ] Phase 2: Scaffold plugin + marketplace structure
- [ ] Phase 3: Atomic move + tooling retarget (single boundary commit)
- [ ] Phase 4: Migrate the live global install (install-and-verify first, then remove)
- [ ] Phase 5: Docs & references

## Findings

- (append findings here as work proceeds)

## Issues & Solutions

(none yet)

## Final Results

(fill on completion)
