#!/usr/bin/env bash
# Phase 5 stale renderer compatibility check.
#
# The snapshotted v1 renderer must reject every valid v2 envelope loudly.
# This proves stale renderer binaries do not silently drop auto_fix data.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
V1_RENDERER="$REPO_ROOT/tests/reconciliation/fixtures/render-reconciled-report-v1.sh"
RECONCILER="$REPO_ROOT/scripts/reconcile-findings.sh"
FIXTURE_DIR="$REPO_ROOT/tests/reconciliation/fixtures"

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

if [[ ! -x "$V1_RENDERER" ]]; then
	fail "preflight: v1 renderer fixture executable"
	echo ""
	echo "Summary: $pass_count passed, $fail_count failed"
	exit 1
fi

if [[ ! -x "$RECONCILER" ]]; then
	fail "preflight: reconciler executable"
	echo ""
	echo "Summary: $pass_count passed, $fail_count failed"
	exit 1
fi

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

shopt -s nullglob
fixtures=("$FIXTURE_DIR"/auto-fix-v2-*.jsonl)
shopt -u nullglob

if [[ ${#fixtures[@]} -eq 0 ]]; then
	fail "preflight: no auto-fix-v2 fixtures"
	echo ""
	echo "Summary: $pass_count passed, $fail_count failed"
	exit 1
fi

for fixture in "${fixtures[@]}"; do
	name="$(basename "$fixture")"
	case "$name" in
	*malformed*)
		continue
		;;
	esac

	case_dir="$scratch/${name%.jsonl}"
	mkdir -p "$case_dir"
	if ! bash "$RECONCILER" --skill deep-review <"$fixture" >"$case_dir/envelope.json" 2>"$case_dir/reconcile.stderr"; then
		fail "$name: reconciler could not build v2 envelope"
		sed 's/^/  /' "$case_dir/reconcile.stderr"
		continue
	fi

	if bash "$V1_RENDERER" <"$case_dir/envelope.json" >"$case_dir/stdout" 2>"$case_dir/stderr"; then
		fail "$name: v1 renderer exited zero on v2 envelope"
		sed 's/^/  /' "$case_dir/stdout"
	elif grep -Fq "schema_version mismatch (got 2, expected 1)" "$case_dir/stderr"; then
		pass "$name: v1 renderer rejects v2 schema"
	else
		fail "$name: v1 renderer stderr missing schema mismatch"
		sed 's/^/  /' "$case_dir/stderr"
	fi
done

echo ""
echo "Summary: $pass_count passed, $fail_count failed"
if [[ $fail_count -ne 0 ]]; then
	exit 1
fi
