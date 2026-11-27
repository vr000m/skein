#!/usr/bin/env bash
# decisions-active.sh — print the active decision records that apply to a set
# of paths, or every active record, escaped for embedding in a lens prompt.
#
# Usage:
#   decisions-active.sh [--temp-output] --all-active
#   decisions-active.sh [--temp-output] --paths-stdin
#   decisions-active.sh [--temp-output] [--] <path>...
#
# --all-active selects every valid active record and reads no paths: it
# takes no stdin and no path argument, and combining it with --paths-stdin or
# a path is a usage error (exit 2). deep-review uses it: its architecture lens
# judges applicability itself, by matching each record's `Applies to` against
# the files of the diff it reviews, so no path list is derived from a patch.
# Validation, the cap, escaping and every exit status but 4 work as below.
#
# Otherwise paths arrive one of two ways, and the skills never put one on a
# command line:
#   --paths-stdin  stdin lines `p <path>`, normally a quoted here-document. The
#                  prefix means no path can end the here-document early; a
#                  line without it is refused (exit 4). Blank lines are
#                  skipped. review-plan passes exactly the paths the plan
#                  names, so the selector never derives a range of its own.
#   <path>...      literal arguments, for direct use.
# The selector takes no revision range: the range options of earlier
# revisions (--base, --head, --range-stdin, --two-dot, --uncommitted) are
# usage errors. Records are always read from the working tree; a caller
# whose reviewed snapshot is not the checked-out tree says so itself.
# Each path is a literal, repo-relative path (braces already expanded by the
# caller). A path is data, never a pattern: spaces and shell metacharacters are
# matched as written. Every path, from either source, is first
# normalised by normalise_path: a leading `./` (repeated or not), `.`
# components and repeated `/` are dropped (`./src//a/./b` is `src/a/b`; a
# trailing `/` is kept as one `/`), and globs are matched against that
# spelling only, so spellings of one repo path select the same records. A
# git-derived path is already normal and passes unchanged. A path that is not
# a plain repo-relative path (empty, absolute, holding a `..` component, or
# nothing left after normalising, such as `.`) is never skipped: the selector
# prints no selection, stderr carries the fixed reason
# `decisions-active.sh: DECISIONS-PATH-UNNORMALISABLE` (never the path) and
# the exit status is 4.
#
# The selection goes to stdout. With --temp-output it goes instead to a fresh
# private file the selector creates itself (mktemp under ${TMPDIR:-/tmp},
# mode 0600; never a caller-supplied path), and stdout carries one status
# line, `selector-output=<that file>` after exit 0 or 3, or `selector-output=`
# (the file removed) after any other exit. The selector writes nothing into
# the repository.
#
# Records are <repo-root>/docs/decisions/*.md (README.md excluded); <repo-root>
# is the git top level, or the current directory outside a repository. A
# record is selected when its Status is `active` and, unless --all-active is
# given, any of its `Applies to` globs matches any path. A glob is literal characters, `*` (any characters,
# `/` included) and `?` (one byte), written in the paths' normal form; the
# validator rejects anything else (dec_glob_problem). glob_match equals bash `[[ $path == $glob ]]` on that
# dialect under LC_ALL=C, without backtracking.
# Superseded records are never printed.
#
# Output, in path-sorted record order, one block per selected record:
#   ### Record: docs/decisions/<name>
#   <title and header lines>
#   ## Decision ... and ## Why ... (those two sections only). A section ends
#   at the next level-one or level-two heading as CommonMark reads one: ATX
#   indented up to three spaces, or setext (a paragraph underlined with `=`
#   or `-`); a heading inside a fenced code block is text. Fences follow
#   CommonMark: an opener is up to three spaces, then at least three backticks
#   (with no backtick in the rest of the line) or at least three tildes; only
#   a line of the same character, at least as long, indented up to three
#   spaces and followed by nothing but spaces or tabs, closes it. An unclosed
#   fence runs to the end of the record.
# Record text is escaped: the opening of any case-insensitive closing-tag
# lookalike, `<`, `/` and the tag name with any whitespace between them and a
# non-word character or end of text after, becomes `<\/untrusted-content`; the
# rest of the text is kept. Escaping the whole output again changes nothing, so
# the orchestrator can wrap it in `<untrusted-content>` without a record
# closing it early.
#
# Cap: at most 8 records and 24 KiB of record text. When more records match,
# stderr carries `decisions-active.sh: DECISIONS-TRUNCATED: N of M records
# shown` and the exit status is 3. Nothing but record text reaches the
# selection, so a record cannot forge the truncation report: callers judge
# coverage by the exit status alone.
#
# Exit codes:
#   0  complete: no match, no docs/decisions directory, or every match printed
#   2  usage error: an unknown option (a removed range option included), no
#      path, or --all-active beside --paths-stdin or a path
#   3  degraded: a record is malformed (check-decisions.sh would reject it:
#      both call dec_validate_tree), docs/decisions is not a readable local
#      directory, or more records matched than the cap shows. stderr names
#      each problem as the record's file name and a reason code (file-type,
#      header, status, supersession, source-plan, applies-to), never a value
#      from the record, plus the DECISIONS-TRUNCATED line when capped. Only
#      records the validator accepts are selected, and those matches are
#      still printed, so the caller reports degraded coverage rather than
#      "no applicable decisions".
#   4  the path list is unavailable (never with --all-active, which reads
#      none): the --paths-stdin list cannot be read,
#      a --paths-stdin line lacks its `p ` prefix, or a path cannot be
#      normalised to a plain repo-relative path
#      (DECISIONS-PATH-UNNORMALISABLE)
#   5  a private temp file (the --temp-output file or the --paths-stdin
#      copy) could not be created; stderr carries a fixed reason, never a
#      path
#   6  escaping record text failed: stderr carries the fixed reason
#      `decisions-active.sh: DECISIONS-ESCAPE-FAILED` and stdout carries no
#      selection (with --temp-output, the status line `selector-output=`)
#   7  internal failure: a command failed unexpectedly under `set -e` (a
#      pipeline, a read, a substitution), or the records could not be
#      listed, before a documented result; stderr
#      carries the fixed reason `decisions-active.sh: DECISIONS-INTERNAL` and no
#      selection is handed over (with --temp-output, `selector-output=`).
#      Every documented status leaves through quit; any other non-zero exit
#      becomes 7, so a failure is never silent and never reads as another code.
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
da_documented=0
quit() {
	da_documented=1
	exit "$1"
}

# Private temp files (mktemp, outside the repository), removed on any exit
# except a selection handed to the caller after exit 0 or 3.
out_tmp=""
# Every write here is guarded: under `set -e` a failed handoff write (a closed
# or read-only stdout) would end the handler with bash's own error and exit 1,
# skipping the fixed reason. A handoff that cannot be written hands nothing
# over and is internal failure 7. The status line is written in a subshell:
# Bash 3.2 keeps a failed printf in its stdout buffer and would flush it into
# the next write, the reason on stderr.
on_exit() {
	local rc=$? da_line da_reason=0
	set +e
	if [[ $rc -ne 0 && $da_documented -ne 1 ]]; then
		rc=7
		da_reason=1
	fi
	if [[ -n "$out_tmp" ]]; then
		case "$rc" in
		0 | 3) da_line="selector-output=$out_tmp" ;;
		*)
			rm -f -- "$out_tmp" 2>/dev/null
			da_line="selector-output="
			;;
		esac
		if ! { exec 1>&3 3>&-; } 2>/dev/null || ! (printf '%s\n' "$da_line") 2>/dev/null; then
			rm -f -- "$out_tmp" 2>/dev/null
			# A documented exit 7 has already printed the reason.
			[[ $rc -eq 7 ]] || da_reason=1
			rc=7
		fi
	fi
	if [[ $da_reason -eq 1 ]]; then
		echo "decisions-active.sh: DECISIONS-INTERNAL" >&2 2>/dev/null
	fi
	exit "$rc"
}
trap on_exit EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
# shellcheck source=scripts/lib/decisions-common.sh disable=SC1091
. "$SCRIPT_DIR/lib/decisions-common.sh"

# A glob from a record is matched case-sensitively: the shared lib clears
# nocasematch.

MAX_RECORDS=8
MAX_BYTES=24576

usage() {
	echo "usage: decisions-active.sh [--temp-output] (--all-active | --paths-stdin | [--] <path>...)" >&2
	quit 2
}

temp_output=0
from_stdin=0
all_active=0
while [[ $# -gt 0 ]]; do
	case "$1" in
	--temp-output)
		temp_output=1
		shift
		;;
	--paths-stdin)
		from_stdin=1
		shift
		;;
	--all-active)
		all_active=1
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
if [[ $all_active -eq 1 ]]; then
	mode=all
	[[ $from_stdin -eq 0 && $# -eq 0 ]] || usage
elif [[ $from_stdin -eq 1 ]]; then
	mode=stdin
	[[ $# -eq 0 ]] || usage
fi

root="$(cd -P -- "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" >/dev/null && pwd -P)"

# normalise_path <path>: sets NORM to the path's normal spelling (see the
# header): leading `./`, `.` components and repeated `/` dropped, one
# trailing `/` kept. Returns 1, NORM empty, when the path is empty, absolute,
# holds a `..` component, or is empty after normalising. The one normaliser
# for every input mode.
normalise_path() {
	local p="$1" out="" comp trail=0
	NORM=""
	[[ -n "$p" && "$p" != /* ]] || return 1
	case "/$p/" in
	*/./* | *//* | */../*) ;;
	*)
		NORM="$p"
		return 0
		;;
	esac
	[[ "$p" != */ && "$p" != */. ]] || trail=1
	while [[ -n "$p" ]]; do
		comp="${p%%/*}"
		if [[ "$comp" == "$p" ]]; then
			p=""
		else
			p="${p#*/}"
		fi
		case "$comp" in
		"" | .) ;;
		..) return 1 ;;
		*) out+="${out:+/}$comp" ;;
		esac
	done
	[[ -n "$out" ]] || return 1
	[[ $trail -eq 0 ]] || out+=/
	NORM="$out"
}

if [[ $temp_output -eq 1 ]]; then
	if ! out_tmp="$(mktemp "${TMPDIR:-/tmp}/skein-decisions.XXXXXX" 2>/dev/null)"; then
		out_tmp=""
		echo "decisions-active.sh: --temp-output: cannot create a temp file" >&2
		printf 'selector-output=\n'
		quit 5
	fi
	exec 3>&1 1>"$out_tmp"
fi
# private_tmp: a fresh mktemp file, or exit 5 with a fixed reason (mktemp's own
# message, which names a random path, is dropped).
private_tmp() {
	mktemp 2>/dev/null || {
		echo "decisions-active.sh: cannot create a private temp file" >&2
		return 5
	}
}
paths=()
case "$mode" in
argv)
	paths=("$@")
	;;
stdin)
	entries="$(private_tmp)" || quit 5
	if ! dec_read_list - >"$entries"; then
		rm -f -- "$entries"
		echo "decisions-active.sh: cannot read the path list" >&2
		quit 4
	fi
	unprefixed=0
	while IFS= read -r -d '' entry; do
		if [[ "$entry" != "p "* ]]; then
			unprefixed=1
		else
			paths+=("${entry#p }")
		fi
	done <"$entries"
	rm -f -- "$entries"
	if [[ $unprefixed -eq 1 ]]; then
		echo "decisions-active.sh: a --paths-stdin line lacks its 'p ' prefix" >&2
		quit 4
	fi
	;;
all) ;;
esac
# Globs see only the normal spelling; a path with none is refused loudly.
for ((k = 0; k < ${#paths[@]}; k++)); do
	if ! normalise_path "${paths[$k]}"; then
		echo "decisions-active.sh: DECISIONS-PATH-UNNORMALISABLE" >&2
		quit 4
	fi
	paths[k]="$NORM"
done
[[ $mode == all || ${#paths[@]} -gt 0 ]] || usage

dec_check_directory "$root" || quit 3

# glob_match <path> <glob>: `[[ $path == $glob ]]` for the dialect (literal
# characters, `*`, `?`) without backtracking. The glob is split at its stars;
# the first segment must match the path's start and the last its end, and
# each middle segment is taken at its leftmost match after the one before,
# which finds a match whenever one exists. Bash only ever sees star-free
# segments, each matching a fixed number of characters.
glob_match() {
	local p="$1" g="$2" first last rest seg pos end
	if [[ "$g" != *'*'* ]]; then
		# shellcheck disable=SC2053  # the glob is the pattern on purpose
		[[ "$p" == $g ]]
		return
	fi
	first="${g%%\**}"
	last="${g##*\*}"
	end=$((${#p} - ${#last}))
	[[ $end -ge ${#first} ]] || return 1
	# shellcheck disable=SC2053
	[[ "${p:0:${#first}}" == $first && "${p:end}" == $last ]] || return 1
	pos=${#first}
	rest="${g:${#first}+1}"
	rest="${rest:0:${#rest}-${#last}}"
	while [[ -n "$rest" ]]; do
		seg="${rest%%\**}"
		rest="${rest:${#seg}+1}"
		[[ -n "$seg" ]] || continue
		while :; do
			[[ $((pos + ${#seg})) -le $end ]] || return 1
			# shellcheck disable=SC2053
			[[ "${p:pos:${#seg}}" == $seg ]] && break
			pos=$((pos + 1))
		done
		pos=$((pos + ${#seg}))
	done
}

# applies <glob-list>: succeeds when any glob matches any path. LC_ALL=C makes
# `?` match one byte in every locale.
applies() {
	local glob p
	local LC_ALL=C
	dec_split_globs "$1"
	for glob in "${DEC_GLOBS[@]}"; do
		for p in "${paths[@]}"; do
			glob_match "$p" "$glob" && return 0
		done
	done
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

# Fences follow CommonMark (the header above): FENCE_OPEN captures the run
# and the rest of the line, FENCE_CLOSE a run followed only by blanks. A
# trailing CR is a line ending, not content.
FENCE_OPEN='^ {0,3}(`{3,}|~{3,})(.*)$'
FENCE_CLOSE='^ {0,3}(`{3,}|~{3,})[[:blank:]]*$'
# Headings follow CommonMark too. An ATX heading is the shared lib's
# dec_heading, the rule dec_header also uses to end the header; levels three
# to six end a paragraph but are text within a section. SETEXT_LINE: up to
# three spaces, a run of `=` (level 1) or `-` (level 2), then only blanks; it
# makes the paragraph above it a heading. CODE_INDENT: a line that cannot
# start a paragraph (four columns of indentation make an indented code block).
SETEXT_LINE='^ {0,3}(=+|-+)[[:blank:]]*$'
CODE_INDENT=$'^(    | {0,3}\t)'

# block <record path>: the header, then the Decision and Why sections. A
# section is what follows a level-one or level-two heading, ATX (indented up
# to three spaces, an optional closing `#` run) or setext, up to the next one;
# Decision and Why are the level-two headings with exactly that text. Lines
# before the first level-two heading (the title and the header) are kept, and
# so is a level-one heading among them. A heading inside a fence is text. A
# paragraph is held back until it ends, because a setext underline decides
# after the fact that it was a heading.
block() {
	local line text keep=1 fence="" seen=0 title level k
	local -a para=()
	local LC_ALL=C
	# _block_emit <line>: prints the line when the current section is kept.
	_block_emit() {
		if [[ $keep -eq 1 ]]; then
			printf '%s\n' "$1"
		fi
	}
	# _block_flush: emits the held paragraph as body text.
	_block_flush() {
		for ((k = 0; k < ${#para[@]}; k++)); do
			_block_emit "${para[$k]}"
		done
		para=()
	}
	# _block_heading <level> <text>: starts a section.
	_block_heading() {
		local t="$2"
		t="${t#"${t%%[![:blank:]]*}"}"
		t="${t%"${t##*[![:blank:]]}"}"
		if [[ "$t" =~ (^|[[:blank:]])#+$ ]]; then
			t="${t%"${BASH_REMATCH[0]}"}"
			t="${t%"${t##*[![:blank:]]}"}"
		fi
		if [[ $1 -eq 2 ]]; then
			seen=1
			case "$t" in
			Decision | Why) keep=1 ;;
			*) keep=0 ;;
			esac
		elif [[ $seen -eq 1 ]]; then
			keep=0
		fi
	}
	while IFS= read -r line || [[ -n "$line" ]]; do
		text="${line%$'\r'}"
		if [[ -n "$fence" ]]; then
			if [[ "$text" =~ $FENCE_CLOSE ]] && [[ "${BASH_REMATCH[1]:0:1}" == "${fence:0:1}" && ${#BASH_REMATCH[1]} -ge ${#fence} ]]; then
				fence=""
			fi
			_block_emit "$line"
		elif [[ "$text" =~ $FENCE_OPEN ]] && [[ "${BASH_REMATCH[1]:0:1}" == '~' || "${BASH_REMATCH[2]}" != *'`'* ]]; then
			_block_flush
			fence="${BASH_REMATCH[1]}"
			_block_emit "$line"
		elif dec_heading "$text"; then
			_block_flush
			if [[ $DEC_HEADING_LEVEL -le 2 ]]; then
				_block_heading "$DEC_HEADING_LEVEL" "$DEC_HEADING_TEXT"
			fi
			_block_emit "$line"
		elif [[ ${#para[@]} -gt 0 && "$text" =~ $SETEXT_LINE ]]; then
			level=2
			[[ "${BASH_REMATCH[1]:0:1}" == '=' ]] && level=1
			title=""
			for ((k = 0; k < ${#para[@]}; k++)); do
				title+="${title:+ }${para[$k]%$'\r'}"
			done
			_block_heading "$level" "$title"
			_block_flush
			_block_emit "$line"
		elif [[ "$text" =~ ^[[:blank:]]*$ ]] || [[ ${#para[@]} -eq 0 && "$text" =~ $CODE_INDENT ]]; then
			_block_flush
			_block_emit "$line"
		else
			para+=("$line")
		fi
	done 2>/dev/null <"$1"
	_block_flush
}

malformed=0
dec_validate_tree "$root" || malformed=$?
# The records could not be listed: nothing was validated, so an empty
# selection would read as "no decision applies".
if [[ $malformed -eq 2 ]]; then
	echo "decisions-active.sh: DECISIONS-INTERNAL" >&2
	quit 7
fi
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
	if [[ $mode == all ]] || applies "$(dec_header "$path" "Applies to" || true)"; then
		matched+=("$path")
	fi
done

# The selection is held until every record is escaped, so an escaping failure
# prints nothing: no unescaped or partial selection reaches a lens prompt.
shown=0
used=0
selection=""
for path in "${matched[@]+"${matched[@]}"}"; do
	text="$(
		printf '### Record: docs/decisions/%s\n' "${path##*/}"
		block "$path"
	)"
	if ! text="$(printf '%s\n' "$text" | escape)"; then
		echo "decisions-active.sh: DECISIONS-ESCAPE-FAILED" >&2
		quit 6
	fi
	size="$(printf '%s\n' "$text" | LC_ALL=C wc -c | tr -d '[:space:]')"
	if [[ $shown -ge $MAX_RECORDS || $((used + size)) -gt $MAX_BYTES ]]; then
		break
	fi
	selection+="$text"$'\n'
	shown=$((shown + 1))
	used=$((used + size))
done
[[ -z "$selection" ]] || printf '%s' "$selection"

total=${#matched[@]}
if [[ $shown -lt $total ]]; then
	printf 'decisions-active.sh: DECISIONS-TRUNCATED: %d of %d records shown\n' "$shown" "$total" >&2
	quit 3
fi

[[ $malformed -eq 0 ]] || quit 3
