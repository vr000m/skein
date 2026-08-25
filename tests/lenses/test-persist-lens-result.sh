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

# no_jsonl_anywhere <root> -- true (0) iff no .jsonl file exists anywhere
# under <root>, including under a hidden dir (find's default already
# recurses into dotdirs; -not -path excludes nothing here deliberately, we
# want the strictest possible check for a traversal write).
no_jsonl_anywhere() {
	local root="$1"
	! find "$root" -name '*.jsonl' 2>/dev/null | grep -q .
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

# ---------------------------------------------------------------------------
# (5) F1 -- identifier validation: path traversal, glob metachars, leading
#     dash in --lens/--run-id -> exit 2 (or non-zero), no file written
#     ANYWHERE under root (not just at the naive expected path).
# ---------------------------------------------------------------------------

case5_root="$TMPDIR_ROOT/case-5"
mkdir -p "$case5_root"

# attempt_dir would be <case5_root>/.deep-review/lenses/run-5; the classic
# reproduction ("../../pwned") resolves two levels up from there, i.e.
# <case5_root>/.deep-review/pwned.1.jsonl.
traversal_target="$case5_root/.deep-review/pwned.1.jsonl"

set +e
bash "$SCRIPT" --root "$case5_root" --skill deep-review --run-id run-5 \
	--lens '../../pwned' --attempt 1 --type start --units u1 \
	>"$case5_root/stdout-lens-traversal" 2>"$case5_root/stderr-lens-traversal"
lens_traversal_exit=$?
set -e

if [[ $lens_traversal_exit -eq 0 ]]; then
	fail "(5a) --lens '../../pwned' exits non-zero (script exited 0)"
elif [[ -e "$traversal_target" ]]; then
	fail "(5a) --lens '../../pwned' writes nothing (traversal target $traversal_target exists!)"
elif ! no_jsonl_anywhere "$case5_root"; then
	fail "(5a) --lens '../../pwned' writes nothing anywhere under root (found a stray .jsonl)"
else
	pass "(5a) --lens '../../pwned' rejected, no file written anywhere"
fi

for bad_lens in 'a*b' '-x' '.' '..' '' 'a/b' 'a b' 'a,b'; do
	set +e
	bash "$SCRIPT" --root "$case5_root" --skill deep-review --run-id "run-5-lens" \
		--lens "$bad_lens" --attempt 1 --type start --units u1 \
		>"$case5_root/stdout-bl" 2>"$case5_root/stderr-bl"
	bl_exit=$?
	set -e
	if [[ $bl_exit -eq 0 ]]; then
		fail "(5b) --lens '$bad_lens' exits non-zero (script exited 0)"
	elif ! no_jsonl_anywhere "$case5_root"; then
		fail "(5b) --lens '$bad_lens' writes no file (found one)"
	else
		pass "(5b) --lens '$bad_lens' rejected, no file written"
	fi
done

for bad_run_id in '../x' '/etc/passwd' 'a*b' '-x' '.' 'a/b'; do
	set +e
	bash "$SCRIPT" --root "$case5_root" --skill deep-review --run-id "$bad_run_id" \
		--lens logic --attempt 1 --type start --units u1 \
		>"$case5_root/stdout-br" 2>"$case5_root/stderr-br"
	br_exit=$?
	set -e
	if [[ $br_exit -eq 0 ]]; then
		fail "(5c) --run-id '$bad_run_id' exits non-zero (script exited 0)"
	elif ! no_jsonl_anywhere "$case5_root"; then
		fail "(5c) --run-id '$bad_run_id' writes no file (found one)"
	else
		pass "(5c) --run-id '$bad_run_id' rejected, no file written"
	fi
done

# Conforming values still succeed, including a colon in --run-id (ISO-8601
# run-ids must keep working -- ':' is allowed for run-id, not for --lens).
target5_ok="$(attempt_file "$case5_root" "deep-review" "2026-03-17T14:30:00Z" "logic" "1")"
set +e
bash "$SCRIPT" --root "$case5_root" --skill deep-review --run-id '2026-03-17T14:30:00Z' \
	--lens logic --attempt 1 --type start --units u1 \
	>"$case5_root/stdout-ok" 2>"$case5_root/stderr-ok"
ok_exit=$?
set -e
if [[ $ok_exit -eq 0 && -f "$target5_ok" ]]; then
	pass "(5d) --lens logic --run-id (ISO-8601, colon) exits 0, file written at expected path"
else
	fail "(5d) --lens logic --run-id (ISO-8601, colon) should succeed (exit=$ok_exit, file present=$([[ -f "$target5_ok" ]] && echo yes || echo no))"
	sed 's/^/    /' "$case5_root/stderr-ok" 2>/dev/null
fi

# ---------------------------------------------------------------------------
# (6) F1 -- symlinked lenses dir is refused, nothing written through it
# ---------------------------------------------------------------------------

if [[ "$(id -u)" -eq 0 ]]; then
	echo "SKIP: (6) symlinked lenses dir refused (running as root)"
else
	case6_root="$TMPDIR_ROOT/case-6"
	mkdir -p "$case6_root/.deep-review"
	outside6="$TMPDIR_ROOT/case-6-outside"
	mkdir -p "$outside6"
	ln -s "$outside6" "$case6_root/.deep-review/lenses"

	set +e
	bash "$SCRIPT" --root "$case6_root" --skill deep-review --run-id run-6 \
		--lens logic --attempt 1 --type start --units u1 \
		>"$case6_root/stdout" 2>"$case6_root/stderr"
	case6_exit=$?
	set -e

	if [[ $case6_exit -eq 0 ]]; then
		fail "(6) symlinked lenses dir is refused (script exited 0)"
		sed 's/^/    /' "$case6_root/stdout"
	elif find "$outside6" -name '*.jsonl' 2>/dev/null | grep -q .; then
		fail "(6) symlinked lenses dir is refused (a file was written through the symlink into $outside6)"
	else
		pass "(6) symlinked lenses dir is refused, nothing written through the link (exit=$case6_exit)"
	fi
fi

# ---------------------------------------------------------------------------
# (7) F9 -- leading-zero --attempt normalises to the same file as the
#     non-padded spelling; JSON `attempt` field is 7 in both cases.
# ---------------------------------------------------------------------------

case7_root="$TMPDIR_ROOT/case-7"
mkdir -p "$case7_root"
target7="$(attempt_file "$case7_root" "deep-review" "run-7" "logic" "7")"
target7_padded="$(attempt_file "$case7_root" "deep-review" "run-7" "logic" "007")"

set +e
bash "$SCRIPT" --root "$case7_root" --skill deep-review --run-id run-7 \
	--lens logic --attempt 007 --type start --units u1 \
	>"$case7_root/stdout1" 2>"$case7_root/stderr1"
c7a_exit=$?
bash "$SCRIPT" --root "$case7_root" --skill deep-review --run-id run-7 \
	--lens logic --attempt 7 --type progress --unit u1 \
	>"$case7_root/stdout2" 2>"$case7_root/stderr2"
c7b_exit=$?
set -e

if [[ $c7a_exit -ne 0 || $c7b_exit -ne 0 ]]; then
	fail "(7) --attempt 007 and --attempt 7 both succeed (exit1=$c7a_exit exit2=$c7b_exit)"
	sed 's/^/    /' "$case7_root/stderr1" "$case7_root/stderr2" 2>/dev/null
elif [[ -e "$target7_padded" ]]; then
	fail "(7) --attempt 007 normalises to the unpadded filename (a separate $target7_padded was created -- duplicate writer)"
elif [[ ! -f "$target7" ]]; then
	fail "(7) --attempt 007 and --attempt 7 write to $target7 (file not found)"
else
	line_count7="$(wc -l <"$target7" | tr -d ' ')"
	attempt_fields="$(jq -r '.attempt' "$target7" | sort -u | tr '\n' ' ')"
	if [[ "$line_count7" == "2" && "$attempt_fields" == "7 " ]]; then
		pass "(7) --attempt 007 and --attempt 7 write to one file (logic.7.jsonl), attempt=7 in both lines, no duplicate writer"
	else
		fail "(7) --attempt 007/--attempt 7 normalisation (lines=$line_count7, attempt fields='$attempt_fields')"
		sed 's/^/    /' "$target7"
	fi
fi

# ---------------------------------------------------------------------------
# (8) F10/D1 -- a --unit containing a comma is rejected, exit 2, no file
# ---------------------------------------------------------------------------

case8_root="$TMPDIR_ROOT/case-8"
mkdir -p "$case8_root"

set +e
bash "$SCRIPT" --root "$case8_root" --skill deep-review --run-id run-8 \
	--lens logic --attempt 1 --type progress --unit 'a,b' \
	>"$case8_root/stdout" 2>"$case8_root/stderr"
case8_exit=$?
set -e

if [[ $case8_exit -eq 2 ]]; then
	if no_jsonl_anywhere "$case8_root"; then
		pass "(8) --unit 'a,b' (comma) rejected with exit 2, no file written"
	else
		fail "(8) --unit 'a,b' rejected but a file was written anyway"
	fi
else
	fail "(8) --unit 'a,b' (comma) must exit 2 (got $case8_exit)"
	sed 's/^/    /' "$case8_root/stderr"
fi

# ---------------------------------------------------------------------------
# (9) G1 -- --json-stdin carries untrusted text without shell expansion
# ---------------------------------------------------------------------------

case9_root="$TMPDIR_ROOT/case-9"
mkdir -p "$case9_root"
case9_canary="$case9_root/pwned"

case9_evidence='literal $(touch "'"$case9_canary"'") and `touch '"$case9_canary"'` and a " quote'
case9_json="$(jq -n -c --arg ev "$case9_evidence" '{
	type: "finding", severity: "Critical", category: "Logic",
	location: "a.md:1", summary: "untrusted text round-trip",
	evidence: $ev, suggestion: "none"
}')"

set +e
printf '%s' "$case9_json" | bash "$SCRIPT" --root "$case9_root" --skill deep-review \
	--run-id run-9 --lens logic --attempt 1 --json-stdin \
	>"$case9_root/stdout" 2>"$case9_root/stderr"
case9_exit=$?
set -e

case9_target="$case9_root/.deep-review/lenses/run-9/logic.1.jsonl"
if [[ $case9_exit -ne 0 ]]; then
	fail "(9) --json-stdin finding must exit 0 (got $case9_exit)"
	sed 's/^/    /' "$case9_root/stderr"
elif [[ -e "$case9_canary" ]]; then
	fail "(9) --json-stdin evidence was shell-expanded -- canary $case9_canary exists"
elif [[ ! -f "$case9_target" ]]; then
	fail "(9) --json-stdin wrote no line at $case9_target"
else
	case9_got="$(jq -r '.evidence' "$case9_target")"
	case9_type="$(jq -r '.type' "$case9_target")"
	case9_attempt="$(jq -r '.attempt' "$case9_target")"
	case9_lens="$(jq -r '.lens' "$case9_target")"
	if [[ "$case9_got" == "$case9_evidence" && "$case9_type" == "finding" && "$case9_attempt" == "1" && "$case9_lens" == "logic" ]]; then
		pass "(9) --json-stdin persists untrusted evidence literally, no shell expansion"
	else
		fail "(9) --json-stdin round-trip mismatch (type=$case9_type lens=$case9_lens attempt=$case9_attempt evidence='$case9_got')"
	fi
fi

# ---------------------------------------------------------------------------
# (9b) G1 -- --json-stdin line is byte-identical to the flag-mode line
# ---------------------------------------------------------------------------

case9b_root="$TMPDIR_ROOT/case-9b"
mkdir -p "$case9b_root"

set +e
bash "$SCRIPT" --root "$case9b_root" --skill deep-review --run-id run-9b \
	--lens logic --attempt 1 --type finding --severity Important \
	--category Logic --location 'a.md:2' --summary 'flag mode' \
	--evidence 'ev' --suggestion 'sg' >/dev/null 2>"$case9b_root/stderr"
case9b_flag_exit=$?
printf '%s' '{"type":"finding","severity":"Important","category":"Logic","location":"a.md:2","summary":"flag mode","evidence":"ev","suggestion":"sg"}' |
	bash "$SCRIPT" --root "$case9b_root" --skill deep-review --run-id run-9b \
		--lens logic --attempt 2 --json-stdin >/dev/null 2>>"$case9b_root/stderr"
case9b_json_exit=$?
set -e

case9b_a="$case9b_root/.deep-review/lenses/run-9b/logic.1.jsonl"
case9b_b="$case9b_root/.deep-review/lenses/run-9b/logic.2.jsonl"
if [[ $case9b_flag_exit -ne 0 || $case9b_json_exit -ne 0 ]]; then
	fail "(9b) flag/json parity setup failed (flag=$case9b_flag_exit json=$case9b_json_exit)"
	sed 's/^/    /' "$case9b_root/stderr"
elif [[ ! -f "$case9b_a" || ! -f "$case9b_b" ]]; then
	fail "(9b) flag/json parity: one of the attempt files is missing"
else
	case9b_norm_a="$(jq -c 'del(.ts) | .attempt = 0' "$case9b_a")"
	case9b_norm_b="$(jq -c 'del(.ts) | .attempt = 0' "$case9b_b")"
	if [[ "$case9b_norm_a" == "$case9b_norm_b" ]]; then
		pass "(9b) --json-stdin produces the same line shape as flag mode (one encoder)"
	else
		fail "(9b) flag/json line shapes diverge: '$case9b_norm_a' vs '$case9b_norm_b'"
	fi
fi

# ---------------------------------------------------------------------------
# (10) G1 -- malformed / non-object stdin exits 2 and writes nothing
# ---------------------------------------------------------------------------

case10_root="$TMPDIR_ROOT/case-10"
mkdir -p "$case10_root"

set +e
printf '%s' '{"type":"finding",' | bash "$SCRIPT" --root "$case10_root" \
	--skill deep-review --run-id run-10 --lens logic --attempt 1 --json-stdin \
	>"$case10_root/stdout" 2>"$case10_root/stderr"
case10_exit=$?
printf '%s' '["not","an","object"]' | bash "$SCRIPT" --root "$case10_root" \
	--skill deep-review --run-id run-10 --lens logic --attempt 1 --json-stdin \
	>>"$case10_root/stdout" 2>>"$case10_root/stderr"
case10_arr_exit=$?
set -e

if [[ $case10_exit -eq 2 && $case10_arr_exit -eq 2 ]]; then
	if no_jsonl_anywhere "$case10_root"; then
		pass "(10) malformed JSON and non-object stdin both exit 2, nothing written"
	else
		fail "(10) malformed --json-stdin exited 2 but a file was written anyway"
	fi
else
	fail "(10) malformed/non-object --json-stdin must exit 2 (got $case10_exit / $case10_arr_exit)"
	sed 's/^/    /' "$case10_root/stderr"
fi

# ---------------------------------------------------------------------------
# (11) G1 -- --json-stdin is mutually exclusive with the payload flags
# ---------------------------------------------------------------------------

case11_root="$TMPDIR_ROOT/case-11"
mkdir -p "$case11_root"

set +e
printf '%s' '{"type":"finding","severity":"Minor","category":"Logic","location":"a.md:1","summary":"s"}' |
	bash "$SCRIPT" --root "$case11_root" --skill deep-review --run-id run-11 \
		--lens logic --attempt 1 --json-stdin --type finding \
		>"$case11_root/stdout" 2>"$case11_root/stderr"
case11_exit=$?
printf '%s' '{"type":"finding","severity":"Minor","category":"Logic","location":"a.md:1","summary":"s"}' |
	bash "$SCRIPT" --root "$case11_root" --skill deep-review --run-id run-11 \
		--lens logic --attempt 1 --json-stdin --evidence 'x' \
		>>"$case11_root/stdout" 2>>"$case11_root/stderr"
case11_ev_exit=$?
set -e

if [[ $case11_exit -eq 2 && $case11_ev_exit -eq 2 ]]; then
	if no_jsonl_anywhere "$case11_root"; then
		pass "(11) --json-stdin with --type/--evidence exits 2, nothing written"
	else
		fail "(11) --json-stdin + payload flag exited 2 but a file was written anyway"
	fi
else
	fail "(11) --json-stdin + payload flag must exit 2 (got $case11_exit / $case11_ev_exit)"
	sed 's/^/    /' "$case11_root/stderr"
fi

# ---------------------------------------------------------------------------
# (12) G1 -- path-controlling keys inside the JSON body are ignored
# ---------------------------------------------------------------------------

case12_root="$TMPDIR_ROOT/case-12"
mkdir -p "$case12_root"

set +e
printf '%s' '{"type":"done","status":"completed","lens":"evil","attempt":99,"run_id":"other","skill":"review-plan","root":"/nonexistent/evil"}' |
	bash "$SCRIPT" --root "$case12_root" --skill deep-review --run-id run-12 \
		--lens logic --attempt 1 --json-stdin >"$case12_root/stdout" 2>"$case12_root/stderr"
case12_exit=$?
set -e

case12_target="$case12_root/.deep-review/lenses/run-12/logic.1.jsonl"
if [[ $case12_exit -ne 0 ]]; then
	fail "(12) --json-stdin done must exit 0 (got $case12_exit)"
	sed 's/^/    /' "$case12_root/stderr"
elif [[ ! -f "$case12_target" ]]; then
	fail "(12) body-supplied lens/attempt redirected the write path (expected $case12_target)"
else
	case12_fields="$(jq -r '[.lens, (.attempt|tostring), .run_id, .status] | join(" ")' "$case12_target")"
	if [[ "$case12_fields" == "logic 1 run-12 completed" ]]; then
		pass "(12) orchestrator-owned keys in the JSON body are ignored"
	else
		fail "(12) orchestrator-owned keys leaked from the body: '$case12_fields'"
	fi
fi

# ---------------------------------------------------------------------------
# (A1-A10) --json-stdin decoder must never let a payload byte reach a shell.
#
# r2 finding #1/#2/#3 (Critical): the decoder built shell assignments with
# jq's `@sh` and ran `eval`. `@sh` errors only on OBJECTS -- an ARRAY renders
# as space-separated shell-quoted words, so `TYPE='start' 'sh' '-c' 'cmd'`
# parsed as an assignment followed by a COMMAND, executed before the exit-2
# rejection. r2 finding #10: the shape check was un-slurped, so jq's exit
# status reflected only the LAST of several concatenated documents.
#
# Invariant under test: no payload byte ever reaches a shell (there is no
# `eval` in the script); stdin must be exactly one document; that document an
# object; every recognised scalar key absent, null, or a string. Anything
# else exits 2 before a directory is created or a byte written.
# ---------------------------------------------------------------------------

# reject_payload <label> <root-name> <payload> -- assert the payload exits 2
# and writes no JSONL anywhere under its own root.
reject_payload() {
	local label="$1" name="$2" payload="$3"
	local root="$TMPDIR_ROOT/$name"
	mkdir -p "$root"
	local rc=0
	set +e
	printf '%s' "$payload" |
		bash "$SCRIPT" --root "$root" --skill deep-review --run-id run-a \
			--lens logic --attempt 1 --json-stdin >/dev/null 2>"$root/stderr"
	rc=$?
	set -e
	if [[ $rc -ne 2 ]]; then
		fail "$label must exit 2 (got $rc)"
		sed 's/^/    /' "$root/stderr"
		return
	fi
	if ! no_jsonl_anywhere "$root"; then
		fail "$label exited 2 but a JSONL file was written under $root"
		return
	fi
	pass "$label"
}

# --- A1: an array-valued `type` must not execute --------------------------
a1_root="$TMPDIR_ROOT/case-a1"
mkdir -p "$a1_root"
a1_probe="$a1_root/EXEC_PROBE"
set +e
printf '%s' "{\"type\":[\"start\",\"/bin/sh\",\"-c\",\"echo pwned > $a1_probe\"],\"units\":[]}" |
	bash "$SCRIPT" --root "$a1_root" --skill deep-review --run-id run-a1 \
		--lens logic --attempt 1 --json-stdin >/dev/null 2>"$a1_root/stderr"
a1_exit=$?
set -e
if [[ -e "$a1_probe" ]]; then
	fail "(A1) array-valued 'type' EXECUTED the payload -- probe $a1_probe exists"
elif [[ $a1_exit -ne 2 ]]; then
	fail "(A1) array-valued 'type' must exit 2 (got $a1_exit)"
elif ! no_jsonl_anywhere "$a1_root"; then
	fail "(A1) array-valued 'type' exited 2 but wrote a JSONL file"
else
	pass "(A1) array-valued 'type' exits 2, executes nothing, writes nothing"
fi

# --- A2: an array-valued `summary` on an otherwise valid finding ----------
a2_root="$TMPDIR_ROOT/case-a2"
mkdir -p "$a2_root"
a2_probe="$a2_root/EXEC_PROBE"
set +e
printf '%s' "{\"type\":\"finding\",\"severity\":\"Critical\",\"category\":\"Logic\",\"location\":\"a.sh:1\",\"summary\":[\"x\",\"/bin/sh\",\"-c\",\"echo pwned > $a2_probe\"]}" |
	bash "$SCRIPT" --root "$a2_root" --skill deep-review --run-id run-a2 \
		--lens logic --attempt 1 --json-stdin >/dev/null 2>"$a2_root/stderr"
a2_exit=$?
set -e
if [[ -e "$a2_probe" ]]; then
	fail "(A2) array-valued 'summary' EXECUTED the payload -- probe $a2_probe exists"
elif [[ $a2_exit -ne 2 ]]; then
	fail "(A2) array-valued 'summary' must exit 2 (got $a2_exit)"
elif ! no_jsonl_anywhere "$a2_root"; then
	fail "(A2) array-valued 'summary' exited 2 but wrote a JSONL file"
else
	pass "(A2) array-valued 'summary' exits 2, executes nothing, writes nothing"
fi

# --- A3/A4: object- and number-valued scalar keys -------------------------
reject_payload "(A3) object-valued 'category' exits 2, nothing written" case-a3 \
	'{"type":"finding","severity":"Critical","category":{"a":1},"location":"a.sh:1","summary":"s"}'
reject_payload "(A4) number-valued 'severity' exits 2, nothing written" case-a4 \
	'{"type":"finding","severity":3,"category":"Logic","location":"a.sh:1","summary":"s"}'

# --- A5: an explicit null is accepted and serialised as "" ----------------
a5_root="$TMPDIR_ROOT/case-a5"
mkdir -p "$a5_root"
set +e
printf '%s' '{"type":"finding","severity":"Critical","category":"Logic","location":"a.sh:1","summary":"s","evidence":null,"suggestion":null}' |
	bash "$SCRIPT" --root "$a5_root" --skill deep-review --run-id run-a5 \
		--lens logic --attempt 1 --json-stdin >/dev/null 2>"$a5_root/stderr"
a5_exit=$?
set -e
a5_target="$a5_root/.deep-review/lenses/run-a5/logic.1.jsonl"
if [[ $a5_exit -ne 0 ]]; then
	fail "(A5) null-valued 'evidence'/'suggestion' must be accepted (exit $a5_exit)"
	sed 's/^/    /' "$a5_root/stderr"
elif [[ ! -f "$a5_target" ]]; then
	fail "(A5) no line written at $a5_target"
elif [[ "$(jq -r '[.evidence, .suggestion] | join("|")' "$a5_target")" == "|" ]]; then
	pass "(A5) explicit JSON null serialises as the empty string"
else
	fail "(A5) null did not serialise as \"\": $(jq -c '[.evidence,.suggestion]' "$a5_target")"
fi

# --- A6: two concatenated documents -- neither may be written -------------
reject_payload "(A6) two concatenated JSON documents exit 2, nothing written" case-a6 \
	'{"type":"done","status":"errored"} {"type":"done","status":"completed"}'

# --- A7: empty stdin ------------------------------------------------------
reject_payload "(A7) empty stdin exits 2, nothing written" case-a7 ''

# --- A8: non-object top-level values --------------------------------------
reject_payload "(A8a) top-level array exits 2, nothing written" case-a8a '[]'
reject_payload "(A8b) top-level string exits 2, nothing written" case-a8b '"x"'
reject_payload "(A8c) top-level number exits 2, nothing written" case-a8c '3'

# --- A9: byte-exact fidelity of a hostile-looking but valid string --------
a9_root="$TMPDIR_ROOT/case-a9"
mkdir -p "$a9_root"
a9_probe="$a9_root/EXEC_PROBE"
a9_expected="$a9_root/expected.txt"
printf 'x $(touch %s) `touch %s` "dq" '"'"'sq'"'"' \\ ${HOME} line1\nline2\n' \
	"$a9_probe" "$a9_probe" >"$a9_expected"
a9_payload="$(jq -n --rawfile s "$a9_expected" \
	'{type:"finding",severity:"Critical",category:"Logic",location:"a.sh:1",summary:$s}')"
set +e
printf '%s' "$a9_payload" |
	bash "$SCRIPT" --root "$a9_root" --skill deep-review --run-id run-a9 \
		--lens logic --attempt 1 --json-stdin >/dev/null 2>"$a9_root/stderr"
a9_exit=$?
set -e
a9_target="$a9_root/.deep-review/lenses/run-a9/logic.1.jsonl"
if [[ -e "$a9_probe" ]]; then
	fail "(A9) a valid string payload was shell-expanded -- probe $a9_probe exists"
elif [[ $a9_exit -ne 0 ]]; then
	fail "(A9) valid string payload must exit 0 (got $a9_exit)"
	sed 's/^/    /' "$a9_root/stderr"
elif [[ ! -f "$a9_target" ]]; then
	fail "(A9) no line written at $a9_target"
elif jq -e --rawfile want "$a9_expected" '.summary == $want' "$a9_target" >/dev/null; then
	pass "(A9) \$(...), backticks, quotes and embedded/trailing newlines stored byte-identically"
else
	fail "(A9) round-trip is not byte-identical: $(jq -c '.summary' "$a9_target")"
fi

# --- A10: `units` stays array-of-strings (exempt from the scalar rule) ----
a10_root="$TMPDIR_ROOT/case-a10"
mkdir -p "$a10_root"
set +e
printf '%s' '{"type":"start","units":["a b","c"]}' |
	bash "$SCRIPT" --root "$a10_root" --skill deep-review --run-id run-a10 \
		--lens logic --attempt 1 --json-stdin >/dev/null 2>"$a10_root/stderr"
a10_exit=$?
set -e
a10_target="$a10_root/.deep-review/lenses/run-a10/logic.1.jsonl"
if [[ $a10_exit -ne 0 ]]; then
	fail "(A10) 'units' array-of-strings must be accepted (exit $a10_exit)"
	sed 's/^/    /' "$a10_root/stderr"
elif [[ "$(jq -c '.units' "$a10_target" 2>/dev/null)" != '["a b","c"]' ]]; then
	fail "(A10) 'units' array not preserved: $(jq -c '.units' "$a10_target" 2>/dev/null)"
else
	pass "(A10) 'units' array-of-strings is accepted verbatim"
fi
reject_payload "(A10b) 'units' with a non-string element exits 2, nothing written" case-a10b \
	'{"type":"start","units":["a",1]}'

# --- A11: a comma-bearing unit name ROUND-TRIPS on the JSON transport -----
# r4 F10 INVERSION. This used to reject `{"units":["a,b"]}`, on the reasoning
# that expected units reach the collector as a CSV so a comma-bearing name
# would be re-split downstream and never match its own progress record. That
# premise is gone: the collector holds --expected-file units as a JSON array
# from jq to jq and never joins them. The rule was enforcing a property of the
# collector's old internal representation, and it rejected a real review-plan
# heading (`## Post-completion follow-ups (A3/A5, 2026-05-24)`) at the writer.
# The comma survives as a restriction only on the CSV spellings, where it
# genuinely is the separator (A11b below, and --expected in the collector).
a11_root="$TMPDIR_ROOT/case-a11"
mkdir -p "$a11_root"
set +e
printf '%s' '{"type":"start","units":["a,b","c"]}' |
	bash "$SCRIPT" --root "$a11_root" --skill deep-review --run-id run-a11 \
		--lens logic --attempt 1 --json-stdin >/dev/null 2>"$a11_root/stderr"
a11_exit=$?
set -e
a11_target="$a11_root/.deep-review/lenses/run-a11/logic.1.jsonl"
if [[ $a11_exit -ne 0 ]]; then
	fail "(A11) a comma-bearing 'units' element must be accepted on the JSON transport (exit $a11_exit)"
	sed 's/^/    /' "$a11_root/stderr"
elif [[ "$(jq -c '.units' "$a11_target" 2>/dev/null)" != '["a,b","c"]' ]]; then
	fail "(A11) comma-bearing unit not preserved: $(jq -c '.units' "$a11_target" 2>/dev/null)"
else
	pass "(A11) a comma-bearing 'units' element round-trips as ONE unit on the JSON transport"
fi

# An EMPTY element is still rejected: that is the one rule which is a property
# of a unit rather than of a transport (a lens can never report it reviewed).
reject_payload "(A11c) an empty 'units' element exits 2, nothing written" case-a11c \
	'{"type":"start","units":["a",""]}'
# R6-G3a — the CSV-STRING spelling of `units` on the JSON wire is GONE.
#
# This case is the INVERSION of the round-5 (A11b) assertion, which required
# `{"type":"start","units":"a,b"}` to be accepted and split into two units.
# That assertion encoded the defect: on this transport a comma is DATA — the
# script header, PERSIST_UNIT_JQ_GATE, the frozen plan and all four lens
# SKILL.md mirrors all say "a JSON array of strings ... a unit is a string,
# not a CSV field" — so a lens emitting a single comma-bearing unit as a bare
# string silently registered TWO assigned units that no `progress` record can
# ever match, stranding the lens at `partial` forever with no exit 2.
# DO NOT RESTORE THE OLD ASSERTION. The ARGV `--units` CSV is a different
# wire and keeps its comma separator — see (R6-G3c) below.
a11b_root="$TMPDIR_ROOT/case-a11b"
mkdir -p "$a11b_root"
set +e
printf '%s' '{"type":"start","units":"a,b"}' |
	bash "$SCRIPT" --root "$a11b_root" --skill deep-review --run-id run-a11b \
		--lens logic --attempt 1 --json-stdin >/dev/null 2>"$a11b_root/stderr"
a11b_exit=$?
set -e
a11b_target="$a11b_root/.deep-review/lenses/run-a11b/logic.1.jsonl"
if [[ $a11b_exit -eq 2 ]] && grep -q "array" "$a11b_root/stderr" && [[ ! -e "$a11b_target" ]]; then
	pass "(R6-G3a) a CSV-string 'units' on the JSON wire exits 2, names 'array', and writes no attempt file"
else
	fail "(R6-G3a) exit=$a11b_exit err='$(cat "$a11b_root/stderr")' attempt_file=$([[ -e "$a11b_target" ]] && echo present || echo absent)"
fi

# R6-G3b — the POSITIVE control the removal exists to protect: a real
# comma-bearing review-plan heading, carried as ONE array element, round-trips
# byte-identically through the writer and back out of the collector's
# `assigned`/`unreviewed`.
r6g3b_root="$TMPDIR_ROOT/case-r6g3b"
mkdir -p "$r6g3b_root"
r6g3b_unit='## Post-completion follow-ups (A3/A5, 2026-05-24)'
set +e
jq -n -c --arg u "$r6g3b_unit" '{type:"start",units:[$u]}' |
	bash "$SCRIPT" --root "$r6g3b_root" --skill deep-review --run-id run-r6g3b \
		--lens logic --attempt 1 --json-stdin >/dev/null 2>"$r6g3b_root/stderr"
r6g3b_exit=$?
set -e
r6g3b_target="$r6g3b_root/.deep-review/lenses/run-r6g3b/logic.1.jsonl"
r6g3b_units="$(jq -c '.units' "$r6g3b_target" 2>/dev/null || true)"
r6g3b_expect="$(jq -n -c --arg u "$r6g3b_unit" '[$u]')"
jq -n -c --arg u "$r6g3b_unit" '{logic:[$u]}' >"$r6g3b_root/expected.json"
r6g3b_collect="$(bash "$REPO_ROOT/scripts/collect-lens-results.sh" --root "$r6g3b_root" \
	--skill deep-review --run-id run-r6g3b --expected-file "$r6g3b_root/expected.json" 2>"$r6g3b_root/collect.err" || true)"
r6g3b_unreviewed="$(printf '%s' "$r6g3b_collect" | jq -c '.logic.unreviewed' 2>/dev/null || true)"
if [[ $r6g3b_exit -eq 0 && "$r6g3b_units" == "$r6g3b_expect" && "$r6g3b_unreviewed" == "$r6g3b_expect" ]]; then
	pass "(R6-G3b) a comma-bearing unit is ONE unit and round-trips byte-identically through the collector"
else
	fail "(R6-G3b) exit=$r6g3b_exit written=$r6g3b_units unreviewed=$r6g3b_unreviewed expected=$r6g3b_expect err='$(cat "$r6g3b_root/stderr")'"
fi

# R6-G3c — the ARGV wire is untouched: `--units 'a,b'` is still two units.
r6g3c_root="$TMPDIR_ROOT/case-r6g3c"
mkdir -p "$r6g3c_root"
set +e
bash "$SCRIPT" --root "$r6g3c_root" --skill deep-review --run-id run-r6g3c \
	--lens logic --attempt 1 --type start --units 'a,b' >/dev/null 2>"$r6g3c_root/stderr"
r6g3c_exit=$?
set -e
r6g3c_units="$(jq -c '.units' "$r6g3c_root/.deep-review/lenses/run-r6g3c/logic.1.jsonl" 2>/dev/null || true)"
if [[ $r6g3c_exit -eq 0 && "$r6g3c_units" == '["a","b"]' ]]; then
	pass "(R6-G3c) the ARGV --units CSV still splits on the comma"
else
	fail "(R6-G3c) exit=$r6g3c_exit units=$r6g3c_units err='$(cat "$r6g3c_root/stderr")'"
fi

# ---------------------------------------------------------------------------
# (G5) --json-file: the same payload, read from a file, with no heredoc
# delimiter to end early.
#
# --json-stdin reaches this script under a quoted heredoc (<<'SKEIN_JSON'),
# and bash ends a heredoc at a line consisting EXACTLY of the delimiter. A
# payload that ever contained a bare `SKEIN_JSON` line would end the heredoc
# there and the remainder would execute as shell. Valid JSON cannot produce
# such a line, so the hazard is gated on a model FORMATTING error rather than
# on reviewed content -- but orchestrator-side writers have a file-write tool
# and no reason to accept it. Lenses keep --json-stdin (a temp file per
# streamed finding is worse ergonomics for a streaming writer).
# ---------------------------------------------------------------------------
g5_root="$TMPDIR_ROOT/case-g5"
mkdir -p "$g5_root"
g5_payload="$g5_root/payload.json"
printf '%s' '{"type":"start","units":["u1","u2"]}' >"$g5_payload"

set +e
bash "$SCRIPT" --root "$g5_root" --skill deep-review --run-id run-g5 \
	--lens logic --attempt 1 --json-file "$g5_payload" >/dev/null 2>"$g5_root/stderr"
g5_rc=$?
set -e
g5_target="$g5_root/.deep-review/lenses/run-g5/logic.1.jsonl"
if [[ $g5_rc -ne 0 ]]; then
	fail "(G5) --json-file must be accepted (exit $g5_rc)"
	sed 's/^/    /' "$g5_root/stderr"
elif [[ "$(jq -r '.type' "$g5_target" 2>/dev/null)" != "start" ]] ||
	[[ "$(jq -c '.units' "$g5_target" 2>/dev/null)" != '["u1","u2"]' ]]; then
	fail "(G5) --json-file wrote the wrong line: $(cat "$g5_target" 2>/dev/null)"
else
	pass "(G5) --json-file writes the same line --json-stdin would"
fi

# Parity: --json-file and --json-stdin must produce byte-identical lines
# apart from the timestamp, i.e. they share every gate and the serializer.
set +e
printf '%s' '{"type":"start","units":["u1","u2"]}' |
	bash "$SCRIPT" --root "$g5_root" --skill deep-review --run-id run-g5 \
		--lens logic --attempt 2 --json-stdin >/dev/null 2>&1
set -e
g5_stdin_target="$g5_root/.deep-review/lenses/run-g5/logic.2.jsonl"
g5_a="$(jq -Sc 'del(.ts, .attempt)' "$g5_target" 2>/dev/null || true)"
g5_b="$(jq -Sc 'del(.ts, .attempt)' "$g5_stdin_target" 2>/dev/null || true)"
if [[ -n "$g5_a" && "$g5_a" == "$g5_b" ]]; then
	pass "(G5) --json-file and --json-stdin serialize identically (shared gates and serializer)"
else
	fail "(G5) transport parity broke: file='$g5_a' stdin='$g5_b'"
fi

# Two concatenated objects are rejected on the FILE transport too -- the
# one-object shape gate is shared, not re-implemented.
printf '%s' '{"type":"start"} {"type":"start"}' >"$g5_root/two.json"
set +e
bash "$SCRIPT" --root "$g5_root" --skill deep-review --run-id run-g5 \
	--lens logic --attempt 3 --json-file "$g5_root/two.json" >/dev/null 2>&1
g5_two_rc=$?
set -e
if [[ $g5_two_rc -eq 2 ]] && [[ ! -e "$g5_root/.deep-review/lenses/run-g5/logic.3.jsonl" ]]; then
	pass "(G5) two concatenated objects in --json-file exit 2 with no byte written"
else
	fail "(G5) two-object --json-file: rc=$g5_two_rc (expected 2), file exists=$([[ -e "$g5_root/.deep-review/lenses/run-g5/logic.3.jsonl" ]] && echo yes || echo no)"
fi

# --json-file with --json-stdin is a caller bug, not last-wins.
set +e
bash "$SCRIPT" --root "$g5_root" --skill deep-review --run-id run-g5 \
	--lens logic --attempt 4 --json-file "$g5_payload" --json-stdin </dev/null >/dev/null 2>&1
g5_both_rc=$?
bash "$SCRIPT" --root "$g5_root" --skill deep-review --run-id run-g5 \
	--lens logic --attempt 5 --json-file "$g5_root/absent.json" >/dev/null 2>&1
g5_absent_rc=$?
set -e
if [[ $g5_both_rc -eq 2 && $g5_absent_rc -eq 2 ]]; then
	pass "(G5) --json-file with --json-stdin exits 2; an unreadable --json-file exits 2"
else
	fail "(G5) both-flags rc=$g5_both_rc, unreadable rc=$g5_absent_rc (both must be 2)"
fi
# ---------------------------------------------------------------------------
# Group R4-G3 — writer/reader unit-validation parity (F3), and the comma rule
# scoped to the wire that actually needs it.
#
# A unit is a STRING, not a CSV field. On the JSON transports (--json-stdin,
# --json-file) `units` is a JSON array and a comma inside an element is not a
# separator, so it must round-trip. On the `--units <csv>` argv spelling the
# comma IS the separator and keeps splitting. And `--unit` now goes through
# persist_validate_unit (the ARGV rules; it owns no other wire), which closes the missing
# leading-`-` rule (persist_require_value only checks arity, so `--unit -foo`
# was accepted).
# ---------------------------------------------------------------------------

r4g3_root="$TMPDIR_ROOT/r4g3p"
mkdir -p "$r4g3_root"
(
	cd "$r4g3_root"
	git init -q
	git config user.email "t@example.com"
	git config user.name "T"
	echo x >README.md
	git add README.md
	git commit -q -m init
)

# A comma-bearing unit on the JSON transport round-trips as ONE element.
printf '%s' '{"type":"start","units":["a,b","c"]}' >"$r4g3_root/start.json"
set +e
bash "$SCRIPT" --root "$r4g3_root" --skill deep-review --run-id r4g3p \
	--lens logic --attempt 1 --json-file "$r4g3_root/start.json" >/dev/null 2>&1
r4g3_start_rc=$?
set -e
r4g3_units="$(jq -c '.units' "$r4g3_root/.deep-review/lenses/r4g3p/logic.1.jsonl" 2>/dev/null || true)"
if [[ "$r4g3_start_rc" -eq 0 && "$r4g3_units" == '["a,b","c"]' ]]; then
	pass "(R4-G3) a comma-bearing unit on --json-file is stored as ONE element"
else
	fail "(R4-G3) comma unit on --json-file: rc=$r4g3_start_rc units=$r4g3_units"
fi

# A control character (a literal newline) in a JSON-transport unit survives.
jq -n -c '{type:"start",units:["a\nb"]}' >"$r4g3_root/ctl.json"
set +e
bash "$SCRIPT" --root "$r4g3_root" --skill deep-review --run-id r4g3p \
	--lens ctl --attempt 1 --json-file "$r4g3_root/ctl.json" >/dev/null 2>&1
r4g3_ctl_rc=$?
set -e
r4g3_ctl_units="$(jq -c '.units' "$r4g3_root/.deep-review/lenses/r4g3p/ctl.1.jsonl" 2>/dev/null || true)"
if [[ "$r4g3_ctl_rc" -eq 0 && "$r4g3_ctl_units" == '["a\nb"]' ]]; then
	pass "(R4-G3) a control-character unit on --json-file survives verbatim"
else
	fail "(R4-G3) control-char unit: rc=$r4g3_ctl_rc units=$r4g3_ctl_units"
fi

# The argv CSV spelling still splits on commas -- it is that wire's format.
set +e
bash "$SCRIPT" --root "$r4g3_root" --skill deep-review --run-id r4g3p \
	--lens csv --attempt 1 --type start --units 'a,b' >/dev/null 2>&1
r4g3_csv_rc=$?
set -e
r4g3_csv_units="$(jq -c '.units' "$r4g3_root/.deep-review/lenses/r4g3p/csv.1.jsonl" 2>/dev/null || true)"
if [[ "$r4g3_csv_rc" -eq 0 && "$r4g3_csv_units" == '["a","b"]' ]]; then
	pass "(R4-G3) --units 'a,b' still splits into two units on argv"
else
	fail "(R4-G3) argv CSV split regressed: rc=$r4g3_csv_rc units=$r4g3_csv_units"
fi

# Writer parity gap (F3): `--unit -foo` reached the wire because
# persist_require_value only checks arity. It now goes through
# persist_validate_unit (the ARGV rules; it owns no other wire), which rejects a leading `-`.
set +e
bash "$SCRIPT" --root "$r4g3_root" --skill deep-review --run-id r4g3p \
	--lens logic --attempt 1 --type progress --unit -foo >/dev/null 2>&1
r4g3_dash_rc=$?
set -e
if [[ "$r4g3_dash_rc" -eq 2 ]]; then
	pass "(R4-G3/F3) --unit -foo exits 2 (leading-dash rule now applies to the writer)"
else
	fail "(R4-G3/F3) --unit -foo must exit 2, got rc=$r4g3_dash_rc"
fi

# ...and the shell-metachar half of the argv blacklist reaches --unit too.
set +e
bash "$SCRIPT" --root "$r4g3_root" --skill deep-review --run-id r4g3p \
	--lens logic --attempt 1 --type progress --unit 'src/$(id).ts' >/dev/null 2>&1
r4g3_meta_rc=$?
set -e
if [[ "$r4g3_meta_rc" -eq 2 ]]; then
	pass "(R4-G3/F3) a shell-metachar --unit exits 2 on the argv transport"
else
	fail "(R4-G3/F3) metachar --unit must exit 2, got rc=$r4g3_meta_rc"
fi

# ...but the SAME value is legitimate on the JSON transport, which never
# passes through a shell. This is the asymmetry the parity fix preserves.
jq -n -c '{type:"progress",unit:"src/$(id).ts"}' >"$r4g3_root/meta.json"
set +e
bash "$SCRIPT" --root "$r4g3_root" --skill deep-review --run-id r4g3p \
	--lens meta --attempt 1 --json-file "$r4g3_root/meta.json" >/dev/null 2>&1
r4g3_metaok_rc=$?
set -e
if [[ "$r4g3_metaok_rc" -eq 0 ]]; then
	pass "(R4-G3/F3) the same metachar unit is accepted on the --json-file transport"
else
	fail "(R4-G3/F3) metachar unit on --json-file must succeed, got rc=$r4g3_metaok_rc"
fi

# ---------------------------------------------------------------------------
# Group R4-G4 (F12) — --json-file gets the same symlink guard every other
# repo-rooted state path already has. The guard depends on WHAT the path is,
# not WHICH FLAG carried it: an out-of-tree payload file stays legal.
# ---------------------------------------------------------------------------

mkdir -p "$r4g3_root/real"
printf '%s' '{"type":"done","status":"completed"}' >"$r4g3_root/real/payload.json"
ln -s "$r4g3_root/real/payload.json" "$r4g3_root/linked-payload.json"
set +e
bash "$SCRIPT" --root "$r4g3_root" --skill deep-review --run-id r4g3p \
	--lens logic --attempt 1 --json-file "$r4g3_root/linked-payload.json" >/dev/null 2>&1
r4g4_link_rc=$?
set -e
if [[ "$r4g4_link_rc" -eq 2 ]]; then
	pass "(R4-G4/F12) a symlinked --json-file inside the root exits 2"
else
	fail "(R4-G4/F12) symlinked --json-file must exit 2, got rc=$r4g4_link_rc"
fi

r4g4_ext="$TMPDIR_ROOT/outside-payload.json"
printf '%s' '{"type":"done","status":"completed"}' >"$r4g4_ext"
set +e
bash "$SCRIPT" --root "$r4g3_root" --skill deep-review --run-id r4g3p \
	--lens ext --attempt 1 --json-file "$r4g4_ext" >/dev/null 2>&1
r4g4_ext_rc=$?
set -e
if [[ "$r4g4_ext_rc" -eq 0 ]]; then
	pass "(R4-G4/control) an out-of-tree --json-file is still accepted"
else
	fail "(R4-G4/control) out-of-tree --json-file broke (rc=$r4g4_ext_rc)"
fi

# ---------------------------------------------------------------------------
# Group R5-G1 — the argv CSV transport has ONE splitter, and its elements go
# through the argv unit rules.
#
# `--units` split in jq and validated with the FILE-wire gate only, so
# `--units '-foo'` and `--units 'src/$(id).ts'` were accepted by the writer
# and rejected by the reader; and `--units $'a\nb'` aborted `jq -R` with the
# wrong exit code (1, the "append failed" code, instead of 2, the usage code).
# ---------------------------------------------------------------------------

r5_root="$TMPDIR_ROOT/r5"
mkdir -p "$r5_root"
(
	cd "$r5_root"
	git init -q
	git config user.email "t@example.com"
	git config user.name "T"
	echo x >README.md
	git add README.md
	git commit -q -m init
)
COLLECT="$REPO_ROOT/scripts/collect-lens-results.sh"

# r5_write <lens> <args...> -- one writer invocation, exit code on stdout.
r5_write() {
	local lens="$1"
	shift
	set +e
	bash "$SCRIPT" --root "$r5_root" --skill deep-review --run-id r5 \
		--lens "$lens" --attempt 1 "$@" >/dev/null 2>&1
	local rc=$?
	set -e
	printf '%s' "$rc"
}

r5g1_dash_rc="$(r5_write dash --type start --units '-foo,src/$(id).ts')"
if [[ "$r5g1_dash_rc" -eq 2 ]]; then
	pass "(R5-G1) --units applies the argv unit rules (leading dash / shell metachar -> exit 2)"
else
	fail "(R5-G1) --units '-foo,src/\$(id).ts' must exit 2, got rc=$r5g1_dash_rc"
fi

r5g1_nl_rc="$(r5_write nl --type start --units "$(printf 'a\nb')")"
if [[ "$r5g1_nl_rc" -eq 2 ]]; then
	pass "(R5-G1) a newline in --units is a USAGE error (exit 2), not a jq abort (exit 1)"
else
	fail "(R5-G1) --units \$'a\\nb' must exit 2, got rc=$r5g1_nl_rc"
fi

r5g1_ok_rc="$(r5_write okcsv --type start --units 'a,b')"
r5g1_ok_units="$(jq -c '.units' "$r5_root/.deep-review/lenses/r5/okcsv.1.jsonl" 2>/dev/null || true)"
if [[ "$r5g1_ok_rc" -eq 0 && "$r5g1_ok_units" == '["a","b"]' ]]; then
	pass "(R5-G1/control) --units 'a,b' still yields exactly [\"a\",\"b\"]"
else
	fail "(R5-G1/control) rc=$r5g1_ok_rc units=$r5g1_ok_units"
fi

# The invariant itself: writer and reader accept and reject the SAME CSV.
r5g1_parity_ok=1
r5g1_table=""
r5g1_i=0
for r5g1_csv in 'a,b' 'a,b,' 'a,,b' '-foo' "$(printf 'a\nb')"; do
	r5g1_i=$((r5g1_i + 1))
	r5g1_w="$(r5_write "parity$r5g1_i" --type start --units "$r5g1_csv")"
	set +e
	(cd "$r5_root" && bash "$COLLECT" --root "$r5_root" --skill deep-review \
		--run-id r5collect --expected "logic:$r5g1_csv" >/dev/null 2>&1)
	r5g1_r=$?
	set -e
	r5g1_table="$r5g1_table  csv=$(printf '%q' "$r5g1_csv") writer=$r5g1_w reader=$r5g1_r"$'\n'
	[[ "$r5g1_w" -eq "$r5g1_r" ]] || r5g1_parity_ok=0
done
if [[ "$r5g1_parity_ok" -eq 1 ]]; then
	pass "(R5-G1) writer and reader agree about the same --units/--expected CSV"
else
	fail "(R5-G1) writer/reader CSV disagreement:"$'\n'"$r5g1_table"
fi

# ---------------------------------------------------------------------------
# Group R5-G2 — --json-file symlink refusal does not depend on the spelling.
# ---------------------------------------------------------------------------

mkdir -p "$r5_root/real"
printf '%s' '{"type":"done","status":"completed"}' >"$r5_root/real/payload.json"
ln -s "$r5_root/real/payload.json" "$r5_root/rel-linked.json"
set +e
(cd "$r5_root" && bash "$SCRIPT" --root "$r5_root" --skill deep-review --run-id r5 \
	--lens relabs --attempt 1 --json-file "$r5_root/rel-linked.json" >/dev/null 2>&1)
r5g2_abs_rc=$?
(cd "$r5_root" && bash "$SCRIPT" --root "$r5_root" --skill deep-review --run-id r5 \
	--lens relrel --attempt 1 --json-file "rel-linked.json" >/dev/null 2>&1)
r5g2_rel_rc=$?
set -e
if [[ "$r5g2_abs_rc" -eq 2 && "$r5g2_rel_rc" -eq 2 ]]; then
	pass "(R5-G2) a symlinked --json-file is refused through the absolute AND the relative spelling"
else
	fail "(R5-G2) spelling-dependent guard: absolute rc=$r5g2_abs_rc, relative rc=$r5g2_rel_rc (both must be 2)"
fi

# ---------------------------------------------------------------------------
# Group R5-G3 — assign-then-report parity: every unit the ASSIGNMENT side
# accepts must be REPORTABLE, and every unit it rejects must be unreportable.
# The NUL row is the one that was broken: assignable, never reportable.
# ---------------------------------------------------------------------------

r5g3_matrix_ok=1
r5g3_rows=""
r5g3_j=0
r5g3_check() { # <label> <units-json-array> <unit-json-string> <expected-rc>
	local label="$1" arr="$2" unit="$3" want="$4"
	r5g3_j=$((r5g3_j + 1))
	local ef="$r5_root/r5g3-$r5g3_j.json"
	jq -n -c --argjson u "$arr" '{logic:$u}' >"$ef"
	set +e
	(cd "$r5_root" && bash "$COLLECT" --root "$r5_root" --skill deep-review \
		--run-id r5g3 --expected-file "$ef" >/dev/null 2>&1)
	local assign_rc=$?
	jq -n -c --argjson v "$unit" '{type:"progress",unit:$v}' >"$r5_root/r5g3-p-$r5g3_j.json"
	bash "$SCRIPT" --root "$r5_root" --skill deep-review --run-id r5g3 \
		--lens "rep$r5g3_j" --attempt 1 --json-file "$r5_root/r5g3-p-$r5g3_j.json" >/dev/null 2>&1
	local report_rc=$?
	set -e
	r5g3_rows="$r5g3_rows  $label: assign=$assign_rc report=$report_rc want=$want"$'\n'
	[[ "$assign_rc" -eq "$want" && "$report_rc" -eq "$want" ]] || r5g3_matrix_ok=0
}
r5g3_check comma '["a,b"]' '"a,b"' 0
r5g3_check newline '["a\nb"]' '"a\nb"' 0
r5g3_check leading-dash '["-foo"]' '"-foo"' 0
r5g3_check NUL '["a\u0000b"]' '"a\u0000b"' 2
if [[ "$r5g3_matrix_ok" -eq 1 ]]; then
	pass "(R5-G3) assign/report parity holds for every row of the unit matrix (NUL rejected on BOTH sides)"
else
	fail "(R5-G3) assign/report parity broken:"$'\n'"$r5g3_rows"
fi

# ---------------------------------------------------------------------------
# Group R6-G5 — persist_validate_unit is an ARGV validator and its SIGNATURE
# says so. R5-G6 removed the `file` arm, which left a <source> parameter with
# exactly one legal value: a parameter expressing no choice, whose only job
# was rejecting a word nothing meant any more, and which invited a future
# reader to conclude another wire existed. This replaces that case: the
# parameter is gone, and the argv rules are UNCONDITIONALLY in force.
# ---------------------------------------------------------------------------

r6g5_src() {
	bash -c '. "$1/scripts/lib/auto-fix-common.sh"; . "$1/scripts/lib/persist-common.sh"; shift; persist_validate_unit "$@"' _ "$REPO_ROOT" "$@" 2>&1
}
set +e
r6g5_ok_out="$(r6g5_src x label)"
r6g5_ok_rc=$?
r6g5_bad_out="$(r6g5_src -x label)"
r6g5_bad_rc=$?
set -e
r6g5_sig="$(grep -n '^# persist_validate_unit <value> <label>$' "$REPO_ROOT/scripts/lib/persist-common.sh" || true)"
r6g5_locals="$(grep -c 'local value="\$1" label="\$2"$' "$REPO_ROOT/scripts/lib/persist-common.sh" || true)"
r6g5_why=""
[[ "$r6g5_ok_rc" -eq 0 ]] || r6g5_why="$r6g5_why two-arg-call-rc=$r6g5_ok_rc($r6g5_ok_out)"
[[ "$r6g5_bad_rc" -eq 2 && "$r6g5_bad_out" == *"must not start with '-'"* ]] ||
	r6g5_why="$r6g5_why argv-rules-not-in-force(rc=$r6g5_bad_rc out='$r6g5_bad_out')"
[[ -n "$r6g5_sig" ]] || r6g5_why="$r6g5_why signature-still-takes-<source>"
[[ "$r6g5_locals" -eq 1 ]] || r6g5_why="$r6g5_why body-still-binds-a-third-param"
if [[ -z "$r6g5_why" ]]; then
	pass "(R6-G5a) persist_validate_unit takes exactly <value> <label>, and the argv rules are unconditional"
else
	fail "(R6-G5a)$r6g5_why"
fi

# ---------------------------------------------------------------------------
# Group R5-G7 — the writer's HEADER states the contract the code ships.
#
# r4 reversed the unit contract in code and updated the collector's doctrine
# block and the shared gate's header, but not this script's own header, which
# went on describing comma-joined unit lists. Comment drift survives every
# behavioural test in this suite, so it needs its own assertion.
# ---------------------------------------------------------------------------

r5g7_header="$(awk '/^set -euo pipefail/{exit} {print}' "$SCRIPT")"
r5g7_ok=1
r5g7_why=""
for r5g7_stale in 'must not contain commas' 'comma-joined'; do
	if printf '%s' "$r5g7_header" | grep -Fq -- "$r5g7_stale"; then
		r5g7_ok=0
		r5g7_why="$r5g7_why stale:'$r5g7_stale'"
	fi
done
if ! printf '%s' "$r5g7_header" | grep -Fq -- 'PERSIST_UNIT_JQ_GATE'; then
	r5g7_ok=0
	r5g7_why="$r5g7_why missing:PERSIST_UNIT_JQ_GATE"
fi
if [[ "$r5g7_ok" -eq 1 ]]; then
	pass "(R5-G7) the header's unit contract matches the code (no comma-joined doctrine; the wire gate is named)"
else
	fail "(R5-G7) header/code contract drift:$r5g7_why"
fi

# ---------------------------------------------------------------------------
# Group R6-G2 — a containment decision must not depend on the CWD's spelling
# either.
#
# Round 5 absolutised a relative <path> against `$PWD`. `$PWD` is the LOGICAL
# cwd: started from a symlinked directory alias it keeps the alias, while
# `--root` (typically `git rev-parse --show-toplevel`) is PHYSICAL. The
# lexical prefix match then failed, persist_path_is_inside_root answered
# "outside", and BOTH callers skipped af_assert_no_symlink entirely --
# fail-OPEN on exactly the in-tree path the guard exists to protect.
# ---------------------------------------------------------------------------

r6g2_base="$TMPDIR_ROOT/r6g2"
mkdir -p "$r6g2_base/repo/sub" "$r6g2_base/outside"
r6g2_phys="$(cd "$r6g2_base/repo" && pwd -P)"
printf '%s' '{"type":"done","status":"completed"}' >"$r6g2_base/outside/payload.json"
ln -s "$r6g2_base/outside/payload.json" "$r6g2_base/repo/rel-link.json"
ln -s "$r6g2_base/repo" "$r6g2_base/cwd-link"

set +e
r6g2a_err="$(cd "$r6g2_base/cwd-link" && bash "$SCRIPT" --root "$r6g2_phys" \
	--skill deep-review --run-id r6g2 --lens logic --attempt 1 \
	--json-file rel-link.json 2>&1 >/dev/null)"
r6g2a_rc=$?
set -e
if [[ "$r6g2a_rc" -eq 2 && "$r6g2a_err" == *"symlink"* ]] && no_jsonl_anywhere "$r6g2_base/repo"; then
	pass "(R6-G2a) a symlinked --json-file is still guarded when the cwd is a symlinked alias of the root"
else
	fail "(R6-G2a) cwd-spelling-dependent guard: rc=$r6g2a_rc err='$r6g2a_err'"
fi

# R6-G2c — the containment table itself, asserted directly, from BOTH the
# physical and the symlinked spelling of the same cwd. The out-of-tree row is
# what keeps the platform-symlink false refusal from coming back.
r6g2c_probe() {
	# <cwd> <path> <root> -> prints "inside" or "outside"
	bash -c '
		cd "$1" || exit 9
		. "$4/scripts/lib/auto-fix-common.sh"
		. "$4/scripts/lib/persist-common.sh"
		if persist_path_is_inside_root "$2" "$3"; then echo inside; else echo outside; fi
	' _ "$1" "$2" "$3" "$REPO_ROOT"
}
r6g2c_rows=""
for r6g2c_cwd in "$r6g2_phys" "$r6g2_base/cwd-link"; do
	r6g2c_check() {
		local got
		got="$(r6g2c_probe "$r6g2c_cwd" "$1" "$2")"
		[[ "$got" == "$3" ]] || r6g2c_rows="$r6g2c_rows"$'\n'"  cwd=$r6g2c_cwd path='$1' root='$2' expected=$3 got=$got"
	}
	r6g2c_check "sub/x.json" "$r6g2_phys" inside
	r6g2c_check "sub/x.json" "." inside
	r6g2c_check "/etc/passwd" "$r6g2_phys" outside
	r6g2c_check "$r6g2_phys/sub/x.json" "$r6g2_phys" inside
	r6g2c_check "../x" "$r6g2_phys" inside
	r6g2c_check "$r6g2_base/outside/payload.json" "$r6g2_phys" outside
done
if [[ -z "$r6g2c_rows" ]]; then
	pass "(R6-G2c) persist_path_is_inside_root answers identically from the physical and the symlinked cwd"
else
	fail "(R6-G2c) containment table mismatch:$r6g2c_rows"
fi

# ---------------------------------------------------------------------------
# Group R7-G3 — the ABSOLUTE branch of persist_path_is_inside_root needs a
# physical spelling too (round 7, F5).
#
# Round 6 fixed the RELATIVE branch only. An in-root file named by an
# ABSOLUTE path running through a symlinked directory alias prefix-matched
# nothing against a physical --root, the predicate answered "outside", and
# BOTH r4 file-transport guards were skipped entirely. Same fail-open, same
# guard, different spelling.
# ---------------------------------------------------------------------------

r7g3_alias="$r6g2_base/cwd-link"
r7g3_alias_pwd="$(cd "$r7g3_alias" && printf '%s' "$PWD")"

# R7-G3a — the three spellings of ONE in-root file must all answer "inside".
r7g3a_rows=""
r7g3a_check() {
	local got
	got="$(r6g2c_probe "$r7g3_alias" "$1" "$r6g2_phys")"
	[[ "$got" == "inside" ]] || r7g3a_rows="$r7g3a_rows"$'\n'"  path='$1' expected=inside got=$got"
}
r7g3a_check "sub/x.json"
r7g3a_check "$r7g3_alias_pwd/sub/x.json"
r7g3a_check "$r6g2_phys/sub/x.json"
if [[ -z "$r7g3a_rows" ]]; then
	pass "(R7-G3a) relative, alias-absolute and physical-absolute spellings of one in-root file all answer 'inside'"
else
	fail "(R7-G3a) absolute alias spelling is not guarded:$r7g3a_rows"
fi

# R7-G3b — end-to-end: an ABSOLUTE --json-file spelled through the cwd alias,
# whose parent is a symlink OUT of the repo, must be refused. On 470c636 the
# scope predicate answered "outside" and the payload was read and persisted.
mkdir -p "$r6g2_base/outside/esc"
printf '%s' '{"type":"done","status":"completed"}' >"$r6g2_base/outside/esc/payload.json"
ln -s "$r6g2_base/outside/esc" "$r6g2_base/repo/esclink"
set +e
r7g3b_err="$(cd "$r7g3_alias" && bash "$SCRIPT" --root "$r6g2_phys" \
	--skill deep-review --run-id r7g3 --lens logic --attempt 1 \
	--json-file "$r7g3_alias_pwd/esclink/payload.json" 2>&1 >/dev/null)"
r7g3b_rc=$?
set -e
if [[ "$r7g3b_rc" -eq 2 && "$r7g3b_err" == *"symlink"* ]]; then
	pass "(R7-G3b) an ABSOLUTE --json-file spelled through the cwd alias, with a symlinked parent, is refused"
else
	fail "(R7-G3b) rc=$r7g3b_rc err='$r7g3b_err'"
fi

# R7-G3c/control — a genuinely out-of-tree fixture still answers "outside"
# and is still accepted: no false refusal, no platform-symlink regression.
r7g3c_rows=""
for r7g3c_cwd in "$r6g2_phys" "$r7g3_alias"; do
	r7g3c_got="$(r6g2c_probe "$r7g3c_cwd" "$r6g2_base/outside/payload.json" "$r6g2_phys")"
	[[ "$r7g3c_got" == "outside" ]] || r7g3c_rows="$r7g3c_rows [cwd=$r7g3c_cwd got=$r7g3c_got]"
done
set +e
(cd "$r7g3_alias" && bash "$SCRIPT" --root "$r6g2_phys" \
	--skill deep-review --run-id r7g3c --lens logic --attempt 1 \
	--json-file "$r6g2_base/outside/payload.json") >/dev/null 2>&1
r7g3c_rc=$?
set -e
if [[ -z "$r7g3c_rows" && "$r7g3c_rc" -eq 0 ]]; then
	pass "(R7-G3c/control) an out-of-tree fixture still answers 'outside' from both cwd spellings and is still accepted"
else
	fail "(R7-G3c/control) rows:$r7g3c_rows accept_rc=$r7g3c_rc"
fi

# ---------------------------------------------------------------------------
# Group R7-G4 — the duplicate-key rule is a WIRE rule, enforced on both sides.
#
# The reader (collect-lens-results.sh --expected-file) has refused a repeated
# object key since round 6; the WRITER accepted it, so `units` spelled twice
# was silently collapsed to the last occurrence on the same transport. A rule
# that holds on one side of a wire only is not a wire rule.
# ---------------------------------------------------------------------------

r7g4_base="$TMPDIR_ROOT/r7g4"
mkdir -p "$r7g4_base"
set +e
r7g4e_err="$(printf '%s' '{"type":"start","units":["a"],"units":["b"]}' |
	bash "$SCRIPT" --root "$r7g4_base" --skill deep-review --run-id r7g4 \
		--lens logic --attempt 1 --json-stdin 2>&1 >/dev/null)"
r7g4e_rc=$?
set -e
if [[ "$r7g4e_rc" -eq 2 && "$r7g4e_err" == *"duplicate key"* && "$r7g4e_err" == *"units"* ]] &&
	no_jsonl_anywhere "$r7g4_base"; then
	pass "(R7-G4e) a --json-stdin payload spelling 'units' twice exits 2, NAMES the duplicated key, and persists nothing"
else
	fail "(R7-G4e) rc=$r7g4e_rc err='$r7g4e_err'"
fi

# R7-G4f/control — the same payload with ONE `units` key is unchanged.
set +e
printf '%s' '{"type":"start","units":["a","b"]}' |
	bash "$SCRIPT" --root "$r7g4_base" --skill deep-review --run-id r7g4f \
		--lens logic --attempt 1 --json-stdin >/dev/null 2>&1
r7g4f_rc=$?
set -e
if [[ "$r7g4f_rc" -eq 0 ]] && ! no_jsonl_anywhere "$r7g4_base"; then
	pass "(R7-G4f/control) the same payload with a single 'units' key still persists normally"
else
	fail "(R7-G4f/control) rc=$r7g4f_rc"
fi

# ---------------------------------------------------------------------------
# R8-G3e — the writer half of the EVENT-COUNT rule (round 8, F6).
#
# R7-G4e's payload (`{"units":["a"],"units":["b"]}`) shares the leaf paths
# ["units",0] between its two assignments, which is the only reason the round-7
# path-comparison rule caught it. Disjoint value shapes shared nothing and
# passed: `{"units":["x","y"],"units":[]}` persisted at a970c3a with the two
# real units dropped.
r8g3_base="$TMPDIR_ROOT/r8g3"
mkdir -p "$r8g3_base"
set +e
r8g3e_err="$(printf '%s' '{"type":"start","units":["x","y"],"units":[]}' |
	bash "$SCRIPT" --root "$r8g3_base" --skill deep-review --run-id r8g3 \
		--lens logic --attempt 1 --json-stdin 2>&1 >/dev/null)"
r8g3e_rc=$?
set -e
if [[ "$r8g3e_rc" -eq 2 && "$r8g3e_err" == *"duplicate key"* && "$r8g3e_err" == *"units"* ]] &&
	no_jsonl_anywhere "$r8g3_base"; then
	pass "(R8-G3e) a --json-stdin payload whose duplicate 'units' assignments have DISJOINT shapes exits 2, names the key, and persists nothing"
else
	fail "(R8-G3e) rc=$r8g3e_rc err='$r8g3e_err'"
fi

# ---------------------------------------------------------------------------
# (R9-G5a) F8 -- the one-document/object rule is a WIRE rule, so the writer
# must reject through the SHARED helper the reader uses, not through a
# hand-rolled copy with its own diagnostic. Two implementations of one rule is
# the defect; the observable symptom is two different messages for the same
# rejection. Asserting the HELPER's wording is what makes the single
# implementation checkable rather than asserted.
# ---------------------------------------------------------------------------
r9g5a_root="$TMPDIR_ROOT/r9g5a"
mkdir -p "$r9g5a_root"

set +e
r9g5a_multi_err="$(printf '%s' '{"type":"start"} {"type":"done"}' |
	bash "$SCRIPT" --root "$r9g5a_root" --skill deep-review --run-id run-r9g5a \
		--lens logic --attempt 1 --json-stdin 2>&1 >/dev/null)"
r9g5a_multi_rc=$?
r9g5a_arr_err="$(printf '%s' '[{"type":"start"}]' |
	bash "$SCRIPT" --root "$r9g5a_root" --skill deep-review --run-id run-r9g5a \
		--lens logic --attempt 1 --json-stdin 2>&1 >/dev/null)"
r9g5a_arr_rc=$?
set -e

if [[ "$r9g5a_multi_rc" -eq 2 && "$r9g5a_arr_rc" -eq 2 &&
	"$r9g5a_multi_err" == *"must be exactly one JSON document"* &&
	"$r9g5a_arr_err" == *"must be a JSON object"* ]] &&
	no_jsonl_anywhere "$r9g5a_root"; then
	pass "(R9-G5a) the writer's shape gate is persist_validate_json_shape -- both rejections carry the SHARED helper's wording and persist nothing"
else
	fail "(R9-G5a) multi rc=$r9g5a_multi_rc err='$r9g5a_multi_err'; array rc=$r9g5a_arr_rc err='$r9g5a_arr_err'"
fi

# ---------------------------------------------------------------------------
# (R9-G5b) F9 -- the writer must COMPOSE the attempt directory with
# persist_lens_run_dir, the same helper the reader (collect-lens-results.sh)
# uses, not by re-spelling `<lenses_dir>/$RUN_ID` inline. Derive the expected
# path by calling the helper directly and assert it equals what the writer
# PRINTS on stdout: this fails the moment the helper's body changes and the
# writer does not follow -- the silent-divergence class that makes the
# collector report every lens `missing`.
# ---------------------------------------------------------------------------
r9g5b_root="$TMPDIR_ROOT/r9g5b"
mkdir -p "$r9g5b_root"

r9g5b_written="$(printf '%s' '{"type":"start","units":["u1"]}' |
	bash "$SCRIPT" --root "$r9g5b_root" --skill deep-review --run-id run-r9g5b \
		--lens logic --attempt 3 --json-stdin)"
r9g5b_expected="$(
	# shellcheck source=/dev/null
	. "$REPO_ROOT/scripts/lib/auto-fix-common.sh"
	# shellcheck source=/dev/null
	. "$REPO_ROOT/scripts/lib/persist-common.sh"
	printf '%s/%s\n' \
		"$(persist_lens_run_dir "$r9g5b_root" deep-review run-r9g5b)" \
		"logic.3.jsonl"
)"

if [[ -n "$r9g5b_written" && "$r9g5b_written" == "$r9g5b_expected" && -f "$r9g5b_expected" ]]; then
	pass "(R9-G5b) the writer's attempt path is persist_lens_run_dir's output -- writer and reader derive the same directory"
else
	fail "(R9-G5b) writer='$r9g5b_written' helper='$r9g5b_expected'"
fi

# ---------------------------------------------------------------------------
# (R10-E1a) F10 -- `jq -e .` reports the TRUTHINESS OF THE RESULT, not parse
# success: it exits 1 on the valid documents `false` and `null`, so the shape
# helper's first gate misdiagnosed them as "is not valid JSON" and they never
# reached the type gate that would have named the real problem. The verdict
# (reject, exit 2) was always right; only the reason was wrong. The gate now
# uses `jq empty`, which is non-zero iff parsing failed. `false` and `null`
# are the negative control -- they carry the wrong message before this fix.
# ---------------------------------------------------------------------------
r10e1a_root="$TMPDIR_ROOT/r10e1a"
mkdir -p "$r10e1a_root"

# <input> <expected substring in stderr>
r10e1a_cases=(
	'false|must be a JSON object'
	'null|must be a JSON object'
	'[]|must be a JSON object'
	'"x"|must be a JSON object'
	'{"a":1}{"b":2}|must be exactly one JSON document'
	'not json|is not valid JSON'
)

r10e1a_bad=""
for r10e1a_case in "${r10e1a_cases[@]}"; do
	r10e1a_input="${r10e1a_case%%|*}"
	r10e1a_want="${r10e1a_case##*|}"
	set +e
	r10e1a_err="$(printf '%s' "$r10e1a_input" |
		bash "$SCRIPT" --root "$r10e1a_root" --skill deep-review --run-id run-r10e1a \
			--lens logic --attempt 1 --json-stdin 2>&1 >/dev/null)"
	r10e1a_rc=$?
	set -e
	if [[ "$r10e1a_rc" -ne 2 ]]; then
		r10e1a_bad="$r10e1a_bad [$r10e1a_input: rc=$r10e1a_rc]"
	elif [[ "$r10e1a_err" != *"$r10e1a_want"* ]]; then
		r10e1a_bad="$r10e1a_bad [$r10e1a_input: want '$r10e1a_want' got '$r10e1a_err']"
	fi
done

if [[ -z "$r10e1a_bad" ]] && no_jsonl_anywhere "$r10e1a_root"; then
	pass "(R10-E1a) every parseable non-object is rejected as 'must be a JSON object' -- only unparseable input is 'is not valid JSON'"
else
	fail "(R10-E1a)$r10e1a_bad"
fi

finish
