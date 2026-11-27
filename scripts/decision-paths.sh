#!/usr/bin/env bash
# decision-paths.sh — the decision selector's path set, read by git from the
# exact patch the Architecture Lens is given.
#
# Usage:
#   decision-paths.sh [--output <file>] < <patch file>
#
# stdin is one patch: the text of the `git diff` or `gh pr diff` whose output
# the lens reviews. Callers write the diff to a file and run this script only
# after the diff command exited 0, never in a pipe after it: a diff that
# prints one complete file patch and then fails would otherwise leave a
# complete-looking, incomplete list. The script writes a JSON array of every path that patch
# changes, sorted and unique: both paths of a rename or copy, the removed path
# of a deletion, a mode-only change and a binary change. An empty patch gives
# `[]`.
#
# Git parses the patch, never this script. A `diff --git` header is a display
# format: a name holding ` b/` cannot be split at the first ` b/`, and git
# C-quotes a non-ASCII or special name ("a/na\303\257ve.py"). The paths come
# from `git apply --numstat -z`, which reads the same patch text and prints
# each name unquoted and NUL-terminated. It names one path per patch: the new
# path, or the old path of a deletion. A second pass over the same text with
# -R (the patch reversed) names the old path of every rename and copy. The
# union of the two passes is every path the patch changes.
#
# The result does not depend on the caller's directory or diff config:
#   - git apply skips every file patch outside the current directory, so it
#     runs from the work tree's top level (`git rev-parse --show-toplevel`),
#     whatever directory the script is called from; outside a work tree the
#     script refuses (exit 1).
#   - git apply strips one leading component (-p1), which is right only for a
#     patch whose names carry the `a/` and `b/` prefixes. A `diff.noprefix`,
#     `diff.mnemonicPrefix` or custom `diff.srcPrefix`/`diff.dstPrefix` diff
#     would lose a real directory instead, so every `diff --git` header is
#     checked before git reads the patch: the old name must start `a/` and the
#     new name `b/` (C-quoted names inside the quotes), and the two must be the
#     same name, or the names of the patch's `rename from`/`rename to` (or
#     `copy from`/`copy to`) lines. A patch that fails is refused (exit 1).
#     Producers pin the prefixes (`git diff --src-prefix=a/ --dst-prefix=b/`);
#     a patch made with prefixes that themselves start `a/<dir>/` and
#     `b/<dir>/` is text-identical to a standard one and cannot be told apart.
#   - git apply must name one file per `diff --git` header; any other count
#     means it skipped or invented a file patch (exit 1).
# Empty input (zero bytes, the diff of a range that changes nothing) is `[]`;
# input that is not empty but holds no `diff --git` header is refused (exit 1).
#
#   --output <file>  create <file> once and write the array there; an existing
#                    <file> (a symlink included) is never rewritten. A run's
#                    decision paths file is written once, with its lens
#                    assignment, so a second write for the same run is refused.
#                    Without it the array goes to stdout.
#
# Exit codes:
#   0  the array is written
#   1  degraded: the script is not run inside a git work tree; the patch is
#      not empty but holds no `diff --git` header, or a header lacks the
#      `a/`/`b/` prefixes; git cannot parse the patch, or names a different
#      number of files than the patch has headers; a record is not in the
#      numstat form; or a path holds a newline or is not valid UTF-8 (a JSON
#      string cannot carry it byte for byte); stderr carries
#      `decision-paths.sh: DECISION-PATHS-UNREADABLE: <why>` and nothing is
#      written
#   2  usage error, or git or jq is missing
#   3  --output names a file that exists, or it cannot be created there
#   4  internal failure: a command failed unexpectedly; stderr carries the
#      fixed reason `decision-paths.sh: DECISION-PATHS-INTERNAL`
set -euo pipefail
unset CDPATH
# Byte semantics: a path is read and compared byte for byte.
export LC_ALL=C

dp_documented=0
quit() {
	dp_documented=1
	exit "$1"
}
patch_tmp=""
raw_tmp=""
err_tmp=""
list_tmp=""
json_tmp=""
out_tmp=""
# shellcheck disable=SC2329  # invoked by the EXIT trap
dp_on_exit() {
	local rc=$?
	set +e
	rm -f -- "$patch_tmp" "$raw_tmp" "$err_tmp" "$list_tmp" "$json_tmp" "$out_tmp" 2>/dev/null
	if [[ $rc -ne 0 && $dp_documented -ne 1 ]]; then
		echo "decision-paths.sh: DECISION-PATHS-INTERNAL" >&2 2>/dev/null
		rc=4
	fi
	exit "$rc"
}
trap dp_on_exit EXIT

# internal: an unexpected failure; the EXIT trap prints the fixed reason and
# exits 4.
internal() {
	exit 4
}
usage() {
	echo "usage: decision-paths.sh [--output <file>] < patch" >&2
	quit 2
}
unreadable() {
	echo "decision-paths.sh: DECISION-PATHS-UNREADABLE: $1" >&2
	quit 1
}

output=""
while [[ $# -gt 0 ]]; do
	case "$1" in
	--output)
		[[ $# -ge 2 && -n "$2" ]] || usage
		output="$2"
		shift 2
		;;
	*) usage ;;
	esac
done
for tool in git jq; do
	command -v "$tool" >/dev/null 2>&1 || {
		echo "decision-paths.sh: $tool is not installed" >&2
		quit 2
	}
done
if [[ -n "$output" && (-e "$output" || -L "$output") ]]; then
	echo "decision-paths.sh: $output exists; a run's decision paths are written once" >&2
	quit 3
fi

patch_tmp="$(mktemp "${TMPDIR:-/tmp}/skein-decision-patch.XXXXXX")"
raw_tmp="$(mktemp "${TMPDIR:-/tmp}/skein-decision-numstat.XXXXXX")"
err_tmp="$(mktemp "${TMPDIR:-/tmp}/skein-decision-err.XXXXXX")"
list_tmp="$(mktemp "${TMPDIR:-/tmp}/skein-decision-list.XXXXXX")"
json_tmp="$(mktemp "${TMPDIR:-/tmp}/skein-decision-json.XXXXXX")"
cat >"$patch_tmp"

# git apply skips file patches outside the current directory: read the patch
# from the top level, never from the caller's directory.
if ! top="$(git rev-parse --show-toplevel 2>/dev/null)" || [[ -z $top || ! -d $top ]]; then
	unreadable "not inside a git work tree"
fi

# check_headers: prints the number of `diff --git` headers when each carries
# the a/ and b/ prefixes over one name (or a rename's or copy's two names);
# exits 1 at the first header that does not.
# shellcheck disable=SC2016  # awk program
check_headers() {
	awk '
	function q(prefix, name) {
		return substr(name, 1, 1) == "\"" ? "\"" prefix substr(name, 2) : prefix name
	}
	function check(   rest, n, mid, l, r) {
		if (hdr == "") return
		rest = substr(hdr, 12)
		if (from != "" || to != "") {
			if (from == "" || to == "" || rest != q("a/", from) " " q("b/", to)) bad = 1
		} else {
			n = length(rest)
			mid = (n + 1) / 2
			l = substr(rest, 1, mid - 1)
			r = substr(rest, mid + 1)
			if (n % 2 == 0 || substr(rest, mid, 1) != " ") bad = 1
			else if (substr(l, 1, 1) == "\"") {
				if (substr(l, 1, 3) != "\"a/" || substr(r, 1, 3) != "\"b/" || substr(l, 4) != substr(r, 4)) bad = 1
			} else if (substr(l, 1, 2) != "a/" || substr(r, 1, 2) != "b/" || substr(l, 3) != substr(r, 3)) bad = 1
		}
		if (bad) exit 1
	}
	/^diff --git / { check(); hdr = $0; from = ""; to = ""; ext = 1; headers++; next }
	ext && /^(rename|copy) from / { from = $0; sub(/^(rename|copy) from /, "", from); next }
	ext && /^(rename|copy) to / { to = $0; sub(/^(rename|copy) to /, "", to); next }
	ext && /^(old mode|new mode|deleted file mode|new file mode|similarity index|dissimilarity index|index) / { next }
	{ ext = 0 }
	END { if (bad) exit 1; check(); if (bad) exit 1; print headers + 0 }
	' "$patch_tmp"
}

if [[ -s "$patch_tmp" ]]; then
	hdr_rc=0
	headers="$(check_headers)" || hdr_rc=$?
	[[ $hdr_rc -ne 1 ]] || unreadable "a diff --git header lacks the a/ and b/ prefixes"
	[[ $hdr_rc -eq 0 && $headers =~ ^[0-9]+$ ]] || internal
	[[ $headers -gt 0 ]] || unreadable "the patch holds no diff --git header"
	for direction in forward reverse; do
		reverse=()
		[[ $direction == reverse ]] && reverse=(-R)
		# --numstat reads the patch and applies nothing; --whitespace=nowarn
		# keeps an apply.whitespace=error setting from refusing a patch.
		if ! git -C "$top" apply --numstat -z -p1 --whitespace=nowarn ${reverse[@]+"${reverse[@]}"} <"$patch_tmp" >>"$raw_tmp" 2>"$err_tmp"; then
			cat -- "$err_tmp" >&2 || true
			unreadable "git apply cannot parse the patch"
		fi
		if [[ $direction == forward ]]; then
			named="$(tr -cd '\000' <"$raw_tmp" | wc -c | tr -d ' ')"
			[[ $named =~ ^[0-9]+$ ]] || internal
			[[ $named -eq $headers ]] || unreadable "git apply named $named files for $headers diff --git headers"
		fi
	done
fi

# Each record is `<added>\t<deleted>\t<path>`; the counts are digits or `-`.
numstat_re=$'^[-0-9]+\t[-0-9]+\t'
while IFS= read -r -d '' record; do
	[[ $record =~ $numstat_re ]] || unreadable "a git apply record is not in the numstat form"
	path="${record#*$'\t'}"
	path="${path#*$'\t'}"
	[[ -n $path ]] || unreadable "a git apply record names no path"
	[[ $path != *$'\n'* ]] || unreadable "a changed path holds a newline"
	printf '%s\n' "$path" >>"$list_tmp"
done <"$raw_tmp"

sort -u -o "$list_tmp" -- "$list_tmp"
jq -R . <"$list_tmp" | jq -cs . >"$json_tmp"
# jq replaces a byte that is not UTF-8 with U+FFFD, so a path survives the
# JSON form only when decoding it gives the same bytes back.
if ! jq -r '.[]' <"$json_tmp" | cmp -s - "$list_tmp"; then
	unreadable "a changed path is not valid UTF-8"
fi

if [[ -z "$output" ]]; then
	cat -- "$json_tmp"
	quit 0
fi
# Create the output exclusively: a hard link fails when the name exists, so a
# concurrent or repeated write never replaces a run's decision paths.
out_dir="$(dirname -- "$output")"
if ! out_tmp="$(mktemp "$out_dir/.decision-paths.XXXXXX" 2>/dev/null)"; then
	out_tmp=""
	echo "decision-paths.sh: cannot create a file in $out_dir" >&2
	quit 3
fi
cat -- "$json_tmp" >"$out_tmp"
if ! ln -- "$out_tmp" "$output" 2>/dev/null; then
	echo "decision-paths.sh: $output exists or cannot be created; a run's decision paths are written once" >&2
	quit 3
fi
quit 0
