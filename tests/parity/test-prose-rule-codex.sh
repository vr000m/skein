#!/usr/bin/env bash
# Phase 4 (review-output-formats): Codex plain-prose rule.
# Checks counts, placement and shared block identity with Claude, plus the
# Codex-native gate-1 prompt sentence.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CODEX="$REPO_ROOT/plugins/skein-codex/skills"
CLAUDE="$REPO_ROOT/plugins/skein/skills"
FILES=("$CODEX/review-gauntlet/SKILL.md" "$CODEX/deep-review/SKILL.md" "$CODEX/review-plan/SKILL.md")
CLAUDE_FILES=("$CLAUDE/review-gauntlet/SKILL.md" "$CLAUDE/deep-review/SKILL.md" "$CLAUDE/review-plan/SKILL.md")
GATE="$CODEX/review-gauntlet/native_gates.py"
PASS=0
FAIL=0
pass() {
	PASS=$((PASS + 1))
	echo "PASS: $*"
}
fail() {
	FAIL=$((FAIL + 1))
	echo "FAIL: $*" >&2
}
check() { if [ "$2" -eq 0 ]; then pass "$1"; else fail "$1"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
for f in "${FILES[@]}" "${CLAUDE_FILES[@]}" "$GATE"; do
	[ -f "$f" ] || {
		echo "FAIL: missing $f" >&2
		exit 1
	}
done

count_line() { grep -cxF -- "$2" "$1" || true; }
extract() { # extract <tag> <file> <output>
	awk -v b="<!-- BEGIN PROSE RULE BLOCK $1 -->" -v e="<!-- END PROSE RULE BLOCK $1 -->" '
		$0 == b { if (inb) bad = 1; inb = 1; n++ }
		inb { print }
		$0 == e { if (inb) inb = 0 }
		END { if (inb || bad) exit 3; print "COUNT=" n + 0 }
	' "$2" >"$3"
}

for tag in A B; do
	total=0
	for i in 0 1 2; do
		f="${FILES[$i]}"
		cf="${CLAUDE_FILES[$i]}"
		out="$TMP/$tag.codex.$i"
		cout="$TMP/$tag.claude.$i"
		begin="<!-- BEGIN PROSE RULE BLOCK $tag -->"
		end="<!-- END PROSE RULE BLOCK $tag -->"
		nb="$(count_line "$f" "$begin")"
		ne="$(count_line "$f" "$end")"
		rc=0
		[ "$nb" = "$ne" ] || rc=1
		check "Block $tag anchors balanced in $(basename "$(dirname "$f")")" "$rc"
		rc=0
		extract "$tag" "$f" "$out" || rc=$?
		check "Block $tag well formed in $(basename "$(dirname "$f")")" "$rc"
		# The test's counted occurrence is anchors paired in the source file.
		total=$((total + nb))
		rc=0
		extract "$tag" "$cf" "$cout" || rc=$?
		check "Claude Block $tag reference well formed in $(basename "$(dirname "$cf")")" "$rc"
		# Strip the extraction count footer before byte comparison.
		sed '$d' "$out" >"$out.body"
		sed '$d' "$cout" >"$cout.body"
		rc=0
		cmp -s "$out.body" "$cout.body" || rc=1
		check "Codex Block $tag matches Claude in $(basename "$(dirname "$f")")" "$rc"
	done
	expected=3
	[ "$tag" = A ] && expected=11
	# Count starts/ends equally, so divide the number of BEGIN anchors by actual
	# known skill distribution below; total uses one BEGIN per occurrence.
	rc=0
	[ "$total" -eq "$expected" ] || rc=1
	check "Block $tag total = $expected (got $total)" "$rc"
done

# Distribution: Block A is only in deep-review/review-plan; B is once per skill.
rc=0
[ "$(count_line "${FILES[0]}" '<!-- BEGIN PROSE RULE BLOCK A -->')" -eq 0 ] || rc=1
[ "$(count_line "${FILES[1]}" '<!-- BEGIN PROSE RULE BLOCK A -->')" -eq 5 ] || rc=1
[ "$(count_line "${FILES[2]}" '<!-- BEGIN PROSE RULE BLOCK A -->')" -eq 6 ] || rc=1
check "Block A distribution is 0/5/6" "$rc"
rc=0
for f in "${FILES[@]}"; do [ "$(count_line "$f" '<!-- BEGIN PROSE RULE BLOCK B -->')" -eq 1 ] || rc=1; done
check "Block B appears once in each Codex skill" "$rc"

# In each review-plan lens prompt, Block A follows its output instructions
# inside the dispatched prompt fence and before the separate persistence contract.
rc=0
awk '
	/^[[:space:]]*```/ { fence = !fence; next }
	/^[[:space:]]*## Output$/ { in_output = 1; if (!fence) bad = 1; next }
	/^[[:space:]]*## Lens Persistence Contract/ { in_output = 0 }
	/^<!-- BEGIN PROSE RULE BLOCK A -->$/ {
		if (!in_output || !fence) bad = 1
		count++
	}
	END { if (count != 6 || bad) exit 1 }
' "${FILES[2]}" || rc=$?
check "review-plan Block A reaches each dispatched prompt after Output" "$rc"

# Blocks must carry the finding-key exemption and sit outside generic schema
# blocks and inner schema fences (the outer prompt fences are expected).
for tag in A B; do
	for i in 0 1 2; do
		f="${FILES[$i]}"
		out="$TMP/check.$tag.$i"
		awk -v b="<!-- BEGIN PROSE RULE BLOCK $tag -->" -v e="<!-- END PROSE RULE BLOCK $tag -->" '
			/^<!-- BEGIN GENERIC FINDING SCHEMA AND MERGE -->$/ { gen = 1 }
			/^<!-- END GENERIC FINDING SCHEMA AND MERGE -->$/ { gen = 0 }
			/^[[:space:]]*```/ { line=$0; sub(/^[[:space:]]*```+/, "", line); if (infence) { infence=0; tagged=0 } else { infence=1; tagged=(line != "") }; next }
			$0 == b { active=1 }
			active && (gen || tagged) { bad=1 }
			$0 == e { active=0 }
			END { exit bad }
		' "$f" 2>"$out"
		rc=$?
		check "Block $tag outside generic schema and inner fences in $(basename "$(dirname "$f")")" "$rc"
	done
	doc="$TMP/$tag.codex.1.body"
	rc=0
	# shellcheck disable=SC2016 # backticks are literal text being tested
	grep -qF 'Keep these machine-read values exact: `summary`/`finding`, severity/category labels, status tokens, paths, line numbers, and code.' "$doc" || rc=1
	check "Block $tag names machine-constrained values" "$rc"
	rc=0
	# shellcheck disable=SC2016 # backticks are literal text being tested
	grep -qF 'Apply the prose rule to `evidence`, `suggestion`, and overall summaries, even when tools read them.' "$doc" || rc=1
	check "Block $tag keeps tool-read prose fields in scope" "$rc"
done

GATE1='Write each finding in plain prose: short sentences, active voice, one term per concept, no filler.'
rc=0
grep -qF "$GATE1" "$GATE" || rc=1
check "Codex gate-1 prompt contains plain-prose sentence" "$rc"

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
