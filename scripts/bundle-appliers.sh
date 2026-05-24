#!/usr/bin/env bash
# bundle-appliers.sh — copy the auto-fix applier pipeline into each skill's
# scripts/ subtree so `--auto-fix=trivial` resolves its pipeline wherever the
# skill is installed, not only when cwd is the skills.md repo.
#
# Canonical source is scripts/. Bundled copies are byte-identical generated
# artifacts, enforced by tests/parity/test-applier-bundle-parity.sh. The
# bundled layout preserves scripts/ + scripts/lib/ so the appliers'
# BASH_SOURCE-relative resolution (and the lib's `../..` walk to the allowlist)
# finds the bundled siblings. Idempotent: re-running against an in-sync tree
# produces no diff.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT_DIR/scripts"

# Shared pipeline bundled into every auto-fix skill.
SHARED=(
	reconcile-findings.sh
	audit-auto-fix-eligibility.sh
	render-reconciled-report.sh
	plan-scope-detect.sh
	auto-fix-allowlist.json
	lib/auto-fix-common.sh
)

MIRRORS=(.claude .codex)
SKILLS=(deep-review review-plan)

# Skill-specific applier. Keep in sync with tests/parity/test-applier-bundle-parity.sh.
applier_for() {
	case "$1" in
	deep-review) printf 'apply-auto-fix-code.sh\n' ;;
	review-plan) printf 'apply-auto-fix-plan.sh\n' ;;
	*)
		printf 'bundle-appliers: unknown skill %s\n' "$1" >&2
		return 1
		;;
	esac
}

stage_root="$(mktemp -d)"
trap 'rm -rf "$stage_root"' EXIT

count=0
for skill in "${SKILLS[@]}"; do
	applier="$(applier_for "$skill")"

	# Build a canonical staging layout once per skill, then rsync --delete it
	# into each mirror so stale files cannot linger (matches sync-skills.sh).
	stage="$stage_root/$skill/scripts"
	mkdir -p "$stage/lib"
	for f in "${SHARED[@]}"; do
		cp "$SRC/$f" "$stage/$f"
	done
	cp "$SRC/$applier" "$stage/$applier"
	chmod +x "$stage"/*.sh "$stage"/lib/*.sh

	for mirror in "${MIRRORS[@]}"; do
		dest="$ROOT_DIR/$mirror/skills/$skill/scripts"
		mkdir -p "$dest"
		rsync -a --delete "$stage/" "$dest/"
		count=$((count + 1))
		printf 'bundled %s -> %s/skills/%s/scripts\n' "$skill" "$mirror" "$skill"
	done
done

printf 'bundle-appliers: wrote %d skill/mirror subtrees\n' "$count"
