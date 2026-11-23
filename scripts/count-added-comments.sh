#!/usr/bin/env bash
# count-added-comments.sh — count comment lines ADDED between two revisions.
#
# Usage: count-added-comments.sh [--verbose] <base> [<head>]
#
# Reads `git diff <base>...<head>` (head defaults to HEAD) and counts added
# lines whose first non-blank character is `#` in *.sh, *.py, *.jq and
# justfile. For a merge commit M, `<M^1> <M>` measures the merged PR.
#
# This is a HEURISTIC, documented so counts stay comparable across runs:
#   - excluded: shebang lines, linter/type pragmas (`# shellcheck`, `# noqa`,
#     `# type:`), license headers (`# Copyright`, `# SPDX-`), and TODO lines
#     that carry an issue link (a URL or `#N`);
#   - excluded: lines inside a shell heredoc body (*.sh and justfile only);
#   - NOT excluded (known over-count): `#` lines inside Python docstrings or
#     other multi-line strings, and heredoc-like text the opener regex misses;
#   - markdown is never read, so HTML BEGIN/END markers cannot count.
# Only ADDED lines count; removed comments, diff headers and context never do.
#
# Output: one integer. With --verbose, one "<count> <path>" line per file with
# a non-zero count, then "total <N>".
set -euo pipefail

verbose=0
if [[ "${1:-}" == "--verbose" ]]; then
	verbose=1
	shift
fi
if [[ $# -lt 1 || $# -gt 2 ]]; then
	echo "usage: ${0##*/} [--verbose] <base> [<head>]" >&2
	exit 2
fi
base="$1"
head="${2:-HEAD}"

# awk program: argv ranges "start-end ..." name the added lines of one file.
# kind is "shell" (heredoc tracking on) or "other".
IFS= read -r -d '' awk_prog <<'AWK' || true
function in_added(n,   i) {
	for (i = 1; i <= nr; i++)
		if (n >= lo[i] && n <= hi[i]) return 1
	return 0
}
BEGIN {
	nr = split(ranges, parts, " ")
	for (i = 1; i <= nr; i++) {
		split(parts[i], se, "-")
		lo[i] = se[1] + 0
		hi[i] = se[2] + 0
	}
	count = 0
	inhd = 0
}
{
	line = $0
	if (inhd) {
		cmp = line
		if (dash) sub(/^\t+/, "", cmp)
		if (cmp == delim) inhd = 0
		next
	}
	is_comment = (line ~ /^[ \t]*#/)
	if (kind == "shell" && !is_comment && match(line, /<<-?[ \t]*["']?[A-Za-z_][A-Za-z0-9_]*["']?/)) {
		if (RSTART == 1 || substr(line, RSTART - 1, 1) != "<") {
			tok = substr(line, RSTART, RLENGTH)
			dash = (tok ~ /^<<-/)
			sub(/^<<-?[ \t]*["']?/, "", tok)
			sub(/["']$/, "", tok)
			delim = tok
			inhd = 1
		}
	}
	if (!is_comment || !in_added(NR)) next
	if (NR == 1 && line ~ /^#!/) next
	if (line ~ /^[ \t]*#[ \t]*(shellcheck|noqa|type:)/) next
	if (line ~ /^[ \t]*#[ \t]*(Copyright|SPDX-)/) next
	if (line ~ /TODO/ && (line ~ /https?:\/\// || line ~ /#[0-9]+/)) next
	count++
}
END { print count }
AWK

total=0
details=""
while IFS= read -r -d '' file; do
	case "$file" in
	*.sh | justfile | */justfile) kind="shell" ;;
	*) kind="other" ;;
	esac
	ranges="$(git diff -U0 --no-color --no-renames "$base...$head" -- "$file" |
		awk '/^@@ /{
			plus = $3; sub(/^\+/, "", plus)
			n = split(plus, a, ",")
			start = a[1]; len = (n > 1) ? a[2] : 1
			if (len > 0) printf "%d-%d ", start, start + len - 1
		}')"
	[[ -n "$ranges" ]] || continue
	n="$(git show "$head:$file" | awk -v kind="$kind" -v ranges="$ranges" "$awk_prog")"
	if [[ "$n" -gt 0 ]]; then
		total=$((total + n))
		details="${details}${n} ${file}"$'\n'
	fi
done < <(git diff --name-only -z --diff-filter=AM --no-renames "$base...$head" -- '*.sh' '*.py' '*.jq' 'justfile' '*/justfile')

if [[ "$verbose" -eq 1 ]]; then
	printf '%s' "$details"
	echo "total $total"
else
	echo "$total"
fi
