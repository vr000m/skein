#!/usr/bin/env bash
# check-decisions.sh — validate the docs/decisions record graph.
#
# Usage: check-decisions.sh [<repo-root>] [--targets [--] <path>... | --targets-file <file>]
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
#   - Applies to is comma-separated globs of literal characters from
#     [A-Za-z0-9._/@+=:%~ -], `*` and `?`, with no `**`
#
# --targets is the write preflight for a promotion: each <path> is a
# repo-relative file the promotion is about to create or edit (the new record,
# a superseded record, a first-promotion README, the source plan). Each must be
# `docs/dev_plans/<name>` or `docs/decisions/<name>`, where <name> is one path
# component matching `[A-Za-z0-9][A-Za-z0-9._-]*[.]md` (no further `/`, no
# `.git` component, no leading `-` or `.`). Neither the path nor any ancestor
# below <repo-root> may be a symlink, and an existing path must be a regular
# file. Reported as `<path>: <message>`. The record graph is still validated
# in full, so the exit status tells the two failures apart.
#
# --targets-file takes the same paths from <file> instead of the command line,
# one per line (or NUL-delimited when the file holds a NUL), empty lines
# skipped; `-` reads stdin, normally a quoted here-document. A promotion uses
# it so no record or plan file name ever becomes a shell word. Every valid
# target starts with `docs/`, so none can end a here-document early. A
# <file> other than `-` must be a regular, non-symlink file.
#
# Exit codes: 0 valid, 1 the record graph has a problem (every target is safe),
# 2 usage error, 3 at least one --targets path is unsafe (whatever the graph).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/decisions-common.sh disable=SC1091
. "$SCRIPT_DIR/lib/decisions-common.sh"

usage() {
	echo "usage: check-decisions.sh [<repo-root>] [--targets [--] <path>... | --targets-file <file>]" >&2
	exit 2
}
root=""
if [[ $# -gt 0 && "$1" != -* ]]; then
	root="$1"
	shift
fi
targets=()
if [[ $# -gt 0 ]]; then
	case "$1" in
	--targets)
		shift
		[[ "${1:-}" == -- ]] && shift
		[[ $# -gt 0 ]] || usage
		targets=("$@")
		;;
	--targets-file)
		[[ $# -eq 2 && -n "$2" ]] || usage
		list="$(mktemp)"
		if ! dec_read_list "$2" >"$list"; then
			rm -f -- "$list"
			echo "check-decisions.sh: cannot read the targets file" >&2
			exit 2
		fi
		while IFS= read -r -d '' target; do
			targets+=("$target")
		done <"$list"
		rm -f -- "$list"
		[[ ${#targets[@]} -gt 0 ]] || usage
		;;
	*) usage ;;
	esac
fi

[[ -n "$root" ]] || root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
root="$(cd -P -- "$root" && pwd -P)" || exit 2
rc=0
# The per-record rules live in dec_validate_tree, which the selector shares.
if dec_check_directory "$root"; then
	dec_validate_tree "$root" || rc=1
	for problem in "${DEC_PROBLEMS[@]+"${DEC_PROBLEMS[@]}"}"; do
		printf '%s\n' "$problem" >&2
	done
else
	rc=1
fi
for target in "${targets[@]+"${targets[@]}"}"; do
	if reason="$(dec_target_problem "$root" "$target")"; then
		printf '%s: %s\n' "$target" "$reason" >&2
		rc=3
	fi
done
exit "$rc"
