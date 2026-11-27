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
# Checks, each reported as `<record>: <message>` on stderr (a control byte in a
# quoted record value is printed as `?`):
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
# file. Reported as `<path>: <message>`. Every target is checked first, from
# path metadata alone (lstat, never file contents): when one is unsafe the
# script exits 3 before it reads any record or plan, so a candidate is never
# read through a link. Only when every target is safe is the record graph
# validated, so the exit status tells the two failures apart.
#
# --targets-file takes the same paths from <file> instead of the command line,
# one per line (or NUL-delimited when the file holds a NUL), empty lines
# skipped; `-` reads stdin, normally a quoted here-document. A promotion uses
# it so no record or plan file name ever becomes a shell word. Every valid
# target starts with `docs/`, so none can end a here-document early. A
# <file> other than `-` must be a regular, non-symlink file.
#
# Exit codes: 0 valid, 1 the record graph has a problem (every target is safe),
# 2 usage error, 3 at least one --targets path is unsafe (whatever the graph),
# 4 internal failure: a command failed unexpectedly (mktemp, a read, a
# pipeline, counting the NUL bytes of a targets file, listing the records)
# before the script reached a documented result, so neither the
# targets nor the graph are known; stderr carries the fixed reason
# `check-decisions.sh: CHECK-DECISIONS-INTERNAL`. Every documented status leaves
# through quit, so exit 1 always means every target was checked and is safe;
# any other non-zero exit (an unexpected `set -e` failure) becomes 4.
set -euo pipefail
# An inherited CDPATH makes `cd` print the directory, which would corrupt
# SCRIPT_DIR before the shared lib resets the environment; an inherited
# failglob or nullglob changes what a glob expands to (the lib clears both
# again for every script that sources it).
unset CDPATH
shopt -u failglob nullglob
# Byte semantics for the whole run, before the first read: under a UTF-8
# locale an unpatched Bash 5.2 `read -d ''` can skip the NUL after an
# incomplete multibyte sequence and lose the next path (the lib sets it too).
export LC_ALL=C

# quit <status>: the only way out with a documented status.
cd_documented=0
quit() {
	cd_documented=1
	exit "$1"
}
# The reason write is guarded: under `set -e` a failed write to a closed or
# read-only stderr would otherwise exit 1, which means "the record graph has a
# problem".
cd_internal() {
	cd_documented=1
	echo "check-decisions.sh: CHECK-DECISIONS-INTERNAL" >&2 2>/dev/null || true
	exit 4
}
# shellcheck disable=SC2329  # invoked by the EXIT trap
cd_on_exit() {
	local rc=$?
	if [[ $rc -ne 0 && $cd_documented -ne 1 ]]; then
		echo "check-decisions.sh: CHECK-DECISIONS-INTERNAL" >&2 2>/dev/null || true
		exit 4
	fi
}
trap cd_on_exit EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
# shellcheck source=scripts/lib/decisions-common.sh disable=SC1091
. "$SCRIPT_DIR/lib/decisions-common.sh"

usage() {
	echo "usage: check-decisions.sh [<repo-root>] [--targets [--] <path>... | --targets-file <file>]" >&2
	quit 2
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
		list="$(mktemp 2>/dev/null)" || cd_internal
		read_rc=0
		dec_read_list "$2" >"$list" || read_rc=$?
		if [[ $read_rc -ne 0 ]]; then
			rm -f -- "$list"
			# 2: the list could not be copied or its NUL bytes counted, so
			# its entries are unknown.
			[[ $read_rc -eq 1 ]] || cd_internal
			echo "check-decisions.sh: cannot read the targets file" >&2
			quit 2
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
root="$(cd -P -- "$root" >/dev/null && pwd -P)" || quit 2
rc=0
# Containment first: dec_target_problem inspects path metadata only, so an
# unsafe target exits 3 before any record or plan is read.
for target in "${targets[@]+"${targets[@]}"}"; do
	if reason="$(dec_target_problem "$root" "$target")"; then
		printf '%s: %s\n' "$target" "$reason" >&2
		rc=3
	fi
done
[[ $rc -eq 0 ]] || quit "$rc"
# The per-record rules live in dec_validate_tree, which the selector shares.
if dec_check_directory "$root"; then
	tree_rc=0
	dec_validate_tree "$root" || tree_rc=$?
	# 2: the records could not be listed, so the graph is unknown.
	[[ $tree_rc -ne 2 ]] || cd_internal
	[[ $tree_rc -eq 0 ]] || rc=1
	for problem in "${DEC_PROBLEMS[@]+"${DEC_PROBLEMS[@]}"}"; do
		# A message quotes record values, so a control byte (an escape sequence,
		# a CR, a newline in a file name) reaches the terminal as `?`.
		printf '%s' "$problem" | tr '\000-\037\177' '?' >&2
		printf '\n' >&2
	done
else
	rc=1
fi
quit "$rc"
