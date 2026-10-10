#!/usr/bin/env bash
# Phase 1 (review-output-formats): Claude plain-prose rule.
# Asserts Block A (authoring rule, 11 copies) and Block B (summary-prose rule,
# 3 copies) across the three Claude SKILL.md files: exact counts, byte-identical
# copies, exemption sentence, anchor placement, no routing tokens, and the
# gate-1 sentence in review-gauntlet.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SK="$REPO_ROOT/plugins/skein/skills"
GAUNTLET="$SK/review-gauntlet/SKILL.md"
DEEP="$SK/deep-review/SKILL.md"
PLAN="$SK/review-plan/SKILL.md"
FILES=("$GAUNTLET" "$DEEP" "$PLAN")

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
check() { # check <desc> <status>
	if [ "$2" -eq 0 ]; then pass "$1"; else fail "$1"; fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for f in "${FILES[@]}"; do
	[ -f "$f" ] || {
		echo "FAIL: missing $f" >&2
		exit 1
	}
done

# Count anchor lines (own line, exact) in a file.
count_line() { grep -cxF -- "$2" "$1" || true; }

# Extract every occurrence of a block (inclusive of anchors) to
# $TMP/<tag>.<file-idx>.<n>; prints the number extracted for that file.
extract() { # extract <tag> <file> <idx>
	awk -v b="<!-- BEGIN PROSE RULE BLOCK $1 -->" \
		-v e="<!-- END PROSE RULE BLOCK $1 -->" \
		-v out="$TMP/$1.$3" '
		$0 == b { if (inb) bad = 1; inb = 1; n++; file = out "." n; }
		inb { print > file }
		$0 == e { if (inb) { close(file); inb = 0 } }
		END { if (inb) bad = 1; print n + 0 + 0; if (bad) exit 3 }
	' "$2"
}

declare -A TOTAL
for tag in A B; do
	TOTAL[$tag]=0
	i=0
	for f in "${FILES[@]}"; do
		i=$((i + 1))
		b="<!-- BEGIN PROSE RULE BLOCK $tag -->"
		e="<!-- END PROSE RULE BLOCK $tag -->"
		nb="$(count_line "$f" "$b")"
		ne="$(count_line "$f" "$e")"
		rc=0
		[ "$nb" = "$ne" ] || rc=1
		check "Block $tag BEGIN/END balanced in $(basename "$(dirname "$f")") ($nb/$ne)" "$rc"
		set +e
		n="$(extract "$tag" "$f" "$i")"
		rc=$?
		set -e
		check "Block $tag anchors well-formed (no nesting/unterminated) in $(basename "$(dirname "$f")")" "$rc"
		TOTAL[$tag]=$((TOTAL[$tag] + n))
		eval "N_${tag}_$i=$n"
	done
done

# Exact counts overall.
rc=0
[ "${TOTAL[A]}" -eq 11 ] || rc=1
check "Block A total = 11 (got ${TOTAL[A]})" "$rc"
rc=0
[ "${TOTAL[B]}" -eq 3 ] || rc=1
check "Block B total = 3 (got ${TOTAL[B]})" "$rc"

# Per-file distribution: A none in gauntlet; B one per skill.
rc=0
[ "${N_A_1}" -eq 0 ] || rc=1
check "review-gauntlet has no Block A (got ${N_A_1})" "$rc"
rc=0
[ "${N_A_2}" -eq 5 ] || rc=1
check "deep-review has 5 Block A (got ${N_A_2})" "$rc"
rc=0
[ "${N_A_3}" -eq 6 ] || rc=1
check "review-plan has 6 Block A (got ${N_A_3})" "$rc"
for i in 1 2 3; do
	eval "nb=\${N_B_$i}"
	rc=0
	[ "$nb" -eq 1 ] || rc=1
	check "$(basename "$(dirname "${FILES[$((i - 1))]}")") has exactly 1 Block B (got $nb)" "$rc"
done

# Byte-identity across copies, and content checks per block.
for tag in A B; do
	first=""
	for blk in "$TMP/$tag".*; do
		[ -e "$blk" ] || continue
		if [ -z "$first" ]; then
			first="$blk"
			continue
		fi
		rc=0
		cmp -s "$first" "$blk" || rc=$?
		check "Block $tag copy $(basename "$blk") byte-identical to $(basename "$first")" "$rc"
	done
	if [ -n "$first" ]; then
		rc=0
		# shellcheck disable=SC2016 # literal backticks intended
		grep -qF 'the finding summary line (`summary` in deep-review, `finding` in review-plan lens prompts)' "$first" || rc=$?
		check "Block $tag contains exemption sentence naming both fields" "$rc"
		rc=0
		grep -qE 'model:|effort:|reasoning_effort=' "$first" && rc=1
		check "Block $tag has no model:/effort:/reasoning_effort= tokens" "$rc"
		rc=0
		grep -qE '^[[:space:]]*```' "$first" && rc=1
		check "Block $tag contains no code fence lines" "$rc"
	else
		fail "Block $tag has no extracted copy to check"
	fi
done

# Anchor placement: not inside GENERIC FINDING SCHEMA AND MERGE, not inside an
# inner (info-string) fence. Outer lens-prompt fences are bare ``` and expected.
for f in "${FILES[@]}"; do
	name="$(basename "$(dirname "$f")")"
	out="$(awk '
		/^<!-- BEGIN GENERIC FINDING SCHEMA AND MERGE -->$/ { gen = 1 }
		/^<!-- END GENERIC FINDING SCHEMA AND MERGE -->$/ { gen = 0 }
		/^[[:space:]]*```/ {
			line = $0; sub(/^[[:space:]]*```+/, "", line)
			if (infence) { infence = 0; tagged = 0 }
			else { infence = 1; tagged = (line != "") }
			next
		}
		/^<!-- (BEGIN|END) PROSE RULE BLOCK [AB] -->$/ {
			if (gen) print NR ": inside GENERIC FINDING SCHEMA AND MERGE"
			if (tagged) print NR ": inside inner info-string fence"
		}
	' "$f")"
	rc=0
	[ -z "$out" ] || rc=1
	check "anchors in $name outside GENERIC block and inner schema fences${out:+ ($out)}" "$rc"
done

# Gate-1 sentence: exactly one full line in review-gauntlet.
GATE1='Write each finding in plain prose: short sentences, active voice, one term per concept, no filler.'
c="$(grep -cF -- "$GATE1" "$GAUNTLET" || true)" # list-item continuation may indent the line
rc=0
[ "$c" -ge 1 ] || rc=1
check "gate-1 sentence present as its own line in review-gauntlet (count $c)" "$rc"

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
