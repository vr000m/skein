# Task: Bundle auto-fix applier pipeline into review skills for portable `--auto-fix`

**Status**: Not Started
**Component**: review-skills
**Assigned to**: Claude
**Priority**: Medium
**Branch**: feature/bundle-auto-fix-appliers
**Created**: 2026-05-23
**Completed**: (fill when done)

## Objective

Bundle the auto-fix applier pipeline into the `deep-review` and `review-plan` skill directories so `--auto-fix=trivial` runs the gated applier wherever the skill is installed — not only when the current working directory is the `skills.md` repo.

## Context

`/deep-review --auto-fix=trivial` and `/review-plan --auto-fix=trivial` drive a pipeline of shell scripts that the SKILL.md prose invokes by **bare, cwd-relative paths** (`scripts/apply-auto-fix-code.sh`, `scripts/reconcile-findings.sh`, …). Those scripts ship only at the `skills.md` repo root. An installed skill ships just `SKILL.md` + `rubric.md` (verified: `~/.claude/skills/deep-review/` contains exactly those two files). So when a skill is run from any other project's directory, the bare `scripts/…` paths do not resolve and the auto-fix pipeline is absent.

**Observed failure:** a run reported the applier scripts "aren't shipped in this skill install" and fell back to applying the trivial fixes **directly**, bypassing the gated applier's safety contract (requires `--test-cmd`, runs the test command exactly once per fix, restores from a saved blob on failure without touching `HEAD`). The fixes happened to be benign, but the fallback is exactly the path the gating was built to prevent.

**Key reframing fact from codebase exploration:** the applier scripts **already self-locate via `BASH_SOURCE`** and resolve their own dependencies relative to their own file location — they do *not* depend on cwd:
- `scripts/apply-auto-fix-code.sh:32-35` — `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`; `SCRIPT_ROOT="$SCRIPT_DIR/.."`; `. "$SCRIPT_ROOT/scripts/lib/auto-fix-common.sh"`.
- `scripts/apply-auto-fix-plan.sh:40-43` — identical pattern; also `:187` references `"$SCRIPT_ROOT/scripts/plan-scope-detect.sh"`.
- `scripts/audit-auto-fix-eligibility.sh:9-11,34` — `ROOT_DIR="$(dirname "${BASH_SOURCE[0]}")/.."`; resolves `auto-fix-allowlist.json`, `plan-scope-detect.sh`, and the lib from `$ROOT_DIR/scripts/`.
- `scripts/lib/auto-fix-common.sh:38-40` — `AF_LIB_ROOT="$(dirname "${BASH_SOURCE[0]}")/../.."` (two levels up); `AF_ALLOWLIST_PATH="$AF_LIB_ROOT/scripts/auto-fix-allowlist.json"`.
- `scripts/reconcile-findings.sh`, `scripts/render-reconciled-report.sh` — self-contained, source nothing.

**Consequence:** if we place copies of these scripts under a `scripts/` (+ `scripts/lib/`) subtree *inside each skill directory*, the existing `BASH_SOURCE` resolution finds the bundled siblings automatically — **no script edits are needed for path resolution**. The only changes are (a) bundling the files, (b) changing SKILL.md to invoke the applier via the skill's own base directory instead of a bare `scripts/` path, and (c) a build + parity step so the bundled copies never drift from the canonical `scripts/`.

**Base-dir disclosure (Claude):** Claude Code discloses the skill's absolute base directory to the model at skill-load time (observed this session: `Base directory for this skill: /Users/vr000m/.claude/skills/dev-plan`). SKILL.md can therefore instruct the model to anchor applier invocations at that base dir. The **Codex** equivalent is an open question this plan must resolve (see Review Focus + Phase 2).

## Requirements

- `--auto-fix=trivial` for `deep-review` and `review-plan` must run the gated applier when the skill is installed and invoked from an arbitrary cwd (not the `skills.md` repo).
- The gated applier's safety contract is preserved unchanged: `--test-cmd` (or `AUTO_FIX_TEST_CMD`) remains **mandatory** (`apply-auto-fix-code.sh:88-90` exits 2 when absent); test runs once per fix; failure restores from blob without touching `HEAD`.
- **No direct-apply fallback.** If the bundled scripts cannot be located, the skill must hard-fail with a clear message, never apply fixes by hand.
- `scripts/` remains the single canonical source. Bundled copies are byte-identical mirrors enforced by a parity test (same posture as the existing `auto-fix-allowlist.json` byte-identity check). The bundled copies are **generated artifacts** produced by `bundle-appliers.sh` and committed; canonical `scripts/X` always wins on conflict.
- The bundled-`scripts/` round-trip authority is explicit: the global→repo sync direction (`sync-skills`, `rsync -a --delete`) must not be allowed to overwrite the canonical-bundled repo copy with a stale global copy (the failure mode the content-review `references/` carve-out already guards against, `sync-skills.sh:58`, `check-sync.sh:63-122`).
- All executable pipeline invocations in SKILL.md — `reconcile-findings.sh`, `audit-auto-fix-eligibility.sh`, `render-reconciled-report.sh`, and the applier — must be base-dir-anchored, not just the appliers. Prose citations of `scripts/…` (source-of-truth pointers) stay bare and are documentation-only.
- Codex-side base-dir resolution must be defined from verified runtime evidence, not left as an implementation note. First probe whether Codex exposes the loaded skill path directly. If it does not, use `$HOME/.codex/skills/<skill>` for installed skills unless `CODEX_HOME` is explicitly verified as a supported Codex install-root override; repo-local `.codex/skills/<skill>` paths are only for development/parity checks. The `.codex` SKILL.md prose must state the supported installed path, whether `CODEX_HOME` is supported, and the hard-fail if the resolved bundled `scripts/` subtree is absent.
- `.claude` and `.codex` SKILL.md mirrors stay in prompt-parity (`scripts/check-prompt-parity.sh`, `tests/parity/`). The `auto-fix-allowlist.json` array literal stays byte-identical across all four SKILL.md mirrors (`tests/parity/test-allowlist-byte-identity.sh`). The `test-auto-fix-orchestration-contract.sh` literals (which assert the bare `scripts/audit-…` invocation today) must be updated in lockstep with the anchoring change.
- All parity tests the plan relies on must be wired into an executed `just` target (there is no `.github/workflows`); `reconciliation-tests` currently runs neither `test-allowlist-byte-identity.sh` nor `test-auto-fix-orchestration-contract.sh`.
- Bundled scripts must survive the sync/promote/bootstrap round-trip (`rsync -a --delete`) and reach the global install via `promote-skills`/`bootstrap-skills`.
- Minimal impact; respect the `MANAGED_SKILLS` / `CLAUDE_ONLY_SKILLS` authority model in `AGENTS.md`.

## Review Focus

- **Codex base-dir resolution (highest risk).** Claude discloses the skill base dir at load; confirm whether Codex CLI exposes an equivalent (env var, disclosed path, or AGENTS-relative anchor). If it does not, the `.codex` SKILL.md needs a distinct resolution idiom anchored at `$HOME/.codex/skills/<skill>/scripts/` for installed skills. Only use `${CODEX_HOME:-$HOME/.codex}/skills/<skill>/scripts/` if Phase 0 proves Codex honors `CODEX_HOME` as an install-root override. Repo-local `.codex/skills/<skill>/scripts/` is development/parity-only. The dispatch/resolution idiom is the *one* place `.claude` and `.codex` mirrors are allowed to legitimately diverge (cf. the Explore-prompt mirroring note in `dev-plan/SKILL.md`); everything else must stay in parity.
- **No silent degradation.** Verify the SKILL.md prose now hard-fails on missing bundled scripts and that no remaining sentence authorizes a manual/direct apply. Grep all four mirrors for fallback language.
- **Drift guard correctness.** The new parity test must compare byte-identity between canonical `scripts/X` and *every* bundled copy across all four skill mirrors, and must be wired into a `just` target and `check-sync` so a forgotten re-bundle fails CI/local checks — not just exist as an orphan script.
- **Round-trip stability.** Confirm `sync-skills` (global→repo, `--exclude='references/'`) and `promote-skills`/`bootstrap-skills` (repo→global, `--delete`) carry the bundled `scripts/` subtree both ways without deleting it or causing spurious drift.
- **Allowlist parity preserved.** The `auto-fix-allowlist.json` byte-identity assertions (`tests/parity/test-allowlist-byte-identity.sh`, `check-prompt-parity.sh:286-305`) must stay green after SKILL.md edits.

## Implementation Checklist

**Codex conduct note:** this plan is dual-harness. Run `/review-plan` in both Claude and Codex before implementation, then conduct with harness awareness: Phase 0/2 are the Codex-critical phases because they define `.codex` runtime path resolution and update `.codex/skills/{deep-review,review-plan}/SKILL.md`. A Codex conductor must not treat the Claude base-dir disclosure as sufficient evidence for Codex; it must record the Codex loaded-skill-path probe result and either prove `CODEX_HOME` support or deliberately use the `$HOME/.codex` installed-skill fallback before marking Phase 2 complete.

### Phase 0: Codex runtime resolution preflight

**Impl files:** none (evidence-gathering only; findings feed Phase 2 SKILL.md wording)
**Test files:** none
**Test command:** `env | rg '^CODEX|CODEX_HOME|CODEX_'`
**Validation cmd:** record the observed Codex loaded-skill-path behavior and `CODEX_HOME` support decision in this plan before editing `.codex` SKILL.md

- Probe the active Codex session for a loaded-skill base path exposed to the model/tooling. Accept only concrete runtime evidence, such as a disclosed skill path in the invocation context or a documented env var present in the process environment; do not infer from Claude's `Base directory for this skill:` behavior.
- Probe `CODEX_HOME` separately. In the current Codex Desktop session, `env | rg '^CODEX|CODEX_HOME|CODEX_'` shows `CODEX_CI`, `CODEX_INTERNAL_ORIGINATOR_OVERRIDE`, `CODEX_SANDBOX`, `CODEX_SHELL`, and `CODEX_THREAD_ID`, but no `CODEX_HOME`; that absence is a signal to verify, not proof of unsupported behavior. If no authoritative support is found, do not document `${CODEX_HOME:-$HOME/.codex}` as the installed-skill contract.
- Choose exactly one Codex installed-skill resolution contract for Phase 2:
  - Use a runtime-disclosed loaded skill path if Codex exposes one.
  - Else use `$HOME/.codex/skills/<skill>/scripts/` as the installed-skill fallback.
  - Use `${CODEX_HOME:-$HOME/.codex}/skills/<skill>/scripts/` only if the preflight proves `CODEX_HOME` is a supported Codex install-root override.
- Record the decision in the Phase 2 "Resolving the bundled applier" subsection for both `.codex` SKILL.md files and in `CODEX_MIRROR_BACKLOG.md` if it is a tracked harness divergence.

### Phase 1: Bundle build step + generate copies + drift-guard parity tests

**Impl files:** `scripts/bundle-appliers.sh`, `justfile`, `.claude/skills/deep-review/scripts/**`, `.claude/skills/review-plan/scripts/**`, `.codex/skills/deep-review/scripts/**`, `.codex/skills/review-plan/scripts/**`
**Test files:** `tests/parity/test-applier-bundle-parity.sh`
**Test command:** `bash tests/parity/test-applier-bundle-parity.sh`
**Validation cmd:** `just lint-scripts && git diff --exit-code -- '*/skills/*/scripts'`

- Write `scripts/bundle-appliers.sh`: for each skill in a defined map, copy the canonical scripts into `<root>/.claude/skills/<skill>/scripts/` and `<root>/.codex/skills/<skill>/scripts/`, preserving the `scripts/` + `scripts/lib/` layout the `BASH_SOURCE` resolution expects (the lib's `../..` at `auto-fix-common.sh:38` requires the allowlist to sit as a sibling of `lib/`, i.e. `<skill>/scripts/auto-fix-allowlist.json` + `<skill>/scripts/lib/auto-fix-common.sh` — a flattened bundle resolves the wrong allowlist path at runtime, not bundle time).
- Define the bundled set. Shared pipeline (both skills): `reconcile-findings.sh`, `audit-auto-fix-eligibility.sh`, `render-reconciled-report.sh`, `auto-fix-allowlist.json`, `plan-scope-detect.sh`, `lib/auto-fix-common.sh`. Skill-specific applier: `apply-auto-fix-code.sh` → `deep-review`; `apply-auto-fix-plan.sh` → `review-plan`. (`plan-scope-detect.sh` is bundled into both because `audit-auto-fix-eligibility.sh:9-11` references it unconditionally at startup; bundling the union avoids conditional-presence bugs.)
- Make `bundle-appliers.sh` idempotent and deterministic (stable file set, `chmod +x` on `.sh`) so the sync round-trip produces no spurious diff.
- **Run `just bundle-appliers` and commit the generated `scripts/` subtrees** — the parity test and the Phase 2 base-dir paths both depend on these artifacts existing. Confirm `bash tests/parity/test-applier-bundle-parity.sh` is green before proceeding.
- Write `tests/parity/test-applier-bundle-parity.sh`: assert byte-identity (`cmp -s`) between each canonical `scripts/X` and every bundled copy across all four skill mirrors; fail listing any drifted/missing file. Include a **drift-injection** negative case (mutate a bundled copy in a temp checkout → assert non-zero exit), an **idempotency** assertion (run `bundle-appliers.sh` twice → `git diff --exit-code` on the bundled subtree), and a **lib-resolution** assertion (a bundled `audit-`/applier run resolves `AF_ALLOWLIST_PATH` to the bundled allowlist, not a flattened path). Self-locate `ROOT_DIR` via `BASH_SOURCE` like the sibling parity test.
- Add `just bundle-appliers` recipe and a `just parity-tests` aggregate target that runs `test-applier-bundle-parity.sh`, `test-allowlist-byte-identity.sh`, and `test-auto-fix-orchestration-contract.sh` (folding in the two currently-orphaned parity tests). Do **not** wire the `check-sync` gate yet — that lands in Phase 3 after `promote-skills` has seeded global, so `check-sync` is never red between phases.

### Phase 2: SKILL.md base-dir path convention + no-fallback hard-fail (×4 mirrors)

**Impl files:** `.claude/skills/deep-review/SKILL.md`, `.claude/skills/review-plan/SKILL.md`, `.codex/skills/deep-review/SKILL.md`, `.codex/skills/review-plan/SKILL.md`, `tests/parity/test-auto-fix-orchestration-contract.sh`
**Test files:** `tests/parity/test-no-manual-apply-fallback.sh`, `tests/parity/test-auto-fix-orchestration-contract.sh`, `tests/parity/test-allowlist-byte-identity.sh`
**Test command:** `bash scripts/check-prompt-parity.sh && bash tests/parity/test-allowlist-byte-identity.sh && bash tests/parity/test-auto-fix-orchestration-contract.sh && bash tests/parity/test-no-manual-apply-fallback.sh`

- Consume the Phase 0 Codex resolution decision first. Document the resolution idiom for each harness. For Codex, explicitly cover the loaded-skill-path probe result, whether `CODEX_HOME` is supported, installed global skill paths, and repo-local mirror paths used only during development.
- In each SKILL.md, replace **every executable pipeline invocation** (not just the appliers — `reconcile-findings.sh`, `audit-auto-fix-eligibility.sh`, `render-reconciled-report.sh` are invoked by path and `audit-` fails bare from a foreign cwd identically to the appliers) with a skill-base-dir-anchored path. Claude side: anchor at the disclosed base dir. Codex side: use the resolved idiom (may legitimately differ — the only sanctioned divergence). Enumerate the complete executable set per mirror; leave prose citations (e.g. deep-review `:392-399`) bare as documentation.
  - deep-review Claude executable lines: `:404` (reconcile), `:420` (reconcile), `:427` (audit), `:464` (apply). deep-review Codex: `:401` (apply) + its reconcile/audit lines.
  - review-plan Claude executable lines: `:328` (reconcile), `:335` (audit), `:437` (apply). review-plan Codex: `:454` (apply) + its reconcile/audit lines.
- Update `tests/parity/test-auto-fix-orchestration-contract.sh:60-78` expected literals to the new anchored form (it currently asserts the bare `scripts/audit-auto-fix-eligibility.sh --skill … <envelope>` substring in every mirror).
- Add a short "Resolving the bundled applier" subsection to each SKILL.md explaining the base-dir anchor and the **hard-fail** rule: if the bundled `scripts/` subtree is absent, abort with a clear error — never apply fixes manually.
- Grep all four mirrors for any prose that authorizes a direct/manual apply fallback; remove or tighten it.
- Write `tests/parity/test-no-manual-apply-fallback.sh`: assert (a) each mirror contains the hard-fail sentence, (b) no mirror contains direct/manual-apply authorizing phrasing, and (c) a reproducible missing-bundle case (rename a bundled `scripts/` dir in a temp install → assert the applier path exits non-zero). Add it to `just parity-tests`.
- Add a Codex-specific resolution assertion to `test-auto-fix-orchestration-contract.sh` or a new parity test: the `.codex` SKILL.md for both `deep-review` and `review-plan` must name the Phase 0 resolved installed path (runtime-disclosed loaded skill path, `$HOME/.codex/skills/<skill>/scripts/`, or `${CODEX_HOME:-$HOME/.codex}/skills/<skill>/scripts/` only when `CODEX_HOME` support is proven) and must not leave executable invocations as bare `scripts/...`.
- Keep the allowlist array literal byte-identical in all four mirrors; re-run `bundle-appliers` only if `auto-fix-allowlist.json` changed (it should not).
- **Atomicity note:** the hard-fail SKILL.md must not reach a global install before the bundled scripts do — Phase 2 and Phase 3's promote land in the same PR/merge, and the promote runs as part of merge (see Phase 3), so no install ever has the hard-fail without the bundled scripts.

### Phase 3: Sync round-trip authority + check-sync gate + promote + docs

**Impl files:** `scripts/check-sync.sh`, `scripts/sync-skills.sh`, `AGENTS.md`, `README.md`, `docs/dev_plans/README.md`, `docs/dev_plans/CODEX_MIRROR_BACKLOG.md`
**Test files:** `tests/parity/test-applier-bundle-parity.sh`
**Test command:** `just parity-tests && just check-sync`
**Validation cmd:** `just promote-skills && just check-sync`

- **Bundled-`scripts/` authority in the round-trip.** Decide and implement one of: (a) re-run `bundle-appliers.sh` after `sync-skills` so canonical always wins, wired into the sync flow; or (b) add a dedicated byte-identity block to `check-sync.sh` (mirroring the content-review `references/` block at `check-sync.sh:63-122`) that asserts canonical `scripts/X` == every bundled copy in repo **and** global, independent of the generic `diff -ru` gate. Document which axis each gate owns: the new `test-applier-bundle-parity.sh` enforces **canonical↔bundle** (repo-internal); `check-sync.sh:29,39` `diff -ru` enforces **repo↔global**. Record the required edit order: edit canonical → `bundle-appliers` → commit → `promote-skills`.
- Wire the bundle-parity gate into `check-sync.sh` as a **distinct edit inside `check-sync.sh`** (a `cmp -s` loop or a call to `test-applier-bundle-parity.sh`), separate from whichever `just` target the test is folded into. This is safe to add now because promote (this phase) seeds the global bundled subtree.
- `promote-skills` to seed the global install with the bundled subtree; then verify `sync-skills` (global→repo) round-trips it back with no drift (`git diff --exit-code`), confirming the authority guard from the first bullet holds.
- Add an **out-of-repo global-install portability** check: from a cwd in an unrelated repo, invoke the applier via `$HOME/.claude/skills/deep-review/scripts/apply-auto-fix-code.sh --test-cmd 'true' <fixture>` and confirm it resolves its lib + allowlist (this is the exact scenario the feature exists to fix; the repo skill dir does not exercise the promote→global path).
- Update `AGENTS.md`: Architecture tree (skill dirs now contain a bundled `scripts/` subtree), the Auto-fix tier section (appliers ship with the skill; pipeline resolves via skill base dir), the Commands list (`just bundle-appliers`, `just parity-tests`), and the Authority Model (bundled-`scripts/` generated-then-committed, canonical wins).
- Update `docs/dev_plans/README.md` task tables (Comp = `review-skills`) and `CODEX_MIRROR_BACKLOG.md` if the Codex resolution idiom introduces a tracked divergence.
- Confirm bundled skill scripts are committable (verified: not gitignored).

## Technical Specifications

### Files to Modify
- `.claude/skills/deep-review/SKILL.md`, `.codex/skills/deep-review/SKILL.md` — every executable pipeline invocation → base-dir-anchored; add resolution + hard-fail subsection; remove any fallback prose.
- `.claude/skills/review-plan/SKILL.md`, `.codex/skills/review-plan/SKILL.md` — same.
- `tests/parity/test-auto-fix-orchestration-contract.sh` — update expected literals (`:60-78`) from bare `scripts/audit-…` to the anchored form.
- `justfile` — add `bundle-appliers`; add `parity-tests` aggregate (bundle-parity + allowlist-parity + orchestration-contract).
- `scripts/check-sync.sh` — gate on canonical↔bundle parity (distinct edit; lands in Phase 3 after promote).
- `scripts/sync-skills.sh` — enforce bundled-`scripts/` authority on the global→repo direction (re-bundle after sync, or rely on the dedicated check-sync block).
- `AGENTS.md`, `README.md`, `docs/dev_plans/README.md`, `docs/dev_plans/CODEX_MIRROR_BACKLOG.md` — docs.

### New Files to Create
- `scripts/bundle-appliers.sh` — copies canonical `scripts/` subtree into each skill's bundled `scripts/`.
- `tests/parity/test-applier-bundle-parity.sh` — byte-identity drift guard + drift-injection + idempotency + lib-resolution cases.
- `tests/parity/test-no-manual-apply-fallback.sh` — asserts hard-fail prose present, no fallback phrasing, missing-bundle exits non-zero.
- Bundled copies (generated by `bundle-appliers.sh`, committed): `.claude/skills/{deep-review,review-plan}/scripts/**` and `.codex/skills/{deep-review,review-plan}/scripts/**`.

### Architecture Decisions
- **Copy + parity, not symlink.** Symlinks (`../../../scripts/X`) break on global install (no repo `scripts/` there) and aren't portable. Committed byte-identical copies guarded by a parity test match the repo's existing single-source-of-truth posture (`auto-fix-allowlist.json`).
- **Preserve `scripts/` + `scripts/lib/` layout inside the skill dir.** The appliers' `BASH_SOURCE`-relative resolution expects to sit at `<root>/scripts/X` with the lib at `<root>/scripts/lib/`. Bundling under `<skill>/scripts/` satisfies this with zero script edits; `<root>` resolves to the skill dir. The depth is load-bearing: `auto-fix-common.sh:38` walks `../..`, so a flattened bundle resolves the wrong allowlist path silently at runtime — Phase 1 asserts the resolved path.
- **Dual-root invariant (precondition for edit-free bundling).** Appliers resolve *dependencies* via `SCRIPT_ROOT`/`AF_LIB_ROOT` (BASH_SOURCE, script home) but write *manifests* under the caller's `git rev-parse --show-toplevel` (`apply-auto-fix-code.sh:38-46`, `auto-fix-common.sh:43-48`). This separation is exactly why bundling into the install dir works without writing scratch there. A future refactor that collapses the two roots would silently break portability — do not.
- **Bundle the union of pipeline scripts into both skills.** Avoids conditional-presence bugs from `audit-auto-fix-eligibility.sh:9-11`'s unconditional `plan-scope-detect.sh` reference; keeps the bundle map and parity test uniform.
- **Anchor executable invocations only; prose citations stay bare.** Each SKILL.md has 15-16 `scripts/` references but only ~3-4 are executable. Executable lines (reconcile/audit/render/apply) get the base-dir anchor; prose source-of-truth pointers (e.g. deep-review `:392-399`) remain bare `scripts/` as documentation. This asymmetry is sanctioned here so a later reviewer does not "fix" it.
- **Two check-sync axes, owned separately.** `test-applier-bundle-parity.sh` enforces **canonical↔bundle** (repo-internal generated-artifact integrity). `check-sync.sh:29,39` `diff -ru` enforces **repo↔global** (mirror sync). The global→repo `sync-skills` direction must not overwrite canonical-bundled copies with stale global ones — guarded by re-bundling after sync or a dedicated check-sync block (Phase 3), mirroring the content-review `references/` precedent.
- **Resolution idiom is the one sanctioned `.claude`/`.codex` divergence.** Mirrors the existing carve-out for harness dispatch idioms; everything else stays in parity.

### Dependencies
- Tooling only (no package manifest): `bash`, `jq`, `shellcheck`, `shfmt` (`AGENTS.md:17`), plus `python3` used by `tests/parity/test-allowlist-byte-identity.sh:30`. No new dependencies.

### Integration Seams

| Seam | Writer | Caller | Contract |
|------|--------|--------|----------|
| Bundled scripts byte-identical to canonical (canonical↔bundle axis) | `scripts/bundle-appliers.sh` | `tests/parity/test-applier-bundle-parity.sh`, `check-sync.sh` dedicated block | Every bundled copy `cmp -s` equal to `scripts/<name>`; missing/drifted file fails the test |
| Applier invocation path | SKILL.md (×4) | model at runtime | Every executable pipeline line anchored at skill base dir; bundled `scripts/` absent → hard-fail, no manual apply (asserted by `test-no-manual-apply-fallback.sh`) |
| Orchestration-contract literals | SKILL.md (×4) | `test-auto-fix-orchestration-contract.sh:60-78` | Asserted invocation substrings match the anchored form, not the bare `scripts/…` form |
| `--test-cmd` mandatory | `apply-auto-fix-code.sh:88-90` | SKILL.md prose, `tests/auto-fix/test-deep-review-test-command-required.sh` | Absent `--test-cmd`/`AUTO_FIX_TEST_CMD` → exit 2, no edits |
| Sync round-trip authority (repo↔global axis) | `bundle-appliers.sh` (deterministic) + `sync-skills.sh` guard | `sync-skills`/`promote-skills`/`bootstrap-skills` rsync | global→repo `--delete` must not overwrite canonical-bundled repo copy with stale global; round-trip produces no spurious diff (`git diff --exit-code`) |

## Testing Notes

### Test Approach
- [ ] `test-applier-bundle-parity.sh` — byte-identity across all bundled copies; drift-injection negative case; idempotency (`bundle-appliers` twice → `git diff --exit-code`); lib-resolution (`AF_ALLOWLIST_PATH` resolves to bundled allowlist).
- [ ] `test-no-manual-apply-fallback.sh` — hard-fail prose present in every mirror; no fallback phrasing; missing-bundle exits non-zero.
- [ ] `test-auto-fix-orchestration-contract.sh` — green after literals updated to anchored form.
- [ ] `check-prompt-parity.sh` + `test-allowlist-byte-identity.sh` — green after SKILL.md edits (allowlist literals untouched).
- [ ] Existing `tests/auto-fix/test-deep-review-test-command-required.sh` exercises `--test-cmd` exit 2 against the bundled applier.
- [ ] Scripted out-of-repo / global-install: from a cwd in an unrelated repo, `$HOME/.claude/skills/deep-review/scripts/apply-auto-fix-code.sh --test-cmd 'true' <fixture>` resolves lib + allowlist (post-promote).
- [ ] Scripted Codex out-of-repo / global-install: from a cwd in an unrelated repo, invoke both `<resolved-codex-skill-root>/deep-review/scripts/apply-auto-fix-code.sh --test-cmd 'true' <fixture>` and `<resolved-codex-skill-root>/review-plan/scripts/apply-auto-fix-plan.sh --plan <fixture-plan> <fixture-envelope>` to prove the documented `.codex` installed-path idiom resolves the bundled lib + allowlist. Run a temporary `CODEX_HOME` variant only if Phase 0 proves Codex honors `CODEX_HOME`.
- [ ] `just parity-tests && just check-sync` clean after a `promote-skills`/`sync-skills` round-trip.

### Test Results
- [ ] All existing tests pass
- [ ] New parity + no-fallback tests added and passing
- [ ] Orchestration-contract literals updated and green
- [ ] Out-of-repo global-install applier invocation verified

### Edge Cases Tested
- [ ] Bundled file drifted from canonical → parity test fails
- [ ] `bundle-appliers` run twice → no git diff (idempotent)
- [ ] Flattened/wrong-depth bundle → lib resolves wrong allowlist (asserted against)
- [ ] Bundled `scripts/` subtree absent → SKILL.md hard-fails (no manual apply), missing-bundle path exits non-zero
- [ ] `--test-cmd` absent → exit 2
- [ ] global→repo `sync-skills --delete` does not overwrite canonical-bundled copy

## Acceptance Criteria

- `deep-review` and `review-plan` install dirs contain a `scripts/` subtree with the bundled pipeline; the gated applier resolves and runs from an arbitrary cwd (proven by the scripted global-install out-of-repo test, not a manual checkbox).
- `--test-cmd` remains mandatory; missing bundled scripts hard-fail with no manual-apply fallback — asserted by `test-no-manual-apply-fallback.sh` (recurring), not a one-time grep.
- Every executable pipeline invocation (reconcile/audit/render/apply) is base-dir-anchored across all four mirrors; prose citations remain bare and documented as such.
- Codex resolution is documented and tested as an installed-skill contract based on Phase 0 evidence: use the runtime-disclosed loaded skill path if present; otherwise use `$HOME/.codex/skills/<skill>/scripts/`; use `${CODEX_HOME:-$HOME/.codex}/skills/<skill>/scripts/` only if `CODEX_HOME` support is proven. Repo-local `.codex/skills/<skill>` paths are only used for development/parity checks.
- `scripts/bundle-appliers.sh` + `tests/parity/test-applier-bundle-parity.sh` enforce canonical↔bundle byte-identity (incl. drift-injection, idempotency, lib-resolution); wired into `just parity-tests` and a distinct `check-sync.sh` gate (added after promote seeds global).
- `tests/parity/test-auto-fix-orchestration-contract.sh` literals updated to the anchored form and green.
- All four SKILL.md mirrors updated; `check-prompt-parity.sh` and `test-allowlist-byte-identity.sh` green; `.claude`/`.codex` divergence limited to the documented resolution idiom.
- Bundled subtree round-trips through sync/promote/bootstrap without drift; global→repo `sync-skills` does not overwrite canonical-bundled copies (authority guard in place).
- Phase 2 hard-fail and Phase 3 promote land in the same merge — no install ever has the hard-fail without the bundled scripts.
- `AGENTS.md` / READMEs / `CODEX_MIRROR_BACKLOG.md` updated.
- `/review-plan`, `/deep-review`, `/update-docs`, `/security-review` run before merge; findings fixed.
<!-- reviewed: 2026-05-23 @ 739c3687f7014bd00c4f11b8f8e9fe121911083a -->

<!-- /review-plan writes the marker line above. Everything below is the workspace: edits here do NOT invalidate the marker. -->

## Progress

- [ ] Phase 0: Codex runtime resolution preflight
- [ ] Phase 1: Bundle build step + generate copies + drift-guard parity tests
- [ ] Phase 2: SKILL.md base-dir path convention + no-fallback hard-fail (×4 mirrors; consumes Phase 0 Codex resolution decision)
- [ ] Phase 3: Sync round-trip authority + check-sync gate + promote + docs

## Findings

- (append findings here as work proceeds)

## Issues & Solutions

- (none yet)

## Final Results

[Fill when complete]
