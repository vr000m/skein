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
# first `## ` heading. The first occurrence of a field wins.

# Status, glob and name matches are case-sensitive, and the record glob skips
# hidden files, in every script that sources this file. Bash takes options
# from an exported BASHOPTS or SHELLOPTS, so a caller's `nocasematch`,
# `nocaseglob` or `dotglob` (which would make docs/decisions/.hidden.md a
# record), or `noglob` (which would leave the record glob unexpanded, an
# empty record set) would otherwise reach one script and not another.
set +f
shopt -u nocasematch nocaseglob dotglob

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
# `-` must be a regular, non-symlink file. Returns 1 when it cannot be read.
dec_read_list() {
	local file="$1" entry nul
	local LC_ALL=C
	if [[ "$file" != - ]]; then
		[[ ! -L "$file" && -f "$file" && -r "$file" ]] || return 1
	fi
	# A here-document cannot carry a NUL, so stdin is copied once to test for one.
	nul="$(mktemp)" || return 1
	if ! cat -- "$file" >"$nul"; then
		rm -f -- "$nul"
		return 1
	fi
	if [[ "$(tr -cd '\000' <"$nul" | wc -c | tr -d '[:space:]')" -gt 0 ]]; then
		while IFS= read -r -d '' entry || [[ -n "$entry" ]]; do
			if [[ -n "$entry" ]]; then
				printf '%s\0' "$entry"
			fi
		done <"$nul"
	else
		while IFS= read -r entry || [[ -n "$entry" ]]; do
			if [[ -n "$entry" ]]; then
				printf '%s\0' "$entry"
			fi
		done <"$nul"
	fi
	rm -f -- "$nul"
}

# NUL-delimited entries in byte order, including invalid file types to diagnose.
dec_record_files() {
	local dir="$1" f
	local LC_ALL=C
	[[ -d "$dir" ]] || return 0
	for f in "$dir"/*.md; do
		[[ -e "$f" || -L "$f" ]] || continue
		[[ "${f##*/}" == README.md ]] && continue
		printf '%s\0' "$f"
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
		parent="$(cd -P -- "${path%/*}/" 2>/dev/null && pwd -P)" || return 1
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

# dec_header <file> <Field>: the trimmed value of the first `**Field**:` line in
# the header, or nothing when absent. Exit status is 0 only when found, so an
# empty value is distinguishable from a missing header.
dec_header() {
	local file="$1" field="$2" line value
	local LC_ALL=C
	while IFS= read -r line || [[ -n "$line" ]]; do
		[[ "$line" == "## "* ]] && return 1
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
# bash `[[ $path == $glob ]]` on bash 3.2 and bash 5 alike.
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
# Returns 0 when no record has a problem.
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
	while IFS= read -r -d '' path; do
		DEC_RECORDS+=("$path")
	done < <(dec_record_files "$dir")

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
	# _dec_member <name>: sets target to the index of a regular record so named.
	_dec_member() {
		local i
		for ((i = 0; i < ${#DEC_RECORDS[@]}; i++)); do
			if [[ "${DEC_RECORDS[$i]}" == "$dir/$1" ]] && dec_regular_record "$dir/$1"; then
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

		while IFS= read -r glob; do
			if reason="$(dec_glob_problem "$glob")"; then
				_dec_problem "$index" applies-to "Applies to: $reason"
			fi
		done < <(dec_split_globs "$(_dec_field "$name" "Applies to")")
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

# dec_split_globs <Applies to value>: one glob per line, split at every comma
# and trimmed; empty entries are kept so the validator can name them.
dec_split_globs() {
	local rest="$1," part
	local LC_ALL=C
	while [[ -n "$rest" ]]; do
		part="${rest%%,*}"
		rest="${rest#*,}"
		part="${part#"${part%%[![:space:]]*}"}"
		printf '%s\n' "${part%"${part##*[![:space:]]}"}"
	done
}
