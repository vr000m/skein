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
	expect_text "$name: preflights every target before offering, targets on stdin" "$section" \
		"${check_path} --targets-file - <<'SKEIN_TARGETS'"
	expect_text "$name: checks every file name before any shell use" "$section" \
		"check each file name (the source plan's, the new record's and a superseded record's) against \`^[A-Za-z0-9][A-Za-z0-9._-]*[.]md\$\`"
	expect_text "$name: reports a plan link to a missing record" "$section" '`broken partial promotion: <link>`'
	run_step1_guard "$name" "$section"
	run_step1_containment "$name" "$section" 'only with your file-read and file-search (glob) tools'
	expect_text "$name: reports an orphan record and offers only its link" "$section" \
		'report it as `already exists, link missing`, never draft a second record for it, and offer only its missing link line'
	expect_text "$name: step 7 compares the signed-prefix digest" "$section" \
		'the same `signed-prefix-sha256=` line it printed before the first write'
	expect_text "$name: the classifier prints the signed-prefix digest" "$section" \
		'print("signed-prefix-sha256=%s" % marker.signed_prefix_sha256(sys.argv[1]))'
	expect_text "$name: re-runs the preflight immediately before the first write" "$section" \
		'Immediately before the first write, re-run the step 3 preflight over the same paths and write nothing unless it exits `0`.'
	local pre_at offer_at recheck_at write_at
	pre_at="$(grep -n -- '--targets-file - ' <<<"$section" | head -1 | cut -d: -f1 || true)"
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
	expect_text "$name: writes the plan link last" "$write_step" 'The plan link is always the final write'
	save_at="$(grep -bo 'save the exact bytes' <<<"$write_step" | head -1 | cut -d: -f1 || true)"
	first_at="$(grep -bo 'Then write in this order' <<<"$write_step" | head -1 | cut -d: -f1 || true)"
	if [[ -n "$save_at" && -n "$first_at" && "$save_at" -lt "$first_at" ]]; then
		pass "$name: the snapshot precedes the first write"
	else
		fail "$name: the snapshot does not precede the first write ($save_at, $first_at)"
	fi
	expect_text "$name: rolls back on a failed or partial write, validation or digest change" "$validate_step" \
		'If a write fails or stops part-way, the validator exits non-zero, the step 5 check prints anything but `valid`, the digest differs, or a link-only promotion'"'"'s record is gone, restore every saved file to its saved bytes, delete every path this promotion created'
	run_link_only_guard "$name" "$section"
	expect_text "$name: offers nothing further after a rollback" "$validate_step" 'offer nothing further in this invocation'
	expect_text "$name: an interrupted supersession blocks the next preflight" "$validate_step" \
		'the next step 3 preflight exits `1` and offers nothing until the records are repaired'
	expect_text "$name: an interruption before the link is an orphan step 1 reports" "$validate_step" \
		'step 1 reports the new record as `already exists, link missing`'

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
			[[ "${got%%$'\n'*}" == "$state" && "${got#*$'\n'}" =~ ^signed-prefix-sha256=([0-9a-f]{64}|None)$ ]]; then
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

# preflight_fence <plugin>: the mirror's own step 3 preflight fence, unindented.
preflight_fence() {
	awk '
		/^## Decision Promotion$/ { promotion = 1; next }
		promotion && /^## / { exit }
		promotion && /^   ```$/ && !code { code = 1; next }
		code && /^   ```$/ { exit }
		code { print substr($0, 4) }
	' "$REPO_ROOT/plugins/$1/skills/update-docs/SKILL.md" | sed "s#\${CLAUDE_PLUGIN_ROOT}#$REPO_ROOT/plugins/$1#g"
}
# preflight_run <plugin> <root> <target line>...: runs the fence in <root>
# with its four template target lines replaced by the given lines; sets rc.
preflight_run() {
	local plugin="$1" root="$2" fence line script=""
	shift 2
	fence="$(preflight_fence "$plugin")"
	while IFS= read -r line; do
		case "$line" in
		docs/dev_plans/'<plan file>') printf -v script '%s%s\n' "$script" "$(printf '%s\n' "$@")" ;;
		docs/decisions/'<'*) ;;
		*) printf -v script '%s%s\n' "$script" "$line" ;;
		esac
	done <<<"$fence"
	rc=0
	(cd "$root" && SKILL_DIR="$REPO_ROOT/plugins/$plugin/skills/update-docs" bash -e <<<"$script" >/dev/null 2>&1) || rc=$?
}

# run_preflight <name> <plugin>: the mirror's own preflight fence, run as
# written over a promotion's targets: exit 3 (a target refused, not merely a
# bad graph) for a linked docs/decisions and a linked source plan, 0 for a
# real tree, and a hostile name in the here-document runs nothing.
run_preflight() {
	local name="$1" plugin="$2" root rc fence want
	fence="$(preflight_fence "$plugin")"
	if [[ "$fence" != *"--targets-file - <<'SKEIN_TARGETS'"* || "$fence" != *$'\nSKEIN_TARGETS'* ]]; then
		fail "$name: no runnable here-document preflight ($fence)"
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
		preflight_run "$plugin" "$root" "$plan" docs/decisions/20261125-new.md docs/decisions/README.md
		want=3
		[[ "$shape" == real ]] && want=0
		if [[ $rc -eq $want ]]; then
			pass "$name: the preflight verdict on a $shape tree is exit $rc"
		else
			fail "$name: the preflight verdict on a $shape tree is exit $rc (want $want)"
		fi
	done
	root="$tmp/preflight-$name-real"
	# shellcheck disable=SC2016  # the metacharacters are the test data
	preflight_run "$plugin" "$root" docs/dev_plans/real.md 'docs/decisions/x$(touch pwned).md'
	if [[ $rc -eq 3 && ! -e "$root/pwned" ]]; then
		pass "$name: a hostile record name in the preflight here-document is refused (exit 3) and runs nothing"
	else
		fail "$name: hostile here-document name: exit $rc, pwned $([[ -e "$root/pwned" ]] && echo yes || echo no)"
	fi
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

# ---------------------------------------------------------------------------
# Seam 2: the promotion write flow as a state space, driven by each mirror's
# own text. Invariants: (2) no interruption leaves a plan link to a missing
# record; every partial state is either blocked by the real validator (exit 1)
# or an orphan record step 1 reports as `already exists, link missing`;
# (3) a write is accepted only when the plan is still `valid` AND its
# signed-prefix digest (line 1 through the marker line) is unchanged; (1) the
# skill's file-name rule is the validator's DEC_TARGET_NAME.

# write_order <SKILL.md> <step opener>: the write kinds (readme, record,
# supersede, link) in the order the step lists them after "Then write".
write_order() {
	awk -v opener="$2" 'index($0, opener) == 1 { print; exit }' "$1" | python3 -c '
import re, sys
step = sys.stdin.read()
step = step[step.find("Then write"):]
kinds = {"readme": "folder and", "record": "the new record", "supersede": "supers", "link": "link"}
found = sorted((step.find(p), k) for k, p in kinds.items() if step.find(p) >= 0)
print(" ".join(k for _, k in found))'
}

# promo_fixture <root> <first|existing>: a plan with a Promoted Decisions
# section and, unless first, one active record from the same plan.
promo_fixture() {
	local root="$1"
	rm -rf "$root"
	mkdir -p "$root/docs/dev_plans"
	printf '# Plan\n\n## Promoted Decisions\n' >"$root/docs/dev_plans/plan.md"
	if [[ "$2" == existing ]]; then
		mkdir -p "$root/docs/decisions"
		cp "$REPO_ROOT/docs/decisions/README.md" "$root/docs/decisions/README.md"
		sup_record "$root" 20260101-old.md active none none
	fi
}

# promo_write <root> <kind> <supersede yes|no>: one write of the offer.
promo_write() {
	local root="$1"
	case "$2" in
	readme)
		mkdir -p "$root/docs/decisions"
		cp "$REPO_ROOT/docs/decisions/README.md" "$root/docs/decisions/README.md"
		;;
	record)
		mkdir -p "$root/docs/decisions"
		if [[ "$3" == yes ]]; then
			sup_record "$root" 20261125-new.md active 20260101-old.md none
		else
			sup_record "$root" 20261125-new.md active none none
		fi
		;;
	supersede) sup_record "$root" 20260101-old.md superseded none 20261125-new.md ;;
	link) printf -- '- `docs/decisions/20261125-new.md`: New\n' >>"$root/docs/dev_plans/plan.md" ;;
	esac
}

# promo_state <root>: dangling | blocked | orphan | linked | none.
promo_state() {
	local root="$1" link=0 record=0 rc=0
	grep -qF '`docs/decisions/20261125-new.md`' "$root/docs/dev_plans/plan.md" && link=1
	[[ -f "$root/docs/decisions/20261125-new.md" ]] && record=1
	if [[ $link -eq 1 && $record -eq 0 ]]; then
		echo dangling
		return
	fi
	"$CHECK" "$root" >/dev/null 2>&1 || rc=$?
	if [[ $rc -ne 0 ]]; then
		echo blocked
	elif [[ $record -eq 1 && $link -eq 0 ]] &&
		grep -qx '\*\*Source plan\*\*: docs/dev_plans/plan.md' "$root/docs/decisions/20261125-new.md"; then
		echo orphan
	elif [[ $record -eq 1 ]]; then
		echo linked
	else
		echo none
	fi
}

# run_write_order <name> <SKILL.md> <step opener>: every cell of
# {first promotion, plain, superseding} x {interrupted after 0..n writes}.
run_write_order() {
	local name="$1" order cell base sup kinds kind k n done_ok=1 seen="" st root
	order="$(write_order "$2" "$3")"
	if [[ "$order" != *readme* || "$order" != *record* || "$order" != *link* ]]; then
		fail "$name: cannot read the write order from step '$3', or it lacks the first-promotion README write ($order)"
		return
	fi
	for cell in first:no:readme,record,link existing:no:record,link existing:yes:record,supersede,link; do
		base="${cell%%:*}"
		sup="${cell#*:}"
		sup="${sup%%:*}"
		kinds=()
		for kind in $order; do
			[[ ",${cell##*:}," == *",$kind,"* ]] && kinds+=("$kind")
		done
		n=${#kinds[@]}
		for ((k = 0; k <= n; k++)); do
			root="$tmp/order-$name-$base-$sup-$k"
			promo_fixture "$root" "$base"
			for ((i = 0; i < k; i++)); do
				promo_write "$root" "${kinds[$i]}" "$sup"
			done
			st="$(promo_state "$root")"
			seen+=" $st"
			if [[ "$st" == dangling || ($k -eq $n && "$st" != linked) ]]; then
				done_ok=0
				fail "$name: $base promotion, supersede=$sup, interrupted after $k of $n writes (${kinds[*]}): $st"
			fi
			# A completed first promotion installs the folder's README too.
			if [[ "$base" == first && $k -eq $n ]] && ! cmp -s "$root/docs/decisions/README.md" "$REPO_ROOT/docs/decisions/README.md"; then
				done_ok=0
				fail "$name: a completed first promotion left no docs/decisions/README.md"
			fi
		done
	done
	if [[ $done_ok -eq 1 ]]; then
		pass "$name: no interruption of '$order' leaves a dangling plan link (states:$seen)"
	fi
	if [[ "$seen" == *orphan* && "$seen" == *blocked* ]]; then
		pass "$name: the table reaches both recoverable partial states (orphan, blocked)"
	else
		fail "$name: the write-order table missed a partial state (states:$seen)"
	fi
}

# classifier_script <plugin>: the mirror's own step 5 marker snippet.
classifier_script() {
	awk '
		/^## Decision Promotion$/ { promotion = 1; next }
		promotion && /^## / { exit }
		promotion && /^   python3 .*- "\$PLAN" / { on = 1 }
		on { print substr($0, 4) }
		on && /^   PY$/ { exit }
	' "$REPO_ROOT/plugins/$1/skills/update-docs/SKILL.md" | sed "s#\${CLAUDE_PLUGIN_ROOT}#$REPO_ROOT/plugins/$1#g"
}

# run_marker_integrity <name> <plugin>: step 7's rule (accept only `valid`
# with the pre-write digest) over {below-marker link, marker date rewritten,
# above-marker edit}. The rewritten date keeps the hash and classifies
# `valid`, so it is the cell the digest alone refuses.
run_marker_integrity() {
	local name="$1" plugin="$2" script plan out before state digest verdict cell want
	script="$(classifier_script "$plugin")"
	for cell in below-link:accept date-changed:refuse above-edit:refuse; do
		want="${cell#*:}"
		cell="${cell%%:*}"
		plan="$tmp/integrity-$name-$cell.md"
		cp "$TEMPLATE" "$plan"
		python3 "$WRITER" "$plan" >/dev/null
		before="$(PLAN="$plan" SKILL_DIR="$REPO_ROOT/plugins/$plugin/skills/update-docs" bash -e <<<"$script")"
		case "$cell" in
		below-link) printf -- '- `docs/decisions/20261125-new.md`: New\n' >>"$plan" ;;
		date-changed) sed -i.bak -E 's/^(<!-- reviewed: )[0-9]{4}-[0-9]{2}-[0-9]{2}( @ [0-9a-f]{40} -->)$/\11999-01-01\2/' "$plan" ;;
		above-edit) sed -i.bak 's/^## Objective$/## Objective (edited)/' "$plan" ;;
		esac
		out="$(PLAN="$plan" SKILL_DIR="$REPO_ROOT/plugins/$plugin/skills/update-docs" bash -e <<<"$script")"
		state="${out%%$'\n'*}"
		digest="${out#*$'\n'}"
		verdict=refuse
		[[ "$state" == valid && "$digest" == "${before#*$'\n'}" ]] && verdict=accept
		if [[ "${before%%$'\n'*}" == valid && "$verdict" == "$want" ]] &&
			{ [[ "$cell" != date-changed ]] || [[ "$state" == valid ]]; }; then
			pass "$name: marker integrity, $cell: $state, digest $([[ "$digest" == "${before#*$'\n'}" ]] && echo same || echo changed) -> $verdict"
		else
			fail "$name: marker integrity, $cell: before '${before%%$'\n'*}', after '$state', verdict $verdict (want $want)"
		fi
	done
}

# run_step1_guard <name> <section>: step 1 checks every link target and record
# name against DEC_TARGET_NAME before it uses one, and checks existence with
# file tools only, never a shell. Contract: the guard sentence precedes the
# first use (`a link whose record file does not exist`), and its regex is the
# validator's.
run_step1_guard() {
	local name="$1" section="$2" shell_rule="${3:-only with your file-read and file-search (glob) tools, never with a shell command}" guard rule
	guard='each `## Promoted Decisions` link target must be `docs/decisions/<name>` and each record file found in `docs/decisions/` must be named `<name>`, where `<name>` matches `'
	rule="^$(sed -n "s/^DEC_TARGET_NAME='\(.*\)'\$/\1/p" "$REPO_ROOT/scripts/lib/decisions-common.sh")\$"
	# shellcheck disable=SC2016  # literal skill text
	if [[ "$section" == *"$guard$rule\`"*"$shell_rule"*"a link whose record file does not exist"* ]]; then
		pass "$name: step 1 checks link targets and record names (DEC_TARGET_NAME) before any use, existence via file tools only"
	else
		fail "$name: step 1 uses a link target or record name before the DEC_TARGET_NAME check, or allows a shell existence check"
	fi
}

# run_step1_containment <name> <section> <listing phrase> [<read phrase>]:
# round 5. Contract:
# step 1 lists record names without reading them (the listing phrase), runs
# the containment preflight over the plan and those records, and only then
# reads the plan or a record; an exit 3 reads nothing. Order: listing <
# preflight < first read of the plan.
run_step1_containment() {
	local name="$1" section="$2" listing="$3" reading="${4:-read the plan file itself}" step1 list_at pre_at read_at
	step1="$(grep -F -- '1. ' <<<"$section" | grep -F -- 'Gather candidates' | head -1 || true)"
	list_at="$(grep -bo -F -- "$listing" <<<"$step1" | head -1 | cut -d: -f1 || true)"
	pre_at="$(grep -bo -F -- 'before reading the plan or any record, run the step 3 preflight' <<<"$step1" | head -1 | cut -d: -f1 || true)"
	read_at="$(grep -bo -F -- "$reading" <<<"$step1" | head -1 | cut -d: -f1 || true)"
	if [[ -n "$list_at" && -n "$pre_at" && -n "$read_at" ]] && ((list_at < pre_at && pre_at < read_at)) &&
		[[ "$step1" == *'exit `3` means a listed path is a symlink or sits under one, so read none of the listed files'* ]]; then
		pass "$name: step 1 lists names, runs the containment preflight, then reads the plan and records"
	else
		fail "$name: step 1 reads a candidate before the containment preflight ($list_at, $pre_at, $read_at)"
	fi
}

# run_link_only_guard <name> <section>: round 5. Contract: a link-only offer
# preflights its existing record, and confirms the record still exists (and
# names this plan) before the offer, immediately before the write and after
# it, rolling back when it is gone, so approval cannot add a dangling link.
run_link_only_guard() {
	local name="$1" section="$2" ok=1 needle
	for needle in \
		'A link-only offer lists its existing record in place of `<new file>`' \
		'offer nothing unless it still exists and its `Source plan` is still this plan' \
		'For a link-only offer, immediately before the write, read the linked record again' \
		'after a link-only write also read the linked record once more: it must still exist'; do
		if [[ "$section" != *"$needle"* ]]; then
			ok=0
			fail "$name: link-only guard missing: $needle"
		fi
	done
	[[ $ok -eq 1 ]] && pass "$name: a link-only offer re-checks its record before the offer, before the write and after it"
}

# run_link_only_guard_pi: Pi's wording of the same link-only contract.
run_link_only_guard_pi() {
	local text ok=1 needle
	text="$(cat "$REPO_ROOT/plugins/skein-pi/skills/update-docs/SKILL.md")"
	for needle in \
		'a link-only offer lists its existing record in place of the new record' \
		'offer nothing unless it still exists and its `Source plan` is still this plan' \
		'For a link-only offer, immediately before the write, read the linked record again' \
		'after a link-only write also read the linked record once more: it must still exist'; do
		if [[ "$text" != *"$needle"* ]]; then
			ok=0
			fail "pi: link-only guard missing: $needle"
		fi
	done
	[[ $ok -eq 1 ]] && pass "pi: a link-only offer re-checks its record before the offer, before the write and after it"
}

# run_name_rule <name> <SKILL.md>: the skill's file-name regex is the
# validator's DEC_TARGET_NAME, and it refuses every hostile name.
run_name_rule() {
	local name="$1" rule hostile ok=1
	rule="$(grep -o 'against `\^[^`]*`' "$2" | head -1 | sed -e 's/^against `//' -e 's/`$//')"
	if [[ "$rule" != "^$(sed -n "s/^DEC_TARGET_NAME='\(.*\)'\$/\1/p" "$REPO_ROOT/scripts/lib/decisions-common.sh")\$" ]]; then
		fail "$name: the skill's name rule '$rule' is not the validator's DEC_TARGET_NAME"
		return
	fi
	[[ "20261125-new.md" =~ $rule ]] || ok=0
	# shellcheck disable=SC2016  # the metacharacters are the test data
	for hostile in 'x$(touch p).md' 'x`id`.md' 'a b.md' '-x.md' '.x.md' 'x.md;rm' 'x.md'$'\n''y.md' 'x".md' "x'.md" 'SKEIN_TARGETS'; do
		if [[ "$hostile" =~ $rule ]]; then
			ok=0
			fail "$name: the name rule accepts hostile '$hostile'"
		fi
	done
	[[ $ok -eq 1 ]] && pass "$name: the name rule is DEC_TARGET_NAME and refuses every hostile name"
}

if [[ "$mirror" == claude || "$mirror" == both ]]; then
	check_mirror claude skein '"${CLAUDE_PLUGIN_ROOT}/skills/update-docs/scripts/check-decisions.sh"'
	run_marker_classifier claude skein
	run_preflight claude skein
	run_write_order claude "$REPO_ROOT/plugins/skein/skills/update-docs/SKILL.md" '6. **Write exactly the approved offer'
	run_marker_integrity claude skein
	run_name_rule claude "$REPO_ROOT/plugins/skein/skills/update-docs/SKILL.md"
	run_write_order pi "$REPO_ROOT/plugins/skein-pi/skills/update-docs/SKILL.md" '5. Write exactly the individually approved offer'
	run_name_rule pi "$REPO_ROOT/plugins/skein-pi/skills/update-docs/SKILL.md"
	run_step1_guard pi "$(cat "$REPO_ROOT/plugins/skein-pi/skills/update-docs/SKILL.md")" 'Read files only with your read tool, never with a shell command'
	run_step1_containment pi "$(awk '/^## 4\. Decision Promotion/{on=1} on' "$REPO_ROOT/plugins/skein-pi/skills/update-docs/SKILL.md" | sed 's/^1\. Verify the live source path/1. Gather candidates: verify the live source path/')" '`ls -1A -- docs/decisions`' 'Then read the plan.'
	run_link_only_guard_pi
fi
if [[ "$mirror" == codex || "$mirror" == both ]]; then
	check_mirror codex skein-codex '"$SKILL_DIR"/scripts/check-decisions.sh'
	run_marker_classifier codex skein-codex
	run_preflight codex skein-codex
	run_write_order codex "$REPO_ROOT/plugins/skein-codex/skills/update-docs/SKILL.md" '6. **Write exactly the approved offer'
	run_marker_integrity codex skein-codex
	run_name_rule codex "$REPO_ROOT/plugins/skein-codex/skills/update-docs/SKILL.md"
fi

echo "---"
echo "passed: $PASS_COUNT, failed: $FAIL_COUNT"
[[ $FAIL_COUNT -eq 0 ]]
