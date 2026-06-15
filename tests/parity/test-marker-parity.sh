#!/usr/bin/env bash
# Verify the canonical scripts/marker.py is the single hashing authority and
# that every bundled / mirrored copy is byte-identical to it, then prove the
# write->recompute round-trip is stable across the edge cases that triggered
# the dropped-newline staleness bug.
#
# Part (a) — Anchored byte-identity. scripts/marker.py is the NAMED ANCHOR.
# Every operative copy (conduct skein/codex, review-plan skein/codex) must be
# byte-identical to it (diff -q). A one-sided edit to the hash logic in any
# mirror would silently make the plugins disagree on plan staleness; anchoring
# every copy to a single canonical file (rather than a pairwise/4-way mutual
# diff that passes even when all copies drift together) fails fast on that.
#
# Part (b) — Behavioural round-trip. write_marker mutates the file (it appends
# a trailing newline to the above-marker bytes when absent, marker.py:209-211),
# so the recorded sha must be validated against the POST-WRITE on-disk bytes,
# exactly as /conduct preflight does. For each edge-case fixture:
#     sha_written   = write_marker(plan)
#     sha_recompute = compute_plan_hash(plan)   # reads post-write bytes
#     assert sha_written == sha_recompute
# Hashing a pristine fixture on both sides would spuriously fail the
# no-EOF-newline case. Each fixture carries a real marker or the template
# placeholder so write_marker has a divider to place the marker at.
#
# Out of scope (owned by Phase 4 / the review-plan-marker-write test): the
# named 9fa0989-vs-df8d891 byte-faithful-vs-rstripped divergence assertion and
# the abort / no-divider cases. This test stays focused on (a) and (b).
#
# Exit codes: 0 clean, 1 drift / missing copy / round-trip mismatch.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

ANCHOR="$ROOT_DIR/scripts/marker.py"

COPIES=(
	"$ROOT_DIR/plugins/skein/skills/conduct/marker.py"
	"$ROOT_DIR/plugins/skein-codex/skills/conduct/marker.py"
	"$ROOT_DIR/plugins/skein/skills/review-plan/scripts/marker.py"
	"$ROOT_DIR/plugins/skein-codex/skills/review-plan/scripts/marker.py"
)

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

# --- (a) Anchored byte-identity: every copy == canonical scripts/marker.py ---
if [[ ! -f "$ANCHOR" ]]; then
	fail "missing canonical anchor scripts/marker.py"
else
	for copy in "${COPIES[@]}"; do
		rel="${copy#"$ROOT_DIR"/}"
		if [[ ! -f "$copy" ]]; then
			fail "missing copy $rel"
		elif diff -q "$ANCHOR" "$copy" >/dev/null 2>&1; then
			pass "byte-identical to anchor: $rel"
		else
			fail "drift $rel != canonical scripts/marker.py:"
			diff "$ANCHOR" "$copy" || true
		fi
	done
fi

# --- (b) Behavioural round-trip across edge-case fixtures --------------------
# Run only when the anchor exists and git is available (write_marker shells to
# git hash-object). Each fixture writes bytes to a temp file, then in Python
# importing the canonical scripts/marker.py:
#     sha_written = write_marker(tmp); sha_recompute = compute_plan_hash(tmp)
# and asserts equality on the post-write file.
roundtrip_fixture() {
	local label="$1"
	local pyfixture="$2"          # python *literal* (ast.literal_eval) -> bytes
	local check_placeholder="${3:-}" # "1" => also assert no placeholder survives

	local tmpdir
	tmpdir="$(mktemp -d)"
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	local out
	if out="$(
		ANCHOR="$ANCHOR" TMPDIR_FIX="$tmpdir" FIXBYTES="$pyfixture" \
			CHECK_PLACEHOLDER="$check_placeholder" python3 - <<'PY'
import ast, os, sys, importlib.util

anchor = os.environ["ANCHOR"]
spec = importlib.util.spec_from_file_location("canonical_marker", anchor)
marker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(marker)

tmp = os.path.join(os.environ["TMPDIR_FIX"], "plan.md")
# ast.literal_eval (not eval) — the fixture is a byte literal only; no code runs.
data = ast.literal_eval(os.environ["FIXBYTES"])
assert isinstance(data, (bytes, bytearray)), "fixture must yield bytes"
with open(tmp, "wb") as fh:
    fh.write(data)

sha_written = marker.write_marker(tmp)
sha_recompute = marker.compute_plan_hash(tmp)  # reads POST-WRITE bytes

ok = sha_written == sha_recompute
detail = f"written={sha_written} recompute={sha_recompute}"

if os.environ.get("CHECK_PLACEHOLDER") == "1":
    post = open(tmp, "rb").read().decode("utf-8")
    survivors = [l for l in post.splitlines() if marker.MARKER_PLACEHOLDER_RE.match(l)]
    if survivors:
        ok = False
        detail += f" | placeholder survived: {survivors!r}"
    else:
        detail += " | no placeholder survived"

print(detail)
sys.exit(0 if ok else 1)
PY
	)"; then
		pass "round-trip $label ($out)"
	else
		fail "round-trip $label ($out)"
	fi
}

if [[ ! -f "$ANCHOR" ]]; then
	echo "SKIP: round-trip (canonical anchor absent)"
elif ! command -v git >/dev/null 2>&1; then
	echo "SKIP: round-trip (git not available)"
else
	REAL_MARKER='<!-- reviewed: 2026-06-15 @ 0000000000000000000000000000000000000000 -->'
	PLACEHOLDER='<!-- reviewed: YYYY-MM-DD @ <hash> -->'

	# Trailing blank line immediately above the marker (named regression for the
	# dropped-newline bug): the blank line before the marker must be preserved by
	# the byte-faithful slice, so write and recompute agree.
	roundtrip_fixture "trailing-blank-above-marker" \
		"b'# Plan\n\nContract body.\n\n${REAL_MARKER}\n\n## Workspace\n'"

	# No trailing newline at EOF: write_marker appends a newline to the
	# above-marker bytes; compute_plan_hash must hash that post-write form. (A
	# pristine-vs-pristine comparison would spuriously fail this case.)
	roundtrip_fixture "no-eof-newline" \
		"b'# Plan\n\nContract body.\n${REAL_MARKER}'"

	# CRLF line endings preserved byte-faithfully above the marker.
	roundtrip_fixture "crlf" \
		"b'# Plan\r\n\r\nContract body.\r\n\r\n${REAL_MARKER}\r\n\r\n## Workspace\r\n'"

	# Template placeholder divider (first review): write_marker replaces it in
	# place; additionally assert NO MARKER_PLACEHOLDER_RE line survives the write.
	roundtrip_fixture "placeholder-divider" \
		"b'# Plan\n\nContract body.\n\n${PLACEHOLDER}\n\n## Workspace\n'" \
		"1"
fi

echo ""
echo "Summary: $pass_count passed, $fail_count failed"
# Non-vacuous-pass guard: if nothing was checked we would exit 0 with no
# evidence. Require at least one pass.
if [[ "$pass_count" -eq 0 ]]; then
	echo "FAIL: vacuous pass — no assertions ran (anchor/copies missing?)"
	exit 1
fi
[[ "$fail_count" -eq 0 ]]
