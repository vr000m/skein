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
# over a table of spellings. What this file adds is the walk below the root
# (no `..`, `.`, empty, `.git` or symlink component, directories created one by
# one) and the temp-then-rename commit that runs from the selector's EXIT trap.
# persist_atomic_write is not reused: it writes a value it is handed, while the
# selector streams its whole stdout into the temp file and commits it on every
# exit status, after the run.

_DEC_SCRATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/lens-common.sh disable=SC1091
. "$_DEC_SCRATCH_DIR/lens-common.sh"
unset _DEC_SCRATCH_DIR

# dec_scratch_prepare <physical root> <logical root> <file>: the one guard for
# every file the selector writes (its path list and output). <file> is
# absolute or relative to the physical cwd. It must be inside the repository
# by persist_path_is_inside_root, and spelled under <root> or <logical root>.
# No component below the root may be `..`, `.`, empty, `.git` or a symlink;
# every existing ancestor must be a directory and an existing leaf a regular
# file. Missing directories are created one at a time, each re-checked. On
# success sets DEC_SCRATCH_PATH (physical) and returns 0; otherwise sets
# DEC_SCRATCH_REASON and returns 1.
# shellcheck disable=SC2034  # DEC_SCRATCH_* are read by the sourcing script
dec_scratch_prepare() {
	local root="$1" logical="$2" file="$3" rest part path
	DEC_SCRATCH_PATH=""
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
	if [[ "/$rest/" == */../* || "/$rest/" == */./* || "/$rest/" == *//* || "/$rest/" == */.git/* ]]; then
		DEC_SCRATCH_REASON="a '..', '.', empty or .git component"
		return 1
	fi
	path="$root"
	while [[ -n "$rest" ]]; do
		part="${rest%%/*}"
		if [[ "$rest" == */* ]]; then
			rest="${rest#*/}"
		else
			rest=""
		fi
		path="$path/$part"
		if [[ -L "$path" ]]; then
			DEC_SCRATCH_REASON="${path#"$root"/} is a symlink"
			return 1
		fi
		if [[ -n "$rest" ]]; then
			if [[ ! -e "$path" ]]; then
				mkdir -- "$path" 2>/dev/null || true
			fi
			if [[ -L "$path" || ! -d "$path" ]]; then
				DEC_SCRATCH_REASON="${path#"$root"/} is not a directory"
				return 1
			fi
		elif [[ -e "$path" && ! -f "$path" ]]; then
			DEC_SCRATCH_REASON="${path#"$root"/} is not a regular file"
			return 1
		fi
	done
	DEC_SCRATCH_PATH="$path"
}

# dec_scratch_tmp <prepared path>: prints a fresh temp file beside it.
dec_scratch_tmp() {
	mktemp "${1%/*}/.${1##*/}.XXXXXX"
}

# dec_scratch_commit <temp file> <prepared path>: renames the temp file over
# the path after re-checking the leaf, so the write never follows a link.
# shellcheck disable=SC2034  # DEC_SCRATCH_REASON is read by the sourcing script
dec_scratch_commit() {
	if [[ -L "$2" || (-e "$2" && ! -f "$2") ]]; then
		DEC_SCRATCH_REASON="${2##*/} is no longer a regular file"
		return 1
	fi
	mv -f -- "$1" "$2"
}
