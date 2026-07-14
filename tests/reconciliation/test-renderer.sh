#!/usr/bin/env bash
# Renderer fixture harness for scripts/render-reconciled-report.sh.
#
# Pipes each fixture's reconciled JSON envelope (expected/<name>.md)
# through the reference renderer and diffs against
# expected/<name>.rendered.md. This closes the gap left by run-fixtures.sh,
# which only verifies the JSON envelope; here we verify the canonical
# markdown body fragment that the deep-review and review-plan SKILL.md
# report templates promise to produce.
#
# Contract under test:
#   1. The `**Reconciliation**:` summary line is always present; the
#      `dropped=D` term appears iff D > 0.
#   2. Findings render under per-severity headers in canonical order
#      (Critical, Important, Minor, then any other severity alphabetically).
#   3. Critical/Important findings, and Minor findings when `--verbose` is
#      passed, render Lenses, Evidence, Suggestion sub-bullets; a Related
#      findings sub-bullet appears only when the JSON envelope's `related`
#      array references this (file, line, category). By default (no flag),
#      Minor findings render compact instead: a single
#      `- **Category**: summary (file:line)` line, with a terse
#      ` — see also Other at same location` suffix in place of the
#      sub-bullet when related, and the location segment omitted for
#      unanchored findings.
#   4. Renderer is deterministic: identical envelope + identical flags ->
#      byte-identical markdown body fragment.
#
# Exit 0 on all-pass, 1 on any mismatch.

set -euo pipefail

# `declare -A` (associative arrays, used below for VERBOSE_FIXTURES)
# requires bash 4.0+. macOS ships /bin/bash 3.2 by default, which
# silently mis-parses the associative-array literal and then crashes
# later with a cryptic "unbound variable" error under `set -u`. Fail
# fast with a clear message instead.
if ((BASH_VERSINFO[0] < 4)); then
	echo "test-renderer.sh requires bash 4.0+ (found ${BASH_VERSION}); on macOS install via 'brew install bash' and ensure it's first on PATH" >&2
	exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RENDERER="$REPO_ROOT/scripts/render-reconciled-report.sh"
EXPECTED_DIR="$REPO_ROOT/tests/reconciliation/expected"

# Fixtures rendered with `--verbose` rather than the renderer's new
# compact-Minor default. Two groups:
#   - Five pre-existing fixtures whose golden `.rendered.md` asserts
#     full-detail Minor rendering (auto-fix status handling, category
#     cross-references — unrelated to severity-tier rendering); migrated
#     here so they keep asserting full detail now that compact-Minor is
#     the renderer's default, rather than silently failing.
#   - The two new `*-compact-minor-verbose` fixtures (Open Question 1,
#     option (b)), whose entire purpose is to exercise `--verbose`
#     against the same underlying findings as their `*-compact-minor-default`
#     counterpart.
# Keyed by envelope basename (i.e. `expected/<name>.md` with the `.md`
# stripped).
declare -A VERBOSE_FIXTURES=(
	["auto-fix-v2-docstring-typo"]=1
	["auto-fix-v2-pass-through"]=1
	["auto-fix-v2-reject-statuses"]=1
	["same-category-different-line"]=1
	["auto-fix-v2-empty-fields"]=1
	["deep-review-compact-minor-verbose"]=1
	["review-plan-compact-minor-verbose"]=1
)

TMPDIR_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

pass_count=0
fail_count=0

if [[ ! -f "$RENDERER" ]]; then
	echo "FAIL: preflight (scripts/render-reconciled-report.sh not found at $RENDERER)"
	echo ""
	echo "Summary: 0 passed, 1 failed"
	exit 1
fi

if [[ ! -d "$EXPECTED_DIR" ]]; then
	echo "FAIL: preflight (expected dir missing: $EXPECTED_DIR)"
	echo ""
	echo "Summary: 0 passed, 1 failed"
	exit 1
fi

shopt -s nullglob
envelopes=("$EXPECTED_DIR"/*.md)
shopt -u nullglob

# Filter out the .rendered.md goldens so they aren't fed back as inputs.
inputs=()
for env in "${envelopes[@]}"; do
	case "$env" in
	*.rendered.md) continue ;;
	*) inputs+=("$env") ;;
	esac
done

if [[ ${#inputs[@]} -eq 0 ]]; then
	echo "FAIL: preflight (no envelope fixtures found in $EXPECTED_DIR)"
	echo ""
	echo "Summary: 0 passed, 1 failed"
	exit 1
fi

for envelope in "${inputs[@]}"; do
	name="$(basename "$envelope" .md)"
	rendered_expected="$EXPECTED_DIR/${name}.rendered.md"

	if [[ ! -f "$rendered_expected" ]]; then
		echo "FAIL: $name (missing rendered golden: $rendered_expected)"
		fail_count=$((fail_count + 1))
		continue
	fi

	case_dir="$(mktemp -d "$TMPDIR_ROOT/case.XXXXXX")"
	actual_file="$case_dir/actual.md"
	diff_file="$case_dir/diff.txt"

	extra_flags=()
	if [[ "${VERBOSE_FIXTURES[$name]:-0}" == "1" ]]; then
		extra_flags+=(--verbose)
	fi

	if ! bash "$RENDERER" "${extra_flags[@]}" <"$envelope" >"$actual_file" 2>"$case_dir/stderr"; then
		echo "FAIL: $name (renderer exited non-zero)"
		echo "  stderr: $(cat "$case_dir/stderr")"
		fail_count=$((fail_count + 1))
		continue
	fi

	if diff -u "$rendered_expected" "$actual_file" >"$diff_file"; then
		echo "PASS: $name"
		pass_count=$((pass_count + 1))
	else
		echo "FAIL: $name"
		echo "--- expected: $rendered_expected"
		echo "+++ actual"
		sed 's/^/    /' "$diff_file"
		fail_count=$((fail_count + 1))
	fi
done

# ---------------------------------------------------------------------------
# Cross-parser invariant: jq path and awk fallback render byte-identically
# ---------------------------------------------------------------------------

if command -v jq >/dev/null 2>&1; then
	no_jq_bin="$TMPDIR_ROOT/no-jq-bin"
	mkdir "$no_jq_bin"
	for cmd in bash awk sort diff sed mktemp dirname basename rm grep cat printf wc cut tr tail head seq; do
		cmd_path="$(command -v "$cmd" 2>/dev/null || true)"
		if [[ -n "$cmd_path" ]]; then
			ln -s "$cmd_path" "$no_jq_bin/$cmd"
		fi
	done

	for envelope in "${inputs[@]}"; do
		name="$(basename "$envelope" .md)"
		case_dir="$(mktemp -d "$TMPDIR_ROOT/cross-parser.XXXXXX")"
		jq_rendered="$case_dir/jq.md"
		awk_rendered="$case_dir/awk.md"
		diff_file="$case_dir/diff.txt"

		extra_flags=()
		if [[ "${VERBOSE_FIXTURES[$name]:-0}" == "1" ]]; then
			extra_flags+=(--verbose)
		fi

		bash "$RENDERER" "${extra_flags[@]}" <"$envelope" >"$jq_rendered"
		PATH="$no_jq_bin" bash "$RENDERER" "${extra_flags[@]}" <"$envelope" >"$awk_rendered"

		if diff -u "$jq_rendered" "$awk_rendered" >"$diff_file"; then
			echo "PASS: $name (jq and awk renderer paths byte-identical)"
			pass_count=$((pass_count + 1))
		else
			echo "FAIL: $name (jq and awk renderer paths differ)"
			sed 's/^/    /' "$diff_file"
			fail_count=$((fail_count + 1))
		fi
	done
fi

# ---------------------------------------------------------------------------
# Cross-fixture invariant: dropped=D appears iff dropped > 0
# ---------------------------------------------------------------------------

clean_rendered="$EXPECTED_DIR/two-lens-merge.rendered.md"
dropped_rendered="$EXPECTED_DIR/dropped-input.rendered.md"

if [[ -f "$clean_rendered" && -f "$dropped_rendered" ]]; then
	if grep -q '^\*\*Reconciliation\*\*: .* dropped=' "$clean_rendered"; then
		echo "FAIL: dropped-conditional-rendering (clean envelope rendered with dropped=)"
		fail_count=$((fail_count + 1))
	elif ! grep -q '^\*\*Reconciliation\*\*: .* dropped=[1-9]' "$dropped_rendered"; then
		echo "FAIL: dropped-conditional-rendering (dropped envelope missing dropped=N>0)"
		fail_count=$((fail_count + 1))
	else
		echo "PASS: dropped-conditional-rendering (present iff dropped>0)"
		pass_count=$((pass_count + 1))
	fi
fi

# ---------------------------------------------------------------------------
# Schema + auto-fix rendering invariants
# ---------------------------------------------------------------------------

schema_case_dir="$(mktemp -d "$TMPDIR_ROOT/schema.XXXXXX")"
stale_v1_envelope='{"schema_version":1,"summary":{"raw":0,"merged":0,"unique":0,"related":0,"dropped":0},"findings":[],"related":[]}'
if printf '%s\n' "$stale_v1_envelope" | bash "$RENDERER" >"$schema_case_dir/stdout" 2>"$schema_case_dir/stderr"; then
	echo "FAIL: stale-v1-schema-rejected (renderer exited zero)"
	fail_count=$((fail_count + 1))
elif grep -Eq "schema(_version)? mismatch.*got 1, expected 2" "$schema_case_dir/stderr"; then
	echo "PASS: stale-v1-schema-rejected"
	pass_count=$((pass_count + 1))
else
	echo "FAIL: stale-v1-schema-rejected (stderr missing expected mismatch)"
	echo "  stderr: $(cat "$schema_case_dir/stderr")"
	fail_count=$((fail_count + 1))
fi

auto_fix_case_dir="$(mktemp -d "$TMPDIR_ROOT/auto-fix.XXXXXX")"
cat >"$auto_fix_case_dir/envelope.json" <<'JSON'
{
  "schema_version": 2,
  "summary": {
    "raw": 3,
    "merged": 0,
    "unique": 3,
    "related": 0,
    "dropped": 0
  },
  "findings": [
    {
      "severity": "Minor",
      "category": "apply",
      "file": "src/a.py",
      "line": 1,
      "lenses": ["logic"],
      "summary": "would apply",
      "evidence": "audit precomputed would_apply",
      "suggestion": "apply it",
      "auto_fix_status": "would_apply"
    },
    {
      "severity": "Minor",
      "category": "reject",
      "file": "src/b.py",
      "line": 2,
      "lenses": ["logic"],
      "summary": "rejected kind",
      "evidence": "audit rejected kind",
      "suggestion": "surface it",
      "auto_fix_status": "rejected_kind"
    },
    {
      "severity": "Minor",
      "category": "proposal",
      "file": "src/c.py",
      "line": 3,
      "lenses": ["logic"],
      "summary": "has proposal only",
      "evidence": "auto_fix block alone is not enough",
      "suggestion": "surface it",
      "auto_fix": {
        "kind": "docstring_typo",
        "before": "recieve",
        "after": "receive",
        "scope": "file"
      }
    }
  ],
  "related": []
}
JSON

if ! bash "$RENDERER" <"$auto_fix_case_dir/envelope.json" >"$auto_fix_case_dir/rendered.md" 2>"$auto_fix_case_dir/stderr"; then
	echo "FAIL: auto-fixable-status-only-rendering (renderer exited non-zero)"
	echo "  stderr: $(cat "$auto_fix_case_dir/stderr")"
	fail_count=$((fail_count + 1))
else
	auto_fix_count="$(grep -c '\[AUTO-FIXABLE\]' "$auto_fix_case_dir/rendered.md" || true)"
	apply_line="$(grep -F -- '- **apply**' "$auto_fix_case_dir/rendered.md" || true)"
	reject_line="$(grep -F -- '- **reject**' "$auto_fix_case_dir/rendered.md" || true)"
	proposal_line="$(grep -F -- '- **proposal**' "$auto_fix_case_dir/rendered.md" || true)"
	if [[ "$auto_fix_count" == "1" ]] &&
		[[ "$apply_line" == *"[AUTO-FIXABLE]"* ]] &&
		[[ "$reject_line" != *"[AUTO-FIXABLE]"* ]] &&
		[[ "$proposal_line" != *"[AUTO-FIXABLE]"* ]]; then
		echo "PASS: auto-fixable-status-only-rendering"
		pass_count=$((pass_count + 1))
	else
		echo "FAIL: auto-fixable-status-only-rendering"
		echo "  expected exactly one [AUTO-FIXABLE] marker on the would_apply finding"
		sed 's/^/    /' "$auto_fix_case_dir/rendered.md"
		fail_count=$((fail_count + 1))
	fi
fi

# ---------------------------------------------------------------------------
# End-to-end audit + render: a reconciled envelope passed through the
# pre-render audit MUST emit `auto_fix_status` for each finding carrying
# an `auto_fix` block, and the renderer MUST surface `[AUTO-FIXABLE]`
# only for `would_apply`. Eligibility statuses for `rejected_kind` and
# `would_apply` cases are computed by `scripts/audit-auto-fix-eligibility.sh`
# from the JSON allowlist and a drift-check against the cited file:line.
# ---------------------------------------------------------------------------

AUDIT="$REPO_ROOT/scripts/audit-auto-fix-eligibility.sh"
if [[ -x "$AUDIT" || -f "$AUDIT" ]]; then
	audit_case_dir="$(mktemp -d "$TMPDIR_ROOT/audit.XXXXXX")"
	# Source file the auto_fix.before is asserted to match byte-for-byte
	# on line 1. The audit script resolves relative paths against $REPO_ROOT
	# when the cited file does not exist in cwd, so this sample lives under
	# the temp dir and is referenced by absolute path in the envelope.
	src_dir="$audit_case_dir/src"
	mkdir -p "$src_dir"
	printf '# recieve\n' >"$src_dir/foo.py"

	cat >"$audit_case_dir/envelope.json" <<JSON
{
  "schema_version": 2,
  "summary": {"raw": 2, "merged": 0, "unique": 2, "related": 0, "dropped": 0},
  "findings": [
    {
      "severity": "Minor",
      "category": "style",
      "file": "$src_dir/foo.py",
      "line": 1,
      "lenses": ["docs"],
      "summary": "would apply typo",
      "evidence": "matches before line 1",
      "suggestion": "fix it",
      "auto_fix": {"kind": "docstring_typo", "before": "# recieve", "after": "# receive", "scope": "file"}
    },
    {
      "severity": "Minor",
      "category": "naming",
      "file": "$src_dir/foo.py",
      "line": 1,
      "lenses": ["logic"],
      "summary": "kind outside allowlist",
      "evidence": "refactor_method not in allowlist",
      "suggestion": "surface it",
      "auto_fix": {"kind": "refactor_method", "before": "# recieve", "after": "# receive", "scope": "file"}
    }
  ],
  "related": []
}
JSON

	if ! bash "$AUDIT" --skill deep-review "$audit_case_dir/envelope.json" \
		>"$audit_case_dir/audited.json" 2>"$audit_case_dir/audit.stderr"; then
		echo "FAIL: audit-then-render-end-to-end (audit exited non-zero)"
		echo "  stderr: $(cat "$audit_case_dir/audit.stderr")"
		fail_count=$((fail_count + 1))
	elif ! bash "$RENDERER" <"$audit_case_dir/audited.json" \
		>"$audit_case_dir/rendered.md" 2>"$audit_case_dir/render.stderr"; then
		echo "FAIL: audit-then-render-end-to-end (renderer exited non-zero)"
		echo "  stderr: $(cat "$audit_case_dir/render.stderr")"
		fail_count=$((fail_count + 1))
	else
		marker_count="$(grep -c '\[AUTO-FIXABLE\]' "$audit_case_dir/rendered.md" || true)"
		apply_line="$(grep -F -- '- **style**' "$audit_case_dir/rendered.md" || true)"
		reject_line="$(grep -F -- '- **naming**' "$audit_case_dir/rendered.md" || true)"
		if [[ "$marker_count" == "1" ]] &&
			[[ "$apply_line" == *"[AUTO-FIXABLE]"* ]] &&
			[[ "$reject_line" != *"[AUTO-FIXABLE]"* ]]; then
			echo "PASS: audit-then-render-end-to-end (would_apply marked; rejected_kind not marked)"
			pass_count=$((pass_count + 1))
		else
			echo "FAIL: audit-then-render-end-to-end (annotation mismatch)"
			echo "  audited envelope:"
			sed 's/^/    /' "$audit_case_dir/audited.json"
			echo "  rendered:"
			sed 's/^/    /' "$audit_case_dir/rendered.md"
			fail_count=$((fail_count + 1))
		fi
	fi
fi

echo ""
echo "Summary: $pass_count passed, $fail_count failed"

if [[ $fail_count -ne 0 ]]; then
	exit 1
fi
exit 0
