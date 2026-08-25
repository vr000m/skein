#!/usr/bin/env bash
# test-lens-collect.sh — Phase 2 acceptance for scripts/collect-lens-results.sh
# (the streamed-lens-results merger/collector).
#
# Plan: docs/dev_plans/20260823-feature-review-skills-resilience.md, R3/R4
# and the Phase 2 checklist ("Tests (collector)").
#
# Contract under test (per the plan; the script did not exist yet at the
# time this suite was written):
#
#   scripts/collect-lens-results.sh --skill deep-review|review-plan \
#       --run-id <id> --expected <lens:units,...> [--expected <lens:units,...> ...]
#
#   Reads every `<state-dir>/lenses/<run-id>/<lens>.<attempt>.jsonl` file
#   under the current git worktree (root-anchored the same way the other
#   persist/collect scripts are -- ASSUMPTION: no separate --root flag is
#   named in the plan's abbreviated collector signature, unlike
#   persist-lens-result.sh's explicit --root; this suite runs the collector
#   from inside the scratch git repo it builds so root-anchoring resolves
#   correctly either way. If the real script instead requires --root, only
#   the invocation wrapper below needs a flag added -- the fixtures and
#   assertions do not change), merges attempts, and emits on stdout a JSON
#   object keyed by lens name, each value:
#     {"status": ..., "reviewed": N, "assigned": N, "unreviewed": [...],
#      "findings": [...]}
#   status enum: completed|partial|timed_out|errored|skipped, or "missing"
#   for a lens with no attempt file at all (R4: "for a missing lens,
#   unreviewed := the full assigned list").
#
#   Merge rule: attempts for a lens are read in attempt-number order;
#   findings are deduped by (file, line, category) (R4: "the reconciler's
#   (file, line, category) signature"); reviewed/unreviewed are the union
#   of progress units seen across all attempts, up to the total assigned
#   count.
#
# Exit codes: 0 all assertions pass, 1 any assertion fails.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/collect-lens-results.sh"

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

if [[ ! -f "$SCRIPT" ]]; then
	fail "preflight (scripts/collect-lens-results.sh not found at $SCRIPT -- not implemented yet)"
	finish
fi

if [[ ! -x "$SCRIPT" ]]; then
	fail "preflight (scripts/collect-lens-results.sh found but not executable at $SCRIPT)"
	finish
fi

if ! command -v jq >/dev/null 2>&1; then
	fail "preflight (jq required by this test harness, not found on PATH)"
	finish
fi

# make_scratch_repo <dir> -- a bare git repo so root-anchoring (git
# rev-parse --show-toplevel) resolves inside the scratch tree, not this
# repository's own working tree.
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

# lens_file <repo_dir> <skill> <run_id> <lens> <attempt>
lens_file() {
	local dir="$1" skill="$2" run_id="$3" lens="$4" attempt="$5"
	local state_dir
	case "$skill" in
	deep-review) state_dir=".deep-review" ;;
	review-plan) state_dir=".review-plan" ;;
	esac
	printf '%s/%s/lenses/%s/%s.%s.jsonl' "$dir" "$state_dir" "$run_id" "$lens" "$attempt"
}

write_lens_file() {
	local path="$1"
	mkdir -p "$(dirname "$path")"
	cat >"$path"
}

# run_collect <repo_dir> <skill> <run_id> <expected...>
# Runs from inside <repo_dir> so git-root-anchoring resolves there.
run_collect() {
	local repo_dir="$1" skill="$2" run_id="$3"
	shift 3
	local expected_args=()
	for e in "$@"; do
		expected_args+=(--expected "$e")
	done
	(cd "$repo_dir" && bash "$SCRIPT" --skill "$skill" --run-id "$run_id" "${expected_args[@]}")
}

# run_collect_attempts <repo_dir> <skill> <run_id> <expected_csv> <attempts_csv> [extra args...]
# <expected_csv> and <attempts_csv> are space-separated lists of
# "<lens>:<val>" entries (space-separated so callers can pass multiple
# without nested-array plumbing); each becomes its own --expected/--attempts
# flag. Extra trailing args (e.g. --findings-jsonl) are passed through
# verbatim.
run_collect_attempts() {
	local repo_dir="$1" skill="$2" run_id="$3" expected_csv="$4" attempts_csv="$5"
	shift 5
	local args=(--skill "$skill" --run-id "$run_id")
	for e in $expected_csv; do
		args+=(--expected "$e")
	done
	for a in $attempts_csv; do
		args+=(--attempts "$a")
	done
	args+=("$@")
	(cd "$repo_dir" && bash "$SCRIPT" "${args[@]}")
}

# run_collect_jsonl <repo_dir> <skill> <run_id> <expected...> -- like
# run_collect, but always appends --findings-jsonl at the end (kept
# separate from run_collect's variadic --expected loop so the flag is never
# mistaken for an --expected value).
run_collect_jsonl() {
	local repo_dir="$1" skill="$2" run_id="$3"
	shift 3
	local expected_args=()
	for e in "$@"; do
		expected_args+=(--expected "$e")
	done
	(cd "$repo_dir" && bash "$SCRIPT" --skill "$skill" --run-id "$run_id" "${expected_args[@]}" --findings-jsonl)
}

# ---------------------------------------------------------------------------
# (a) done -> completed
# ---------------------------------------------------------------------------

dir_a="$TMPDIR_ROOT/case-a"
make_scratch_repo "$dir_a"
write_lens_file "$(lens_file "$dir_a" deep-review a-run logic 1)" <<'JSONL'
{"type":"start","run_id":"a-run","units":["u1","u2","u3"]}
{"type":"progress","unit":"u1"}
{"type":"progress","unit":"u2"}
{"type":"progress","unit":"u3"}
{"type":"done","status":"completed"}
JSONL

out_a="$(run_collect "$dir_a" deep-review a-run "logic:u1,u2,u3" 2>"$dir_a/stderr" || true)"
if printf '%s' "$out_a" | jq -e '.logic.status == "completed" and .logic.reviewed == 3 and .logic.assigned == 3 and (.logic.unreviewed | length) == 0' >/dev/null 2>&1; then
	pass "(a) done -> completed (full coverage, no unreviewed)"
else
	fail "(a) done -> completed"
	sed 's/^/    /' "$dir_a/stderr" 2>/dev/null
	echo "    stdout: $out_a"
fi

# ---------------------------------------------------------------------------
# (b) done status:"errored" -> errored
# ---------------------------------------------------------------------------

dir_b="$TMPDIR_ROOT/case-b"
make_scratch_repo "$dir_b"
write_lens_file "$(lens_file "$dir_b" deep-review b-run security 1)" <<'JSONL'
{"type":"start","run_id":"b-run","units":["u1","u2"]}
{"type":"progress","unit":"u1"}
{"type":"done","status":"errored"}
JSONL

out_b="$(run_collect "$dir_b" deep-review b-run "security:u1,u2" 2>"$dir_b/stderr" || true)"
if printf '%s' "$out_b" | jq -e '.security.status == "errored"' >/dev/null 2>&1; then
	pass "(b) done status:errored -> errored"
else
	fail "(b) done status:errored -> errored"
	echo "    stdout: $out_b"
fi

# ---------------------------------------------------------------------------
# (c) orchestrator-written done status:"skipped" -> skipped, and excluded
#     from the --continue re-run set (timed_out|errored|partial|absent)
# ---------------------------------------------------------------------------

dir_c="$TMPDIR_ROOT/case-c"
make_scratch_repo "$dir_c"
write_lens_file "$(lens_file "$dir_c" deep-review c-run spec 1)" <<'JSONL'
{"type":"start","run_id":"c-run","units":["u1"]}
{"type":"done","status":"skipped"}
JSONL

out_c="$(run_collect "$dir_c" deep-review c-run "spec:u1" 2>"$dir_c/stderr" || true)"
if printf '%s' "$out_c" | jq -e '.spec.status == "skipped"' >/dev/null 2>&1; then
	pass "(c) orchestrator-written done status:skipped -> skipped"
	rerun_status="$(printf '%s' "$out_c" | jq -r '.spec.status')"
	if [[ "$rerun_status" == "timed_out" || "$rerun_status" == "errored" || "$rerun_status" == "partial" || "$rerun_status" == "missing" ]]; then
		fail "(c) skipped is excluded from the --continue re-run set (status '$rerun_status' would be re-run)"
	else
		pass "(c) skipped is excluded from the --continue re-run set (terminal, not timed_out|errored|partial|absent)"
	fi
else
	fail "(c) orchestrator-written done status:skipped -> skipped"
	echo "    stdout: $out_c"
fi

# ---------------------------------------------------------------------------
# (d) start + 2/5 progress, no done -> partial 2/5, unreviewed list of 3
# ---------------------------------------------------------------------------

dir_d="$TMPDIR_ROOT/case-d"
make_scratch_repo "$dir_d"
write_lens_file "$(lens_file "$dir_d" deep-review d-run architecture 1)" <<'JSONL'
{"type":"start","run_id":"d-run","units":["u1","u2","u3","u4","u5"]}
{"type":"progress","unit":"u1"}
{"type":"progress","unit":"u2"}
JSONL

out_d="$(run_collect "$dir_d" deep-review d-run "architecture:u1,u2,u3,u4,u5" 2>"$dir_d/stderr" || true)"
if printf '%s' "$out_d" | jq -e '.architecture.status == "partial" and .architecture.reviewed == 2 and .architecture.assigned == 5 and (.architecture.unreviewed | length) == 3 and (.architecture.unreviewed | sort) == (["u3","u4","u5"] | sort)' >/dev/null 2>&1; then
	pass "(d) start + 2/5 progress, no done -> partial 2/5, unreviewed = [u3,u4,u5]"
else
	fail "(d) start + 2/5 progress, no done -> partial 2/5, unreviewed of 3"
	echo "    stdout: $out_d"
fi

# ---------------------------------------------------------------------------
# (e) attempt-2 merge -> no duplicate findings (same finding re-reported
#     across attempts is deduped by (file, line, category))
# ---------------------------------------------------------------------------

dir_e="$TMPDIR_ROOT/case-e"
make_scratch_repo "$dir_e"
write_lens_file "$(lens_file "$dir_e" deep-review e-run logic 1)" <<'JSONL'
{"type":"start","run_id":"e-run","units":["u1","u2","u3"]}
{"type":"progress","unit":"u1"}
{"type":"finding","file":"foo.py","line":10,"category":"bug","message":"first sighting"}
JSONL
write_lens_file "$(lens_file "$dir_e" deep-review e-run logic 2)" <<'JSONL'
{"type":"start","run_id":"e-run","units":["u2","u3"]}
{"type":"progress","unit":"u2"}
{"type":"finding","file":"foo.py","line":10,"category":"bug","message":"re-reported, same signature"}
{"type":"progress","unit":"u3"}
{"type":"finding","file":"bar.py","line":42,"category":"style","message":"a distinct finding"}
{"type":"done","status":"completed"}
JSONL

out_e="$(run_collect "$dir_e" deep-review e-run "logic:u1,u2,u3" 2>"$dir_e/stderr" || true)"
if printf '%s' "$out_e" | jq -e '(.logic.findings | length) == 2' >/dev/null 2>&1; then
	pass "(e) attempt-2 merge -> no duplicate findings (2 unique findings, not 3)"
else
	fail "(e) attempt-2 merge -> no duplicate findings"
	echo "    stdout: $out_e"
fi

# ---------------------------------------------------------------------------
# (f) attempt-3 file (a --continue re-run) merges like any other attempt
# ---------------------------------------------------------------------------

dir_f="$TMPDIR_ROOT/case-f"
make_scratch_repo "$dir_f"
write_lens_file "$(lens_file "$dir_f" deep-review f-run security 1)" <<'JSONL'
{"type":"start","run_id":"f-run","units":["u1","u2","u3"]}
{"type":"progress","unit":"u1"}
JSONL
write_lens_file "$(lens_file "$dir_f" deep-review f-run security 2)" <<'JSONL'
{"type":"start","run_id":"f-run","units":["u2","u3"]}
{"type":"progress","unit":"u2"}
JSONL
write_lens_file "$(lens_file "$dir_f" deep-review f-run security 3)" <<'JSONL'
{"type":"start","run_id":"f-run","units":["u3"]}
{"type":"progress","unit":"u3"}
{"type":"done","status":"completed"}
JSONL

out_f="$(run_collect "$dir_f" deep-review f-run "security:u1,u2,u3" 2>"$dir_f/stderr" || true)"
if printf '%s' "$out_f" | jq -e '.security.status == "completed" and .security.reviewed == 3 and .security.assigned == 3' >/dev/null 2>&1; then
	pass "(f) attempt-3 file merges like any attempt (coverage from attempts 1+2+3 combined)"
else
	fail "(f) attempt-3 file merges like any attempt"
	echo "    stdout: $out_f"
fi

# ---------------------------------------------------------------------------
# (g) attempt-1 partial + attempt-2 partial/missing -> timed_out with
#     merged coverage
# ---------------------------------------------------------------------------

dir_g="$TMPDIR_ROOT/case-g"
make_scratch_repo "$dir_g"
write_lens_file "$(lens_file "$dir_g" deep-review g-run architecture 1)" <<'JSONL'
{"type":"start","run_id":"g-run","units":["u1","u2","u3","u4","u5"]}
{"type":"progress","unit":"u1"}
{"type":"progress","unit":"u2"}
JSONL
write_lens_file "$(lens_file "$dir_g" deep-review g-run architecture 2)" <<'JSONL'
{"type":"start","run_id":"g-run","units":["u3","u4","u5"]}
{"type":"progress","unit":"u3"}
JSONL

out_g="$(run_collect "$dir_g" deep-review g-run "architecture:u1,u2,u3,u4,u5" 2>"$dir_g/stderr" || true)"
if printf '%s' "$out_g" | jq -e '.architecture.status == "timed_out" and .architecture.reviewed == 3 and .architecture.assigned == 5 and (.architecture.unreviewed | sort) == (["u4","u5"] | sort)' >/dev/null 2>&1; then
	pass "(g) attempt-1 partial + attempt-2 partial/missing -> timed_out with merged coverage (3/5)"
else
	fail "(g) attempt-1 partial + attempt-2 partial/missing -> timed_out with merged coverage"
	echo "    stdout: $out_g"
fi

# ---------------------------------------------------------------------------
# (h) returned-but-no-done -> orchestrator-written done, no respawn
#
# The orchestrator salvages a parseable-but-done-less Agent return by
# writing the done (+finding) lines itself, on attempt 1 -- so from the
# collector's point of view this is indistinguishable from a lens that
# wrote its own done line: status ends up terminal (completed), which is
# exactly what keeps it out of the --continue re-run set (no respawn). The
# "who wrote the done line" distinction is an orchestrator-side fact this
# collector-level test cannot observe directly; it only asserts the
# resulting terminal status a single attempt-1 file produces.
# ---------------------------------------------------------------------------

dir_h="$TMPDIR_ROOT/case-h"
make_scratch_repo "$dir_h"
write_lens_file "$(lens_file "$dir_h" deep-review h-run documentation 1)" <<'JSONL'
{"type":"start","run_id":"h-run","units":["u1","u2"]}
{"type":"progress","unit":"u1"}
{"type":"progress","unit":"u2"}
{"type":"done","status":"completed"}
JSONL

out_h="$(run_collect "$dir_h" deep-review h-run "documentation:u1,u2" 2>"$dir_h/stderr" || true)"
if printf '%s' "$out_h" | jq -e '.documentation.status == "completed" and .documentation.reviewed == 2 and .documentation.assigned == 2' >/dev/null 2>&1; then
	# No attempt-2 file exists for this lens/run-id -- confirms no respawn
	# was needed once the done line landed (attempt 1 only).
	if [[ -f "$(lens_file "$dir_h" deep-review h-run documentation 2)" ]]; then
		fail "(h) returned-but-no-done -> orchestrator-written done, no respawn (an attempt-2 file exists unexpectedly)"
	else
		pass "(h) returned-but-no-done -> orchestrator-written done makes the lens terminal, no respawn (attempt 1 only)"
	fi
else
	fail "(h) returned-but-no-done -> orchestrator-written done, no respawn"
	echo "    stdout: $out_h"
fi

# ---------------------------------------------------------------------------
# (i) stale run-id -> missing
# ---------------------------------------------------------------------------

dir_i="$TMPDIR_ROOT/case-i"
make_scratch_repo "$dir_i"
# A real run-id exists on disk, but we query a *different*, stale/unknown
# run-id -- it should come back missing, not accidentally matched.
write_lens_file "$(lens_file "$dir_i" deep-review real-run logic 1)" <<'JSONL'
{"type":"start","run_id":"real-run","units":["u1"]}
{"type":"done","status":"completed"}
JSONL

out_i="$(run_collect "$dir_i" deep-review stale-run-id-999 "logic:u1,u2,u3" 2>"$dir_i/stderr" || true)"
if printf '%s' "$out_i" | jq -e '.logic.status == "missing" and .logic.reviewed == 0 and .logic.assigned == 3 and (.logic.unreviewed | sort) == (["u1","u2","u3"] | sort)' >/dev/null 2>&1; then
	pass "(i) stale run-id -> missing, unreviewed = full expected list"
else
	fail "(i) stale run-id -> missing"
	echo "    stdout: $out_i"
fi

# ---------------------------------------------------------------------------
# (j) missing dir (no lenses/ directory exists at all for the skill) with
#     --expected units -> unreviewed = full list
# ---------------------------------------------------------------------------

dir_j="$TMPDIR_ROOT/case-j"
make_scratch_repo "$dir_j"
# Deliberately: no .deep-review directory created at all in this scratch
# repo -- the collector must not error, just report every expected lens as
# missing with the full unit list as unreviewed.

out_j="$(run_collect "$dir_j" deep-review never-run "logic:u1,u2" "security:u1,u2,u3" 2>"$dir_j/stderr" || true)"
if printf '%s' "$out_j" | jq -e '
	.logic.status == "missing" and (.logic.unreviewed | sort) == (["u1","u2"] | sort)
	and .security.status == "missing" and (.security.unreviewed | sort) == (["u1","u2","u3"] | sort)
' >/dev/null 2>&1; then
	pass "(j) missing lenses/ directory entirely -> every expected lens missing, unreviewed = full list"
else
	fail "(j) missing lenses/ directory entirely -> every expected lens missing, unreviewed = full list"
	echo "    stdout: $out_j"
	sed 's/^/    /' "$dir_j/stderr" 2>/dev/null
fi

# ---------------------------------------------------------------------------
# (k) truncated last line ignored
# ---------------------------------------------------------------------------

dir_k="$TMPDIR_ROOT/case-k"
make_scratch_repo "$dir_k"
target_k="$(lens_file "$dir_k" deep-review k-run logic 1)"
mkdir -p "$(dirname "$target_k")"
{
	printf '%s\n' '{"type":"start","run_id":"k-run","units":["u1","u2","u3"]}'
	printf '%s\n' '{"type":"progress","unit":"u1"}'
	printf '%s\n' '{"type":"progress","unit":"u2"}'
	# Deliberately truncated trailing line: no closing brace, no newline --
	# simulates a lens process killed mid-write.
	printf '%s' '{"type":"progress","unit":"u3"'
} >"$target_k"

set +e
out_k="$(run_collect "$dir_k" deep-review k-run "logic:u1,u2,u3" 2>"$dir_k/stderr")"
k_exit=$?
set -e

if [[ $k_exit -ne 0 ]]; then
	fail "(k) truncated last line ignored (script exited non-zero instead of tolerating it: $k_exit)"
	sed 's/^/    /' "$dir_k/stderr"
elif printf '%s' "$out_k" | jq -e '.logic.status == "partial" and .logic.reviewed == 2 and (.logic.unreviewed | sort) == (["u3"] | sort)' >/dev/null 2>&1; then
	pass "(k) truncated trailing line is ignored (only the two complete progress lines counted)"
else
	fail "(k) truncated last line ignored"
	echo "    stdout: $out_k"
fi

# ---------------------------------------------------------------------------
# (l) F3/D2 -- truly-silent attempt 2: attempt-1 file with start + partial
#     progress, NO attempt-2 file on disk, --attempts logic:2 -> timed_out,
#     coverage merged from attempt 1 only.
# ---------------------------------------------------------------------------

dir_l="$TMPDIR_ROOT/case-l"
make_scratch_repo "$dir_l"
write_lens_file "$(lens_file "$dir_l" deep-review l-run logic 1)" <<'JSONL'
{"type":"start","run_id":"l-run","units":["u1","u2","u3"]}
{"type":"progress","unit":"u1"}
JSONL

out_l="$(run_collect_attempts "$dir_l" deep-review l-run "logic:u1,u2,u3" "logic:2" 2>"$dir_l/stderr" || true)"
if printf '%s' "$out_l" | jq -e '.logic.status == "timed_out" and .logic.reviewed == 1 and .logic.assigned == 3 and (.logic.unreviewed | sort) == (["u2","u3"] | sort)' >/dev/null 2>&1; then
	pass "(l) truly-silent attempt 2 (--attempts logic:2, no attempt-2 file) -> timed_out, coverage merged from attempt 1"
else
	fail "(l) truly-silent attempt 2 -> timed_out with coverage from attempt 1"
	echo "    stdout: $out_l"
	sed 's/^/    /' "$dir_l/stderr" 2>/dev/null
fi

# ---------------------------------------------------------------------------
# (m) --attempts logic:2 WITH an attempt-2 file present but no done ->
#     timed_out (existing behaviour, now also flag-driven)
# ---------------------------------------------------------------------------

dir_m="$TMPDIR_ROOT/case-m"
make_scratch_repo "$dir_m"
write_lens_file "$(lens_file "$dir_m" deep-review m-run logic 1)" <<'JSONL'
{"type":"start","run_id":"m-run","units":["u1","u2"]}
{"type":"progress","unit":"u1"}
JSONL
write_lens_file "$(lens_file "$dir_m" deep-review m-run logic 2)" <<'JSONL'
{"type":"start","run_id":"m-run","units":["u2"]}
JSONL

out_m="$(run_collect_attempts "$dir_m" deep-review m-run "logic:u1,u2" "logic:2" 2>"$dir_m/stderr" || true)"
if printf '%s' "$out_m" | jq -e '.logic.status == "timed_out"' >/dev/null 2>&1; then
	pass "(m) --attempts logic:2 with an attempt-2 file present, no done -> timed_out"
else
	fail "(m) --attempts logic:2 with attempt-2 file present, no done -> timed_out"
	echo "    stdout: $out_m"
fi

# ---------------------------------------------------------------------------
# (n) --attempts logic:1, one attempt file, no done -> partial (flag must
#     not over-trigger timed_out)
# ---------------------------------------------------------------------------

dir_n="$TMPDIR_ROOT/case-n"
make_scratch_repo "$dir_n"
write_lens_file "$(lens_file "$dir_n" deep-review n-run logic 1)" <<'JSONL'
{"type":"start","run_id":"n-run","units":["u1","u2"]}
{"type":"progress","unit":"u1"}
JSONL

out_n="$(run_collect_attempts "$dir_n" deep-review n-run "logic:u1,u2" "logic:1" 2>"$dir_n/stderr" || true)"
if printf '%s' "$out_n" | jq -e '.logic.status == "partial"' >/dev/null 2>&1; then
	pass "(n) --attempts logic:1, one attempt file, no done -> partial (flag does not over-trigger)"
else
	fail "(n) --attempts logic:1 should still be partial"
	echo "    stdout: $out_n"
fi

# ---------------------------------------------------------------------------
# (o) --attempts logic:2, ZERO attempt files at all -> timed_out with
#     assigned/unreviewed = full expected list
# ---------------------------------------------------------------------------

dir_o="$TMPDIR_ROOT/case-o"
make_scratch_repo "$dir_o"
# No lens files written at all for this run-id.

out_o="$(run_collect_attempts "$dir_o" deep-review o-run "logic:u1,u2,u3" "logic:2" 2>"$dir_o/stderr" || true)"
if printf '%s' "$out_o" | jq -e '.logic.status == "timed_out" and .logic.assigned == 3 and (.logic.unreviewed | sort) == (["u1","u2","u3"] | sort)' >/dev/null 2>&1; then
	pass "(o) --attempts logic:2 with zero attempt files -> timed_out, assigned/unreviewed = full list"
else
	fail "(o) --attempts logic:2 with zero attempt files -> timed_out with full unreviewed list"
	echo "    stdout: $out_o"
	sed 's/^/    /' "$dir_o/stderr" 2>/dev/null
fi

# ---------------------------------------------------------------------------
# (p) --attempts flag ABSENT -> unchanged (regression): re-run cases (d),
#     (g), (i) with no --attempts and confirm identical results to today.
# ---------------------------------------------------------------------------

out_p_d="$(run_collect "$dir_d" deep-review d-run "architecture:u1,u2,u3,u4,u5" 2>/dev/null || true)"
out_p_g="$(run_collect "$dir_g" deep-review g-run "architecture:u1,u2,u3,u4,u5" 2>/dev/null || true)"
if printf '%s' "$out_p_d" | jq -e '.architecture.status == "partial"' >/dev/null 2>&1 \
	&& printf '%s' "$out_p_g" | jq -e '.architecture.status == "timed_out"' >/dev/null 2>&1; then
	pass "(p) --attempts absent -> unchanged behaviour on existing fixtures ((d) partial, (g) timed_out)"
else
	fail "(p) --attempts absent regression (d)/(g) changed status"
fi

# ---------------------------------------------------------------------------
# (q) malformed --attempts entries -> exit 2
# ---------------------------------------------------------------------------

dir_q="$TMPDIR_ROOT/case-q"
make_scratch_repo "$dir_q"

for bad_attempts in "logic" "logic:0" "logic:x" "lo*c:1" "-x:1" "logic:-1"; do
	set +e
	out_q="$(
		cd "$dir_q" && bash "$SCRIPT" --skill deep-review --run-id q-run \
			--expected "logic:u1" --attempts "$bad_attempts" 2>"$dir_q/stderr"
	)"
	q_exit=$?
	set -e
	if [[ $q_exit -eq 2 ]]; then
		pass "(q) malformed --attempts '$bad_attempts' -> exit 2"
	else
		fail "(q) malformed --attempts '$bad_attempts' should exit 2 (got $q_exit)"
		sed 's/^/    /' "$dir_q/stderr" 2>/dev/null
	fi
done

# ---------------------------------------------------------------------------
# (r) --attempts for a lens NOT in --expected -> ignored, exit 0
# ---------------------------------------------------------------------------

dir_r="$TMPDIR_ROOT/case-r"
make_scratch_repo "$dir_r"
write_lens_file "$(lens_file "$dir_r" deep-review r-run logic 1)" <<'JSONL'
{"type":"start","run_id":"r-run","units":["u1"]}
{"type":"progress","unit":"u1"}
{"type":"done","status":"completed"}
JSONL

set +e
out_r="$(run_collect_attempts "$dir_r" deep-review r-run "logic:u1" "security:2" 2>"$dir_r/stderr")"
r_exit=$?
set -e
if [[ $r_exit -eq 0 ]] && printf '%s' "$out_r" | jq -e '.logic.status == "completed" and (has("security") | not)' >/dev/null 2>&1; then
	pass "(r) --attempts for a lens not in --expected is ignored, exit 0"
else
	fail "(r) --attempts for an un-expected lens should be ignored (exit=$r_exit)"
	echo "    stdout: $out_r"
	sed 's/^/    /' "$dir_r/stderr" 2>/dev/null
fi

# ---------------------------------------------------------------------------
# (s) F1 -- lens-name interpolation: an on-disk file for a DIFFERENT lens
#     whose name is a prefix/superstring of the requested lens must not be
#     picked up (exact basename-component match, not a glob match), and a
#     glob-metacharacter --expected lens key is rejected outright.
# ---------------------------------------------------------------------------

dir_s="$TMPDIR_ROOT/case-s"
make_scratch_repo "$dir_s"
write_lens_file "$(lens_file "$dir_s" deep-review s-run logicX 1)" <<'JSONL'
{"type":"start","run_id":"s-run","units":["ux1"]}
{"type":"done","status":"completed"}
JSONL
write_lens_file "$(lens_file "$dir_s" deep-review s-run logic 1)" <<'JSONL'
{"type":"start","run_id":"s-run","units":["u1"]}
{"type":"progress","unit":"u1"}
{"type":"done","status":"completed"}
JSONL

out_s="$(run_collect "$dir_s" deep-review s-run "logic:u1" 2>"$dir_s/stderr" || true)"
if printf '%s' "$out_s" | jq -e '.logic.status == "completed" and .logic.reviewed == 1 and .logic.assigned == 1' >/dev/null 2>&1; then
	pass "(s1) lens-name interpolation: only logic.1.jsonl is read, logicX.1.jsonl is excluded"
else
	fail "(s1) lens-name interpolation: exact match should exclude logicX's attempt file"
	echo "    stdout: $out_s"
fi

set +e
out_s2="$(cd "$dir_s" && bash "$SCRIPT" --skill deep-review --run-id s-run --expected 'lo*c:u1' 2>"$dir_s/stderr2")"
s2_exit=$?
set -e
if [[ $s2_exit -eq 2 ]]; then
	pass "(s2) --expected 'lo*c:u1' (glob metachar in lens key) -> exit 2"
else
	fail "(s2) --expected 'lo*c:u1' should be rejected with exit 2 (got $s2_exit)"
	sed 's/^/    /' "$dir_s/stderr2" 2>/dev/null
fi

# ---------------------------------------------------------------------------
# (t) F1 -- symlinked run dir is refused (exit 2), not silently followed
# ---------------------------------------------------------------------------

if [[ "$(id -u)" -eq 0 ]]; then
	echo "SKIP: (t) symlinked run dir refused (running as root)"
else
	dir_t="$TMPDIR_ROOT/case-t"
	make_scratch_repo "$dir_t"
	outside_t="$TMPDIR_ROOT/case-t-outside"
	mkdir -p "$outside_t"
	write_lens_file "$outside_t/logic.1.jsonl" <<'JSONL'
{"type":"start","run_id":"t-run","units":["u1"]}
{"type":"done","status":"completed"}
JSONL
	mkdir -p "$dir_t/.deep-review/lenses"
	ln -s "$outside_t" "$dir_t/.deep-review/lenses/t-run"

	set +e
	out_t="$(run_collect "$dir_t" deep-review t-run "logic:u1" 2>"$dir_t/stderr")"
	t_exit=$?
	set -e

	if [[ $t_exit -eq 2 ]]; then
		pass "(t) symlinked run dir refused, exit 2"
	else
		fail "(t) symlinked run dir should be refused with exit 2 (got $t_exit)"
		echo "    stdout: $out_t"
		sed 's/^/    /' "$dir_t/stderr" 2>/dev/null
	fi
fi

# ---------------------------------------------------------------------------
# (u) D-7/C3 -- --findings-jsonl: one JSON object per line, correct
#     lens/file/line split (including a "last colon" location and an
#     empty-evidence/suggestion default), findings from a partial/timed_out
#     lens included, deterministic --expected order.
# ---------------------------------------------------------------------------

dir_u="$TMPDIR_ROOT/case-u"
make_scratch_repo "$dir_u"
write_lens_file "$(lens_file "$dir_u" deep-review u-run logic 1)" <<'JSONL'
{"type":"start","run_id":"u-run","units":["u1","u2"]}
{"type":"progress","unit":"u1"}
{"type":"finding","severity":"Critical","category":"bug","location":"foo.py:10","summary":"first finding"}
JSONL
write_lens_file "$(lens_file "$dir_u" deep-review u-run security 1)" <<'JSONL'
{"type":"start","run_id":"u-run","units":["u1"]}
{"type":"progress","unit":"u1"}
{"type":"finding","severity":"Important","category":"style","location":"C:\\x\\a:b:12","summary":"windows-ish colon location","evidence":"ev","suggestion":"sg"}
{"type":"done","status":"completed"}
JSONL

out_u="$(run_collect_jsonl "$dir_u" deep-review u-run "logic:u1,u2" "security:u1" 2>"$dir_u/stderr" || true)"
line_count_u="$(printf '%s\n' "$out_u" | grep -c . || true)"

if [[ "$line_count_u" != "2" ]]; then
	fail "(u1) --findings-jsonl emits one line per finding across all reported lenses (expected 2 lines, got $line_count_u)"
	echo "    stdout: $out_u"
else
	pass "(u1) --findings-jsonl emits one JSON-Lines object per finding (2 lines)"
fi

if printf '%s\n' "$out_u" | jq -e -c 'select(.lens == "logic")' | jq -e '.file == "foo.py" and .line == "10" and .summary == "first finding" and .evidence == "" and .suggestion == ""' >/dev/null 2>&1; then
	pass "(u2) --findings-jsonl: logic finding has file/line split from location, empty defaults for absent evidence/suggestion"
else
	fail "(u2) --findings-jsonl: logic finding shape incorrect"
	echo "    stdout: $out_u"
fi

if printf '%s\n' "$out_u" | jq -e -c 'select(.lens == "security")' | jq -e '.file == "C:\\x\\a:b" and .line == "12" and .evidence == "ev" and .suggestion == "sg"' >/dev/null 2>&1; then
	pass "(u3) --findings-jsonl: location split on the LAST colon (C:\\x\\a:b:12 -> file=C:\\x\\a:b, line=12), findings from a completed lens included too"
else
	fail "(u3) --findings-jsonl: last-colon split incorrect for a multi-colon location"
	echo "    stdout: $out_u"
fi

# A partial/timed_out lens's on-disk findings must still be emitted.
dir_u2="$TMPDIR_ROOT/case-u2"
make_scratch_repo "$dir_u2"
write_lens_file "$(lens_file "$dir_u2" deep-review u2-run architecture 1)" <<'JSONL'
{"type":"start","run_id":"u2-run","units":["u1","u2"]}
{"type":"progress","unit":"u1"}
{"type":"finding","severity":"Minor","category":"style","location":"bar.py:5","summary":"finding from a partial lens"}
JSONL
out_u2="$(run_collect_jsonl "$dir_u2" deep-review u2-run "architecture:u1,u2" 2>"$dir_u2/stderr" || true)"
if printf '%s\n' "$out_u2" | jq -e -c 'select(.lens == "architecture")' | jq -e '.file == "bar.py" and .line == "5"' >/dev/null 2>&1; then
	pass "(u4) --findings-jsonl includes findings from a partial/timed_out lens, not just terminal ones"
else
	fail "(u4) --findings-jsonl should include a partial lens's on-disk findings"
	echo "    stdout: $out_u2"
fi

# Empty input (no findings at all across any expected lens) -> zero lines, exit 0.
dir_u3="$TMPDIR_ROOT/case-u3"
make_scratch_repo "$dir_u3"
set +e
out_u3="$(run_collect_jsonl "$dir_u3" deep-review u3-run "logic:u1" 2>"$dir_u3/stderr")"
u3_exit=$?
set -e
if [[ $u3_exit -eq 0 && -z "$out_u3" ]]; then
	pass "(u5) --findings-jsonl with no findings anywhere -> zero lines, exit 0"
else
	fail "(u5) --findings-jsonl with no findings should be zero lines, exit 0 (exit=$u3_exit, output='$out_u3')"
fi

# ---------------------------------------------------------------------------
# (v) F8 -- portability: mapfile (bash 4+) must not appear anywhere in
#     scripts/ -- the repo floor is macOS bash 3.2.
# ---------------------------------------------------------------------------

if grep -rn 'mapfile' "$REPO_ROOT/scripts" 2>/dev/null | grep -q .; then
	fail "(v) no 'mapfile' anywhere in scripts/ (bash 3.2 portability)"
	grep -rn 'mapfile' "$REPO_ROOT/scripts" 2>/dev/null | sed 's/^/    /'
else
	pass "(v) no 'mapfile' anywhere in scripts/ (bash 3.2 portability)"
fi

# ---------------------------------------------------------------------------
# (w) C3 close-out -- collect-lens-results.sh --findings-jsonl piped into
#     reconcile-findings.sh end to end: reconciler exits 0, emits
#     schema_version 2, findings attributed to the right lenses.
# ---------------------------------------------------------------------------

RECONCILE="$REPO_ROOT/scripts/reconcile-findings.sh"
if [[ ! -x "$RECONCILE" ]]; then
	fail "(w) preflight (scripts/reconcile-findings.sh not found/executable at $RECONCILE)"
else
	dir_w="$TMPDIR_ROOT/case-w"
	make_scratch_repo "$dir_w"
	write_lens_file "$(lens_file "$dir_w" deep-review w-run logic 1)" <<'JSONL'
{"type":"start","run_id":"w-run","units":["u1"]}
{"type":"progress","unit":"u1"}
{"type":"finding","severity":"Critical","category":"bug","location":"foo.py:10","summary":"logic sees a bug"}
{"type":"done","status":"completed"}
JSONL
	write_lens_file "$(lens_file "$dir_w" deep-review w-run security 1)" <<'JSONL'
{"type":"start","run_id":"w-run","units":["u1"]}
{"type":"progress","unit":"u1"}
{"type":"finding","severity":"Important","category":"vuln","location":"baz.py:20","summary":"security sees a vuln"}
{"type":"done","status":"completed"}
JSONL

	set +e
	reconciled_w="$(
		cd "$dir_w" && bash "$SCRIPT" --skill deep-review --run-id w-run \
			--expected "logic:u1" --expected "security:u1" --findings-jsonl \
			| bash "$RECONCILE" --skill deep-review
	)"
	w_exit=$?
	set -e

	if [[ $w_exit -ne 0 ]]; then
		fail "(w) collect --findings-jsonl | reconcile-findings.sh exits 0 (got $w_exit)"
	elif printf '%s' "$reconciled_w" | jq -e '
			.schema_version == 2
			and (.findings | length) == 2
			and ([.findings[] | select(.file == "foo.py") | .lenses] | flatten | index("logic") != null)
			and ([.findings[] | select(.file == "baz.py") | .lenses] | flatten | index("security") != null)
		' >/dev/null 2>&1; then
		pass "(w) collect-lens-results.sh --findings-jsonl | reconcile-findings.sh: schema_version 2, findings attributed to the right lenses"
	else
		fail "(w) collect --findings-jsonl | reconcile-findings.sh: unexpected shape"
		echo "    reconciled: $reconciled_w"
	fi
fi

# ---------------------------------------------------------------------------
# (x) G4/G5/G12c -- status derivation, empty-array expansion, --root guard
# ---------------------------------------------------------------------------

# --- (x1) G4 finding 7: status comes from the LATEST attempt, not from
#     "last non-null across all attempts". A completed attempt 1 must not
#     mask a start-only attempt 2.

x1_dir="$TMPDIR_ROOT/x1"
make_scratch_repo "$x1_dir"
write_lens_file "$(lens_file "$x1_dir" deep-review x-run logic 1)" <<'EOF'
{"type":"start","run_id":"x-run","lens":"logic","attempt":1,"ts":1,"units":["u1","u2"]}
{"type":"progress","run_id":"x-run","lens":"logic","attempt":1,"ts":2,"unit":"u1"}
{"type":"done","run_id":"x-run","lens":"logic","attempt":1,"ts":3,"status":"completed"}
EOF
write_lens_file "$(lens_file "$x1_dir" deep-review x-run logic 2)" <<'EOF'
{"type":"start","run_id":"x-run","lens":"logic","attempt":2,"ts":4,"units":["u2"]}
EOF

x1_out="$(cd "$x1_dir" && bash "$SCRIPT" --skill deep-review --run-id x-run \
	--expected "logic:u1,u2" --attempts "logic:2")"
x1_status="$(printf '%s' "$x1_out" | jq -r '.logic.status')"
if [[ "$x1_status" == "timed_out" ]]; then
	pass "(x1) G4: a start-only attempt 2 is not masked by attempt 1's done line (status=timed_out)"
else
	fail "(x1) G4: expected timed_out from the latest attempt, got '$x1_status'"
fi

# Earlier attempts' findings/progress must still merge -- disk-first recovery
# is the whole point; only STATUS is latest-attempt-scoped.
x1_reviewed="$(printf '%s' "$x1_out" | jq -r '.logic.reviewed')"
if [[ "$x1_reviewed" == "1" ]]; then
	pass "(x1b) G4: attempt 1's progress still merges into reviewed (=1)"
else
	fail "(x1b) G4: attempt-1 progress must still merge (reviewed='$x1_reviewed')"
fi

# --- (x2) G4 finding 12: --running <lens>:<n> means "still in flight", so
#     the collector must not report a terminal timed_out for it.

x2_status="$(cd "$x1_dir" && bash "$SCRIPT" --skill deep-review --run-id x-run \
	--expected "logic:u1,u2" --attempts "logic:2" --running "logic:2" |
	jq -r '.logic.status')"
if [[ "$x2_status" == "partial" ]]; then
	pass "(x2) G4: --running logic:2 downgrades timed_out to partial"
else
	fail "(x2) G4: --running logic:2 must yield partial, got '$x2_status'"
fi

# --- (x3) G4: on --continue, attempt files 1 and 2 exist and attempt 3 is
#     in flight. `effective` must come from --attempts, never from
#     max(index, count), and --running must keep it non-terminal.

x3_dir="$TMPDIR_ROOT/x3"
make_scratch_repo "$x3_dir"
write_lens_file "$(lens_file "$x3_dir" deep-review x3-run logic 1)" <<'EOF'
{"type":"start","run_id":"x3-run","lens":"logic","attempt":1,"ts":1,"units":["u1","u2"]}
EOF
write_lens_file "$(lens_file "$x3_dir" deep-review x3-run logic 2)" <<'EOF'
{"type":"start","run_id":"x3-run","lens":"logic","attempt":2,"ts":2,"units":["u1","u2"]}
EOF

x3_status="$(cd "$x3_dir" && bash "$SCRIPT" --skill deep-review --run-id x3-run \
	--expected "logic:u1,u2" --attempts "logic:3" --running "logic:3" |
	jq -r '.logic.status')"
if [[ "$x3_status" == "partial" ]]; then
	pass "(x3) G4: a healthy in-flight attempt 3 reports partial, not terminal timed_out"
else
	fail "(x3) G4: in-flight attempt 3 must report partial, got '$x3_status'"
fi

# Without --running, the same fixture is terminal.
x3_term="$(cd "$x3_dir" && bash "$SCRIPT" --skill deep-review --run-id x3-run \
	--expected "logic:u1,u2" --attempts "logic:3" | jq -r '.logic.status')"
if [[ "$x3_term" == "timed_out" ]]; then
	pass "(x3b) G4: without --running the same fixture is terminal (timed_out)"
else
	fail "(x3b) G4: without --running expected timed_out, got '$x3_term'"
fi

# --- (x4) G4: the `missing` shortcut must survive the `max` removal --
#     --attempts logic:2 with zero files on disk is still not `missing`.

x4_dir="$TMPDIR_ROOT/x4"
make_scratch_repo "$x4_dir"
mkdir -p "$x4_dir/.deep-review/lenses/x4-run"
x4_status="$(cd "$x4_dir" && bash "$SCRIPT" --skill deep-review --run-id x4-run \
	--expected "logic:u1,u2" --attempts "logic:2" | jq -r '.logic.status')"
if [[ "$x4_status" == "timed_out" ]]; then
	pass "(x4) G4: spawned-but-fileless attempt 2 is timed_out, not missing"
else
	fail "(x4) G4: spawned-but-fileless attempt 2 expected timed_out, got '$x4_status'"
fi

# A lens with neither files nor an --attempts entry is still `missing`.
x4_missing="$(cd "$x4_dir" && bash "$SCRIPT" --skill deep-review --run-id x4-run \
	--expected "logic:u1,u2" | jq -r '.logic.status')"
if [[ "$x4_missing" == "missing" ]]; then
	pass "(x4b) G4: no files and no --attempts entry is still missing"
else
	fail "(x4b) G4: expected missing, got '$x4_missing'"
fi

# --- (x5) G5 finding 11: files==0 && effective>=2 must not expand an empty
#     array under `set -u` (bash 3.2 aborts with no JSON on stdout).

set +e
x5_out="$(cd "$x4_dir" && /bin/bash "$SCRIPT" --skill deep-review --run-id x4-run \
	--expected "logic:u1,u2" --attempts "logic:2" 2>"$TMPDIR_ROOT/x5.err")"
x5_exit=$?
set -e
if [[ $x5_exit -eq 0 ]] && printf '%s' "$x5_out" | jq -e '.logic.status == "timed_out"' >/dev/null 2>&1; then
	pass "(x5) G5: zero attempt files with --attempts logic:2 emits valid JSON under /bin/bash, exit 0"
else
	fail "(x5) G5: empty-array expansion under set -u (exit=$x5_exit, stdout='$x5_out')"
	sed 's/^/    /' "$TMPDIR_ROOT/x5.err"
fi

# --- (x6) G12c finding 19: --root omitted AND cwd outside a git worktree
#     is a refusal, not a silent read of a different directory than the
#     writer wrote to.

x6_dir="$TMPDIR_ROOT/x6-not-a-repo"
mkdir -p "$x6_dir"
set +e
x6_out="$(cd "$x6_dir" && bash "$SCRIPT" --skill deep-review --run-id x6-run \
	--expected "logic:u1" 2>"$TMPDIR_ROOT/x6.err")"
x6_exit=$?
set -e
if [[ $x6_exit -eq 2 && -z "$x6_out" ]]; then
	pass "(x6) G12c: --root omitted outside a git worktree exits 2 with empty stdout"
else
	fail "(x6) G12c: expected exit 2 + empty stdout (exit=$x6_exit, stdout='$x6_out')"
	sed 's/^/    /' "$TMPDIR_ROOT/x6.err"
fi

# An explicit --root from the same non-worktree cwd still works.
mkdir -p "$x6_dir/state/.deep-review/lenses/x6-run"
x6_root_status="$(cd "$x6_dir" && bash "$SCRIPT" --root "$x6_dir/state" \
	--skill deep-review --run-id x6-run --expected "logic:u1" | jq -r '.logic.status')"
if [[ "$x6_root_status" == "missing" ]]; then
	pass "(x6b) G12c: an explicit --root outside a git worktree still works"
else
	fail "(x6b) G12c: explicit --root outside a worktree failed (status='$x6_root_status')"
fi


# ---------------------------------------------------------------------------
# (C5) attempt-merge dedup must not fold path case.
#
# r2 finding #5: the dedup key was
# `($file|ascii_downcase) + "|" + $line + "|" + $cat`. Lowercasing the FILE
# is exactly the decision `finding-key.sh` rejects in writing (paths are
# case-sensitive on the filesystems this runs on; the reconciler folds no
# case at all), so the collector carried a THIRD, contradictory
# finding-identity policy. Consequence inside its own scope: one lens
# reporting `Foo.md:10` and `foo.md:10` in one category silently lost a
# finding before reconciliation ever saw it.
#
# Invariant: dedup identity matches finding-key.sh verbatim -- `file` is
# compared case-SENSITIVELY, `category` case-INSENSITIVELY.
# ---------------------------------------------------------------------------

c5_root="$TMPDIR_ROOT/case-c5"
c5_dir="$c5_root/.deep-review/lenses/c5-run"
mkdir -p "$c5_dir"
{
	printf '%s\n' '{"type":"start","run_id":"c5-run","lens":"logic","attempt":1,"ts":1,"units":["u1"]}'
	printf '%s\n' '{"type":"progress","run_id":"c5-run","lens":"logic","attempt":1,"ts":2,"unit":"u1"}'
	printf '%s\n' '{"type":"finding","run_id":"c5-run","lens":"logic","attempt":1,"ts":3,"severity":"Minor","category":"Logic","location":"Foo.md:10","summary":"upper","evidence":"","suggestion":""}'
	printf '%s\n' '{"type":"finding","run_id":"c5-run","lens":"logic","attempt":1,"ts":4,"severity":"Minor","category":"Logic","location":"foo.md:10","summary":"lower","evidence":"","suggestion":""}'
	printf '%s\n' '{"type":"done","run_id":"c5-run","lens":"logic","attempt":1,"ts":5,"status":"completed"}'
} >"$c5_dir/logic.1.jsonl"

c5_out="$(bash "$SCRIPT" --root "$c5_root" --skill deep-review --run-id c5-run \
	--expected "logic:u1" 2>"$TMPDIR_ROOT/c5.err")"
c5_count="$(printf '%s' "$c5_out" | jq -r '.logic.findings | length')"
if [[ "$c5_count" == "2" ]]; then
	pass "(C5) Foo.md:10 and foo.md:10 are two findings -- dedup does not fold path case"
else
	fail "(C5) case-only path difference was deduped away (findings=$c5_count, expected 2)"
	sed 's/^/    /' "$TMPDIR_ROOT/c5.err"
fi

# Control: category case IS folded (finding-key.sh's documented split), so a
# same-path/same-line pair differing only in category case stays ONE finding.
c5b_root="$TMPDIR_ROOT/case-c5b"
c5b_dir="$c5b_root/.deep-review/lenses/c5-run"
mkdir -p "$c5b_dir"
{
	printf '%s\n' '{"type":"start","run_id":"c5-run","lens":"logic","attempt":1,"ts":1,"units":["u1"]}'
	printf '%s\n' '{"type":"finding","run_id":"c5-run","lens":"logic","attempt":1,"ts":3,"severity":"Minor","category":"Logic","location":"foo.md:10","summary":"a","evidence":"","suggestion":""}'
	printf '%s\n' '{"type":"finding","run_id":"c5-run","lens":"logic","attempt":1,"ts":4,"severity":"Minor","category":"logic","location":"foo.md:10","summary":"b","evidence":"","suggestion":""}'
	printf '%s\n' '{"type":"done","run_id":"c5-run","lens":"logic","attempt":1,"ts":5,"status":"completed"}'
} >"$c5b_dir/logic.1.jsonl"
c5b_count="$(bash "$SCRIPT" --root "$c5b_root" --skill deep-review --run-id c5-run \
	--expected "logic:u1" 2>/dev/null | jq -r '.logic.findings | length')"
if [[ "$c5b_count" == "1" ]]; then
	pass "(C5b) control: category case IS folded, matching finding-key.sh"
else
	fail "(C5b) category case is no longer folded (findings=$c5b_count, expected 1)"
fi

# ---------------------------------------------------------------------------
# (C19) --running is a FLOOR, not an override: a recorded terminal `done`
# status wins over it.
#
# r2 finding #19: the header claimed "a lens named by --running is never
# reported terminal: its status floor is `partial`" -- absolute, and false.
# The derivation checks `done_status` FIRST and only then reaches the
# `elif $running > 0` leg, so a --running lens whose attempt file already
# carries a `done` line reports that terminal status. The BEHAVIOUR is
# right (the record on disk is evidence the attempt finished); the stated
# invariant was wrong. This case locks the real contract.
# ---------------------------------------------------------------------------

c19_root="$TMPDIR_ROOT/case-c19"
c19_dir="$c19_root/.deep-review/lenses/c19-run"
mkdir -p "$c19_dir"
{
	printf '%s\n' '{"type":"start","run_id":"c19-run","lens":"logic","attempt":2,"ts":1,"units":["u1"]}'
	printf '%s\n' '{"type":"progress","run_id":"c19-run","lens":"logic","attempt":2,"ts":2,"unit":"u1"}'
	printf '%s\n' '{"type":"done","run_id":"c19-run","lens":"logic","attempt":2,"ts":3,"status":"completed"}'
} >"$c19_dir/logic.2.jsonl"

c19_status="$(bash "$SCRIPT" --root "$c19_root" --skill deep-review --run-id c19-run \
	--expected "logic:u1" --running "logic:2" 2>/dev/null | jq -r '.logic.status')"
if [[ "$c19_status" == "completed" ]]; then
	pass "(C19) --running logic:2 with a recorded done/completed reports completed, not partial"
else
	fail "(C19) --running did not defer to the recorded terminal status (status='$c19_status')"
fi

# Control: the same --running declaration with NO done line still floors at
# partial (the reason --running exists).
c19b_root="$TMPDIR_ROOT/case-c19b"
c19b_dir="$c19b_root/.deep-review/lenses/c19-run"
mkdir -p "$c19b_dir"
{
	printf '%s\n' '{"type":"start","run_id":"c19-run","lens":"logic","attempt":2,"ts":1,"units":["u1"]}'
} >"$c19b_dir/logic.2.jsonl"
c19b_status="$(bash "$SCRIPT" --root "$c19b_root" --skill deep-review --run-id c19-run \
	--expected "logic:u1" --running "logic:2" 2>/dev/null | jq -r '.logic.status')"
if [[ "$c19b_status" == "partial" ]]; then
	pass "(C19b) control: --running with no done line still floors at partial"
else
	fail "(C19b) --running floor broke (status='$c19b_status', expected partial)"
fi

# ---------------------------------------------------------------------------
# (C19c) The header prose must state the RECONCILED rule (A8), not an
# absolute floor and not an unqualified "a done line always wins".
# ---------------------------------------------------------------------------
if grep -q 'is never reported terminal' "$SCRIPT"; then
	fail "(C19c) collect-lens-results.sh still claims a --running lens 'is never reported terminal'"
elif grep -q 'only when its attempt is >= the running attempt' "$SCRIPT"; then
	pass "(C19c) the --running header states the attempt-ordered exception to the partial floor"
else
	fail "(C19c) the --running header does not state the attempt-ordered exception"
fi

# ---------------------------------------------------------------------------
# (A8) A STALE terminal status must not beat a LIVE retry.
#
# Codex addendum A8: the merge takes done_status from the latest attempt
# FILE PRESENT, not the latest attempt SPAWNED, and the status ladder tests
# it before the `elif $running > 0` leg. So attempt 1 finishing `completed`
# and attempt 2 being spawned-but-silent reported `completed`, retiring a
# lens whose retry had not returned. This does NOT contradict (C19): there,
# the done line belongs to the RUNNING attempt itself. Reconciled rule: a
# terminal status wins over --running only when its attempt >= the running
# attempt number; otherwise the `partial` floor applies.
# ---------------------------------------------------------------------------

a8_root="$TMPDIR_ROOT/case-a8"
a8_dir="$a8_root/.deep-review/lenses/a8-run"
mkdir -p "$a8_dir"
{
	printf '%s\n' '{"type":"start","run_id":"a8-run","lens":"logic","attempt":1,"ts":1,"units":["u1"]}'
	printf '%s\n' '{"type":"progress","run_id":"a8-run","lens":"logic","attempt":1,"ts":2,"unit":"u1"}'
	printf '%s\n' '{"type":"done","run_id":"a8-run","lens":"logic","attempt":1,"ts":3,"status":"completed"}'
} >"$a8_dir/logic.1.jsonl"

a8_status="$(bash "$SCRIPT" --root "$a8_root" --skill deep-review --run-id a8-run \
	--expected "logic:u1" --attempts "logic:2" --running "logic:2" 2>/dev/null | jq -r '.logic.status')"
if [[ "$a8_status" == "partial" ]]; then
	pass "(A8) attempt 1 completed + attempt 2 spawned-and-silent reports partial, not completed"
else
	fail "(A8) a stale attempt-1 terminal status beat the live attempt-2 retry (status='$a8_status')"
fi

# (A8b) The same stale done line with NO --running still reports the
# terminal status -- the guard keys on the running attempt, not on the mere
# existence of a later attempt index.
a8b_status="$(bash "$SCRIPT" --root "$a8_root" --skill deep-review --run-id a8-run \
	--expected "logic:u1" 2>/dev/null | jq -r '.logic.status')"
if [[ "$a8b_status" == "completed" ]]; then
	pass "(A8b) control: with no --running, the recorded terminal status still wins"
else
	fail "(A8b) the A8 guard fired without --running (status='$a8b_status', expected completed)"
fi

# ---------------------------------------------------------------------------
# (A4) `effective` is an attempt INDEX, not a file COUNT.
#
# Codex addendum A4, step 3: `effective="$files"` used the NUMBER of attempt
# files, so `logic.1` + `logic.3` (attempt 2 crashed before writing a byte)
# gave effective 2 and the ladder read it as "one respawn happened". With
# three attempts on the clock and no done line, the honest status is
# `timed_out`; the count only reaches 3 if every attempt file exists.
# ---------------------------------------------------------------------------

# A LONE `logic.2.jsonl` (attempt 1 crashed before writing a byte) is the
# discriminating shape: the file COUNT is 1 -> `partial`, while the max
# attempt INDEX is 2 -> `timed_out`, which is the honest answer since a
# respawn demonstrably happened.
a4_root="$TMPDIR_ROOT/case-a4"
a4_dir="$a4_root/.deep-review/lenses/a4-run"
mkdir -p "$a4_dir"
printf '%s\n' '{"type":"start","run_id":"a4-run","lens":"logic","attempt":2,"ts":2,"units":["u1"]}' >"$a4_dir/logic.2.jsonl"

a4_status="$(bash "$SCRIPT" --root "$a4_root" --skill deep-review --run-id a4-run \
	--expected "logic:u1" 2>/dev/null | jq -r '.logic.status')"
if [[ "$a4_status" == "timed_out" ]]; then
	pass "(A4) a lone attempt-2 file derives effective 2 from the max INDEX -> timed_out"
else
	fail "(A4) effective was derived from the file COUNT, not the max index (status='$a4_status', expected timed_out)"
fi

# Control: a single attempt-1 file with no done line is still `partial` --
# the max index is 1, so nothing was ever respawned.
a4b_root="$TMPDIR_ROOT/case-a4b"
a4b_dir="$a4b_root/.deep-review/lenses/a4-run"
mkdir -p "$a4b_dir"
printf '%s\n' '{"type":"start","run_id":"a4-run","lens":"logic","attempt":1,"ts":1,"units":["u1"]}' >"$a4b_dir/logic.1.jsonl"
a4b_status="$(bash "$SCRIPT" --root "$a4b_root" --skill deep-review --run-id a4-run \
	--expected "logic:u1" 2>/dev/null | jq -r '.logic.status')"
if [[ "$a4b_status" == "partial" ]]; then
	pass "(A4b) control: a lone attempt-1 file is still partial (max index 1)"
else
	fail "(A4b) the A4 change altered the single-attempt baseline (status='$a4b_status', expected partial)"
fi

# ---------------------------------------------------------------------------
# (A3) Salvage semantics: a salvaged `done` is only believed when it is
# written to the attempt whose reply is being salvaged.
#
# Codex addendum A3. The SKILL.md mirrors used to hardwire salvage to
# `--attempt 1`. Applied to attempt 2's return that is either a no-op or --
# when attempt 2 is fileless -- reports `completed` while the retry is still
# unresolved. These two cases lock the collector semantics the corrected
# prose depends on.
# ---------------------------------------------------------------------------

a3_mk() {
	local root="$1"
	mkdir -p "$root/.deep-review/lenses/a3-run"
	printf '%s\n' '{"type":"start","run_id":"a3-run","lens":"logic","attempt":1,"ts":1,"units":["u1"]}' \
		'{"type":"progress","run_id":"a3-run","lens":"logic","attempt":1,"ts":2,"unit":"u1"}' \
		>"$root/.deep-review/lenses/a3-run/logic.1.jsonl"
}

# Salvaged into attempt 1 while attempt 2 is the declared in-flight retry.
a3a_root="$TMPDIR_ROOT/case-a3a"
a3_mk "$a3a_root"
printf '%s\n' '{"type":"done","run_id":"a3-run","lens":"logic","attempt":1,"ts":3,"status":"completed"}' \
	>>"$a3a_root/.deep-review/lenses/a3-run/logic.1.jsonl"
a3a_status="$(bash "$SCRIPT" --root "$a3a_root" --skill deep-review --run-id a3-run \
	--expected "logic:u1" --attempts "logic:2" --running "logic:2" 2>/dev/null | jq -r '.logic.status')"
if [[ "$a3a_status" == "partial" ]]; then
	pass "(A3) a done salvaged into attempt 1 does not retire an in-flight attempt 2 (partial)"
else
	fail "(A3) salvaging into the wrong attempt retired the lens (status='$a3a_status', expected partial)"
fi

# Salvaged into attempt 2 -- the attempt whose reply is actually being salvaged.
a3b_root="$TMPDIR_ROOT/case-a3b"
a3_mk "$a3b_root"
printf '%s\n' '{"type":"done","run_id":"a3-run","lens":"logic","attempt":2,"ts":3,"status":"completed"}' \
	>"$a3b_root/.deep-review/lenses/a3-run/logic.2.jsonl"
a3b_status="$(bash "$SCRIPT" --root "$a3b_root" --skill deep-review --run-id a3-run \
	--expected "logic:u1" --attempts "logic:2" --running "logic:2" 2>/dev/null | jq -r '.logic.status')"
if [[ "$a3b_status" == "completed" ]]; then
	pass "(A3b) a done salvaged into attempt 2 is believed and reports completed"
else
	fail "(A3b) salvaging into the correct attempt was not believed (status='$a3b_status', expected completed)"
fi

# ---------------------------------------------------------------------------
# (A2) A respawned attempt must be declared BOTH spawned and running.
# --attempts alone declares the retry exhausted while it is still in flight.
# ---------------------------------------------------------------------------
a2_root="$TMPDIR_ROOT/case-a2"
a3_mk "$a2_root"
mv "$a2_root/.deep-review/lenses/a3-run" "$a2_root/.deep-review/lenses/a2-run"
a2_attempts_only="$(bash "$SCRIPT" --root "$a2_root" --skill deep-review --run-id a2-run \
	--expected "logic:u1" --attempts "logic:2" 2>/dev/null | jq -r '.logic.status')"
a2_both="$(bash "$SCRIPT" --root "$a2_root" --skill deep-review --run-id a2-run \
	--expected "logic:u1" --attempts "logic:2" --running "logic:2" 2>/dev/null | jq -r '.logic.status')"
if [[ "$a2_attempts_only" == "timed_out" && "$a2_both" == "partial" ]]; then
	pass "(A2) --attempts alone reports timed_out; adding --running reports partial"
else
	fail "(A2) attempts-only='$a2_attempts_only' (expected timed_out), both='$a2_both' (expected partial)"
fi

# ---------------------------------------------------------------------------
# (G2) The --running floor applies at attempt 1 with ZERO files on disk.
# The `missing` shortcut (files==0 && effective<=1) sits ABOVE the jq status
# ladder that r2 taught about --running, so the floor held at attempt 2 and
# broke at attempt 1: `--attempts logic:1 --running logic:1` on an empty run
# dir reported `missing`, while `--attempts logic:2 --running logic:2`
# reported `partial`. `missing` is what makes --continue treat a lens as
# never-spawned and reassign it from scratch, discarding a healthy in-flight
# attempt 1. The header and the status table both call the floor
# unconditional; this asserts it is.
# ---------------------------------------------------------------------------
g2_root="$TMPDIR_ROOT/case-g2"
mkdir -p "$g2_root/.deep-review/lenses/g2-run"
g2_out="$(bash "$SCRIPT" --root "$g2_root" --skill deep-review --run-id g2-run \
	--expected "logic:u1,u2" --attempts "logic:1" --running "logic:1" 2>/dev/null || true)"
g2_status="$(printf '%s' "$g2_out" | jq -r '.logic.status')"
g2_unreviewed="$(printf '%s' "$g2_out" | jq -c '.logic.unreviewed')"
if [[ "$g2_status" == "partial" ]]; then
	pass "(G2) running floor applies at attempt 1 with zero files: status is partial, not missing"
else
	fail "(G2) running floor broke at attempt 1 with zero files (status='$g2_status', expected partial)"
fi
if [[ "$g2_unreviewed" == '["u1","u2"]' ]]; then
	pass "(G2) the zero-coverage partial still reports the full --expected unit list as unreviewed"
else
	fail "(G2) zero-coverage unreviewed='$g2_unreviewed' (expected [\"u1\",\"u2\"])"
fi

# Control: WITHOUT --running the same zero-file fixture is still `missing`.
g2b_status="$(bash "$SCRIPT" --root "$g2_root" --skill deep-review --run-id g2-run \
	--expected "logic:u1,u2" --attempts "logic:1" 2>/dev/null | jq -r '.logic.status')"
if [[ "$g2b_status" == "missing" ]]; then
	pass "(G2b) control: without --running the same zero-file fixture is still missing"
else
	fail "(G2b) control broke: expected missing without --running, got '$g2b_status'"
fi

# Parity: the floor must not depend on the attempt index. Attempt 1 and
# attempt 2 with zero files on disk must agree once --running names the lens.
g2c_status="$(bash "$SCRIPT" --root "$g2_root" --skill deep-review --run-id g2-run \
	--expected "logic:u1,u2" --attempts "logic:2" --running "logic:2" 2>/dev/null | jq -r '.logic.status')"
if [[ "$g2c_status" == "$g2_status" ]]; then
	pass "(G2c) the running floor is attempt-index independent (attempt 1 and 2 both report '$g2_status')"
else
	fail "(G2c) attempt 1 reported '$g2_status' but attempt 2 reported '$g2c_status'"
fi

# ---------------------------------------------------------------------------
# (G4) Diff-derived unit lists must not travel on the command line.
#
# `--expected "logic:src/$(id).ts"` is substituted by the ORCHESTRATOR'S
# shell before this script is entered, so no in-script whitelist can see the
# pre-substitution text; quoting stops splitting and globbing but not
# substitution. The fix is a transport change (--expected-file, written with
# a file-write tool) plus a defence-in-depth blacklist on anything that does
# reach argv.
# ---------------------------------------------------------------------------
g4_root="$TMPDIR_ROOT/case-g4"
mkdir -p "$g4_root/.deep-review/lenses/g4-run"
g4_ef="$g4_root/expected.json"
printf '%s' '{"logic":["u1","u2"],"security":["s1"]}' >"$g4_ef"

g4_file_out="$(bash "$SCRIPT" --root "$g4_root" --skill deep-review --run-id g4-run \
	--expected-file "$g4_ef" 2>/dev/null || true)"
g4_argv_out="$(bash "$SCRIPT" --root "$g4_root" --skill deep-review --run-id g4-run \
	--expected "logic:u1,u2" --expected "security:s1" 2>/dev/null || true)"
if [[ -n "$g4_file_out" && "$g4_file_out" == "$g4_argv_out" ]]; then
	pass "(G4) --expected-file yields the SAME envelope as the equivalent --expected flags"
else
	fail "(G4) --expected-file envelope differs: file='$g4_file_out' argv='$g4_argv_out'"
fi

set +e
bash "$SCRIPT" --root "$g4_root" --skill deep-review --run-id g4-run \
	--expected 'logic:src/$(id).ts' >/dev/null 2>&1
g4_subst_rc=$?
set -e
if [[ "$g4_subst_rc" -eq 2 ]]; then
	pass "(G4) a command-substitution-shaped unit on --expected exits 2"
else
	fail "(G4) --expected 'logic:src/\$(id).ts' must exit 2, got rc=$g4_subst_rc"
fi

set +e
bash "$SCRIPT" --root "$g4_root" --skill deep-review --run-id g4-run \
	--expected 'logic:--not-a-unit' >/dev/null 2>&1
g4_dash_rc=$?
set -e
if [[ "$g4_dash_rc" -eq 2 ]]; then
	pass "(G4) a leading-dash unit exits 2 (it would be parsed as a flag downstream)"
else
	fail "(G4) a leading-dash unit must exit 2, got rc=$g4_dash_rc"
fi

# r4 F10 INVERSION. This used to assert "a comma-bearing unit is rejected on
# BOTH transports", on the reasoning that unit lists are comma-joined
# end-to-end. They are not, any more: the collector holds --expected-file
# units as a JSON array from jq to jq and never joins them, so the rule was
# enforcing a property of the OLD internal representation, not of a unit --
# and it hard-failed a real review-plan heading,
# `## Post-completion follow-ups (A3/A5, 2026-05-24)`. The comma restriction
# now lives only on --expected, where the comma genuinely is the separator
# (asserted in the R4-G3 group below).
printf '%s' '{"logic":["a,b"]}' >"$g4_root/comma.json"
set +e
g4_comma_out="$(bash "$SCRIPT" --root "$g4_root" --skill deep-review --run-id g4-run \
	--expected-file "$g4_root/comma.json" 2>&1)"
g4_comma_rc=$?
set -e
if [[ "$g4_comma_rc" -eq 0 ]] &&
	[[ "$(printf '%s' "$g4_comma_out" | jq -r '.logic.assigned' 2>/dev/null)" == "1" ]] &&
	[[ "$(printf '%s' "$g4_comma_out" | jq -r '.logic.unreviewed[0]' 2>/dev/null)" == "a,b" ]]; then
	pass "(G4) a comma-bearing unit inside --expected-file is ONE unit, not a usage error"
else
	fail "(G4) comma unit on --expected-file: rc=$g4_comma_rc out=$g4_comma_out"
fi

# ...but a shell metacharacter inside --expected-file is ACCEPTED: those
# units never reach a command line, and a file path or plan section may
# legitimately contain '$' or a quote. Rejecting it would be a whitelist,
# which is exactly what this deliberately is not.
printf '%s' '{"logic":["src/$weird (v2).ts"]}' >"$g4_root/meta.json"
g4_meta_units="$(bash "$SCRIPT" --root "$g4_root" --skill deep-review --run-id g4-run \
	--expected-file "$g4_root/meta.json" 2>/dev/null | jq -c '.logic.unreviewed' || true)"
if [[ "$g4_meta_units" == '["src/$weird (v2).ts"]' ]]; then
	pass "(G4) a shell metacharacter inside --expected-file is accepted verbatim (file transport never reaches a shell)"
else
	fail "(G4) --expected-file mangled or rejected a legitimate unit (got '$g4_meta_units')"
fi

set +e
bash "$SCRIPT" --root "$g4_root" --skill deep-review --run-id g4-run \
	--expected "logic:u1" --expected-file "$g4_ef" >/dev/null 2>&1
g4_both_rc=$?
set -e
if [[ "$g4_both_rc" -eq 2 ]]; then
	pass "(G4) --expected and --expected-file are mutually exclusive (exit 2)"
else
	fail "(G4) --expected + --expected-file must exit 2, got rc=$g4_both_rc"
fi

set +e
printf '%s' '{"logic":"u1"}' >"$g4_root/notarray.json"
bash "$SCRIPT" --root "$g4_root" --skill deep-review --run-id g4-run \
	--expected-file "$g4_root/notarray.json" >/dev/null 2>&1
g4_shape_rc=$?
bash "$SCRIPT" --root "$g4_root" --skill deep-review --run-id g4-run \
	--expected-file "$g4_root/nope.json" >/dev/null 2>&1
g4_missing_rc=$?
set -e
if [[ "$g4_shape_rc" -eq 2 && "$g4_missing_rc" -eq 2 ]]; then
	pass "(G4) a non-array-valued or unreadable --expected-file exits 2"
else
	fail "(G4) shape rc=$g4_shape_rc, missing-file rc=$g4_missing_rc (both must be 2)"
fi
# ---------------------------------------------------------------------------
# Group R4-G3 — A UNIT IS A STRING, NOT A CSV FIELD.
#
# One root cause behind four r4 findings (F3, F9, F10, F11): the collector
# held assigned units as a COMMA-JOINED STRING and re-split it with
# `jq -R 'split(",")'`.
#   F11 newline: `jq -R` is line-oriented, so a unit containing a newline
#        produced TWO JSON documents and --argjson aborted the collection.
#   F9  NUL: the NUL-delimited validation pass is not injective for a unit
#        that itself contains a NUL -- it silently became two units.
#   F10 comma: the no-comma rule hard-failed on a REAL review-plan heading,
#        `## Post-completion follow-ups (A3/A5, 2026-05-24)`.
#   F3  the writer never adopted the reader's validation helper.
#
# The fix keeps the unit as a JSON string end-to-end on the FILE transport.
# The comma/leading-dash/metachar restrictions survive only on ARGV, where
# they are honestly properties of that wire and not of a unit.
# ---------------------------------------------------------------------------

r4g3_root="$TMPDIR_ROOT/r4g3"
make_scratch_repo "$r4g3_root"

# r4g3_collect <units-json> [extra args...] -- write the units file OUTSIDE
# the run dir (the run-dir symlink group below owns that axis) and collect.
r4g3_collect() {
	local json="$1"
	shift
	local ef="$r4g3_root/units.json"
	printf '%s' "$json" >"$ef"
	(cd "$r4g3_root" && bash "$SCRIPT" --root "$r4g3_root" --skill deep-review \
		--run-id r4g3 --expected-file "$ef" "$@")
}

# F11: a unit containing a literal newline.
set +e
r4g3_nl_out="$(r4g3_collect "$(jq -n -c '{logic:["a\nb","c"]}')" 2>&1)"
r4g3_nl_rc=$?
set -e
r4g3_nl_first="$(printf '%s' "$r4g3_nl_out" | jq -r '.logic.unreviewed[0]' 2>/dev/null || true)"
if [[ "$r4g3_nl_rc" -eq 0 ]] &&
	[[ "$(printf '%s' "$r4g3_nl_out" | jq -r '.logic.assigned' 2>/dev/null)" == "2" ]] &&
	[[ "$r4g3_nl_first" == "$(printf 'a\nb')" ]]; then
	pass "(R4-G3/F11) a newline-bearing unit collects as ONE unit, exit 0"
else
	fail "(R4-G3/F11) newline unit: rc=$r4g3_nl_rc out=$r4g3_nl_out"
fi

# F9: a unit containing a NUL. JSON carries one as \u0000, and the old
# NUL-delimited extraction split it into two units.
set +e
r4g3_nul_out="$(r4g3_collect "$(jq -n -c '{logic:["a\u0000b","c"]}')" 2>&1)"
r4g3_nul_rc=$?
set -e
if [[ "$r4g3_nul_rc" -eq 0 ]] &&
	[[ "$(printf '%s' "$r4g3_nul_out" | jq -r '.logic.assigned' 2>/dev/null)" == "2" ]]; then
	pass "(R4-G3/F9) a NUL-bearing unit collects as ONE unit (assigned: 2, not 3)"
else
	fail "(R4-G3/F9) NUL unit: rc=$r4g3_nul_rc out=$r4g3_nul_out"
fi

# F10: a real review-plan heading with a comma in it.
r4g3_heading='Post-completion follow-ups (A3/A5, 2026-05-24)'
set +e
r4g3_comma_out="$(r4g3_collect "$(jq -n -c --arg h "$r4g3_heading" '{architecture:[$h]}')" 2>&1)"
r4g3_comma_rc=$?
set -e
if [[ "$r4g3_comma_rc" -eq 0 ]] &&
	[[ "$(printf '%s' "$r4g3_comma_out" | jq -r '.architecture.assigned' 2>/dev/null)" == "1" ]] &&
	[[ "$(printf '%s' "$r4g3_comma_out" | jq -r '.architecture.unreviewed[0]' 2>/dev/null)" == "$r4g3_heading" ]]; then
	pass "(R4-G3/F10) a comma-bearing plan heading is ONE unit on the file transport"
else
	fail "(R4-G3/F10) comma heading: rc=$r4g3_comma_rc out=$r4g3_comma_out"
fi

# Codex addendum (persist-common.sh:388): a leading `-` is an ARGV concern.
# On the file transport the value arrived as data, never at an option
# boundary, and a git path or plan heading may legally start with one.
set +e
r4g3_dash_out="$(r4g3_collect "$(jq -n -c '{logic:["-foo","bar"]}')" 2>&1)"
r4g3_dash_rc=$?
set -e
if [[ "$r4g3_dash_rc" -eq 0 ]] &&
	[[ "$(printf '%s' "$r4g3_dash_out" | jq -r '.logic.assigned' 2>/dev/null)" == "2" ]]; then
	pass "(R4-G3/addendum) a leading-dash unit is accepted on the file transport"
else
	fail "(R4-G3/addendum) leading-dash unit: rc=$r4g3_dash_rc out=$r4g3_dash_out"
fi

# ...and is still REFUSED on argv, where it would be parsed as a flag.
set +e
(cd "$r4g3_root" && bash "$SCRIPT" --root "$r4g3_root" --skill deep-review \
	--run-id r4g3 --expected 'logic:-foo' >/dev/null 2>&1)
r4g3_dash_argv_rc=$?
set -e
if [[ "$r4g3_dash_argv_rc" -eq 2 ]]; then
	pass "(R4-G3/addendum) a leading-dash unit still exits 2 on argv"
else
	fail "(R4-G3/addendum) leading-dash on argv must exit 2, got rc=$r4g3_dash_argv_rc"
fi

# ...and argv CSV still splits on commas: --expected is that wire's own
# format and keeps its own semantics.
set +e
r4g3_argv_out="$(cd "$r4g3_root" && bash "$SCRIPT" --root "$r4g3_root" \
	--skill deep-review --run-id r4g3 --expected 'logic:a,b' 2>&1)"
r4g3_argv_rc=$?
set -e
if [[ "$r4g3_argv_rc" -eq 0 ]] &&
	[[ "$(printf '%s' "$r4g3_argv_out" | jq -r '.logic.assigned' 2>/dev/null)" == "2" ]]; then
	pass "(R4-G3) --expected 'logic:a,b' still splits into 2 units on argv"
else
	fail "(R4-G3) argv CSV split regressed: rc=$r4g3_argv_rc out=$r4g3_argv_out"
fi

# Writer -> disk -> reader round-trip for a comma-bearing unit: the whole
# point of the parity fix. persist-lens-result.sh records progress on the
# unit; the collector must match it against the assigned entry byte-for-byte.
r4g3_pscript="$REPO_ROOT/scripts/persist-lens-result.sh"
jq -n -c --arg h "$r4g3_heading" '{type:"start",units:[$h]}' >"$r4g3_root/start.json"
jq -n -c --arg h "$r4g3_heading" '{type:"progress",unit:$h}' >"$r4g3_root/pay.json"
jq -n -c '{type:"done",status:"completed"}' >"$r4g3_root/done.json"
set +e
bash "$r4g3_pscript" --root "$r4g3_root" --skill review-plan --run-id r4g3rt \
	--lens architecture --attempt 1 --json-file "$r4g3_root/start.json" >/dev/null 2>&1
r4g3_w1=$?
bash "$r4g3_pscript" --root "$r4g3_root" --skill review-plan --run-id r4g3rt \
	--lens architecture --attempt 1 --json-file "$r4g3_root/pay.json" >/dev/null 2>&1
r4g3_w2=$?
bash "$r4g3_pscript" --root "$r4g3_root" --skill review-plan --run-id r4g3rt \
	--lens architecture --attempt 1 --json-file "$r4g3_root/done.json" >/dev/null 2>&1
r4g3_w3=$?
jq -n -c --arg h "$r4g3_heading" '{architecture:[$h]}' >"$r4g3_root/rt-units.json"
r4g3_rt_out="$(cd "$r4g3_root" && bash "$SCRIPT" --root "$r4g3_root" --skill review-plan \
	--run-id r4g3rt --expected-file "$r4g3_root/rt-units.json" 2>&1)"
r4g3_rt_rc=$?
set -e
if [[ "$r4g3_w1" -eq 0 && "$r4g3_w2" -eq 0 && "$r4g3_w3" -eq 0 && "$r4g3_rt_rc" -eq 0 ]] &&
	[[ "$(printf '%s' "$r4g3_rt_out" | jq -r '.architecture.reviewed' 2>/dev/null)" == "1" ]] &&
	[[ "$(printf '%s' "$r4g3_rt_out" | jq -r '.architecture.status' 2>/dev/null)" == "completed" ]]; then
	pass "(R4-G3/F3) a comma-bearing unit survives writer -> disk -> reader as ONE unit"
else
	fail "(R4-G3/F3) round-trip: w=$r4g3_w1/$r4g3_w2/$r4g3_w3 rc=$r4g3_rt_rc out=$r4g3_rt_out"
fi

# ---------------------------------------------------------------------------
# Group R4-G2 — expected.json lives in the per-run lens state dir.
#
# The prescribed path is now `persist_lens_state_dir <root> <skill>`/<run_id>/
# expected.json -- the same directory the attempt files occupy. Attempt
# discovery matches `<lens>.<attempt>.jsonl` only, so expected.json must NOT
# be picked up as an attempt file.
# ---------------------------------------------------------------------------

r4g2_root="$TMPDIR_ROOT/r4g2"
make_scratch_repo "$r4g2_root"
r4g2_run="$r4g2_root/.deep-review/lenses/r4g2"
mkdir -p "$r4g2_run"
jq -n -c '{logic:["u1","u2"]}' >"$r4g2_run/expected.json"
write_lens_file "$r4g2_run/logic.1.jsonl" <<'R4G2EOF'
{"type":"start","units":["u1","u2"]}
{"type":"progress","unit":"u1"}
{"type":"done","status":"completed"}
R4G2EOF

set +e
r4g2_out="$(cd "$r4g2_root" && bash "$SCRIPT" --root "$r4g2_root" --skill deep-review \
	--run-id r4g2 --expected-file "$r4g2_run/expected.json" 2>&1)"
r4g2_rc=$?
set -e
if [[ "$r4g2_rc" -eq 0 ]] &&
	[[ "$(printf '%s' "$r4g2_out" | jq -r '.logic.assigned' 2>/dev/null)" == "2" ]] &&
	[[ "$(printf '%s' "$r4g2_out" | jq -r '.logic.reviewed' 2>/dev/null)" == "1" ]] &&
	[[ "$(printf '%s' "$r4g2_out" | jq -r 'keys | length' 2>/dev/null)" == "1" ]]; then
	pass "(R4-G2) expected.json inside the run dir is read, and is not collected as an attempt file"
else
	fail "(R4-G2) in-run-dir expected.json: rc=$r4g2_rc out=$r4g2_out"
fi

# ...and a collect run leaves no `.skein/` state root behind: the retired
# third root was ungitignored, so it showed up in `git status`.
if [[ ! -e "$r4g2_root/.skein" ]]; then
	pass "(R4-G2) no .skein/ state root is created by a collect run"
else
	fail "(R4-G2) a collect run created a .skein/ state root"
fi

# ---------------------------------------------------------------------------
# Group R4-G4 — the file transport gets the same symlink guard as every other
# repo-rooted state path (F12). The guard now depends on WHAT the path is (a
# repo-rooted state path), not on WHICH FLAG it arrived through. An
# out-of-tree fixture path stays legal, so the whole suite above still runs.
# ---------------------------------------------------------------------------

r4g4_root="$TMPDIR_ROOT/r4g4"
make_scratch_repo "$r4g4_root"
mkdir -p "$r4g4_root/real" "$r4g4_root/.deep-review/lenses/r4g4"
jq -n -c '{logic:["u1"]}' >"$r4g4_root/real/units.json"
ln -s "$r4g4_root/real/units.json" "$r4g4_root/linked-units.json"

set +e
(cd "$r4g4_root" && bash "$SCRIPT" --root "$r4g4_root" --skill deep-review \
	--run-id r4g4 --expected-file "$r4g4_root/linked-units.json" >/dev/null 2>&1)
r4g4_link_rc=$?
set -e
if [[ "$r4g4_link_rc" -eq 2 ]]; then
	pass "(R4-G4/F12) a symlinked --expected-file inside the root exits 2"
else
	fail "(R4-G4/F12) symlinked --expected-file must exit 2, got rc=$r4g4_link_rc"
fi

# Ordering: the run dir's own guard must fire BEFORE --expected-file is read,
# so a symlinked run directory is refused before its contents are trusted.
r4g4b_root="$TMPDIR_ROOT/r4g4b"
make_scratch_repo "$r4g4b_root"
mkdir -p "$r4g4b_root/.deep-review/lenses" "$r4g4b_root/elsewhere"
ln -s "$r4g4b_root/elsewhere" "$r4g4b_root/.deep-review/lenses/r4g4b"
jq -n -c '{logic:["u1"]}' >"$r4g4b_root/.deep-review/lenses/r4g4b/expected.json"
set +e
r4g4b_err="$(cd "$r4g4b_root" && bash "$SCRIPT" --root "$r4g4b_root" --skill deep-review \
	--run-id r4g4b --expected-file "$r4g4b_root/.deep-review/lenses/r4g4b/expected.json" 2>&1 >/dev/null)"
r4g4b_rc=$?
set -e
if [[ "$r4g4b_rc" -eq 2 && "$r4g4b_err" == *"symlink"* && "$r4g4b_err" == *"lenses/r4g4b"* ]]; then
	pass "(R4-G4/F12) a symlinked run dir is refused before --expected-file is read"
else
	fail "(R4-G4/F12) symlinked run dir: rc=$r4g4b_rc err='$r4g4b_err'"
fi

# Control: an out-of-tree --expected-file (the fixture transport this whole
# suite uses) is untouched by the guard.
r4g4_ext="$TMPDIR_ROOT/outside-units.json"
jq -n -c '{logic:["u1"]}' >"$r4g4_ext"
set +e
(cd "$r4g4_root" && bash "$SCRIPT" --root "$r4g4_root" --skill deep-review \
	--run-id r4g4 --expected-file "$r4g4_ext" >/dev/null 2>&1)
r4g4_ext_rc=$?
set -e
if [[ "$r4g4_ext_rc" -eq 0 ]]; then
	pass "(R4-G4/control) an out-of-tree --expected-file is still accepted"
else
	fail "(R4-G4/control) out-of-tree --expected-file broke (rc=$r4g4_ext_rc)"
fi

# ---------------------------------------------------------------------------
# Group R4-G10 — coverage accounting survives a respawn.
#
# Codex addendum (SKILL.md:189): on respawn the prompt's unit payload narrows
# to the unreviewed list, but the EXPECTED FILE must keep the full original
# set. progress records merge across every attempt, and reviewed/unreviewed
# are computed as (assigned INTERSECT progress) / (assigned MINUS progress) --
# so a narrowed expected file drops the already-reviewed units out of
# `assigned` and the run under-reports its own coverage.
# ---------------------------------------------------------------------------

r4g10_root="$TMPDIR_ROOT/r4g10"
make_scratch_repo "$r4g10_root"
r4g10_run="$r4g10_root/.deep-review/lenses/r4g10"
mkdir -p "$r4g10_run"
write_lens_file "$r4g10_run/logic.1.jsonl" <<'R4G10A'
{"type":"start","units":["u1","u2"]}
{"type":"progress","unit":"u1"}
R4G10A
write_lens_file "$r4g10_run/logic.2.jsonl" <<'R4G10B'
{"type":"start","units":["u2"]}
{"type":"progress","unit":"u2"}
{"type":"done","status":"completed"}
R4G10B

jq -n -c '{logic:["u1","u2"]}' >"$r4g10_run/expected.json"
set +e
r4g10_full="$(cd "$r4g10_root" && bash "$SCRIPT" --root "$r4g10_root" --skill deep-review \
	--run-id r4g10 --expected-file "$r4g10_run/expected.json" --attempts 'logic:2' 2>&1)"
r4g10_full_rc=$?
set -e
if [[ "$r4g10_full_rc" -eq 0 ]] &&
	[[ "$(printf '%s' "$r4g10_full" | jq -r '.logic.assigned' 2>/dev/null)" == "2" ]] &&
	[[ "$(printf '%s' "$r4g10_full" | jq -r '.logic.reviewed' 2>/dev/null)" == "2" ]]; then
	pass "(R4-G10) an IMMUTABLE expected file reports full post-respawn coverage (assigned 2, reviewed 2)"
else
	fail "(R4-G10) immutable expected file: rc=$r4g10_full_rc out=$r4g10_full"
fi

# The counter-case the SKILL.md rule exists to prevent: a NARROWED expected
# file silently loses u1 from coverage accounting. Pinning it here records
# why the prose rule is load-bearing rather than stylistic.
jq -n -c '{logic:["u2"]}' >"$r4g10_root/narrowed.json"
set +e
r4g10_narrow="$(cd "$r4g10_root" && bash "$SCRIPT" --root "$r4g10_root" --skill deep-review \
	--run-id r4g10 --expected-file "$r4g10_root/narrowed.json" --attempts 'logic:2' 2>&1)"
set -e
if [[ "$(printf '%s' "$r4g10_narrow" | jq -r '.logic.assigned' 2>/dev/null)" == "1" ]]; then
	pass "(R4-G10/rationale) a narrowed expected file under-reports assigned (1, not 2) -- why the file is immutable"
else
	fail "(R4-G10/rationale) expected a narrowed file to report assigned:1, got $r4g10_narrow"
fi

finish
