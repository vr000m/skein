#!/usr/bin/env bash
# plan-scope-detect.sh — resolve a `<plan-file> <line>` pair to enclosing
# column-zero markdown headings.
#
# Usage:
#   scripts/plan-scope-detect.sh <plan-file> <line>
#   scripts/plan-scope-detect.sh --stack <plan-file> <line>
#
# Default mode prints a single line to stdout: the deepest heading text that
# encloses the target line, exactly as it appears in the plan (e.g.
# `## Requirements`, `### Phase 2: Foo`). Stack mode prints every enclosing
# heading, outermost-first, one heading per line. For lines before the first
# heading, default mode prints `unknown`; stack mode prints nothing. Fenced
# code blocks (``` or ~~~, indented by up to three spaces per CommonMark) are
# tracked so that headings *inside* a code fence are not treated as real
# headings.
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

MODE="deepest"
if [[ "${1:-}" == "--stack" ]]; then
	MODE="stack"
	shift
fi

if [[ $# -ne 2 ]]; then
	echo "usage: plan-scope-detect.sh [--stack] <plan-file> <line>" >&2
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

awk -v target="$TARGET" -v mode="$MODE" '
	BEGIN { in_fence = 0; fence_char = ""; heading = "unknown"; stack_depth = 0 }
	function emit(  i) {
		if (mode == "stack") {
			# Skip unpopulated heading levels (e.g., a document
			# jumping from # H1 to ### H3 without ## H2 leaves
			# stack[2] unset). Awk auto-vivifies on bare read access
			# so an unguarded `print stack[i]` would emit a blank
			# line and violate the documented schema ("one heading
			# per line, no trailing blank line").
			for (i = 1; i <= stack_depth; i++) {
				if (i in stack) {
					print stack[i]
				}
			}
		} else {
			print heading
		}
	}
	function update_stack(raw,  level, text, i) {
		text = raw
		sub(/[ \t]+$/, "", text)
		match(text, /^#{1,6}/)
		level = RLENGTH
		for (i in stack) {
			if (i >= level) {
				delete stack[i]
			}
		}
		stack[level] = text
		stack_depth = 0
		for (i = 1; i <= 6; i++) {
			if (i in stack) {
				stack_depth = i
			}
		}
		heading = text
	}
	{
		# Track fenced code blocks. Per CommonMark a fence may be indented
		# by up to three spaces and is opened by 3+ backticks OR 3+ tildes,
		# then closed only by a fence using the SAME character. We track the
		# opening char so a plan that opens with ``` and contains a literal
		# ~~~ in prose does not falsely close the fence.
		fence_line = $0
		sub(/^ {0,3}/, "", fence_line)
		if (in_fence == 0 && fence_line ~ /^(```|~~~)/) {
			in_fence = 1
			fence_char = substr(fence_line, 1, 1)
			if (NR == target) { emit(); exit }
			next
		}
		if (in_fence == 1 && substr(fence_line, 1, 1) == fence_char && fence_line ~ /^(```|~~~)/) {
			in_fence = 0
			fence_char = ""
			if (NR == target) { emit(); exit }
			next
		}
		if (in_fence == 1) {
			# Inside a fence; never read headings, just advance.
			if (NR == target) { emit(); exit }
			next
		}
		# Column-zero ATX heading? Markdown requires at least one `#`
		# followed by a space (or end-of-line for an empty heading). We
		# accept 1-6 `#` chars to mirror the markdown spec; the
		# scope-forbid list is matched by the caller against the full
		# heading text.
		if (in_fence == 0 && $0 ~ /^#{1,6}[ \t]/) {
			update_stack($0)
		}
		if (NR == target) { emit(); exit }
	}
	END {
		# If we ran past EOF without hitting the target, still emit the
		# last seen heading so callers get a deterministic answer when
		# the cited line is past the plan length (e.g. drift). The
		# applier treats this as a drift signal upstream.
		if (NR < target) { emit() }
	}
' "$PLAN"
