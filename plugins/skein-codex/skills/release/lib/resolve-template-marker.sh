#!/usr/bin/env bash
# resolve-template-marker.sh — Audit Step A2's classification-source resolution
# (three-pattern marker search, dual-anchor binding, tracked-mode gate, current
# template fallback) plus the ok/drifted comparison, extracted from SKILL.md
# prose. Pure over injected inputs (grilled decision 9): the gh / ls-remote
# fetches stay in SKILL.md and their results arrive as files; the only git the
# script runs is read-only inspection of the explicit --repo, through the
# pinned RELEASE_GIT. Pinned jq arrives in RELEASE_JQ. Stdout is JSON
# (decision 12) carrying classification fields only.
#
# Usage:
#   resolve-template-marker.sh --site a2-classify --repo DIR --release-list FILE
#       --bodies-dir DIR --peeled FILE --changelog FILE --web-base-url URL
#     Body for tag T is <bodies-dir>/T.md, else <bodies-dir>/T.lf.md.
#   resolve-template-marker.sh --site step3-recovery --repo DIR --tag TAG
#       --body-file FILE --peeled FILE
#     Emits only the marker decision for one body (no ok/drifted comparison).
#
# Exit: 0 classified, 1 validation failure (malformed input), 2 environment.

# jq programs are single-quoted on purpose (they contain $vars for jq).
# shellcheck disable=SC2016
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugins/skein/skills/release/lib/release-common.sh
. "$HERE/release-common.sh"

SCRIPT="resolve-template-marker"
site="" repo="" list="" bodies="" peeled="" changelog="" web="" tag="" body_file=""

die() { # code decision gate
	echo "resolve-template-marker.sh: $1" >&2
	release_emit "$SCRIPT" "${site:-unknown}" "$3" "$2" "${4-}" null untemplated
	exit "$2"
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--site) site="${2-}" ;;
	--repo) repo="${2-}" ;;
	--release-list) list="${2-}" ;;
	--bodies-dir) bodies="${2-}" ;;
	--peeled) peeled="${2-}" ;;
	--changelog) changelog="${2-}" ;;
	--web-base-url) web="${2-}" ;;
	--tag) tag="${2-}" ;;
	--body-file) body_file="${2-}" ;;
	*) die "unknown argument: $1" 2 environment-failure bad-arguments ;;
	esac
	shift 2 || die "missing value for an argument" 2 environment-failure bad-arguments
done

case "$site" in
a2-classify | step3-recovery) ;;
*) die "unknown --site" 2 environment-failure bad-arguments ;;
esac
release_require_exe RELEASE_JQ || die "RELEASE_JQ must be an absolute executable path" 2 environment-failure jq-unresolvable
release_require_exe RELEASE_GIT || die "RELEASE_GIT must be an absolute executable path" 2 environment-failure git-unresolvable
JQ="$RELEASE_JQ"
GIT="$RELEASE_GIT"
[[ -d "$repo" ]] || die "--repo is not a directory" 2 environment-failure repo-unreadable
[[ -r "$peeled" ]] || die "--peeled unreadable" 2 environment-failure input-unreadable

TPATH=".release-template.json"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/release-marker.XXXXXX")" || die "mktemp failed" 2 environment-failure tmpdir
trap 'rm -rf "$tmp"' EXIT

g() { "$GIT" -C "$repo" "$@"; }

# HEAD is resolved once for the whole check (single-resolution rule).
HEAD_SHA="$(g rev-parse HEAD 2>/dev/null)" || die "cannot resolve HEAD" 2 environment-failure head-unresolvable
[[ "$HEAD_SHA" =~ ^[0-9a-f]{40}$ ]] || die "SHA-256 (or other non-SHA-1) repositories are not supported" 1 hard-stop non-sha1-repository

# anchor_blob <commit> — tracked-mode gate + blob SHA. Sets ANCHOR_STATE to
# one of: resolved, mode:<mode>, unresolved, and ANCHOR_BLOB to the blob SHA
# when resolved (globals, not stdout, so callers keep the state).
anchor_blob() {
	local commit="$1" line count meta mode type
	ANCHOR_STATE="unresolved"
	ANCHOR_BLOB=""
	[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || return 0
	line="$(g ls-tree "$commit" -- "$TPATH" 2>/dev/null)" || return 0
	count="$(printf '%s' "$line" | grep -c .)"
	[[ "$count" == 1 ]] || return 0
	meta="${line%%$'\t'*}"
	mode="${meta%% *}"
	type="$(printf '%s' "$meta" | awk '{print $2}')"
	if [[ "$type" != "blob" || ("$mode" != "100644" && "$mode" != "100755") ]]; then
		ANCHOR_STATE="mode:$mode"
		return 0
	fi
	ANCHOR_BLOB="$(g rev-parse --verify --quiet "$commit:$TPATH" 2>/dev/null)" || return 0
	ANCHOR_STATE="resolved"
}

# Current-template presence (two-sided, decision 18) for the marker-absent fallback.
CUR_STATE="absent" # absent | valid | invalid:<note>
CUR_FILE="$tmp/current-template.json"
resolve_current_template() {
	local head_line wt=0
	head_line="$(g ls-tree "$HEAD_SHA" -- "$TPATH" 2>/dev/null)"
	[[ -e "$repo/$TPATH" || -L "$repo/$TPATH" ]] && wt=1
	if [[ "$wt" == 0 && -z "$head_line" ]]; then
		CUR_STATE="absent"
		return 0
	fi
	if [[ -z "$(g ls-files -- "$TPATH")" ]] || ! g diff --quiet "$HEAD_SHA" -- "$TPATH" 2>/dev/null; then
		CUR_STATE="invalid:current template failed the commit precondition"
		return 0
	fi
	local blob
	anchor_blob "$HEAD_SHA"
	blob="$ANCHOR_BLOB"
	if [[ "$ANCHOR_STATE" != "resolved" ]]; then
		CUR_STATE="invalid:current template entry is not a regular-file blob"
		return 0
	fi
	g cat-file blob "$blob" >"$CUR_FILE" 2>/dev/null || {
		CUR_STATE="invalid:current template unreadable"
		return 0
	}
	local gate
	if gate="$(release_validate_gates "$JQ" "$CUR_FILE")"; then
		CUR_STATE="valid"
	else
		CUR_STATE="invalid:validation gate failed: $gate"
	fi
}

# resolve_source <tag> <body-file> — sets SRC_KIND (marker|current|canonical|
# unresolvable), SRC_NOTE, and SRC_FILE (template JSON when kind marker/current).
resolve_source() {
	local tagname="$1" body="$2"
	local strict loose shape sha final_ok
	SRC_KIND="canonical"
	SRC_NOTE=""
	SRC_FILE=""
	strict="$(grep -a -c -E '^<!-- release-template-sha: [0-9a-f]{40} -->$' "$body")"
	loose="$(grep -a -c -E '^<!-- release-template-sha: [0-9a-f]+ -->$' "$body")"
	shape="$(grep -a -c -E '^<!-- release-template-sha:.*-->$' "$body")"
	if [[ "$shape" == 0 ]]; then
		resolve_current_template
		case "$CUR_STATE" in
		absent) SRC_KIND="canonical" ;;
		valid)
			SRC_KIND="current"
			SRC_FILE="$CUR_FILE"
			;;
		*)
			SRC_KIND="unresolvable"
			SRC_NOTE="${CUR_STATE#invalid:}"
			;;
		esac
		return 0
	fi
	SRC_KIND="unresolvable"
	if ((strict >= 2 || shape >= 2)); then
		SRC_NOTE="marker line appears more than once"
		return 0
	fi
	if [[ "$strict" == 0 && "$loose" -ge 1 ]]; then
		SRC_NOTE="marker present but hash length unsupported (expected 40 hex characters)"
		return 0
	fi
	if [[ "$strict" == 0 ]]; then
		SRC_NOTE="marker present but hash is not lowercase hexadecimal"
		return 0
	fi
	final_ok="$(tail -n 1 "$body" | grep -a -c -E '^<!-- release-template-sha: [0-9a-f]{40} -->$')"
	if [[ "$final_ok" != 1 ]]; then
		SRC_NOTE="marker-shaped line is not the body's final line"
		return 0
	fi
	sha="$(grep -a -E '^<!-- release-template-sha: [0-9a-f]{40} -->$' "$body" | sed -E 's/^<!-- release-template-sha: ([0-9a-f]{40}) -->$/\1/')"
	local peeled_sha origin_blob="" head_blob="" o_state h_state matched=0 mode_note=""
	peeled_sha="$("$JQ" -r --arg t "$tagname" '.[$t] // empty' <"$peeled" 2>/dev/null)"
	if [[ -n "$peeled_sha" ]]; then
		anchor_blob "$peeled_sha"
		origin_blob="$ANCHOR_BLOB"
		o_state="$ANCHOR_STATE"
	else
		o_state="unresolved"
	fi
	anchor_blob "$HEAD_SHA"
	head_blob="$ANCHOR_BLOB"
	h_state="$ANCHOR_STATE"
	[[ "$o_state" == resolved && "$origin_blob" == "$sha" ]] && matched=1
	[[ "$h_state" == resolved && "$head_blob" == "$sha" ]] && matched=1
	if [[ "$matched" == 0 ]]; then
		[[ "$o_state" == mode:* ]] && mode_note="${o_state#mode:}"
		[[ -z "$mode_note" && "$h_state" == mode:* ]] && mode_note="${h_state#mode:}"
		if [[ -n "$mode_note" ]]; then
			SRC_NOTE="anchor entry is not a regular-file blob (mode $mode_note)"
		elif [[ "$o_state" == resolved || "$h_state" == resolved ]]; then
			SRC_NOTE="anchor resolved but SHA mismatched"
		else
			SRC_NOTE="neither anchor resolved (object or path absent in this clone)"
		fi
		return 0
	fi
	[[ "$(g cat-file -t "$sha" 2>/dev/null)" == "blob" ]] || {
		SRC_NOTE="marker blob is not a blob object"
		return 0
	}
	SRC_FILE="$tmp/marker-template.json"
	g cat-file -p "$sha" >"$SRC_FILE" 2>/dev/null || {
		SRC_NOTE="marker blob unreadable"
		return 0
	}
	local gate
	if ! gate="$(release_validate_gates "$JQ" "$SRC_FILE")"; then
		SRC_NOTE="validation gate failed: $gate"
		return 0
	fi
	SRC_KIND="marker"
}

if [[ "$site" == "step3-recovery" ]]; then
	[[ -r "$body_file" && -n "$tag" ]] || die "--tag and --body-file are required" 2 environment-failure input-unreadable
	resolve_source "$tag" "$body_file"
	case "$SRC_KIND" in
	marker) release_emit "$SCRIPT" "$site" "marker-bound" 0 "" null templated ;;
	current) release_emit "$SCRIPT" "$site" "marker-absent-current-template" 0 "" null templated ;;
	canonical) release_emit "$SCRIPT" "$site" "marker-absent-canonical" 0 "" null untemplated ;;
	*) release_emit "$SCRIPT" "$site" "template-marker-unresolvable" 0 "$SRC_NOTE" null templated ;;
	esac
	exit 0
fi

[[ -r "$list" && -d "$bodies" && -r "$changelog" && -n "$web" ]] || die "a2-classify inputs missing or unreadable" 2 environment-failure input-unreadable
"$JQ" -e 'type == "array"' <"$list" >/dev/null 2>&1 || die "release list is not a JSON array" 1 gate-failed release-list-shape
repo_name="${web##*/}"

# section <version> — the CHANGELOG section body (header stripped), edges trimmed.
section() {
	awk -v want="## [$1]" '
		index($0, want) == 1 { on = 1; next }
		/^## \[/ { on = 0 }
		on { print }
	' "$changelog" | trim_edges
}
trim_edges() {
	awk '{ l[NR] = $0 } END {
		s = 1; while (s <= NR && l[s] ~ /^[[:space:]]*$/) s++
		e = NR; while (e >= s && l[e] ~ /^[[:space:]]*$/) e--
		for (i = s; i <= e; i++) print l[i]
	}'
}
# drop_excluded <template-json> — filters the section on stdin by excluded_sections.
drop_excluded() {
	local excl="$tmp/excl.txt"
	"$JQ" -r '(.excluded_sections // [])[]' <"$1" >"$excl"
	awk -v exfile="$excl" '
		BEGIN { while ((getline l < exfile) > 0) ex[l] = 1 }
		/^### / { skip = ($0 in ex) }
		!skip { print }
	' | trim_edges
}

all_tags="$("$JQ" -r 'keys[]' <"$peeled" | sed -E 's/\^\{\}$//;s#^refs/tags/##' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V)"
rows="[]"
any_templated=0
while IFS= read -r t; do
	[[ "$t" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
	ver="${t#v}"
	name="$("$JQ" -r --arg t "$t" '.[] | select(.tagName == $t) | .name' <"$list" | head -n 1)"
	bfile="$bodies/$t.md"
	[[ -r "$bfile" ]] || bfile="$bodies/$t.lf.md"
	[[ -r "$bfile" ]] || die "no body file for $t" 2 environment-failure input-unreadable
	resolve_source "$t" "$bfile"
	status="ok" note=""
	case "$SRC_KIND" in
	unresolvable)
		status="template-marker-unresolvable"
		note="$SRC_NOTE"
		any_templated=1
		;;
	*)
		[[ "$SRC_KIND" != canonical ]] && any_templated=1
		title_format="canonical" label="Full diff"
		if [[ -n "$SRC_FILE" ]]; then
			title_format="$("$JQ" -r '.title_format // "canonical"' <"$SRC_FILE")"
			label="$("$JQ" -r '.compare_line_label // "Full diff"' <"$SRC_FILE")"
		fi
		want_section="$tmp/want.txt"
		if [[ -n "$SRC_FILE" ]]; then
			section "$ver" | drop_excluded "$SRC_FILE" >"$want_section"
		else
			section "$ver" >"$want_section"
		fi
		# Body: strip a trailing marker, an optional What's New paragraph, and the compare line.
		got="$tmp/got.txt"
		grep -a -v -E '^<!-- release-template-sha:.*-->$' "$bfile" >"$got.0"
		awk 'NR == 1 && /^## What.s New$/ { skip = 1; state = 0; next }
			skip && state == 0 && /^[[:space:]]*$/ { state = 1; next }
			skip && state == 1 && !/^[[:space:]]*$/ { state = 2; next }
			skip && state == 2 && /^[[:space:]]*$/ { skip = 0; next }
			skip { next }
			{ print }' "$got.0" | trim_edges >"$got.1"
		prev="$(printf '%s\n' "$all_tags" | awk -v c="$t" '$0 == c { print prev; exit } { prev = $0 }')"
		compare_ok=1
		if [[ "$label" == "none" ]]; then
			grep -a -q -E '^\*\*Full (diff|changelog):\*\*' "$got.1" && compare_ok=0
			cp "$got.1" "$got"
		else
			nlines="$(grep -a -c -E '^\*\*Full (diff|changelog):\*\*' "$got.1")"
			if [[ -n "$prev" ]]; then
				expected="**$label:** $web/compare/$prev...$t"
				if [[ "$nlines" == 1 && "$(tail -n 1 "$got.1")" == "$expected" ]]; then
					sed '$d' "$got.1" | trim_edges >"$got"
				else
					compare_ok=0
					cp "$got.1" "$got"
				fi
			else
				[[ "$nlines" == 0 ]] || compare_ok=0
				cp "$got.1" "$got"
			fi
		fi
		title_ok=0
		if [[ "$title_format" == "bare" ]]; then
			[[ "$name" == "$t" ]] && title_ok=1
		else
			[[ "$name" == "$repo_name $t — "?* ]] && title_ok=1
		fi
		if [[ "$title_ok" == 1 && "$compare_ok" == 1 ]] && cmp -s "$got" "$want_section"; then
			status="ok"
		else
			status="drifted"
		fi
		;;
	esac
	rows="$("$JQ" -c --arg v "$ver" --arg s "$status" --arg n "$note" '. + [{version: $v, status: $s, note: (if $n == "" then null else $n end)}]' <<<"$rows")"
done < <("$JQ" -r '.[].tagName' <"$list")

case_name="untemplated"
[[ "$any_templated" == 1 ]] && case_name="templated"
release_emit "$SCRIPT" "$site" "classified" 0 "" "$("$JQ" -c 'sort_by(.version)' <<<"$rows")" "$case_name"
