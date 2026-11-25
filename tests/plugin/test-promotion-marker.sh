#!/usr/bin/env bash
# Decision-promotion contract.
#   Part 1 (marker): a below-marker promotion edit leaves a signed plan's marker
#   line, signed bytes and hash unchanged (invariant I1), and a supersession must
#   update both records for check-decisions.sh to pass.
#   Part 2 (wording): the selected mirror's update-docs keeps record writes
#   behind per-record approval, even with --apply, with a narrow creation rule
#   and refusals for a missing, placeholder or stale marker (invariant I3).
#
# Usage: test-promotion-marker.sh [--mirror claude|codex|both]   (default both)
# shellcheck disable=SC2016  # backticks and ${...} are literal skill text
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WRITER="$REPO_ROOT/plugins/skein/skills/review-plan/scripts/write-review-marker.py"
MARKER_LIB="$REPO_ROOT/scripts"
CHECK="$REPO_ROOT/scripts/check-decisions.sh"
TEMPLATE="$REPO_ROOT/plugins/skein/skills/dev-plan/template.md"

mirror=both
while [[ $# -gt 0 ]]; do
	case "$1" in
	--mirror)
		mirror="${2:-}"
		shift 2 || true
		;;
	*)
		echo "usage: test-promotion-marker.sh [--mirror claude|codex|both]" >&2
		exit 2
		;;
	esac
done
case "$mirror" in
claude | codex | both) ;;
*)
	echo "usage: test-promotion-marker.sh [--mirror claude|codex|both]" >&2
	exit 2
	;;
esac

PASS_COUNT=0
FAIL_COUNT=0

pass() {
	PASS_COUNT=$((PASS_COUNT + 1))
	echo "ok: $1"
}

fail() {
	FAIL_COUNT=$((FAIL_COUNT + 1))
	echo "FAIL: $1" >&2
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# snapshot <plan>: marker line, sha256 of the signed bytes, computed hash and
# staleness, all from the canonical marker module.
snapshot() {
	python3 - "$MARKER_LIB" "$1" <<'PY'
import hashlib
import sys

sys.path.insert(0, sys.argv[1])
import marker

path = sys.argv[2]
text = open(path, "rb").read().decode("utf-8")
start, end = marker._marker_line_span(text)
signed = marker.strip_marker_for_hashing(text)
print("marker-line:", text[start:end].rstrip("\n"))
print("signed-sha256:", hashlib.sha256(signed.encode("utf-8")).hexdigest())
print("computed-hash:", marker.compute_plan_hash(path))
print("recorded:", marker.read_marker(path))
print("stale:", marker.marker_is_stale(path))
PY
}

# ---------------------------------------------------------------------------
echo "== Part 1: marker integrity and supersession =="

# Fixture A uses the shipped template, so the edit lands in its own
# `## Promoted Decisions` section. Fixture B lacks the section, so the edit
# creates the heading at the end of the workspace.
plan_a="$tmp/plan-a.md"
plan_b="$tmp/plan-b.md"
cp "$TEMPLATE" "$plan_a"
python3 - "$TEMPLATE" "$plan_b" <<'PY'
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
text = re.sub(r"## Promoted Decisions\n.*?(?=\n## )\n", "", text, flags=re.S)
open(sys.argv[2], "w", encoding="utf-8").write(text)
PY
if grep -q '^## Promoted Decisions$' "$plan_b"; then
	fail "fixture B still carries ## Promoted Decisions"
fi

for plan in "$plan_a" "$plan_b"; do
	label="$(basename "$plan")"
	# Signed once here and never again: re-signing would hide a changed prefix.
	if ! python3 "$WRITER" "$plan" >/dev/null; then
		fail "$label: marker writer failed"
		continue
	fi
	before="$(snapshot "$plan")"
	if ! grep -q '^stale: False$' <<<"$before"; then
		fail "$label: freshly signed fixture is not valid ($before)"
		continue
	fi
	before_bytes="$(cksum <"$plan")"

	python3 - "$plan" <<'PY'
import sys

path = sys.argv[1]
link = "- `docs/decisions/20261124-example.md`: Example decision\n"
lines = open(path, encoding="utf-8").read().splitlines(keepends=True)
heading = "## Promoted Decisions\n"
if heading in lines:
    i = lines.index(heading) + 1
    while i < len(lines) and not lines[i].startswith("## "):
        i += 1
    while lines[i - 1].strip() == "":
        i -= 1
    lines[i:i] = ["\n", link]
else:
    if lines and lines[-1].strip():
        lines.append("\n")
    lines += [heading, "\n", link]
open(path, "w", encoding="utf-8").write("".join(lines))
PY

	after="$(snapshot "$plan")"
	if [[ "$(cksum <"$plan")" == "$before_bytes" ]]; then
		fail "$label: the scripted promotion edit changed nothing"
	elif ! grep -qF '`docs/decisions/20261124-example.md`' "$plan"; then
		fail "$label: the link line was not written"
	elif [[ "$before" == "$after" ]]; then
		pass "$label: marker line, signed bytes and hash unchanged after a below-marker promotion edit"
	else
		fail "$label: marker changed after a below-marker edit"$'\n'"before:"$'\n'"$before"$'\n'"after:"$'\n'"$after"
	fi
	if [[ "$(grep -c '^## Promoted Decisions$' "$plan")" -eq 1 ]]; then
		pass "$label: exactly one ## Promoted Decisions heading after the edit"
	else
		fail "$label: ## Promoted Decisions heading count is not 1"
	fi
done

# classify_marker is the one four-state classification every update-docs
# mirror runs. Table: fixture -> expected state; the fixtures are reused by
# run_marker_classifier below, which runs each mirror's own snippet.
states_rc=0
python3 - "$MARKER_LIB" "$TEMPLATE" "$tmp" <<'PY' || states_rc=$?
import sys

sys.path.insert(0, sys.argv[1])
import marker

template = open(sys.argv[2], encoding="utf-8").read()
tmp = sys.argv[3]

def fixture(name, text, sign=False, tamper=False):
    path = f"{tmp}/{name}.md"
    open(path, "w", encoding="utf-8").write(text)
    if sign:
        marker.write_marker(path)
    if tamper:
        body = open(path, encoding="utf-8").read()
        open(path, "w", encoding="utf-8").write(body.replace("## Objective", "## Objective (edited)", 1))
    return path

no_marker = "\n".join(l for l in template.splitlines() if not l.startswith("<!-- reviewed:")) + "\n"
fenced = no_marker + "\n```\n<!-- reviewed: 2026-11-24 @ " + "0" * 40 + " -->\n```\n"
table = [
    ("missing", fixture("missing", no_marker)),
    ("placeholder", fixture("placeholder", template)),
    ("stale", fixture("stale", template, sign=True, tamper=True)),
    ("valid", fixture("valid", template, sign=True)),
    ("missing", fixture("fenced", fenced)),
]
bad = [(want, path, marker.classify_marker(path)) for want, path in table if marker.classify_marker(path) != want]
assert not bad, bad
assert {want for want, _ in table} == {"missing", "placeholder", "stale", "valid"}
PY
if [[ $states_rc -eq 0 ]]; then
	pass "classify_marker returns missing, placeholder, stale and valid for its table, and missing for a fenced marker"
else
	fail "classify_marker disagrees with its four-state table"
fi

# Supersession: an old active record replaced by a new one.
sup_record() {
	local root="$1" name="$2" status="$3" supersedes="$4" superseded_by="$5"
	cat >"$root/docs/decisions/$name" <<EOF
# Decision $name

**Status**: $status
**Date**: 2026-11-24
**Applies to**: src/*
**Supersedes**: $supersedes
**Superseded by**: $superseded_by
**Source plan**: docs/dev_plans/plan.md

## Decision
Keep it.
## Why
Because.
## Alternatives rejected
None.
## Consequences
None.
EOF
}

sup_root() {
	local root="$tmp/sup-$1"
	mkdir -p "$root/docs/decisions" "$root/docs/dev_plans"
	: >"$root/docs/dev_plans/plan.md"
	cp "$REPO_ROOT/docs/decisions/README.md" "$root/docs/decisions/README.md"
	sup_record "$root" 20260101-old.md active none none
	printf '%s\n' "$root"
}

root="$(sup_root both)"
sup_record "$root" 20261124-new.md active 20260101-old.md none
sup_record "$root" 20260101-old.md superseded none 20261124-new.md
if "$CHECK" "$root" >/dev/null 2>&1; then
	pass "supersession updating both records passes check-decisions.sh"
else
	fail "supersession updating both records fails check-decisions.sh: $("$CHECK" "$root" 2>&1 || true)"
fi

root="$(sup_root new-only)"
sup_record "$root" 20261124-new.md active 20260101-old.md none
if "$CHECK" "$root" >/dev/null 2>&1; then
	fail "supersession writing only the new record passes check-decisions.sh"
else
	pass "supersession writing only the new record fails check-decisions.sh"
fi

root="$(sup_root old-only)"
sup_record "$root" 20260101-old.md superseded none 20261124-new.md
if "$CHECK" "$root" >/dev/null 2>&1; then
	fail "supersession updating only the old record passes check-decisions.sh"
else
	pass "supersession updating only the old record fails check-decisions.sh"
fi

# ---------------------------------------------------------------------------
echo "== Part 2: update-docs promotion wording =="

# expect_text <label> <haystack> <needle>
expect_text() {
	if grep -qF -- "$3" <<<"$2"; then
		pass "$1"
	else
		fail "$1 (missing: $3)"
	fi
}

check_mirror() {
	local name="$1" plugin="$2" check_path="$3"
	local skill="$REPO_ROOT/plugins/$plugin/skills/update-docs/SKILL.md"
	if [[ ! -f "$skill" ]]; then
		fail "$name: $skill does not exist"
		return
	fi
	local whole section
	whole="$(cat "$skill")"
	section="$(awk '/^## Decision Promotion$/{on=1; print; next} on && /^## /{exit} on' "$skill")"
	if [[ -z "$section" ]]; then
		fail "$name: update-docs has no '## Decision Promotion' section (the $name mirror's promotion step has not landed)"
		return
	fi

	expect_text "$name: usage says --apply still needs per-record approval" "$whole" \
		'except decision records, which always need per-record approval'
	expect_text "$name: Phase 4 list never writes records, even with --apply" "$whole" \
		'never write them from this list, even with `--apply`'
	expect_text "$name: writes need explicit per-record approval" "$section" \
		'Write only on explicit per-record approval.'
	expect_text "$name: --apply does not approve a record" "$section" \
		'`--apply` does not approve a record'
	expect_text "$name: each record is offered on its own" "$section" \
		'Offer each record on its own.'
	expect_text "$name: creation exception is narrow" "$whole" \
		'The only exception is Decision Promotion: it may create the exact record the user approved under `docs/decisions/`'
	expect_text "$name: creation exception creates nothing else" "$whole" \
		'It creates nothing else, and nothing under `docs/decisions/` without approval of that record.'
	expect_text "$name: re-reads the live plan and requires a real marker" "$section" \
		're-read the live plan and require a valid real review marker'
	expect_text "$name: below-marker link goes in ## Promoted Decisions" "$section" \
		'under the plan'"'"'s existing `## Promoted Decisions` section below the marker'
	# Anchored to step 7 itself: the step 3 preflight names the same script, so
	# a section-wide search would pass with the post-write check removed.
	local validate_step
	validate_step="$(grep -F -- '7. **Validate after writing' <<<"$section" || true)"
	expect_text "$name: runs the bundled validator after writes" "$validate_step" "From the repo root, run \`$check_path\`"
	# The --targets scope rule and its exit codes, word for word.
	expect_text "$name: confines targets to the two promotion directories" "$section" \
		'requires each listed path to be `docs/dev_plans/<name>` or `docs/decisions/<name>`, where `<name>` is one path component matching `[A-Za-z0-9][A-Za-z0-9._-]*[.]md` (no further `/`, no `.git` component, no leading `-` or `.`)'
	expect_text "$name: exit 3 is an unsafe target" "$section" 'Exit `3` means a listed path is unsafe'
	expect_text "$name: exit 1 is an invalid record set, a promotion precondition" "$section" \
		'Exit `1` means the existing records already fail validation; a valid record set is a precondition of every promotion.'

	# Marker integrity is one invariant with two writers: ordinary Phase 4 plan
	# edits and promotion. Both mirrors guard both writers.
	local apply_phase
	apply_phase="$(awk '/^## Phase 4: Apply Updates$/{on=1; next} on && /^## /{exit} on' "$skill")"
	expect_text "$name: Phase 4 shows the report before applying" "$apply_phase" \
		'**Always show the report (Phase 3) first**'
	expect_text "$name: ordinary apply classifies the source plan's marker first" "$apply_phase" \
		'Before applying any changes to the source plan selected for Decision Promotion, use the marker classifier below.'
	expect_text "$name: ordinary apply defers edits to the signed source-plan prefix" "$apply_phase" \
		'If the plan has a valid marker, apply only edits below it. Report any proposed above-marker edits as deferred'
	expect_text "$name: ordinary apply preserves the signed prefix even when no record is approved" "$apply_phase" \
		'Preserve the marker and signed prefix for the rest of this invocation, including when no record is approved.'
	expect_text "$name: promotion follows ordinary edits" "$section" \
		'after the Phase 3 report and any ordinary Phase 4 edits'
	# Write preflight: before the offer and again immediately before the write.
	expect_text "$name: preflights every target before offering" "$section" \
		"${check_path} --targets -- \"\$PLAN\" docs/decisions/<new file>"
	expect_text "$name: re-runs the preflight immediately before the first write" "$section" \
		'Immediately before the first write, re-run the step 3 preflight over the same paths and write nothing unless it exits `0`.'
	local pre_at offer_at recheck_at write_at
	pre_at="$(grep -n -- '--targets -- ' <<<"$section" | head -1 | cut -d: -f1 || true)"
	offer_at="$(grep -n -- 'Then show the exact offer:' <<<"$section" | head -1 | cut -d: -f1 || true)"
	recheck_at="$(grep -n -- 're-run the step 3 preflight' <<<"$section" | head -1 | cut -d: -f1 || true)"
	write_at="$(grep -n -- 'Write exactly the approved offer' <<<"$section" | head -1 | cut -d: -f1 || true)"
	if [[ -n "$pre_at" && -n "$offer_at" && -n "$recheck_at" && -n "$write_at" ]] &&
		((pre_at < offer_at && offer_at < recheck_at && recheck_at < write_at)); then
		pass "$name: preflight precedes the offer and its re-run precedes the write"
	else
		fail "$name: preflight/offer/write order is wrong ($pre_at, $offer_at, $recheck_at, $write_at)"
	fi
	# A skill ships what it runs: no python3 without isolation, and no reach
	# into review-plan's scripts/.
	if grep -nE 'python3( |$)' "$skill" | grep -v 'python3 -I -B -S ' | grep -q .; then
		fail "$name: update-docs runs python3 without -I -B -S"
	else
		pass "$name: every python3 call in update-docs is isolated"
	fi
	if grep -q 'review-plan/scripts' "$skill"; then
		fail "$name: update-docs imports from review-plan/scripts"
	else
		pass "$name: update-docs imports only its own bundled scripts"
	fi

	expect_text "$name: changed inputs require a fresh offer before writing" "$section" \
		'If an input changed, report it and make a fresh offer before writing.'
	expect_text "$name: re-confirms the candidate and the offered link location" "$section" \
		'Also confirm the candidate and offered link location still match the live plan'
	expect_text "$name: the write never replaces an existing record" "$section" \
		'so the write never replaces a record that already exists.'
	expect_text "$name: classifies the marker with the shared classify_marker" "$section" \
		'print(marker.classify_marker(sys.argv[1]))'
	# Recovery: snapshot first, the new record last, full rollback on failure.
	local write_step save_at first_at
	write_step="$(grep -F -- '6. **Write exactly the approved offer' <<<"$section" || true)"
	expect_text "$name: saves every changed file's bytes before the first write" "$write_step" \
		'Before the first write, save the exact bytes of every existing file the offer changes'
	expect_text "$name: writes the new record last" "$write_step" 'and the new record last'
	save_at="$(grep -bo 'save the exact bytes' <<<"$write_step" | head -1 | cut -d: -f1 || true)"
	first_at="$(grep -bo 'Then write in this order' <<<"$write_step" | head -1 | cut -d: -f1 || true)"
	if [[ -n "$save_at" && -n "$first_at" && "$save_at" -lt "$first_at" ]]; then
		pass "$name: the snapshot precedes the first write"
	else
		fail "$name: the snapshot does not precede the first write ($save_at, $first_at)"
	fi
	expect_text "$name: rolls back on a failed or partial write or validation" "$validate_step" \
		'If a write fails or stops part-way, the validator exits non-zero, or the step 5 check prints anything but `valid`, restore every saved file to its saved bytes, delete every path this promotion created'
	expect_text "$name: offers nothing further after a rollback" "$validate_step" 'offer nothing further in this invocation'
	expect_text "$name: an interrupted promotion blocks the next preflight" "$validate_step" \
		'the next step 3 preflight exits `1` and offers nothing until the records are repaired'

	if [[ "$name" == codex ]]; then
		expect_text "codex: Phase 4 excludes decisions from the allowlist" "$apply_phase" \
			'`docs/decisions/` path from this apply-target allowlist'
		expect_text "codex: reports an unwritable target before the first write" "$section" \
			'If a required target is outside that boundary or is otherwise unwritable, report the blocker before the first write.'
	fi

	local refusal
	refusal="$(grep -F 'Refuse the promotion and write nothing when it prints' <<<"$section" || true)"
	if [[ -z "$refusal" ]]; then
		fail "$name: no marker refusal sentence"
	else
		local state
		for state in missing placeholder stale; do
			expect_text "$name: refuses a $state marker" "$refusal" "\`$state\`"
		done
	fi
}

run_marker_classifier() {
	local name="$1" plugin="$2" skill_dir script state got
	skill_dir="$REPO_ROOT/plugins/$plugin/skills/update-docs"
	script="$(awk '
		/^## Decision Promotion$/ { promotion = 1; next }
		promotion && /^## / { exit }
		promotion && /^   python3 .*- "\$PLAN" / { on = 1 }
		on { print substr($0, 4) }
		on && /^   PY$/ { exit }
	' "$skill_dir/SKILL.md" | sed "s#\${CLAUDE_PLUGIN_ROOT}#$REPO_ROOT/plugins/$plugin#g")"
	if [[ -z "$script" ]]; then
		fail "$name: no marker classifier block in update-docs"
		return
	fi
	# Run from a hostile checkout: every stdlib module marker.py imports is
	# planted in the current directory. Isolation must keep them all off
	# sys.path, in every marker state.
	local shadow="$tmp/shadow-$name" module
	mkdir -p "$shadow"
	for module in re subprocess datetime pathlib hashlib os; do
		printf 'open(%s, "w").write("ran")\nraise SystemExit("SHADOWED %s")\n' "'$shadow/canary-$module'" "$module" >"$shadow/$module.py"
	done
	for state in missing placeholder stale valid; do
		if got="$(cd "$shadow" && PLAN="$tmp/$state.md" SKILL_DIR="$skill_dir" bash -e <<<"$script" 2>&1)" &&
			[[ "$got" == "$state" ]]; then
			pass "$name: update-docs marker classifier prints $state"
		else
			fail "$name: update-docs marker classifier on the $state fixture printed '$got'"
		fi
	done
	if compgen -G "$shadow/canary-*" >/dev/null; then
		fail "$name: a repo-root module shadowed a marker.py import ($(ls "$shadow"))"
	else
		pass "$name: no repo-root module runs when the classifier imports marker.py"
	fi
	if [[ ! -d "$skill_dir/scripts/__pycache__" ]]; then
		pass "$name: the classifier writes no bytecode into the bundled scripts"
	else
		fail "$name: the classifier wrote $skill_dir/scripts/__pycache__"
	fi
}

# run_preflight <name> <plugin>: the mirror's own preflight line, run as
# written over a promotion's targets, refuses a linked docs/decisions and a
# linked source plan and accepts a real tree.
run_preflight() {
	local name="$1" plugin="$2" skill_dir line root rc
	skill_dir="$REPO_ROOT/plugins/$plugin/skills/update-docs"
	line="$(grep -E '^   .*check-decisions\.sh"? --targets -- ' "$skill_dir/SKILL.md" | head -1 | sed 's/^   //')"
	line="${line//\$\{CLAUDE_PLUGIN_ROOT\}/$REPO_ROOT/plugins/$plugin}"
	line="${line/ docs\/decisions\/<new file> \[docs\/decisions\/<superseded file>\] \[docs\/decisions\/README.md\]/ docs/decisions/20261125-new.md docs/decisions/README.md}"
	if [[ -z "$line" || "$line" == *'<'* ]]; then
		fail "$name: no runnable preflight line ($line)"
		return
	fi
	for shape in real linked-decisions linked-plan; do
		root="$tmp/preflight-$name-$shape"
		mkdir -p "$root/docs/dev_plans" "$tmp/preflight-outside/decisions"
		: >"$root/docs/dev_plans/real.md"
		case "$shape" in
		real | linked-plan) mkdir -p "$root/docs/decisions" ;;
		linked-decisions) ln -s "$tmp/preflight-outside/decisions" "$root/docs/decisions" ;;
		esac
		plan=docs/dev_plans/real.md
		if [[ "$shape" == linked-plan ]]; then
			ln -s real.md "$root/docs/dev_plans/linked.md"
			plan=docs/dev_plans/linked.md
		fi
		rc=0
		(cd "$root" && PLAN="$plan" SKILL_DIR="$skill_dir" bash -e <<<"$line" >/dev/null 2>&1) || rc=$?
		if [[ "$shape" == real && $rc -eq 0 ]] || [[ "$shape" != real && $rc -ne 0 ]]; then
			pass "$name: the preflight verdict on a $shape tree is exit $rc"
		else
			fail "$name: the preflight verdict on a $shape tree is exit $rc"
		fi
	done
}

# The shared promotion text is byte-identical across Claude and Codex except
# the deliberate harness differences: the path anchor and Codex's sandbox
# writability sentence.
promotion_text() {
	awk '/^## Decision Promotion$/{on=1} on && /^## Phase 5/{exit} on' "$REPO_ROOT/plugins/$1/skills/update-docs/SKILL.md" |
		sed -e 's#"\${CLAUDE_PLUGIN_ROOT}/skills/update-docs/scripts/check-decisions.sh"#<check>#g' \
			-e 's#"\$SKILL_DIR"/scripts/check-decisions.sh#<check>#g' \
			-e 's#"\${CLAUDE_PLUGIN_ROOT}/skills/update-docs/scripts"#<scripts>#g' \
			-e 's#"\$SKILL_DIR"/scripts#<scripts>#g' \
			-e 's#`\${CLAUDE_PLUGIN_ROOT}/skills/update-docs/references/decision-records.md`#<reference>#g' \
			-e 's#`"\$SKILL_DIR"/references/decision-records.md`#<reference>#g' \
			-e 's# Check that every offered target is writable within the current sandbox. If a required target is outside that boundary or is otherwise unwritable, report the blocker before the first write.##'
}
if [[ "$mirror" == both ]]; then
	if diff <(promotion_text skein) <(promotion_text skein-codex) >"$tmp/promotion.diff"; then
		pass "the Claude and Codex promotion sections match except anchors and the Codex sandbox sentence"
	else
		fail "the Claude and Codex promotion sections drift: $(cat "$tmp/promotion.diff")"
	fi
fi

if [[ "$mirror" == claude || "$mirror" == both ]]; then
	check_mirror claude skein '"${CLAUDE_PLUGIN_ROOT}/skills/update-docs/scripts/check-decisions.sh"'
	run_marker_classifier claude skein
	run_preflight claude skein
fi
if [[ "$mirror" == codex || "$mirror" == both ]]; then
	check_mirror codex skein-codex '"$SKILL_DIR"/scripts/check-decisions.sh'
	run_marker_classifier codex skein-codex
	run_preflight codex skein-codex
fi

echo "---"
echo "passed: $PASS_COUNT, failed: $FAIL_COUNT"
[[ $FAIL_COUNT -eq 0 ]]
