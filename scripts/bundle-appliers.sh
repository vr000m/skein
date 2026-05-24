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

# shellcheck source=scripts/lib/bundle-map.sh
. "$ROOT_DIR/scripts/lib/bundle-map.sh"

MIRRORS=(.claude .codex)

stage_root="$(mktemp -d)"
trap 'rm -rf "$stage_root"' EXIT

count=0
for skill in "${BUNDLE_SKILLS[@]}"; do
	applier="$(bundle_applier_for "$skill")"

	# Build a canonical staging layout once per skill, then rsync --delete it
	# into each mirror so stale files cannot linger (matches sync-skills.sh).
	stage="$stage_root/$skill/scripts"
	mkdir -p "$stage/lib"
	for f in "${BUNDLE_SHARED[@]}"; do
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
