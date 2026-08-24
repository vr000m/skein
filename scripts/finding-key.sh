#!/usr/bin/env bash
# finding-key.sh — compute review-gauntlet's regression key for one or more
# findings.
#
# Usage:
#   scripts/finding-key.sh [<findings.jsonl>|-]
#
# Stdin/file: JSON-Lines findings, one object per line, each with at least
# {file, category, summary}. Blank lines and lines that fail to parse as a
# JSON object are skipped silently (same tolerance as reconcile-findings.sh).
#
# Stdout: one regression key per line, in input order —
#   sha1(len(file):file <US> len(category):category <US> len(summary):summary)
# (`<US>` = ASCII 0x1F, kept purely for legibility when debugging — the
# length prefixes, not the separator, are what make the encoding
# unambiguous). File path is used VERBATIM (never lowercased). Category is
# lowercased. Summary is normalised (see below). Missing file/category/
# summary default to "".
#
# Field identity, precisely:
#   - file: VERBATIM, no case-folding. Every gate reports a git path, which
#     is byte-stable across platforms regardless of local filesystem case
#     sensitivity — lowercasing it would collide two genuinely different
#     files (`Foo.md` vs `foo.md` in the git index / on a case-sensitive
#     filesystem) into one regression key, which can produce a FALSE
#     terminal `regression` — the one failure mode this key is explicitly
#     biased against (see the precision rationale below).
#   - category: lowercased. Gates genuinely disagree on casing convention
#     (`Security` vs `security`), and collapsing that is desirable —
#     unlike file, there is no cross-gate case-sensitive identity to lose.
#   - summary: lowercased + whitespace-collapsed (leading/trailing trim,
#     internal runs of whitespace collapsed to a single space). There is NO
#     digit-stripping — two findings in the same file/category whose
#     summaries differ only in a number ("line 12 unused" vs "line 34
#     unused") must produce DISTINCT keys, biasing this key toward precision
#     (a missed regression degrades to today's cap behaviour; a
#     false-positive regression would halt a healthy convergence loop).
#
# The length-prefixed encoding is deliberately injective regardless of field
# content: a literal `|` or `\x1f` inside a summary can no longer shift a
# field boundary the way a bare separator-joined `printf` could. `LC_ALL=C`
# (set below) makes `${#var}` a byte count and makes case-folding ASCII-only
# — both are determinism gains, so the same finding hashes identically on
# any host locale.
#
# This key is DISTINCT BY DESIGN from the reconciler's line-anchored
# (file, line, category) dedup key: a finding that shifts to a different line
# across rounds (the same bug, reported again by a fresh gate pass against a
# changed diff) must still resolve to the SAME regression key, which is
# exactly why `line` is excluded here.
#
# This script is gauntlet-only: registered via `bundle_extra_for
# review-gauntlet` in scripts/lib/bundle-map.sh, NOT `BUNDLE_SHARED` — no
# other skill consumes finding identity in this shape.
#
# Dependencies: bash + jq + shasum|sha1sum.

set -euo pipefail
export LC_ALL=C

usage() {
	echo "usage: finding-key.sh [<findings.jsonl>|-]" >&2
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
	usage
	exit 0
fi

if [[ $# -gt 1 ]]; then
	usage
	exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
	echo "finding-key: jq is required" >&2
	exit 2
fi
if ! command -v shasum >/dev/null 2>&1 && ! command -v sha1sum >/dev/null 2>&1; then
	echo "finding-key: shasum or sha1sum is required" >&2
	exit 2
fi

fk_sha1() {
	if command -v shasum >/dev/null 2>&1; then
		shasum | awk '{print $1}'
	else
		sha1sum | awk '{print $1}'
	fi
}

input_path="${1:--}"

read_input() {
	if [[ "$input_path" == "-" ]]; then
		cat
	else
		cat "$input_path"
	fi
}

# normalise_summary <raw> — lowercase, trim, collapse internal whitespace
# runs to a single space. No digit-stripping (see header comment).
normalise_summary() {
	printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ' | sed -E 's/^ +//; s/ +$//'
}

read_input | while IFS= read -r line; do
	[[ -n "$line" ]] || continue
	if ! printf '%s' "$line" | jq -e 'type == "object"' >/dev/null 2>&1; then
		continue
	fi
	file="$(printf '%s' "$line" | jq -r '.file // ""')"
	category="$(printf '%s' "$line" | jq -r '.category // ""')"
	summary="$(printf '%s' "$line" | jq -r '.summary // ""')"

	file_norm="$file"
	category_norm="$(printf '%s' "$category" | tr '[:upper:]' '[:lower:]')"
	summary_norm="$(normalise_summary "$summary")"

	printf '%d:%s\x1f%d:%s\x1f%d:%s' \
		"${#file_norm}" "$file_norm" \
		"${#category_norm}" "$category_norm" \
		"${#summary_norm}" "$summary_norm" | fk_sha1
done
