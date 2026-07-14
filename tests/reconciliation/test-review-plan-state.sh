#!/usr/bin/env bash
# Phase 5 test harness for scripts/persist-review-state.sh
# (`review-plan`'s Review State persistence script).
#
# Contract under test (from
# docs/dev_plans/20260712-feature-deep-review-compact-output.md, Phase 5):
#
#   scripts/persist-review-state.sh --harness claude|codex --plan-path <path> \
#       --plan-hash <sha1> --run-id <id> [envelope.json|-]
#
#     Reads the reconciled v2 envelope JSON (as emitted by
#     scripts/reconcile-findings.sh --skill review-plan) from the positional
#     envelope-path argument, or stdin when it is "-" or omitted.
#     Root-anchors via git rev-parse --show-toplevel.
#     Writes the envelope, extended with exactly three top-level fields
#     (plan_path, plan_hash, run_id -- no wrapper object, no second
#     schema_version), to .review-plan/latest-<harness>.json.
#     Exit 0 on success; exit 2 on a usage error; exit 1 on a best-effort
#     write failure, printing "Could not persist findings JSON: <reason>"
#     to stderr.
#
#   NOTE: the plan left stdin-vs-args for plan_path/plan_hash/run_id as the
#   implementer's choice, "documented in its own header". This harness
#   targets the flag-based CLI documented in scripts/persist-review-state.sh's
#   own header (confirmed against the landed script), passing the envelope
#   on stdin.
#
# Covers plan Phase 5's four required cases:
#   (a) synthetic envelope + plan_path/plan_hash/run_id -> written file has
#       all required top-level keys.
#   (b) a pre-existing malformed/corrupt file at the target path is
#       successfully overwritten with the new envelope.
#   (c) a UID-robust simulated write failure (target path's parent path
#       component is a regular file, not a directory) makes the script exit
#       non-zero and print "Could not persist findings JSON: <reason>" to
#       stderr.
#   (d) a superset envelope (v2 reconciled shape + plan_path/plan_hash/
#       run_id) piped through scripts/render-reconciled-report.sh renders
#       without error, confirming the renderer's forward-compat tolerance
#       of unrecognized top-level keys.
#
# Exit 0 on all-pass, 1 on any failure.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/persist-review-state.sh"
RENDERER="$REPO_ROOT/scripts/render-reconciled-report.sh"

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

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

if [[ ! -x "$SCRIPT" && ! -f "$SCRIPT" ]]; then
	fail "preflight (scripts/persist-review-state.sh not found at $SCRIPT)"
	echo ""
	echo "Summary: $pass_count passed, $fail_count failed"
	exit 1
fi

if [[ ! -x "$RENDERER" && ! -f "$RENDERER" ]]; then
	fail "preflight (scripts/render-reconciled-report.sh not found at $RENDERER)"
	echo ""
	echo "Summary: $pass_count passed, $fail_count failed"
	exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
	fail "preflight (jq required by this test harness, not found on PATH)"
	echo ""
	echo "Summary: $pass_count passed, $fail_count failed"
	exit 1
fi

# A minimal, structurally valid v2 reconciled envelope (as emitted by
# scripts/reconcile-findings.sh --skill review-plan).
sample_envelope() {
	cat <<'JSON'
{
  "schema_version": 2,
  "summary": {"raw": 1, "merged": 0, "unique": 1, "related": 0, "dropped": 0},
  "findings": [
    {
      "severity": "Minor",
      "category": "naming",
      "file": "src/foo.py",
      "line": 12,
      "lenses": ["logic"],
      "summary": "variable name is unclear",
      "evidence": "single-letter var `x` used across 40 lines",
      "suggestion": "rename to something descriptive"
    }
  ],
  "related": []
}
JSON
}

# persist_state <envelope_file> <plan_path> <plan_hash> <run_id> <harness>
#   Invokes the script under test per the CLI contract documented in its own
#   header (see NOTE above). Runs from a subshell with a fixed cwd so
#   WORKTREE_ROOT resolves to the scratch repo, not $REPO_ROOT.
persist_state() {
	local envelope_file="$1" plan_path="$2" plan_hash="$3" run_id="$4" harness="$5"
	bash "$SCRIPT" --harness "$harness" --plan-path "$plan_path" \
		--plan-hash "$plan_hash" --run-id "$run_id" <"$envelope_file"
}

# Sets up a scratch git worktree so WORKTREE_ROOT-anchored writes (and the
# .review-plan/ directory they create) don't touch this repository's own
# working tree.
make_scratch_repo() {
	local dir="$1"
	mkdir -p "$dir"
	(
		cd "$dir"
		git init -q
		git config user.email "test@example.com"
		git config user.name "Test"
		echo "placeholder" >README.md
		git add README.md
		git commit -q -m "init"
	)
}

# ---------------------------------------------------------------------------
# (a) writes a file with all required top-level keys
# ---------------------------------------------------------------------------

case_a_dir="$TMPDIR_ROOT/case-a"
make_scratch_repo "$case_a_dir"
sample_envelope >"$case_a_dir/envelope.json"

if (
	cd "$case_a_dir" && persist_state "$case_a_dir/envelope.json" \
		"docs/dev_plans/example-plan.md" \
		"deadbeefcafebabe0000000000000000000000" \
		"20260714-000000" \
		"claude"
) >"$case_a_dir/stdout" 2>"$case_a_dir/stderr"; then
	target="$case_a_dir/.review-plan/latest-claude.json"
	if [[ ! -f "$target" ]]; then
		fail "(a) writes required top-level keys (no file at $target)"
	else
		missing_keys=""
		for key in schema_version plan_path plan_hash run_id summary findings related; do
			if ! jq -e --arg k "$key" 'has($k)' "$target" >/dev/null 2>&1; then
				missing_keys="$missing_keys $key"
			fi
		done
		if [[ -z "$missing_keys" ]]; then
			pass "(a) writes required top-level keys"
		else
			fail "(a) writes required top-level keys (missing:$missing_keys)"
			sed 's/^/    /' "$target"
		fi
	fi
else
	fail "(a) writes required top-level keys (script exited non-zero)"
	sed 's/^/    /' "$case_a_dir/stderr"
fi

# ---------------------------------------------------------------------------
# (b) overwrites a pre-existing malformed/corrupt file at the target path
# ---------------------------------------------------------------------------

case_b_dir="$TMPDIR_ROOT/case-b"
make_scratch_repo "$case_b_dir"
sample_envelope >"$case_b_dir/envelope.json"
mkdir -p "$case_b_dir/.review-plan"
printf '{not valid json,,,' >"$case_b_dir/.review-plan/latest-claude.json"

if (
	cd "$case_b_dir" && persist_state "$case_b_dir/envelope.json" \
		"docs/dev_plans/example-plan.md" \
		"deadbeefcafebabe0000000000000000000000" \
		"20260714-000001" \
		"claude"
) >"$case_b_dir/stdout" 2>"$case_b_dir/stderr"; then
	target="$case_b_dir/.review-plan/latest-claude.json"
	if jq -e 'has("schema_version") and has("plan_path")' "$target" >/dev/null 2>&1; then
		pass "(b) overwrites pre-existing malformed file"
	else
		fail "(b) overwrites pre-existing malformed file (target is still malformed)"
		sed 's/^/    /' "$target"
	fi
else
	fail "(b) overwrites pre-existing malformed file (script exited non-zero)"
	sed 's/^/    /' "$case_b_dir/stderr"
fi

# ---------------------------------------------------------------------------
# (c) simulated write failure (UID-robust: parent path component is a file)
# ---------------------------------------------------------------------------

case_c_dir="$TMPDIR_ROOT/case-c"
make_scratch_repo "$case_c_dir"
sample_envelope >"$case_c_dir/envelope.json"
# .review-plan is a regular file, not a directory, so mkdir/write for
# .review-plan/latest-claude.json must fail regardless of permission bits
# (root-proof; no reliance on chmod).
printf 'not a directory\n' >"$case_c_dir/.review-plan"

set +e
(
	cd "$case_c_dir" && persist_state "$case_c_dir/envelope.json" \
		"docs/dev_plans/example-plan.md" \
		"deadbeefcafebabe0000000000000000000000" \
		"20260714-000002" \
		"claude"
) >"$case_c_dir/stdout" 2>"$case_c_dir/stderr"
c_exit=$?
set -e

if [[ $c_exit -eq 0 ]]; then
	fail "(c) write failure exits non-zero (script exited 0 with $case_c_dir/.review-plan as a plain file)"
	sed 's/^/    /' "$case_c_dir/stdout"
elif grep -Fq "Could not persist findings JSON:" "$case_c_dir/stderr"; then
	pass "(c) write failure exits non-zero and prints the documented stderr message"
else
	fail "(c) write failure exits non-zero, but stderr is missing the documented message"
	sed 's/^/    /' "$case_c_dir/stderr"
fi

# Supplementary permission-bit variant (skipped when running as root, where
# permission bits don't block writes).
if [[ "$(id -u)" -eq 0 ]]; then
	echo "SKIP: (c-supplementary) permission-bit write failure (running as root)"
else
	case_c2_dir="$TMPDIR_ROOT/case-c-perm"
	make_scratch_repo "$case_c2_dir"
	sample_envelope >"$case_c2_dir/envelope.json"
	mkdir -p "$case_c2_dir/.review-plan"
	chmod 0555 "$case_c2_dir/.review-plan"

	set +e
	(
		cd "$case_c2_dir" && persist_state "$case_c2_dir/envelope.json" \
			"docs/dev_plans/example-plan.md" \
			"deadbeefcafebabe0000000000000000000000" \
			"20260714-000003" \
			"claude"
	) >"$case_c2_dir/stdout" 2>"$case_c2_dir/stderr"
	c2_exit=$?
	set -e
	chmod 0755 "$case_c2_dir/.review-plan"

	if [[ $c2_exit -eq 0 ]]; then
		fail "(c-supplementary) write failure exits non-zero (read-only .review-plan dir, script exited 0)"
		sed 's/^/    /' "$case_c2_dir/stdout"
	elif grep -Fq "Could not persist findings JSON:" "$case_c2_dir/stderr"; then
		pass "(c-supplementary) write failure exits non-zero and prints the documented stderr message (permission-bit variant)"
	else
		fail "(c-supplementary) write failure exits non-zero, but stderr is missing the documented message"
		sed 's/^/    /' "$case_c2_dir/stderr"
	fi
fi

# ---------------------------------------------------------------------------
# (d) superset envelope (v2 + plan_path/plan_hash/run_id) renders cleanly
#     through scripts/render-reconciled-report.sh
# ---------------------------------------------------------------------------

case_d_dir="$TMPDIR_ROOT/case-d"
mkdir -p "$case_d_dir"
cat >"$case_d_dir/superset-envelope.json" <<'JSON'
{
  "schema_version": 2,
  "plan_path": "docs/dev_plans/example-plan.md",
  "plan_hash": "deadbeefcafebabe0000000000000000000000",
  "run_id": "20260714-000004",
  "summary": {"raw": 1, "merged": 0, "unique": 1, "related": 0, "dropped": 0},
  "findings": [
    {
      "severity": "Minor",
      "category": "naming",
      "file": "src/foo.py",
      "line": 12,
      "lenses": ["logic"],
      "summary": "variable name is unclear",
      "evidence": "single-letter var `x` used across 40 lines",
      "suggestion": "rename to something descriptive"
    }
  ],
  "related": []
}
JSON

if bash "$RENDERER" <"$case_d_dir/superset-envelope.json" >"$case_d_dir/rendered.md" 2>"$case_d_dir/stderr"; then
	if [[ -s "$case_d_dir/rendered.md" ]]; then
		pass "(d) renderer tolerates superset envelope (plan_path/plan_hash/run_id)"
	else
		fail "(d) renderer tolerates superset envelope (exited zero but produced empty output)"
	fi
else
	fail "(d) renderer tolerates superset envelope (renderer exited non-zero)"
	sed 's/^/    /' "$case_d_dir/stderr"
fi

echo ""
echo "Summary: $pass_count passed, $fail_count failed"

if [[ $fail_count -ne 0 ]]; then
	exit 1
fi
exit 0
