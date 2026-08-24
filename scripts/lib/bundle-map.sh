#!/usr/bin/env bash
# Single source of truth for the auto-fix bundle map. Sourced by
# scripts/bundle-appliers.sh, scripts/check-sync.sh, and
# tests/parity/test-applier-bundle-parity.sh so the bundled set cannot drift
# between the bundler, the drift-guard test, and the sync gate. Defines
# variables/functions only; the sourcing script owns `set -euo pipefail`.

# Shared pipeline bundled into every auto-fix skill (paths relative to scripts/).
# Only scripts the installed SKILL.md invokes by anchored path belong here, so
# "bundled" stays synonymous with "operative". render-reconciled-report.sh is
# deliberately excluded: it is the reference renderer (cited in prose, exercised
# by tests/reconciliation/test-renderer.sh from the repo) and is never invoked
# by an anchored "$SKILL_DIR"/scripts/... call, so it does not ship in the bundle.
#
# lens-budget.sh: canonical in scripts/, and BUNDLE_SHARED since Phase 2 (was
# review-gauntlet-only via bundle_extra_for in Phase 1; promoted here once
# deep-review and review-plan also invoke it for their per-lens budgets —
# "bundled == operative" holds for all three skills again).
# shellcheck disable=SC2034  # consumed by sourcing scripts
BUNDLE_SHARED=(
	reconcile-findings.sh
	audit-auto-fix-eligibility.sh
	plan-scope-detect.sh
	auto-fix-allowlist.json
	lib/auto-fix-common.sh
	lens-budget.sh
)

# Skills that receive a bundled pipeline.
# shellcheck disable=SC2034  # consumed by sourcing scripts
BUNDLE_SKILLS=(deep-review review-plan review-gauntlet)

# Skill-specific applier basename. Returns non-zero for an unknown skill.
bundle_applier_for() {
	case "$1" in
	deep-review) printf 'apply-auto-fix-code.sh\n' ;;
	review-plan) printf 'apply-auto-fix-plan.sh\n' ;;
	review-gauntlet) printf 'apply-auto-fix-code.sh\n' ;;
	*)
		printf 'bundle-map: unknown skill %s\n' "$1" >&2
		return 1
		;;
	esac
}

# Skill-specific bundle extras (one basename per line; empty for skills with
# none). These are NOT in BUNDLE_SHARED on purpose: adding them there would copy
# them into every auto-fix skill, breaking the "bundled == operative" invariant
# documented above. review-plan's Step 7 invokes write-review-marker.py (which
# imports the byte-faithful marker.py hashing authority), so both files ship
# only into review-plan's mirrors. deep-review's Step 5 invokes
# persist-deep-review-state.sh, its own Review State persistence script (a
# different schema from review-plan's persist-review-state.sh — see each
# script's header), so it ships only into deep-review's mirrors.
# lib/persist-common.sh is sourced by both persist-*.sh scripts (root-anchor,
# CLI required-value check, and guard+atomic-write helpers, plus the Phase 2
# lens-state-dir/jsonl-append helpers shared by persist-lens-result.sh and
# collect-lens-results.sh), so it ships alongside each of them — never into
# review-gauntlet's mirrors, which bundle neither persist script nor the two
# lens scripts. review-gauntlet's gate 1 (Codex) invocation is wrapped in
# `lens-budget.sh --kind codex` for its wall-clock budget (see
# lib/gate-bounded.sh, an authored — not bundled — harness-neutral helper);
# lens-budget.sh itself is canonical and now BUNDLE_SHARED (see above), so it
# is no longer listed as a review-gauntlet-only extra here.
#
# persist-lens-result.sh (writer) and collect-lens-results.sh (reader) are
# Phase 2's disk-first streamed lens results: canonical in scripts/, bundled
# only into deep-review's and review-plan's mirrors (the two skills that spawn
# lens subagents) — never review-gauntlet's, which spawns no lenses of its
# own.
bundle_extra_for() {
	case "$1" in
	review-plan)
		printf 'marker.py\n'
		printf 'write-review-marker.py\n'
		printf 'persist-review-state.sh\n'
		printf 'lib/persist-common.sh\n'
		printf 'persist-lens-result.sh\n'
		printf 'collect-lens-results.sh\n'
		;;
	deep-review)
		printf 'persist-deep-review-state.sh\n'
		printf 'lib/persist-common.sh\n'
		printf 'persist-lens-result.sh\n'
		printf 'collect-lens-results.sh\n'
		;;
	review-gauntlet)
		:
		;;
	*)
		printf 'bundle-map: unknown skill %s\n' "$1" >&2
		return 1
		;;
	esac
}
