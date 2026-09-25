#!/usr/bin/env bash
# Self-test for tests/release/lib.sh: deterministic builds, committed template
# blob resolvable via `git cat-file`, and recorded peeled SHAs match the builder.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/release/lib.sh
. "$HERE/lib.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/skein-release-lib.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail=0
check() {
	if [[ "$2" == "$3" ]]; then
		echo "PASS: $1"
	else
		echo "FAIL: $1 (got '$2', want '$3')" >&2
		fail=1
	fi
}

# Every release-repo fixture case (one with a CHANGELOG.md, buildable via
# release_build_repo) is listed here explicitly — not auto-globbed, since
# fixtures/ also holds non-repo fixtures (invalid/, presence/) that would
# break release_build_repo if picked up. Add new release-repo fixture names
# to this list so they get the same determinism + blob-identity coverage
# without a second, parallel harness.
for case_name in templated untemplated none-label; do
	release_build_repo "$case_name" "$TMP/$case_name.a"
	release_build_repo "$case_name" "$TMP/$case_name.b"
	head_a="$(git -C "$TMP/$case_name.a" rev-parse HEAD)"
	head_b="$(git -C "$TMP/$case_name.b" rev-parse HEAD)"
	check "$case_name: two builds yield the same HEAD SHA" "$head_a" "$head_b"
	check "$case_name: SHA-1 object format" "${#head_a}" "40"

	if [[ -f "$HERE/fixtures/$case_name/.release-template.json" ]]; then
		blob="$(cat "$HERE/fixtures/$case_name/template-blob-sha.txt")"
		check "$case_name: marker blob SHA resolves via git cat-file" \
			"$(git -C "$TMP/$case_name.a" cat-file -t "$blob")" "blob"
		check "$case_name: template blob is addressed at HEAD" \
			"$(git -C "$TMP/$case_name.a" rev-parse "HEAD:.release-template.json")" "$blob"
	else
		check "$case_name: no template at HEAD" \
			"$(git -C "$TMP/$case_name.a" ls-tree HEAD -- .release-template.json)" ""
	fi
done

# Recorded peeled commits (static fixture) must equal what the builder emits.
recorded="$(jq -r '[.[]] | unique | join(" ")' "$HERE/fixtures/templated/peeled-commits.json")"
built="$(release_peeled_commits "$TMP/templated.a" | tr ' ' '\n' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
check "templated: peeled-commits.json matches the builder" "$recorded" "$built"

exit "$fail"
