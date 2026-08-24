#!/usr/bin/env bash
# lens-budget.sh — one size-scaled budget formula for every bounded
# reviewer this repo spawns: the review-gauntlet Codex gate, and (from
# Phase 2 onward) deep-review/review-plan lens subagents. Canonical
# source lives here; it is bundled into review-gauntlet's mirrors via
# `bundle_extra_for review-gauntlet` (see scripts/lib/bundle-map.sh) and
# promoted to BUNDLE_SHARED once deep-review/review-plan start invoking it.
#
# Usage:
#   lens-budget.sh --kind lens|plan-lens|codex [--files N] [--lines N]
#                   [--sections N] [--gate-timeout SECONDS | --override SECONDS]
#
# Formula (seconds, coefficients are untuned guesses — Codex ~0.5m/file
# from an observed ~11.5-minute baseline):
#   lens      = clamp(120 + 45*files + 10*(lines/100), floor=300,  cap=1800)
#   plan-lens = clamp(120 + 20*sections,                floor=300,  cap=1800)
#   codex     = clamp(2 * lens(files, lines),            floor=1200, cap=2700)
#
# --gate-timeout / --override (synonyms) short-circuit the formula
# entirely: the given value is echoed back unchanged, no clamping applied
# — an explicit operator override always beats the computed budget.
#
# Output: the computed (or overridden) budget in seconds, on stdout, no
# trailing text.
#
# Exit codes: 0 success. 2 usage/validation error (missing/unknown --kind,
# non-numeric input).

set -euo pipefail

usage() {
	cat >&2 <<'EOF'
usage: lens-budget.sh --kind lens|plan-lens|codex [--files N] [--lines N]
                       [--sections N] [--gate-timeout SECONDS | --override SECONDS]
EOF
}

is_nonneg_int() {
	[[ "$1" =~ ^[0-9]+$ ]]
}

kind=""
files=0
lines=0
sections=0
override=""

while [[ $# -gt 0 ]]; do
	case "$1" in
	--kind)
		shift
		[[ $# -gt 0 ]] || {
			usage
			exit 2
		}
		kind="$1"
		;;
	--files)
		shift
		[[ $# -gt 0 ]] || {
			usage
			exit 2
		}
		files="$1"
		;;
	--lines)
		shift
		[[ $# -gt 0 ]] || {
			usage
			exit 2
		}
		lines="$1"
		;;
	--sections)
		shift
		[[ $# -gt 0 ]] || {
			usage
			exit 2
		}
		sections="$1"
		;;
	--gate-timeout | --override)
		shift
		[[ $# -gt 0 ]] || {
			usage
			exit 2
		}
		override="$1"
		;;
	--help | -h)
		usage
		exit 0
		;;
	*)
		echo "lens-budget: unrecognised argument: $1" >&2
		usage
		exit 2
		;;
	esac
	shift
done

if [[ -n "$override" ]]; then
	if ! is_nonneg_int "$override"; then
		echo "lens-budget: --gate-timeout/--override must be a non-negative integer number of seconds (got '$override')" >&2
		exit 2
	fi
	printf '%s\n' "$override"
	exit 0
fi

if [[ -z "$kind" ]]; then
	echo "lens-budget: --kind is required" >&2
	usage
	exit 2
fi

for v in "$files" "$lines" "$sections"; do
	is_nonneg_int "$v" || {
		echo "lens-budget: --files/--lines/--sections must be non-negative integers (got '$v')" >&2
		exit 2
	}
done

clamp() {
	local value="$1" floor="$2" cap="$3"
	if ((value < floor)); then
		value="$floor"
	elif ((value > cap)); then
		value="$cap"
	fi
	printf '%s' "$value"
}

lens_seconds() {
	local f="$1" l="$2"
	local raw=$((120 + 45 * f + (10 * l) / 100))
	clamp "$raw" 300 1800
}

plan_lens_seconds() {
	local s="$1"
	local raw=$((120 + 20 * s))
	clamp "$raw" 300 1800
}

codex_seconds() {
	local f="$1" l="$2"
	local lens_s
	lens_s="$(lens_seconds "$f" "$l")"
	local raw=$((2 * lens_s))
	clamp "$raw" 1200 2700
}

case "$kind" in
lens) lens_seconds "$files" "$lines" ;;
plan-lens) plan_lens_seconds "$sections" ;;
codex) codex_seconds "$files" "$lines" ;;
*)
	echo "lens-budget: unknown --kind '$kind' (expected lens|plan-lens|codex)" >&2
	exit 2
	;;
esac
echo
