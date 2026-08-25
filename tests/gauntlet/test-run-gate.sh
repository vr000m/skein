#!/usr/bin/env bash
# test-run-gate.sh — runtime acceptance for run-gate.sh's operative logic.
#
# test-reuse-wiring.sh covers run-gate.sh only with static grep assertions
# (that it resolves bundled scripts, calls reconcile without --skill, etc.).
# This suite drives the REAL CLI end to end so a regression in the operative
# paths — normalize's schema mapping + auto_fix side-cache + exit-4
# non-clean-status signal, reconcile's bundled-reconciler piping, and route's
# (file,line,category) auto_fix re-attach + eligibility delegation — actually
# fails a test rather than passing silently.
#
# The bundled shared pipeline (reconcile-findings.sh, audit-auto-fix-eligibility.sh)
# is resolved via gc_bundled_scripts_dir, which anchors on ${CLAUDE_PLUGIN_ROOT};
# this test exports it to the installed skill's own tree.
#
# Exit codes: 0 all assertions pass, 1 any assertion fails.

set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
SKILL_LIB="$ROOT_DIR/plugins/skein/skills/review-gauntlet/lib"
RUN_GATE="$SKILL_LIB/run-gate.sh"
export CLAUDE_PLUGIN_ROOT="$ROOT_DIR/plugins/skein"

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
	local actual="$1" expected="$2" label="$3"
	if [[ "$actual" == "$expected" ]]; then
		pass "$label"
	else
		fail "$label (expected '$expected', got '$actual')"
	fi
}

if [[ ! -x "$RUN_GATE" ]]; then
	fail "run-gate.sh missing or not executable: $RUN_GATE"
	echo "Results: $pass_count passed, $fail_count failed"
	exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
	fail "jq is required to run this test"
	echo "Results: $pass_count passed, $fail_count failed"
	exit 1
fi

WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

# --- 1. normalize: schema mapping + auto_fix side-cache + exit 0 ----------
# Two findings; only the second carries an auto_fix block. Expect: both emitted
# to stdout as normalized, auto_fix-free, lens-tagged JSON lines; only the
# auto_fix-carrying finding appended (unstripped) to the cache; exit 0.

cache="$WORKDIR/autofix-cache.jsonl"
raw_gate="$WORKDIR/raw-gate.json"
cat >"$raw_gate" <<'EOF'
{
  "gate": "code-review",
  "status": "approve",
  "findings": [
    {"file": "a.py", "line": 10, "category": "correctness", "severity": "high",
     "confidence": 0.9, "summary": "off-by-one", "evidence": "loop bound"},
    {"file": "b.py", "line": 3, "category": "style", "severity": "low",
     "confidence": 0.5, "summary": "typo in docstring", "evidence": "teh",
     "auto_fix": {"kind": "docstring_typo", "before": "# teh value",
                  "after": "# the value", "scope": "3-3"}}
  ],
  "notes": null
}
EOF

normalize_out="$WORKDIR/normalize.out"
normalize_rc=0
"$RUN_GATE" normalize --gate code-review --autofix-cache "$cache" "$raw_gate" >"$normalize_out" 2>/dev/null || normalize_rc=$?

assert_eq "$normalize_rc" "0" "normalize on status=approve exits 0"
assert_eq "$(grep -c '^' "$normalize_out")" "2" "normalize emits one JSON line per finding (2)"
assert_eq "$(jq -sr '[.[] | select(has("auto_fix"))] | length' "$normalize_out")" "0" \
	"normalize stdout is auto_fix-free (auto_fix stripped from pooled payload)"
assert_eq "$(jq -sr 'all(.[]; .lens == "code-review")' "$normalize_out")" "true" \
	"normalize tags every emitted finding with lens=<gate>"
assert_eq "$(jq -sr 'map(.file) | sort | join(",")' "$normalize_out")" "a.py,b.py" \
	"normalize preserves both findings' file fields under the common schema"
assert_eq "$(grep -c '^' "$cache")" "1" "normalize side-caches exactly the one auto_fix-carrying finding"
assert_eq "$(jq -r '.auto_fix.kind' "$cache")" "docstring_typo" \
	"normalize caches the finding UNSTRIPPED (auto_fix.kind intact)"

# --- 2. normalize: non-clean status exits 4, still emits findings ---------

raw_err="$WORKDIR/raw-err.json"
cat >"$raw_err" <<'EOF'
{"gate": "security-review", "status": "error",
 "findings": [{"file": "c.py", "line": 1, "category": "sec", "severity": "high",
               "confidence": null, "summary": "x", "evidence": "y"}],
 "notes": "gate crashed"}
EOF
err_cache="$WORKDIR/err-cache.jsonl"
err_out="$WORKDIR/err.out"
err_rc=0
"$RUN_GATE" normalize --gate security-review --autofix-cache "$err_cache" "$raw_err" >"$err_out" 2>/dev/null || err_rc=$?
assert_eq "$err_rc" "4" "normalize on status=error exits 4 (non-clean-pass signal to the conductor)"
assert_eq "$(grep -c '^' "$err_out")" "1" "normalize still emits findings even on a non-clean status"

# --- 3. reconcile: pooled findings -> bundled reconciler v2 envelope ------

reconciled="$WORKDIR/reconciled.json"
reconcile_rc=0
"$RUN_GATE" reconcile "$normalize_out" >"$reconciled" 2>/dev/null || reconcile_rc=$?
assert_eq "$reconcile_rc" "0" "reconcile exits 0"
assert_eq "$(jq -r '.schema_version | tostring' "$reconciled")" "2" \
	"reconcile emits the bundled reconciler's v2 envelope (schema_version 2)"
assert_eq "$(jq -r '.findings | type' "$reconciled")" "array" \
	"reconcile envelope carries a findings array"

# --- 4. route: re-attach cached auto_fix + delegate eligibility -----------
# The finding's file does not exist in this scratch tree, so the auditor
# classifies it as drift (not would_apply) and route sends it to
# substantive_findings — but the auto_fix must have been re-attached and the
# auditor must have annotated it (proving the re-attach + delegation ran).

route_out="$WORKDIR/route.json"
route_rc=0
"$RUN_GATE" route --autofix-cache "$cache" "$reconciled" >"$route_out" 2>/dev/null || route_rc=$?
assert_eq "$route_rc" "0" "route exits 0"
assert_eq "$(jq -r 'has("trivial_envelope") and has("substantive_findings")' "$route_out")" "true" \
	"route emits both trivial_envelope and substantive_findings"
assert_eq "$(jq -r '[.substantive_findings[], (.trivial_envelope.findings[]?)] | map(select(.file == "b.py")) | any(has("auto_fix"))' "$route_out")" "true" \
	"route re-attaches the cached auto_fix onto its (file,line,category)-matching finding"
assert_eq "$(jq -r '[.substantive_findings[], (.trivial_envelope.findings[]?)] | map(select(.file == "b.py")) | any(has("auto_fix_status"))' "$route_out")" "true" \
	"route delegates eligibility to the bundled auditor (auto_fix_status annotated)"

# --- 5. route: duplicate (file,line,category) sig warns on stderr ---------

dup_cache="$WORKDIR/dup-cache.jsonl"
cat >"$dup_cache" <<'EOF'
{"file": "b.py", "line": 3, "category": "style", "auto_fix": {"kind": "docstring_typo", "before": "x", "after": "y", "scope": "3-3"}}
{"file": "b.py", "line": 3, "category": "style", "auto_fix": {"kind": "mechanical_replace", "before": "p", "after": "q", "scope": "3-3"}}
EOF
dup_stderr="$WORKDIR/route-dup.err"
"$RUN_GATE" route --autofix-cache "$dup_cache" "$reconciled" >/dev/null 2>"$dup_stderr" || true
if grep -q "WARNING multiple cached auto_fix proposals share signature" "$dup_stderr"; then
	pass "route warns to stderr on a colliding (file,line,category) auto_fix signature"
else
	fail "route did not warn on a colliding auto_fix signature"
fi

# --- 6. route: architecture-category finding never gets auto_fix re-attached
# Guardrail 1 floor: even if a gate proposes an allowlisted auto_fix for a
# finding it tagged "Architecture" (design-relevant), route must strip that
# proposal before it ever reaches the auditor, so it cannot land in
# trivial_envelope — it must fall through to substantive_findings, auto_fix-free.

arch_raw="$WORKDIR/raw-arch.json"
cat >"$arch_raw" <<'EOF'
{
  "gate": "deep-review",
  "status": "approve",
  "findings": [
    {"file": "d.py", "line": 5, "category": "Architecture", "severity": "low",
     "confidence": 0.4, "summary": "drops a plan-mandated re-export", "evidence": "unused_import",
     "auto_fix": {"kind": "unused_import", "before": "import foo", "after": "",
                  "scope": "5-5"}}
  ],
  "notes": null
}
EOF

arch_cache="$WORKDIR/arch-cache.jsonl"
arch_normalize_out="$WORKDIR/arch-normalize.out"
"$RUN_GATE" normalize --gate deep-review --autofix-cache "$arch_cache" "$arch_raw" >"$arch_normalize_out" 2>/dev/null
arch_reconciled="$WORKDIR/arch-reconciled.json"
"$RUN_GATE" reconcile "$arch_normalize_out" >"$arch_reconciled" 2>/dev/null
arch_route_out="$WORKDIR/arch-route.json"
"$RUN_GATE" route --autofix-cache "$arch_cache" "$arch_reconciled" >"$arch_route_out" 2>/dev/null

assert_eq "$(jq -r '.trivial_envelope.findings | map(select(.file == "d.py")) | length' "$arch_route_out")" "0" \
	"route never places an architecture-category finding in trivial_envelope"
assert_eq "$(jq -r '.substantive_findings | map(select(.file == "d.py")) | length' "$arch_route_out")" "1" \
	"route sends the architecture-category finding to substantive_findings"
assert_eq "$(jq -r '.substantive_findings[] | select(.file == "d.py") | has("auto_fix")' "$arch_route_out")" "false" \
	"route strips the auto_fix proposal from the architecture-category finding entirely"

# ---------------------------------------------------------------------------
# R6-G1f — `normalize --autofix-cache` is a STATE-TREE WRITER and gets the
# skill's one containment guard.
#
# SKILL.md composes --autofix-cache from the same $gate_out_dir that
# gate_run_bounded writes its envelope into, and this command CREATES that
# file (`printf '' >"$cache"`) and later APPENDS full findings to it. It was
# the one `.gauntlet/` writer in the skill with no guard at all — found by
# sweeping the mechanism, not reported.
# ---------------------------------------------------------------------------

r6g1f_root="$WORKDIR/r6g1f"
mkdir -p "$r6g1f_root/repo" "$r6g1f_root/outside"
git -C "$r6g1f_root/repo" init -q 2>/dev/null || git -C "$r6g1f_root/repo" init >/dev/null 2>&1
ln -s "$r6g1f_root/outside" "$r6g1f_root/repo/.gauntlet"
set +e
r6g1f_err="$(cd "$r6g1f_root/repo" && printf '%s' '{"status":"approve","findings":[]}' |
	"$RUN_GATE" normalize --gate demo --autofix-cache .gauntlet/auto-fix-cache.jsonl - 2>&1 >/dev/null)"
r6g1f_rc=$?
set -e
if [[ "$r6g1f_rc" -eq 2 && "$r6g1f_err" == *"refusing to operate on symlink"* &&
	! -e "$r6g1f_root/outside/auto-fix-cache.jsonl" ]]; then
	pass "R6-G1f: normalize --autofix-cache under a symlinked ancestor exits 2 and creates nothing"
else
	fail "R6-G1f: rc=$r6g1f_rc err='$r6g1f_err' created=$([[ -e "$r6g1f_root/outside/auto-fix-cache.jsonl" ]] && echo yes || echo no)"
fi

# Control: the same command against an ordinary path still works.
set +e
(cd "$r6g1f_root/repo" && mkdir -p real && printf '%s' '{"status":"approve","findings":[]}' |
	"$RUN_GATE" normalize --gate demo --autofix-cache real/cache.jsonl -) >/dev/null 2>&1
r6g1f_ok_rc=$?
set -e
if [[ "$r6g1f_ok_rc" -eq 0 && -e "$r6g1f_root/repo/real/cache.jsonl" ]]; then
	pass "R6-G1f/control: an ordinary --autofix-cache path is still created and normalize exits 0"
else
	fail "R6-G1f/control: rc=$r6g1f_ok_rc created=$([[ -e "$r6g1f_root/repo/real/cache.jsonl" ]] && echo yes || echo no)"
fi

# ---------------------------------------------------------------------------
# R7-G5 — `route` READS the same state path `normalize` guards (round 7, F9).
#
# Round 6 guarded --autofix-cache in `normalize` and left `route` alone as
# "read-only". But route's read is re-attached as `.auto_fix` objects that
# apply-auto-fix-code.sh later applies to the WORKING TREE, so an
# attacker-planted symlink at the cache path feeds chosen JSON into the
# auto-fix proposal stream. Every access to a `.gauntlet/` state path — read
# or write — passes the guard before the first filesystem effect.
# ---------------------------------------------------------------------------

r7g5_root="$WORKDIR/r7g5"
mkdir -p "$r7g5_root/repo" "$r7g5_root/outside"
git -C "$r7g5_root/repo" init -q 2>/dev/null || git -C "$r7g5_root/repo" init >/dev/null 2>&1
ln -s "$r7g5_root/outside" "$r7g5_root/repo/.gauntlet"
printf '%s\n' '{"file":"a.py","line":1,"category":"logic","auto_fix":{"kind":"planted"}}' \
	>"$r7g5_root/outside/auto-fix-cache.jsonl"
set +e
r7g5a_out="$(cd "$r7g5_root/repo" && printf '%s' '{"findings":[]}' |
	"$RUN_GATE" route --autofix-cache .gauntlet/auto-fix-cache.jsonl - 2>/dev/null)"
r7g5a_rc=$?
r7g5a_err="$(cd "$r7g5_root/repo" && printf '%s' '{"findings":[]}' |
	"$RUN_GATE" route --autofix-cache .gauntlet/auto-fix-cache.jsonl - 2>&1 >/dev/null)"
set -e
if [[ "$r7g5a_rc" -eq 2 && "$r7g5a_err" == *"refusing to operate on symlink"* && -z "$r7g5a_out" ]]; then
	pass "R7-G5a: route --autofix-cache under a symlinked ancestor exits 2, refuses loudly, and emits no envelope"
else
	fail "R7-G5a: rc=$r7g5a_rc err='$r7g5a_err' out='$r7g5a_out'"
fi

# R7-G5b/control: an ordinary (non-symlinked) cache path still routes and
# re-attaches .auto_fix unchanged — the guard adds a refusal, not a behaviour
# change. Reuses the section-4 fixtures, which are the real route wire.
set +e
r7g5b_out="$("$RUN_GATE" route --autofix-cache "$cache" "$reconciled" 2>/dev/null)"
r7g5b_rc=$?
set -e
r7g5b_attached="$(printf '%s' "$r7g5b_out" | jq -r '[.substantive_findings[], (.trivial_envelope.findings[]?)] | map(select(.file == "b.py")) | any(has("auto_fix"))' 2>/dev/null)"
if [[ "$r7g5b_rc" -eq 0 && "$r7g5b_attached" == "true" ]]; then
	pass "R7-G5b/control: an ordinary --autofix-cache path still routes (rc 0) and re-attaches .auto_fix unchanged"
else
	fail "R7-G5b/control: rc=$r7g5b_rc attached='$r7g5b_attached'"
fi

# ---------------------------------------------------------------------------
# Group R8-G2 — the TRAILING POSITIONAL is a state path, and it is guarded at
# the single open (round 8, F3).
#
# `--autofix-cache` was guarded on both the write (round 6) and the read (round
# 7, F9) side, but the positional envelope/pooled-findings path — a
# `.gauntlet/` path composed by SKILL.md from the same `$gate_out_dir`, and the
# file the `auto_fix` blocks ORIGINATE in — was read through unguarded by all
# four subcommands. The guard now lives in `read_input`, so the SUBCOMMAND LIST
# IS DERIVED FROM `usage()` rather than hardcoded here: a new subcommand joins
# this matrix automatically and cannot inherit an unguarded read.
r8g2_root="$WORKDIR/r8g2"
mkdir -p "$r8g2_root/repo/.gauntlet"
git -C "$r8g2_root/repo" init -q >/dev/null 2>&1 || git -C "$r8g2_root/repo" init >/dev/null 2>&1
printf '%s' '{"gate":"demo","status":"approve","findings":[],"notes":"n"}' >"$r8g2_root/target.json"
ln -s "$r8g2_root/target.json" "$r8g2_root/repo/.gauntlet/in.json"
r8g2_link="$r8g2_root/repo/.gauntlet/in.json"
r8g2_cache="$r8g2_root/repo/.gauntlet/cache.jsonl"

# No `mapfile`: this repo holds itself to bash 3.2 portability (asserted for
# scripts/ by tests/lenses/test-lens-collect.sh case (v)); the same discipline
# applies here.
r8g2_subcommands=()
while IFS= read -r r8g2_line; do
	[[ -n "$r8g2_line" ]] && r8g2_subcommands+=("$r8g2_line")
done < <("$RUN_GATE" --help 2>&1 | awk '{for (i = 1; i < NF; i++) if ($i == "run-gate.sh") print $(i + 1)}' | sort -u)
if [[ "${#r8g2_subcommands[@]}" -lt 4 ]]; then
	fail "R8-G2a: could not parse the subcommand list out of usage() (got '${r8g2_subcommands[*]}')"
else
	pass "R8-G2a/setup: subcommand matrix derived from usage(): ${r8g2_subcommands[*]}"
fi

# Per-subcommand stdin payload: route wants a reconciled envelope, the others
# a gate envelope. Only the READ PATH is under test here, not the schema.
r8g2_stdin_for() {
	case "$1" in
	route) printf '%s' '{"schema_version":2,"findings":[]}' ;;
	*) printf '%s' '{"gate":"demo","status":"approve","findings":[],"notes":"n"}' ;;
	esac
}

r8g2_args_for() {
	case "$1" in
	normalize) printf '%s\n' --gate demo --autofix-cache "$r8g2_cache" ;;
	route) printf '%s\n' --autofix-cache "$r8g2_cache" ;;
	*) : ;;
	esac
}

r8g2a_bad=""
for r8g2_sub in "${r8g2_subcommands[@]}"; do
	r8g2_flags=()
	while IFS= read -r r8g2_a; do
		[[ -n "$r8g2_a" ]] && r8g2_flags+=("$r8g2_a")
	done < <(r8g2_args_for "$r8g2_sub")
	set +e
	r8g2_out="$("$RUN_GATE" "$r8g2_sub" "${r8g2_flags[@]+"${r8g2_flags[@]}"}" "$r8g2_link" 2>"$r8g2_root/err.$r8g2_sub")"
	r8g2_rc=$?
	set -e
	r8g2_err="$(cat "$r8g2_root/err.$r8g2_sub")"
	if [[ "$r8g2_sub" == "status-row" ]]; then
		# F4 is load-bearing here and is exactly why read_input RETURNS
		# instead of exiting: a refused envelope must still account for its
		# slot with exactly one `error` row, and exit 0.
		r8g2_rows="$(printf '%s' "$r8g2_out" | grep -c . || true)"
		if [[ "$r8g2_rc" -ne 0 || "$r8g2_rows" != "1" || "$r8g2_out" != *"error"* ]]; then
			r8g2a_bad="$r8g2a_bad [status-row rc=$r8g2_rc rows=$r8g2_rows out='$r8g2_out']"
		fi
	else
		if [[ "$r8g2_rc" -ne 2 || "$r8g2_err" != *"refusing to operate on symlink"* || -n "$r8g2_out" ]]; then
			r8g2a_bad="$r8g2a_bad [$r8g2_sub rc=$r8g2_rc err='$r8g2_err' out='$r8g2_out']"
		fi
	fi
done
if [[ -z "$r8g2a_bad" ]]; then
	pass "R8-G2a: every subcommand refuses a SYMLINKED positional path — normalize/reconcile/route exit 2 with the diagnostic and emit nothing; status-row still prints exactly one error row and exits 0"
else
	fail "R8-G2a: unguarded or wrongly-handled positional read:$r8g2a_bad"
fi

# R8-G2b/control — the guard adds a refusal, not a behaviour change: `-` (and
# an absent positional) still reads stdin for every subcommand.
r8g2b_bad=""
for r8g2_sub in "${r8g2_subcommands[@]}"; do
	r8g2_flags=()
	while IFS= read -r r8g2_a; do
		[[ -n "$r8g2_a" ]] && r8g2_flags+=("$r8g2_a")
	done < <(r8g2_args_for "$r8g2_sub")
	for r8g2_pos in "-" ""; do
		set +e
		if [[ -n "$r8g2_pos" ]]; then
			r8g2_out="$(r8g2_stdin_for "$r8g2_sub" |
				"$RUN_GATE" "$r8g2_sub" "${r8g2_flags[@]+"${r8g2_flags[@]}"}" "$r8g2_pos" 2>/dev/null)"
		else
			r8g2_out="$(r8g2_stdin_for "$r8g2_sub" |
				"$RUN_GATE" "$r8g2_sub" "${r8g2_flags[@]+"${r8g2_flags[@]}"}" 2>/dev/null)"
		fi
		r8g2_rc=$?
		set -e
		[[ "$r8g2_rc" -eq 0 ]] || r8g2b_bad="$r8g2b_bad [$r8g2_sub pos='${r8g2_pos:-<absent>}' rc=$r8g2_rc]"
		if [[ "$r8g2_sub" == "status-row" && "$r8g2_out" == *"envelope missing or unreadable"* ]]; then
			r8g2b_bad="$r8g2b_bad [status-row pos='${r8g2_pos:-<absent>}' did not read stdin]"
		fi
	done
done
if [[ -z "$r8g2b_bad" ]]; then
	pass "R8-G2b/control: '-' and an absent positional still read stdin unchanged, for every subcommand"
else
	fail "R8-G2b/control:$r8g2b_bad"
fi

echo ""
echo "Results: $pass_count passed, $fail_count failed"
[[ "$fail_count" -eq 0 ]]
