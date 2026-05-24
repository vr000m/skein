set dotenv-load := true

sync-skills:
    ./scripts/sync-skills.sh

promote-skills:
    ./scripts/promote-skills.sh --yes

bootstrap-skills:
    ./scripts/bootstrap-skills.sh --yes

bootstrap-skills-force:
    ./scripts/bootstrap-skills.sh --yes --force

check-sync:
    ./scripts/check-sync.sh

# Verify rubric.md parity between .claude and .codex mirrors
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
