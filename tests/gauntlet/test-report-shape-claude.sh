#!/usr/bin/env bash
# test-report-shape-claude.sh — Phase 2 acceptance: static shape assertions on
# the Claude review-gauntlet and deep-review SKILL.md files for the opt-in
# `--report` flag.
#
# Plan: docs/dev_plans/20261008-feature-review-output-formats.md, Phase 2.
# A pure documentation/shape check, like test-gauntlet-skill-shape.sh: no
# runtime behaviour is exercised (test-render-report.sh does that).
#
# Exit codes: 0 all assertions pass, 1 any assertion fails.

# shellcheck disable=SC2016  # single-quoted literal grep patterns throughout, not shell expansions
set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
GAUNTLET="$ROOT_DIR/plugins/skein/skills/review-gauntlet/SKILL.md"
DEEP="$ROOT_DIR/plugins/skein/skills/deep-review/SKILL.md"

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

assert_eq() {
	if [[ "$1" == "$2" ]]; then
		pass "$3"
	else
		fail "$3 (expected '$2', got '$1')"
	fi
}

# count_fixed FILE NEEDLE — number of lines containing the fixed string.
count_fixed() {
	{ grep -cF -- "$2" "$1" || true; }
}

# count_re FILE ERE — number of lines matching the regex.
count_re() {
	{ grep -cE -- "$2" "$1" || true; }
}

# has FILE NEEDLE LABEL
has() {
	if grep -qF -- "$2" "$1"; then
		pass "$3"
	else
		fail "$3 (missing: $2)"
	fi
}

# lacks_re FILE ERE LABEL
lacks_re() {
	if grep -qE -- "$2" "$1"; then
		fail "$3 (matched /$2/)"
	else
		pass "$3"
	fi
}

# line_of FILE NEEDLE — first line number containing the fixed string, or 0.
line_of() {
	local n
	n="$(grep -nF -- "$2" "$1" | head -1 | cut -d: -f1 || true)"
	printf '%s' "${n:-0}"
}

# region FILE BEGIN_NEEDLE END_NEEDLE — the lines between two marker lines.
region() {
	awk -v b="$2" -v e="$3" 'index($0, e) { on = 0 } on { print } index($0, b) { on = 1 }' "$1"
}

for f in "$GAUNTLET" "$DEEP"; do
	if [[ ! -f "$f" ]]; then
		echo "FAIL: missing $f"
		exit 1
	fi
done

echo "== review-gauntlet: flag and gating =="
assert_eq "$(sed -n '1,8p' "$GAUNTLET" | grep -c 'argument-hint:.*--report' || true)" "1" "argument-hint lists --report"
has "$GAUNTLET" '`--report` is a rendering-mode modifier' "--report is documented as a rendering-mode modifier"
has "$GAUNTLET" 'Runs only when `--report` was passed.' "terminal report step is gated on --report"
has "$GAUNTLET" 'Without the flag this step does not exist: do nothing here and do not call the hook.' "no flag means no hook call"
has "$GAUNTLET" "does not forward \`--report\`" "conduct auto-chain does not forward --report"

echo "== review-gauntlet: REPORT STEP anchors enclose one Block B =="
assert_eq "$(count_fixed "$GAUNTLET" '<!-- BEGIN REPORT STEP -->')" "1" "exactly one BEGIN REPORT STEP anchor"
assert_eq "$(count_fixed "$GAUNTLET" '<!-- END REPORT STEP -->')" "1" "exactly one END REPORT STEP anchor"
b="$(line_of "$GAUNTLET" '<!-- BEGIN REPORT STEP -->')"
e="$(line_of "$GAUNTLET" '<!-- END REPORT STEP -->')"
if [[ "$b" -gt 0 && "$e" -gt "$b" ]]; then
	pass "REPORT STEP anchors are ordered BEGIN before END"
else
	fail "REPORT STEP anchors out of order (begin=$b end=$e)"
fi
assert_eq "$(count_fixed "$GAUNTLET" '<!-- BEGIN PROSE RULE BLOCK B -->')" "1" "exactly one Block B in the gauntlet (no duplicate)"
assert_eq "$(count_fixed "$GAUNTLET" '<!-- END PROSE RULE BLOCK B -->')" "1" "exactly one Block B end anchor"
inside="$(region "$GAUNTLET" '<!-- BEGIN REPORT STEP -->' '<!-- END REPORT STEP -->')"
assert_eq "$(printf '%s\n' "$inside" | grep -cF '<!-- BEGIN PROSE RULE BLOCK B -->' || true)" "1" "Block B sits inside the REPORT STEP anchors"
assert_eq "$(printf '%s\n' "$inside" | grep -cF '<!-- END PROSE RULE BLOCK B -->' || true)" "1" "Block B end anchor sits inside the REPORT STEP anchors"
has "$GAUNTLET" 'Report the terminal status, the gates passed' "terminal-status report text is the wrapped step"
assert_eq "$(printf '%s\n' "$inside" | grep -cF '### Terminal report step' || true)" "1" "the --report terminal step is inside the anchors"

echo "== review-gauntlet: gate 2 never receives --report =="
has "$GAUNTLET" 'This slot **never receives `--report`**' "gate 2 states it never receives --report"
lacks_re "$GAUNTLET" 'skein:deep-review( --verbose)? --report|skein:deep-review --report' "no deep-review invocation carries --report"
lacks_re "$GAUNTLET" 'skein:deep-review[^`]*`--report`[^.]*(pass|forward|append)' "no instruction forwards --report to deep-review"

echo "== review-gauntlet: error exits skip reporting =="
has "$GAUNTLET" '**Error exits skip it**' "error exits skip the report"
has "$GAUNTLET" 'a script error, an ambiguous ledger, a missing ledger on `--resume`, a guard refusal' "error-exit classes enumerated"
has "$GAUNTLET" 'success_with_quarantine`, `regression`, `cap`, `non-converge`' "all terminal tokens route through the step"
has "$GAUNTLET" 'resume/auto-chain exit-5 paths' "exit-5 terminal paths route through the step"

echo "== review-gauntlet: \$run_dir via one --run-dir call =="
assert_eq "$(count_re "$GAUNTLET" '^run_dir="\$\(.*convergence-ledger\.sh --run-dir --ledger "\$ledger_path"\)"$')" "1" "exactly one run_dir=\$(... --run-dir ...) definition"
assert_eq "$(count_re "$GAUNTLET" '^[[:space:]]*run_dir=')" "1" "run_dir is assigned exactly once"
has "$GAUNTLET" 'gate_out_dir="$run_dir/round-$round_n"' "gate dirs derive from \$run_dir"
has "$GAUNTLET" '`.gauntlet/<ledger-stem>/`' "run dir is documented as .gauntlet/<ledger-stem>/"
has "$GAUNTLET" 'it is idempotent and never deletes anything' "--run-dir documented idempotent and non-deleting"
has "$GAUNTLET" '<ledger-stem>.report.html' "sibling report path is guarded"
has "$GAUNTLET" '`round_n = <length of .rounds> + 1`' "resume derives round_n from the ledger rounds array"
lacks_re "$GAUNTLET" 'rm -rf[^`]*run_dir|rm -rf[^`]*ledger-stem' "no rm -rf of the run dir in skill prose"

echo "== review-gauntlet: hook call =="
assert_eq "$(count_re "$GAUNTLET" '^"\$\{CLAUDE_PLUGIN_ROOT\}"/skills/review-gauntlet/scripts/report-hook\.sh')" "1" "exactly one report-hook.sh invocation"
has "$GAUNTLET" '--out "$report_out" --ledger "$ledger_path"' "hook gets --out and --ledger"
has "$GAUNTLET" 'report_out="${ledger_path%.json}.report.html"' "report path sits beside the ledger"
has "$GAUNTLET" '--round 1="$run_dir/round-1/reconciled.json"' "rounds passed as --round N=<run_dir>/round-N/reconciled.json"
has "$GAUNTLET" "jq -r '.rounds | length' \"\$ledger_path\"" "rounds enumerated from the ledger, not globbed"
has "$GAUNTLET" 'The hook always exits 0' "hook exit-0 contract documented"
has "$GAUNTLET" 'the hook never calls `gh`' "gh resolution stays with the orchestrator"
has "$GAUNTLET" 'gh pr view <N> --json baseRefOid,headRefOid' "--pr diff scope resolved by the orchestrator via gh"
has "$GAUNTLET" 'If `${CLAUDE_PLUGIN_ROOT}/skills/review-gauntlet/scripts/report-hook.sh` is absent, warn and skip' "absent hook warns and skips"
lacks_re "$GAUNTLET" '\$SKILL_DIR' "Claude mirror uses CLAUDE_PLUGIN_ROOT, never SKILL_DIR"

echo "== deep-review: flag and input rules =="
assert_eq "$(sed -n '1,8p' "$DEEP" | grep -c 'argument-hint:.*--report' || true)" "1" "argument-hint lists --report"
for n in 2 4 5; do
	assert_eq "$(count_re "$DEEP" "^${n}\\. .*--report")" "1" "input rule $n lists --report"
done
has "$DEEP" '`--report` is also a rendering-mode modifier' "--report documented as a rendering-mode modifier"
has "$DEEP" 'Without `--report` the output is unchanged, and nothing in that step runs.' "default output is unchanged without --report"

echo "== deep-review: Step 3.5 audit redirect =="
has "$DEEP" '**With `--report` only:**' "audit capture is gated on --report"
has "$DEEP" 'report_envelope="$(mktemp "${TMPDIR:-/tmp}/skein-report-envelope.XXXXXX")"' "envelope scratch file comes from mktemp"
has "$DEEP" 'audit-auto-fix-eligibility.sh --skill deep-review <envelope> > "$report_envelope"' "audit stdout redirected to the scratch file"
has "$DEEP" '**outside** `.deep-review/`' "scratch file is outside .deep-review/"
has "$DEEP" 'Step 5.5 deletes it' "Step 3.5 hands cleanup to Step 5.5"
assert_eq "$(count_fixed "$DEEP" 'report_envelope="$(mktemp')" "1" "envelope scratch created exactly once"

echo "== deep-review: Step 5.5 =="
has "$DEEP" '### 5.5. Render the HTML Report (`--report` only)' "Step 5.5 heading present"
has "$DEEP" 'Without the flag this step does not exist: do not create scratch files and do not call the hook.' "Step 5.5 is gated on --report"
has "$DEEP" 'report_keys="$(mktemp "${TMPDIR:-/tmp}/skein-report-keys.XXXXXX")"' "keys scratch file comes from mktemp"
assert_eq "$(count_fixed "$DEEP" 'rm -f "$report_envelope" "$report_keys"')" "1" "both scratch files removed by one rm -f"
has "$DEEP" 'success or failure' "scratch removal covers failure too"
has "$DEEP" 'warn and skip the report, then still delete any scratch file created' "skip path still deletes scratch files"
assert_eq "$(count_re "$DEEP" '^[[:space:]]*"\$\{CLAUDE_PLUGIN_ROOT\}"/skills/deep-review/scripts/report-hook\.sh')" "1" "exactly one report-hook.sh invocation"
has "$DEEP" '--out "$REPO_ROOT/.deep-review/report-claude.html"' "report lands at .deep-review/report-claude.html"
has "$DEEP" '--envelope "$report_envelope" --suppress-keys "$report_keys"' "hook gets --envelope and --suppress-keys"
has "$DEEP" 'suppressed and auto-fixed findings omitted' "report label documented"
has "$DEEP" 'The hook always exits 0' "hook exit-0 contract documented"
lacks_re "$DEEP" '\$SKILL_DIR' "Claude mirror uses CLAUDE_PLUGIN_ROOT, never SKILL_DIR"
s55="$(line_of "$DEEP" '### 5.5. Render the HTML Report')"
s5="$(line_of "$DEEP" '### 5. Present Findings')"
if [[ "$s5" -gt 0 && "$s55" -gt "$s5" ]]; then
	pass "Step 5.5 follows Step 5"
else
	fail "Step 5.5 does not follow Step 5 (5=$s5 5.5=$s55)"
fi

echo "== deep-review: schema lockstep note outside the GENERIC block =="
lock="$(line_of "$DEEP" '**Schema lockstep (outside the GENERIC block):**')"
gend="$(line_of "$DEEP" '<!-- END GENERIC FINDING SCHEMA AND MERGE -->')"
if [[ "$lock" -gt 0 && "$gend" -gt 0 && "$lock" -gt "$gend" ]]; then
	pass "lockstep note sits after the GENERIC block end anchor"
else
	fail "lockstep note not outside the GENERIC block (note=$lock end=$gend)"
fi
lockline="$(sed -n "${lock}p" "$DEEP")"
case "$lockline" in
*scripts/render-report.py*) pass "lockstep note names scripts/render-report.py" ;;
*) fail "lockstep note does not name scripts/render-report.py" ;;
esac
inside_generic="$(region "$DEEP" '<!-- BEGIN GENERIC FINDING SCHEMA AND MERGE -->' '<!-- END GENERIC FINDING SCHEMA AND MERGE -->')"
if printf '%s\n' "$inside_generic" | grep -qF 'render-report.py'; then
	fail "render-report.py leaked into the GENERIC block (breaks cross-mirror byte parity)"
else
	pass "GENERIC block does not mention render-report.py"
fi

echo ""
echo "Results: $pass_count passed, $fail_count failed"

if [[ "$fail_count" -gt 0 ]]; then
	exit 1
fi

exit 0
