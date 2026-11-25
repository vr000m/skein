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

# G4(c) derives the skill -> state-dir mapping from its OWNER rather than
# keeping a second copy (see the group below). persist-common.sh assumes
# auto-fix-common.sh is already sourced.
# shellcheck source=scripts/lib/auto-fix-common.sh disable=SC1091
. "$ROOT_DIR/scripts/lib/auto-fix-common.sh"
# shellcheck source=scripts/lib/lens-common.sh disable=SC1091
. "$ROOT_DIR/scripts/lib/lens-common.sh"

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
# (C15) persist-lens-result.sh must present NO argv payload form at all.
#
# r2 finding #15 was an ORDERING rule: the script's header and `usage()` both
# led with the argv payload form, so the first usage form a reader (or a
# model) copies was the one every SKILL.md mirror forbids -- reviewed text on
# argv is expanded by the lens's OWN shell before this script ever runs. The
# fix at the time was presentational, because "the flags stay for back-compat
# and tests".
#
# R11/F4 removed the flags. The ordering rule is now VACUOUS -- there is no
# second form to be ordered against, and the original assertions would have
# aborted on an empty `grep` rather than reporting anything. Ported to the
# stronger property the ordering rule was a proxy for: a payload flag must
# not appear in the usage text in ANY position, so there is nothing wrong to
# copy. Weakening this back to an ordering check would re-admit the form.
# ---------------------------------------------------------------------------

PERSIST_SCRIPT="$ROOT_DIR/scripts/persist-lens-result.sh"

# The ten flags F4 removed. --type/--units/--unit are payload keys on the
# JSON wire and legitimate words in prose, so they are matched only in their
# argv spelling (a flag token followed by a value placeholder or quote).
usage_body="$(awk '/^usage\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$PERSIST_SCRIPT")"
header_body="$(sed -n '1,/^set -euo pipefail/p' "$PERSIST_SCRIPT")"

c15_argv_re='[-][-](severity|category|location|summary|evidence|suggestion|status)( |=)?[<"'"'"']'
c15_usage_hits="$(printf '%s\n' "$usage_body" | grep -cE -- "$c15_argv_re" || true)"
c15_header_hits="$(printf '%s\n' "$header_body" | grep -cE -- "$c15_argv_re" || true)"

if [[ "$c15_usage_hits" -eq 0 ]]; then
	pass "(C15) usage() advertises no argv payload flag"
else
	fail "(C15) usage() still advertises $c15_usage_hits argv payload flag(s): $(printf '%s\n' "$usage_body" | grep -oE -- "$c15_argv_re" | sort -u | tr '\n' ' ')"
fi

if [[ "$c15_header_hits" -eq 0 ]]; then
	pass "(C15b) the file header Usage block advertises no argv payload flag"
else
	fail "(C15b) the file header still advertises $c15_header_hits argv payload flag(s)"
fi

# Non-vacuous-pass guard: the two extractors must have found real text. An
# awk/sed range that silently matched nothing would make both checks above
# trivially true -- exactly the failure mode that hid the F4 breakage.
if [[ -n "${usage_body// /}" && -n "${header_body// /}" && "$usage_body" == *"--json-stdin"* && "$header_body" == *"--json-stdin"* ]]; then
	pass "(C15c/guard) both usage extractors returned real text naming --json-stdin"
else
	fail "(C15c/guard) an extractor returned no usable usage text (usage=${#usage_body} bytes, header=${#header_body} bytes)"
fi

# ...and the surviving text must state the single-transport rule positively,
# so the absence above reads as a decision rather than an omission.
if grep -q 'Exactly one of --json-stdin / --json-file is required' "$PERSIST_SCRIPT" &&
	grep -q 'never argv flags' "$PERSIST_SCRIPT"; then
	pass "(C15d) usage() states the single-payload-transport rule explicitly"
else
	fail "(C15d) usage() does not state that the payload is never argv flags"
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
	# shellcheck disable=SC2016  # literal grep/regex pattern text, not shell expansion
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
	# shellcheck disable=SC2016  # literal grep/regex pattern text, not shell expansion
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
	if grep -q -- '--expected-file' <<<"$(grep -oE 'collect-lens-results\.sh[^`]*' "$skill_md")"; then
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
	#
	# R5/R10: this guard used to keep its OWN hardcoded copy of the
	# skill -> state-dir mapping and grep the prose for that literal, so a
	# change to persist_lens_state_dir plus a matching change to the prose
	# left it green -- it could not detect drift on the side it exists to
	# police. It now DERIVES the directory from the helper that owns it, so
	# the only hand-written component left is `/<run_id>/expected.json`. The
	# old `*) g_state_dir='' ;;` arm was itself a silent-pass hazard: an
	# empty pattern makes assert_grep match anything. An unknown skill is now
	# a loud failure, which is what persist_lens_state_dir already returns 1
	# for.
	if g_state_dir_abs="$(persist_lens_state_dir /ROOT "$g_skill" 2>/dev/null)"; then
		g_state_dir="${g_state_dir_abs#/ROOT/}"
		g_state_dir_re="$(printf '%s' "$g_state_dir" | sed 's/[.[\*^$]/\\&/g')"
		assert_grep "$skill_md" "$g_state_dir_re/<run_id>/expected\\.json" \
			"G4(c) ($glabel): the units-file path is the per-run lens state dir"
	else
		fail "G4(c) ($glabel): persist_lens_state_dir does not know skill '$g_skill'"
	fi
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

# ---------------------------------------------------------------------------
# (R11-F1) the deep-review state schema_version agrees across all three sites.
#
# The Phase-2 rework changed the per-lens object from
# {status, model, effort, reason, findings} to
# {status, assigned, reviewed, unreviewed, findings} and widened the status
# enum, WITHOUT bumping schema_version -- so version 1 named two
# incompatible shapes and SKILL.md's --continue compat gate could not tell
# them apart. The bump to 2 is only half the fix; this is the other half.
# Nothing failed when the producer and the two mirrors disagreed, which is
# exactly how the drift went unnoticed. Assert the three agree, by value.
# ---------------------------------------------------------------------------

f1_script="$(grep -oE -- '--argjson schema_version [0-9]+' "$ROOT_DIR/scripts/persist-deep-review-state.sh" |
	grep -oE '[0-9]+$' | sort -u)"
f1_claude="$(grep -oE '"schema_version": [0-9]+,' "$ROOT_DIR/plugins/skein/skills/deep-review/SKILL.md" |
	grep -oE '[0-9]+' | sort -u)"
f1_codex="$(grep -oE '"schema_version": [0-9]+,' "$ROOT_DIR/plugins/skein-codex/skills/deep-review/SKILL.md" |
	grep -oE '[0-9]+' | sort -u)"

if [[ -z "$f1_script" ]]; then
	fail "(R11-F1) could not read --argjson schema_version from persist-deep-review-state.sh"
elif [[ "$(printf '%s' "$f1_script" | wc -l)" -ne 0 ]]; then
	fail "(R11-F1) persist-deep-review-state.sh stamps more than one schema_version: $f1_script"
elif [[ "$f1_script" == "$f1_claude" && "$f1_script" == "$f1_codex" ]]; then
	pass "(R11-F1) schema_version $f1_script agrees across the script and both deep-review mirrors"
else
	fail "(R11-F1) schema_version drift: script=$f1_script claude-mirror=$f1_claude codex-mirror=$f1_codex"
fi

# The compat gate must name the SAME version in prose. This is the sentence
# that decides whether a stale state file is honoured or discarded, so a
# bumped sample with an un-bumped gate is worse than no bump at all.
for f1_md in "$ROOT_DIR/plugins/skein/skills/deep-review/SKILL.md" "$ROOT_DIR/plugins/skein-codex/skills/deep-review/SKILL.md"; do
	f1_gate="$(grep -oE 'current expected version \([0-9]+\)' "$f1_md" | grep -oE '[0-9]+' | sort -u || true)"
	if [[ -z "$f1_gate" ]]; then
		fail "(R11-F1b) $(basename "$(dirname "$f1_md")")/$(basename "$f1_md") in $(basename "$(dirname "$(dirname "$(dirname "$f1_md")")")") states no --continue expected-version gate"
	elif [[ "$f1_gate" == "$f1_script" ]]; then
		pass "(R11-F1b) the --continue compat gate names version $f1_gate ($(basename "$(dirname "$(dirname "$(dirname "$f1_md")")")"))"
	else
		fail "(R11-F1b) compat gate names version $f1_gate but the script stamps $f1_script ($f1_md)"
	fi
done

# ---------------------------------------------------------------------------
# (R11-F10) every Lens Persistence Contract block in a file is IDENTICAL once
# the three deliberately per-lens tokens are normalised.
#
# Each mirror pastes this block into five lens prompts. The suite already
# asserted each block's PRESENCE, never that the copies agree -- so any of
# the twenty could drift and every existing assertion still passed. That is
# a twenty-way synchronised edit guarded by nothing.
#
# The block is NOT hoisted: these are prompt templates pasted into each lens
# subagent's prompt, so hoisting changes what text reaches five lenses --
# a prompt-behaviour change to settle a duplication complaint. The
# assertion gives the same protection at zero prompt risk.
#
# Three tokens legitimately vary per lens and are normalised by name rather
# than by a catch-all: the --lens value, the finding `category`, and the
# `location` placeholder (documentation findings name a file, not a line).
# A fourth varying token must therefore FAIL this test rather than be
# absorbed silently.
# ---------------------------------------------------------------------------

f10_files=(
	"$ROOT_DIR/plugins/skein/skills/deep-review/SKILL.md"
	"$ROOT_DIR/plugins/skein-codex/skills/deep-review/SKILL.md"
	"$ROOT_DIR/plugins/skein/skills/review-plan/SKILL.md"
	"$ROOT_DIR/plugins/skein-codex/skills/review-plan/SKILL.md"
)

f10_total=0
for f10_md in "${f10_files[@]}"; do
	f10_label="$(basename "$(dirname "$(dirname "$(dirname "$f10_md")")")")/$(basename "$(dirname "$f10_md")")"

	f10_count="$(grep -c '^## Lens Persistence Contract' "$f10_md" || true)"

	# The Codex deep-review mirror states the contract ONCE, as an
	# orchestrator instruction, instead of pasting a per-lens copy -- it has
	# zero blocks by this heading, which is a different (and strictly safer)
	# shape, not drift. Recorded here so "zero blocks" can never become the
	# way a mirror silently loses the contract: the total-count guard below
	# still has to be satisfied by the other three.
	if [[ "$f10_count" -eq 0 ]]; then
		if grep -q 'persist-lens-result.sh' "$f10_md"; then
			pass "(R11-F10) $f10_label states the persistence contract once, not per lens — nothing to compare"
		else
			fail "(R11-F10) $f10_label has no Lens Persistence Contract blocks AND never names persist-lens-result.sh"
		fi
		continue
	fi

	# Extract each block into its own file: the "## Lens Persistence
	# Contract" heading through the line before the next "## " heading.
	# Separate files rather than a delimiter-in-a-pipeline, so the block
	# text itself can contain anything without ending its own record.
	f10_dir="$(mktemp -d)"
	awk -v out="$f10_dir" '
		/^## Lens Persistence Contract/ { n++; f = sprintf("%s/blk.%02d", out, n); inblock = 1; next }
		inblock && /^## / { inblock = 0 }
		inblock { print > f }
	' "$f10_md"

	# Normalise the three deliberately per-lens tokens, then hash.
	f10_hashes="$(for f10_blk in "$f10_dir"/blk.*; do
		sed -E -e 's/--lens [A-Za-z0-9_-]+ /--lens <LENS> /g' \
			-e 's/"category":"[A-Za-z ]+"/"category":"<CAT>"/g' \
			-e 's/"location":"<[^"]*>"/"location":"<LOC>"/g' "$f10_blk" |
			shasum | cut -d' ' -f1
	done)"
	rm -rf "$f10_dir"

	# Cross-check the extractor against a trivially-correct count, so a
	# broken awk range cannot pass vacuously.
	f10_uniq="$(printf '%s\n' "$f10_hashes" | grep -c . || true)"

	f10_total=$((f10_total + f10_count))

	if [[ "$f10_count" -lt 2 ]]; then
		fail "(R11-F10) $f10_label has $f10_count Lens Persistence Contract blocks — nothing to compare (extractor drift?)"
		continue
	fi

	f10_distinct="$(printf '%s\n' "$f10_hashes" | grep . | sort -u | wc -l | tr -d ' ')"
	if [[ "$f10_uniq" -ne "$f10_count" ]]; then
		fail "(R11-F10) $f10_label: extracted $f10_uniq blocks but the file has $f10_count"
	elif [[ "$f10_distinct" -eq 1 ]]; then
		pass "(R11-F10) $f10_label: all $f10_count Lens Persistence Contract blocks are identical after normalisation"
	else
		fail "(R11-F10) $f10_label: $f10_count blocks normalise to $f10_distinct DISTINCT texts — the copies have drifted"
	fi
done

if [[ "$f10_total" -ge 12 ]]; then
	pass "(R11-F10/guard) $f10_total Lens Persistence Contract blocks were compared across the four mirrors"
else
	fail "(R11-F10/guard) only $f10_total blocks found across four mirrors — layout drift, not a passing test"
fi

# ---------------------------------------------------------------------------
# Documentation Lens comment classes and each mirror's ignore line. A model
# run on tests/lenses/fixtures/documentation-lens.diff is the sampled check.
# ---------------------------------------------------------------------------

DOC_LENS_MD="$ROOT_DIR/plugins/skein/skills/deep-review/SKILL.md"
CODEX_DOC_LENS_MD="$ROOT_DIR/plugins/skein-codex/skills/deep-review/SKILL.md"
DOC_LENS_FIXTURE="$ROOT_DIR/tests/lenses/fixtures/documentation-lens.diff"

doc_lens_has() {
	local pattern="$1" label="$2"
	if grep -Eq -- "$pattern" <<<"$doc_lens"; then
		pass "Documentation Lens ($doc_lens_mirror): $label"
	else
		fail "Documentation Lens ($doc_lens_mirror): $label"
	fi
}

for doc_lens_mirror in Claude Codex; do
	case "$doc_lens_mirror" in
	Claude)
		doc_lens="$(awk '/^#### Documentation Lens/{f=1; next} /^#### /{f=0} f' "$DOC_LENS_MD")"
		doc_lens_has 'Minor typos in comments within the diff' "retains the typo ignore line"
		;;
	Codex)
		doc_lens="$(awk '/^### Documentation Lens$/{f=1; next} /^<!-- BEGIN PROSE RULE BLOCK A -->$/{f=0} f' "$CODEX_DOC_LENS_MD")"
		doc_lens_has 'Code behavior unless the docs misstate it' "retains the code behavior ignore line"
		;;
	esac
	doc_lens_has 'excuse \(Important\)' "excuse class is Important"
	doc_lens_has 'tautology \(Minor\)' "tautology class is Minor"
	doc_lens_has 'stale \(Minor\)' "stale class is Minor"
	doc_lens_has 'decision candidate \(Minor, informational\)' "decision candidate class is Minor and informational"
	doc_lens_has 'Comments the diff ADDS \(never pre-existing comments\)' "scope is added comments only"
	doc_lens_has 'no whole-file evidence step' "no whole-file evidence step"
	doc_lens_has 'symbol that the same diff removes or renames' "stale is limited to symbols the same diff removes or renames"
	doc_lens_has 'docstrings, linter and type pragmas, license headers, or TODOs that link an issue' "exemptions are listed"
	doc_lens_has 'exactly .Decision candidate:.' "exact Decision candidate: prefix"
	doc_lens_has 'excuses\. Begin its .summary. with exactly .Excuse:.' "exact Excuse: prefix on the excuse class"
	doc_lens_has 'category .Documentation.' "uses the existing Documentation category"
	doc_lens_has 'One class per comment: when a comment matches more than one class, report it once, under the first that matches in the order excuse, stale, tautology, decision candidate' \
		"one class per comment, by the shared precedence"
done

# Step 5.5 appends the summary to a suppress key whose (file, line, category)
# is shared or unanchored, so Codex's suppression step must keep the summary of
# each finding it drops, not only the tuple.
# shellcheck disable=SC2016
if grep -q -F 'retain every finding suppressed here with its `summary`' \
	"$ROOT_DIR/plugins/skein-codex/skills/deep-review/SKILL.md"; then
	pass "Codex deep-review suppression keeps each dropped finding's summary for Step 5.5 keys"
else
	fail "Codex deep-review suppression keeps only the (file, line, category) tuple; Step 5.5 cannot key a shared tuple"
fi

if [[ -s "$DOC_LENS_FIXTURE" ]] && grep -q '^+.*hack: workaround' "$DOC_LENS_FIXTURE" &&
	grep -q '^+.*increment the hit counter' "$DOC_LENS_FIXTURE" &&
	grep -q '^ # Pre-existing comment' "$DOC_LENS_FIXTURE" &&
	[[ -s "$ROOT_DIR/tests/lenses/fixtures/documentation-lens.expected" ]]; then
	pass "documentation lens fixture diff and expected findings are committed"
else
	fail "documentation lens fixture diff or expected findings missing or incomplete"
fi
if git apply --numstat "$DOC_LENS_FIXTURE" >/dev/null 2>&1; then
	pass "documentation lens fixture is a well-formed patch (hunk counts match its lines)"
else
	fail "documentation lens fixture is a corrupt patch: git apply --numstat rejects it"
fi

# ---------------------------------------------------------------------------
# Active decision records reach the architecture lenses only.
# ---------------------------------------------------------------------------

DECISION_SKILLS=(
	"review-plan:$ROOT_DIR/plugins/skein/skills/review-plan/SKILL.md"
	"deep-review:$ROOT_DIR/plugins/skein/skills/deep-review/SKILL.md"
	"review-plan:$ROOT_DIR/plugins/skein-codex/skills/review-plan/SKILL.md"
	"deep-review:$ROOT_DIR/plugins/skein-codex/skills/deep-review/SKILL.md"
)

decision_has() {
	local text="$1" pattern="$2" label="$3"
	if grep -Eq -- "$pattern" <<<"$text"; then
		pass "decisions ($dec_mirror/$dec_skill): $label"
	else
		fail "decisions ($dec_mirror/$dec_skill): $label"
	fi
}

decision_lacks() {
	local text="$1" pattern="$2" label="$3"
	if grep -Eq -- "$pattern" <<<"$text"; then
		fail "decisions ($dec_mirror/$dec_skill): $label"
	else
		pass "decisions ($dec_mirror/$dec_skill): $label"
	fi
}

# Backticks in these patterns are literal Markdown, not expansions.
# shellcheck disable=SC2016
for dec_entry in "${DECISION_SKILLS[@]}"; do
	dec_skill="${dec_entry%%:*}"
	dec_md="${dec_entry#*:}"
	dec_mirror="${dec_md#"$ROOT_DIR/plugins/"}"
	dec_mirror="${dec_mirror%%/*}"
	require_file "$dec_md" || continue
	dec_all="$(cat "$dec_md")"
	case "$dec_skill" in
	review-plan)
		dec_arch="$(awk '/^<!-- BEGIN GENERIC LENS PROMPT: architecture -->$/{f=1} f; /^<!-- END GENERIC LENS PROMPT: architecture -->$/{f=0}' "$dec_md")"
		dec_others="$(awk '/^<!-- BEGIN GENERIC LENS PROMPT: /{f=($0 !~ /: architecture -->$/)} f; /^<!-- END GENERIC LENS PROMPT: /{f=0}' "$dec_md")"
		decision_has "$dec_arch" '"category":"<category>"' "architecture finding record keeps the open category slot"
		decision_has "$dec_arch" 'as a `Constraint` finding citing the record path' "a decision conflict is a Constraint finding"
		decision_has "$dec_arch" '^- `category` — one of \{Assumption, Constraint, Ambiguity, Risk, Sequencing, Missing Task, Testing Gap, Nonexistent Reference, Contradiction\}\.' \
			"architecture category vocabulary is unchanged"
		decision_has "$dec_all" 'Collect every repo-relative path the plan names in its `\*\*Impl files:\*\*` lines and its `### Files to Modify` and `### New Files to Create` sections, and expand braces yourself' \
			"paths come from the plan's file sections, brace-expanded"
		decision_has "$dec_all" 'the architecture lens alone also gets the active decision records block' \
			"Step 2's allowed inputs name the block for the architecture lens alone"
		if [[ "$dec_mirror" == skein-codex ]]; then
			decision_has "$dec_all" 'run the same lens prompts sequentially.*same allowed inputs, active decision records block' \
				"the sequential fallback receives the same architecture input"
		fi
		decision_has "$dec_all" 'a plan that names no paths' "a plan with no paths is degraded coverage"
		;;
	deep-review)
		if [[ "$dec_mirror" == skein-codex ]]; then
			dec_arch="$(awk '/^### Architecture Lens$/{f=1; next} /^### /{f=0} f' "$dec_md")"
			dec_others="$(awk '/^### /{f=($0 ~ /Lens$/ && $0 !~ /Architecture Lens$/)} /^## /{f=0} f' "$dec_md")"
			decision_has "$dec_arch" '^- `category`: `Architecture`$' "architecture category is unchanged"
			decision_has "$dec_all" '"category":"<category>","location":"<file:line>","summary":"<one line>","evidence":"<evidence>","suggestion":"<suggestion>"\}' \
				"shared finding record shape is unchanged"
			decision_has "$dec_all" '^below\. Only the Architecture Lens also takes active decision records' \
				"the lens prompt input is optional and architecture-only"
			decision_has "$dec_all" '"\$SKILL_DIR"/scripts/decisions-active\.sh -- "\$\{p\[@\]\}"' \
				"passes each path as one literal argument after --"
		else
			dec_arch="$(awk '/^#### Architecture Lens/{f=1; next} /^#### /{f=0} f' "$dec_md")"
			dec_others="$(awk '/^#### Architecture Lens/{f=0; next} /^#### .*Lens/{f=1; next} /^### /{f=0} f' "$dec_md")"
			decision_has "$dec_arch" '"category":"Architecture","location":"<file:line>","summary":"<one line>","evidence":"<evidence>","suggestion":"<suggestion>"\}' \
				"architecture finding record shape is unchanged"
			decision_has "$dec_arch" '^\*\*Location\*\* \(file_path:line\), \*\*Finding\*\*, \*\*Evidence\*\* \(pattern/convention violated\), \*\*Suggestion\*\*\.$' \
				"architecture output fields are unchanged"
			decision_has "$dec_all" '"\$\{CLAUDE_PLUGIN_ROOT\}"/skills/deep-review/scripts/decisions-active\.sh -- "\$\{p\[@\]\}"' \
				"passes each path as one literal argument after --"
		fi
		decision_has "$dec_all" 'git diff --no-ext-diff --no-renames --name-only -z' \
			"the resolved diff contributes both rename paths"
		decision_has "$dec_arch" '^- Decision records: code that contradicts a record under Active Decision Records, or that should supersede one' \
			"architecture scope covers decision conflicts"
		;;
	esac
	if [[ "$(grep -c '^<untrusted-content>$' <<<"$dec_arch")" -eq "$(grep -c '^</untrusted-content>$' <<<"$dec_arch")" ]] &&
		[[ "$(grep -A1 '^<untrusted-content>$' <<<"$dec_arch" | grep -c '^{{ACTIVE_DECISIONS}}$')" -eq 1 ]] &&
		[[ "$(grep -A1 '^{{ACTIVE_DECISIONS}}$' <<<"$dec_arch" | grep -c '^</untrusted-content>$')" -eq 1 ]]; then
		pass "decisions ($dec_mirror/$dec_skill): exactly one wrapped block in the architecture prompt"
	else
		fail "decisions ($dec_mirror/$dec_skill): the architecture prompt's block is missing, unwrapped or duplicated"
	fi
	if [[ -n "$dec_others" ]]; then
		decision_lacks "$dec_others" 'ACTIVE_DECISIONS' "no other lens prompt carries the block"
	else
		fail "decisions ($dec_mirror/$dec_skill): other lens prompts not found, layout drift"
	fi
	decision_lacks "$dec_arch" 'as a `?Contradiction`? finding' "decision conflicts never use the reserved Contradiction category"
	if [[ "$dec_mirror" == skein-codex ]]; then
		decision_has "$dec_all" '"\$SKILL_DIR"/scripts/decisions-active\.sh' "runs the bundled selector through the Codex path anchor"
		decision_lacks "$dec_all" 'CLAUDE_PLUGIN_ROOT.*decisions-active' "never uses the Claude selector anchor"
	else
		decision_has "$dec_all" "\"\\\$\\{CLAUDE_PLUGIN_ROOT\\}\"/skills/$dec_skill/scripts/decisions-active\\.sh" \
			"runs the bundled selector through the Claude path anchor"
		decision_lacks "$dec_all" 'SKILL_DIR"?/scripts/decisions-active' "never uses the Codex selector anchor"
	fi
	if [[ "$dec_skill" != deep-review ]]; then
		decision_has "$dec_all" 'exec "\$1" -- "\$\{p\[@\]\}"' "passes each path as one literal argument after --"
	fi
	decision_lacks "$dec_all" 'mapfile|readarray|\$\{[^}]*,,' "the selector call runs on bash 3.2"
	decision_has "$dec_all" 'Exit `0` with empty output means no record applies, a genuine result' "an empty match is genuine"
	decision_has "$dec_all" 'Exit `3`, any other non-zero exit, a missing selector' "exit 3 or an unavailable selector is degraded coverage"
	decision_has "$dec_all" 'final `DECISIONS-TRUNCATED:` line means coverage is missing or degraded' "truncation is degraded coverage"
	decision_has "$dec_all" 'Never report that as "no applicable decisions"' "degraded coverage is never no applicable decisions"
	decision_has "$dec_all" 'reuse the same block for every attempt of the [Aa]rchitecture [Ll]ens, including a respawn' "a retry reuses the same block"
	# Both mirrors refresh architecture on every same-scope resume and fence off
	# its earlier attempts, so a stale or vanished record cannot linger.
	decision_has "$dec_all" 'Re-run architecture over all its assigned units, even if it completed and the fresh selection is empty' \
		"resume refreshes architecture even after the last applicable record disappears"
	decision_has "$dec_all" '--from-attempt architecture:N. on every collector call' \
		"every collector call excludes earlier architecture attempts"
	decision_lacks "$dec_all" 'when it selects none, reuse it as above' \
		"no mirror reuses a completed architecture lens on resume"
	dec_collectors="$(grep -E 'collect-lens-results\.sh --root' <<<"$dec_all" || true)"
	if [[ -n "$dec_collectors" ]] && ! grep -v -- '--from-attempt "architecture:<N>"' <<<"$dec_collectors" | grep -q .; then
		pass "decisions ($dec_mirror/$dec_skill): every collector command line carries the architecture attempt boundary"
	else
		fail "decisions ($dec_mirror/$dec_skill): a collector command line lacks [--from-attempt \"architecture:<N>\"]"
	fi
done

DEC_RUBRIC="$ROOT_DIR/plugins/skein/skills/review-plan/rubric.md"
# shellcheck disable=SC2016
if grep -qF -- '- `architecture` alone receives the active `docs/decisions/` records that apply to the plan'"'"'s paths, inside `<untrusted-content>`; a plan decision that contradicts or should supersede one is a `Constraint` finding, never `Contradiction`' "$DEC_RUBRIC"; then
	pass "review-plan rubric scopes decision records to architecture as Constraint"
else
	fail "review-plan rubric lacks the architecture decision-records bullet"
fi

# The committed lens fixtures: each case's selector output must match the
# exact block its .expected file records after its leading "# " notes.
DEC_FIXTURES="$ROOT_DIR/tests/lenses/fixtures/decisions"
dec_tmp="$(mktemp -d)"
cp -R "$DEC_FIXTURES/repo/." "$dec_tmp/"
git -C "$dec_tmp" init -q
if "$ROOT_DIR/scripts/check-decisions.sh" "$dec_tmp" >/dev/null 2>&1; then
	pass "decision lens fixture records pass the validator"
else
	fail "decision lens fixture records fail check-decisions.sh"
fi
for dec_case in conflict unrelated superseded lookalike; do
	if [[ ! -s "$DEC_FIXTURES/$dec_case.paths" || ! -f "$DEC_FIXTURES/$dec_case.expected" ]]; then
		fail "decision lens fixture $dec_case: paths or expected file missing"
		continue
	fi
	dec_paths=()
	while IFS= read -r dec_line; do dec_paths+=("$dec_line"); done <"$DEC_FIXTURES/$dec_case.paths"
	dec_rc=0
	dec_out="$(cd "$dec_tmp" && "$ROOT_DIR/scripts/decisions-active.sh" -- "${dec_paths[@]}")" || dec_rc=$?
	dec_want="$(awk 'body || !/^# / {body=1; print}' "$DEC_FIXTURES/$dec_case.expected")"
	if [[ $dec_rc -eq 0 && "$dec_out" == "$dec_want" ]]; then
		pass "decision lens fixture $dec_case: selector output matches its expected result"
	else
		fail "decision lens fixture $dec_case: selector exit $dec_rc or output differs from $dec_case.expected"
	fi
done
# Executable selector snippets, each mirror's own fence run as written (the
# Claude anchor resolved through the environment). Contract: the snippet's
# stdout is exactly two status lines, `selector-exit=` and `selector-output=`;
# the named file holds the selector's stdout and nothing else; deep-review
# hands the selector both sides of a rename, runs no selector for an empty
# range, and reports a failed diff as exit 4 with no record text.
# dec_fence <SKILL.md> <section opener regex>: the first fence after the opener.
dec_fence() {
	DEC_OPENER="$2" awk '
		$0 ~ ENVIRON["DEC_OPENER"] { section = 1; next }
		code && /^```$/ { exit }
		section && /^```(bash)?$/ { code = 1; next }
		code { print }
	' "$1"
}
# dec_run_snippet <mirror> <snippet>: runs it in $dec_tmp; sets dec_status,
# dec_text (the output file's content) and dec_lines (stdout line count).
# The Bash tool may run zsh, where `path`, `status` and `argv` are special
# parameters (assigning `path` rewrites PATH), so each snippet also runs under
# zsh when it is installed: dec_shell is bash or zsh.
dec_shell=bash
dec_run_snippet() {
	local out file
	out="$(cd "$dec_tmp" && SKILL_DIR="$ROOT_DIR/plugins/$1/skills/$dec_exec_skill" CLAUDE_PLUGIN_ROOT="$ROOT_DIR/plugins/$1" "$dec_shell" -e <<<"$2")" || true
	dec_lines="$(grep -c '' <<<"$out" || true)"
	dec_status="$(sed -n 's/^selector-exit=//p' <<<"$out")"
	file="$(sed -n 's/^selector-output=//p' <<<"$out")"
	dec_text=""
	[[ -n "$file" && -f "$file" ]] && dec_text="$(cat "$file")" && rm -f -- "$file"
	return 0
}
mkdir -p "$dec_tmp/src/cache" "$dec_tmp/archive"
printf 'unchanged file\n' >"$dec_tmp/src/cache/index.py"
git -C "$dec_tmp" add -- src/cache/index.py
git -C "$dec_tmp" -c user.name=Skein -c user.email=skein@example.invalid -c commit.gpgsign=false commit -qm 'Add cache file'
git -C "$dec_tmp" mv -- src/cache/index.py archive/index.py
git -C "$dec_tmp" -c user.name=Skein -c user.email=skein@example.invalid -c commit.gpgsign=false commit -qm 'Move cache file'
if [[ "$(git -C "$dec_tmp" diff --name-only --find-renames HEAD^ HEAD)" == archive/index.py ]]; then
	pass "the rename fixture hides the source path under default rename detection"
else
	fail "the rename fixture does not exercise rename detection"
fi
dec_shells=(bash)
if command -v zsh >/dev/null 2>&1; then
	dec_shells+=(zsh)
else
	pass "zsh is not installed; the selector snippets run under bash only"
fi
# dec_range <snippet> <base> <head>: the deep-review snippet for that range.
dec_range() {
	local snippet="${1//<run_id>/decisions-shape}"
	snippet="${snippet/BASE=\"<base>\"/BASE=\"$2\"}"
	printf '%s\n' "${snippet/TIP=\"<head>\"/TIP=\"$3\"}"
}
dec_exec_skill=deep-review
for dec_mirror in skein skein-codex; do
	selector_snippet="$(dec_fence "$ROOT_DIR/plugins/$dec_mirror/skills/deep-review/SKILL.md" '^\*\*Active decision records \(Architecture Lens only\)\.')"
	# shellcheck disable=SC2016  # the snippet text is literal
	if [[ "$selector_snippet" == *mktemp* || "$selector_snippet" != *'LENS_DIR="$REPO_ROOT/.deep-review/lenses/<run_id>"'* ||
		"$selector_snippet" != *'DECISIONS="$LENS_DIR/decision-records.txt"'* || "$selector_snippet" != *'"$LENS_DIR/decision-paths.z"'* ]]; then
		fail "$dec_mirror deep-review keeps the selector output and path list outside the run's lens directory"
	else
		pass "$dec_mirror deep-review writes decision-paths.z and decision-records.txt in the run's lens directory"
	fi
	for dec_shell in "${dec_shells[@]}"; do
		# cells: rename range, empty range, failed range
		dec_run_snippet "$dec_mirror" "$(dec_range "$selector_snippet" 'HEAD^' HEAD)"
		if [[ "$dec_status" == 0 && "$dec_lines" == 2 ]] &&
			grep -qxF '### Record: docs/decisions/20261101-cache-store.md' <<<"$dec_text" &&
			[[ "$dec_text" != *selector-exit* ]]; then
			pass "[$dec_shell] $dec_mirror deep-review selects a record that applies only to a rename source, status kept out of the block"
		else
			fail "[$dec_shell] $dec_mirror deep-review lost the rename-source record or mixed the status into the block (exit '$dec_status', $dec_lines lines)"
		fi
		dec_run_snippet "$dec_mirror" "$(dec_range "$selector_snippet" HEAD HEAD)"
		if [[ "$dec_status" == 0 && -z "$dec_text" ]]; then
			pass "[$dec_shell] $dec_mirror deep-review runs no selector for a range with no changed path"
		else
			fail "[$dec_shell] $dec_mirror deep-review on an empty range: exit '$dec_status', block '$dec_text'"
		fi
		dec_run_snippet "$dec_mirror" "$(dec_range "$selector_snippet" missing HEAD)"
		if [[ "$dec_status" == 4 && -z "$dec_text" ]]; then
			pass "[$dec_shell] $dec_mirror deep-review exposes path acquisition failure without record text"
		else
			fail "[$dec_shell] $dec_mirror deep-review did not report a failed diff (exit '$dec_status')"
		fi
	done
done
# A --pr review whose base branch advanced after the fork: the selection uses
# the merge base, as `gh pr diff` does, so a base-only change to src/cache/
# selects no record for a PR that touched only notes.txt.
dec_fork="$(git -C "$dec_tmp" rev-parse HEAD)"
git -C "$dec_tmp" checkout -q -b pr-head
printf 'notes\n' >"$dec_tmp/notes.txt"
git -C "$dec_tmp" add -- notes.txt
git -C "$dec_tmp" -c user.name=Skein -c user.email=skein@example.invalid -c commit.gpgsign=false commit -qm 'PR change'
git -C "$dec_tmp" checkout -q -b base-tip "$dec_fork"
printf 'advanced\n' >"$dec_tmp/src/cache/advanced.py"
git -C "$dec_tmp" add -- src/cache/advanced.py
git -C "$dec_tmp" -c user.name=Skein -c user.email=skein@example.invalid -c commit.gpgsign=false commit -qm 'Base advances'
if git -C "$dec_tmp" diff --name-only base-tip..pr-head | grep -qx src/cache/advanced.py; then
	pass "the advanced-base fixture puts a base-only change in the two-dot range"
else
	fail "the advanced-base fixture does not exercise an advanced base"
fi
for dec_mirror in skein skein-codex; do
	selector_snippet="$(dec_fence "$ROOT_DIR/plugins/$dec_mirror/skills/deep-review/SKILL.md" '^\*\*Active decision records \(Architecture Lens only\)\.')"
	dec_run_snippet "$dec_mirror" "$(dec_range "$selector_snippet" base-tip pr-head)"
	if [[ "$dec_status" == 0 && -z "$dec_text" ]] &&
		[[ "$(tr '\0' '\n' <"$dec_tmp/.deep-review/lenses/decisions-shape/decision-paths.z")" == notes.txt ]]; then
		pass "$dec_mirror deep-review selects over the merge base, not the advanced base tip"
	else
		fail "$dec_mirror deep-review selected over the advanced base tip (exit '$dec_status', block '$dec_text')"
	fi
done
dec_exec_skill=review-plan
for dec_mirror in skein skein-codex; do
	selector_snippet="$(dec_fence "$ROOT_DIR/plugins/$dec_mirror/skills/review-plan/SKILL.md" '^\*\*Active decision records \(architecture lens only\)\.')"
	# shellcheck disable=SC2016  # the snippet text is literal
	if [[ "$selector_snippet" == *mktemp* || "$selector_snippet" != *'DECISIONS="$REPO_ROOT/.review-plan/lenses/$RUN_ID/decision-records.txt"'* ]]; then
		fail "$dec_mirror review-plan keeps the selector output outside the run's lens directory"
	else
		pass "$dec_mirror review-plan writes decision-records.txt in the run's lens directory"
	fi
	selector_snippet="${selector_snippet//<run_id>/decisions-shape}"
	mkdir -p "$dec_tmp/.review-plan/lenses/decisions-shape"
	for dec_shell in "${dec_shells[@]}"; do
		for dec_case in conflict unrelated; do
			cp "$DEC_FIXTURES/$dec_case.paths" "$dec_tmp/.review-plan/lenses/decisions-shape/decision-paths.txt"
			dec_run_snippet "$dec_mirror" "$selector_snippet"
			dec_want="$(awk 'body || !/^# / {body=1; print}' "$DEC_FIXTURES/$dec_case.expected")"
			if [[ "$dec_status" == 0 && "$dec_lines" == 2 && "$dec_text" == "$dec_want" ]]; then
				pass "[$dec_shell] $dec_mirror review-plan keeps the selector status out of the $dec_case block"
			else
				fail "[$dec_shell] $dec_mirror review-plan $dec_case: exit '$dec_status', $dec_lines status lines, or the block differs from $dec_case.expected"
			fi
		done
	done
done
rm -rf "$dec_tmp"
if grep -q '^### Record: docs/decisions/20261101-cache-store\.md$' "$DEC_FIXTURES/conflict.expected" &&
	! grep -q '^### Record: ' "$DEC_FIXTURES/superseded.expected" &&
	! grep -q '^### Record: ' "$DEC_FIXTURES/unrelated.expected" &&
	grep -qF '<\/untrusted-content data-x="1">' "$DEC_FIXTURES/lookalike.expected" &&
	! grep -qi '</untrusted-content' "$DEC_FIXTURES/lookalike.expected" &&
	git apply --numstat "$DEC_FIXTURES/conflict.diff" >/dev/null 2>&1; then
	pass "decision lens fixtures cover the conflict, superseded and closing-tag cases"
else
	fail "decision lens fixtures do not cover the conflict, superseded and closing-tag cases"
fi

echo ""
echo "Summary: $pass_count passed, $fail_count failed"

if [[ $fail_count -ne 0 ]]; then
	exit 1
fi
exit 0
