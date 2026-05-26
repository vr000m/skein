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

**Repo strategy (locked 2026-05-25):** implementation happens in a **fresh `vr000m/skein` repo (private to start) created by `git clone`-ing `skills.md`** so full commit history of every skill is preserved (no `filter-repo` needed unless we later choose to prune). The two repos are **not synced** — once skein takes over, no further changes flow either direction. `skills.md` continues to exist as a **dev lab for future non-skein skills**; after `skein` is proven in real use, the 11 migrated skills will be **deleted from `skills.md`** so each repo owns a disjoint set (deletion is a deferred follow-up, not part of this plan's acceptance — it gates on "skein is in production use"). Consequence: because the clone starts from the flat layout, Phase 3 is still an in-place `git mv` + tooling retarget — the C4 atomic-commit constraint still applies (a from-scratch build would drop it but lose history, which we reject).

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

- Create empty private GitHub repo: `gh repo create vr000m/skein --private --description "skein: namespaced skill plugin (Claude + Codex)"`. Flip to public when proven.
- Local clone from `skills.md` to a sibling dir: `git clone /Users/vr000m/Code/vr000m/skills.md /Users/vr000m/Code/vr000m/skein` (carries all history and branches). Set `origin` to `git@github.com:vr000m/skein.git`, push `main` and the feature branch. Verify `git log` depth matches and `git log --follow` traces a pre-existing skill asset (e.g. `.claude/skills/plan-view/generate.py`).
- Leave `skills.md` untouched (no deletions yet — that's the deferred follow-up, gated on "skein in production use"). All subsequent phases run **inside the `skein` clone**, on a `feature/plugin-restructure` branch.
- Carry this plan forward in the clone (it travels with the history); update its `**Branch**` header to the skein-repo branch on first edit in skein.

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

### Phase 3: Atomic move + tooling cleanup (single boundary commit)

> **Why one phase (C4):** the `git mv` and the tooling cleanup land in **one commit** because the bundle-destination + parity-test paths are coupled to the new skill roots — splitting them across commits would leave `bundle-appliers`/`check-sync` axis (b)/`tests/parity/*` broken at the intermediate commit. The phase's Test command is the green-at-boundary gate.
>
> **Posture shift (2026-05-25 — locked in skills.md handoff):** the original plan said "retarget all the scripts". The actual posture is **delete much, retarget a little**. `/plugin install skein` (Claude) and `codex plugin add skein@<marketplace>` (Codex) replace the rsync-driven promote/sync/bootstrap flow entirely; only the intra-repo invariant guards (bundle byte-identity + mirror prompt parity) survive — those are orthogonal to install mechanism.

**Impl files:** `plugins/skein/skills/*, plugins/skein-codex/skills/* (git mv), scripts/check-sync.sh, scripts/bundle-appliers.sh, justfile, tests/parity/test-applier-bundle-parity.sh, tests/parity/test_skill_md_presence.py`
**Files to delete (in the same commit):** `scripts/promote-skills.sh, scripts/sync-skills.sh, scripts/bootstrap-skills.sh`
**Test files:** `tests/plugin/test_history_and_assets.sh, tests/parity/test-applier-bundle-parity.sh, tests/parity/test_skill_md_presence.py`
**Test command:** `just check-sync && just parity-tests && just reconciliation-tests && bash tests/plugin/test_history_and_assets.sh && bash tests/parity/test-applier-bundle-parity.sh && python3 -m pytest tests/parity/test_skill_md_presence.py -q`
**Validation cmd:** `! test -e scripts/promote-skills.sh && ! test -e scripts/sync-skills.sh && ! test -e scripts/bootstrap-skills.sh && ! grep -qE '^(sync-skills|promote-skills|bootstrap-skills)' justfile`

- `git mv` all 11 skills: `.claude/skills/<name>/` → `plugins/skein/skills/<name>/`, `.codex/skills/<name>/` → `plugins/skein-codex/skills/<name>/`, preserving internal assets (conduct/*.py+prompts+tests, plan-view/generate.py+_widgets+templates+tests, deep-review & review-plan scripts/lib, content-review/references, dev-plan/template.md+rubric.md, fan-out scripts/toolchains, spec-compliance/rubric.md).
- Apply the Phase-1 `$SKILL_DIR` decision. If "rewrite": update anchors in `deep-review/SKILL.md` and `review-plan/SKILL.md` (anchor lines re-grep at edit time — line numbers drift; affected files are the contract, not the line numbers) and `conduct/tests/test_skill_spawn_grep.sh` (Phase-1 finding) to `${CLAUDE_PLUGIN_ROOT}/skills/<name>/…` (Claude) and the Codex equivalent. Add a grep-guard asserting **no** surviving bare `"$SKILL_DIR"` anchors (I4). If "survives": no SKILL.md edits.
- **Delete** `scripts/promote-skills.sh`, `scripts/sync-skills.sh`, `scripts/bootstrap-skills.sh` outright. `/plugin install skein` and `codex plugin add skein@<marketplace>` replace them; the `~/.claude/CLAUDE.md` / `~/.codex/AGENTS.md` cp block (formerly `promote-skills.sh:63-79`) is **not preserved on the skein side** — those globals are authored in `skills.md`, not skein (see Architecture Decision below). The `content-review/references` copy block is also dropped here because plugin install carries `references/` inside the plugin tree.
- `check-sync.sh`: **delete axis (a)** (the repo↔global `diff -ru` loop) — global-state diffing is obsolete once install runs through the plugin CLI. **Keep axis (b)** (canonical↔bundle byte-identity), retargeting the destination anchor to the new skill roots. `scripts/lib/bundle-map.sh` is NOT edited — `BUNDLE_SHARED` is canonical-`scripts/`-relative (C2).
- `scripts/bundle-appliers.sh`: retarget the bundle **destination** anchor (the skill `scripts/` write target) to the new roots.
- Retarget existing parity tests (C3): `tests/parity/test-applier-bundle-parity.sh` (`MIRRORS=(.claude .codex)` + glob) and `tests/parity/test_skill_md_presence.py` (path constants) to the new roots; add a non-vacuous assertion (the bundle glob must match >0 files, so it cannot false-pass).
- `justfile`: delete recipes `sync-skills`, `promote-skills`, `bootstrap-skills`, `bootstrap-skills-force`. **Keep** recipes `bundle-appliers`, `check-prompt-parity`, `check-trunk-snippet-parity`, `parity-tests`, `reconciliation-tests`, `lint-scripts`, and the retargeted `check-sync`. Add a top-of-file comment noting that install runs through `/plugin install skein` (Claude) and `codex plugin add skein@<marketplace>` (Codex), not through repo scripts.

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

**Impl files:** `AGENTS.md, README.md, docs/dev_plans/README.md`
**Test files:** (none — doc review)
**Test command:** `just check-prompt-parity && just check-trunk-snippet-parity`

- Rewrite install-flow descriptions in `AGENTS.md` (drop the "Sync Workflow" section — that flow is deleted; replace with a "Plugin install" section pointing at `/plugin install skein` and `codex plugin add skein@<marketplace>`), `README.md`, `docs/dev_plans/README.md`. Use the correct Codex verb (`codex plugin add`, not `install`) and the `.agents/plugins/marketplace.json` path.
- Remove any references to `scripts/promote-skills.sh`, `scripts/sync-skills.sh`, `scripts/bootstrap-skills.sh` from in-repo docs (they've been deleted).
- **Do NOT touch `.claude/CLAUDE.md` or `.codex/AGENTS.md`** — those global instruction files are owned by `skills.md`, not skein.
- Index this plan in `docs/dev_plans/README.md` task table with Component `meta`.
- Run `/update-docs` to catch residual staleness.

## Technical Specifications

> Line numbers below are anchors as of plan-authoring (codebase-claims verified them accurate); prefer the named variable/function when editing, as line numbers drift (M3).

### Files to Modify
- `scripts/check-sync.sh` — **delete axis (a)** (repo↔global `diff -ru` loop and its `MANAGED_SKILLS` driver); **keep + retarget axis (b)** (canonical↔bundle byte-identity destination anchor → new skill roots) (I1).
- `scripts/bundle-appliers.sh` — bundle **destination** anchor (the skill `scripts/` write target) → new roots (C2).
- `tests/parity/test-applier-bundle-parity.sh` — `MIRRORS=(.claude .codex)` + skill-`scripts/` glob → new roots; add non-vacuous (>0 files) assertion (C3).
- `tests/parity/test_skill_md_presence.py` — SKILL.md path constants → new roots (C3).
- `justfile` — delete recipes `sync-skills`, `promote-skills`, `bootstrap-skills`, `bootstrap-skills-force`; retarget `check-sync`; keep `bundle-appliers`, `check-prompt-parity`, `check-trunk-snippet-parity`, `parity-tests`, `reconciliation-tests`, `lint-scripts`. Add top-of-file comment pointing to `/plugin install skein` / `codex plugin add skein@<marketplace>` as the install path.
- `deep-review/SKILL.md`, `review-plan/SKILL.md`, `conduct/tests/test_skill_spawn_grep.sh` (Phase-1 finding) — **only if** Phase 1 decides `$SKILL_DIR` must be rewritten; re-grep anchor lines at edit time (numbers drift).
- `AGENTS.md`, `README.md`, `docs/dev_plans/README.md` — layout/flow references; remove rsync/promote/sync/bootstrap mentions, replace with plugin-install flow.
- **NOT modified:** `scripts/lib/bundle-map.sh` — `BUNDLE_SHARED` is canonical-`scripts/`-relative, not skill-root-relative; the move requires zero edits here (C2). `scripts/lib/*` more generally is unchanged.

### Files to Delete (Phase 3, same boundary commit)
- `scripts/promote-skills.sh` — entire script. `/plugin install skein` (Claude) and `codex plugin add skein@<marketplace>` (Codex) replace the skill-body promote; the `content-review/references` copy block is dropped (plugin install carries `references/` inside the plugin tree); the `~/.claude/CLAUDE.md` / `~/.codex/AGENTS.md` cp block is dropped because **global instruction files are authored in `skills.md`, not skein** (see Architecture Decision).
- `scripts/sync-skills.sh` — entire script. Global→repo back-sync is obsolete once the plugin tree is the authored source and install runs through the plugin CLI.
- `scripts/bootstrap-skills.sh` — entire script. `/plugin install skein` is the bootstrap path on a fresh machine; no rsync-into-`~/.claude/skills/` step remains.
- (Implied) `MANAGED_SKILLS` env / array — disappears with the three scripts above; no other caller remains.

### Files NOT touched by skein (authored elsewhere)
- `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md` — global instruction files; **owned by `skills.md`**, not skein. The two repos are not synced; this is a one-way ownership split, not a copy.

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
- **Fresh `vr000m/skein` repo (private to start), cloned from `skills.md` (history-preserving).** Gives the branded repo identity (`github.com/vr000m/skein`, matching the `skein.sh` domain) and makes the skills portable, without losing commit history (`git clone` carries it; `filter-repo` reserved for optional later pruning). `skills.md` is **kept as the dev lab for future non-skein skills**; **no sync** between repos; the 11 migrated skills are **deleted from `skills.md` once `skein` is in production use** (deferred follow-up). Rejected: naive copy (loses history, contradicts the history-preservation criterion); GitHub rename (would not leave `skills.md` available as a lab); ongoing two-repo sync (the source-of-truth burden we've been avoiding all session).
- **Dedicated `plugins/skein{,-codex}/` roots, not reuse of `.claude/`/`.codex/`.** Rationale: the repo's own `.claude/` is project-config (holds `settings.local.json`) and its `.claude/skills/` auto-loads as *project* skills when developing in-repo; making `.claude/` double as the distributable plugin root would re-introduce the duplicate-skill problem during development. A separate `plugins/` tree decouples distribution from repo config. (Alternative considered: add `.claude/.claude-plugin/plugin.json` in place — minimal moves but rejected for the doubling hazard.)
- **Two in-repo skill copies retained.** The Claude/Codex dispatch-idiom divergence is legitimate; collapsing to one source is out of scope.
- **Promote becomes plugin install; no rsync/cp shim survives in skein (revised 2026-05-25).** The skill-body install path is `/plugin install skein` (Claude) and `codex plugin add skein@<marketplace>` (Codex). `scripts/promote-skills.sh`, `scripts/sync-skills.sh`, `scripts/bootstrap-skills.sh` are **deleted outright** in Phase 3 — not retargeted. The `content-review/references` directory ships inside the plugin tree, so the legacy references-copy block is dropped. The `~/.claude/CLAUDE.md` / `~/.codex/AGENTS.md` cp block is also dropped: **those globals are owned by `skills.md`, not skein.** The two repos are not synced; ownership is split, not duplicated. Flat global skill copies are removed in Phase 4 (install-and-verify first), never leaving a no-skills window (C5). (Supersedes the earlier "Promote splits into two flows" framing — I2 / I6 references in this plan should be read in that light.)
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
| Install path | `plugins/skein{,-codex}/` tree | `/plugin install skein` (Claude); `codex plugin add skein@<marketplace>` (Codex) | Plugin CLI is the **only** install mechanism in skein; no rsync/cp shim survives. `MANAGED_SKILLS` and promote/sync/bootstrap scripts deleted in Phase 3. |
| Bundle destination | canonical `scripts/` (via `bundle-appliers.sh`) | each skill `scripts/` subtree; `check-sync.sh` axis (b) | Bundle copied into new skill roots and verified byte-identical to canonical; `bundle-map.sh` unchanged |
| Global instruction files | `skills.md` repo | `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md` | **Out of scope for skein.** Owned by `skills.md`; no sync between repos. |
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
- `scripts/promote-skills.sh`, `scripts/sync-skills.sh`, `scripts/bootstrap-skills.sh` and their `justfile` recipes are deleted; remaining `justfile` + retargeted `tests/parity/*` operate on the plugin layout and pass; bundle-parity check is non-vacuous.
- Bundle-parity preserved (`bundle-map.sh` unchanged; destinations retargeted to new skill roots).
- Global instruction files (`~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`) untouched by skein — ownership remains in `skills.md`.
- Codex packaging uses confirmed facts: JSON `.codex-plugin/plugin.json`, `.agents/plugins/marketplace.json`, `codex plugin add` (not `install`).
- Live migration installed-and-verified before flat-copy removal (no no-skills window); backup retained until post-removal `check-sync` passes.
- Docs reflect the plugin layout and correct install/add flow.
- GTM/name-finder work explicitly deferred (this plan packaging-only).

<!-- reviewed: 2026-05-25 @ 989ef5b84877ce4c793cbe40ef07cbf711cca5ed -->

## Progress

- [x] Phase 0: Establish the `skein` repo (clone with history)
- [x] Phase 1: De-risk spike — confirm formats & runtime path resolution
- [x] Phase 2: Scaffold plugin + marketplace structure
- [ ] Phase 3: Atomic move + tooling retarget (single boundary commit)
- [ ] Phase 4: Migrate the live global install (install-and-verify first, then remove)
- [ ] Phase 5: Docs & references

## Findings

- Phase 0 (2026-05-25): vr000m/skein created private (https://github.com/vr000m/skein); local clone at /Users/vr000m/Code/vr000m/skein, origin = git@github.com:vr000m/skein.git. History preserved: 398 commits on main (matches skills.md exactly); `git log --follow .claude/skills/plan-view/generate.py` traces back to commit `064dbb4` ("plan-view: HTML dashboard for dev-plan corpora"). main + feature/skein-plugin-migration pushed to new origin. skills.md left untouched.

- Phase 1 partial — research + scaffolding (2026-05-25, pre-handback):
  - **Claude plugin docs** (code.claude.com/docs/en/plugins.md, plugins-reference.md): `.claude-plugin/plugin.json` requires only `name` (kebab-case → `<name>:<skill>` namespace). Marketplace lives at `.claude-plugin/marketplace.json` with `plugins[].source` accepting a path string. Install verbs: `/plugin marketplace add <path>` then `/plugin install <plugin>@<marketplace>`; non-interactive CLI `claude plugin install <plugin>@<marketplace>`; reload via `/reload-plugins`; local dev shortcut `claude --plugin-dir <path>`. Validator: `claude plugin validate ./my-plugin [--strict]`.
  - **`$SKILL_DIR` is NOT documented** for plugin-bundled skills. The documented plugin-context env vars are `${CLAUDE_PLUGIN_ROOT}`, `${CLAUDE_PLUGIN_DATA}`, `${CLAUDE_PROJECT_DIR}` — substituted in skill content AND exported to hook/MCP/LSP subprocesses. Whether they reach a SKILL.md-invoked bundled script remains unverified by docs and requires the live spike on each harness.
  - **Codex CLI confirmed** (codex-cli 0.133.0): subcommand set is `add | list | marketplace | remove`. `codex plugin install` errors with `unrecognized subcommand 'install'` → **verb is `add`** (matches plan). `codex plugin add <PLUGIN[@MARKETPLACE]>` syntax confirmed. `codex plugin marketplace add <SOURCE>` accepts `a local path, owner/repo[@ref], HTTPS Git URL, or SSH Git URL`. **No `codex plugin validate` subcommand exists** — plan must drop the "use the local Codex plugin validator" instruction (fall back to `jq`/schema linting in Phase 2 tests).
  - **Codex marketplace-file location and manifest field set remain unconfirmed by the CLI help.** `codex plugin marketplace add <local-path>` accepts a directory, but the help does not state which filename Codex looks for inside it. The plan's claims (`.agents/plugins/marketplace.json`, full `interface.*` field set) come from the Codex self-review and are still **pending live install confirmation** — the manual spike below resolves this.
  - **Throwaway plugins scaffolded** at `/tmp/skein-spike/` (outside the repo to satisfy "no repo restructuring"):
    - `/tmp/skein-spike/claude-plugin/` — basic rfc-finder spike (Claude side)
    - `/tmp/skein-spike/codex-plugin/` — basic rfc-finder spike (Codex side)
    - `/tmp/skein-spike/claude-skill-dir-test/` — `show-dir` skill whose bundled script echoes `SKILL_DIR=$SKILL_DIR` and `CLAUDE_PLUGIN_ROOT=$CLAUDE_PLUGIN_ROOT`
    - `/tmp/skein-spike/codex-skill-dir-test/` — same `show-dir` skill for Codex
    Each scaffold contains a README with the verbatim install command sequence (next section).
  - **`$SKILL_DIR` affected-set in repo** (`rg -n '\$SKILL_DIR' .claude/skills/`):
    - `deep-review/SKILL.md` lines **421, 429, 436, 473** (4 occurrences — plan lists 5 at 418/421/429/436/473; line 418 has drifted out, update plan anchors at Phase 3 time)
    - `review-plan/SKILL.md` lines **328, 336, 343, 446** (matches plan)
    - **`conduct/tests/test_skill_spawn_grep.sh` lines 47, 57** also depend on `$SKILL_DIR` — plan's Review Focus says "conduct has no anchors", which is true for SKILL.md but the test script is affected. **Plan amendment needed: extend the Review Focus affected-set to include this test.**
  - Not yet checked: `$SKILL_DIR` references in `.codex/skills/` mirror (do as part of the manual spike or Phase 3 prep).

- Phase 1 manual harness verification — **Claude side resolved**, Codex side still pending:
  - **Claude basic spike** (skein-spike:rfc-finder install): ✓ installed and namespaced correctly via `/plugin install skein-spike@skein-spike-local`. Trigger works.
  - **Claude `$SKILL_DIR` test** (skill-dir-test:show-dir): ran with both candidate forms.
    - `$SKILL_DIR` env var: **`<UNSET>`** in the Bash subprocess.
    - `${CLAUDE_PLUGIN_ROOT}` env var: **`<UNSET>`** in the Bash subprocess.
    - BUT the SKILL.md template literal `${CLAUDE_PLUGIN_ROOT}` **is substituted at render time** before the model sees the content (the literal `${CLAUDE_PLUGIN_ROOT}` in SKILL.md was rendered as the absolute path `/tmp/skein-spike/claude-skill-dir-test/plugins/skill-dir-test`). The literal `$SKILL_DIR` is **not** substituted and is also not env-exported.
    - Decision (Claude side): rewrite SKILL.md anchors from `"$SKILL_DIR"/scripts/...` to `${CLAUDE_PLUGIN_ROOT}/skills/<name>/scripts/...`. Resolution mechanism is **template substitution**, not env-var export.
    - Affected on Claude: `deep-review/SKILL.md` (4 anchors), `review-plan/SKILL.md` (4 anchors), and `conduct/tests/test_skill_spawn_grep.sh` — needs separate review since that test reads `$SKILL_DIR` from its own runtime, not from SKILL.md substitution.
    - Other env probes: `CLAUDE_PLUGIN_DATA` was set but to a **different plugin's data dir** (`/Users/vr000m/.claude/plugins/data/codex-openai-codex`) — env leakage, not this skill's value. `CLAUDE_PROJECT_DIR` was `<UNSET>`.
  - **Codex basic spike** (skein-spike@skein-spike-local): ✓ installed and enabled per `codex plugin list`. Installed plugin root: `/Users/vr000m/.codex/plugins/cache/skein-spike-local/skein-spike/0.0.1`.
  - **Codex `$SKILL_DIR` test** (skill-dir-test:show-dir): bundled script ran with these values:
    - `SKILL_DIR=/Users/vr000m/.codex/plugins/cache/skill-dir-test-local/skill-dir-test/0.0.1` — **Codex DOES env-export `$SKILL_DIR`** to the bundled-script subprocess. Path resolves to the plugin install cache root, including the skill-subdir suffix.
    - `CLAUDE_PLUGIN_ROOT=<UNSET>`, `CLAUDE_PLUGIN_DATA=<UNSET>`, `CLAUDE_PROJECT_DIR=<UNSET>` — Claude-specific vars are NOT set on Codex (expected).
    - Decision (Codex side): **no rewrite needed.** Codex-mirror SKILL.md anchors continue to use `"$SKILL_DIR"/scripts/...` as today.
  - **Codex manifest schema findings (from install errors / successful manifest):**
    - `policy.installation` enum: `NOT_AVAILABLE | AVAILABLE | INSTALLED_BY_DEFAULT` (the plan's original `manual` is invalid; the Codex self-review's wording was wrong here).
    - `policy.authentication` value `ON_INSTALL` is accepted (full enum not exhaustively probed).
    - Marketplace file path **`.agents/plugins/marketplace.json`** confirmed — `codex plugin marketplace add <dir>` finds it there.
    - Plugin manifest at `<plugin>/.codex-plugin/plugin.json` with `name`, `version`, `description`, `interface.*` confirmed accepted (the scaffold passed schema).
  - **Single-repo distribution check** (partial): `codex plugin list` shows only Codex marketplaces (`.agents/plugins/marketplace.json` paths); Claude's `.claude-plugin/marketplace.json` is NOT loaded by Codex. The two harnesses cleanly partition by marketplace-file path. ✓ holds.
  - **Path-resolution decision (final, Phase 1 close):** **harness-divergent**, matching the existing two-mirror policy.
    - Claude mirror (`plugins/skein/skills/<name>/SKILL.md`): rewrite anchors from `"$SKILL_DIR"/scripts/...` → `${CLAUDE_PLUGIN_ROOT}/skills/<name>/scripts/...`. Resolution is **template substitution at SKILL.md render time**.
    - Codex mirror (`plugins/skein-codex/skills/<name>/SKILL.md`): **no change.** Resolution is **env-var export** of `$SKILL_DIR` to the script subprocess.
    - Phase 3's grep-guard must be **harness-aware**: assert no surviving bare `"$SKILL_DIR"` anchors in `plugins/skein/skills/**/SKILL.md` (Claude tree) but allow them in `plugins/skein-codex/skills/**/SKILL.md` (Codex tree, unchanged).
    - `conduct/tests/test_skill_spawn_grep.sh` uses `$SKILL_DIR` inside a child shell — needs verification at Phase 3 time that the test invocation context still provides `$SKILL_DIR` on both harnesses (Codex exports it; on Claude, the test runs from where? Check whether the conduct skill's test harness inherits from Claude's substituted skill context or runs a separate subprocess).
  - **Plan amendment list (for Phase 2/3 to apply):**
    - Drop "use the local Codex plugin validator" from Phase 1/2 wording — no such `codex plugin validate` subcommand exists.
    - Update Codex `policy.installation` example to `AVAILABLE` (not `manual`) wherever the plan describes the manifest.
    - Mark the `$SKILL_DIR` rewrite scope as **Claude-mirror-only**; Codex mirror unchanged.

- Contract amendments folded in (2026-05-25, skills.md handoff):
  - **Phase 3 posture shifted from "retarget all the scripts" to "delete much, retarget a little".** `scripts/promote-skills.sh`, `sync-skills.sh`, `bootstrap-skills.sh` and their `justfile` recipes are deleted outright; `/plugin install skein` and `codex plugin add skein@<marketplace>` replace them. `check-sync.sh` axis (a) (repo↔global diff) is deleted; axis (b) (canonical↔bundle byte-identity) is retargeted. `bundle-appliers.sh`, `scripts/lib/*`, `check-prompt-parity`, `check-trunk-snippet-parity`, `tests/parity/*`, `tests/reconciliation/*` are all kept (intra-repo invariants orthogonal to install mechanism).
  - **`~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md` ownership stays in `skills.md`, not skein.** No cp shim survives in skein; the two repos are not synced; ownership is split, not duplicated. Phase 5 no longer touches those files; the `promote-skills.sh:63-79` cp block is dropped, not slim-replaced.
  - **Marker re-stamped** to `989ef5b8…` after these contract edits (previous: `29bf039c…`).

## Issues & Solutions

(none yet)

## Final Results

(fill on completion)
