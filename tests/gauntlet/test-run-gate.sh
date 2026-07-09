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

echo ""
echo "Results: $pass_count passed, $fail_count failed"
[[ "$fail_count" -eq 0 ]]
