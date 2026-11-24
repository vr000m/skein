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
# Record text is escaped: any case-insensitive `</untrusted-content ...>`
# lookalike becomes `<\/untrusted-content>`, so the orchestrator can wrap the
# whole output in `<untrusted-content>` without a record closing it early.
#
# Cap: at most 8 records and 24 KiB of record text. When more records match,
# the last line is `DECISIONS-TRUNCATED: N of M records shown`.
#
# Exit codes:
#   0  success: no match, no docs/decisions directory, or a truncated block
#   2  usage error (no path, or an option)
#   3  a record is malformed (Status missing or not active/superseded, or an
#      active record with a missing or unsupported `Applies to`); stderr names
#      each such file. Well-formed matches are still printed, so the caller
#      reports degraded coverage rather than "no applicable decisions".
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/decisions-common.sh disable=SC1091
. "$SCRIPT_DIR/lib/decisions-common.sh"

# A glob from a record is matched with these defaults, whatever the caller set.
shopt -u extglob nocasematch nocaseglob

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
dir="$root/docs/decisions"

records=()
while IFS= read -r record_path; do
	records+=("$record_path")
done < <(dec_record_files "$dir")
[[ ${#records[@]} -gt 0 ]] || exit 0

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

# escape: neutralise a closing-tag lookalike anywhere in stdin, including one
# split across lines. The boundary after the tag name is a non-word character,
# matching the rule the skills apply to untrusted input.
escape() {
	sed -E -e ':a' -e 'N' -e '$!ba' -e 's#<[[:space:]]*/[[:space:]]*[uU][nN][tT][rR][uU][sS][tT][eE][dD]-[cC][oO][nN][tT][eE][nN][tT]([^A-Za-z0-9_>][^>]*)?>#<\\/untrusted-content>#g'
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

matched=()
malformed=0
for path in "${records[@]+"${records[@]}"}"; do
	name="$(basename "$path")"
	status="$(dec_header "$path" Status || true)"
	case "$status" in
	active) ;;
	superseded) continue ;;
	*)
		echo "decisions-active.sh: malformed record $name: Status must be active or superseded" >&2
		malformed=1
		continue
		;;
	esac
	applies_to="$(dec_header "$path" "Applies to" || true)"
	bad=""
	while IFS= read -r glob; do
		if reason="$(dec_glob_problem "$glob")"; then
			bad="$reason"
			break
		fi
	done < <(dec_split_globs "$applies_to")
	if [[ -n "$bad" ]]; then
		echo "decisions-active.sh: malformed record $name: Applies to: $bad" >&2
		malformed=1
		continue
	fi
	if applies "$applies_to"; then
		matched+=("$path")
	fi
done

shown=0
used=0
for path in "${matched[@]+"${matched[@]}"}"; do
	text="$(
		printf '### Record: docs/decisions/%s\n' "$(basename "$path")"
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
