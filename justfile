set dotenv-load := true

# Skein ships as two Claude Code marketplace plugins (skein/, skein-codex/)
# under plugins/. Installation is via `/plugin install skein` (Claude Code)
# and `codex plugin add skein@<marketplace>` (Codex), not through repo
# scripts. The recipes below cover parity, drift, and bundle regeneration
# only — there are no sync/promote/bootstrap workflows.

check-sync:
    ./scripts/check-sync.sh

# Verify rubric.md and *-prompt.md parity plus normalized release workflows
# between the skein (Claude) and skein-codex mirrors.
check-prompt-parity:
    ./scripts/check-prompt-parity.sh

# Verify the trunk-resolution snippet is byte-identical across SKILL.md copies
check-trunk-snippet-parity:
    ./scripts/check-trunk-snippet-parity.sh

# Regenerate the bundled auto-fix pipeline inside each skill's scripts/ subtree
bundle-appliers:
    ./scripts/bundle-appliers.sh

# Run every parity guard: bundle/allowlist byte-identity, prompt/release contracts,
# auto-fix orchestration, marker parity, and managed-skill/cleanup regressions.
parity-tests:
    ./scripts/check-prompt-parity.sh
    bash tests/parity/test-applier-bundle-parity.sh
    bash tests/parity/test-allowlist-byte-identity.sh
    bash tests/parity/test-auto-fix-orchestration-contract.sh
    bash tests/parity/test-handoff-ignores-auto-fix.sh
    bash tests/parity/test-no-manual-apply-fallback.sh
    bash tests/parity/test-conduct-marker-parity.sh
    bash tests/parity/test-marker-parity.sh
    bash tests/parity/test-spawn-tiers.sh
    bash tests/parity/test-managed-skills-parity.sh
    bash tests/parity/test-prompt-parity-extended.sh
    uv run --with pytest python -m pytest tests/parity/test_skill_md_presence.py -q
    uv run --with pytest python -m pytest tests/parity/test_release_skill_contract.py -q
    uv run --with pytest python -m pytest tests/parity/test_delete_skills.py -q
    bash tests/auto-fix/test-review-plan-marker-write.sh

# Run the review-gauntlet test suite (schema + injection coverage, plus the
# skill-shape, convergence, reuse-wiring, marker, and hook tests).
gauntlet-tests:
    bash tests/gauntlet/test-goal-field-schema.sh
    bash tests/gauntlet/test-goal-injection.sh
    bash tests/gauntlet/test-goal-docs.sh
    bash tests/gauntlet/test-gauntlet-skill-shape.sh
    bash tests/gauntlet/test-convergence-ledger.sh
    bash tests/gauntlet/test-run-gate.sh
    bash tests/gauntlet/test-reuse-wiring.sh
    bash tests/gauntlet/test-review-gates-marker.sh
    bash tests/gauntlet/test-conduct-hook.sh
    bash tests/gauntlet/test-fanout-hook.sh
    bash tests/gauntlet/test-codex-capability-gap-unresolved.sh
    bash tests/gauntlet/test-gate-timeout.sh
    bash tests/gauntlet/test-lens-budget.sh
    bash tests/gauntlet/test-regression-stop.sh
    bash tests/gauntlet/test-finding-key.sh
    bash tests/gauntlet/test-claimed-findings.sh
    bash tests/gauntlet/test-status-row.sh

# Phase 2 disk-first streamed lens results: persist-lens-result.sh (writer),
# collect-lens-results.sh (reader/merge), persist-deep-review-state.sh's
# --from-collector derivation, and the deep-review/review-plan SKILL.md
# shape assertions (both mirrors).
lens-tests:
    bash tests/lenses/test-persist-lens-result.sh
    bash tests/lenses/test-lens-collect.sh
    bash tests/lenses/test-derived-lenses-state.sh
    bash tests/lenses/test-lens-skill-shape.sh

reconciliation-tests:
    ./scripts/check-prompt-parity.sh
    ./scripts/check-trunk-snippet-parity.sh
    bash tests/reconciliation/test-renderer.sh
    bash tests/reconciliation/run-fixtures.sh
    bash tests/reconciliation/test-determinism.sh
    bash tests/reconciliation/test-reconciler-unit.sh
    bash tests/reconciliation/test-review-plan-state.sh
    bash tests/reconciliation/test-deep-review-state.sh
    ./scripts/check-report-templates.sh
    bash tests/reconciliation/test-check-report-templates.sh

# Plus a grep lint for PREDICTABLE temp paths (`/tmp/foo.$$`, `/tmp/foo.$RANDOM`)
# anywhere under scripts/, tests/ and plugins/. R5/R11: a lone
# `2>/tmp/gauntlet-ledger-test-precompat.$$` in a suite where 18 sibling temp
# files went through `mktemp` is followed by bash's `>` redirect if a symlink
# is pre-planted there. A behavioural test asserting a test's own temp-path
# construction would be circular, so the guard is a lint.
#
# shellcheck + shfmt over the canonical scripts/ tree AND review-gauntlet's
# hand-authored lib/. The lib/ files have no canonical counterpart under
# scripts/ (they are not bundled by bundle-appliers.sh), so without this line
# ~1400 lines of signal handling, pgid kills and `# shellcheck disable`
# directives would be linted by nothing. Only the Claude copy is listed: the
# Codex copy is held byte-identical to it by
# tests/parity/test-applier-bundle-parity.sh.
#
# The fourth entry is not an exception to the rule, it IS a rule (round 10,
# F8): a `tests/` file is listed here IFF it is the regression suite for a
# lint that this recipe itself runs. `tests/plugin/test-lint-temp-paths.sh`
# qualifies because the last line runs `scripts/lint-temp-paths.sh`; a suite
# that tests something else does not, however shell-shaped it is. The other 61
# files under `tests/*/` are out of scope by MEASUREMENT, not oversight:
# `shellcheck -f gcc tests/*/*.sh` reports 86 findings across 41 files today
# (and even the narrowest containing glob, `tests/plugin/*.sh`, reports 2 --
# in noqa-probe.sh and test_history_and_assets.sh -- plus `shfmt -d` diffs in
# those same two files), so widening a glob here turns `lint-scripts` red on
# pre-existing style debt.
# Cleaning that up is its own change with its own diff; adopt a new file here
# only together with the fix that makes it pass.
lint-scripts:
    shellcheck scripts/*.sh scripts/lib/*.sh plugins/skein/skills/review-gauntlet/lib/*.sh tests/plugin/test-lint-temp-paths.sh
    shfmt -d scripts/*.sh scripts/lib/*.sh plugins/skein/skills/review-gauntlet/lib/*.sh tests/plugin/test-lint-temp-paths.sh
    ./scripts/lint-temp-paths.sh

# Plugin-level guards: CLAUDE.md hygiene rules and the manifest checks.
# (tests/plugin/test_history_and_assets.sh is deliberately NOT listed: it is
# a one-off migration-commit assertion that only holds against the specific
# commit it was written for, not a suite member that can run against
# arbitrary HEAD. tests/plugin/noqa-probe.sh is not listed either -- see the
# `noqa-probe` recipe below.)
plugin-tests:
    bash tests/plugin/test-claude-md-hygiene.sh
    bash tests/plugin/test_manifests.sh
    bash tests/plugin/test-lint-temp-paths.sh

# Diagnostic, NOT a suite member. noqa-probe.sh asserts that
# ~/.claude/hooks/format-on-edit.sh does not strip `# noqa` comments -- but
# that hook is owned by sync-computer, not by this repo, so skein has no code
# path that can turn a red probe green. Its SKIP arms cover "hook absent" and
# "ruff absent", not "hook present and still stripping", which is exactly the
# state the ownership boundary makes possible. Wiring it into plugin-tests
# would therefore fail the suite for a defect in another repo. Run it by hand
# when investigating a stripped `# noqa`; override the target with
# HOOK_PATH=/path/to/format-on-edit.sh.
noqa-probe:
    bash tests/plugin/noqa-probe.sh
