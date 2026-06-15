#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -f "$ROOT_DIR/.env" ]]; then
	# shellcheck disable=SC1091
	source "$ROOT_DIR/.env"
fi

# shellcheck source=scripts/lib/bundle-map.sh
. "$ROOT_DIR/scripts/lib/bundle-map.sh"

# Canonical<->bundle axis: every bundled auto-fix script (in the plugin-side
# skill mirrors under plugins/skein{,-codex}/skills/<skill>/scripts) must be
# byte-identical to canonical scripts/. Keep this set in sync with
# scripts/bundle-appliers.sh.
BUNDLE_DIFF=0
CANONICAL_SCRIPTS_DIR="$ROOT_DIR/scripts"

check_bundle_dir() {
	local tdir="$1"
	shift
	local f canon found rel declared d
	for f in "$@"; do
		canon="$CANONICAL_SCRIPTS_DIR/$f"
		if [[ ! -f "$tdir/$f" ]]; then
			echo "drift: missing bundled $tdir/$f"
			BUNDLE_DIFF=1
		elif ! cmp -s "$canon" "$tdir/$f"; then
			echo "drift: bundled $tdir/$f differs from canonical scripts/$f"
			BUNDLE_DIFF=1
		fi
	done
	# Stale-leftover guard: no files beyond the declared set.
	while IFS= read -r found; do
		rel="${found#"$tdir"/}"
		declared=0
		for d in "$@"; do [[ "$rel" == "$d" ]] && declared=1 && break; done
		if [[ "$declared" -eq 0 ]]; then
			echo "drift: unexpected bundled $tdir/$rel"
			BUNDLE_DIFF=1
		fi
	done < <(find "$tdir" -type f 2>/dev/null)
}

for skill in "${BUNDLE_SKILLS[@]}"; do
	bundle_files=("${BUNDLE_SHARED[@]}" "$(bundle_applier_for "$skill")")
	# Per-skill extras (review-plan's marker.py + write-review-marker.py) are
	# bundled too; include them so the byte-identity check covers them and the
	# stale-leftover guard does not flag them as unexpected.
	while IFS= read -r extra; do
		[[ -n "$extra" ]] && bundle_files+=("$extra")
	done < <(bundle_extra_for "$skill")
	check_bundle_dir "$ROOT_DIR/plugins/skein/skills/$skill/scripts" "${bundle_files[@]}"
	check_bundle_dir "$ROOT_DIR/plugins/skein-codex/skills/$skill/scripts" "${bundle_files[@]}"
done

if [[ "$BUNDLE_DIFF" -eq 1 ]]; then
	echo "check-sync failed"
	exit 1
fi

echo "check-sync passed"
