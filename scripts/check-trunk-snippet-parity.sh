#!/usr/bin/env bash
# check-trunk-snippet-parity.sh
#
# Verify the trunk-resolution snippet is byte-identical across every
# SKILL.md that copies it. Two skills currently carry the snippet:
# update-docs (origin) and deep-review (Phase 1 copy). Add more skill
# paths to TARGETS as the snippet propagates.
#
# Exits 0 on parity, 1 on drift. Output is silent on parity, lists the
# offending skills + a unified diff against the canonical (first) copy
# on drift.
#
# The snippet is defined as the contiguous block beginning with
# `BASE=$(git symbolic-ref refs/remotes/origin/HEAD` and ending at the
# closing `fi` of the main/master fallback (5 lines including the seed).

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
TARGETS=(
	"$REPO_ROOT/plugins/skein/skills/update-docs/SKILL.md"
	"$REPO_ROOT/plugins/skein/skills/deep-review/SKILL.md"
	"$REPO_ROOT/plugins/skein-codex/skills/update-docs/SKILL.md"
	"$REPO_ROOT/plugins/skein-codex/skills/deep-review/SKILL.md"
)

extract() {
	# Print the first 5 lines starting at the BASE= line.
	awk '/BASE=\$\(git symbolic-ref refs\/remotes\/origin\/HEAD/ {found=1; n=0}
         found {print; n++; if (n==5) exit}' "$1"
}

canonical=""
canonical_path=""
drift=0

for path in "${TARGETS[@]}"; do
	if [[ ! -f "$path" ]]; then
		echo "missing: $path" >&2
		drift=1
		continue
	fi
	snippet="$(extract "$path")"
	if [[ -z "$snippet" ]]; then
		echo "snippet not found in $path" >&2
		drift=1
		continue
	fi
	if [[ -z "$canonical" ]]; then
		canonical="$snippet"
		canonical_path="$path"
		continue
	fi
	if [[ "$snippet" != "$canonical" ]]; then
		echo "drift: $path differs from $canonical_path" >&2
		diff <(echo "$canonical") <(echo "$snippet") || true
		drift=1
	fi
done

exit $drift
