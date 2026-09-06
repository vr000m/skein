#!/usr/bin/env bash
# Verify auto-fix allowlist arrays stay byte-identical between the source JSON
# and the four SKILL.md mirrors that document the lens contract.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ALLOWLIST="$ROOT_DIR/scripts/auto-fix-allowlist.json"

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

if [[ ! -f "$ALLOWLIST" ]]; then
	fail "preflight (missing scripts/auto-fix-allowlist.json)"
	echo ""
	echo "Summary: $pass_count passed, $fail_count failed"
	exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
	fail "preflight (python3 required to parse auto-fix-allowlist.json)"
	echo ""
	echo "Summary: $pass_count passed, $fail_count failed"
	exit 1
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

allowlist_preflight_rc=0
python3 - "$ALLOWLIST" >"$tmpdir/arrays.tsv" <<'PY' 2>"$tmpdir/python.err" || allowlist_preflight_rc=$?
import json
import sys

path = sys.argv[1]
expected = {
    "deep-review": [
        "docstring_typo",
        "unused_import",
        "unused_var",
        "mechanical_replace",
        "import_sort",
    ],
    "review-plan": [
        "symbol_rename",
        "path_rename",
        "line_anchor_refresh",
        "marker_refresh",
        "prose_typo",
        "prose_clarify",
    ],
}

with open(path, encoding="utf-8") as fh:
    data = json.load(fh)

if data != expected:
    raise SystemExit(f"allowlist JSON does not match the Phase 1 contract: {data!r}")

for skill in ("deep-review", "review-plan"):
    print(f"{skill}\t{json.dumps(data[skill], ensure_ascii=False, separators=(',', ':'))}")
PY
if [[ "$allowlist_preflight_rc" -ne 0 ]]; then
	fail "preflight (allowlist JSON parse/contract check failed)"
	sed 's/^/  /' "$tmpdir/python.err"
	echo ""
	echo "Summary: $pass_count passed, $fail_count failed"
	exit 1
fi

check_skill_array() {
	local allowlist_key="$1"
	local array_literal="$2"
	local target
	local seen=0

	for target in \
		"$ROOT_DIR/plugins/skein/skills/deep-review/SKILL.md" \
		"$ROOT_DIR/plugins/skein/skills/review-plan/SKILL.md" \
		"$ROOT_DIR/plugins/skein-codex/skills/deep-review/SKILL.md" \
		"$ROOT_DIR/plugins/skein-codex/skills/review-plan/SKILL.md"; do
		seen=$((seen + 1))
		if [[ ! -f "$target" ]]; then
			fail "$allowlist_key allowlist mirror missing: $target"
			continue
		fi
		if grep -Fq -- "$array_literal" "$target"; then
			pass "$allowlist_key allowlist cited byte-identically in ${target#"$ROOT_DIR"/}"
		else
			fail "$allowlist_key allowlist drift in ${target#"$ROOT_DIR"/}"
			echo "  expected literal: $array_literal"
		fi
	done

	if [[ "$seen" -ne 4 ]]; then
		fail "$allowlist_key expected four mirrors, saw $seen"
	fi
}

while IFS=$'\t' read -r skill array_literal; do
	[[ -z "$skill" ]] && continue
	check_skill_array "$skill" "$array_literal"
done <"$tmpdir/arrays.tsv"

echo ""
echo "Summary: $pass_count passed, $fail_count failed"

if [[ "$fail_count" -ne 0 ]]; then
	exit 1
fi
