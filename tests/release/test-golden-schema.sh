#!/usr/bin/env bash
# Every golden under tests/release/golden/ must carry exactly the frozen key set
# in schema.json (grilled decision 14) with an exit_code in the decision-20
# vocabulary, and every `rows` entry exactly the schema's row keys.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GOLDEN="$HERE/golden"
fail=0
count=0
for f in "$GOLDEN"/*.json; do
	[[ "$(basename "$f")" == "schema.json" ]] && continue
	count=$((count + 1))
	if jq -e --slurpfile s "$GOLDEN/schema.json" '
		(keys == ($s[0].keys | sort))
		and (.exit_code | IN(0, 1, 2))
		and (.rows == null or (.rows | all(keys == ($s[0].row_keys | sort))))
	' "$f" >/dev/null; then
		echo "PASS: $(basename "$f")"
	else
		echo "FAIL: $(basename "$f") violates schema.json" >&2
		fail=1
	fi
done
# Required deliverable (round 8): a2-templated exercises ok, drifted, and
# template-marker-unresolvable.
if jq -e '[.rows[].status] | (index("ok") and index("drifted") and index("template-marker-unresolvable"))' \
	"$GOLDEN/a2-templated.json" >/dev/null; then
	echo "PASS: a2-templated covers ok/drifted/template-marker-unresolvable"
else
	echo "FAIL: a2-templated must cover ok, drifted and template-marker-unresolvable" >&2
	fail=1
fi
[[ "$count" -gt 0 ]] || {
	echo "FAIL: no goldens found" >&2
	exit 1
}
exit "$fail"
