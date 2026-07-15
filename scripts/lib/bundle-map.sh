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
# shellcheck disable=SC2034  # consumed by sourcing scripts
BUNDLE_SHARED=(
	reconcile-findings.sh
	audit-auto-fix-eligibility.sh
	plan-scope-detect.sh
	auto-fix-allowlist.json
	lib/auto-fix-common.sh
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
# script's header), so it ships only into deep-review's mirrors. Returns 0
# with no output for review-gauntlet.
bundle_extra_for() {
	case "$1" in
	review-plan)
		printf 'marker.py\n'
		printf 'write-review-marker.py\n'
		printf 'persist-review-state.sh\n'
		;;
	deep-review)
		printf 'persist-deep-review-state.sh\n'
		;;
	review-gauntlet) ;;
	*)
		printf 'bundle-map: unknown skill %s\n' "$1" >&2
		return 1
		;;
	esac
}
