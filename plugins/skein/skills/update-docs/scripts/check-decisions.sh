#!/usr/bin/env bash
# check-decisions.sh — validate the docs/decisions record graph.
#
# Usage: check-decisions.sh [<repo-root>]
#
# <repo-root> defaults to the git top level (or the current directory outside a
# repository). Records are <repo-root>/docs/decisions/*.md, README.md excluded;
# their format is defined in docs/decisions/README.md. A repo without a
# docs/decisions directory passes: the folder is adopted, never required.
#
# Checks, each reported as `<record>: <message>` on stderr:
#   - every header present and non-empty: Status, Date, Applies to, Supersedes,
#     Superseded by, Source plan
#   - Status is `active` or `superseded`
#   - Supersedes and Superseded by are `none` or the filename of an existing
#     record, and the link is reciprocal
#   - no active record is superseded
#   - Source plan resolves to a file under <repo-root>
#   - Applies to is comma-separated globs without `**` or braces
#
# Exit codes: 0 valid, 1 at least one problem, 2 usage error.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/decisions-common.sh disable=SC1091
. "$SCRIPT_DIR/lib/decisions-common.sh"

if [[ $# -gt 1 || "${1:-}" == -* ]]; then
	echo "usage: check-decisions.sh [<repo-root>]" >&2
	exit 2
fi

root="${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
dir="$root/docs/decisions"
problems=0

complain() {
	printf '%s: %s\n' "$1" "$2" >&2
	problems=$((problems + 1))
}

records=()
while IFS= read -r record_path; do
	records+=("$record_path")
done < <(dec_record_files "$dir")
if [[ ${#records[@]} -eq 0 ]]; then
	exit 0
fi

# header <name> <Field>: the value, or an empty string when absent.
header() {
	dec_header "$dir/$1" "$2" || true
}

for path in "${records[@]+"${records[@]}"}"; do
	name="$(basename "$path")"

	complete=1
	for field in Status Date "Applies to" Supersedes "Superseded by" "Source plan"; do
		if [[ -z "$(header "$name" "$field")" ]]; then
			complain "$name" "missing header $field"
			complete=0
		fi
	done
	[[ $complete -eq 1 ]] || continue

	status="$(header "$name" Status)"
	supersedes="$(header "$name" Supersedes)"
	superseded_by="$(header "$name" "Superseded by")"

	if [[ "$status" != active && "$status" != superseded ]]; then
		complain "$name" "invalid Status '$status' (expected active or superseded)"
	fi

	if [[ "$supersedes" != none ]]; then
		if [[ "$supersedes" == */* || "$supersedes" == README.md || ! -f "$dir/$supersedes" ]]; then
			complain "$name" "Supersedes '$supersedes' does not resolve to a record"
		elif [[ "$(header "$supersedes" "Superseded by")" != "$name" ]]; then
			complain "$name" "Supersedes '$supersedes' is not reciprocal: it must name $name in Superseded by"
		fi
	fi

	if [[ "$superseded_by" != none ]]; then
		if [[ "$superseded_by" == */* || "$superseded_by" == README.md || ! -f "$dir/$superseded_by" ]]; then
			complain "$name" "Superseded by '$superseded_by' does not resolve to a record"
		elif [[ "$(header "$superseded_by" Supersedes)" != "$name" ]]; then
			complain "$name" "Superseded by '$superseded_by' is not reciprocal: it must name $name in Supersedes"
		fi
		if [[ "$status" == active ]]; then
			complain "$name" "active record is superseded by '$superseded_by'"
		fi
	fi

	source_plan="$(header "$name" "Source plan")"
	if [[ ! -f "$root/$source_plan" ]]; then
		complain "$name" "Source plan '$source_plan' does not resolve to a file"
	fi

	while IFS= read -r glob; do
		if reason="$(dec_glob_problem "$glob")"; then
			complain "$name" "Applies to: $reason"
		fi
	done < <(dec_split_globs "$(header "$name" "Applies to")")
done

[[ $problems -eq 0 ]] || exit 1
