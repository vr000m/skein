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
#   - excluded: shebang lines (line 1, or an indented justfile recipe
#     shebang), linter/type pragmas (`# shellcheck`, `# noqa`,
#     `# type:`), license headers (`# Copyright`, `# SPDX-`), and TODO lines
#     that carry an issue link (a URL or `#N`);
#   - excluded: lines inside a shell heredoc body (*.sh and justfile only). An
#     opener counts only outside quotes, comments and `((...))` arithmetic, and
#     only when its terminator follows; otherwise it is not a heredoc. Every
#     opener on one line is honoured, and their bodies are skipped in order. In a
#     justfile the terminator may be indented, because just strips recipe
#     indentation before the shell sees it;
#   - NOT excluded (known over-count): `#` lines inside Python docstrings or
#     other multi-line strings;
#   - markdown is never read, so HTML BEGIN/END markers cannot count.
# Only ADDED lines count; removed comments, diff headers and context never do.
# A renamed file counts only the lines its rename changed.
# Added lines are read from the `+` lines of the diff body, not from hunk
# ranges, so `diff.interHunkContext` cannot pull context lines into the count.
#
# Output: one integer. With --verbose, one "<count> <path>" line per file with
# a non-zero count, then "total <N>". A revision that does not name a commit
# exits 2 with no count. Paths are repo-root relative wherever it runs from.
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
cd "$(git rev-parse --show-toplevel)"
for rev in "$base" "$head"; do
	if ! git rev-parse --verify --quiet --end-of-options "$rev^{commit}" >/dev/null; then
		echo "${0##*/}: not a commit: $rev" >&2
		exit 2
	fi
done

# Prints the new-side line numbers of the `+` lines in one file's diff.
IFS= read -r -d '' added_prog <<'AWK' || true
/^@@ / {
	plus = $3; sub(/^\+/, "", plus)
	split(plus, a, ",")
	nl = a[1] + 0
	inhunk = 1
	next
}
!inhunk { next }
/^\+/ { printf "%d ", nl; nl++; next }
/^ / { nl++ }
AWK

# Counts comment lines of one file at <head> whose line numbers are in `added`.
# kind is "shell", "justfile" (heredoc tracking on) or "other".
IFS= read -r -d '' count_prog <<'AWK' || true
function heredoc_opener(s,   i, n, c, q, j, tok) {
	n = length(s)
	q = ""
	ndelim = 0
	for (i = 1; i <= n; i++) {
		c = substr(s, i, 1)
		if (q != "") {
			if (q == "\"" && c == "\\") i++
			else if (c == q) q = ""
			continue
		}
		if (c == "\\") { i++; continue }
		if (c == "\"" || c == "'") { q = c; continue }
		if (c == "#" && (i == 1 || substr(s, i - 1, 1) ~ /[ \t;]/)) break
		if (substr(s, i, 2) == "((") {
			j = index(substr(s, i + 2), "))")
			if (j == 0) break
			i += j + 2
			continue
		}
		if (substr(s, i, 3) == "<<<") { i += 2; continue }
		if (substr(s, i, 2) == "<<") {
			if (!match(substr(s, i), /^<<-?[ \t]*["']?[A-Za-z0-9_][A-Za-z0-9_-]*["']?/)) break
			tok = substr(s, i, RLENGTH)
			i += RLENGTH - 1
			ndelim++
			dashes[ndelim] = (tok ~ /^<<-/)
			sub(/^<<-?[ \t]*["']?/, "", tok)
			sub(/["']$/, "", tok)
			delims[ndelim] = tok
		}
	}
	return ndelim
}
function is_terminator(s, k,   cmp) {
	cmp = s
	if (kind == "justfile") sub(/^[ \t]+/, "", cmp)
	else if (dashes[k]) sub(/^\t+/, "", cmp)
	return cmp == delims[k]
}
function counts(line, n) {
	if (n == 1 && line ~ /^#!/) return 0
	if (kind == "justfile" && line ~ /^[ \t]+#!/) return 0
	if (line ~ /^[ \t]*#[ \t]*(shellcheck|noqa|type:)/) return 0
	if (line ~ /^[ \t]*#[ \t]*(Copyright|SPDX-)/) return 0
	if (line ~ /TODO/ && (line ~ /https?:\/\// || line ~ /#[0-9]+/)) return 0
	return 1
}
BEGIN {
	nadd = split(added, parts, " ")
	for (k = 1; k <= nadd; k++) is_added[parts[k] + 0] = 1
}
{ L[NR] = $0 }
END {
	count = 0
	i = 1
	while (i <= NR) {
		line = L[i]
		if (line ~ /^[ \t]*#/) {
			if ((i in is_added) && counts(line, i)) count++
		} else if (kind != "other" && heredoc_opener(line)) {
			last = i
			for (k = 1; k <= ndelim; k++) {
				for (j = last + 1; j <= NR; j++)
					if (is_terminator(L[j], k)) break
				if (j > NR) break
				last = j
			}
			if (last > i) {
				i = last + 1
				continue
			}
		}
		i++
	}
	print count
}
AWK

names="$(mktemp)"
trap 'rm -f "$names"' EXIT
# Rename detection on, and each diff below names both sides, so a moved file
# counts only the lines its move changed, never its whole body. The file-type
# filter runs on the destination after Git pairs renames: a pathspec here would
# drop a source such as `x.txt` renamed to `x.sh`, and the rename would read as
# an addition of the whole file.
git diff --name-status -z --diff-filter=AMR -M --end-of-options "$base...$head" >"$names"

total=0
details=""
while IFS= read -r -d '' status; do
	IFS= read -r -d '' file
	old="$file"
	if [[ "$status" == R* ]]; then
		IFS= read -r -d '' file
	fi
	case "$file" in
	*.sh) kind="shell" ;;
	justfile | */justfile) kind="justfile" ;;
	*.py | *.jq) kind="other" ;;
	*) continue ;;
	esac
	added="$(git diff -U0 --no-color --no-ext-diff -M --end-of-options "$base...$head" -- "$old" "$file" |
		awk "$added_prog")"
	[[ -n "$added" ]] || continue
	n="$(git show --end-of-options "$head:$file" | awk -v kind="$kind" -v added="$added" "$count_prog")"
	if [[ "$n" -gt 0 ]]; then
		total=$((total + n))
		details="${details}${n} ${file}"$'\n'
	fi
done <"$names"

if [[ "$verbose" -eq 1 ]]; then
	printf '%s' "$details"
	echo "total $total"
else
	echo "$total"
fi
