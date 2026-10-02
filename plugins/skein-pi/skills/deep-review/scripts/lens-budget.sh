#!/usr/bin/env bash
# lens-budget.sh — one size-scaled budget formula for every bounded
# reviewer this repo spawns: the review-gauntlet Codex gate, and (from
# Phase 2 onward) deep-review/review-plan lens subagents. Canonical
# source lives here; it is BUNDLE_SHARED (see scripts/lib/bundle-map.sh),
# promoted from a review-gauntlet-only `bundle_extra_for` entry once
# deep-review/review-plan began invoking it for their own per-lens budgets.
#
# Usage:
#   lens-budget.sh --kind lens|plan-lens|codex [--files N] [--lines N]
#                   [--sections N] [--gate-timeout SECONDS]
#
# Formula (seconds, coefficients are untuned guesses — Codex ~0.5m/file
# from an observed ~11.5-minute baseline):
#   lens      = clamp(120 + 45*files + 10*(lines/100), floor=300,  cap=1800)
#   plan-lens = clamp(120 + 20*sections,                floor=300,  cap=1800)
#   codex     = clamp(2 * lens(files, lines),            floor=1200, cap=2700)
#
# --gate-timeout short-circuits the formula entirely: the given value is
# echoed back unchanged, no clamping applied — an explicit operator
# override always beats the computed budget. It is the ONE override flag
# name (an earlier `--override` alias was removed: one name, one behaviour,
# in a script bundled into three skills). Must be a positive integer
# (>= 1); a budget below 1 second is rejected here
# because GNU `timeout 0s` and the shim's `proc.wait(timeout=0.0)` mean
# opposite things ("unbounded" vs. "instant expiry") for the same input.
#
# Output: the computed (or overridden) budget in seconds, on stdout, no
# trailing text. Numeric inputs are evaluated with an explicit `10#` base
# prefix, so a zero-padded value like `08` is eight, not an octal parse
# error. stdout is either a complete budget line or nothing at all: a
# caller doing `budget="$(lens-budget.sh ...)"` never sees an empty budget
# alongside exit 0.
#
# Exit codes: 0 success. 2 usage/validation error (missing/unknown --kind,
# non-numeric input). Non-zero (and empty stdout) if the arithmetic itself
# fails.

set -euo pipefail

usage() {
	cat >&2 <<'EOF'
usage: lens-budget.sh --kind lens|plan-lens|codex [--files N] [--lines N]
                       [--sections N] [--gate-timeout SECONDS]
EOF
}

is_nonneg_int() {
	[[ "$1" =~ ^[0-9]+$ ]]
}

is_pos_int() {
	[[ "$1" =~ ^[0-9]+$ ]] && ((10#$1 >= 1))
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
	--gate-timeout)
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

# `--kind` is required and validated on EVERY path, the --gate-timeout
# override included. It used to be checked only below the override's early
# `exit 0` and again in the dispatching `case`, so `--gate-timeout 5` with no
# --kind (and `--kind unknown --gate-timeout 5`) printed a budget and exited
# 0 while the header documents exit 2 -- a typo'd kind silently took the
# operator's override instead of failing loudly. Hoisted here, above the
# override; the dispatch `case` below keeps its arms and no longer needs an
# error arm.
validate_kind() {
	if [[ -z "$kind" ]]; then
		echo "lens-budget: --kind is required" >&2
		usage
		exit 2
	fi
	case "$kind" in
	lens | plan-lens | codex) ;;
	*)
		echo "lens-budget: unknown --kind '$kind' (expected lens|plan-lens|codex)" >&2
		exit 2
		;;
	esac
}

validate_kind

if [[ -n "$override" ]]; then
	if ! is_pos_int "$override"; then
		echo "lens-budget: --gate-timeout must be a positive integer number of seconds (>= 1); got '$override'" >&2
		exit 2
	fi
	printf '%s\n' "$override"
	exit 0
fi

for v in "$files" "$lines" "$sections"; do
	is_nonneg_int "$v" || {
		echo "lens-budget: --files/--lines/--sections must be non-negative integers (got '$v')" >&2
		exit 2
	}
done

# Every operand below is forced to base 10 with `10#`. is_nonneg_int admits
# a zero-padded value like "08", and bash's default base would read that as
# octal and fail the whole expression.
#
# Every arithmetic assignment is also SPLIT from its `local` declaration.
# `local raw=$((...))` reports `local`'s exit status, not the arithmetic's,
# so a failed expression was invisible to `set -e` — the function returned
# 0, the trailing bare `echo` supplied a newline, and the script exited 0
# having printed no budget. Declaring first makes the assignment its own
# command, so `set -e` sees the failure.
clamp() {
	local value="$1" floor="$2" cap="$3"
	if ((10#$value < 10#$floor)); then
		value="$floor"
	elif ((10#$value > 10#$cap)); then
		value="$cap"
	fi
	printf '%s\n' "$value"
}

lens_seconds() {
	local f="$1" l="$2"
	local raw
	raw=$((120 + 45 * 10#$f + (10 * 10#$l) / 100))
	clamp "$raw" 300 1800
}

plan_lens_seconds() {
	local s="$1"
	local raw
	raw=$((120 + 20 * 10#$s))
	clamp "$raw" 300 1800
}

codex_seconds() {
	local f="$1" l="$2"
	local lens_s
	lens_s="$(lens_seconds "$f" "$l")"
	local raw
	raw=$((2 * 10#$lens_s))
	clamp "$raw" 1200 2700
}

# Every arm here is already proven reachable by validate_kind above, which
# rejects an unknown --kind before the override; this `case` dispatches only.
case "$kind" in
lens) lens_seconds "$files" "$lines" ;;
plan-lens) plan_lens_seconds "$sections" ;;
codex) codex_seconds "$files" "$lines" ;;
esac
