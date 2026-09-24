#!/usr/bin/env bash
# A2 -> A2.5 field contract (Phase 3 of the release-skill restructure, grilled
# decisions 3/9/12). Every field name listed under "### Script-stdout fields" in
# references/audit-inference.md must appear in the A2 script's projected JSON
# stdout AND in its goldens; a rename on either side fails. The fetch-side
# subsection is script INPUT, never output, and is out of scope.
#
# Overrides (mutation evidence): RELEASE_LIB_DIR points at a scratch lib/ copy,
# RELEASE_A25_REF at a scratch audit-inference.md.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
LIB="${RELEASE_LIB_DIR:-$ROOT/plugins/skein/skills/release/lib}"
REF="${RELEASE_A25_REF:-$ROOT/plugins/skein/skills/release/references/audit-inference.md}"
FIX="$HERE/fixtures"
GOLDEN="$HERE/golden"
# shellcheck source=tests/release/lib.sh disable=SC1091
. "$HERE/lib.sh"

fail=0
bad() {
	echo "FAIL: $1" >&2
	fail=1
}

real() { python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$(command -v "$1")"; }
JQ_REAL="$(real jq)"
GIT_REAL="$(real git)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/skein-a2-a25.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# Documented names: backticked leading token of each bullet in the subsection.
documented="$(awk '
	/^### Script-stdout fields/ {on = 1; next}
	/^##/ {on = 0}
	on && /^- `/ {
		line = $0
		sub(/^- `/, "", line)
		sub(/`.*/, "", line)
		print line
	}
' "$REF")"
if [[ -z "$documented" ]]; then
	bad "no fields parsed from the Script-stdout fields subsection of $REF"
fi

top=()
rowkeys=()
while IFS= read -r name; do
	[[ -z "$name" ]] && continue
	case "$name" in
	'rows[].'*) rowkeys+=("${name#rows\[\].}") ;;
	*) top+=("$name") ;;
	esac
done <<<"$documented"

web="$(cat "$FIX/untemplated/web-base-url.txt")"
check_output() { # label json
	local label="$1" json="$2" k
	for k in "${top[@]}"; do
		jq -e --arg k "$k" 'has($k)' <<<"$json" >/dev/null 2>&1 || bad "$label: documented field '$k' missing from stdout"
	done
	for k in "${rowkeys[@]}"; do
		jq -e --arg k "$k" '(.rows | length > 0) and all(.rows[]; has($k))' <<<"$json" >/dev/null 2>&1 || bad "$label: documented row field '$k' missing from rows[]"
	done
}

for c in templated untemplated; do
	release_build_repo "$c" "$TMP/repo-$c" || bad "fixture build $c"
	head_sha="$("$GIT_REAL" -C "$TMP/repo-$c" rev-parse HEAD)"
	out="$(RELEASE_JQ="$JQ_REAL" RELEASE_GIT="$GIT_REAL" "$LIB/resolve-template-marker.sh" --site a2-classify \
		--repo "$TMP/repo-$c" --release-list "$FIX/$c/release-list.json" --bodies-dir "$FIX/$c/bodies" \
		--peeled "$FIX/$c/peeled-commits.json" --tags "$FIX/$c/tags.json" --changelog "$FIX/$c/CHANGELOG.md" \
		--web-base-url "$web" --head-sha "$head_sha" 2>/dev/null)"
	check_output "live a2-classify ($c)" "$out"
done
check_output "golden a2-marker-absent" "$(cat "$GOLDEN/a2-marker-absent.json")"
check_output "golden a2-templated" "$(cat "$GOLDEN/a2-templated.json")"

# Mutation evidence (each side of the contract, automated): rename a field in a
# scratch copy of the script, then in a scratch copy of the reference; the
# contract check must fail both times. Skipped inside its own re-run.
if [[ -z "${RELEASE_A25_SELFTEST:-}" ]]; then
	cp -R "$LIB" "$TMP/lib-mut"
	sed -i.bak 's/{version: \$v, status: \$s,/{version: $v, state: $s,/' "$TMP/lib-mut/resolve-template-marker.sh"
	if cmp -s "$LIB/resolve-template-marker.sh" "$TMP/lib-mut/resolve-template-marker.sh"; then
		bad "mutation self-test: script rename was a no-op"
	elif RELEASE_A25_SELFTEST=1 RELEASE_LIB_DIR="$TMP/lib-mut" bash "${BASH_SOURCE[0]}" >/dev/null 2>&1; then
		bad "mutation self-test: renaming rows[].status in the script did not fail the contract"
	fi
	# shellcheck disable=SC2016 # literal backticks in a sed pattern, not an expansion
	sed 's/^- `rows\[\]\.status`/- `rows[].state`/' "$REF" >"$TMP/ref-mut.md"
	if cmp -s "$REF" "$TMP/ref-mut.md"; then
		bad "mutation self-test: reference rename was a no-op"
	elif RELEASE_A25_SELFTEST=1 RELEASE_A25_REF="$TMP/ref-mut.md" bash "${BASH_SOURCE[0]}" >/dev/null 2>&1; then
		bad "mutation self-test: renaming rows[].status in the reference did not fail the contract"
	fi
fi

if [[ "$fail" -eq 0 ]]; then
	echo "PASS: A2 -> A2.5 field contract (${#top[@]} top-level, ${#rowkeys[@]} per-row fields)"
fi
exit "$fail"
