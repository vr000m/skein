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
#       --head-sha 40-HEX
#     Body for tag T is <bodies-dir>/T.md, else <bodies-dir>/T.lf.md.
#   resolve-template-marker.sh --site step3-recovery --repo DIR --tag TAG
#       --body-file FILE --peeled FILE --head-sha 40-HEX
#     Emits only the marker decision for one body (no ok/drifted comparison).
#   --head-sha is REQUIRED at both sites: the caller resolves HEAD once
#     (SKILL.md's single-resolution rule) and passes the literal SHA in; this
#     script never self-resolves HEAD, matching read-release-template.sh's
#     strict contract.
#   --peeled FILE is a JSON object of {"vX.Y.Z": "<40-hex origin peeled-commit
#     SHA>"} — bare tag names as keys, gated by both call sites; never
#     `refs/tags/vX.Y.Z^{}` ls-remote-style keys.
#
# Exit: 0 classified, 1 validation failure (malformed input), 2 environment.

# jq programs are single-quoted on purpose (they contain $vars for jq).
# shellcheck disable=SC2016
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugins/skein/skills/release/lib/release-common.sh
. "$HERE/release-common.sh"

SCRIPT="resolve-template-marker"
site="" repo="" list="" bodies="" peeled="" changelog="" web="" tag="" body_file="" head_sha=""

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
	--head-sha) head_sha="${2-}" ;;
	*) die "unknown argument: $1" 2 environment-failure bad-arguments ;;
	esac
	shift 2 || die "missing value for an argument" 2 environment-failure bad-arguments
done

case "$site" in
a2-classify | step3-recovery) ;;
*) die "unknown --site" 2 environment-failure bad-arguments ;;
esac
release_require_exe RELEASE_GIT || die "RELEASE_GIT must be an absolute executable path" 2 environment-failure git-unresolvable
GIT="$RELEASE_GIT"
# jq is the pinned set's one CONDITIONAL member (SKILL.md's pinned-executable
# invariant): it is resolved only once a candidate actually reaches a gate run
# or a jq-parsed input. A markerless step3-recovery in an untemplated repo
# reaches neither, so requiring RELEASE_JQ up front would hard-stop a run that
# never uses jq. a2-classify parses its release-list/peeled JSON with jq
# unconditionally, so it pins immediately.
JQ=""
need_jq() {
	[[ -n "$JQ" ]] && return 0
	release_require_exe RELEASE_JQ || die "RELEASE_JQ must be an absolute executable path" 2 environment-failure jq-unresolvable
	JQ="$RELEASE_JQ"
}
[[ "$site" == "a2-classify" ]] && need_jq
[[ -d "$repo" ]] || die "--repo is not a directory" 2 environment-failure repo-unreadable
[[ -r "$peeled" ]] || die "--peeled unreadable" 2 environment-failure input-unreadable

TPATH=".release-template.json"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/release-marker.XXXXXX")" || die "mktemp failed" 2 environment-failure tmpdir
trap 'rm -rf "$tmp"' EXIT

g() { "$GIT" -C "$repo" "$@"; }

# HEAD is resolved ONCE by the caller (SKILL.md's single-resolution rule,
# Step 1b) and passed in as --head-sha, matching read-release-template.sh's
# now-strict pure contract: this script must never self-resolve HEAD. Doing so
# here would be a second, independent resolution of the same symbolic ref the
# caller already resolved for the whole audit, exactly the failure mode the
# single-resolution rule exists to close (a commit/checkout/rebase landing
# between the two resolutions binds this script's reads to a different commit
# than the one the caller reported).
[[ -n "$head_sha" ]] || die "--head-sha is required" 2 environment-failure bad-arguments
HEAD_SHA="$head_sha"
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
	local head_line head_rc wt=0
	# Tri-state, fail-closed (SKILL.md Step 1b item 2): exit zero with empty
	# output is the only clean *absent*; exit zero with exactly one entry is
	# *present*; anything else (nonzero exit, more than one line) leaves the
	# committed-object question UNANSWERED and must never be read as absence.
	head_line="$(g ls-tree "$HEAD_SHA" -- "$TPATH" 2>/dev/null)"
	head_rc=$?
	[[ -e "$repo/$TPATH" || -L "$repo/$TPATH" ]] && wt=1
	if [[ "$head_rc" != 0 ]]; then
		CUR_STATE="invalid:committed-object presence for the current template could not be resolved"
		return 0
	fi
	if [[ -n "$head_line" && "$(printf '%s' "$head_line" | grep -c .)" != 1 ]]; then
		CUR_STATE="invalid:committed-object presence for the current template is ambiguous (more than one entry)"
		return 0
	fi
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
	need_jq
	if gate="$(release_validate_gates "$JQ" "$CUR_FILE")"; then
		CUR_STATE="valid"
	else
		CUR_STATE="invalid:validation gate failed: $gate"
	fi
}

# resolve_source <tag> <body-file> — sets SRC_KIND (marker|current|canonical|
# unresolvable), SRC_NOTE, SRC_FILE (template JSON when kind marker/current),
# and SRC_SCAN (the CR-normalized body path — every downstream reader of "the
# body", not just marker detection, must read this path, never the raw
# <body-file>, or a CRLF body drifts between the two byte streams).
resolve_source() {
	local tagname="$1" body="$2"
	local strict loose shape sha final_ok
	SRC_KIND="canonical"
	SRC_NOTE=""
	SRC_FILE=""
	# A release body fetched from GitHub may carry CRLF line endings (fixture
	# decision 19 commits both variants). Every marker pattern below anchors on
	# `-->$`, so a single trailing CR would defeat all three and silently drop a
	# marker-bearing body into the marker-absent fallback. Normalise a lone
	# trailing CR per line first; the marker decision is then identical to the
	# LF body's, which is the byte-for-byte invariant the CRLF fixture pins.
	# SRC_SCAN is set unconditionally, before any early return below, because
	# every caller that reaches the ok/drifted comparison (not just marker
	# detection) must read this same normalized stream.
	local scan="$tmp/body-lf.txt"
	sed $'s/\r$//' <"$body" >"$scan"
	SRC_SCAN="$scan"
	strict="$(grep -a -c -E '^<!-- release-template-sha: [0-9a-f]{40} -->$' "$scan")"
	loose="$(grep -a -c -E '^<!-- release-template-sha: [0-9a-f]+ -->$' "$scan")"
	shape="$(grep -a -c -E '^<!-- release-template-sha:.*-->$' "$scan")"
	if [[ "$shape" == 0 ]]; then
		# Step 3 recovery (SKILL.md Step 3 item 1): "If there are zero strict
		# markers, use the no-template sentinel." The current-template fallback
		# belongs to Audit Step A2 alone — recovery of an ALREADY-PUBLISHED body
		# must be parametrized by the shape it was cut under, never by whatever
		# `.release-template.json` currently reads.
		if [[ "$site" == "step3-recovery" ]]; then
			SRC_KIND="canonical"
			return 0
		fi
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
	final_ok="$(tail -n 1 "$scan" | grep -a -c -E '^<!-- release-template-sha: [0-9a-f]{40} -->$')"
	if [[ "$final_ok" != 1 ]]; then
		SRC_NOTE="marker-shaped line is not the body's final line"
		return 0
	fi
	sha="$(grep -a -E '^<!-- release-template-sha: [0-9a-f]{40} -->$' "$scan" | sed -E 's/^<!-- release-template-sha: ([0-9a-f]{40}) -->$/\1/')"
	local peeled_sha origin_blob="" head_blob="" o_state h_state matched=0 mode_note=""
	need_jq
	# --peeled's keys are bare `vX.Y.Z` tag names (the fixtures' shape, and the
	# ONE format this script reads — see the top-of-file --peeled usage note).
	# Gate the shape once per run, lazily, right before the first read: an
	# object whose values are all strings. A malformed entry must fail closed
	# the same way the release-list gate does, never silently read as
	# "unresolved" (an unset/wrong-type value and a genuinely absent tag both
	# jq-select to empty, which is indistinguishable without this gate).
	if [[ -z "${PEELED_SHAPE_OK:-}" ]]; then
		"$JQ" -e 'type == "object" and all(.[]; type == "string")' <"$peeled" >/dev/null 2>&1 ||
			die "--peeled is not a JSON object of {tagName: sha} strings" 1 gate-failed peeled-shape
		PEELED_SHAPE_OK=1
	fi
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
# SKILL.md Step A1 item 3: the release inventory is valid only when it parses as
# a top-level JSON array whose EVERY entry carries string `tagName` and `name`
# fields. A shape-only check would let a missing/non-string `name` through and
# classify a candidate against an empty title — fail closed instead.
"$JQ" -e 'type == "array" and all(.[]; type == "object" and (.tagName | type) == "string" and (.name | type) == "string")' \
	<"$list" >/dev/null 2>&1 || die "release list is not a JSON array of {tagName,name} strings" 1 gate-failed release-list-shape
repo_name="${web##*/}"

# section <version> — the CHANGELOG section body (header stripped), edges
# trimmed. SKILL.md's A2 `ok`/`drifted` bullet extracts with "Step 1's exact
# extraction+tolerant-matching logic", so a strict miss retries tolerating
# whitespace/punctuation drift in the header (Step 1 item 5) before giving up.
section() {
	local out
	out="$(section_exact "$1")"
	[[ -n "$out" ]] || out="$(section_tolerant "$1")"
	[[ -n "$out" ]] && printf '%s\n' "$out"
	return 0
}
section_exact() {
	awk -v want="## [$1]" '
		index($0, want) == 1 { on = 1; next }
		/^## \[/ { on = 0 }
		on { print }
	' "$changelog" | trim_edges
}
# Tolerant retry: compare the header with all whitespace removed, so `##  [1.0.0]`
# and `## [ 1.0.0 ] – date` match `## [1.0.0]` the way Step 1 item 5 requires.
section_tolerant() {
	awk -v want="##[$1]" '
		function squash(s) { gsub(/[[:space:]]/, "", s); return s }
		/^[[:space:]]*##[[:space:]]*\[/ {
			on = (index(squash($0), want) == 1)
			next
		}
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

# SKILL.md Step A1 item 4: only STRICT `vX.Y.Z` names enter the T/R/C union —
# each component rejects a leading zero, so `v01.2.3` is a `non-release-tag`,
# not a release row.
SEMVER_TAG='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
# --peeled's keys are bare `vX.Y.Z` tag names (see resolve_source's PEELED_SHAPE_OK
# gate above) — never `refs/tags/vX.Y.Z^{}` ls-remote-style keys. The strip that
# used to run here for that other shape was dead code against every fixture and
# is deliberately gone: this is the one format both --peeled call sites (this
# line and resolve_source's per-candidate lookup) agree on.
all_tags="$("$JQ" -r 'keys[]' <"$peeled" | grep -E "$SEMVER_TAG" | sort -V)"
rows="[]"
any_templated=0
while IFS= read -r t; do
	[[ "$t" =~ $SEMVER_TAG ]] || continue
	ver="${t#v}"
	# Audit PREV (SKILL.md's A2.5 field-contract, decision D2): depends only on
	# $all_tags and this candidate's own tag, never on SRC_KIND/status, so it is
	# computed once per candidate, uniformly, and threaded into every row this
	# loop emits below — including the unresolvable/missing-body rows, which
	# previously discarded it entirely.
	prev="$(printf '%s\n' "$all_tags" | awk -v c="$t" '$0 == c { print prev; exit } { prev = $0 }')"
	name="$("$JQ" -r --arg t "$t" '.[] | select(.tagName == $t) | .name' <"$list" | head -n 1)"
	bfile="$bodies/$t.md"
	[[ -r "$bfile" ]] || bfile="$bodies/$t.lf.md"
	if [[ ! -r "$bfile" ]]; then
		# Audit Mode is read-only and per-candidate: a failure to obtain this
		# candidate's classification source classifies the ROW, it never aborts
		# the whole audit (SKILL.md's A2 marker-absent bullet).
		rows="$("$JQ" -c --arg v "$ver" --arg p "$prev" '. + [{version: $v, status: "template-marker-unresolvable", note: "release body unavailable for this candidate", prev: (if $p == "" then null else $p end)}]' <<<"$rows")"
		any_templated=1
		continue
	fi
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
		# Read from SRC_SCAN (the CR-normalized stream resolve_source already built
		# for marker detection), never the raw $bfile: a CRLF body's marker line
		# carries a trailing CR that defeats the `-->$` anchor below the same way it
		# would defeat resolve_source's own patterns, and reading two different byte
		# streams for "the same body" is exactly the bug SRC_SCAN exists to close.
		got="$tmp/got.txt"
		grep -a -v -E '^<!-- release-template-sha:.*-->$' "$SRC_SCAN" >"$got.0"
		awk 'NR == 1 && /^## What.s New$/ { skip = 1; state = 0; next }
			skip && state == 0 && /^[[:space:]]*$/ { state = 1; next }
			skip && state == 1 && !/^[[:space:]]*$/ { state = 2; next }
			skip && state == 2 && /^[[:space:]]*$/ { skip = 0; next }
			skip { next }
			{ print }' "$got.0" | trim_edges >"$got.1"
		# Check (4) of SKILL.md's `ok`/`drifted` bullet: the split-out
		# `## What's New` paragraph's PRESENCE must match the classification
		# source's `whats_new` when it is explicitly set. `whats_new: false`
		# makes a present summary drift, not something merely stripped and
		# ignored; `true`/unset impose no presence requirement here.
		whats_new_ok=1
		has_summary=0
		head -n 1 "$got.0" | grep -a -q -E '^## What.s New$' && has_summary=1
		if [[ -n "$SRC_FILE" ]]; then
			wn="$("$JQ" -r 'if has("whats_new") then (.whats_new | tostring) else "unset" end' <"$SRC_FILE")"
			[[ "$wn" == "false" && "$has_summary" == 1 ]] && whats_new_ok=0
		fi
		# $prev is already computed once per candidate, above the bfile lookup.
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
		body_ok=1
		cmp -s "$got" "$want_section" || body_ok=0
		if [[ "$title_ok" == 1 && "$compare_ok" == 1 && "$whats_new_ok" == 1 && "$body_ok" == 1 ]]; then
			status="ok"
		else
			status="drifted"
			# SKILL.md's ok/drifted bullet: "name each failed check in the
			# punch-list Note column — title, exact CHANGELOG bytes, exact
			# cached-base compare path, and What's New presence-vs-whats_new
			# are independent checks." Build the note from whichever of the
			# four independent checks failed, in that order.
			# ${failed[*]} with IFS=", " joins on only IFS's FIRST character
			# (a single ','), dropping the space — two failures would render
			# "title,exact CHANGELOG bytes" instead of "title, exact CHANGELOG
			# bytes". Join explicitly instead.
			failed=()
			[[ "$title_ok" == 1 ]] || failed+=("title")
			[[ "$body_ok" == 1 ]] || failed+=("exact CHANGELOG bytes")
			[[ "$compare_ok" == 1 ]] || failed+=("exact cached-base compare path")
			[[ "$whats_new_ok" == 1 ]] || failed+=("What's New presence-vs-whats_new")
			note=""
			for f in "${failed[@]}"; do
				[[ -n "$note" ]] && note+=", "
				note+="$f"
			done
		fi
		;;
	esac
	rows="$("$JQ" -c --arg v "$ver" --arg s "$status" --arg n "$note" --arg p "$prev" '. + [{version: $v, status: $s, note: (if $n == "" then null else $n end), prev: (if $p == "" then null else $p end)}]' <<<"$rows")"
done < <("$JQ" -r '.[].tagName' <"$list")

case_name="untemplated"
[[ "$any_templated" == 1 ]] && case_name="templated"
release_emit "$SCRIPT" "$site" "classified" 0 "" "$("$JQ" -c 'sort_by(.version)' <<<"$rows")" "$case_name"
