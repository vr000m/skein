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
printf '%s' '{"type":"done","status":"completed","lens":"evil","attempt":99,"run_id":"other","skill":"review-plan","root":"/tmp/evil"}' |
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

# --- A11: a comma-bearing unit name is rejected at the boundary -----------
# Expected units reach the collector as a CSV (`--expected lens:a,b`), so a
# unit whose own name holds a comma is re-split downstream and its progress
# can never match -- the lens could never reach `completed`. Reject it here.
reject_payload "(A11) a comma-bearing 'units' element exits 2, nothing written" case-a11 \
	'{"type":"start","units":["a,b"]}'
# Positive control: the CSV spelling keeps its comma as the SEPARATOR, so
# `"a,b"` is two comma-free units and stays accepted.
a11b_root="$TMPDIR_ROOT/case-a11b"
mkdir -p "$a11b_root"
set +e
printf '%s' '{"type":"start","units":"a,b"}' |
	bash "$SCRIPT" --root "$a11b_root" --skill deep-review --run-id run-a11b \
		--lens logic --attempt 1 --json-stdin >/dev/null 2>"$a11b_root/stderr"
a11b_exit=$?
set -e
a11b_target="$a11b_root/.deep-review/lenses/run-a11b/logic.1.jsonl"
if [[ $a11b_exit -ne 0 ]]; then
	fail "(A11b) CSV 'units' string must still be accepted (exit $a11b_exit)"
	sed 's/^/    /' "$a11b_root/stderr"
elif [[ "$(jq -c '.units' "$a11b_target" 2>/dev/null)" != '["a","b"]' ]]; then
	fail "(A11b) CSV 'units' not split into two units: $(jq -c '.units' "$a11b_target" 2>/dev/null)"
else
	pass "(A11b) CSV 'units' comma is the separator, not a rejected character"
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

finish
