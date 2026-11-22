#!/usr/bin/env bash
# resolve-template-marker.sh — Audit Step A2's classification-source resolution
# (three-pattern marker search, dual-anchor binding, tracked-mode gate, current
# template fallback) plus the ok/drifted comparison, extracted from SKILL.md
# prose, and the re-sync decisions that must agree with it: Step 3's recovery
# marker decision (step3-recovery), Step 3 item 3's publishable-content stop and
# Step A4's offer gate (resync-gate), and Step 3's summary recovery/discard and
# preserve-vs-regenerate decision (resync-summary), all computed by the same
# functions a2-classify runs. Pure over injected inputs (grilled decision 9): the gh / ls-remote
# fetches stay in SKILL.md and their results arrive as files; the only git the
# script runs is read-only inspection of the explicit --repo, through the
# pinned RELEASE_GIT. Pinned jq arrives in RELEASE_JQ. Stdout is JSON
# (decision 12) carrying classification fields only.
#
# Usage:
#   resolve-template-marker.sh --site a2-classify --repo DIR --release-list FILE
#       --bodies-dir DIR --peeled FILE --tags FILE --changelog FILE
#       --web-base-url URL --head-sha 40-HEX
#     Body for tag T is <bodies-dir>/T.md, else <bodies-dir>/T.lf.md.
#     --tags FILE is the full origin-authoritative tag inventory (A1.1), a
#       JSON array of bare `vX.Y.Z` tag-name strings — independent of which of
#       those tags have a resolved --peeled entry (A1.1 permits an
#       unavailable peeled identity; that costs the tag only its own origin
#       anchor, never its membership in this inventory). Audit PREV is
#       computed from this population, never from --peeled's keys.
#   resolve-template-marker.sh --site step3-recovery --repo DIR --tag TAG
#       --body-file FILE --peeled FILE --head-sha 40-HEX
#     Emits only the marker decision for one body (no ok/drifted comparison).
#   resolve-template-marker.sh --site resync-gate --repo DIR --head-sha 40-HEX
#       --changelog FILE --version X.Y.Z
#     Emits rows = {stops, reason}: would a re-sync stop at the publishable-
#       content test (Canonical Format item 2 clause (a)) under the CURRENT
#       committed template? Step A4's offer gate and Step 3 item 3's hard stop.
#       Only exit 0 with rows.stops == false is a "proceed"; a non-zero exit
#       (rows null) is no decision, and both callers treat it as a stop.
#   resolve-template-marker.sh --site resync-summary --repo DIR --tag TAG
#       --body-file FILE --peeled FILE --head-sha 40-HEX --changelog FILE
#       [--headingless-summary FILE]
#     Emits rows = {recovery_template, recovery_label, recovery_note,
#       marker_stripped, summary_present, summary_kind, summary_text, discard,
#       discard_line, peeled_marker_line, content_block_text,
#       content_block_valid, invalid_reason, preserve, regenerate_safe,
#       regenerate_reason}: Step 3 item 1's summary recovery/discard and Step 3
#       item 3's preserve-vs-regenerate decision for one fetched body.
#       Invariant: the body a re-sync composes from these rows on either branch
#       audits `ok` under the current template, or the row marks that branch
#       unsafe (see the site's comment). Only exit 0 yields rows; a non-zero
#       exit (rows null) is no decision, and the caller stops the re-sync.
#       summary_text/content_block_text are the body's bytes with a trailing CR
#       per line removed (LF-normalised), serialised by jq; a body that is not
#       NUL-free valid UTF-8 emits both as null with preserve=false.
#       recovery_note names an unbound/ambiguous marker on exit 0 (failed_gate
#       stays exit-1-only).
#   --head-sha is REQUIRED at every site: the caller resolves HEAD once
#     (SKILL.md's single-resolution rule) and passes the literal SHA in; this
#     script never self-resolves HEAD, matching read-release-template.sh's
#     strict contract.
#   --peeled FILE is a JSON object of {"vX.Y.Z": "<40-hex origin peeled-commit
#     SHA>"} — bare tag names as keys, gated by both call sites; never
#     `refs/tags/vX.Y.Z^{}` ls-remote-style keys. Used only as the per-candidate
#     origin-anchor SHA lookup (never as the tag-inventory source — see --tags).
#
# Exit: 0 classified, 1 validation failure (malformed input), 2 environment.

# jq programs are single-quoted on purpose (they contain $vars for jq).
# shellcheck disable=SC2016
set -uo pipefail
# Release bodies and CHANGELOGs are operator-edited bytes that may carry a stray
# invalid UTF-8 byte. Under a UTF-8 locale BSD awk/grep/tr abort or truncate on
# one ("Illegal byte sequence"), which would silently misread a valid body as
# empty. Every comparison here is bytewise, so pin the C locale for the script.
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugins/skein/skills/release/lib/release-common.sh
. "$HERE/release-common.sh"

SCRIPT="resolve-template-marker"
site="" repo="" list="" bodies="" peeled="" tags="" changelog="" web="" tag="" body_file="" head_sha=""
version="" headingless=""

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
	--tags) tags="${2-}" ;;
	--changelog) changelog="${2-}" ;;
	--web-base-url) web="${2-}" ;;
	--tag) tag="${2-}" ;;
	--body-file) body_file="${2-}" ;;
	--head-sha) head_sha="${2-}" ;;
	--version) version="${2-}" ;;
	--headingless-summary) headingless="${2-}" ;;
	*) die "unknown argument: $1" 2 environment-failure bad-arguments ;;
	esac
	shift 2 || die "missing value for an argument" 2 environment-failure bad-arguments
done

case "$site" in
a2-classify | step3-recovery | resync-gate | resync-summary) ;;
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
# resync-gate binds no marker, so it alone takes no --peeled.
[[ "$site" == "resync-gate" || -r "$peeled" ]] || die "--peeled unreadable" 2 environment-failure input-unreadable

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

# anchor_blob_head — memoized anchor_blob "$HEAD_SHA". HEAD_SHA and TPATH are
# fixed for the whole run (HEAD_SHA is caller-resolved, never re-resolved
# here; see the single-resolution comment above), so resolving HEAD's anchor
# blob is invariant across every a2-classify candidate in the per-tag loop.
# Without this cache resolve_current_template and resolve_source each call
# anchor_blob "$HEAD_SHA" (2 git subprocesses: ls-tree + rev-parse) on every
# tag, re-doing identical work up to 2x per candidate on a long tag history.
_head_anchor_done=""
_head_anchor_state=""
_head_anchor_blob=""
anchor_blob_head() {
	if [[ -z "$_head_anchor_done" ]]; then
		anchor_blob "$HEAD_SHA"
		_head_anchor_state="$ANCHOR_STATE"
		_head_anchor_blob="$ANCHOR_BLOB"
		_head_anchor_done=1
	fi
	ANCHOR_STATE="$_head_anchor_state"
	ANCHOR_BLOB="$_head_anchor_blob"
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
	anchor_blob_head
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
		# resync-summary parses the same already-published body, so it takes
		# the same rule.
		if [[ "$site" == "step3-recovery" || "$site" == "resync-summary" ]]; then
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
	# Separator cardinality (SKILL.md:168, "exactly one blank line, always"):
	# the marker's immediate predecessor line must be blank, and the line
	# before THAT must not also be blank — zero or two-or-more blank lines
	# before the marker is a distinct failure, never silently compared `ok`
	# after the marker itself is stripped (round-3 Codex finding: stripping
	# only the matched marker line, without validating what precedes it,
	# left a double-blank-line body indistinguishable from a single-blank-line
	# one once trim_edges later trims the resulting trailing blank line away).
	# bash 3.2 portability (repo floor): `mapfile` is bash 4.0+ only.
	local ml_line
	src_lines=()
	while IFS= read -r ml_line || [[ -n "$ml_line" ]]; do
		src_lines+=("$ml_line")
	done <"$scan"
	local n="${#src_lines[@]}"
	if ((n < 2)) || [[ -n "${src_lines[$((n - 2))]}" ]] ||
		{ ((n >= 3)) && [[ -z "${src_lines[$((n - 3))]}" ]]; }; then
		SRC_NOTE="marker-shaped line is not preceded by exactly one blank line"
		return 0
	fi
	sha="$(grep -a -E '^<!-- release-template-sha: [0-9a-f]{40} -->$' "$scan" | sed -E 's/^<!-- release-template-sha: ([0-9a-f]{40}) -->$/\1/')"
	local peeled_sha origin_blob="" head_blob="" o_state h_state matched=0 mode_note=""
	need_jq
	# --peeled's keys are bare `vX.Y.Z` tag names (the fixtures' shape, and the
	# ONE format this script reads — see the top-of-file --peeled usage note).
	# Gate the shape once per run: an object whose values are all strings. A
	# malformed entry must fail closed the same way the release-list gate
	# does, never silently read as "unresolved" (an unset/wrong-type value
	# and a genuinely absent tag both jq-select to empty, which is
	# indistinguishable without this gate). For a2-classify this is already a
	# no-op — that site's own unconditional pre-loop gate (above, before the
	# per-tag loop) sets PEELED_SHAPE_OK before any candidate reaches here,
	# since that gate site is the actual first read of --peeled for
	# a2-classify (round-3 fix 5). This lazy form stays live for
	# step3-recovery, which never reaches that pre-loop gate and must not
	# require jq on a markerless run.
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
	anchor_blob_head
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

# normalise_changelog — CR-normalize CHANGELOG.md once, the same way
# resolve_source normalizes each release body into SRC_SCAN (round-3 fix 6):
# section_exact/section_tolerant below must read this normalized stream, never
# the raw $changelog, or a CRLF CHANGELOG paired with a CRLF body drifts between
# the two byte streams — a comparison that matched before the body-side
# CR-normalization landed (both sides raw) now mismatches once only one side is
# normalized. A function (called once by every site that reads the CHANGELOG:
# a2-classify, resync-gate, resync-summary) rather than top-level code, so the
# helpers below stay side-effect-free definitions every site can share.
CHANGELOG_LF="$tmp/changelog-lf.txt"
normalise_changelog() {
	sed $'s/\r$//' <"$changelog" >"$CHANGELOG_LF"
}
# SECTION_SRC — the file section_exact/section_tolerant read: CHANGELOG_LF for
# every comparison, but the RAW --changelog when building the block Step 3 item
# 3 publishes (it copies the section's bytes verbatim, CRs included), so the
# regenerate probe normalises those bytes exactly once, as a2-classify will.
# The boundaries are identical either way: every header test ignores a
# trailing CR (index prefix, squash, start-anchored regex).
SECTION_SRC=""

# The ONE Markdown heading-indentation bound every STRUCTURAL heading test in
# this script shares: up to 3 leading spaces, no tab (4 spaces or a tab is a code
# block or a paragraph continuation, never a heading). ` ? ? ?` rather than an
# interval expression, which not every awk supports. The structural heading
# patterns below are built on it, so the section boundary, clause (c), the
# What's New summary split and has_summary cannot disagree about what counts as
# a heading line. The excluded-heading comparison (is_h3, below) is deliberately
# NOT one of them: it is the trimmed cut-time comparison drop_excluded applies
# to the CHANGELOG, so audit and cut time stay symmetric.
HEADING_INDENT_RE='^ ? ? ?'
# Any ATX heading line (levels 1-6: `#`..`######`, then whitespace or end of
# line): where a What's New summary paragraph ends. One `#` plus up to five
# optional ones, not `#+` (7+ hashes is paragraph text) and not an interval
# expression (not every awk supports one).
HEADING_START_RE="${HEADING_INDENT_RE}##?#?#?#?#?([[:space:]]|\$)"
# The ONE section-boundary rule both extractors share, and has_version_header's
# first stage: a line that opens like a `## [` header modulo whitespace starts
# the next section (`    ## [0.0.1] example` stays content). Bracket
# expressions, not `\[`, so the text survives an awk `-v` value's escape
# processing.
VERSION_HEADER_START_RE="${HEADING_INDENT_RE}##[[:space:]]*[[]"
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
# Complete-header-shape match (round-3 Codex finding): require the exact
# canonical `## [X.Y.Z] - ` prefix (with its single trailing space before the
# date), never a bare `## [X.Y.Z]` prefix. A bare prefix let a malformed line
# such as `## [0.1.0]bogus` — not even whitespace/punctuation drift, just
# unrelated trailing text — match here and start extraction from the wrong
# place; the documented tolerant retry below (whitespace/punctuation drift
# only, SKILL.md Step 1 item 5) is the sole sanctioned fallback for anything
# looser than this exact shape. The section ENDS at any line section_tolerant
# would treat as a header (VERSION_HEADER_START_RE), not only a single-space
# `## [`: a strict start with a narrower end let an empty section swallow a
# following `##  [1.0.0]  –  date` release's header and notes.
section_exact() {
	awk -v want="## [$1] - " -v hs="$VERSION_HEADER_START_RE" '
		index($0, want) == 1 { on = 1; next }
		$0 ~ hs { on = 0 }
		on { print }
	' "${SECTION_SRC:-$CHANGELOG_LF}" | trim_edges
}
# Tolerant retry: compare the header with all whitespace removed, so `##  [1.0.0]`
# and `## [ 1.0.0 ] – date` match `## [1.0.0]` the way Step 1 item 5 requires.
# Still requires a hyphen or en dash immediately after the squashed brackets
# (the documented drift is whitespace/punctuation-style ONLY — hyphen vs. en
# dash — never arbitrary trailing content): a bare prefix match here would
# reopen the same "## [0.1.0]bogus" hole section_exact's fix above closes,
# just one fallback stage later.
section_tolerant() {
	awk -v h="##[$1]-" -v e="##[$1]$(printf '\xe2\x80\x93')" -v hs="$VERSION_HEADER_START_RE" '
		function squash(s) { gsub(/[[:space:]]/, "", s); return s }
		$0 ~ hs {
			s = squash($0)
			on = (index(s, h) == 1) || (index(s, e) == 1)
			next
		}
		on { print }
	' "${SECTION_SRC:-$CHANGELOG_LF}" | trim_edges
}
trim_edges() {
	awk '{ l[NR] = $0 } END {
		s = 1; while (s <= NR && l[s] ~ /^[[:space:]]*$/) s++
		e = NR; while (e >= s && l[e] ~ /^[[:space:]]*$/) e--
		for (i = s; i <= e; i++) print l[i]
	}'
}
# Canonical Format item 2's ONE heading comparison: leading/trailing whitespace
# trimmed on both sides. Shared, as an awk function prefix, by every program that
# compares a line against an excluded_sections entry (excluded_headings,
# drop_excluded, clause (d)) so the cut-time and audit sides cannot diverge.
# EXCL_AWK adds the list loader and the ONE heading predicate (`###` then
# whitespace or end of line, after trimming) both drop_excluded and
# has_excluded_heading use, so an entry that trims to a bare `###` is a heading
# on both sides, never dropped at cut time on one and flagged on the other.
TRIM_AWK='function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }'
EXCL_AWK="$TRIM_AWK"'
function load_excl(f, l) { while ((getline l < f) > 0) ex[l] = 1 }
function is_h3(t) { return t ~ /^###([[:space:]]|$)/ }'
# A compare-shaped line (`**Full diff:**`/`**Full changelog:**`), label-agnostic.
# Bracket expressions instead of `\*` so the SAME text is safe both for
# `grep -E` and for an awk `-v` value (whose escape processing eats `\*`).
COMPARE_SHAPED_RE='^[*][*]Full (diff|changelog):[*][*]'
# excluded_headings <template-json> — the template's active excluded_sections
# entries, one per line, trimmed. Built explicitly into its own file per
# candidate and read by BOTH sides of the exclusion contract: drop_excluded (the
# CHANGELOG side) and body_invalid_reason's clause (d) (the body side), so the
# two can never match different lists.
excluded_headings() {
	"$JQ" -r '(.excluded_sections // [])[]' <"$1" |
		awk "$TRIM_AWK"' { t = trim($0); if (t != "") print t }'
}
# drop_excluded <excluded-headings-file> — filters the section on stdin by the
# list excluded_headings built: a `###` heading (is_h3) whose trimmed text
# equals an entry starts a skipped subsection (Step 3 item 3's cut-time rule).
drop_excluded() {
	awk -v exfile="$1" "$EXCL_AWK"'
		BEGIN { load_excl(exfile) }
		{ t = trim($0) }
		is_h3(t) { skip = (t in ex) }
		!skip { print }
	' | trim_edges
}
# has_excluded_heading <file> <excluded-headings-file> — clause (d): does the
# file carry a `###` heading (is_h3) whose trimmed text equals an entry? The
# same loader and predicate drop_excluded uses. Prints the first matching line
# (raw, untrimmed) on stdout: resync-summary reports it as the discard line;
# body_invalid_reason discards it.
has_excluded_heading() {
	awk -v exfile="$2" "$EXCL_AWK"'
		BEGIN { load_excl(exfile) }
		{ t = trim($0) }
		is_h3(t) && (t in ex) { f = 1; print; exit }
		END { exit !f }
	' "$1"
}
# has_content <file> — does the file carry a non-whitespace line other than a
# compare-shaped one? Clause (a) (composition drops compare-shaped CHANGELOG
# lines, so a section of only those has nothing to publish) and clause (b) (a
# stale trailer must not mask an empty body). Single awk pass: no SIGPIPE.
has_content() {
	awk -v cre="$COMPARE_SHAPED_RE" '$0 ~ cre { next } /[^[:space:]]/ { f = 1; exit } END { exit !f }' "$1"
}
# The `## What's New` summary heading as Canonical Format item 2 documents it:
# HEADING_INDENT_RE's leading-space bound, tolerant of trailing whitespace and
# runs of spaces, and of exactly the real apostrophe encodings -- ASCII `'`,
# U+2019 and U+2018 (literal UTF-8 bytes; the script runs under the C locale).
# Nothing wider: `## What was New` is content. ONE pattern feeds the summary
# split, has_summary and so check (4).
WHATS_NEW_RE="$HEADING_INDENT_RE"$'##[[:space:]]+What(\'|\xe2\x80\x99|\xe2\x80\x98)s[[:space:]]+New[[:space:]]*$'
# has_version_header <file> — does the file carry a CHANGELOG version-header
# line? Two stages: the line must open like a header (VERSION_HEADER_START_RE,
# the section boundary's own predicate), then -- mirroring section_tolerant's
# squash -- the whitespace-squashed line must read `##[X.Y.Z]` (optionally a
# SemVer `-prerelease` and/or `+build` tail, each a dot-separated run of
# NON-EMPTY [0-9A-Za-z-] identifiers, so `[1.2.3-]`, `[1.2.3+.]` and
# `[1.2.3-rc..1]` are not versions) or `##[Unreleased]`,
# followed by a hyphen, an en dash, or end of line. A link heading such as
# `## [Migration guide](guide.md)` or `## [1.2.3](guide.md)`, and a heading that
# merely starts with a version (`## [1.2.3 compatibility notes]`), is not a
# version header. Single awk pass over the file: no pipe, so no SIGPIPE.
# Prints the first matching line (raw) on stdout, like has_excluded_heading.
has_version_header() {
	awk -v ed="$(printf '\xe2\x80\x93')" -v hs="$VERSION_HEADER_START_RE" '
		function squash(s) { gsub(/[[:space:]]/, "", s); return s }
		$0 ~ hs {
			s = squash($0)
			if (match(s, /^##\[([0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?|Unreleased)\]/)) {
				rest = substr(s, RLENGTH + 1)
				if (rest == "" || substr(rest, 1, 1) == "-" || index(rest, ed) == 1) { f = 1; print; exit }
			}
		}
		END { exit !f }
	' "$1"
}
# section_publishable <version> <excluded-headings-file> — Canonical Format
# item 2 clause (a), the skill's ONE publishable-content test: the CHANGELOG
# section (Step 1's exact+tolerant extraction) after drop_excluded, ignoring
# compare-shaped lines (has_content), is non-empty. A missing section and one
# emptied by exclusions both fail. The single function behind three decisions
# that must agree: a2-classify's clause (a) (via body_invalid_reason), the
# resync-gate site (Step A4's offer gate and Step 3 item 3's hard stop), and
# resync-summary's content-block validity (again via body_invalid_reason).
section_publishable() {
	local f="$tmp/section-after-excl.txt"
	section "$1" | drop_excluded "$2" >"$f"
	has_content "$f"
}
# body_invalid_reason <content-block> <version> <excluded-headings-file> <whole-body> —
# Canonical Format item 2's valid-body predicate, the audit's executable form
# of it. Callers: audit_body_checks (a2-classify, and resync-summary's composed
# re-sync body) and resync-summary's content-block validity test.
# Prints the first failing clause's punch-list note, or nothing when valid:
#   (a) section_publishable -- `body (missing CHANGELOG section)` covers both
#       a missing section and one left empty by exclusions;
#   (b) the content block, ignoring compare-shaped lines, is non-empty;
#   (c) the WHOLE body (summary included, read before the summary split)
#       embeds no CHANGELOG version-header line (has_version_header);
#   (d) the WHOLE body (summary included) carries no `###` heading equal,
#       trimmed, to an active excluded_sections entry (has_excluded_heading).
# (c) and (d) read the whole body although the split now ends a summary at any
# heading line (HEADING_START_RE): (d)'s comparison trims, exactly as
# drop_excluded does at cut time, so a 4-space/tab-indented `### Internal` is an
# excluded heading on both sides even though Markdown reads it as a summary
# continuation line, never a heading; the whole-body scan keeps audit symmetric
# with that cut-time rule wherever the line sits, and costs nothing for (c).
# (b) alone reads the content block; (a) reads the CHANGELOG section.
# Clause (e) — no compare-shaped line inside the content block — is enforced by
# the compare-path check (3) below, which already drifts on any compare-shaped
# line other than the one exact canonical trailer, so it is not re-reported here.
# Every test is a single awk pass reading the file directly: a `grep | grep -q`
# pipe under pipefail returns 141 (SIGPIPE) on a large body and misreads it.
body_invalid_reason() {
	if ! section_publishable "$2" "$3"; then
		echo "body (missing CHANGELOG section)"
	elif ! has_content "$1"; then
		echo "body (empty)"
	elif has_version_header "$4" >/dev/null; then
		echo "body (embeds a CHANGELOG header)"
	elif has_excluded_heading "$4" "$3" >/dev/null; then
		echo "body (carries an excluded section)"
	fi
}

# body_stream <scan> <strip|keep> — the body stream every summary split reads:
# a2-classify's and resync-summary's. It reads SRC_SCAN (the CR-normalized
# stream resolve_source built for marker detection), never the raw body file:
# a CRLF body's marker line carries a trailing CR that defeats the `-->$`
# anchor below the same way it would defeat resolve_source's own patterns, and
# reading two different byte streams for "the same body" is exactly the bug
# SRC_SCAN exists to close. `strip` drops marker-shaped lines: a caller passes
# it only when resolve_source did NOT classify the body unresolvable, i.e. the
# body carries either no marker-shaped line (a no-op) or exactly one bound
# strict marker as its final line -- so the strip removes exactly that bound
# marker. `keep` (resync-summary over an unbound/ambiguous marker, which
# a2-classify never splits) keeps the line; resync-summary then peels a final
# one into peeled_marker_line, and a marker-shaped line anywhere else makes
# the block unpreservable. Leading blank lines are dropped either way so the `## What's New`
# summary is recognised as the first CONTENT line, not physical line one: a
# body that opens with a blank line must not let a summary-only body slip past
# the summary split and read as ordinary content.
MARKER_SHAPED_RE='^<!-- release-template-sha:.*-->$'
body_stream() {
	if [[ "$2" == strip ]]; then
		grep -a -v -E "$MARKER_SHAPED_RE" "$1"
	else
		cat "$1"
	fi | awk 'f || /[^[:space:]]/ { f = 1; print }'
}
# has_whats_new_heading <body-stream> — is the first content line the
# `## What's New` heading (WHATS_NEW_RE)? Audit's check (4) presence test and
# resync-summary's summary_present, one predicate.
has_whats_new_heading() {
	awk -v wn="$WHATS_NEW_RE" 'NR == 1 { f = ($0 ~ wn); exit } END { exit !f }' "$1"
}
# whats_new_split <body-stream> <compare-label> <content-out> <summary-out> —
# THE What's New split, shared by a2-classify and resync-summary so Audit's
# split and Step 3 item 1's headed-summary recovery boundary are one function.
# Writes the body minus the summary (edges trimmed) to <content-out> and the
# summary paragraph's own lines (heading excluded) to <summary-out>.
# SKILL.md's own recovery-boundary definition (Step 3 item 1): the
# What's New prose block runs from the heading up to whichever comes
# first of the next heading line (HEADING_START_RE: levels 1-6, up to 3
# leading spaces -- the shared bound -- or a VERSION_HEADER_START_RE
# line), the compare line, or EOF. Real release bodies use both a paragraph
# immediately after the heading (no blank line) and a blank line
# between the heading and the paragraph -- both are well-formed, so
# leading blank lines before any paragraph content are swallowed
# without ending the skip. Once the paragraph has started, the blank
# line that follows it (the separator before the next boundary) is
# itself part of the boundary and is swallowed too, not just the
# anchor lines that follow it -- a prior version of this rewrite
# dropped blank-line detection entirely and skipped everything up to
# the first anchor line unconditionally, which silently ate real
# CHANGELOG content whenever a release's CHANGELOG section has no
# "### "/"## " subsection before the compare line (flat prose or
# bullets directly under the version header), since nothing
# terminated the skip before EOF/the compare line. An even earlier
# version required NR==2 to be blank before entering skip mode at
# all, which left every summary using the no-blank-line style
# unstripped. The anchor check remains as a fallback boundary for a
# paragraph that runs straight into "### "/"## "/the compare line
# with no intervening blank line at all.
# The compare-line anchor itself is parametrized by the caller's resolved
# label (a2-classify: the classification source's compare_line_label;
# resync-summary: the recovery template's), never a fixed diff-or-changelog
# alternation: under "none" no compare-line boundary exists at all, so a
# `## What's New` paragraph that opens with literal bold text shaped like
# `**Full diff:**`/`**Full changelog:**` must stay ordinary summary prose, not
# a boundary -- matching either label unconditionally (a previous bug) mis-ends
# the scan on that line and leaks it, plus everything after it, into the
# content block the valid-body predicate reads (clause (b)'s emptiness test and
# check (3)'s compare-shaped-line test). Bracket-expression form, for the `-v`
# escape reason COMPARE_SHAPED_RE's comment gives.
whats_new_split() {
	local compare_anchor=""
	[[ "$2" == "none" ]] || compare_anchor='^[*][*]'"$2"':[*][*]'
	: >"$4"
	awk -v anchor="$compare_anchor" -v wn="$WHATS_NEW_RE" \
		-v hd="$HEADING_START_RE" -v hs="$VERSION_HEADER_START_RE" -v sumfile="$4" \
		'NR == 1 && $0 ~ wn { insummary = 1; started = 0; next }
		insummary && ($0 ~ hd || $0 ~ hs || (anchor != "" && $0 ~ anchor)) { insummary = 0; print; next }
		insummary && started && /^[[:space:]]*$/ { insummary = 0; next }
		insummary && !started && /^[[:space:]]*$/ { next }
		insummary { started = 1; print > sumfile; next }
		{ print }' "$1" | trim_edges >"$3"
}

# template_label / template_whats_new <template-json> — the two template fields
# the body checks read (an unset label is "Full diff"; whats_new is
# "true"/"false"/"unset").
template_label() { "$JQ" -r '.compare_line_label // "Full diff"' <"$1"; }
template_whats_new() { "$JQ" -r 'if has("whats_new") then (.whats_new | tostring) else "unset" end' <"$1"; }

# audit_body_checks <stream> <label> <whats_new> <prev> <tag> <web> <excl> <ver> <out>
# Audit Step A2's body-side checks (2), (3) and (4) over one marker-stripped
# body stream (body_stream's output) under one template's fields: <label> its
# compare_line_label, <whats_new> template_whats_new's value, <excl> its
# excluded_headings file. The ONE implementation a2-classify runs per candidate
# and resync-summary runs over the body a re-sync would publish, so "re-sync
# would publish it" and "audit accepts it" are the same predicate. Writes the
# split (whats_new_split) to <out>.1 / <out>.summary and the content block
# (compare trailer dropped when exact) to <out>; sets AUD_BODY_NOTE (empty =
# valid body), AUD_COMPARE_OK and AUD_WN_OK (1 = check passed).
audit_body_checks() {
	local stream="$1" label="$2" wnv="$3" prev="$4" t="$5" webu="$6" excl="$7" v="$8" out="$9"
	local nlines expected
	whats_new_split "$stream" "$label" "$out.1" "$out.summary"
	AUD_WN_OK=1
	[[ "$wnv" == "false" ]] && has_whats_new_heading "$stream" && AUD_WN_OK=0
	AUD_COMPARE_OK=1
	if [[ "$label" == "none" ]]; then
		grep -a -q -E "$COMPARE_SHAPED_RE" "$out.1" && AUD_COMPARE_OK=0
		cp "$out.1" "$out"
	else
		nlines="$(grep -a -c -E "$COMPARE_SHAPED_RE" "$out.1")"
		if [[ -n "$prev" ]]; then
			expected="**$label:** $webu/compare/$prev...$t"
			if [[ "$nlines" == 1 && "$(tail -n 1 "$out.1")" == "$expected" ]]; then
				sed '$d' "$out.1" | trim_edges >"$out"
			else
				AUD_COMPARE_OK=0
				cp "$out.1" "$out"
			fi
		else
			[[ "$nlines" == 0 ]] || AUD_COMPARE_OK=0
			cp "$out.1" "$out"
		fi
	fi
	# Check (2) is compact-tolerant: a release body MAY be shorter than its
	# CHANGELOG section, so its bytes are not compared. It must instead be a
	# valid body (body_invalid_reason).
	AUD_BODY_NOTE="$(body_invalid_reason "$out" "$v" "$excl" "$stream")"
}

# current_excluded_headings <out-file> — the CURRENT committed template's
# excluded_sections (resolve_current_template's two-sided, fail-closed oracle
# at --head-sha, the template every re-sync composes with), one per line, via
# the same excluded_headings a2-classify uses. Empty for an absent template.
# Returns 1 with CUR_STATE left "invalid:<note>" when the template is present
# but fails Step 1b's gates (a re-sync would hard-stop at Step 1b).
current_excluded_headings() {
	: >"$1"
	resolve_current_template
	case "$CUR_STATE" in
	absent) return 0 ;;
	valid) excluded_headings "$CUR_FILE" >"$1" ;;
	*) return 1 ;;
	esac
}
# body_bytes_ok <file> — the resync-summary byte-safety gate: the file is
# NUL-free valid UTF-8. A body that fails it is never parsed into reusable text
# (NUL would be dropped by every line tool, an invalid byte would be rewritten
# by jq or rejected by a strict JSON reader), so the block is regenerated and
# no text field is emitted. The UTF-8 test is the pinned jq's own decoder: its
# raw-string read rewrites every invalid sequence to U+FFFD, so the round trip
# is byte-identical exactly when the input is valid UTF-8.
body_bytes_ok() {
	cmp -s <(tr -d '\000' <"$1") "$1" || return 1
	# shellcheck disable=SC2094 # both sides only read the file
	"$JQ" -j -Rs . <"$1" | cmp -s - "$1"
}

# current_template_fields — the current template's compare_line_label and
# whats_new (the sentinel's: "Full diff", "unset"), after
# current_excluded_headings succeeded. The two fields of the NEW body every
# verdict below is judged under.
current_template_fields() {
	cur_label="Full diff" cur_wn="unset"
	if [[ "$CUR_STATE" == valid ]]; then
		cur_label="$(template_label "$CUR_FILE")"
		cur_wn="$(template_whats_new "$CUR_FILE")"
	fi
}
# The compare trailer is composed with a probe PREV/URL: check (3) depends on
# PREV only through whether a trailer is appended, and with or without one it
# passes exactly when no compare-shaped line reaches the post-summary content,
# so every verdict is PREV-independent (a first release, which carries no
# trailer, gets the same verdict).
PROBE_WEB="https://resync.invalid/probe" PROBE_PREV="vPREV"
# compose_audits <summary-file|-> <block-file> — THE composer both resync sites
# share: the body Step 3 would publish (`## What's New` + the summary when one
# is given, then the block, then the current label's compare trailer; the
# current marker binds by construction, so a marker-shaped line anywhere else
# is the only marker failure), normalised exactly once the way a2-classify's
# resolve_source normalises a published body (one trailing CR per line) BEFORE
# any check, then a2-classify's own checks (2)-(4) under the current
# template's label/whats_new/excluded list. Callers pass the bytes Step 3
# publishes: a summary or preserved block as recovered (one CR per line already
# removed), a regenerated block as the raw section's bytes (regen_block).
# Reads cur_label, cur_wn, tag, ver, excl_list. Sets AUD_FAIL.
compose_audits() {
	local c="$tmp/composed.txt" fails=() f
	{
		if [[ "$1" != - ]]; then
			printf '%s\n' "## What's New"
			cat "$1"
			printf '\n'
		fi
		cat "$2"
		[[ "$cur_label" == none ]] || printf '\n**%s:** %s/compare/%s...%s\n' "$cur_label" "$PROBE_WEB" "$PROBE_PREV" "$tag"
	} | sed $'s/\r$//' >"$c"
	AUD_FAIL=""
	if grep -a -q -E "$MARKER_SHAPED_RE" "$c"; then
		AUD_FAIL="a marker-shaped line"
		return 1
	fi
	body_stream "$c" strip >"$c.0"
	audit_body_checks "$c.0" "$cur_label" "$cur_wn" "$PROBE_PREV" "$tag" "$PROBE_WEB" "$excl_list" "$ver" "$c.a"
	[[ -z "$AUD_BODY_NOTE" ]] || fails+=("$AUD_BODY_NOTE")
	[[ "$AUD_COMPARE_OK" == 1 ]] || fails+=("exact cached-base compare path")
	[[ "$AUD_WN_OK" == 1 ]] || fails+=("What's New presence-vs-whats_new")
	for f in ${fails[@]+"${fails[@]}"}; do
		[[ -n "$AUD_FAIL" ]] && AUD_FAIL+=", "
		AUD_FAIL+="$f"
	done
	[[ -z "$AUD_FAIL" ]]
}
# regen_block <out> — the block Step 3 item 3 composes from the section: the
# RAW section bytes (SECTION_SRC; Step 3 copies them verbatim, so the one CR
# strip compose_audits applies is the only one, as in a2-classify), the current
# template's exclusions dropped (drop_excluded, the cut-time rule), every
# compare-shaped line dropped, edges trimmed.
REGEN="$tmp/regen.txt"
regen_block() {
	SECTION_SRC="$changelog" section "$ver" | drop_excluded "$excl_list" |
		awk -v cre="$COMPARE_SHAPED_RE" '$0 !~ cre' | trim_edges >"$1"
}
# A representative drafted summary: one plain paragraph, no heading, no compare
# or marker line -- the shape Step 3 drafts. Any summary Step 3 may compose
# behaves like it under Audit's split: a reused one passed the discard rules
# and the summary-alone probe (the split ends it exactly at the separator), so
# the content block, checks (c)/(d) and check (4) see the same bytes.
DRAFTED_SUMMARY="$tmp/drafted-summary.txt"
printf 'Drafted summary.\n' >"$DRAFTED_SUMMARY"
# regenerate_verdict <summary-present 0|1> — THE regenerate-branch verdict, ONE
# function of (current template, CHANGELOG section, summary present) that
# every consumer acts on: resync-gate (a new release's composition and Step
# A4's offer gate for a row with no release) and resync-summary (a re-sync's
# regenerate branch, and so Step A4's offer gate for a row with a release).
# A summary is present only when the current whats_new is not false. Sets
# regen_reason (empty = safe) and regen_needs_summary (true = safe only with
# the summary: Step 3 must then keep it, never compose a bare body).
regenerate_verdict() {
	local s=-
	regen_reason="" regen_needs_summary=false
	[[ "$1" == 1 && "$cur_wn" != false ]] && s="$DRAFTED_SUMMARY"
	if ! compose_audits "$s" "$REGEN"; then
		regen_reason="body (regenerated block would audit drifted: $AUD_FAIL)"
		return 1
	fi
	if [[ "$s" != - ]] && ! compose_audits - "$REGEN"; then
		regen_needs_summary=true
	fi
	return 0
}

# --site resync-gate: would composing --version from its CHANGELOG section stop
# under the CURRENT committed template? The verdict for every path that
# composes the block from the section with no existing release body: Step 3
# item 3's hard stop for a NEW release and Step A4's offer gate for a row with
# no release (missing-tag, missing-release). A re-sync of an existing release
# takes its stop from resync-summary's rows.stops instead (it alone sees the
# old body: preserve vs regenerate, and the summary state). Step A4 withholds
# exactly when the output for its path says stops and Step 3 hard-stops
# exactly when it says stops: both run the same function over the same inputs,
# at the caller's own already-resolved HEAD (A4 at A2's, Step 3 at Step 1b's),
# so a template commit landing between the two can only turn an offered row
# into Step 3's hard stop, never publish a drifted body. Stops when: the
# current template is present but invalid (`template (<note>)`; Step 1b would
# hard-stop first); section_publishable fails (clause (a), the very function
# a2-classify runs via body_invalid_reason); or regenerate_verdict fails with
# the summary Step 3 may draft (none under whats_new:false).
# rows.summary_required = only the summary makes the composed body audit ok.
# Template choice: always the current committed template at --head-sha, never
# A2's historical classification source. Runs no jq unless the template is
# present (a stop reason goes through release_json_escape).
if [[ "$site" == "resync-gate" ]]; then
	[[ -r "$changelog" ]] || die "--changelog unreadable" 2 environment-failure input-unreadable
	[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
		die "--version must be a strict X.Y.Z" 2 environment-failure bad-arguments
	normalise_changelog
	excl_list="$tmp/excl.list"
	gate_case="untemplated"
	if ! current_excluded_headings "$excl_list"; then
		# A present (if invalid) template: pin jq to serialise the free-form note.
		need_jq
		rows="$("$JQ" -cn --arg r "template (${CUR_STATE#invalid:})" '{stops: true, reason: $r, summary_required: false}')" ||
			die "rows serialisation failed" 2 environment-failure jq-failed
		release_emit "$SCRIPT" "$site" "resync-gate-stop" 0 "" "$rows" templated
		exit 0
	fi
	[[ "$CUR_STATE" == valid ]] && gate_case="templated"
	if ! section_publishable "$version" "$excl_list"; then
		release_emit "$SCRIPT" "$site" "resync-gate-stop" 0 "" '{"stops":true,"reason":"body (missing CHANGELOG section)","summary_required":false}' "$gate_case"
		exit 0
	fi
	current_template_fields
	ver="$version" tag="v$version"
	regen_block "$REGEN"
	if regenerate_verdict 1; then
		release_emit "$SCRIPT" "$site" "resync-gate-pass" 0 "" '{"stops":false,"reason":null,"summary_required":'"$regen_needs_summary"'}' "$gate_case"
	else
		release_emit "$SCRIPT" "$site" "resync-gate-stop" 0 "" '{"stops":true,"reason":"'"$(release_json_escape "$regen_reason")"'","summary_required":false}' "$gate_case"
	fi
	exit 0
fi

# headingless_not_summary <normalised-prefix> — a proved headingless prefix of
# only compare-shaped lines (or empty), or one carrying the recovery label's
# compare line, is not a summary (wrapped, Audit's split would end at it): it
# stays in the content block. Reads recovery_label.
headingless_not_summary() {
	local anchor=""
	[[ "$recovery_label" == none ]] || anchor='^[*][*]'"$recovery_label"':[*][*]'
	awk -v cre="$COMPARE_SHAPED_RE" -v anchor="$anchor" '
		anchor != "" && $0 ~ anchor { hit = 1 }
		/[^[:space:]]/ && $0 !~ cre { other = 1 }
		END { exit !(hit || !other) }' "$1"
}
# summary_kind_of <body-stream> <summary-file> <headingless 0|1> — THE summary
# classification both resync-summary branches (byte-valid and byte-invalid)
# share: `headed` when the first content line is `## What's New` and its split
# summary (<summary-file>) carries a non-space byte (an empty headed summary is
# an ABSENT summary, not a discard: an ordinary re-sync preserves the absence);
# `headingless` when a proved prefix (normalised into <summary-file>) is a
# summary; empty otherwise. Prints the kind.
summary_kind_of() {
	if has_whats_new_heading "$1"; then
		grep -a -q '[^[:space:]]' "$2" && echo headed
	elif [[ "$3" == 1 ]] && ! headingless_not_summary "$2"; then
		echo headingless
	fi
	return 0
}

# --site resync-summary: Step 3 item 1's summary recovery + summary-discard rule
# and Step 3 item 3's preserve-vs-regenerate decision and stop, for ONE fetched
# release body, computed by the same functions a2-classify runs.
# Template choices (SKILL.md Step 3):
#   - recovery template (resolve_source at the step3-recovery rules: a bound
#     strict marker's blob, else the no-template sentinel) governs PARSING the
#     old body: whether the marker line is stripped (only when bound) and the
#     compare_line_label that anchors the split boundary and names the stale
#     trailer to drop (sentinel = "Full diff"; "none" = no compare boundary, no
#     trailer strip);
#   - the CURRENT committed template (the active template every re-sync
#     composes with) governs everything about the NEW body.
# THE INVARIANT this site owns: the body a re-sync publishes on EITHER branch
# audits `ok` under the current template, or the row says that branch is
# unsafe; rows.stops (preserve false and regenerate unsafe) is the re-sync's
# one stop, which Step 3 item 3 and Step A4 (for a row with a release) both
# act on. Preserve branch: compose_audits over the summary when reusable
# (present, non-empty, not discarded, current whats_new not false) and the
# recovered content block; a discarded summary is judged absent there, which
# can only be stricter (a preserved block carries no compare-shaped line, so a
# leading paragraph never removes content it would keep). Regenerate branch:
# regenerate_verdict, present when Step 3 will compose a summary (a reusable
# one, or a fresh draft replacing a discarded one), absent when the old body
# has none (an ordinary re-sync preserves the absence). A summary that alone
# makes the branch to be published drift is discarded (`audit-drift`).
# rows.summary_required: a branch the rows mark publishable audits ok only
# with its summary, so Step 4 never offers a bare body.
# A summary is also tested on its own (followed by a non-heading paragraph
# line), because a reused summary precedes either block: Audit's split must
# end it exactly where it ends.
# Not probed (judgment calls Step 4 shows): a compact digest of the
# regenerated block.
# --headingless-summary FILE: for a body with no `## What's New` heading, the
# exact prefix bytes Step 3's byte-exact headingless recovery already proved;
# the discard rule then runs over it and it is removed from the content block
# (headingless_not_summary decides whether it is a summary at all).
# Every rows field is serialised by the pinned jq (--arg, and --rawfile for
# the two free-form texts), so this site pins jq unconditionally: SKILL.md
# pins jq for every re-sync, templated or not, and any non-zero exit stops it.
if [[ "$site" == "resync-summary" ]]; then
	[[ -r "$body_file" && -n "$tag" && -r "$changelog" ]] ||
		die "--tag, --body-file and --changelog are required" 2 environment-failure input-unreadable
	[[ "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
		die "--tag must be a strict vX.Y.Z" 2 environment-failure bad-arguments
	[[ -z "$headingless" || -r "$headingless" ]] ||
		die "--headingless-summary unreadable" 2 environment-failure input-unreadable
	need_jq
	ver="${tag#v}"
	normalise_changelog
	resolve_source "$tag" "$body_file"
	recovery_template="sentinel" recovery_label="Full diff" strip="strip"
	case "$SRC_KIND" in
	marker)
		recovery_template="marker"
		recovery_label="$(template_label "$SRC_FILE")"
		;;
	unresolvable) strip="keep" ;;
	esac
	excl_list="$tmp/excl.list"
	current_excluded_headings "$excl_list" ||
		die "current template invalid: ${CUR_STATE#invalid:}" 1 hard-stop current-template-invalid
	current_template_fields
	# recovery_note: resolve_source's note for an unbound/ambiguous marker (the
	# body was then parsed raw, under the sentinel); empty otherwise.
	recovery_note=""
	[[ "$SRC_KIND" == unresolvable ]] && recovery_note="$SRC_NOTE"
	marker_stripped=false
	[[ "$SRC_KIND" == marker ]] && marker_stripped=true
	summary_case="untemplated"
	[[ "$SRC_KIND" == marker || "$CUR_STATE" == valid ]] && summary_case="templated"
	got="$tmp/got.txt" summary="$tmp/summary.txt" content="$tmp/content.txt"
	: >"$content"
	summary_kind="" discard="" discard_line="" peeled_marker="" invalid_reason="" regen_reason=""
	summary_required=false hl=0
	[[ -n "$headingless" ]] && hl=1
	body_stream "$SRC_SCAN" "$strip" | trim_edges >"$got.0"
	# A trailing marker-shaped line kept as body data (an unbound/ambiguous
	# marker) is peeled off with its separator BEFORE the summary split and
	# reported, never left in the summary or the content block: the re-sync
	# appends its own marker, and a kept one would mask the stale trailer below,
	# swallow a summary-only body's prose, and make the published body
	# unresolvable.
	last="$(tail -n 1 "$got.0")"
	if [[ "$last" =~ $MARKER_SHAPED_RE ]]; then
		peeled_marker="$last"
		sed '$d' "$got.0" | trim_edges >"$got.p"
		mv "$got.p" "$got.0"
	fi
	whats_new_split "$got.0" "$recovery_label" "$got.1" "$summary"
	regen_block "$REGEN"
	emit_rows() { # with-texts(true|false)
		local rows
		rows="$("$JQ" -cn --argjson tx "$1" \
			--arg rt "$recovery_template" --arg rl "$recovery_label" --arg rn "$recovery_note" \
			--argjson ms "$marker_stripped" --arg sk "$summary_kind" --arg dc "$discard" \
			--arg dl "$discard_line" --arg pm "$peeled_marker" --arg ir "$invalid_reason" \
			--arg rr "$regen_reason" --argjson sr "$summary_required" \
			--rawfile st "$summary" --rawfile cb "$content" '
			def opt: if . == "" then null else . end;
			{recovery_template: $rt, recovery_label: $rl, recovery_note: ($rn | opt),
			 marker_stripped: $ms, summary_present: ($sk != ""), summary_kind: ($sk | opt),
			 summary_text: (if $tx and $sk != "" then ($st | rtrimstr("\n")) else null end),
			 discard: ($dc | opt), discard_line: ($dl | opt), peeled_marker_line: ($pm | opt),
			 content_block_text: (if $tx then ($cb | rtrimstr("\n")) else null end),
			 content_block_valid: ($ir == ""), invalid_reason: ($ir | opt), preserve: ($ir == ""),
			 regenerate_safe: ($rr == ""), regenerate_reason: ($rr | opt),
			 stops: ($ir != "" and $rr != ""), reason: (if $ir != "" then ($rr | opt) else null end),
			 summary_required: $sr}')" ||
			die "rows serialisation failed" 2 environment-failure jq-failed
		release_emit "$SCRIPT" "$site" "resync-summary" 0 "" "$rows" "$summary_case"
	}
	# A headingless prefix replaces the (then empty) split summary: normalised
	# the way a2-classify will read it once published (one CR per line removed).
	if [[ "$hl" == 1 ]] && ! has_whats_new_heading "$got.0"; then
		sed $'s/\r$//' <"$headingless" | trim_edges >"$summary"
	fi
	# Byte-safety gate first: a NUL or an invalid UTF-8 byte anywhere in the body
	# (or the proved prefix) means nothing is reused and no text is emitted. The
	# summary is classified by the same summary_kind_of as below, so an empty
	# headed summary is absent here too; a present one is discarded and Step 3
	# redrafts it, which the regenerate verdict accounts for.
	if ! body_bytes_ok "$body_file" || { [[ "$hl" == 1 ]] && ! body_bytes_ok "$headingless"; }; then
		summary_kind="$(summary_kind_of "$got.0" "$summary" "$hl")"
		[[ -z "$summary_kind" ]] || discard="invalid-bytes"
		invalid_reason="body (not valid UTF-8 text)"
		if regenerate_verdict "$([[ -n "$summary_kind" ]] && echo 1 || echo 0)"; then
			summary_required="$regen_needs_summary"
		fi
		emit_rows false
		exit 0
	fi
	if has_whats_new_heading "$got.0"; then
		[[ "$hl" == 0 ]] ||
			die "--headingless-summary given for a body with a What's New heading" 1 hard-stop headingless-summary-mismatch
	elif [[ "$hl" == 1 ]]; then
		# The prefix must be the content's first lines followed by one blank line.
		awk -v sf="$summary" '
			BEGIN { while ((getline l < sf) > 0) p[++n] = l }
			NR <= n { if (($0 "") != (p[NR] "")) bad = 1; next }
			NR == n + 1 { if ($0 !~ /^[[:space:]]*$/) bad = 1; next }
			{ print }
			END { if (n == 0 || NR <= n + 1) bad = 1; exit bad }
		' "$got.1" >"$got.2" ||
			die "--headingless-summary is not a blank-line-separated prefix of the body" 1 hard-stop headingless-summary-mismatch
	fi
	summary_kind="$(summary_kind_of "$got.0" "$summary" "$hl")"
	case "$summary_kind" in
	"") : >"$summary" ;; # absent: a not-a-summary prefix stays in the content block
	headingless) trim_edges <"$got.2" >"$got.1" ;;
	esac
	# Drop the recovery template's own trailing compare line (any URL: recovery
	# neither blesses nor needs a current trailer -- it is regenerated).
	trailer_re='^[*][*]'"$recovery_label"':[*][*] .'
	if [[ "$recovery_label" != "none" && "$(tail -n 1 "$got.1")" =~ $trailer_re ]]; then
		sed '$d' "$got.1" | trim_edges >"$content"
	else
		cp "$got.1" "$content"
	fi
	# Content-block validity under the current template, over the block as
	# a2-classify will read it once published (one trailing CR per line
	# removed): body_invalid_reason (clauses (a)-(d)), then clause (e) and the
	# marker shape.
	sed $'s/\r$//' <"$content" >"$content.n"
	invalid_reason="$(body_invalid_reason "$content.n" "$ver" "$excl_list" "$content.n")"
	if [[ -z "$invalid_reason" ]] && grep -a -q -E "$COMPARE_SHAPED_RE" "$content.n"; then
		invalid_reason="body (carries a compare-shaped line)"
	fi
	if [[ -z "$invalid_reason" ]] && grep -a -q -E "$MARKER_SHAPED_RE" "$content.n"; then
		invalid_reason="body (carries a marker-shaped line)"
	fi
	if [[ -n "$summary_kind" ]]; then
		sed $'s/\r$//' <"$summary" >"$summary.n"
		if discard_line="$(has_version_header "$summary.n")"; then
			discard="version-header"
		elif discard_line="$(has_excluded_heading "$summary.n" "$excl_list")"; then
			discard="excluded-heading"
		else
			discard_line=""
		fi
	fi
	reuse=0
	[[ -n "$summary_kind" && -z "$discard" && "$cur_wn" != false ]] && reuse=1
	if [[ "$reuse" == 1 ]]; then
		# The summary on its own: Audit's split of `## What's New` + summary +
		# a following paragraph line must return the (normalised) summary
		# unchanged.
		printf -- '- probe\n' >"$tmp/probe-block.txt"
		compose_audits "$summary" "$tmp/probe-block.txt" >/dev/null 2>&1
		if ! cmp -s "$tmp/composed.txt.a.summary" "$summary.n" || grep -a -q -E "$MARKER_SHAPED_RE" "$summary.n"; then
			discard="audit-drift"
			discard_line="$(awk -v pf="$tmp/composed.txt.a.summary" '
				BEGIN { while ((getline l < pf) > 0) n++ }
				NR > n && /[^[:space:]]/ { print; exit }' "$summary.n")"
			if marker_line="$(grep -a -m 1 -E "$MARKER_SHAPED_RE" "$summary.n")"; then
				discard_line="$marker_line"
			fi
			reuse=0
		fi
	fi
	sum_arg=-
	[[ "$reuse" == 1 ]] && sum_arg="$summary"
	# Preserve branch: summary-if-reusable + the recovered content block.
	if [[ -z "$invalid_reason" ]] && ! compose_audits "$sum_arg" "$content"; then
		if [[ "$reuse" == 1 ]] && compose_audits - "$content"; then
			discard="audit-drift"
			discard_line=""
			reuse=0 sum_arg=-
		else
			invalid_reason="body (re-sync would audit drifted: $AUD_FAIL)"
		fi
	fi
	# Regenerate branch: regenerate_verdict, with a summary present whenever
	# Step 3 composes one -- the reusable summary, or the fresh draft replacing
	# a discarded one. A reused summary behaves like the drafted one (see
	# DRAFTED_SUMMARY); if composing it with the regenerated block drifts anyway
	# while that block is the branch to be published, it is discarded instead.
	if regenerate_verdict "$([[ -n "$summary_kind" ]] && echo 1 || echo 0)"; then
		if [[ "$reuse" == 1 && -n "$invalid_reason" ]] && ! compose_audits "$summary" "$REGEN"; then
			discard="audit-drift"
			discard_line=""
			reuse=0 sum_arg=-
		fi
		[[ "$regen_needs_summary" == true ]] && summary_required=true
	fi
	if [[ -z "$invalid_reason" && "$reuse" == 1 ]] && ! compose_audits - "$content"; then
		summary_required=true
	fi
	emit_rows true
	exit 0
fi

[[ -r "$list" && -d "$bodies" && -r "$changelog" && -r "$tags" && -n "$web" ]] || die "a2-classify inputs missing or unreadable" 2 environment-failure input-unreadable
# SKILL.md Step A1 item 3: the release inventory is valid only when it parses as
# a top-level JSON array whose EVERY entry carries string `tagName` and `name`
# fields. A shape-only check would let a missing/non-string `name` through and
# classify a candidate against an empty title — fail closed instead.
"$JQ" -e 'type == "array" and all(.[]; type == "object" and (.tagName | type) == "string" and (.name | type) == "string")' \
	<"$list" >/dev/null 2>&1 || die "release list is not a JSON array of {tagName,name} strings" 1 gate-failed release-list-shape
# User-requested fix 2b: a --release-list with two entries sharing the same
# tagName but different name values drove two full classification passes
# emitting two rows for the same version, while `select(...).name | head -n1`
# silently kept only the first title and discarded the second. Gate tagName
# uniqueness unconditionally, the same pre-loop shape-gate pattern as the
# checks immediately around this one, rather than silently processing both
# and discarding one title.
"$JQ" -e '[.[].tagName] | (length == (unique | length))' <"$list" >/dev/null 2>&1 ||
	die "--release-list has a duplicate tagName" 1 gate-failed release-list-duplicate-tag
# --tags is a JSON array of bare tag-name strings (A1.1's origin-authoritative
# inventory) — gated the same way, fail closed on a malformed shape.
"$JQ" -e 'type == "array" and all(.[]; type == "string")' <"$tags" >/dev/null 2>&1 ||
	die "--tags is not a JSON array of strings" 1 gate-failed tags-shape
# --peeled's shape gate (round-3 fix 5): a2-classify reads --peeled inside the
# per-candidate loop below (resolve_source's origin-anchor lookup), not at a
# fixed line number any more now that --tags supplies the tag inventory. Gate
# it here, unconditionally, before the loop — the true "first read" for this
# site — rather than relying on resolve_source's own lazy per-candidate gate,
# which a markerless a2-classify run (every candidate falling through to the
# marker-absent branch before ever reaching resolve_source's peeled lookup)
# would never reach, letting a malformed --peeled (e.g. a bare array) exit 0
# with every row's `prev` silently null instead of failing closed. Setting
# PEELED_SHAPE_OK here makes resolve_source's own gate a no-op for this site;
# step3-recovery (which must not require jq on a markerless run) keeps its
# original lazy behavior, since it never reaches this line.
"$JQ" -e 'type == "object" and all(.[]; type == "string")' <"$peeled" >/dev/null 2>&1 ||
	die "--peeled is not a JSON object of {tagName: sha} strings" 1 gate-failed peeled-shape
PEELED_SHAPE_OK=1
repo_name="${web##*/}"

normalise_changelog

# SKILL.md Step A1 item 4: only STRICT `vX.Y.Z` names enter the T/R/C union —
# each component rejects a leading zero, so `v01.2.3` is a `non-release-tag`,
# not a release row.
SEMVER_TAG='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
# Audit PREV's population is the full origin-authoritative tag inventory
# (--tags, A1.1) — never --peeled's keys (round-3 fix 4). A1.1 explicitly
# permits a tag's peeled identity to be "unavailable" while the tag itself
# stays in the inventory; unavailability costs that one candidate its own
# origin anchor (resolve_source's per-candidate --peeled lookup) and nothing
# else. Deriving all_tags from --peeled's keys instead would silently drop
# such a tag from the PREV-candidate pool too, falsifying an UNRELATED
# candidate's PREV (and therefore its ok/drifted compare-line check) whenever
# the tag immediately below it in SemVer order had no resolved peeled SHA.
all_tags="$("$JQ" -r '.[]' <"$tags" | grep -E "$SEMVER_TAG" | sort -V)"
# User-requested fix 2a: a --release-list candidate whose tag is absent from
# --tags is an input-consistency bug (the two inputs disagree about what tags
# exist), never a legitimate "no previous release" case — but the PREV lookup
# below (`awk '$0==c{print prev;exit}'`) never matches an absent $t, silently
# printing nothing, so that candidate's `prev` came out `null`, indistinguishable
# from a genuine first release. Gate the full --release-list population against
# --tags unconditionally, before the per-candidate loop — the same pre-loop
# shape-gate pattern as release-list-shape/tags-shape/peeled-shape above —
# rather than letting each affected row's `prev` silently null out.
while IFS= read -r t; do
	[[ "$t" =~ $SEMVER_TAG ]] || continue
	# Here-string, not `printf | grep -q`: under pipefail a large inventory
	# would SIGPIPE the writer once grep -q exits early and read as "absent".
	grep -qxF "$t" <<<"$all_tags" ||
		die "release-list tag '$t' is absent from --tags's inventory" 1 gate-failed tag-not-in-inventory
done < <("$JQ" -r '.[].tagName' <"$list")
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
		# the whole audit (SKILL.md's A2 marker-absent bullet). This candidate's
		# body was never read, so neither a marker nor a current template could
		# have participated in its classification — `any_templated` must NOT be
		# set here (round-3 Codex finding: doing so made a wholly untemplated
		# repo's `case` field read "templated" solely because one candidate's
		# body file was missing, contradicting audit-inference.md's field
		# contract that `case` is "templated" only when a marker or current
		# template actually participated).
		rows="$("$JQ" -c --arg v "$ver" --arg p "$prev" '. + [{version: $v, status: "template-marker-unresolvable", note: "release body unavailable for this candidate", prev: (if $p == "" then null else $p end)}]' <<<"$rows")"
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
		excl_list="$tmp/excl.list"
		: >"$excl_list"
		[[ -n "$SRC_FILE" ]] && excluded_headings "$SRC_FILE" >"$excl_list"
		# Body: strip a trailing marker, an optional What's New paragraph, and the
		# compare line. body_stream reads SRC_SCAN (see its comment); the split is
		# whats_new_split, the ONE implementation resync-summary also calls, so
		# Audit's split and Step 3's recovery boundary cannot disagree.
		got="$tmp/got.txt"
		body_stream "$SRC_SCAN" strip >"$got.0"
		# Check (4) of SKILL.md's `ok`/`drifted` bullet: the split-out
		# `## What's New` paragraph's PRESENCE must match the classification
		# source's `whats_new` when it is explicitly set. `whats_new: false`
		# makes a present summary drift, not something merely stripped and
		# ignored; `true`/unset impose no presence requirement here.
		wn="unset"
		[[ -n "$SRC_FILE" ]] && wn="$(template_whats_new "$SRC_FILE")"
		# $prev is already computed once per candidate, above the bfile lookup.
		# Checks (2)-(4) are audit_body_checks, the function resync-summary also
		# runs over the body a re-sync would publish.
		audit_body_checks "$got.0" "$label" "$wn" "$prev" "$t" "$web" "$excl_list" "$ver" "$got"
		compare_ok="$AUD_COMPARE_OK"
		whats_new_ok="$AUD_WN_OK"
		title_ok=0
		if [[ "$title_format" == "bare" ]]; then
			[[ "$name" == "$t" ]] && title_ok=1
		else
			[[ "$name" == "$repo_name $t — "?* ]] && title_ok=1
		fi
		body_note="$AUD_BODY_NOTE"
		body_ok=1
		[[ -z "$body_note" ]] || body_ok=0
		if [[ "$title_ok" == 1 && "$compare_ok" == 1 && "$whats_new_ok" == 1 && "$body_ok" == 1 ]]; then
			status="ok"
		else
			status="drifted"
			# SKILL.md's ok/drifted bullet: "name each failed check in the
			# punch-list Note column — title, body, exact
			# cached-base compare path, and What's New presence-vs-whats_new
			# are independent checks." Build the note from whichever of the
			# four independent checks failed, in that order.
			# ${failed[*]} with IFS=", " joins on only IFS's FIRST character
			# (a single ','), dropping the space — two failures would render
			# "title,body" instead of "title, body". Join explicitly instead.
			failed=()
			[[ "$title_ok" == 1 ]] || failed+=("title")
			[[ "$body_ok" == 1 ]] || failed+=("$body_note")
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
