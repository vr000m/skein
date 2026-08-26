#!/usr/bin/env bash
# claimed-findings.sh — collect the review-gauntlet findings that THIS round
# claims to have fixed, from both claim sources, as one JSONL stream.
#
# Usage:
#   scripts/claimed-findings.sh --envelope <annotated-envelope.json>
#                               [--manifest <auto-fix-manifest.json>]
#                               [--fixer-report <fixer-report.json>]
#
# Stdin: unused.
#
# Stdout: claim finding objects, one JSON object per line — applier-owned
# first, then fixer-owned, preserving the append order the SKILL.md prose this
# replaces used. (The consumer pipes this through finding-key.sh | sort -u, so
# the order is not load-bearing; it is preserved so a diff of the two
# implementations is empty rather than merely equivalent.)
#
# Exit codes:
#   0 — success, INCLUDING zero claims (see "Both sources optional" below)
#   2 — usage error: unknown flag, missing/empty --envelope, a flag given
#       without its value, jq not on PATH, or a NAMED file that cannot be read
#   3 — malformed JSON in the envelope or the manifest/fixer report
#
# There is deliberately no exit 1.
#
# ------------------------------------------------------------------------
# WHY THIS IS A SCRIPT AND NOT PROSE (R11/F2)
#
# This logic lived as ~45 lines of jq inside a numbered comment block in BOTH
# review-gauntlet SKILL.md mirrors, byte-for-byte equivalent and covered by no
# test at all. It now has the same ownership contract as its sibling
# finding-key.sh: canonical here in scripts/, byte-mirrored into each skill by
# scripts/bundle-appliers.sh, tested by tests/gauntlet/test-claimed-findings.sh,
# and invoked from both mirrors as a single anchored call. Two authored copies
# of a rule that decides what enters `fixed_keys` is one copy too many.
#
# ------------------------------------------------------------------------
# THE UNIQUE-(file, line) CLAIM RULE, AND WHY THE KEY CANNOT BE TIGHTENED
#
# The applier's manifest records only (kind, file, line, status, ...) — never
# category or summary. A regression key needs {file, category, summary}
# (finding-key.sh), so the manifest's applied entries must be joined back to
# the annotated envelope on (file, line) to recover the missing fields.
#
# That key CANNOT be tightened with a category: the manifest's `kind` is the
# AUTO-FIX kind (see apply-auto-fix-code.sh), not a review category, so there
# is nothing on the manifest side to match a category against. So a finding is
# claimed only when it is the UNIQUE envelope finding at its (file, line); two
# findings sharing one (file, line) in different categories are BOTH dropped.
#
# The asymmetry that decides this is not a matter of taste:
#   - Under-claiming loses ONE key. At worst a genuinely-fixed finding is
#     re-reported next round and re-fixed. The loop still converges.
#   - Over-claiming promotes a finding NOBODY fixed into the ledger's
#     cumulative `fixed_keys`. Its perfectly legitimate reappearance then
#     fires the TERMINAL `regression` stop — halting a healthy convergence
#     loop on a fiction. That is the exact false positive finding-key.sh's
#     identity design is biased against, and it is unrecoverable without a
#     hand-edited ledger.
# So the rule fails toward under-claiming, deliberately.
#
# ------------------------------------------------------------------------
# BOTH SOURCES OPTIONAL — THE LOAD-BEARING PROPERTY
#
# A clean round runs no fixer and may apply no auto-fix. Each source therefore
# contributes an EMPTY list when its artifact is absent, and an empty stdout is
# a legitimate, successful result — never an error. Concretely:
#   - An UNNAMED source (flag omitted) contributes nothing, silently.
#   - A NAMED source that cannot be read is a wiring bug and exits 2. The
#     distinction matters: "the caller decided there was no manifest" and "the
#     caller pointed at a manifest that isn't there" are different facts.
#   - Every extraction is TOTAL: `($m[0] // [])`, `.findings[]?`, `.claimed[]?`.
#     The unconditional forms exit 5 on a null/absent field, and under the
#     caller's `pipefail` that aborts the round — on exactly the clean round
#     that would otherwise have succeeded. This is the regression that
#     motivated extracting the logic in the first place; do not "simplify" the
#     `?`/`//` away.

set -euo pipefail

usage() {
	echo "usage: claimed-findings.sh --envelope <annotated-envelope.json> [--manifest <auto-fix-manifest.json>] [--fixer-report <fixer-report.json>]" >&2
}

ENVELOPE=""
MANIFEST=""
FIXER_REPORT=""

require_value() {
	# $1 flag name, $2 remaining arg count (including the flag itself)
	if [[ "$2" -lt 2 ]]; then
		echo "claimed-findings: $1 requires a value" >&2
		usage
		exit 2
	fi
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--help | -h)
		usage
		exit 0
		;;
	--envelope)
		require_value "$1" "$#"
		ENVELOPE="$2"
		shift 2
		;;
	--manifest)
		require_value "$1" "$#"
		MANIFEST="$2"
		shift 2
		;;
	--fixer-report)
		require_value "$1" "$#"
		FIXER_REPORT="$2"
		shift 2
		;;
	*)
		echo "claimed-findings: unknown argument '$1'" >&2
		usage
		exit 2
		;;
	esac
done

if ! command -v jq >/dev/null 2>&1; then
	echo "claimed-findings: jq is required but not on PATH" >&2
	exit 2
fi

if [[ -z "$ENVELOPE" ]]; then
	echo "claimed-findings: --envelope is required" >&2
	usage
	exit 2
fi

# A NAMED file must be readable. An UNNAMED one is not an error — see "Both
# sources optional" above.
assert_readable() {
	local flag="$1" path="$2"
	if [[ ! -r "$path" ]]; then
		echo "claimed-findings: $flag file is missing or unreadable: $path" >&2
		exit 2
	fi
}
assert_readable --envelope "$ENVELOPE"
[[ -z "$MANIFEST" ]] || assert_readable --manifest "$MANIFEST"
[[ -z "$FIXER_REPORT" ]] || assert_readable --fixer-report "$FIXER_REPORT"

assert_json() {
	local flag="$1" path="$2"
	# `jq empty`, NOT `jq -e .`: -e sets its exit status from the OUTPUT
	# VALUE, so a perfectly valid document that IS `null` (or `false`) exits
	# 1 and would be misreported as malformed. A literal-null manifest is
	# legitimate -- `($m[0] // [])` below is written precisely to absorb it.
	# `empty` consumes the input and emits nothing, so its status reflects
	# PARSEABILITY alone, which is the property being checked.
	if ! jq empty "$path" >/dev/null 2>&1; then
		echo "claimed-findings: $flag file is not valid JSON: $path" >&2
		exit 3
	fi
}
assert_json --envelope "$ENVELOPE"

# --- 1. applier-owned claims ---------------------------------------------
# Only runs when a manifest was NAMED AND is non-empty. A named-but-zero-byte
# manifest is the applier having produced nothing, not a wiring bug: `-s`
# rather than `-e`, matching the caller's own guard.
if [[ -n "$MANIFEST" && -s "$MANIFEST" ]]; then
	assert_json --manifest "$MANIFEST"
	jq -c --slurpfile m "$MANIFEST" '
		(($m[0] // []) | map(select(.status == "applied"))
		       | map((.file|tostring) + "\u0000" + (.line|tostring))) as $ok
		| ([.findings[]?]
		   | group_by((.file|tostring) + "\u0000" + (.line|tostring))
		   | map(select(length == 1))
		   | add // []) as $unique
		| $unique[]
		| select(((.file|tostring) + "\u0000" + (.line|tostring)) as $k | $ok | index($k))
	' "$ENVELOPE"
fi

# --- 2. fixer-owned claims -----------------------------------------------
if [[ -n "$FIXER_REPORT" && -s "$FIXER_REPORT" ]]; then
	assert_json --fixer-report "$FIXER_REPORT"
	jq -c '.claimed[]?' "$FIXER_REPORT"
fi

exit 0
