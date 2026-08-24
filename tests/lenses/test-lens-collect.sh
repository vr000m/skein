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

finish
