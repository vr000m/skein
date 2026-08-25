#!/usr/bin/env bash
# test-derived-lenses-state.sh — Phase 2 acceptance for the `--continue`
# re-run set as derived from a persisted `.lenses` object.
#
# Plan: docs/dev_plans/20260823-feature-review-skills-resilience.md, R4
# ("`--continue` re-runs `timed_out|errored|partial|absent` (`skipped` is
# terminal)") and the Phase 2 checklist ("Derived-state test asserts the
# `--continue` re-run set derived from `.lenses`").
#
# There is no separate script that computes the re-run set -- per the
# plan's Decision Log and Data Flow table, `--continue`'s re-run set is a
# derivation the deep-review orchestrator itself makes by reading the
# `.lenses` object persist-deep-review-state.sh's `--from-collector` flag
# produces (docs/dev_plans/20260823-feature-review-skills-resilience.md,
# Phase 2, "Derived lens summary" data-flow row). This suite exercises the
# real chain end to end:
#
#   scripts/collect-lens-results.sh (builds per-lens status from JSONL
#   fixtures) | scripts/persist-deep-review-state.sh --from-collector
#   (persists it to .lenses) -> jq reads back .lenses and applies the
#   documented filter (re-run iff status in {timed_out, errored, partial}
#   or the lens key is absent; NOT skipped or completed).
#
# This is intentionally the one test in the Phase 2 suite that depends on
# BOTH scripts.collect-lens-results.sh AND persist-deep-review-state.sh
# --from-collector existing -- if either is missing, this suite reports a
# clean preflight FAIL rather than a raw bash error.
#
# Exit codes: 0 all assertions pass, 1 any assertion fails.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COLLECT="$REPO_ROOT/scripts/collect-lens-results.sh"
PERSIST="$REPO_ROOT/scripts/persist-deep-review-state.sh"

TMPDIR_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

pass_count=0
fail_count=0
pass() {
	echo "PASS: $*"
	pass_count=$((pass_count + 1))
}
fail() {
	echo "FAIL: $*" >&2
	fail_count=$((fail_count + 1))
}

finish() {
	echo ""
	echo "Summary: $pass_count passed, $fail_count failed"
	if [[ $fail_count -ne 0 ]]; then
		exit 1
	fi
	exit 0
}

missing=0
if [[ ! -x "$COLLECT" ]]; then
	fail "preflight (scripts/collect-lens-results.sh not found/executable at $COLLECT -- not implemented yet)"
	missing=1
fi
if [[ ! -x "$PERSIST" ]]; then
	fail "preflight (scripts/persist-deep-review-state.sh not found/executable at $PERSIST)"
	missing=1
fi
if ! command -v jq >/dev/null 2>&1; then
	fail "preflight (jq required by this test harness, not found on PATH)"
	missing=1
fi
if [[ "$missing" -ne 0 ]]; then
	finish
fi

make_scratch_repo() {
	local dir="$1"
	mkdir -p "$dir"
	(
		cd "$dir"
		git init -q
		git config user.email "test@example.com"
		git config user.name "Test"
		echo "placeholder" >README.md
		git add README.md
		git commit -q -m "init"
	)
}

lens_file() {
	local dir="$1" run_id="$2" lens="$3" attempt="$4"
	printf '%s/.deep-review/lenses/%s/%s.%s.jsonl' "$dir" "$run_id" "$lens" "$attempt"
}

write_lens_file() {
	local path="$1"
	mkdir -p "$(dirname "$path")"
	cat >"$path"
}

# The documented re-run filter, applied here (in the test, not in
# implementation code) exactly as R4 states it: re-run iff status is
# timed_out, errored, or partial, OR the lens key is absent from .lenses
# entirely ("absent"). completed and skipped are both terminal.
rerun_set() {
	local lenses_json="$1"
	printf '%s' "$lenses_json" | jq -c '
		[to_entries[] | select(.value.status == "timed_out" or .value.status == "errored" or .value.status == "partial" or .value.status == "missing") | .key] | sort
	'
}

DIR="$TMPDIR_ROOT/scratch"
make_scratch_repo "$DIR"
RUN_ID="derived-1"

# Five lenses, one per status this test needs to distinguish, plus one
# lens entirely absent from --expected's own bookkeeping is not
# representable here (collect-lens-results.sh always reports every
# --expected lens, using "missing" rather than omitting the key -- see
# test-lens-collect.sh cases (i)/(j)), so "absent" is exercised as the
# collector's "missing" status value, per R4's own parenthetical
# ("absent = missing").
write_lens_file "$(lens_file "$DIR" "$RUN_ID" completed-lens 1)" <<'JSONL'
{"type":"start","run_id":"derived-1","units":["u1"]}
{"type":"progress","unit":"u1"}
{"type":"done","status":"completed"}
JSONL
write_lens_file "$(lens_file "$DIR" "$RUN_ID" skipped-lens 1)" <<'JSONL'
{"type":"start","run_id":"derived-1","units":["u1"]}
{"type":"done","status":"skipped"}
JSONL
write_lens_file "$(lens_file "$DIR" "$RUN_ID" errored-lens 1)" <<'JSONL'
{"type":"start","run_id":"derived-1","units":["u1"]}
{"type":"done","status":"errored"}
JSONL
write_lens_file "$(lens_file "$DIR" "$RUN_ID" partial-lens 1)" <<'JSONL'
{"type":"start","run_id":"derived-1","units":["u1","u2"]}
{"type":"progress","unit":"u1"}
JSONL
# timed_out-lens: two attempts, neither reaches done.
write_lens_file "$(lens_file "$DIR" "$RUN_ID" timedout-lens 1)" <<'JSONL'
{"type":"start","run_id":"derived-1","units":["u1","u2"]}
{"type":"progress","unit":"u1"}
JSONL
write_lens_file "$(lens_file "$DIR" "$RUN_ID" timedout-lens 2)" <<'JSONL'
{"type":"start","run_id":"derived-1","units":["u2"]}
JSONL
# missing-lens: no attempt file at all.

collector_out="$(
	cd "$DIR" && bash "$COLLECT" --skill deep-review --run-id "$RUN_ID" \
		--expected "completed-lens:u1" \
		--expected "skipped-lens:u1" \
		--expected "errored-lens:u1" \
		--expected "partial-lens:u1,u2" \
		--expected "timedout-lens:u1,u2" \
		--expected "missing-lens:u1"
)"

persisted="$(
	cd "$DIR" && printf '%s' "$collector_out" | bash "$PERSIST" --harness claude --run-id "$RUN_ID" \
		--base-commit aaa --head-commit bbb --diff-hash ccc --review-focus-hash "" --from-collector
)"

target="$DIR/.deep-review/latest-claude.json"
if [[ ! -f "$target" ]]; then
	fail "(setup) --from-collector persisted a .lenses object to disk (no file at $target)"
	finish
fi

lenses_json="$(jq -c '.lenses' "$target")"

expected_rerun='["errored-lens","missing-lens","partial-lens","timedout-lens"]'
actual_rerun="$(rerun_set "$lenses_json")"

if [[ "$actual_rerun" == "$expected_rerun" ]]; then
	pass "(1) --continue re-run set = {errored, missing/absent, partial, timed_out}, sorted: $actual_rerun"
else
	fail "(1) --continue re-run set derived from .lenses (expected $expected_rerun, got $actual_rerun)"
	echo "    .lenses was: $lenses_json"
fi

if printf '%s' "$actual_rerun" | jq -e 'index("completed-lens") == null' >/dev/null 2>&1; then
	pass "(2) completed lens excluded from --continue re-run set"
else
	fail "(2) completed lens excluded from --continue re-run set"
fi

if printf '%s' "$actual_rerun" | jq -e 'index("skipped-lens") == null' >/dev/null 2>&1; then
	pass "(3) skipped lens excluded from --continue re-run set (terminal per R4)"
else
	fail "(3) skipped lens excluded from --continue re-run set"
fi

# ---------------------------------------------------------------------------
# (4) F3/D2 -- a --attempts-derived timed_out lens (spawned attempt 2 wrote
#     no file at all) still ends up in the --continue re-run set once piped
#     through persist-deep-review-state.sh --from-collector.
# ---------------------------------------------------------------------------

RUN_ID2="derived-2"
write_lens_file "$(lens_file "$DIR" "$RUN_ID2" silent-lens 1)" <<'JSONL'
{"type":"start","run_id":"derived-2","units":["u1","u2"]}
{"type":"progress","unit":"u1"}
JSONL
# No attempt-2 file at all for silent-lens -- the orchestrator spawned a
# respawn that never wrote anything (the "truly silent attempt 2" defect).

collector_out2="$(
	cd "$DIR" && bash "$COLLECT" --skill deep-review --run-id "$RUN_ID2" \
		--expected "silent-lens:u1,u2" --attempts "silent-lens:2"
)"

if printf '%s' "$collector_out2" | jq -e '."silent-lens".status == "timed_out"' >/dev/null 2>&1; then
	pass "(4a) collect-lens-results.sh --attempts silent-lens:2 (no attempt-2 file) -> timed_out"
else
	fail "(4a) --attempts-derived timed_out (collector output was: $collector_out2)"
fi

persisted2="$(
	cd "$DIR" && printf '%s' "$collector_out2" | bash "$PERSIST" --harness claude --run-id "$RUN_ID2" \
		--base-commit aaa --head-commit bbb --diff-hash ccc --review-focus-hash "" --from-collector
)"

target2="$DIR/.deep-review/latest-claude.json"
lenses_json2="$(jq -c '.lenses' "$target2")"
actual_rerun2="$(rerun_set "$lenses_json2")"

if printf '%s' "$actual_rerun2" | jq -e 'index("silent-lens") != null' >/dev/null 2>&1; then
	pass "(4b) --attempts-derived timed_out lens is included in the --continue re-run set: $actual_rerun2"
else
	fail "(4b) --attempts-derived timed_out lens should be in the --continue re-run set (got $actual_rerun2)"
	echo "    .lenses was: $lenses_json2"
fi


# ---------------------------------------------------------------------------
# (C13) The skill -> state-dir mapping lives in FOUR places; each must
# cross-reference the others.
#
# r2 finding #13: `persist_lens_state_dir` duplicates `af_manifest_dir`'s
# mapping. Consolidation was QUARANTINED on purpose -- they differ in root
# source ($AF_COMMON_ROOT vs an argument) and in failure exit code (2 vs 1),
# so merging them is a behaviour change at four call sites for no functional
# gain. The residual risk is silent divergence: someone adding a third skill
# updates one arm and not the others. Guard the discoverability instead --
# every site names the shared marker and carries BOTH arms.
# ---------------------------------------------------------------------------

C13_MARKER='SKILL->STATE-DIR MAPPING (4 sites)'
c13_sites=(
	"$REPO_ROOT/scripts/lib/lens-common.sh"
	"$REPO_ROOT/scripts/lib/auto-fix-common.sh"
	"$REPO_ROOT/scripts/persist-deep-review-state.sh"
	"$REPO_ROOT/scripts/persist-review-state.sh"
)
for c13_site in "${c13_sites[@]}"; do
	c13_name="${c13_site#"$REPO_ROOT/"}"
	if [[ ! -f "$c13_site" ]]; then
		fail "(C13) mapping site missing: $c13_name"
		continue
	fi
	if ! grep -qF "$C13_MARKER" "$c13_site"; then
		fail "(C13) $c13_name does not carry the shared mapping marker '$C13_MARKER'"
	elif ! grep -q '\.deep-review' "$c13_site" || ! grep -q '\.review-plan' "$c13_site"; then
		fail "(C13) $c13_name is missing one arm of the mapping (.deep-review / .review-plan)"
	else
		pass "(C13) $c13_name cross-references the mapping and carries both arms"
	fi
done

# ---------------------------------------------------------------------------
# (C14) persist-common.sh's header must state the REAL --root asymmetry.
#
# r2 finding #14: the header claimed both Phase-2 consumers take an explicit
# --root and so this helper never falls back to cwd. True of the WRITER
# (persist-lens-result.sh hard-errors without --root); FALSE of the READER
# (collect-lens-results.sh makes --root optional and falls back to
# persist_root_dir when cwd is inside a worktree).
# ---------------------------------------------------------------------------

c14_file="$REPO_ROOT/scripts/lib/lens-common.sh"
if grep -q 'Neither script derives a root from cwd' "$c14_file"; then
	fail "(C14) persist-common.sh still claims neither Phase-2 consumer derives a root from cwd"
elif grep -qi 'asymmetr' "$c14_file" && grep -q 'collect-lens-results.sh' "$c14_file"; then
	pass "(C14) persist-common.sh documents the writer/reader --root asymmetry"
else
	fail "(C14) persist-common.sh does not document the writer/reader --root asymmetry"
fi

finish
