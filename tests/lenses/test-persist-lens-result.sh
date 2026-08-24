#!/usr/bin/env bash
# test-persist-lens-result.sh — Phase 2 acceptance for
# scripts/persist-lens-result.sh (the streamed per-lens JSONL writer).
#
# Plan: docs/dev_plans/20260823-feature-review-skills-resilience.md,
# Phase 2 checklist ("Tests (persist writer side)"), and R3/R4's prose.
#
# Contract under test (per the plan; the script did not exist yet at the
# time this suite was written — see the phase's scope note):
#
#   scripts/persist-lens-result.sh --root <repo-root> --skill deep-review|review-plan \
#       --run-id <id> --lens <name> --attempt <n> --type start|progress|finding|done [...]
#
#   Appends ONE JSONL line per invocation to
#   <root>/<state-dir>/lenses/<run-id>/<lens>.<attempt>.jsonl, where
#   <state-dir> is `.deep-review` for --skill deep-review and `.review-plan`
#   for --skill review-plan. `--root` is always explicit, never
#   cwd-derived (R3/checklist: "--root respected from a different cwd").
#   One writer per file: every call is an append, never a truncate.
#
# ASSUMPTION (test-writer scope note, not fully specified by the plan): the
# exact per-`--type` payload flags (e.g. how `start`'s `units` list or
# `progress`'s `unit` name are passed) are not pinned down in the Phase 2
# checklist beyond the JSONL line shapes documented in R3
# (`{"type":"start","run_id":..,"units":[...]}`,
# `{"type":"progress","unit":..}`, ...). This suite assumes `--units
# <comma-list>` for `start` and `--unit <name>` for `progress`, since those
# are the natural flag names for the documented fields, but only asserts
# the flag-agnostic behaviours the checklist actually specifies: append
# (never truncate), `--root`-from-a-different-cwd, and the two error cases.
# If the implementation names these flags differently, only the "two
# sequential calls append two lines" case's invocation needs a rename —
# the assertions themselves (line count, no truncation) do not depend on
# the flag name chosen.
#
# Exit codes: 0 all assertions pass, 1 any assertion fails.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/persist-lens-result.sh"

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
	fail "preflight (scripts/persist-lens-result.sh not found at $SCRIPT -- not implemented yet)"
	finish
fi

if [[ ! -x "$SCRIPT" ]]; then
	fail "preflight (scripts/persist-lens-result.sh found but not executable at $SCRIPT)"
	finish
fi

attempt_file() {
	local root="$1" skill="$2" run_id="$3" lens="$4" attempt="$5"
	local state_dir
	case "$skill" in
	deep-review) state_dir=".deep-review" ;;
	review-plan) state_dir=".review-plan" ;;
	*)
		echo "test bug: unknown skill $skill" >&2
		exit 99
		;;
	esac
	printf '%s/%s/lenses/%s/%s.%s.jsonl' "$root" "$state_dir" "$run_id" "$lens" "$attempt"
}

# ---------------------------------------------------------------------------
# (1) two sequential calls append two lines -- append, never truncate
# ---------------------------------------------------------------------------

case1_root="$TMPDIR_ROOT/case-1"
mkdir -p "$case1_root"
target1="$(attempt_file "$case1_root" "deep-review" "run-1" "logic" "1")"

set +e
bash "$SCRIPT" --root "$case1_root" --skill deep-review --run-id run-1 \
	--lens logic --attempt 1 --type start --units u1,u2,u3 \
	>"$case1_root/stdout1" 2>"$case1_root/stderr1"
call1_exit=$?
bash "$SCRIPT" --root "$case1_root" --skill deep-review --run-id run-1 \
	--lens logic --attempt 1 --type progress --unit u1 \
	>"$case1_root/stdout2" 2>"$case1_root/stderr2"
call2_exit=$?
set -e

if [[ $call1_exit -ne 0 || $call2_exit -ne 0 ]]; then
	fail "(1) two sequential calls append two lines (script exited non-zero: call1=$call1_exit call2=$call2_exit)"
	sed 's/^/    /' "$case1_root/stderr1" "$case1_root/stderr2" 2>/dev/null
elif [[ ! -f "$target1" ]]; then
	fail "(1) two sequential calls append two lines (no file at $target1)"
else
	line_count="$(wc -l <"$target1" | tr -d ' ')"
	first_line="$(sed -n '1p' "$target1")"
	if [[ "$line_count" != "2" ]]; then
		fail "(1) two sequential calls append two lines (expected 2 lines, got $line_count)"
		sed 's/^/    /' "$target1"
	elif ! printf '%s' "$first_line" | jq -e '.type == "start"' >/dev/null 2>&1; then
		fail "(1) two sequential calls append two lines (first line was overwritten/truncated instead of appended: $first_line)"
	else
		pass "(1) two sequential calls append two lines (append, never truncate)"
	fi
fi

# A third call must add a third line without disturbing the first two.
set +e
bash "$SCRIPT" --root "$case1_root" --skill deep-review --run-id run-1 \
	--lens logic --attempt 1 --type progress --unit u2 \
	>"$case1_root/stdout3" 2>"$case1_root/stderr3"
call3_exit=$?
set -e

if [[ $call3_exit -eq 0 && -f "$target1" ]]; then
	line_count3="$(wc -l <"$target1" | tr -d ' ')"
	if [[ "$line_count3" == "3" ]]; then
		pass "(1b) a third sequential call appends a third line (still append-only)"
	else
		fail "(1b) a third sequential call appends a third line (expected 3 lines, got $line_count3)"
	fi
else
	fail "(1b) a third sequential call appends a third line (script exited non-zero or file missing)"
fi

# ---------------------------------------------------------------------------
# (2) --root respected from a different cwd
# ---------------------------------------------------------------------------

case2_root="$TMPDIR_ROOT/case-2-root"
unrelated_cwd="$TMPDIR_ROOT/case-2-elsewhere"
mkdir -p "$case2_root" "$unrelated_cwd"
target2="$(attempt_file "$case2_root" "deep-review" "run-2" "security" "1")"

set +e
(
	cd "$unrelated_cwd" && bash "$SCRIPT" --root "$case2_root" --skill deep-review \
		--run-id run-2 --lens security --attempt 1 --type progress --unit u1
) >"$case2_root/stdout" 2>"$case2_root/stderr"
case2_exit=$?
set -e

if [[ $case2_exit -ne 0 ]]; then
	fail "(2) --root respected from a different cwd (script exited non-zero)"
	sed 's/^/    /' "$case2_root/stderr"
elif [[ -f "$target2" ]]; then
	pass "(2) --root respected from a different cwd (wrote under --root, not cwd)"
elif [[ -e "$unrelated_cwd/.deep-review" ]]; then
	fail "(2) --root respected from a different cwd (wrote under cwd instead of --root)"
else
	fail "(2) --root respected from a different cwd (no file written anywhere; expected $target2)"
fi

# ---------------------------------------------------------------------------
# (3) missing required flag -> non-zero exit, no file written
# ---------------------------------------------------------------------------

case3_root="$TMPDIR_ROOT/case-3"
mkdir -p "$case3_root"

set +e
# --lens omitted.
bash "$SCRIPT" --root "$case3_root" --skill deep-review --run-id run-3 \
	--attempt 1 --type progress --unit u1 \
	>"$case3_root/stdout" 2>"$case3_root/stderr"
case3_exit=$?
set -e

if [[ $case3_exit -eq 0 ]]; then
	fail "(3) missing required flag exits non-zero (script exited 0 with --lens omitted)"
elif find "$case3_root" -name '*.jsonl' 2>/dev/null | grep -q .; then
	fail "(3) missing required flag exits non-zero, no file written (a .jsonl file was written despite the missing flag)"
else
	pass "(3) missing required flag (--lens) exits non-zero and writes no file"
fi

# ---------------------------------------------------------------------------
# (4) unknown --type -> non-zero exit, no file written
# ---------------------------------------------------------------------------

case4_root="$TMPDIR_ROOT/case-4"
mkdir -p "$case4_root"

set +e
bash "$SCRIPT" --root "$case4_root" --skill deep-review --run-id run-4 \
	--lens logic --attempt 1 --type bogus \
	>"$case4_root/stdout" 2>"$case4_root/stderr"
case4_exit=$?
set -e

if [[ $case4_exit -eq 0 ]]; then
	fail "(4) unknown --type exits non-zero (script exited 0 with --type bogus)"
elif find "$case4_root" -name '*.jsonl' 2>/dev/null | grep -q .; then
	fail "(4) unknown --type exits non-zero, no file written (a .jsonl file was written despite the unknown type)"
else
	pass "(4) unknown --type exits non-zero and writes no file"
fi

finish
