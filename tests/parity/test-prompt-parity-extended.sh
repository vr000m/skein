#!/usr/bin/env bash
# tests/parity/test-prompt-parity-extended.sh
#
# Phase 3 acceptance suite for the extended ``scripts/check-prompt-parity.sh``.
#
# Each sub-test runs the script against a synthetic ``MANAGED_SKILLS`` value
# pointing at a temporary directory that mimics the ``.claude/`` /
# ``.codex/`` layout the production script expects. We override
# ``MANAGED_SKILLS`` and run the script from a fake $ROOT_DIR so the test
# doesn't touch the real repo.
#
# The script under test resolves $ROOT_DIR via
# ``cd "$(dirname "$0")/.." && pwd`` so we drop a stub copy of the script
# into ``$tmp/scripts/`` and run that.

set -eu

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REAL_SCRIPT="$REPO_ROOT/scripts/check-prompt-parity.sh"

if [[ ! -x "$REAL_SCRIPT" ]]; then
    echo "FAIL: $REAL_SCRIPT missing or non-executable" >&2
    exit 1
fi

PASS=0
FAIL=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_pass() {
    PASS=$((PASS + 1))
    echo "PASS: $1"
}

_fail() {
    FAIL=$((FAIL + 1))
    echo "FAIL: $1" >&2
    if [[ -n "${2:-}" ]]; then
        echo "  $2" >&2
    fi
}

# Build a synthetic two-mirror skill layout under $1 with a stub SKILL.md
# (containing the GENERIC FINDING SCHEMA AND MERGE block when $skill is in
# {deep-review, review-plan}) and a placeholder rubric/prompt set.
make_fake_root() {
    local root="$1"
    mkdir -p "$root/scripts" "$root/.claude/skills" "$root/.codex/skills"
    cp "$REAL_SCRIPT" "$root/scripts/check-prompt-parity.sh"
    chmod +x "$root/scripts/check-prompt-parity.sh"
    # ``check-prompt-parity.sh`` references scripts/reconcile-findings.sh —
    # supply an empty stub so that check passes.
    cat >"$root/scripts/reconcile-findings.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$root/scripts/reconcile-findings.sh"
}

# Seed a skill directory pair with matching rubric, prompts, and SKILL.md.
seed_skill_pair() {
    local root="$1"
    local skill="$2"
    local prompt_basename="${3:-implementer-prompt.md}"
    mkdir -p "$root/.claude/skills/$skill" "$root/.codex/skills/$skill"
    # SKILL.md must contain the GENERIC block for deep-review/review-plan.
    if [[ "$skill" == "deep-review" || "$skill" == "review-plan" ]]; then
        for side in .claude .codex; do
            cat >"$root/$side/skills/$skill/SKILL.md" <<'EOF'
stub

<!-- BEGIN GENERIC FINDING SCHEMA AND MERGE -->
canonical-block-line-1
canonical-block-line-2
<!-- END GENERIC FINDING SCHEMA AND MERGE -->

trailing
EOF
        done
    else
        echo "stub" >"$root/.claude/skills/$skill/SKILL.md"
        echo "stub" >"$root/.codex/skills/$skill/SKILL.md"
    fi
    echo "matching-rubric" >"$root/.claude/skills/$skill/rubric.md"
    echo "matching-rubric" >"$root/.codex/skills/$skill/rubric.md"
    echo "shared prompt" >"$root/.claude/skills/$skill/$prompt_basename"
    echo "shared prompt" >"$root/.codex/skills/$skill/$prompt_basename"
}

# Required pair for the GENERIC block extraction — deep-review and
# review-plan are both checked by the script regardless of MANAGED_SKILLS.
seed_generic_pair() {
    local root="$1"
    seed_skill_pair "$root" "deep-review"
    seed_skill_pair "$root" "review-plan"
}

run_script() {
    local root="$1"
    shift
    local managed="$1"
    shift
    # Pass through any env overrides for CONDUCT_LAGGING_MIRROR_OK.
    MANAGED_SKILLS="$managed" \
        CONDUCT_LAGGING_MIRROR_OK="${CONDUCT_LAGGING_MIRROR_OK:-}" \
        "$root/scripts/check-prompt-parity.sh" "$@"
}

# ---------------------------------------------------------------------------
# 1. mirror-commit-required-after-impl
#
# A prompt file landed on .claude but not on .codex → drift detected,
# non-zero exit, message names the missing-mirror file.
# ---------------------------------------------------------------------------

test_mirror_commit_required_after_impl() {
    local tmp
    tmp="$(mktemp -d)"
    trap "rm -rf '$tmp'" RETURN
    make_fake_root "$tmp"
    seed_skill_pair "$tmp" "conduct"
    seed_generic_pair "$tmp"
    # Remove the codex mirror of the prompt → impl-only commit fixture.
    rm "$tmp/.codex/skills/conduct/implementer-prompt.md"

    local out rc
    out="$(run_script "$tmp" "conduct deep-review review-plan" 2>&1 || true)"
    rc=$?
    # run_script with ``|| true`` swallows rc, so re-invoke for the rc only.
    set +e
    run_script "$tmp" "conduct deep-review review-plan" >/dev/null 2>&1
    rc=$?
    set -e
    if [[ "$rc" -eq 0 ]]; then
        _fail "mirror-commit-required-after-impl: expected non-zero exit, got 0" "$out"
        return
    fi
    if ! echo "$out" | grep -q "implementer-prompt.md"; then
        _fail "mirror-commit-required-after-impl: stderr missing prompt filename" "$out"
        return
    fi
    _pass "mirror-commit-required-after-impl"
}

# ---------------------------------------------------------------------------
# 2. prompt-divergence-detected
#
# Both sides have the prompt, but with a single-character change → drift,
# non-zero exit, file named.
# ---------------------------------------------------------------------------

test_prompt_divergence_detected() {
    local tmp
    tmp="$(mktemp -d)"
    trap "rm -rf '$tmp'" RETURN
    make_fake_root "$tmp"
    seed_skill_pair "$tmp" "conduct"
    seed_generic_pair "$tmp"
    echo "DIVERGED prompt" >"$tmp/.codex/skills/conduct/implementer-prompt.md"

    local out rc
    set +e
    out="$(run_script "$tmp" "conduct deep-review review-plan" 2>&1)"
    rc=$?
    set -e
    if [[ "$rc" -eq 0 ]]; then
        _fail "prompt-divergence-detected: expected non-zero exit" "$out"
        return
    fi
    if ! echo "$out" | grep -q "implementer-prompt.md"; then
        _fail "prompt-divergence-detected: divergent file not named in output" "$out"
        return
    fi
    _pass "prompt-divergence-detected"
}

# ---------------------------------------------------------------------------
# 3. ci-parity-prompt-included
#
# Deliberate divergence in ci-parity-prompt.md → script fails. Proves the
# new prompt-md filename is in scope of the extended check.
# ---------------------------------------------------------------------------

test_ci_parity_prompt_included() {
    local tmp
    tmp="$(mktemp -d)"
    trap "rm -rf '$tmp'" RETURN
    make_fake_root "$tmp"
    seed_skill_pair "$tmp" "conduct" "ci-parity-prompt.md"
    seed_generic_pair "$tmp"
    echo "DIVERGED ci-parity" >"$tmp/.codex/skills/conduct/ci-parity-prompt.md"

    local out rc
    set +e
    out="$(run_script "$tmp" "conduct deep-review review-plan" 2>&1)"
    rc=$?
    set -e
    if [[ "$rc" -eq 0 ]]; then
        _fail "ci-parity-prompt-included: expected non-zero exit" "$out"
        return
    fi
    if ! echo "$out" | grep -q "ci-parity-prompt.md"; then
        _fail "ci-parity-prompt-included: ci-parity-prompt.md not named" "$out"
        return
    fi
    _pass "ci-parity-prompt-included"
}

# ---------------------------------------------------------------------------
# 4. phase-3-impl-commit-lands-with-hooks-enabled-in-intermediate-state
#
# Structural assertion: scripts/check-prompt-parity.sh is NOT referenced by
# any pre-commit hook chain in the repo (.pre-commit-config.yaml or any
# git-managed hook). If the script were wired in, the Phase 3 impl commit
# could not land while the codex mirror still lags. The plan's
# pre-implementation step (Phase 3, task 1) requires this absence.
# ---------------------------------------------------------------------------

test_phase_3_impl_commit_lands_with_hooks_enabled_in_intermediate_state() {
    local cfg="$REPO_ROOT/.pre-commit-config.yaml"
    if [[ -f "$cfg" ]]; then
        if grep -q "check-prompt-parity" "$cfg"; then
            _fail "phase-3-impl-commit-lands-with-hooks-enabled-in-intermediate-state" \
                "check-prompt-parity referenced in .pre-commit-config.yaml — Phase 3 impl commit could not land with lagging mirror"
            return
        fi
    fi
    # Also rule out any git hook script under .git/hooks/ invoking it.
    local hooks_dir="$REPO_ROOT/.git/hooks"
    if [[ -d "$hooks_dir" ]]; then
        if grep -rq "check-prompt-parity" "$hooks_dir" 2>/dev/null; then
            _fail "phase-3-impl-commit-lands-with-hooks-enabled-in-intermediate-state" \
                "check-prompt-parity invoked from a git hook"
            return
        fi
    fi
    _pass "phase-3-impl-commit-lands-with-hooks-enabled-in-intermediate-state"
}

# ---------------------------------------------------------------------------
# 5. check-prompt-parity-exits-with-documented-expected-drift-in-mid-handoff
#
# Fixture: claude has ci-parity-prompt.md, codex does not. With
# CONDUCT_LAGGING_MIRROR_OK=ci-parity-prompt.md set, the script exits zero
# AND stderr contains the "expected lagging-mirror drift" annotation.
# ---------------------------------------------------------------------------

test_check_prompt_parity_exits_with_documented_expected_drift() {
    local tmp
    tmp="$(mktemp -d)"
    trap "rm -rf '$tmp'" RETURN
    make_fake_root "$tmp"
    seed_skill_pair "$tmp" "conduct"
    seed_generic_pair "$tmp"
    # Add ci-parity-prompt.md only on the claude side.
    echo "ci-parity prompt" >"$tmp/.claude/skills/conduct/ci-parity-prompt.md"

    local out rc
    set +e
    out="$(CONDUCT_LAGGING_MIRROR_OK="ci-parity-prompt.md" \
        run_script "$tmp" "conduct deep-review review-plan" 2>&1)"
    rc=$?
    set -e
    if [[ "$rc" -ne 0 ]]; then
        _fail "check-prompt-parity-exits-with-documented-expected-drift-in-mid-handoff" \
            "expected zero exit when all drift is in CONDUCT_LAGGING_MIRROR_OK, got $rc; out=$out"
        return
    fi
    if ! echo "$out" | grep -q "expected lagging-mirror drift"; then
        _fail "check-prompt-parity-exits-with-documented-expected-drift-in-mid-handoff" \
            "stderr missing 'expected lagging-mirror drift' annotation; out=$out"
        return
    fi
    _pass "check-prompt-parity-exits-with-documented-expected-drift-in-mid-handoff"
}

# ---------------------------------------------------------------------------
# 6. check-prompt-parity-exits-zero-when-all-drift-expected
#
# Same scenario as #5 but assert specifically: exit zero AND
# CONDUCT_LAGGING_MIRROR_OK is honoured.
# ---------------------------------------------------------------------------

test_check_prompt_parity_exits_zero_when_all_drift_expected() {
    local tmp
    tmp="$(mktemp -d)"
    trap "rm -rf '$tmp'" RETURN
    make_fake_root "$tmp"
    seed_skill_pair "$tmp" "conduct"
    seed_generic_pair "$tmp"
    echo "ci-parity prompt" >"$tmp/.claude/skills/conduct/ci-parity-prompt.md"

    local rc
    set +e
    CONDUCT_LAGGING_MIRROR_OK="ci-parity-prompt.md" \
        run_script "$tmp" "conduct deep-review review-plan" >/dev/null 2>&1
    rc=$?
    set -e
    if [[ "$rc" -ne 0 ]]; then
        _fail "check-prompt-parity-exits-zero-when-all-drift-expected" \
            "expected exit 0, got $rc"
        return
    fi
    _pass "check-prompt-parity-exits-zero-when-all-drift-expected"
}

# ---------------------------------------------------------------------------
# 7. check-prompt-parity-exits-non-zero-on-mixed-expected-and-unknown-drift
#
# Two drifts: one expected (ci-parity-prompt.md, in env override) and one
# unexpected (a new ``rogue-prompt.md`` missing on codex). Expect non-zero
# exit AND the unknown drift named in stderr.
# ---------------------------------------------------------------------------

test_check_prompt_parity_exits_non_zero_on_mixed_drift() {
    local tmp
    tmp="$(mktemp -d)"
    trap "rm -rf '$tmp'" RETURN
    make_fake_root "$tmp"
    seed_skill_pair "$tmp" "conduct"
    seed_generic_pair "$tmp"
    # Expected drift.
    echo "ci-parity prompt" >"$tmp/.claude/skills/conduct/ci-parity-prompt.md"
    # Unexpected drift.
    echo "rogue prompt" >"$tmp/.claude/skills/conduct/rogue-prompt.md"

    local out rc
    set +e
    out="$(CONDUCT_LAGGING_MIRROR_OK="ci-parity-prompt.md" \
        run_script "$tmp" "conduct deep-review review-plan" 2>&1)"
    rc=$?
    set -e
    if [[ "$rc" -eq 0 ]]; then
        _fail "check-prompt-parity-exits-non-zero-on-mixed-expected-and-unknown-drift" \
            "expected non-zero exit on unknown drift, got 0; out=$out"
        return
    fi
    if ! echo "$out" | grep -q "rogue-prompt.md"; then
        _fail "check-prompt-parity-exits-non-zero-on-mixed-expected-and-unknown-drift" \
            "unknown drift file not named in stderr; out=$out"
        return
    fi
    _pass "check-prompt-parity-exits-non-zero-on-mixed-expected-and-unknown-drift"
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

test_mirror_commit_required_after_impl
test_prompt_divergence_detected
test_ci_parity_prompt_included
test_phase_3_impl_commit_lands_with_hooks_enabled_in_intermediate_state
test_check_prompt_parity_exits_with_documented_expected_drift
test_check_prompt_parity_exits_zero_when_all_drift_expected
test_check_prompt_parity_exits_non_zero_on_mixed_drift

echo
echo "passed=$PASS failed=$FAIL"
if [[ "$FAIL" -ne 0 ]]; then
    exit 1
fi
exit 0
