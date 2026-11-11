#!/usr/bin/env bash
set -u

ROOT=${EDITORIAL_PREFLIGHT_ROOT:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"}
SCRIPT=${EDITORIAL_PREFLIGHT_SCRIPT:-"$ROOT/plugins/skein-codex/skills/release/lib/editorial-preflight.sh"}
MIRROR=${EDITORIAL_PREFLIGHT_MIRROR:-"$ROOT/plugins/skein/skills/release/lib/editorial-preflight.sh"}
CHECK_BASH=${TEST_BASH:-/bin/bash}
LEGACY_SCRIPT=${EDITORIAL_PREFLIGHT_LEGACY:-}
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

passes=0
failures=0

pass() {
	passes=$((passes + 1))
}

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	failures=$((failures + 1))
}

write_repeat() {
	/usr/bin/awk -v count="$2" -v char="$3" 'BEGIN { for (i = 0; i < count; i++) printf "%s", char }' >"$1"
}

write_multibyte_repeat() {
	/usr/bin/awk -v count="$2" 'BEGIN { for (i = 0; i < count; i++) printf "\360\237\231\202" }' >"$1"
}

run_case() {
	local label=$1 input=$2 expected=$3 expected_rc=${4:-0} mode=${5:-check}
	local out="$TMP/out" err="$TMP/err" rc=0
	local legacy_out="$TMP/legacy-out" legacy_err="$TMP/legacy-err" legacy_rc=0
	if [[ "$mode" == validate ]]; then
		/usr/bin/env -i PATH=/definitely-missing "$CHECK_BASH" "$SCRIPT" --validate <"$input" >"$out" 2>"$err" || rc=$?
	else
		/usr/bin/env -i PATH=/definitely-missing "$CHECK_BASH" "$SCRIPT" <"$input" >"$out" 2>"$err" || rc=$?
	fi
	if [[ -n "$LEGACY_SCRIPT" ]]; then
		if [[ "$mode" == validate ]]; then
			/usr/bin/env -i PATH=/definitely-missing "$CHECK_BASH" "$LEGACY_SCRIPT" --validate <"$input" >"$legacy_out" 2>"$legacy_err" || legacy_rc=$?
		else
			/usr/bin/env -i PATH=/definitely-missing "$CHECK_BASH" "$LEGACY_SCRIPT" <"$input" >"$legacy_out" 2>"$legacy_err" || legacy_rc=$?
		fi
		if [[ "$rc" -ne "$legacy_rc" ]] || ! cmp -s "$out" "$legacy_out" || ! cmp -s "$err" "$legacy_err"; then
			fail "$label: legacy differential mismatch"
			return
		fi
	fi
	if [[ "$rc" -ne "$expected_rc" ]]; then
		fail "$label: exit $rc, expected $expected_rc"
		return
	fi
	if [[ -n "$expected" ]] && ! cmp -s "$expected" "$out"; then
		fail "$label: stdout mismatch"
		return
	fi
	if [[ -z "$expected" && -s "$out" ]]; then
		fail "$label: expected empty stdout"
		return
	fi
	if [[ -s "$err" ]]; then
		fail "$label: stderr was not empty"
		return
	fi
	pass
}

if [[ -n "$LEGACY_SCRIPT" ]] || cmp -s "$SCRIPT" "$MIRROR"; then
	pass
else
	fail "Claude/Codex checker mirrors differ"
fi

# Body thresholds: equality is accepted; only strict greater-than warns.
for size in 2999 3000 3001; do
	write_repeat "$TMP/input" "$size" x
	warn=0
	[[ "$size" -gt 3000 ]] && warn=1
	printf '1\t%s\t3000\t700\t%s\t0\n' "$size" "$warn" >"$TMP/expected"
	run_case "body-$size" "$TMP/input" "$TMP/expected"
done

# Bullet record thresholds include the marker bytes and exact line endings.
for size in 699 700 701; do
	content=$((size - 2))
	printf -- '- ' >"$TMP/input"
	/usr/bin/awk -v count="$content" 'BEGIN { for (i = 0; i < count; i++) printf "x" }' >>"$TMP/input"
	if [[ "$size" -gt 700 ]]; then
		printf '1\t%s\t3000\t700\t1\t1\n1\t%s\n' "$size" "$size" >"$TMP/expected"
	else
		printf '1\t%s\t3000\t700\t0\t0\n' "$size" >"$TMP/expected"
	fi
	run_case "bullet-$size" "$TMP/input" "$TMP/expected"
done

# Multiline records, both bullet markers, ordinal scope, heading boundaries,
# indented bullets, H4 and fence-shaped text are deterministic.
printf -- '- a\n' >"$TMP/input"
write_repeat "$TMP/tail" 697 x
cat "$TMP/tail" >>"$TMP/input"
printf '1\t701\t3000\t700\t1\t1\n1\t701\n' >"$TMP/expected"
run_case "multiline-record" "$TMP/input" "$TMP/expected"

printf -- '- short\n* ' >"$TMP/input"
write_repeat "$TMP/tail" 699 y
cat "$TMP/tail" >>"$TMP/input"
printf '1\t709\t3000\t700\t1\t1\n2\t701\n' >"$TMP/expected"
run_case "multiple-marker-ordinals" "$TMP/input" "$TMP/expected"

printf -- '- ' >"$TMP/input"
write_repeat "$TMP/tail" 699 z
cat "$TMP/tail" >>"$TMP/input"
printf '\n## stop\nplain' >>"$TMP/input"
printf '1\t715\t3000\t700\t1\t1\n1\t702\n' >"$TMP/expected"
run_case "h2-boundary" "$TMP/input" "$TMP/expected"

printf -- '- a\n  - nested\n#### not-boundary\n```\n- ' >"$TMP/input"
write_repeat "$TMP/tail" 699 q
cat "$TMP/tail" >>"$TMP/input"
printf '1\t738\t3000\t700\t1\t1\n2\t701\n' >"$TMP/expected"
run_case "literal-prefix-grammar" "$TMP/input" "$TMP/expected"

# LF/CRLF and terminal-newline bytes count exactly as Unicode scalars.
printf -- '- a\r\n' >"$TMP/input"
write_repeat "$TMP/tail" 696 r
cat "$TMP/tail" >>"$TMP/input"
printf '1\t701\t3000\t700\t1\t1\n1\t701\n' >"$TMP/expected"
run_case "crlf-record" "$TMP/input" "$TMP/expected"
printf 'abc\n' >"$TMP/input"
printf '1\t4\t3000\t700\t0\t0\n' >"$TMP/expected"
run_case "terminal-lf" "$TMP/input" "$TMP/expected"

# Old-decoder differential snapshots: these expected bytes and exit codes were
# captured from the original per-byte implementation before the fast scanner
# replaced it. Together the cases cover ASCII, mixed UTF-8, 2/3/4-byte scalar
# boundaries, invalid sequences, CRLF, and the complete record grammar.
printf '\302\200\337\277\340\240\200\357\277\277\360\220\200\200\364\217\277\277e\314\201' >"$TMP/input"
printf '1\t8\t3000\t700\t0\t0\n' >"$TMP/expected"
run_case "utf8-valid-boundaries" "$TMP/input" "$TMP/expected"

printf 'ASCII\r\n- two \302\200\337\277\r\n  - indented \340\240\200\n#### continued \360\220\200\200\n## stop\n* four \364\217\277\277' >"$TMP/input"
printf '1\t65\t3000\t700\t0\t0\n' >"$TMP/expected"
run_case "legacy-snapshot-mixed-record-grammar" "$TMP/input" "$TMP/expected"

invalid_index=0
while IFS= read -r bytes; do
	invalid_index=$((invalid_index + 1))
	printf '%b' "$bytes" >"$TMP/input"
	: >"$TMP/empty"
	run_case "utf8-invalid-$invalid_index" "$TMP/input" "$TMP/empty" 1
done <<'EOF'
\200
\300\200
\340\200\200
\355\240\200
\360\200\200\200
\364\220\200\200
\365\200\200\200
\302
\340\240
\360\220\200
EOF

printf 'a\0b' >"$TMP/input"
: >"$TMP/empty"
run_case "nul-rejected" "$TMP/input" "$TMP/empty" 1

# The legacy snapshots also pin exact single-line behavior at and above the
# finite work envelope for ASCII and multibyte-heavy input.
write_repeat "$TMP/input" 65536 x
printf '1\t65536\t3000\t700\t1\t0\n' >"$TMP/expected"
ceiling_started=$SECONDS
run_case "input-ceiling" "$TMP/input" "$TMP/expected"
ceiling_elapsed=$((SECONDS - ceiling_started))
if [[ -n "$LEGACY_SCRIPT" || "$ceiling_elapsed" -le 4 ]]; then
	pass
else
	fail "input ceiling took ${ceiling_elapsed}s (expected at most 4 whole seconds, ensuring less than 5s)"
fi
write_multibyte_repeat "$TMP/input" 16384
printf '1\t16384\t3000\t700\t1\t0\n' >"$TMP/expected"
run_case "input-ceiling-multibyte-single-line" "$TMP/input" "$TMP/expected"
write_repeat "$TMP/input" 65537 x
run_case "input-over-ceiling" "$TMP/input" "$TMP/empty" 1

# Shell syntax stays inert data and never reaches checker output.
# The literal expansion syntax is the test input.
# shellcheck disable=SC2016
printf -v shell_payload '$(touch %s) `id` EOF "quoted"' "$TMP/pwn"
printf '%s' "$shell_payload" >"$TMP/input"
printf '1\t%s\t3000\t700\t0\t0\n' "${#shell_payload}" >"$TMP/expected"
run_case "shell-text-is-data" "$TMP/input" "$TMP/expected"
if [[ ! -e "$TMP/pwn" ]]; then
	pass
else
	fail "shell text executed"
fi

# Canonical validator acceptance.
printf '1\t3001\t3000\t700\t1\t2\n1\t701\n3\t900\n' >"$TMP/input"
cp "$TMP/input" "$TMP/expected"
run_case "validator-valid" "$TMP/input" "$TMP/expected" 0 validate

validator_bad=(
	$'1\t3\t3000\t700\t0\t0'
	$'1\t3\t3000\t700\t0\t0\n\n'
	$'1\t3\t3000\t700\t0\t0\textra\n'
	$'01\t3\t3000\t700\t0\t0\n'
	$'1\t+3\t3000\t700\t0\t0\n'
	$'1\t3.0\t3000\t700\t0\t0\n'
	$'1\t9223372036854775808\t3000\t700\t1\t0\n'
	$'2\t3\t3000\t700\t0\t0\n'
	$'1\t3\t2999\t700\t0\t0\n'
	$'1\t3\t3000\t699\t0\t0\n'
	$'1\t3\t3000\t700\t2\t0\n'
	$'1\t3\t3000\t700\t1\t0\n'
	$'1\t3001\t3000\t700\t0\t0\n'
	$'1\t3\t3000\t700\t1\t1\n0\t701\n'
	$'1\t3\t3000\t700\t1\t2\n2\t701\n2\t702\n'
	$'1\t3\t3000\t700\t1\t2\n2\t701\n1\t702\n'
	$'1\t3\t3000\t700\t1\t1\n1\t700\n'
	$'1\t3\t3000\t700\t1\t2\n1\t701\n'
)
bad_index=0
for candidate in "${validator_bad[@]}"; do
	bad_index=$((bad_index + 1))
	printf '%s' "$candidate" >"$TMP/input"
	run_case "validator-bad-$bad_index" "$TMP/input" "$TMP/empty" 1 validate
done

# Load-bearing threshold mutation: changing 3000 to 3001 must break the
# equality/plus-one fixture, proving the boundary tests observe the code.
sed 's/BODY_LIMIT=3000/BODY_LIMIT=3001/' "$SCRIPT" >"$TMP/mutant.sh"
write_repeat "$TMP/input" 3001 x
printf '1\t3001\t3000\t700\t1\t0\n' >"$TMP/expected"
if "$CHECK_BASH" "$TMP/mutant.sh" <"$TMP/input" | cmp -s - "$TMP/expected"; then
	fail "threshold mutation unexpectedly preserved output"
else
	pass
fi

printf 'Summary: %d passed, %d failed\n' "$passes" "$failures"
[[ "$failures" -eq 0 ]]
