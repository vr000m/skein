#!/usr/bin/env bash
# decisions-common.sh — the one header parser for docs/decisions records.
# Sourced by scripts/check-decisions.sh (validator) and, from Phase 2,
# scripts/decisions-active.sh (selector), so the two cannot disagree about what
# a record says. Defines functions only; the sourcing script owns
# `set -euo pipefail`.
#
# A record's header is the run of inline `**Field**: value` lines before its
# first `## ` heading. The first occurrence of a field wins.

# Reject non-local directories even when the link target is missing.
dec_check_directory() {
	local root="$1" dir="$1/docs/decisions"
	if [[ -L "$root/docs" || -L "$dir" || (-e "$dir" && ! -d "$dir") ]]; then
		printf '%s: expected a local decisions directory\n' "$dir" >&2
		return 1
	fi
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

dec_regular_record() {
	[[ ! -L "$1" && -f "$1" ]]
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

# dec_header <file> <Field>: the trimmed value of the first `**Field**:` line in
# the header, or nothing when absent. Exit status is 0 only when found, so an
# empty value is distinguishable from a missing header.
dec_header() {
	local file="$1" field="$2" line value
	while IFS= read -r line || [[ -n "$line" ]]; do
		[[ "$line" == "## "* ]] && return 1
		if [[ "$line" =~ ^\*\*([^*]+)\*\*:[[:space:]]*(.*)$ ]] && [[ "${BASH_REMATCH[1]}" == "$field" ]]; then
			value="${BASH_REMATCH[2]}"
			value="${value%"${value##*[![:space:]]}"}"
			printf '%s\n' "$value"
			return 0
		fi
	done <"$file"
	return 1
}

# dec_glob_problem <glob>: prints why a single `Applies to` glob is outside the
# supported dialect (bash pattern, `*` crosses `/`, no `**`, no braces) and
# returns 0; returns 1 when the glob is supported.
dec_glob_problem() {
	local glob="$1"
	if [[ -z "$glob" ]]; then
		printf 'empty glob\n'
	elif [[ "$glob" == *'**'* ]]; then
		printf "'**' is not supported in '%s'\n" "$glob"
	elif [[ "$glob" == *'{'* || "$glob" == *'}'* ]]; then
		printf "braces are not supported in '%s'\n" "$glob"
	else
		return 1
	fi
}

# dec_split_globs <Applies to value>: one trimmed glob per line, empty entries
# kept so the validator can name them.
dec_split_globs() {
	local rest="$1" part
	while :; do
		part="${rest%%,*}"
		part="${part#"${part%%[![:space:]]*}"}"
		part="${part%"${part##*[![:space:]]}"}"
		printf '%s\n' "$part"
		[[ "$rest" == *,* ]] || break
		rest="${rest#*,}"
	done
}
