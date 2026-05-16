#!/usr/bin/env bash
# plan-scope-detect.sh — resolve a `<plan-file> <line>` pair to the deepest
# enclosing column-zero markdown heading.
#
# Usage:
#   scripts/plan-scope-detect.sh <plan-file> <line>
#
# Prints a single line to stdout: the heading text that encloses the target
# line, exactly as it appears in the plan (e.g. `## Requirements`,
# `### Phase 2: Foo`). Fenced code blocks (``` or ~~~) are tracked so that
# headings *inside* a code fence are not treated as real headings.
#
# Special cases:
#   - If the target line is itself a heading, that heading is returned.
#   - If the target line is inside a fenced code block, the enclosing heading
#     above the fence wins.
#   - If no enclosing heading exists (target sits before the first heading),
#     prints `unknown` and exits 0.
#   - Headings indented by any whitespace are NOT treated as headings (the
#     scope-forbid gate requires structural column-zero `#` characters).
#
# Caller is responsible for matching the returned heading text against the
# scope-forbid list. This script is a pure resolver.

set -euo pipefail

if [[ $# -ne 2 ]]; then
	echo "usage: plan-scope-detect.sh <plan-file> <line>" >&2
	exit 2
fi

PLAN="$1"
TARGET="$2"

if [[ ! -f "$PLAN" ]]; then
	echo "plan-scope-detect: plan file not found: $PLAN" >&2
	exit 2
fi
if ! [[ "$TARGET" =~ ^[0-9]+$ ]]; then
	echo "plan-scope-detect: line must be a positive integer (got '$TARGET')" >&2
	exit 2
fi
if [[ "$TARGET" -lt 1 ]]; then
	echo "plan-scope-detect: line must be >= 1" >&2
	exit 2
fi

awk -v target="$TARGET" '
	BEGIN { in_fence = 0; fence_char = ""; heading = "unknown" }
	{
		# Track fenced code blocks. Per CommonMark a fence is opened by
		# 3+ backticks OR 3+ tildes at column zero, and closed only by a
		# fence using the SAME character. We track the opening char so a
		# plan that opens with ``` and contains a literal ~~~ in prose
		# does not falsely close the fence (which would expose inner
		# content to heading parsing).
		if (in_fence == 0 && $0 ~ /^(```|~~~)/) {
			in_fence = 1
			fence_char = substr($0, 1, 1)
			if (NR == target) { print heading; exit }
			next
		}
		if (in_fence == 1 && substr($0, 1, 1) == fence_char && $0 ~ /^(```|~~~)/) {
			in_fence = 0
			fence_char = ""
			if (NR == target) { print heading; exit }
			next
		}
		if (in_fence == 1) {
			# Inside a fence; never read headings, just advance.
			if (NR == target) { print heading; exit }
			next
		}
		# Column-zero ATX heading? Markdown requires at least one `#`
		# followed by a space (or end-of-line for an empty heading). We
		# accept 1-6 `#` chars to mirror the markdown spec; the
		# scope-forbid list is matched by the caller against the full
		# heading text.
		if (in_fence == 0 && $0 ~ /^#{1,6}[ \t]/) {
			heading = $0
			# Strip trailing whitespace so the caller can compare
			# against canonical forms like `## Requirements`.
			sub(/[ \t]+$/, "", heading)
		}
		if (NR == target) { print heading; exit }
	}
	END {
		# If we ran past EOF without hitting the target, still emit the
		# last seen heading so callers get a deterministic answer when
		# the cited line is past the plan length (e.g. drift). The
		# applier treats this as a drift signal upstream.
		if (NR < target) { print heading }
	}
' "$PLAN"
