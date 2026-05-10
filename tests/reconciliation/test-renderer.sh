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
#   3. Each finding renders Lenses, Evidence, Suggestion sub-bullets;
#      Related findings sub-bullet appears only when the JSON envelope's
#      `related` array references this (file, line, category).
#   4. Renderer is deterministic: identical envelope -> byte-identical
#      markdown body fragment.
#
# Exit 0 on all-pass, 1 on any mismatch.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RENDERER="$REPO_ROOT/scripts/render-reconciled-report.sh"
EXPECTED_DIR="$REPO_ROOT/tests/reconciliation/expected"

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

	if ! bash "$RENDERER" <"$envelope" >"$actual_file" 2>"$case_dir/stderr"; then
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

		bash "$RENDERER" <"$envelope" >"$jq_rendered"
		PATH="$no_jq_bin" bash "$RENDERER" <"$envelope" >"$awk_rendered"

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

echo ""
echo "Summary: $pass_count passed, $fail_count failed"

if [[ $fail_count -ne 0 ]]; then
	exit 1
fi
exit 0
