#!/usr/bin/env bash
# decisions-scratch.sh — the selector's scratch-file guard. Sourced only by
# scripts/decisions-active.sh, which writes its path list and selection into a
# lens run directory; the record parser (decisions-common.sh) and the
# validator never write outside docs/ and do not source this file. Ships with
# the lens skills only (BUNDLE_LENS in scripts/lib/bundle-map.sh), beside the
# lens-common.sh it sources. The sourcing script owns `set -euo pipefail`.
#
# Containment is not re-implemented here: whether a path lies inside the
# repository is persist_path_is_inside_root's answer (lib/lens-common.sh), the
# rule the lens state scripts already use, asked for both the physical and the
# logical root. tests/plugin/test-decisions-active.sh asserts that boundary
# over a table of spellings. What this file adds is the walk below the root and
# the write that runs from the selector's EXIT trap.
#
# Invariant: every byte the selector writes into the repository is written by
# dec_scratch_write, through a leaf name relative to a working directory that
# the same call reached by a verified walk from the physical root. No pathname
# checked earlier is resolved again for a write, so swapping an ancestor for a
# symlink after dec_scratch_prepare cannot redirect the write: the walk that
# performs it refuses the swapped component. The selector streams its output
# into a private temp file (mktemp, outside the repository) and copies it in
# only at the end, so its stdout never points into the repository.
# persist_atomic_write is not reused: it writes to a pathname it is handed.

_DEC_SCRATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/lens-common.sh disable=SC1091
. "$_DEC_SCRATCH_DIR/lens-common.sh"
unset _DEC_SCRATCH_DIR

# _dec_scratch_walk <physical root> <relative dir> <create>: changes the
# current shell's directory to <root>/<relative dir>, one component at a time
# (run it in a subshell). Each component must not be a symlink and must be a
# directory (created first when <create> is 1 and it is missing); after each
# `cd`, the kernel's name for the working directory (`env pwd -P`, the
# external pwd, because bash's builtin keeps the spelling it was given) must
# equal the previous directory plus the component, byte for byte. A symlink, a
# case or normalisation alias of another entry (`.GIT` on a case-insensitive
# volume), or an ancestor replaced or moved between the check and the `cd` is
# therefore refused. On success sets _dec_here to that kernel name; on failure
# prints the reason and returns 1.
_dec_scratch_walk() {
	local rest="$2" create="$3" part walked="" now
	if ! cd -P -- "$1" 2>/dev/null || ! _dec_here="$(env pwd -P 2>/dev/null)"; then
		printf 'the repository root is not reachable\n'
		return 1
	fi
	while [[ -n "$rest" ]]; do
		part="${rest%%/*}"
		if [[ "$rest" == */* ]]; then
			rest="${rest#*/}"
		else
			rest=""
		fi
		walked="${walked:+$walked/}$part"
		if [[ -L "./$part" ]]; then
			printf '%s is a symlink\n' "$walked"
			return 1
		fi
		if [[ $create -eq 1 && ! -e "./$part" ]]; then
			mkdir -- "./$part" 2>/dev/null || true
		fi
		if [[ -L "./$part" || ! -d "./$part" ]] || ! cd -P -- "./$part" 2>/dev/null; then
			printf '%s is not a directory\n' "$walked"
			return 1
		fi
		if ! now="$(env pwd -P 2>/dev/null)" || [[ "$now" != "${_dec_here%/}/$part" ]]; then
			printf '%s is a link, an alias or was moved\n' "$walked"
			return 1
		fi
		_dec_here="$now"
	done
}

# dec_scratch_prepare <physical root> <logical root> <file>: the one guard for
# every file the selector writes (its path list and output). <file> is
# absolute or relative to the physical cwd. It must be inside the repository
# by persist_path_is_inside_root, and spelled under <root> or <logical root>.
# No component below the root may be `..`, `.`, empty, a symlink, or `.git`
# in any letter case (compared after a byte-wise lowercase, since a
# case-insensitive volume resolves `.GiT` to `.git`); every existing ancestor
# must be a directory reached by _dec_scratch_walk and an existing leaf a
# regular file. Missing directories are created during the walk. Nothing is
# written here: dec_scratch_write walks again and writes. On success sets
# DEC_SCRATCH_DIR (the directory relative to <root>, empty for the root),
# DEC_SCRATCH_LEAF and DEC_SCRATCH_PATH (<root>/<relative path>, for
# messages) and returns 0; otherwise sets DEC_SCRATCH_REASON and returns 1.
# shellcheck disable=SC2034  # DEC_SCRATCH_* are read by the sourcing script
dec_scratch_prepare() {
	local root="$1" logical="$2" file="$3" rest lower
	DEC_SCRATCH_PATH=""
	DEC_SCRATCH_DIR=""
	DEC_SCRATCH_LEAF=""
	DEC_SCRATCH_REASON=""
	case "$file" in
	"")
		DEC_SCRATCH_REASON="empty path"
		return 1
		;;
	/*) ;;
	*) file="$(pwd -P)/$file" ;;
	esac
	if ! persist_path_is_inside_root "$file" "$root" &&
		{ [[ -z "$logical" ]] || ! persist_path_is_inside_root "$file" "$logical"; }; then
		DEC_SCRATCH_REASON="not inside the repository"
		return 1
	fi
	if [[ "$file" == "$root" || "$file" == "$root/" || (-n "$logical" && ("$file" == "$logical" || "$file" == "$logical/")) ]]; then
		DEC_SCRATCH_REASON="the repository root is not a file"
		return 1
	elif [[ "$file" == "$root"/* ]]; then
		rest="${file#"$root"/}"
	elif [[ -n "$logical" && "$file" == "$logical"/* ]]; then
		rest="${file#"$logical"/}"
	else
		DEC_SCRATCH_REASON="spelled through a link above the repository root"
		return 1
	fi
	lower="$(printf '%s' "$rest" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
	if [[ "/$rest/" == */../* || "/$rest/" == */./* || "/$rest/" == *//* || "/$lower/" == */.git/* ]]; then
		DEC_SCRATCH_REASON="a '..', '.', empty or .git component"
		return 1
	fi
	if [[ "$rest" == */* ]]; then
		DEC_SCRATCH_DIR="${rest%/*}"
	fi
	DEC_SCRATCH_LEAF="${rest##*/}"
	if ! DEC_SCRATCH_REASON="$(
		_dec_scratch_walk "$root" "$DEC_SCRATCH_DIR" 1 || exit 1
		if [[ -L "./$DEC_SCRATCH_LEAF" ]]; then
			printf '%s is a symlink\n' "$rest"
			exit 1
		elif [[ -e "./$DEC_SCRATCH_LEAF" && ! -f "./$DEC_SCRATCH_LEAF" ]]; then
			printf '%s is not a regular file\n' "$rest"
			exit 1
		fi
	)"; then
		DEC_SCRATCH_DIR=""
		DEC_SCRATCH_LEAF=""
		return 1
	fi
	DEC_SCRATCH_PATH="$root/$rest"
}

# dec_scratch_write <physical root> <relative dir> <leaf> <source file>:
# copies <source file> (a private temp file outside the repository) to
# <root>/<relative dir>/<leaf>. In a subshell it walks to the directory with
# _dec_scratch_walk, creates a fresh temp file beside the leaf with noclobber
# (O_EXCL, so it never opens an existing entry or a link), then, immediately
# before the rename, checks that the working directory still has the kernel
# name the walk verified and that the leaf is absent or a regular,
# non-symlink file, and renames the temp file over the leaf by its relative
# name. On failure removes its temp file, sets DEC_SCRATCH_REASON and returns
# 1.
# shellcheck disable=SC2034  # DEC_SCRATCH_REASON is read by the sourcing script
dec_scratch_write() {
	DEC_SCRATCH_REASON=""
	DEC_SCRATCH_REASON="$(
		dir="$2"
		leaf="$3"
		_dec_scratch_walk "$1" "$dir" 1 || exit 1
		if ! tmp="$(mktemp -u "./.$leaf.XXXXXX" 2>/dev/null)"; then
			printf 'cannot create a temp file\n'
			exit 1
		fi
		set -C
		if ! { cat -- "$4" >"$tmp"; } 2>/dev/null; then
			rm -f -- "$tmp" 2>/dev/null
			printf 'cannot create a temp file\n'
			exit 1
		fi
		set +C
		if [[ "$(env pwd -P 2>/dev/null)" != "$_dec_here" ]]; then
			rm -f -- "$tmp"
			printf '%s was moved\n' "${dir:-the repository root}"
			exit 1
		fi
		if [[ -L "./$leaf" || (-e "./$leaf" && ! -f "./$leaf") ]]; then
			rm -f -- "$tmp"
			printf '%s is no longer a regular file\n' "$leaf"
			exit 1
		fi
		if ! mv -f -- "$tmp" "./$leaf" 2>/dev/null; then
			rm -f -- "$tmp"
			printf 'cannot rename into place\n'
			exit 1
		fi
	)" || return 1
}
