#!/usr/bin/env bash
# check-decisions.sh — validate the docs/decisions record graph.
#
# Usage: check-decisions.sh [<repo-root>] [--targets [--] <path>...]
#
# <repo-root> defaults to the git top level (or the current directory outside a
# repository). Records are <repo-root>/docs/decisions/*.md, README.md excluded;
# their format is defined in docs/decisions/README.md. A repo without a
# docs/decisions directory passes: the folder is adopted, never required.
#
# Checks, each reported as `<record>: <message>` on stderr:
#   - every header present and non-empty: Status, Date, Applies to, Supersedes,
#     Superseded by, Source plan
#   - Status is `active` or `superseded`
#   - Supersedes and Superseded by are `none` or the filename of an existing
#     record, the link is reciprocal, and the chain has no cycles
#   - no active record is superseded
#   - Source plan resolves to a file under <repo-root>
#   - Applies to is comma-separated globs without `**`, braces or extended
#     patterns (`?( *( +( @( !(`)
#
# --targets is the write preflight for a promotion: each <path> is a
# repo-relative file the promotion is about to create or edit (the new record,
# a superseded record, a first-promotion README, the source plan). Each must
# stay inside <repo-root> with no `..` component, and neither it nor any
# ancestor below <repo-root> (`docs`, `docs/decisions`, ...) may be a symlink;
# an existing path must be a regular file. Reported as `<path>: <message>`.
#
# Exit codes: 0 valid, 1 at least one problem, 2 usage error.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/decisions-common.sh disable=SC1091
. "$SCRIPT_DIR/lib/decisions-common.sh"

usage() {
	echo "usage: check-decisions.sh [<repo-root>] [--targets [--] <path>...]" >&2
	exit 2
}
root=""
if [[ $# -gt 0 && "$1" != -* ]]; then
	root="$1"
	shift
fi
targets=()
if [[ $# -gt 0 ]]; then
	[[ "$1" == --targets ]] || usage
	shift
	[[ "${1:-}" == -- ]] && shift
	[[ $# -gt 0 ]] || usage
	targets=("$@")
fi

[[ -n "$root" ]] || root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
root="$(cd -P -- "$root" && pwd -P)" || exit 2
dec_check_directory "$root" || exit 1
# The per-record rules live in dec_validate_tree, which the selector shares.
rc=0
dec_validate_tree "$root" || rc=1
for problem in "${DEC_PROBLEMS[@]+"${DEC_PROBLEMS[@]}"}"; do
	printf '%s\n' "$problem" >&2
done
for target in "${targets[@]+"${targets[@]}"}"; do
	if reason="$(dec_target_problem "$root" "$target")"; then
		printf '%s: %s\n' "$target" "$reason" >&2
		rc=1
	fi
done
exit "$rc"
