#!/usr/bin/env bash
# decisions-active.sh — print the active decision records that apply to a set
# of paths, escaped for embedding in a lens prompt.
#
# Usage: decisions-active.sh [--] <path>...
#
# Each <path> is a literal, repo-relative path (braces already expanded by the
# caller). A path is data, never a pattern: spaces and shell metacharacters are
# matched as written. Records are <repo-root>/docs/decisions/*.md (README.md
# excluded); <repo-root> is the git top level, or the current directory outside
# a repository. A record is selected when its Status is `active` and any of its
# `Applies to` globs matches any <path>, with bash `[[ $path == $glob ]]`
# semantics (`*` crosses `/`). Superseded records are never printed.
#
# Output, in path-sorted record order, one block per selected record:
#   ### Record: docs/decisions/<name>
#   <title and header lines>
#   ## Decision ... and ## Why ... (those two sections only)
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
#   2  usage error (no path, or an option)
#   3  a record is malformed: check-decisions.sh would reject it (both call
#      dec_validate_tree). stderr names each problem as the record's file name
#      and a reason code (file-type, header, status, supersession, source-plan,
#      applies-to), never a value from the record. Only records the
#      validator accepts are selected, and those matches are still printed, so
#      the caller reports degraded coverage rather than "no applicable
#      decisions".
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/decisions-common.sh disable=SC1091
. "$SCRIPT_DIR/lib/decisions-common.sh"

# A glob from a record is matched case-sensitively, whatever the caller set.
# Extended patterns are rejected by dec_glob_problem instead: `[[ == ]]` honours
# them whatever `extglob` says.
shopt -u nocasematch nocaseglob

MAX_RECORDS=8
MAX_BYTES=24576

if [[ "${1:-}" == -- ]]; then
	shift
elif [[ "${1:-}" == -* ]]; then
	echo "usage: decisions-active.sh [--] <path>..." >&2
	exit 2
fi
if [[ $# -eq 0 ]]; then
	echo "usage: decisions-active.sh [--] <path>..." >&2
	exit 2
fi
paths=("$@")

root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
root="$(cd -P -- "$root" && pwd -P)"
dec_check_directory "$root" || exit 3

# applies <glob-list>: succeeds when any glob matches any path.
applies() {
	local glob p
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

# block <record path>: the header, then the Decision and Why sections.
block() {
	local line keep=1
	while IFS= read -r line || [[ -n "$line" ]]; do
		if [[ "$line" == "## "* ]]; then
			case "${line%"${line##*[![:space:]]}"}" in
			"## Decision" | "## Why") keep=1 ;;
			*) keep=0 ;;
			esac
		fi
		if [[ $keep -eq 1 ]]; then
			printf '%s\n' "$line"
		fi
	done <"$1"
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
