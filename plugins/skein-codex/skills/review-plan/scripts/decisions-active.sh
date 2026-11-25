#!/usr/bin/env bash
# decisions-active.sh — print the active decision records that apply to a set
# of paths, escaped for embedding in a lens prompt.
#
# Usage:
#   decisions-active.sh [--output <file>] [--paths-file <file>] --paths-stdin
#   decisions-active.sh [--output <file>] [--paths-file <file>] \
#       --base <rev> --head <rev> [--uncommitted]
#   decisions-active.sh [--output <file>] [--paths-file <file>] [--] <path>...
#
# Paths arrive one of three ways, and the skills never put one on a command
# line:
#   --paths-stdin  stdin lines `p <path>`, normally a quoted here-document. The
#                  prefix means no path can end the here-document early; a
#                  line without it is refused (exit 4). Blank lines are
#                  skipped.
#   --base/--head  the script runs `git diff --no-ext-diff --no-renames
#                  --name-only -z <base>...<head>` itself (both rename paths;
#                  the merge base, as `gh pr diff`), plus the staged and
#                  unstaged diffs with --uncommitted. No changed path is an
#                  empty, successful selection. When <head> is not the
#                  checked-out HEAD, stderr carries `decisions-active.sh:
#                  notice: decision records read from the checked-out tree,
#                  not the reviewed head`: records are always read from the
#                  working tree.
#   <path>...      literal arguments, for direct use.
# Each path is a literal, repo-relative path (braces already expanded by the
# caller). A path is data, never a pattern: spaces and shell metacharacters are
# matched as written.
#
# --paths-file records the path list the selection used (NUL-delimited for
# --base/--head, one per line otherwise) and --output receives the selection
# instead of stdout. The script is the only writer of both: each must lie
# inside the repository, with no symlink, `..` or `.git` component below the
# repo root, no non-directory ancestor and no non-regular leaf
# (dec_scratch_prepare). Missing directories are created; the file is written
# to a temp file and renamed into place. --output is written whatever the exit
# status, once its path is accepted.
#
# Records are <repo-root>/docs/decisions/*.md (README.md excluded); <repo-root>
# is the git top level, or the current directory outside a repository. A
# record is selected when its Status is `active` and any of its `Applies to`
# globs matches any path, with bash `[[ $path == $glob ]]` semantics (`*`
# crosses `/`). Matching runs under LC_ALL=C, so a range such as `[a-c]` and
# `?` match bytes, case-sensitively, in every locale and bash version.
# Superseded records are never printed.
#
# Output, in path-sorted record order, one block per selected record:
#   ### Record: docs/decisions/<name>
#   <title and header lines>
#   ## Decision ... and ## Why ... (those two sections only; a `## ` line
#   inside a ``` or ~~~ fence is text, not a section boundary)
# Record text is escaped: the opening of any case-insensitive closing-tag
# lookalike, `<`, `/` and the tag name with any whitespace between them and a
# non-word character or end of text after, becomes `<\/untrusted-content`; the
# rest of the text is kept. Escaping the whole output again changes nothing, so
# the orchestrator can wrap it in `<untrusted-content>` without a record
# closing it early.
#
# Cap: at most 8 records and 24 KiB of record text. When more records match,
# the last line is `DECISIONS-TRUNCATED: N of M records shown`.
#
# Exit codes:
#   0  success: no match, no docs/decisions directory, or a truncated block
#   2  usage error (an unknown option, or no path)
#   3  a record is malformed (check-decisions.sh would reject it: both call
#      dec_validate_tree), or docs/decisions is not a readable local
#      directory. stderr names each problem as the record's file name and a
#      reason code (file-type, header, status, supersession, source-plan,
#      applies-to), never a value from the record. Only records the validator
#      accepts are selected, and those matches are still printed, so the
#      caller reports degraded coverage rather than "no applicable decisions".
#   4  the path list is unavailable: a git diff failed, or a --paths-stdin line
#      lacks its `p ` prefix
#   5  --output or --paths-file was refused or could not be written
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/decisions-common.sh disable=SC1091
. "$SCRIPT_DIR/lib/decisions-common.sh"

# A glob from a record is matched case-sensitively: the shared lib clears
# nocasematch. Extended patterns are rejected by dec_glob_problem instead:
# `[[ == ]]` honours them whatever `extglob` says.

MAX_RECORDS=8
MAX_BYTES=24576
NOTICE="decisions-active.sh: notice: decision records read from the checked-out tree, not the reviewed head"

usage() {
	echo "usage: decisions-active.sh [--output <file>] [--paths-file <file>] (--paths-stdin | --base <rev> --head <rev> [--uncommitted] | [--] <path>...)" >&2
	exit 2
}

output=""
paths_file=""
base=""
head=""
from_stdin=0
uncommitted=0
while [[ $# -gt 0 ]]; do
	case "$1" in
	--output | --paths-file | --base | --head)
		[[ $# -ge 2 && -n "$2" ]] || usage
		case "$1" in
		--output) output="$2" ;;
		--paths-file) paths_file="$2" ;;
		--base) base="$2" ;;
		--head) head="$2" ;;
		esac
		shift 2
		;;
	--paths-stdin)
		from_stdin=1
		shift
		;;
	--uncommitted)
		uncommitted=1
		shift
		;;
	--)
		shift
		break
		;;
	-*) usage ;;
	*) break ;;
	esac
done
mode=argv
if [[ -n "$base" || -n "$head" ]]; then
	mode=range
	[[ -n "$base" && -n "$head" && $from_stdin -eq 0 && $# -eq 0 ]] || usage
	# A revision starting with `-` would reach git as an option.
	[[ "$base" != -* && "$head" != -* ]] || usage
elif [[ $from_stdin -eq 1 ]]; then
	mode=stdin
	[[ $# -eq 0 ]] || usage
fi
[[ $uncommitted -eq 0 || "$mode" == range ]] || usage

logical_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
root="$(cd -P -- "$logical_root" && pwd -P)"

# Temp files this run created; removed on any exit.
list_tmp=""
out_tmp=""
out_final=""
on_exit() {
	local rc=$?
	[[ -z "$list_tmp" ]] || rm -f -- "$list_tmp"
	[[ -n "$out_tmp" ]] || exit "$rc"
	exec 1>&3 3>&-
	if dec_scratch_commit "$out_tmp" "$out_final"; then
		exit "$rc"
	fi
	rm -f -- "$out_tmp"
	echo "decisions-active.sh: --output not written: $DEC_SCRATCH_REASON" >&2
	exit 5
}
trap on_exit EXIT

# From here on every exit, success or failure, writes --output.
if [[ -n "$output" ]]; then
	if ! dec_scratch_prepare "$root" "$logical_root" "$output"; then
		echo "decisions-active.sh: --output refused: $DEC_SCRATCH_REASON" >&2
		exit 5
	fi
	out_final="$DEC_SCRATCH_PATH"
	out_tmp="$(dec_scratch_tmp "$out_final")" || {
		out_tmp=""
		echo "decisions-active.sh: --output refused: cannot create a temp file" >&2
		exit 5
	}
	exec 3>&1 1>"$out_tmp"
fi

paths_final=""
if [[ -n "$paths_file" ]]; then
	if ! dec_scratch_prepare "$root" "$logical_root" "$paths_file"; then
		echo "decisions-active.sh: --paths-file refused: $DEC_SCRATCH_REASON" >&2
		exit 5
	fi
	paths_final="$DEC_SCRATCH_PATH"
	list_tmp="$(dec_scratch_tmp "$paths_final")" || {
		list_tmp=""
		echo "decisions-active.sh: --paths-file refused: cannot create a temp file" >&2
		exit 5
	}
elif [[ "$mode" != argv ]]; then
	list_tmp="$(mktemp)"
fi

paths=()
case "$mode" in
argv)
	paths=("$@")
	if [[ -n "$list_tmp" && ${#paths[@]} -gt 0 ]]; then
		printf '%s\n' "${paths[@]}" >"$list_tmp"
	fi
	;;
stdin)
	entries="$(mktemp)"
	if ! dec_read_list - >"$entries"; then
		rm -f -- "$entries"
		echo "decisions-active.sh: cannot read the path list" >&2
		exit 4
	fi
	unprefixed=0
	while IFS= read -r -d '' entry; do
		if [[ "$entry" != "p "* ]]; then
			unprefixed=1
		elif [[ -n "${entry#p }" ]]; then
			paths+=("${entry#p }")
		fi
	done <"$entries"
	rm -f -- "$entries"
	if [[ $unprefixed -eq 1 ]]; then
		echo "decisions-active.sh: a --paths-stdin line lacks its 'p ' prefix" >&2
		exit 4
	fi
	if [[ ${#paths[@]} -gt 0 ]]; then
		printf '%s\n' "${paths[@]}" >"$list_tmp"
	fi
	;;
range)
	if ! {
		git -C "$root" diff --no-ext-diff --no-renames --name-only -z "$base...$head" -- &&
			if [[ $uncommitted -eq 1 ]]; then
				git -C "$root" diff --no-ext-diff --no-renames --name-only -z --cached -- &&
					git -C "$root" diff --no-ext-diff --no-renames --name-only -z --
			fi
	} >"$list_tmp"; then
		echo "decisions-active.sh: git diff failed for the reviewed range" >&2
		exit 4
	fi
	while IFS= read -r -d '' entry; do
		paths+=("$entry")
	done <"$list_tmp"
	reviewed="$(git -C "$root" rev-parse --verify --quiet "$head^{commit}" 2>/dev/null || true)"
	current="$(git -C "$root" rev-parse --verify --quiet HEAD 2>/dev/null || true)"
	[[ "$reviewed" == "$current" ]] || echo "$NOTICE" >&2
	;;
esac
if [[ -n "$paths_final" ]]; then
	if ! dec_scratch_commit "$list_tmp" "$paths_final"; then
		echo "decisions-active.sh: --paths-file not written: $DEC_SCRATCH_REASON" >&2
		exit 5
	fi
	list_tmp=""
fi
if [[ ${#paths[@]} -eq 0 ]]; then
	[[ "$mode" == range ]] && exit 0
	usage
fi

dec_check_directory "$root" || exit 3

# applies <glob-list>: succeeds when any glob matches any path. LC_ALL=C makes
# a range or `?` match bytes: bash 3.2 otherwise collates by locale, so
# `src/[a-c]*.py` would match `src/Bar.py` under en_US.UTF-8.
applies() {
	local glob p
	local LC_ALL=C
	while IFS= read -r glob; do
		for p in "${paths[@]}"; do
			# shellcheck disable=SC2053  # the glob is the pattern on purpose
			[[ "$p" == $glob ]] && return 0
		done
	done < <(dec_split_globs "$1")
	return 1
}

# Whitespace inside a lookalike: ASCII whitespace plus the UTF-8 encoding of
# every other character a Unicode `\s` matches (U+001C-001F, U+0085, U+00A0,
# U+1680, U+2000-200A, U+2028, U+2029, U+202F, U+205F, U+3000, U+FEFF). sed runs
# under LC_ALL=C and matches these bytes, so the result does not depend on the
# caller's locale. The name's `s` also matches U+017F, which folds to `s`.
WS="$(printf '([[:space:]\034\035\036\037]|\302[\205\240]|\341\232\200|\342\200[\200\201\202\203\204\205\206\207\210\211\212\250\251\257]|\342\201\237|\343\200\200|\357\273\277)')"
S="$(printf '([sS]|\305\277)')"
NAME="[uU][nN][tT][rR][uU]${S}[tT][eE][dD]-[cC][oO][nN][tT][eE][nN][tT]"

# escape: replace the opening of every closing-tag lookalike in stdin, including
# one split across lines, and nothing else. A match consumes its boundary
# character, so the loop catches a lookalike that starts at that character. A
# replacement cannot start a new match (`<\/` is not `<`, whitespace, `/`).
escape() {
	LC_ALL=C sed -E -e ':a' -e '$!{' -e 'N' -e 'ba' -e '}' \
		-e ':b' -e "s#<${WS}*/${WS}*${NAME}([^A-Za-z0-9_]|\$)#<\\\\/untrusted-content\\4#g" -e 'tb'
}

# The fence rule is scripts/marker.py's: a line starting (after whitespace)
# with ``` or ~~~ opens or closes a fence.
FENCE_RE='^[[:space:]]*(```|~~~)'

# block <record path>: the header, then the Decision and Why sections. A
# `## ` line inside a fence belongs to the section around it.
block() {
	local line keep=1 fenced=0
	while IFS= read -r line || [[ -n "$line" ]]; do
		if [[ "$line" =~ $FENCE_RE ]]; then
			fenced=$((1 - fenced))
		elif [[ $fenced -eq 0 && "$line" == "## "* ]]; then
			case "${line%"${line##*[![:space:]]}"}" in
			"## Decision" | "## Why") keep=1 ;;
			*) keep=0 ;;
			esac
		fi
		if [[ $keep -eq 1 ]]; then
			printf '%s\n' "$line"
		fi
	done 2>/dev/null <"$1"
}

malformed=0
dec_validate_tree "$root" || malformed=1
# stderr reaches the skills' degraded-coverage line, so it names the record
# and a fixed reason code only, never a record value.
for ((k = 0; k < ${#DEC_CODES[@]}; k++)); do
	name="${DEC_RECORDS[${DEC_PROBLEM_INDEX[$k]}]##*/}"
	[[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || name="unsafe-file-name"
	echo "decisions-active.sh: malformed record $name: ${DEC_CODES[$k]}" >&2
done

matched=()
for ((index = 0; index < ${#DEC_RECORDS[@]}; index++)); do
	path="${DEC_RECORDS[$index]}"
	[[ "${DEC_VALID[$index]}" == 1 ]] || continue
	[[ "$(dec_header "$path" Status || true)" == active ]] || continue
	if applies "$(dec_header "$path" "Applies to" || true)"; then
		matched+=("$path")
	fi
done

shown=0
used=0
for path in "${matched[@]+"${matched[@]}"}"; do
	text="$(
		printf '### Record: docs/decisions/%s\n' "${path##*/}"
		block "$path"
	)"
	text="$(printf '%s\n' "$text" | escape)"
	size="$(printf '%s\n' "$text" | LC_ALL=C wc -c | tr -d '[:space:]')"
	if [[ $shown -ge $MAX_RECORDS || $((used + size)) -gt $MAX_BYTES ]]; then
		break
	fi
	printf '%s\n' "$text"
	shown=$((shown + 1))
	used=$((used + size))
done

total=${#matched[@]}
if [[ $shown -lt $total ]]; then
	printf 'DECISIONS-TRUNCATED: %d of %d records shown\n' "$shown" "$total"
fi

[[ $malformed -eq 0 ]] || exit 3
