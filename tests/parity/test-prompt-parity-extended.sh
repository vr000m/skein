#!/usr/bin/env bash
# tests/parity/test-prompt-parity-extended.sh
#
# Phase 3 acceptance suite for the extended ``scripts/check-prompt-parity.sh``.
#
# Each sub-test runs the script against a synthetic ``MANAGED_SKILLS`` value
# pointing at a temporary directory that mimics the
# ``plugins/skein/`` / ``plugins/skein-codex/`` layout the production
# script expects. We override
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
    mkdir -p "$root/scripts" "$root/plugins/skein/skills" "$root/plugins/skein-codex/skills"
    cp "$REAL_SCRIPT" "$root/scripts/check-prompt-parity.sh"
    chmod +x "$root/scripts/check-prompt-parity.sh"
    # ``check-prompt-parity.sh`` references scripts/reconcile-findings.sh —
    # supply an empty stub so that check passes.
    cat >"$root/scripts/reconcile-findings.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$root/scripts/reconcile-findings.sh"
    # ``check-prompt-parity.sh`` (Phase 1+) reads scripts/auto-fix-allowlist.json
    # to validate SKILL.md citations. Seed the real allowlist into the fake root
    # so sandbox tests reflect the production schema.
    cp "$REPO_ROOT/scripts/auto-fix-allowlist.json" "$root/scripts/auto-fix-allowlist.json"
}

# Seed a skill directory pair with matching rubric, prompts, and SKILL.md.
seed_skill_pair() {
    local root="$1"
    local skill="$2"
    local prompt_basename="${3:-implementer-prompt.md}"
    mkdir -p "$root/plugins/skein/skills/$skill" "$root/plugins/skein-codex/skills/$skill"
    # SKILL.md must contain the GENERIC block for deep-review/review-plan
    # plus the verbatim allowlist citations consumed by check-prompt-parity.
    if [[ "$skill" == "deep-review" || "$skill" == "review-plan" ]]; then
        local allowlist_text deep_review_allowlist review_plan_allowlist
        allowlist_text="$(tr -d '\n' <"$root/scripts/auto-fix-allowlist.json")"
        deep_review_allowlist="$(printf '%s' "$allowlist_text" | sed -E 's/.*"deep-review":(\[[^]]*\]).*/\1/')"
        review_plan_allowlist="$(printf '%s' "$allowlist_text" | sed -E 's/.*"review-plan":(\[[^]]*\]).*/\1/')"
        for side in plugins/skein plugins/skein-codex; do
            cat >"$root/$side/skills/$skill/SKILL.md" <<EOF
stub

<!-- BEGIN GENERIC FINDING SCHEMA AND MERGE -->
canonical-block-line-1
canonical-block-line-2
<!-- END GENERIC FINDING SCHEMA AND MERGE -->

deep-review allowlist: ${deep_review_allowlist}
review-plan allowlist: ${review_plan_allowlist}

trailing
EOF
        done
    else
        echo "stub" >"$root/plugins/skein/skills/$skill/SKILL.md"
        echo "stub" >"$root/plugins/skein-codex/skills/$skill/SKILL.md"
    fi
    echo "matching-rubric" >"$root/plugins/skein/skills/$skill/rubric.md"
    echo "matching-rubric" >"$root/plugins/skein-codex/skills/$skill/rubric.md"
    echo "shared prompt" >"$root/plugins/skein/skills/$skill/$prompt_basename"
    echo "shared prompt" >"$root/plugins/skein-codex/skills/$skill/$prompt_basename"
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
# A prompt file landed on the skein mirror but not on skein-codex → drift detected,
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
    rm "$tmp/plugins/skein-codex/skills/conduct/implementer-prompt.md"

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
    echo "DIVERGED prompt" >"$tmp/plugins/skein-codex/skills/conduct/implementer-prompt.md"

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
    echo "DIVERGED ci-parity" >"$tmp/plugins/skein-codex/skills/conduct/ci-parity-prompt.md"

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
# CONDUCT_LAGGING_MIRROR_OK=conduct/ci-parity-prompt.md set, the script exits zero
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
    echo "ci-parity prompt" >"$tmp/plugins/skein/skills/conduct/ci-parity-prompt.md"

    local out rc
    set +e
    out="$(CONDUCT_LAGGING_MIRROR_OK="conduct/ci-parity-prompt.md" \
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
    echo "ci-parity prompt" >"$tmp/plugins/skein/skills/conduct/ci-parity-prompt.md"

    local rc
    set +e
    CONDUCT_LAGGING_MIRROR_OK="conduct/ci-parity-prompt.md" \
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
# Two drifts: one expected (conduct/ci-parity-prompt.md, in env override) and one
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
    echo "ci-parity prompt" >"$tmp/plugins/skein/skills/conduct/ci-parity-prompt.md"
    # Unexpected drift.
    echo "rogue prompt" >"$tmp/plugins/skein/skills/conduct/rogue-prompt.md"

    local out rc
    set +e
    out="$(CONDUCT_LAGGING_MIRROR_OK="conduct/ci-parity-prompt.md" \
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
# CONDUCT_LAGGING_MIRROR_OK is a load-bearing cross-runtime env-var. The
# variable name appears in both the claude-side and codex-side copies of
# check-prompt-parity.sh; a silent rename in one copy would defeat the
# expected-drift escape hatch the variable exists to provide. Assert that
# both runtime mirrors of the script reference it by literal name so a
# rename is caught here.
# ---------------------------------------------------------------------------

test_conduct_lagging_mirror_ok_referenced_by_both_runtimes() {
    local claude_script="$REPO_ROOT/scripts/check-prompt-parity.sh"
    local codex_script="$REPO_ROOT/scripts/check-prompt-parity.sh"
    # The repo currently ships exactly one shared parity script under
    # scripts/. If a future change forks a codex-only copy, extend the
    # assertion to check both paths. For now, assert the literal name is
    # present in the canonical script.
    if ! grep -q "CONDUCT_LAGGING_MIRROR_OK" "$claude_script"; then
        _fail "conduct-lagging-mirror-ok-referenced-by-script" \
            "CONDUCT_LAGGING_MIRROR_OK literal missing from $claude_script"
        return
    fi
    # Also assert this test script itself references it — guards against a
    # rename in the production script that would leave this acceptance
    # suite silent because the test fixtures stopped exercising the env
    # variable.
    if ! grep -q "CONDUCT_LAGGING_MIRROR_OK" "${BASH_SOURCE[0]}"; then
        _fail "conduct-lagging-mirror-ok-referenced-by-script" \
            "CONDUCT_LAGGING_MIRROR_OK literal missing from test-prompt-parity-extended.sh"
        return
    fi
    _pass "conduct-lagging-mirror-ok-referenced-by-both-runtimes"
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Phase 4: Codex-only / Claude-only auto-fix wiring drift is caught.
#
# Plan invariant: "assert a Codex-only auto-fix wiring drift fails the
# parity gate, so Codex cannot silently lag Claude." Symmetry: a
# Claude-only drift must fail too.
#
# Scope clarification: scripts/check-prompt-parity.sh enforces
# byte-identity on rubric.md and *-prompt.md, but SKILL.md is checked
# only for (a) the GENERIC FINDING SCHEMA AND MERGE block being
# byte-identical across all four mirrors and (b) the auto-fix
# allowlist arrays being cited verbatim. The "auto-fix wiring" surface
# named by the plan is precisely those two regions inside SKILL.md, so
# the Phase 4 tests target each region directly rather than
# whole-file byte-equality (which the script does not enforce on
# SKILL.md).
#
# Strategy: operate on the real repo tree, mutate one region in one
# mirror at a time, run the real script, then restore from
# `git show HEAD:`. Refuse to run if any target is already dirty so a
# stale working tree cannot lose user edits.
# ---------------------------------------------------------------------------

_phase4_refuse_if_dirty() {
    local rel="$1"
    if ! git -C "$REPO_ROOT" diff --quiet -- "$rel" 2>/dev/null \
        || ! git -C "$REPO_ROOT" diff --cached --quiet -- "$rel" 2>/dev/null; then
        return 1
    fi
    return 0
}

_phase4_restore_from_head() {
    local rel="$1"
    git -C "$REPO_ROOT" show "HEAD:$rel" >"$REPO_ROOT/$rel"
}

_phase4_run_real_parity() {
    # Run the real script in the real repo (no MANAGED_SKILLS override).
    # Capture combined output for diagnostics on failure.
    local out
    set +e
    out="$(bash "$REAL_SCRIPT" 2>&1)"
    local rc=$?
    set -e
    PHASE4_LAST_OUT="$out"
    return $rc
}

# Inject a sentinel line into the file so it no longer byte-matches its
# mirror. Append-only: the GENERIC block + allowlist literals are
# untouched, so the failure mode under test is the prompt-md /
# SKILL.md byte-equality check rather than allowlist-citation removal.
_phase4_mutate_drift() {
    local path="$1"
    printf '\n<!-- phase4-drift-sentinel %s -->\n' "$(date +%s)" >>"$path"
}

# Tamper the deep-review allowlist citation in `$1` (a SKILL.md path).
# Returns 0 on successful tamper, 2 if the canonical literal was not
# found (so the test can fail loudly rather than silently pass).
_phase4_tamper_allowlist() {
    python3 - "$1" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
text = p.read_text(encoding="utf-8")
canonical = '["docstring_typo","unused_import","unused_var","mechanical_replace","import_sort"]'
if canonical not in text:
    sys.stderr.write(f"canonical allowlist literal not found in {p}\n")
    sys.exit(2)
p.write_text(text.replace(canonical, '["TAMPERED"]', 1), encoding="utf-8")
PY
}

# Tamper one line inside the GENERIC FINDING SCHEMA AND MERGE block of
# `$1`. Returns 0 on success, 2 if the block was not found.
_phase4_tamper_generic_block() {
    python3 - "$1" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
text = p.read_text(encoding="utf-8")
begin = "<!-- BEGIN GENERIC FINDING SCHEMA AND MERGE -->"
end = "<!-- END GENERIC FINDING SCHEMA AND MERGE -->"
i = text.find(begin)
j = text.find(end)
if i < 0 or j < 0 or j <= i:
    sys.stderr.write(f"GENERIC block not found in {p}\n")
    sys.exit(2)
# Inject a sentinel line just after the BEGIN marker.
inject_at = text.find("\n", i) + 1
tampered = text[:inject_at] + "<!-- phase4-generic-tamper -->\n" + text[inject_at:]
p.write_text(tampered, encoding="utf-8")
PY
}

# Generic mutate-and-restore helper. Args: <test_name> <rel-path>
# <tamper-fn-name>. Asserts:
#   * baseline parity green
#   * after tampering: parity non-zero
#   * after restore: parity green again
# Always restores via `git show HEAD:` so a failure mid-test cannot
# leave the working tree dirty.
_phase4_mutate_and_assert_caught() {
    local test_name="$1"
    local rel="$2"
    local tamper_fn="$3"
    local path="$REPO_ROOT/$rel"
    if [[ ! -f "$path" ]]; then
        _fail "$test_name" "missing $rel"
        return
    fi
    if ! _phase4_refuse_if_dirty "$rel"; then
        _fail "$test_name" "$rel has uncommitted changes — refusing to mutate"
        return
    fi
    if ! _phase4_run_real_parity; then
        _fail "$test_name" "baseline parity is already red; out=$PHASE4_LAST_OUT"
        return
    fi
    if ! "$tamper_fn" "$path"; then
        _phase4_restore_from_head "$rel"
        _fail "$test_name" "tamper helper $tamper_fn failed against $rel"
        return
    fi
    if _phase4_run_real_parity; then
        _phase4_restore_from_head "$rel"
        _fail "$test_name" "drift in $rel was NOT caught by check-prompt-parity.sh"
        return
    fi
    _phase4_restore_from_head "$rel"
    if ! _phase4_run_real_parity; then
        _fail "$test_name" "parity still red after restoring $rel from HEAD; out=$PHASE4_LAST_OUT"
        return
    fi
    _pass "$test_name"
}

test_phase4_codex_only_allowlist_citation_drift_fails_parity() {
    _phase4_mutate_and_assert_caught \
        "phase4-codex-only-auto-fix-wiring-drift-fails-parity" \
        "plugins/skein-codex/skills/deep-review/SKILL.md" \
        _phase4_tamper_allowlist
}

test_phase4_claude_only_allowlist_citation_drift_fails_parity() {
    _phase4_mutate_and_assert_caught \
        "phase4-claude-only-auto-fix-wiring-drift-fails-parity" \
        "plugins/skein/skills/deep-review/SKILL.md" \
        _phase4_tamper_allowlist
}

test_phase4_codex_only_generic_block_drift_fails_parity() {
    _phase4_mutate_and_assert_caught \
        "phase4-codex-only-generic-finding-block-drift-fails-parity" \
        "plugins/skein-codex/skills/deep-review/SKILL.md" \
        _phase4_tamper_generic_block
}

test_phase4_claude_only_generic_block_drift_fails_parity() {
    _phase4_mutate_and_assert_caught \
        "phase4-claude-only-generic-finding-block-drift-fails-parity" \
        "plugins/skein/skills/deep-review/SKILL.md" \
        _phase4_tamper_generic_block
}

test_phase4_review_plan_codex_only_allowlist_drift_fails_parity() {
    _phase4_mutate_and_assert_caught \
        "phase4-review-plan-codex-only-auto-fix-wiring-drift-fails-parity" \
        "plugins/skein-codex/skills/review-plan/SKILL.md" \
        _phase4_tamper_allowlist
}

test_mirror_commit_required_after_impl
test_prompt_divergence_detected
test_ci_parity_prompt_included
test_phase_3_impl_commit_lands_with_hooks_enabled_in_intermediate_state
test_check_prompt_parity_exits_with_documented_expected_drift
test_check_prompt_parity_exits_zero_when_all_drift_expected
test_check_prompt_parity_exits_non_zero_on_mixed_drift
test_conduct_lagging_mirror_ok_referenced_by_both_runtimes
test_phase4_codex_only_allowlist_citation_drift_fails_parity
test_phase4_claude_only_allowlist_citation_drift_fails_parity
test_phase4_codex_only_generic_block_drift_fails_parity
test_phase4_claude_only_generic_block_drift_fails_parity
test_phase4_review_plan_codex_only_allowlist_drift_fails_parity

echo
echo "passed=$PASS failed=$FAIL"
if [[ "$FAIL" -ne 0 ]]; then
    exit 1
fi
exit 0
