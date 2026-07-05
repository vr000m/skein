set dotenv-load := true

# Skein ships as two Claude Code marketplace plugins (skein/, skein-codex/)
# under plugins/. Installation is via `/plugin install skein` (Claude Code)
# and `codex plugin add skein@<marketplace>` (Codex), not through repo
# scripts. The recipes below cover parity, drift, and bundle regeneration
# only — there are no sync/promote/bootstrap workflows.

check-sync:
    ./scripts/check-sync.sh

# Verify rubric.md parity between the skein (Claude) and skein-codex mirrors
check-prompt-parity:
    ./scripts/check-prompt-parity.sh

# Verify the trunk-resolution snippet is byte-identical across SKILL.md copies
check-trunk-snippet-parity:
    ./scripts/check-trunk-snippet-parity.sh

# Regenerate the bundled auto-fix pipeline inside each skill's scripts/ subtree
bundle-appliers:
    ./scripts/bundle-appliers.sh

# Run every parity guard: bundle byte-identity, allowlist byte-identity, and
# the auto-fix orchestration-contract literals.
parity-tests:
    bash tests/parity/test-applier-bundle-parity.sh
    bash tests/parity/test-allowlist-byte-identity.sh
    bash tests/parity/test-auto-fix-orchestration-contract.sh
    bash tests/parity/test-no-manual-apply-fallback.sh
    bash tests/parity/test-conduct-marker-parity.sh
    bash tests/parity/test-marker-parity.sh
    bash tests/parity/test-spawn-tiers.sh
    bash tests/auto-fix/test-review-plan-marker-write.sh

reconciliation-tests:
    ./scripts/check-prompt-parity.sh
    ./scripts/check-trunk-snippet-parity.sh
    bash tests/reconciliation/test-renderer.sh
    bash tests/reconciliation/run-fixtures.sh
    bash tests/reconciliation/test-determinism.sh
    bash tests/reconciliation/test-reconciler-unit.sh

lint-scripts:
    shellcheck scripts/*.sh scripts/lib/*.sh
    shfmt -d scripts/*.sh scripts/lib/*.sh
