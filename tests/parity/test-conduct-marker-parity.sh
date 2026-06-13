#!/usr/bin/env bash
# Verify conduct/marker.py is byte-identical between the skein (Claude) and
# skein-codex mirrors.
#
# marker.py is the review-marker hash authority: it computes the content hash
# /conduct uses to decide whether a reviewed plan has drifted. Unlike its
# sibling modules (conductor.py, parser.py, ...), it imports only the standard
# library, so there is no harness-divergent idiom to justify a difference — the
# two copies are, and must remain, byte-identical. A one-sided edit to the hash
# logic (e.g. reintroducing line-ending normalization in one mirror) would
# silently make the Claude and Codex plugins disagree on staleness for the same
# plan. This guard fails fast on that drift.
#
# Exit codes: 0 clean, 1 drift (or a copy missing).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

CLAUDE="$ROOT_DIR/plugins/skein/skills/conduct/marker.py"
CODEX="$ROOT_DIR/plugins/skein-codex/skills/conduct/marker.py"

pass_count=0
fail_count=0

fail() {
	echo "FAIL: $1"
	fail_count=$((fail_count + 1))
}

pass() {
	echo "PASS: $1"
	pass_count=$((pass_count + 1))
}

for f in "$CLAUDE" "$CODEX"; do
	if [[ ! -f "$f" ]]; then
		fail "missing $f"
	fi
done

if [[ $fail_count -eq 0 ]]; then
	if diff -q "$CLAUDE" "$CODEX" >/dev/null 2>&1; then
		pass "conduct/marker.py byte-identical across mirrors"
	else
		fail "conduct/marker.py differs between mirrors:"
		diff "$CLAUDE" "$CODEX" || true
	fi
fi

echo ""
echo "Summary: $pass_count passed, $fail_count failed"
[[ $fail_count -eq 0 ]]
