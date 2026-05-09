#!/usr/bin/env bash
# Unit tests for scripts/reconcile-findings.sh.
#
# Contract under test (from
# docs/dev_plans/20260508-feature-cross-lens-finding-reconciliation.md):
#
#   Stdin:  JSON-Lines findings
#           {lens, severity, category, file, line, summary, evidence, suggestion}
#   Stdout: canonical JSON
#           {summary: {raw, merged, unique, related}, findings: [...], related: [...]}
#
#   Merge rule: group by (file, line, category); merged findings concatenate
#   sorted-unique `lenses`. Same (file, line) but different category groups
#   emit a `related: [...]` cross-reference (NOT merged).
#
#   Sort order: severity (Critical -> Important -> Minor) -> category -> file
#   -> line -> sorted lenses.
#
#   Empty input -> structured report with raw=0 merged=0 unique=0 related=0.
#
# This harness is jq-free: it diffs raw stdout against expected canonical JSON.
# That means the implementation's emitted JSON must be byte-identical to the
# expected blocks below. The expected blocks follow the contract literally
# (2-space indent, sorted keys, trailing newline) and serve as the canonical
# format spec until Phase 2's fixture-based tests take over.
#
# Exit 0 on all-pass, 1 on any failure.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/reconcile-findings.sh"

TMPDIR_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

pass_count=0
fail_count=0

# ---------------------------------------------------------------------------
# Test helpers
# ---------------------------------------------------------------------------

# run_case <case_name> <input> <expected_stdout>
#   Pipes <input> through the reconciler and diffs stdout against
#   <expected_stdout>. Records PASS/FAIL.
run_case() {
    local name="$1"
    local input="$2"
    local expected="$3"

    local case_dir
    case_dir="$(mktemp -d "$TMPDIR_ROOT/case.XXXXXX")"
    local actual_file="$case_dir/actual.json"
    local expected_file="$case_dir/expected.json"
    local diff_file="$case_dir/diff.txt"

    printf '%s' "$expected" > "$expected_file"

    if ! printf '%s' "$input" | bash "$SCRIPT" > "$actual_file" 2>"$case_dir/stderr"; then
        echo "FAIL: $name (script exited non-zero)"
        echo "  stderr: $(cat "$case_dir/stderr")"
        fail_count=$((fail_count + 1))
        return
    fi

    if diff -u "$expected_file" "$actual_file" > "$diff_file"; then
        echo "PASS: $name"
        pass_count=$((pass_count + 1))
    else
        echo "FAIL: $name"
        echo "--- expected"
        echo "+++ actual"
        sed 's/^/    /' "$diff_file"
        fail_count=$((fail_count + 1))
    fi
}

# ---------------------------------------------------------------------------
# Preflight: ensure the script exists and is executable.
# ---------------------------------------------------------------------------

if [[ ! -f "$SCRIPT" ]]; then
    echo "FAIL: preflight (scripts/reconcile-findings.sh not found at $SCRIPT)"
    echo ""
    echo "Summary: 0 passed, 1 failed"
    exit 1
fi

# ---------------------------------------------------------------------------
# Case 1: Single finding from a single lens
#
# Acceptance: passes through with `lenses: ["logic"]` (always populated, never
# missing) and summary {raw=1, merged=0, unique=1, related=0}.
# ---------------------------------------------------------------------------

CASE1_INPUT='{"lens":"logic","severity":"Important","category":"correctness","file":"src/foo.py","line":42,"summary":"off-by-one","evidence":"loop runs N+1 times","suggestion":"use range(N)"}
'

read -r -d '' CASE1_EXPECTED <<'JSON' || true
{
  "summary": {
    "raw": 1,
    "merged": 0,
    "unique": 1,
    "related": 0
  },
  "findings": [
    {
      "severity": "Important",
      "category": "correctness",
      "file": "src/foo.py",
      "line": 42,
      "lenses": ["logic"],
      "summary": "off-by-one",
      "evidence": "loop runs N+1 times",
      "suggestion": "use range(N)"
    }
  ],
  "related": []
}
JSON
CASE1_EXPECTED="${CASE1_EXPECTED}"$'\n'

run_case "single-finding-single-lens" "$CASE1_INPUT" "$CASE1_EXPECTED"

# ---------------------------------------------------------------------------
# Case 2: Two findings on same (file, line, category) from two different
# lenses -> merged into one finding with sorted lenses; summary.merged == 1.
#
# Acceptance: merge rule groups by (file, line, category); merged finding
# cites both source lenses sorted alphabetically. Input order is reversed
# (security first, logic second) to verify canonical output ordering does
# not depend on arrival order.
# ---------------------------------------------------------------------------

CASE2_INPUT='{"lens":"security","severity":"Critical","category":"injection","file":"src/db.py","line":17,"summary":"unsanitised input","evidence":"user param interpolated","suggestion":"use parameterised query"}
{"lens":"logic","severity":"Critical","category":"injection","file":"src/db.py","line":17,"summary":"sql concatenation","evidence":"string concat with user input","suggestion":"prepared statement"}
'

read -r -d '' CASE2_EXPECTED <<'JSON' || true
{
  "summary": {
    "raw": 2,
    "merged": 1,
    "unique": 1,
    "related": 0
  },
  "findings": [
    {
      "severity": "Critical",
      "category": "injection",
      "file": "src/db.py",
      "line": 17,
      "lenses": ["logic", "security"],
      "summary": "unsanitised input",
      "evidence": "user param interpolated",
      "suggestion": "use parameterised query"
    }
  ],
  "related": []
}
JSON
CASE2_EXPECTED="${CASE2_EXPECTED}"$'\n'

run_case "two-lens-merge-same-file-line-category" "$CASE2_INPUT" "$CASE2_EXPECTED"

# ---------------------------------------------------------------------------
# Case 3: Same (file, line) but different categories -> kept separate; emit
# `related: [...]` cross-reference; summary.related >= 1.
#
# Acceptance: signature is (file, line, category) -- different categories at
# the same (file, line) MUST NOT merge. Both findings appear with a
# cross-reference entry in `related`.
# ---------------------------------------------------------------------------

CASE3_INPUT='{"lens":"logic","severity":"Important","category":"correctness","file":"src/api.py","line":88,"summary":"null deref","evidence":"missing guard","suggestion":"add check"}
{"lens":"security","severity":"Critical","category":"authz","file":"src/api.py","line":88,"summary":"missing auth check","evidence":"endpoint reachable without token","suggestion":"add @require_auth"}
'

read -r -d '' CASE3_EXPECTED <<'JSON' || true
{
  "summary": {
    "raw": 2,
    "merged": 0,
    "unique": 2,
    "related": 1
  },
  "findings": [
    {
      "severity": "Critical",
      "category": "authz",
      "file": "src/api.py",
      "line": 88,
      "lenses": ["security"],
      "summary": "missing auth check",
      "evidence": "endpoint reachable without token",
      "suggestion": "add @require_auth"
    },
    {
      "severity": "Important",
      "category": "correctness",
      "file": "src/api.py",
      "line": 88,
      "lenses": ["logic"],
      "summary": "null deref",
      "evidence": "missing guard",
      "suggestion": "add check"
    }
  ],
  "related": [
    {
      "file": "src/api.py",
      "line": 88,
      "categories": ["authz", "correctness"]
    }
  ]
}
JSON
CASE3_EXPECTED="${CASE3_EXPECTED}"$'\n'

run_case "same-file-line-different-category-related-callout" "$CASE3_INPUT" "$CASE3_EXPECTED"

# ---------------------------------------------------------------------------
# Case 4: Empty input -> structured report with all-zero summary.
#
# Acceptance: does not crash; emits the canonical envelope with zero counts
# and empty `findings`/`related` arrays.
# ---------------------------------------------------------------------------

CASE4_INPUT=''

read -r -d '' CASE4_EXPECTED <<'JSON' || true
{
  "summary": {
    "raw": 0,
    "merged": 0,
    "unique": 0,
    "related": 0
  },
  "findings": [],
  "related": []
}
JSON
CASE4_EXPECTED="${CASE4_EXPECTED}"$'\n'

run_case "empty-input" "$CASE4_INPUT" "$CASE4_EXPECTED"

# ---------------------------------------------------------------------------
# Final tally
# ---------------------------------------------------------------------------

echo ""
echo "Summary: $pass_count passed, $fail_count failed"

if [[ $fail_count -ne 0 ]]; then
    exit 1
fi
exit 0
