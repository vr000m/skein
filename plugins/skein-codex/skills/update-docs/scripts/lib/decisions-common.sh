#!/usr/bin/env bash
# decisions-common.sh — the one header parser and record validator for
# docs/decisions records. Sourced by scripts/check-decisions.sh (validator) and
# scripts/decisions-active.sh (selector), so the two cannot disagree about what
# a record says or whether it is valid. It reads records only. The sourcing
# script owns `set -euo pipefail`.
#
# Every function that parses record text runs under `local LC_ALL=C`, so a
# header, glob or status is parsed byte for byte and the validator and
# selector reach the same verdict in every locale (a U+00A0 is not trimmed as
# whitespace, and a non-UTF-8 byte does not stop a regex match).
#
# A record's header is the run of inline `**Field**: value` lines before its
# first level-two heading, as dec_heading reads one. The first occurrence of a
# field wins.

# Status, glob and name matches are case-sensitive, and the record glob skips
# hidden files, in every script that sources this file. Bash takes options
# from an exported BASHOPTS or SHELLOPTS, so a caller's `nocasematch`,
# `nocaseglob` or `dotglob` (which would make docs/decisions/.hidden.md a
# record), or `noglob` (which would leave the record glob unexpanded, an
# empty record set) would otherwise reach one script and not another.
# `failglob` would make an empty record glob an error, and `nullglob` would
# change what it expands to, so both are cleared too (extglob is left alone).
#
# Ambient variables are reset for the same reason: an inherited CDPATH makes
# `cd` print the directory it found, so `$(cd dir && pwd -P)` returns two
# lines; GLOBIGNORE filters the record glob (and turns on dotglob); a
# non-default IFS changes word splitting. LC_ALL=C is exported for the whole
# run, not only inside the parsers: every NUL-delimited list (changed paths,
# --paths-stdin, --targets) is then read byte for byte, so an invalid
# multibyte file name cannot make `read -d ''` swallow the next entry.
unset CDPATH GLOBIGNORE
export LC_ALL=C
IFS=$' \t\n'
set +f
shopt -u nocasematch nocaseglob dotglob failglob nullglob

# Reject non-local directories even when the link target is missing. A linked
# docs/ is refused only when a decisions entry exists through it: a repository
# without docs/decisions passes, however its docs/ is stored. An unlistable
# directory fails too: bash 3.2 leaves its glob unexpanded, so it would
# otherwise read as an empty, valid record set. So does an unsearchable
# docs/: no test can see docs/decisions through it, so it would otherwise read
# as an absent folder.
dec_check_directory() {
	local root="$1" dir="$1/docs/decisions"
	if [[ -L "$dir" || (-L "$root/docs" && -e "$dir") || (-e "$dir" && ! -d "$dir") ]]; then
		printf '%s: expected a local decisions directory\n' "$dir" >&2
		return 1
	fi
	if [[ (-d "$dir" && (! -r "$dir" || ! -x "$dir")) || (-d "$root/docs" && ! -x "$root/docs") ]]; then
		printf '%s: file-type: the decisions directory is not readable\n' "$dir" >&2
		return 1
	fi
}

# dec_read_list <file>: one entry per line on stdout, NUL-terminated, read
# from <file> (`-` is stdin). A list holding a NUL byte is NUL-delimited,
# otherwise newline-delimited; empty entries are dropped. A file other than
# `-` must be a regular, non-symlink file. Returns 1 when it is not one, and 2
# when the list cannot be copied or its NUL bytes cannot be counted
# (dec_nul_state), so a failed count never falls back to newline parsing.
dec_read_list() {
	local file="$1" entry nul state=0
	local LC_ALL=C
	if [[ "$file" != - ]]; then
		[[ ! -L "$file" && -f "$file" && -r "$file" ]] || return 1
	fi
	# A here-document cannot carry a NUL, so stdin is copied once to test for one.
	nul="$(mktemp 2>/dev/null)" || return 2
	if ! cat -- "$file" >"$nul"; then
		rm -f -- "$nul"
		return 2
	fi
	dec_nul_state "$nul" || state=$?
	case "$state" in
	0)
		while IFS= read -r -d '' entry || [[ -n "$entry" ]]; do
			if [[ -n "$entry" ]]; then
				printf '%s\0' "$entry"
			fi
		done <"$nul"
		;;
	1)
		while IFS= read -r entry || [[ -n "$entry" ]]; do
			if [[ -n "$entry" ]]; then
				printf '%s\0' "$entry"
			fi
		done <"$nul"
		;;
	*)
		rm -f -- "$nul"
		return 2
		;;
	esac
	rm -f -- "$nul"
}

# dec_record_files <dir>: appends the record paths to DEC_RECORDS in byte
# order, including invalid file types to diagnose. It fills the array itself
# rather than feeding a process substitution, whose failure the reader could
# not see: a non-zero return means the records could not be listed.
dec_record_files() {
	local dir="$1" f
	local LC_ALL=C
	[[ -d "$dir" ]] || return 0
	for f in "$dir"/*.md; do
		[[ -e "$f" || -L "$f" ]] || continue
		[[ "${f##*/}" == README.md ]] && continue
		DEC_RECORDS+=("$f")
	done
}

# An unreadable record is a file-type problem, so no read of it reaches stderr.
dec_regular_record() {
	[[ ! -L "$1" && -f "$1" && -r "$1" ]]
}

# Resolve symlinked plans and parent directories before testing containment.
dec_source_plan_exists() {
	local root="$1" relative="$2" path parent target hops=0
	[[ -n "$relative" && "$relative" != /* ]] || return 1
	path="${root%/}/$relative"
	while ((hops <= 40)); do
		parent="$(cd -P -- "${path%/*}/" >/dev/null 2>&1 && pwd -P)" || return 1
		[[ "$parent" == "$root" || "$parent" == "${root%/}/"* ]] || return 1
		path="${parent%/}/${path##*/}"
		if [[ ! -L "$path" ]]; then
			[[ -f "$path" ]]
			return
		fi
		# A sentinel preserves trailing newlines in the target.
		target="$(readlink "$path" && printf '\001')" || return 1
		target="${target%$'\n\001'}"
		case "$target" in
		/*) path="$target" ;;
		*) path="${parent%/}/$target" ;;
		esac
		hops=$((hops + 1))
	done
	return 1
}

# dec_target_problem <physical root> <repo-relative path>: prints why a write
# to the path could land outside <root> or through a link, and returns 0;
# returns 1 when the path is safe to create or edit. A promotion writes only
# `docs/dev_plans/<name>` (its source plan) and `docs/decisions/<name>`, where
# <name> is one component matching DEC_TARGET_NAME (so no `.git` component and
# no leading `-`); any other path is refused. Every existing component
# below <root> must be a real directory (the leaf a regular file), so the write
# resolves physically inside <root>. A missing component ends the walk: what
# is created under a verified directory stays inside it. A `..` component is
# refused up front, wherever it sits, because the walk can end before reaching
# one that follows a missing directory.
DEC_TARGET_NAME='[A-Za-z0-9][A-Za-z0-9._-]*[.]md'
dec_target_problem() {
	local root="$1" rest="$2" part path="$1"
	if [[ -z "$rest" || "$rest" == /* ]]; then
		printf 'expected a repo-relative path\n'
		return 0
	fi
	if [[ "/$rest/" == */../* ]]; then
		printf "a '..' component may leave the repository\n"
		return 0
	fi
	if [[ ! "$rest" =~ ^docs/(dev_plans|decisions)/$DEC_TARGET_NAME$ ]]; then
		printf 'expected docs/dev_plans/<name>.md or docs/decisions/<name>.md\n'
		return 0
	fi
	while [[ -n "$rest" ]]; do
		part="${rest%%/*}"
		if [[ "$rest" == */* ]]; then
			rest="${rest#*/}"
		else
			rest=""
		fi
		[[ -n "$part" && "$part" != . ]] || continue
		path="$path/$part"
		if [[ -L "$path" ]]; then
			printf '%s is a symlink\n' "${path#"$root"/}"
			return 0
		fi
		[[ -e "$path" ]] || return 1
		if [[ -n "$rest" && ! -d "$path" ]]; then
			printf '%s is not a directory\n' "${path#"$root"/}"
			return 0
		fi
		if [[ -z "$rest" && ! -f "$path" ]]; then
			printf 'expected a regular file\n'
			return 0
		fi
	done
	return 1
}

# dec_heading <line>: the one heading rule, shared by dec_header and the
# selector's body parser so they agree on where a record's header ends. A
# CommonMark ATX heading: up to three spaces, one to six `#`, then a space, a
# tab or the end of the line (a trailing CR is a line ending). On a match sets
# DEC_HEADING_LEVEL (1-6) and DEC_HEADING_TEXT (the rest of the line) and
# returns 0; returns 1 otherwise.
DEC_ATX_HEADING=$'^ {0,3}(#{1,6})([ \t](.*))?$'
# shellcheck disable=SC2034  # DEC_HEADING_TEXT is read by the selector
dec_heading() {
	local text="${1%$'\r'}"
	local LC_ALL=C
	[[ "$text" =~ $DEC_ATX_HEADING ]] || return 1
	DEC_HEADING_LEVEL=${#BASH_REMATCH[1]}
	DEC_HEADING_TEXT="${BASH_REMATCH[3]}"
}

# dec_header <file> <Field>: the trimmed value of the first `**Field**:` line in
# the header, or nothing when absent. Exit status is 0 only when found, so an
# empty value is distinguishable from a missing header.
dec_header() {
	local file="$1" field="$2" line value
	local LC_ALL=C
	while IFS= read -r line || [[ -n "$line" ]]; do
		if dec_heading "$line" && [[ $DEC_HEADING_LEVEL -eq 2 ]]; then
			return 1
		fi
		if [[ "$line" =~ ^\*\*([^*]+)\*\*:[[:space:]]*(.*)$ ]] && [[ "${BASH_REMATCH[1]}" == "$field" ]]; then
			value="${BASH_REMATCH[2]}"
			printf '%s\n' "${value%"${value##*[![:space:]]}"}"
			return 0
		fi
	done 2>/dev/null <"$file"
	return 1
}

# dec_glob_problem <glob>: prints why a single `Applies to` glob is outside the
# dialect and returns 0; returns 1 when the glob is supported. The dialect is
# literal characters from DEC_GLOB_BAD's complement, `*` (any characters,
# `/` included) and `?` (one character), with no `**`. It has no bracket
# expression, backslash or extended pattern, so the selector's matcher equals
# bash `[[ $path == $glob ]]` on bash 3.2 and bash 5 alike. A glob is also in
# the selector's path normal form (normalise_path): relative, with no empty
# (`//`), `.` or `..` component, so a leading `./` is refused too. The
# selector matches normalised paths only, so a glob in any other spelling
# could never match and would be a valid record that silently selects nothing.
# One trailing `/` stays allowed, as it does on a path.
DEC_GLOB_BAD='[^-A-Za-z0-9._/@+=:%~ *?]'
dec_glob_problem() {
	local glob="$1"
	local LC_ALL=C
	if [[ -z "$glob" ]]; then
		printf 'empty glob\n'
	elif [[ "$glob" =~ $DEC_GLOB_BAD ]]; then
		printf "a character outside letters, digits, spaces, '. _ / - @ + = : %% ~', '*' and '?' in '%s'\n" "$glob"
	elif [[ "$glob" == *'**'* ]]; then
		printf "'**' is not supported in '%s'\n" "$glob"
	elif [[ "$glob" == /* ]]; then
		printf "a glob is repo-relative; '%s' starts with '/'\n" "$glob"
	elif [[ "$glob" == *//* ]]; then
		printf "an empty path component ('//') in '%s'\n" "$glob"
	elif [[ "/$glob/" == */./* || "/$glob/" == */../* ]]; then
		printf "a '.' or '..' path component in '%s'\n" "$glob"
	else
		return 1
	fi
}

# dec_validate_tree <physical repo root>: the one definition of a valid record,
# shared by the validator and the selector so a record is selected only when
# the validator accepts it. Run dec_check_directory first. Sets:
#   DEC_RECORDS[i]  record paths in byte order (dec_record_files)
#   DEC_VALID[i]    1 when record i has no problem, else 0
#   DEC_PROBLEMS[k] `<record name>: <message>`, in report order; the message
#                   quotes record values, so it is for a maintainer's terminal
#   DEC_CODES[k]    problem k's reason code, from a closed set that carries no
#                   record value: file-type, header, status, supersession,
#                   source-plan, applies-to
#   DEC_PROBLEM_INDEX[k]  the index into DEC_RECORDS of problem k's record
# Returns 0 when no record has a problem, 1 when one has, and 2 when the
# records cannot be listed (nothing was validated; callers must not read an
# empty record set as a valid one).
# shellcheck disable=SC2034  # DEC_VALID is read by the sourcing script
dec_validate_tree() {
	local root="$1" dir="$1/docs/decisions" path name field status supersedes
	local superseded_by glob reason index complete start current target
	local -a successors visited
	DEC_RECORDS=()
	DEC_VALID=()
	DEC_PROBLEMS=()
	DEC_CODES=()
	DEC_PROBLEM_INDEX=()
	dec_record_files "$dir" || return 2
	# One NUL pass before any header is read for any purpose: bash 3.2 command
	# substitution drops a NUL and bash 5 keeps the bytes after it, so a value
	# read from such a file differs per bash. A flagged file is a `header`
	# problem below, and _dec_member never resolves to it, so no reciprocal
	# check reads it either.
	DEC_NUL=()
	for ((index = 0; index < ${#DEC_RECORDS[@]}; index++)); do
		DEC_NUL[index]=0
		if dec_regular_record "${DEC_RECORDS[$index]}" && dec_has_nul "${DEC_RECORDS[$index]}"; then
			DEC_NUL[index]=1
		fi
	done

	# _dec_problem <record index> <reason code> <message>
	_dec_problem() {
		DEC_PROBLEMS+=("${DEC_RECORDS[$1]##*/}: $3")
		DEC_CODES+=("$2")
		DEC_PROBLEM_INDEX+=("$1")
		DEC_VALID[$1]=0
	}
	_dec_field() {
		dec_header "$dir/$1" "$2" || true
	}
	# _dec_member <name>: sets target to the index of a regular, NUL-free
	# record so named.
	_dec_member() {
		local i
		for ((i = 0; i < ${#DEC_RECORDS[@]}; i++)); do
			if [[ "${DEC_RECORDS[$i]}" == "$dir/$1" && "${DEC_NUL[$i]}" == 0 ]] && dec_regular_record "$dir/$1"; then
				target="$i"
				return 0
			fi
		done
		return 1
	}

	for ((index = 0; index < ${#DEC_RECORDS[@]}; index++)); do
		path="${DEC_RECORDS[$index]}"
		name="${path##*/}"
		successors[index]=-1
		DEC_VALID[index]=1
		if ! dec_regular_record "$path"; then
			_dec_problem "$index" file-type "expected a readable, regular, non-symlink file"
			continue
		fi
		if [[ "${DEC_NUL[$index]}" == 1 ]]; then
			_dec_problem "$index" header "contains a NUL byte"
			continue
		fi

		complete=1
		for field in Status Date "Applies to" Supersedes "Superseded by" "Source plan"; do
			if [[ -z "$(_dec_field "$name" "$field")" ]]; then
				_dec_problem "$index" header "missing header $field"
				complete=0
			fi
		done
		[[ $complete -eq 1 ]] || continue

		status="$(_dec_field "$name" Status)"
		supersedes="$(_dec_field "$name" Supersedes)"
		superseded_by="$(_dec_field "$name" "Superseded by")"

		if [[ "$status" != active && "$status" != superseded ]]; then
			_dec_problem "$index" status "invalid Status '$status' (expected active or superseded)"
		fi

		if [[ "$supersedes" != none ]]; then
			if ! _dec_member "$supersedes"; then
				_dec_problem "$index" supersession "Supersedes '$supersedes' does not resolve to a record"
			elif [[ "$(_dec_field "$supersedes" "Superseded by")" != "$name" ]]; then
				_dec_problem "$index" supersession "Supersedes '$supersedes' is not reciprocal: it must name $name in Superseded by"
			fi
		fi

		if [[ "$superseded_by" != none ]]; then
			if ! _dec_member "$superseded_by"; then
				_dec_problem "$index" supersession "Superseded by '$superseded_by' does not resolve to a record"
			elif [[ "$(_dec_field "$superseded_by" Supersedes)" != "$name" ]]; then
				_dec_problem "$index" supersession "Superseded by '$superseded_by' is not reciprocal: it must name $name in Supersedes"
			else
				successors[index]="$target"
			fi
			if [[ "$status" == active ]]; then
				_dec_problem "$index" supersession "active record is superseded by '$superseded_by'"
			fi
		fi

		if ! dec_source_plan_exists "$root" "$(_dec_field "$name" "Source plan")"; then
			_dec_problem "$index" source-plan "Source plan '$(_dec_field "$name" "Source plan")' does not resolve to a file inside the repository"
		fi

		dec_split_globs "$(_dec_field "$name" "Applies to")"
		for glob in "${DEC_GLOBS[@]}"; do
			if reason="$(dec_glob_problem "$glob")"; then
				_dec_problem "$index" applies-to "Applies to: $reason"
			fi
		done
	done

	# Follow verified edges once. A node visited from the current start is a cycle.
	for ((start = 0; start < ${#DEC_RECORDS[@]}; start++)); do
		current="$start"
		while ((current >= 0)); do
			if [[ -n "${visited[$current]:-}" ]]; then
				if [[ "${visited[$current]}" == "$start" ]]; then
					_dec_problem "$current" supersession "supersession cycle"
				fi
				break
			fi
			visited[current]="$start"
			current="${successors[$current]}"
		done
	done

	[[ ${#DEC_PROBLEMS[@]} -eq 0 ]]
}

# dec_nul_state <file>: the one NUL test. Returns 0 when <file> holds a NUL
# byte, 1 when it holds none, and 2 when its bytes cannot be counted (a failed
# wc or tr, or a count that is not a number). Compares byte counts with and
# without NULs, so it never puts file bytes through a shell variable, which
# works on bash 3.2.
dec_nul_state() {
	local all kept
	local LC_ALL=C
	all="$(LC_ALL=C wc -c <"$1" 2>/dev/null)" || return 2
	kept="$(
		set -o pipefail
		LC_ALL=C tr -d '\000' <"$1" 2>/dev/null | LC_ALL=C wc -c
	)" || return 2
	all="${all//[[:space:]]/}"
	kept="${kept//[[:space:]]/}"
	[[ "$all" =~ ^[0-9]+$ && "$kept" =~ ^[0-9]+$ ]] || return 2
	[[ "$all" != "$kept" ]] || return 1
}

# dec_has_nul <file>: returns 0 when <file> holds a NUL byte or cannot be
# counted, 1 otherwise, so an uncountable record is refused.
dec_has_nul() {
	local state=0
	dec_nul_state "$1" || state=$?
	[[ $state -ne 1 ]]
}

# dec_split_globs <Applies to value>: sets DEC_GLOBS to one glob per entry,
# split at every comma and trimmed; empty entries are kept so the validator
# can name them. It fills the array itself, so no reader depends on a
# producer's status.
dec_split_globs() {
	local rest="$1," part
	local LC_ALL=C
	DEC_GLOBS=()
	while [[ -n "$rest" ]]; do
		part="${rest%%,*}"
		rest="${rest#*,}"
		part="${part#"${part%%[![:space:]]*}"}"
		DEC_GLOBS+=("${part%"${part##*[![:space:]]}"}")
	done
}
