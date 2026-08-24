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

MIRRORS=(plugins/skein plugins/skein-codex)

temp_root="${TMPDIR:-/tmp}"
if [[ -d /private/tmp && -w /private/tmp ]]; then
	temp_root="/private/tmp"
fi
stage_root="$(mktemp -d "${temp_root%/}/skein-bundle.XXXXXX")"
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
	# Per-skill extras: everything `bundle_extra_for <skill>` prints, staged
	# here so it fans out byte-identically into both mirrors alongside the
	# shared pipeline. EVERY bundled skill has extras today -- review-plan
	# (marker.py, write-review-marker.py, persist-review-state.sh,
	# lib/persist-common.sh, persist-lens-result.sh, collect-lens-results.sh),
	# deep-review (persist-deep-review-state.sh plus the same three lens/lib
	# files), and review-gauntlet (finding-key.sh). Do not re-enumerate that
	# list here: `scripts/lib/bundle-map.sh` is the single source of truth,
	# and a canonical script absent from BUNDLE_SHARED or from its skill's
	# `bundle_extra_for` arm never reaches any mirror no matter how often
	# this script runs.
	while IFS= read -r extra; do
		[[ -n "$extra" ]] || continue
		cp "$SRC/$extra" "$stage/$extra"
	done < <(bundle_extra_for "$skill")
	chmod +x "$stage"/*.sh "$stage"/lib/*.sh
	# write-review-marker.py is an executable entrypoint; keep its bit set.
	[[ -f "$stage/write-review-marker.py" ]] && chmod +x "$stage/write-review-marker.py"

	for mirror in "${MIRRORS[@]}"; do
		dest="$ROOT_DIR/$mirror/skills/$skill/scripts"
		mkdir -p "$dest"
		rsync -a --delete "$stage/" "$dest/"
		count=$((count + 1))
		printf 'bundled %s -> %s/skills/%s/scripts\n' "$skill" "$mirror" "$skill"
	done
done

printf 'bundle-appliers: wrote %d skill/mirror subtrees\n' "$count"
