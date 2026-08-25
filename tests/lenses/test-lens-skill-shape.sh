#!/usr/bin/env bash
# test-lens-skill-shape.sh — Phase 2 acceptance: both mirrors of
# deep-review AND review-plan SKILL.md document the streamed-lens protocol.
#
# Plan: docs/dev_plans/20260823-feature-review-skills-resilience.md, Phase 2
# checklist ("new shape test tests/lenses/test-lens-skill-shape.sh asserts
# both mirrors reference persist-lens-result.sh (JSON transport only since
# r4/G1 — G6(a) asserts NO flag-mode --type start remains), --attempt 2,
# collect-lens-results.sh, lens-budget.sh, the --continue re-run clause
# (timed_out|errored|partial|absent), and the Codex sequential-mode
# clause").
#
# Pure documentation/shape check over the four SKILL.md files (Claude +
# Codex mirrors, deep-review + review-plan) — no runtime behaviour, in the
# style of tests/gauntlet/test-gauntlet-skill-shape.sh.
#
# Exit codes: 0 all assertions pass, 1 any assertion fails.

set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"

SKILLS=(
	"$ROOT_DIR/plugins/skein/skills/deep-review/SKILL.md"
	"$ROOT_DIR/plugins/skein-codex/skills/deep-review/SKILL.md"
	"$ROOT_DIR/plugins/skein/skills/review-plan/SKILL.md"
	"$ROOT_DIR/plugins/skein-codex/skills/review-plan/SKILL.md"
)

pass_count=0
fail_count=0

pass() {
	echo "PASS: $1"
	pass_count=$((pass_count + 1))
}

fail() {
	echo "FAIL: $1"
	fail_count=$((fail_count + 1))
}

require_file() {
	local file="$1"
	if [[ ! -f "$file" ]]; then
		fail "file missing: $file"
		return 1
	fi
	return 0
}

# assert_grep FILE PATTERN LABEL
# PATTERN is passed to `grep -Eq` (extended regex) against the whole file.
assert_grep() {
	local file="$1" pattern="$2" label="$3"
	if grep -Eq -- "$pattern" "$file"; then
		pass "$label ($file)"
	else
		fail "$label ($file)"
	fi
}

for skill_md in "${SKILLS[@]}"; do
	if ! require_file "$skill_md"; then
		continue
	fi

	assert_grep "$skill_md" 'persist-lens-result\.sh' \
		"references persist-lens-result.sh"

	# G1: the lens-facing contract moved to --json-stdin, so `--type start`
	# survives only in the orchestrator-authored (closed-enum) invocations.
	# Either spelling of "there is a start record" satisfies this leg.
	if grep -Eq -- '--type[[:space:]]+start' "$skill_md" ||
		grep -Eq -- '"type"[[:space:]]*:[[:space:]]*"start"' "$skill_md"; then
		pass "references a start record ($skill_md)"
	else
		fail "references a start record ($skill_md)"
	fi

	# --- G1 (findings 1/3): untrusted text must not reach the lens's argv ---

	assert_grep "$skill_md" '\-\-json-stdin' \
		"references --json-stdin (payload off argv)"

	assert_grep "$skill_md" "<<'SKEIN_JSON'" \
		"uses the quoted heredoc delimiter <<'SKEIN_JSON' (no shell expansion)"

	# NEGATIVE assertion: the old argv-carrying template must be GONE, not
	# merely supplemented. `--evidence "` is the exact shape that let a lens's
	# own shell expand $(...)/backticks out of reviewed code.
	if grep -Eq -- '\-\-evidence[[:space:]]*"' "$skill_md"; then
		fail "no --evidence \"...\" on a command line (old injectable template still present) ($skill_md)"
		grep -nE -- '\-\-evidence[[:space:]]*"' "$skill_md" | sed 's/^/    /'
	else
		pass "no --evidence \"...\" on a command line ($skill_md)"
	fi

	assert_grep "$skill_md" '--attempt[[:space:]]+2' \
		"references --attempt 2 (the respawn variant)"

	assert_grep "$skill_md" 'collect-lens-results\.sh' \
		"references collect-lens-results.sh"

	assert_grep "$skill_md" 'lens-budget\.sh' \
		"references lens-budget.sh"

	# The --continue re-run clause: all four re-run statuses must appear
	# somewhere in the file. "absent" is checked loosely (the plan's own
	# prose sometimes phrases it as "absent"/"missing" interchangeably --
	# R4: "absent = missing" -- so either token satisfies this leg).
	if grep -Fq "timed_out" "$skill_md" &&
		grep -Fq "errored" "$skill_md" &&
		grep -Fq "partial" "$skill_md" &&
		(grep -Fq "absent" "$skill_md" || grep -Fq "missing" "$skill_md"); then
		pass "documents the --continue re-run clause (timed_out|errored|partial|absent) ($skill_md)"
	else
		fail "documents the --continue re-run clause (timed_out|errored|partial|absent) ($skill_md)"
	fi

	# Codex sequential-mode clause: the orchestrator emits typed lines
	# itself and skips respawn, but the collector still runs. Checked
	# loosely (case-insensitive "sequential" near "Codex"), since exact
	# phrasing is not pinned down by the plan beyond R4's prose.
	if grep -Eiq 'codex' "$skill_md" && grep -Eiq 'sequential' "$skill_md"; then
		pass "documents the Codex sequential-mode clause ($skill_md)"
	else
		fail "documents the Codex sequential-mode clause ($skill_md)"
	fi

	# --- Phase 2 fix-spec additions (finding 3/5/6/C1/C2/C3 prose) ---

	assert_grep "$skill_md" '\-\-attempts' \
		"references --attempts (respawn-count flag)"

	assert_grep "$skill_md" '\-\-findings-jsonl' \
		"references --findings-jsonl (D-7/C3 collector normalizer flag)"

	# D-2 (finding 5): attempt-3+ on --continue must be documented -- reusing
	# --attempt 2 forever would put two writers on one file. Checked loosely
	# (any phrasing the clause text uses). Codex addendum A4 replaced the
	# "next unused attempt (3, then 4...)" GUESS with a DERIVED rule ("1 +
	# the highest on-disk attempt index"), which states the same invariant
	# without assuming attempt 2 was ever spawned -- so that spelling
	# satisfies this leg too.
	if grep -Fq "attempt 3" "$skill_md" ||
		grep -Eiq 'next unused attempt' "$skill_md" ||
		grep -Fq 'highest on-disk attempt index' "$skill_md"; then
		pass "documents the attempt-3+ --continue re-run clause ($skill_md)"
	else
		fail "documents the attempt-3+ --continue re-run clause ($skill_md)"
	fi

	# D-6 (C2/D3): per-lens deadlines, not one global wake.
	if grep -Eiq 'own deadline' "$skill_md" || grep -Eiq 'per-lens deadline' "$skill_md"; then
		pass "documents the per-lens-deadline wake clause ($skill_md)"
	else
		fail "documents the per-lens-deadline wake clause ($skill_md)"
	fi

	# D-5 (C1): every generic persistence-contract value placeholder is
	# delimited so a multi-word value cannot split. Under G1's --json-stdin
	# contract the argv-splitting hazard is structurally gone, so the JSON
	# spelling (`"severity":"<...>"`) satisfies this leg as well as the old
	# quoted-flag spelling.
	if (grep -Fq -- '--severity "' "$skill_md" && grep -Fq -- '--category "' "$skill_md") ||
		(grep -Fq -- '"severity":"' "$skill_md" && grep -Fq -- '"category":"' "$skill_md"); then
		pass "delimits severity/category value placeholders ($skill_md)"
	else
		fail "delimits severity/category value placeholders ($skill_md)"
	fi
done

# D-1/D-3/D-4 (finding 4==C4, finding 6, finding 7): deep-review-only prose
# -- the final persist step must pipe collect | persist --from-collector
# (never the hand-assembled positional lenses.json), and the orchestrator
# must document writing `done --status skipped` on a deliberately-skipped
# lens's behalf.
DEEP_REVIEW_SKILLS=(
	"$ROOT_DIR/plugins/skein/skills/deep-review/SKILL.md"
	"$ROOT_DIR/plugins/skein-codex/skills/deep-review/SKILL.md"
)
for skill_md in "${DEEP_REVIEW_SKILLS[@]}"; do
	if ! require_file "$skill_md"; then
		continue
	fi

	assert_grep "$skill_md" '\-\-from-collector' \
		"final persist block uses --from-collector ($skill_md)"

	# Either transport: the flag form (--status skipped) or the --json-file
	# payload form ("status":"skipped"). G5 moved orchestrator-side writes to
	# --json-file, so pinning this to the flag spelling would assert the
	# transport rather than the clause.
	assert_grep "$skill_md" '(\-\-status[[:space:]]+skipped|"status":"skipped")' \
		"documents the orchestrator-emitted 'done status skipped' clause ($skill_md)"

	# No positional lenses.json placeholder left in the final-persist prose
	# -- the fix-spec explicitly says to delete this wording when switching
	# to the collector pipe.
	if grep -Fq "assembled after Step 2" "$skill_md" || grep -Fq "assembled by hand" "$skill_md"; then
		fail "final persist block has no leftover hand-assembled-JSON wording ($skill_md)"
	else
		pass "final persist block has no leftover hand-assembled-JSON wording ($skill_md)"
	fi
done

# ---------------------------------------------------------------------------
# (C15) persist-lens-result.sh must PRESENT --json-stdin first.
#
# r2 finding #15: the script's header and `usage()` both led with the argv
# payload form, so the first usage form a reader (or a model) copies is the
# one every SKILL.md mirror forbids — reviewed text on argv is expanded by
# the lens's OWN shell before this script ever runs. No behaviour change; the
# flags stay for back-compat and tests. This locks the presentation order.
# ---------------------------------------------------------------------------

PERSIST_SCRIPT="$ROOT_DIR/scripts/persist-lens-result.sh"

# usage_body -- the text of the usage() heredoc, in order.
usage_body="$(awk '/^usage\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$PERSIST_SCRIPT")"

json_stdin_at="$(printf '%s\n' "$usage_body" | grep -n -- '--json-stdin' | head -1 | cut -d: -f1)"
argv_flag_at="$(printf '%s\n' "$usage_body" | grep -nE -- '--(severity|category|location|summary|evidence|suggestion)' | head -1 | cut -d: -f1)"

if [[ -z "$json_stdin_at" || -z "$argv_flag_at" ]]; then
	fail "(C15) could not locate both usage forms in persist-lens-result.sh usage() (json-stdin='$json_stdin_at' argv='$argv_flag_at')"
elif ((json_stdin_at < argv_flag_at)); then
	pass "(C15) usage() presents --json-stdin before the argv content flags"
else
	fail "(C15) usage() still leads with the argv content flags (--json-stdin at line $json_stdin_at, first content flag at $argv_flag_at)"
fi

# The same order in the file header's `Usage:` block.
header_body="$(sed -n '1,/^set -euo pipefail/p' "$PERSIST_SCRIPT")"
h_json_at="$(printf '%s\n' "$header_body" | grep -n -- '--json-stdin <<' | head -1 | cut -d: -f1)"
h_argv_at="$(printf '%s\n' "$header_body" | grep -n -- '\[--severity' | head -1 | cut -d: -f1)"
if [[ -z "$h_json_at" || -z "$h_argv_at" ]]; then
	fail "(C15b) could not locate both usage forms in the persist-lens-result.sh header (json='$h_json_at' argv='$h_argv_at')"
elif ((h_json_at < h_argv_at)); then
	pass "(C15b) the file header's Usage block presents --json-stdin first"
else
	fail "(C15b) the file header still leads with the argv form (--json-stdin at $h_json_at, --severity at $h_argv_at)"
fi

# The argv content flags must carry the never-from-a-lens-prompt annotation.
if grep -q 'back-compat/test only' "$PERSIST_SCRIPT" &&
	grep -q 'never from a lens prompt' "$PERSIST_SCRIPT"; then
	pass "(C15c) the argv content flags are annotated back-compat/test only, never from a lens prompt"
else
	fail "(C15c) the argv content flags carry no back-compat/test-only annotation"
fi

# ---------------------------------------------------------------------------
# (D4) Per-LENS-SECTION coverage of the persistence protocol.
#
# r2 finding #4: the persistence protocol is stated five times per mirror,
# and the guard above (`assert_grep "$skill_md" ...`) greps the WHOLE FILE.
# Four of the five per-lens blocks could be deleted and every assertion here
# would still pass — a file-granular guard over a per-lens contract. The
# duplication itself is real but restructuring three mirrors' prompt prose is
# a prompt-behaviour-affecting change and stays QUARANTINED; the exploitable
# half is the guard, so tighten that.
#
# Rule: every per-lens section must EITHER contain its own
# `{{PERSIST_CMD}} --json-stdin <<'SKEIN_JSON'` block, OR sit under a `##`
# parent section that contains one AND says it applies to every lens prompt
# (the Codex deep-review mirror's `## Lens Prompts` preamble — it states the
# protocol once, deliberately, rather than per lens).
# ---------------------------------------------------------------------------

PERSIST_BLOCK="{{PERSIST_CMD}} --json-stdin <<'SKEIN_JSON'"

check_per_lens_sections() {
	local skill_md="$1"
	local report
	report="$(awk -v blk="$PERSIST_BLOCK" '
		{ lines[NR] = $0 }
		END {
			n = NR
			# A markdown heading only counts OUTSIDE a fenced code block: the
			# lens PROMPT TEMPLATES are themselves fenced and contain their own
			# `## Lens Persistence Contract` headings, which would otherwise
			# terminate the enclosing `#### <Name> Lens` section at its own
			# persistence block.
			fence = 0
			for (i = 1; i <= n; i++) {
				lvl[i] = 0
				if (lines[i] ~ /^[[:space:]]*```/) { fence = 1 - fence; continue }
				if (fence == 0 && lines[i] ~ /^#+ /) {
					h = lines[i]; sub(/ .*$/, "", h); lvl[i] = length(h)
				}
			}
			# First pass: mark every per-lens section body, so the inherit
			# check below cannot be satisfied by ANOTHER lens section block.
			for (i = 1; i <= n; i++) inlens[i] = 0
			for (i = 1; i <= n; i++) {
				if (lvl[i] < 3 || lvl[i] > 4) continue
				t = lines[i]; sub(/^#+ /, "", t)
				if (t !~ /Lens/) continue
				if (t ~ /^Lens (Prompts|Model Tiers|Persistence Contract|Budget)/) continue
				if (t ~ /^Step /) continue
				e = n
				for (j = i + 1; j <= n; j++)
					if (lvl[j] > 0 && lvl[j] <= lvl[i]) { e = j - 1; break }
				for (j = i; j <= e; j++) inlens[j] = 1
			}
			found = 0
			for (i = 1; i <= n; i++) {
				if (lvl[i] < 3 || lvl[i] > 4) continue
				title = lines[i]; sub(/^#+ /, "", title)
				if (title !~ /Lens/) continue
				# Structural/preamble headings, not per-lens prompt sections.
				if (title ~ /^Lens (Prompts|Model Tiers|Persistence Contract|Budget)/) continue
				if (title ~ /^Step /) continue
				found++
				# section body: up to the next heading of the same or higher level
				end = n
				for (j = i + 1; j <= n; j++)
					if (lvl[j] > 0 && lvl[j] <= lvl[i]) { end = j - 1; break }
				ok = 0
				for (j = i + 1; j <= end; j++)
					if (index(lines[j], blk) > 0) { ok = 1; break }
				if (ok) { printf "OK own %d %s\n", i, title; continue }
				# inherit: nearest enclosing "## " section
				p = 0
				for (j = i - 1; j >= 1; j--) if (lvl[j] == 2) { p = j; break }
				if (p > 0) {
					pend = n
					for (j = p + 1; j <= n; j++)
						if (lvl[j] == 2) { pend = j - 1; break }
					hasblk = 0; hasmark = 0
					for (j = p; j <= pend; j++) {
						if (inlens[j] == 1) continue
						if (index(lines[j], blk) > 0) hasblk = 1
						low = tolower(lines[j])
						if (index(low, "every lens prompt") > 0 || index(low, "each lens prompt") > 0) hasmark = 1
					}
					if (hasblk && hasmark) { printf "OK inherit %d %s\n", i, title; continue }
				}
				printf "MISSING %d %s\n", i, title
			}
			if (found == 0) printf "NOSECTIONS\n"
		}
	' "$skill_md")"

	if [[ "$report" == "NOSECTIONS" ]]; then
		fail "(D4) no per-lens sections found in $skill_md -- the per-section guard would be vacuous"
		return
	fi
	local missing
	missing="$(printf '%s\n' "$report" | grep '^MISSING' || true)"
	local count
	count="$(printf '%s\n' "$report" | grep -c '^OK' || true)"
	if [[ -n "$missing" ]]; then
		fail "(D4) per-lens section without a reachable persistence block ($skill_md):"
		printf '%s\n' "$missing" | sed 's/^/    /'
	else
		pass "(D4) all $count per-lens sections carry (or inherit) a {{PERSIST_CMD}} --json-stdin block ($skill_md)"
	fi
}

for skill_md in "${SKILLS[@]}"; do
	check_per_lens_sections "$skill_md"
done

# ---------------------------------------------------------------------------
# Group F (Codex addendum A1, A2, A3, A4, A10) — the --continue continuation
# contract, asserted on all four mirrors.
# ---------------------------------------------------------------------------

for skill_md in "${SKILLS[@]}"; do
	require_file "$skill_md" || continue
	f_plugin="$(basename "$(dirname "$(dirname "$(dirname "$skill_md")")")")"
	f_skill="$(basename "$(dirname "$skill_md")")"
	label="$f_plugin/$f_skill"

	# A1: the resume rule must be a COMPLEMENT ("not completed and not
	# skipped"), not an allowlist of non-terminal statuses. The allowlist was
	# not total: collect-lens-results.sh emits status "missing" and
	# persist-deep-review-state.sh persists it, so the key is PRESENT with a
	# status in neither arm and --continue silently skipped a lens that never
	# ran. A complement rule no future enum value can escape.
	assert_grep "$skill_md" 'not `completed` and not `skipped`' \
		"A1 ($label): the resume rule is stated as a complement of completed/skipped"

	# A1(b): the stale parenthetical "(absent = missing)" equated an absent
	# KEY with the `missing` STATUS -- two different things, and the reason
	# the allowlist looked total when it was not.
	if grep -Fq '(absent = missing)' "$skill_md"; then
		fail "A1(b) ($label): the false '(absent = missing)' equivalence is still present"
	else
		pass "A1(b) ($label): the false '(absent = missing)' equivalence is gone"
	fi

	# A2: while attempt 2 is in flight, EVERY collect must carry both
	# --attempts <lens>:2 AND --running <lens>:2. Reproduced against the
	# collector (attempt 1 = start+progress, no done): --attempts alone
	# yields `timed_out` -- the retry declared exhausted while still running
	# -- and adding --running yields `partial`.
	assert_grep "$skill_md" '\-\-attempts <lens>:2 \-\-running <lens>:2' \
		"A2 ($label): the respawn bullet requires --attempts <lens>:2 --running <lens>:2"

	# A3: a salvaged return belongs to the attempt whose reply is being
	# salvaged, NOT unconditionally to attempt 1. done_status is
	# latest-attempt-scoped, so salvaging a reply from attempt 2 into
	# attempt 1 is either a no-op or -- when attempt 2 is fileless --
	# reports `completed` while the retry is unresolved.
	if grep -Fq 'attempt stays 1' "$skill_md"; then
		fail "A3 ($label): salvage is still hardwired to attempt 1 ('attempt stays 1')"
	else
		pass "A3 ($label): salvage is no longer hardwired to attempt 1"
	fi
	assert_grep "$skill_md" 'the attempt whose reply is being salvaged' \
		"A3(b) ($label): salvage is written to the attempt whose reply is being salvaged"

	# A4: the next attempt is DERIVED from disk, never guessed. Persisted
	# state carries no spawn counter, so "next unused attempt (3, then 4...)"
	# assumed 2 was spawned: a crash before dispatch leaves 2 free and
	# skipped, and a silently-spawned 2 collides with its own writer.
	if grep -Fq 'next unused attempt' "$skill_md"; then
		fail "A4 ($label): the next attempt is still guessed ('next unused attempt')"
	else
		pass "A4 ($label): the next attempt is no longer guessed"
	fi
	assert_grep "$skill_md" 'highest on-disk attempt index' \
		"A4(b) ($label): the next attempt is 1 + the highest on-disk attempt index"
	assert_grep "$skill_md" 'writes that attempt.s `start` record on the lens' \
		"A4(c) ($label): the orchestrator writes the start record for any attempt N >= 2"

	# A10: every dynamic argument on a collector INVOCATION line must be
	# quoted. An unquoted `--root <repo-root>` splits on a path containing a
	# space and the collector exits 2. Prose that merely NAMES a flag is out
	# of scope; only lines that actually invoke the script are checked.
	# Only the invocation span is inspected: from the script name to the end
	# of its code span, so prose on the same line that merely names a flag
	# combination (e.g. `--attempts <lens>:2 --running <lens>:2`) is ignored.
	if grep -oE 'collect-lens-results\.sh[^`]*' "$skill_md" |
		grep -Eq '\-\-(root|run-id|skill|expected|attempts|running) <'; then
		fail "A10 ($label): a collector INVOCATION carries an unquoted argument placeholder"
	else
		pass "A10 ($label): every collector invocation argument is quoted"
	fi
done

# ---------------------------------------------------------------------------
# Group G (r3 G4/G5) — diff-derived text must not reach a shell command line,
# and the heredoc boundary must be named rather than inferred.
#
# G4: `--expected "logic:src/$(id).ts"` is substituted by the ORCHESTRATOR'S
# shell before collect-lens-results.sh is entered, so no in-script whitelist
# can see it and double quotes do not help (they stop splitting and globbing,
# not substitution). The fix is a transport change: units travel in a file.
#
# G5: bash ends a heredoc at a line consisting EXACTLY of the delimiter, so a
# payload line reading only `SKEIN_JSON` would end the payload and execute the
# remainder as shell. Valid JSON cannot produce one, so the hazard is gated on
# a model FORMATTING error -- which is precisely why the contract has to name
# it instead of expecting the model to infer the boundary rule.
# ---------------------------------------------------------------------------

for skill_md in "${SKILLS[@]}"; do
	require_file "$skill_md" || continue
	g_plugin="$(basename "$(dirname "$(dirname "$(dirname "$skill_md")")")")"
	g_skill="$(basename "$(dirname "$skill_md")")"
	glabel="$g_plugin/$g_skill"

	# G4(a): every collector invocation prescribes --expected-file.
	if grep -oE 'collect-lens-results\.sh[^`]*' "$skill_md" | grep -q -- '--expected-file'; then
		pass "G4(a) ($glabel): a collector invocation prescribes --expected-file"
	else
		fail "G4(a) ($glabel): no collector invocation prescribes --expected-file"
	fi

	# G4(b): NO collector invocation interpolates a unit placeholder into
	# --expected. This is the assertion that actually closes the finding --
	# adding --expected-file somewhere else would not.
	if grep -oE 'collect-lens-results\.sh[^`]*' "$skill_md" |
		grep -Eq -- '--expected "<(lens|[a-z]+)>:'; then
		fail "G4(b) ($glabel): a collector invocation still interpolates units into --expected"
	else
		pass "G4(b) ($glabel): no collector invocation interpolates units into --expected"
	fi

	# G4(c): the units file is named as the transport, with its path -- and
	# that path is the SKILL'S OWN per-run lens state dir
	# (persist_lens_state_dir <root> <skill> / <run_id>), the directory the
	# attempt files already live in. r4 F2: `.skein/lens-runs/<run_id>/` was a
	# third state root invented in prose, owned by no helper and absent from
	# .gitignore, so a collect run left an untracked file behind.
	case "$g_skill" in
	deep-review) g_state_dir='\.deep-review' ;;
	review-plan) g_state_dir='\.review-plan' ;;
	*) g_state_dir='' ;;
	esac
	assert_grep "$skill_md" "$g_state_dir/lenses/<run_id>/expected\\.json" \
		"G4(c) ($glabel): the units-file path is the per-run lens state dir"
	if grep -Fq 'skein/lens-runs' "$skill_md"; then
		fail "G4(c2) ($glabel): the retired .skein/lens-runs path literal survives"
	else
		pass "G4(c2) ($glabel): no .skein/lens-runs path literal"
	fi

	# G5: the delimiter-line hazard is named in the persistence contract.
	assert_grep "$skill_md" 'line consisting only of .SKEIN_JSON' \
		"G5(a) ($glabel): the contract forbids a bare SKEIN_JSON delimiter line"
	assert_grep "$skill_md" 'exactly one line' \
		"G5(b) ($glabel): the contract requires a single-line payload"
	assert_grep "$skill_md" 'persist-lens-result\.sh --json-file' \
		"G5(c) ($glabel): orchestrator-side writes are prescribed --json-file"
done

# ---------------------------------------------------------------------------
# Group G6 (r4 G1) — EXCLUSIVITY, not existence.
#
# G5(c) above only asserts `--json-file` appears SOMEWHERE. A mirror that kept
# the old `--type start --units ...` spelling for one clause (the `--continue`
# attempt-N start, or the Codex skipped-lens clause) alongside a migrated one
# elsewhere still passes it. r4 F0/F1 are exactly that: the round-3 migration
# rewrote the sequential and skipped-lens clauses in three mirrors but not the
# Codex skipped-lens clause nor the attempt-N `start` clause in any mirror.
#
# F0 is the Critical half: it also prescribes `--expected`, which
# collect-lens-results.sh rejects as mutually exclusive with the
# `--expected-file` the same document's collect line uses -- so a Codex
# deep-review run that skips any lens aborts the whole collection with a usage
# error. G6(c) therefore checks the WHOLE FILE for a bare `--expected ` token,
# not just inside a collector invocation: F0's offending text is prose, which
# the invocation-scoped G4(b) grep cannot see.
# ---------------------------------------------------------------------------

for skill_md in "${SKILLS[@]}"; do
	require_file "$skill_md" || continue
	g6_plugin="$(basename "$(dirname "$(dirname "$(dirname "$skill_md")")")")"
	g6_skill="$(basename "$(dirname "$skill_md")")"
	g6label="$g6_plugin/$g6_skill"

	# G6(a): no persist-lens-result.sh invocation anywhere in prose uses the
	# flag-mode `--type <record-type>` payload spelling. Orchestrator-side
	# records go through --json-file; lens-side records go through
	# --json-stdin. Neither puts the payload on argv.
	# Whole-file, not scoped to a `grep -oE 'persist-lens-result\.sh[^`]*'`
	# slice: that slice is LINE-oriented, and the Codex mirrors reflow prose,
	# so a wrapped invocation hides its own payload flags from it -- which is
	# exactly how F0 survived round 3. `--type <record-type>` with one of the
	# four record types is persist-specific; run-gate.sh/status-row prose uses
	# an unrelated `--type` namespace and never these four values.
	if grep -Eq -- '--type (start|done|progress|finding)' "$skill_md"; then
		fail "G6(a) ($g6label): a persist-lens-result.sh invocation still uses flag-mode --type"
	else
		pass "G6(a) ($g6label): no persist-lens-result.sh invocation uses flag-mode --type"
	fi

	# G6(b): and none carries a `--units` payload on argv either. This is the
	# half that actually puts diff-derived text on a command line.
	if grep -Eq -- '--units[ "`]' "$skill_md"; then
		fail "G6(b) ($g6label): a persist-lens-result.sh invocation still passes --units on argv"
	else
		pass "G6(b) ($g6label): no persist-lens-result.sh invocation passes --units on argv"
	fi

	# G6(c): the bare `--expected ` token (space-terminated, so
	# `--expected-file` does not match) appears nowhere in the file -- prose
	# included. --expected survives in the script as the hand-invocation
	# transport, but no SKILL.md may prescribe or even illustrate it, because
	# it is mutually exclusive with the --expected-file every collect line
	# uses.
	if grep -Eq -- '--expected[ "]' "$skill_md"; then
		fail "G6(c) ($g6label): a bare \`--expected\` token survives in prose"
	else
		pass "G6(c) ($g6label): no bare \`--expected\` token anywhere in the file"
	fi

	# G6(d) (r4 G10 / Codex addendum, SKILL.md:189): the expected-units file
	# is IMMUTABLE across a respawn. collect-lens-results.sh derives
	# `assigned`/`reviewed`/`unreviewed` from it, and progress records merge
	# across every attempt -- so narrowing the file to the retry's unit list
	# drops the already-reviewed units out of coverage accounting entirely.
	# Only the respawn PROMPT's unit payload narrows.
	assert_grep "$skill_md" 'never (rewrite|overwrite) the units file' \
		"G6(d) ($g6label): the units file is prescribed immutable across a respawn"

	# G6(e) (r4 G8 / F14): the units file is named as the REQUIRED transport,
	# not merely an available one.
	assert_grep "$skill_md" '\*\*required\*\*' \
		"G6(e) ($g6label): the units file is marked as the required transport"

	# G6(f) (Codex addendum, SKILL.md:193): every --json-file recipe in prose
	# names the required context flags. persist-lens-result.sh requires
	# --root, --skill, --run-id, --lens and --attempt in EVERY mode; a recipe
	# that shows only `--lens spec --attempt 1 --json-file <path>` exits 2 and
	# writes no record, so the collector reports the intentionally-skipped
	# lens as `missing`.
	assert_grep "$skill_md" \
		'[-][-]root .* [-][-]skill .* [-][-]run-id .* [-][-]lens .* [-][-]attempt .* [-][-]json-file' \
		"G6(f) ($g6label): a --json-file recipe carries the full required-flag prefix"

	# G6(g) (design G1(b), "same assertion applied to --json-stdin recipes
	# for symmetry"): the lens-side form is symmetric, but it cannot be
	# asserted the same way, and pretending otherwise would encode the wrong
	# contract. Lens recipes are written as `{{PERSIST_CMD}} --json-stdin`,
	# where the orchestrator substitutes the resolved prefix before dispatch
	# -- the flags are real, they are just supplied one layer up. So the
	# symmetric guarantee is checked in two halves:
	#
	#   (i) every `{{PERSIST_CMD}}` DEFINITION line spells all five required
	#       context flags, since that definition is what the five required
	#       flags actually come from at dispatch time; and
	#   (ii) no --json-stdin recipe bypasses the placeholder by naming
	#        persist-lens-result.sh directly on the same line without a
	#        --root, which is the shape that would exit 2 if followed
	#        literally -- the exact G1(b)/C3 failure, on the other transport.
	# A DEFINITION line is one that mentions {{PERSIST_CMD}} and starts
	# spelling flags for it (`--root`); a recipe line mentions the
	# placeholder and nothing else. Keyed on the flags rather than on any
	# particular sentence, because the two mirror families word this
	# differently on purpose -- but a definition, in either wording, must be
	# on ONE line and must carry all five flags, or the substituted prefix
	# the lens receives is incomplete and every lens-side write exits 2.
	# `{{ATTEMPT}}` is the discriminator: it appears ONLY in a resolved-prefix
	# definition, never in a recipe line and never in prose, so it selects
	# exactly the lines this rule is about without depending on either
	# mirror family's sentence wording.
	g6g_defs="$(grep -c -- '{{ATTEMPT}}' "$skill_md" || true)"
	g6g_full="$(grep -- '{{ATTEMPT}}' "$skill_md" |
		grep -c -- '[-][-]root .*[-][-]skill .*[-][-]run-id .*[-][-]lens .*[-][-]attempt' || true)"
	if [[ "$g6g_defs" -gt 0 && "$g6g_full" -eq "$g6g_defs" ]]; then
		pass "G6(g) ($g6label): all $g6g_defs {{PERSIST_CMD}} definitions spell the five required context flags on one line"
	else
		fail "G6(g) ($g6label): $g6g_full of $g6g_defs {{PERSIST_CMD}} definitions carry the full required-flag prefix"
	fi

	g6g_bare="$(grep -E -- 'persist-lens-result\.sh[^`]*[-][-]json-stdin' "$skill_md" |
		grep -vc -- '[-][-]root' || true)"
	if [[ "$g6g_bare" -eq 0 ]]; then
		pass "G6(g) ($g6label): no --json-stdin recipe names the script directly without its context flags"
	else
		fail "G6(g) ($g6label): $g6g_bare --json-stdin recipe(s) name persist-lens-result.sh with no --root"
	fi
done

echo ""
echo "Summary: $pass_count passed, $fail_count failed"

if [[ $fail_count -ne 0 ]]; then
	exit 1
fi
exit 0
