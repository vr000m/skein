#!/usr/bin/env bash
# Single-invocation regression: the test command is invoked exactly once
# per applied fix (no retry). Implements Review Focus "single-shot, no
# retry" and AC #4 (last sentence).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

require_applier

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

d="$scratch/repo"
mkdir -p "$d"
make_repo "$d" >/dev/null
printf 'from os import path\n' >"$d/a.py"
git -C "$d" add a.py
git -C "$d" commit -q -m "add a.py"

# Counter shim — each invocation appends one line to a counter file.
counter_file="$scratch/counter"
shim="$scratch/shim.sh"
cat >"$shim" <<EOF
#!/usr/bin/env bash
printf '.' >>"$counter_file"
exit 0
EOF
chmod +x "$shim"
: >"$counter_file"

cp "$FIXTURES_DIR/unused_import-accept.jsonl" "$d/findings.json"
run_applier "$d" --test-cmd "$shim" "$d/findings.json"

invocations="$(wc -c <"$counter_file" | tr -d ' ')"
if [[ "$invocations" -eq 1 ]]; then
	pass "test command invoked exactly once (counter=$invocations)"
else
	fail "expected test command invoked exactly 1x for 1 fix; got $invocations"
	echo "$LAST_OUT" | sed 's/^/  /'
fi

summary_and_exit
