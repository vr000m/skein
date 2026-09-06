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
#   (e) a pre-existing symlink at the target file path (pointing outside the
#       scratch repo) is refused rather than written through (defense-in-depth
#       symlink hardening; skipped when running as root).
#   (f) a pre-existing symlink at .review-plan/ itself (pointing outside the
#       scratch repo) is refused the same way (skipped when running as root).
#   (g) crash-safety: an interrupted/failing second write must not destroy
#       the previously-written valid file, and must not leave a stray temp
#       file behind either way.
#   (h) a pre-existing directory (not a symlink, not a regular file) at the
#       target path is refused with a clear "Could not persist findings
#       JSON: ..." message rather than the mv-into-directory false-success,
#       and the pre-existing directory is left untouched (no stray temp file
#       moved inside it).
#   (i) a multi-document input ("{} {}", two concatenated JSON objects) is
#       refused with exit 2 and a clear usage-error message, and no file is
#       written at the target path.
#   (j) a well-typed but incomplete envelope ({"schema_version": 2} with no
#       summary/findings/related) is refused with exit 2 and a clear
#       missing-keys message, and no file is written at the target path.
#   (k) a real SIGTERM delivered mid-`mv` (via a deliberately slow `mv`
#       shim) leaves no stray temp file behind -- regression coverage for
#       persist_atomic_write's EXIT trap (skipped when running as root).
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

# ---------------------------------------------------------------------------
# (e) symlinked target file: refuse to write through it
# ---------------------------------------------------------------------------

if [[ "$(id -u)" -eq 0 ]]; then
	echo "SKIP: (e) refuses to write through a symlinked target file (running as root)"
else
	case_e_dir="$TMPDIR_ROOT/case-e"
	make_scratch_repo "$case_e_dir"
	sample_envelope >"$case_e_dir/envelope.json"
	outside_target="$TMPDIR_ROOT/case-e-outside-target.json"
	printf 'outside content\n' >"$outside_target"
	mkdir -p "$case_e_dir/.review-plan"
	ln -s "$outside_target" "$case_e_dir/.review-plan/latest-claude.json"

	set +e
	(
		cd "$case_e_dir" && persist_state "$case_e_dir/envelope.json" \
			"docs/dev_plans/example-plan.md" \
			"deadbeefcafebabe0000000000000000000000" \
			"20260714-000005" \
			"claude"
	) >"$case_e_dir/stdout" 2>"$case_e_dir/stderr"
	e_exit=$?
	set -e

	if [[ $e_exit -eq 0 ]]; then
		fail "(e) refuses to write through a symlinked target file (script exited 0)"
		sed 's/^/    /' "$case_e_dir/stdout"
	elif ! grep -Fq "Could not persist findings JSON:" "$case_e_dir/stderr"; then
		fail "(e) refuses to write through a symlinked target file (missing documented stderr message)"
		sed 's/^/    /' "$case_e_dir/stderr"
	elif [[ "$(cat "$outside_target")" != "outside content" ]]; then
		fail "(e) refuses to write through a symlinked target file (outside file was overwritten)"
	else
		pass "(e) refuses to write through a symlinked target file"
	fi
fi

# ---------------------------------------------------------------------------
# (f) symlinked .review-plan/ directory: refuse to write through it
# ---------------------------------------------------------------------------

if [[ "$(id -u)" -eq 0 ]]; then
	echo "SKIP: (f) refuses to write through a symlinked .review-plan/ directory (running as root)"
else
	case_f_dir="$TMPDIR_ROOT/case-f"
	make_scratch_repo "$case_f_dir"
	sample_envelope >"$case_f_dir/envelope.json"
	outside_dir="$TMPDIR_ROOT/case-f-outside-dir"
	mkdir -p "$outside_dir"
	ln -s "$outside_dir" "$case_f_dir/.review-plan"

	set +e
	(
		cd "$case_f_dir" && persist_state "$case_f_dir/envelope.json" \
			"docs/dev_plans/example-plan.md" \
			"deadbeefcafebabe0000000000000000000000" \
			"20260714-000006" \
			"claude"
	) >"$case_f_dir/stdout" 2>"$case_f_dir/stderr"
	f_exit=$?
	set -e

	if [[ $f_exit -eq 0 ]]; then
		fail "(f) refuses to write through a symlinked .review-plan/ directory (script exited 0)"
		sed 's/^/    /' "$case_f_dir/stdout"
	elif ! grep -Fq "Could not persist findings JSON:" "$case_f_dir/stderr"; then
		fail "(f) refuses to write through a symlinked .review-plan/ directory (missing documented stderr message)"
		sed 's/^/    /' "$case_f_dir/stderr"
	elif [[ -f "$outside_dir/latest-claude.json" ]]; then
		fail "(f) refuses to write through a symlinked .review-plan/ directory (outside dir was written into)"
	else
		pass "(f) refuses to write through a symlinked .review-plan/ directory"
	fi
fi

# ---------------------------------------------------------------------------
# (g) crash-safety: an interrupted/failing second write must not destroy the
#     previously-written valid file (atomic temp-file + rename), and must not
#     leave a stray temp file behind either way.
# ---------------------------------------------------------------------------

if [[ "$(id -u)" -eq 0 ]]; then
	echo "SKIP: (g) interrupted write preserves the previous valid file (running as root)"
else
	case_g_dir="$TMPDIR_ROOT/case-g"
	make_scratch_repo "$case_g_dir"
	sample_envelope >"$case_g_dir/envelope.json"

	# First, a real successful run writes a valid latest-claude.json.
	if ! (
		cd "$case_g_dir" && persist_state "$case_g_dir/envelope.json" \
			"docs/dev_plans/example-plan.md" \
			"deadbeefcafebabe0000000000000000000000" \
			"20260714-000007" \
			"claude"
	) >"$case_g_dir/stdout-1" 2>"$case_g_dir/stderr-1"; then
		fail "(g) interrupted write preserves the previous valid file (setup: initial successful write failed)"
		sed 's/^/    /' "$case_g_dir/stderr-1"
	else
		target="$case_g_dir/.review-plan/latest-claude.json"
		cp "$target" "$case_g_dir/original-copy.json"

		# Simulate an interrupted/failing second write the same way
		# (c-supplementary) does: make .review-plan/ read-only so the
		# temp-file create/rename cannot land, without relying on root-proof
		# tricks. Any crash mid-write (OOM, Ctrl-C, disk full) should look
		# the same to $OUT_PATH as this: the old file must survive untouched.
		chmod 0555 "$case_g_dir/.review-plan"

		set +e
		(
			cd "$case_g_dir" && persist_state "$case_g_dir/envelope.json" \
				"docs/dev_plans/example-plan.md" \
				"deadbeefcafebabe0000000000000000000000" \
				"20260714-000008" \
				"claude"
		) >"$case_g_dir/stdout-2" 2>"$case_g_dir/stderr-2"
		g_exit=$?
		set -e
		chmod 0755 "$case_g_dir/.review-plan"

		if [[ $g_exit -eq 0 ]]; then
			fail "(g) interrupted write preserves the previous valid file (second write unexpectedly exited 0)"
			sed 's/^/    /' "$case_g_dir/stdout-2"
		elif ! grep -Fq "Could not persist findings JSON:" "$case_g_dir/stderr-2"; then
			fail "(g) interrupted write preserves the previous valid file (missing documented stderr message)"
			sed 's/^/    /' "$case_g_dir/stderr-2"
		elif [[ ! -f "$target" ]]; then
			fail "(g) interrupted write preserves the previous valid file (old file is gone)"
		elif ! cmp -s "$case_g_dir/original-copy.json" "$target"; then
			fail "(g) interrupted write preserves the previous valid file (old file was truncated/corrupted)"
			diff "$case_g_dir/original-copy.json" "$target" | sed 's/^/    /' || true
		elif compgen -G "$case_g_dir/.review-plan/*.tmp.*" >/dev/null 2>&1; then
			fail "(g) interrupted write preserves the previous valid file (stray .tmp.* file left behind)"
			while IFS= read -r _diag_line; do echo "    $_diag_line"; done < <(ls -la "$case_g_dir/.review-plan")
		else
			pass "(g) interrupted write preserves the previous valid file, and leaves no stray temp file"
		fi
	fi
fi

# ---------------------------------------------------------------------------
# (h) pre-existing directory at the target path: refuse rather than mv-into
# ---------------------------------------------------------------------------

case_h_dir="$TMPDIR_ROOT/case-h"
make_scratch_repo "$case_h_dir"
sample_envelope >"$case_h_dir/envelope.json"
mkdir -p "$case_h_dir/.review-plan/latest-claude.json"

set +e
(
	cd "$case_h_dir" && persist_state "$case_h_dir/envelope.json" \
		"docs/dev_plans/example-plan.md" \
		"deadbeefcafebabe0000000000000000000000" \
		"20260714-000009" \
		"claude"
) >"$case_h_dir/stdout" 2>"$case_h_dir/stderr"
h_exit=$?
set -e

if [[ $h_exit -eq 0 ]]; then
	fail "(h) refuses to write when the target path is a pre-existing directory (script exited 0)"
	sed 's/^/    /' "$case_h_dir/stdout"
elif ! grep -Fq "Could not persist findings JSON:" "$case_h_dir/stderr"; then
	fail "(h) refuses to write when the target path is a pre-existing directory (missing documented stderr message)"
	sed 's/^/    /' "$case_h_dir/stderr"
elif [[ ! -d "$case_h_dir/.review-plan/latest-claude.json" ]]; then
	fail "(h) refuses to write when the target path is a pre-existing directory (target directory no longer present)"
elif [[ -n "$(find "$case_h_dir/.review-plan/latest-claude.json" -mindepth 1 2>/dev/null)" ]]; then
	fail "(h) refuses to write when the target path is a pre-existing directory (a stray temp file was moved inside it)"
	while IFS= read -r _diag_line; do echo "    $_diag_line"; done < <(ls -la "$case_h_dir/.review-plan/latest-claude.json")
else
	pass "(h) refuses to write when the target path is a pre-existing directory, and leaves it untouched"
fi

# ---------------------------------------------------------------------------
# (i) multi-document input ("{} {}"): refuse rather than silently persisting
#     a concatenated multi-document blob
# ---------------------------------------------------------------------------

case_i_dir="$TMPDIR_ROOT/case-i"
make_scratch_repo "$case_i_dir"
printf '{} {}' >"$case_i_dir/envelope.json"

set +e
(
	cd "$case_i_dir" && persist_state "$case_i_dir/envelope.json" \
		"docs/dev_plans/example-plan.md" \
		"deadbeefcafebabe0000000000000000000000" \
		"20260714-000010" \
		"claude"
) >"$case_i_dir/stdout" 2>"$case_i_dir/stderr"
i_exit=$?
set -e

if [[ $i_exit -ne 2 ]]; then
	fail "(i) refuses multi-document input (expected exit 2, got $i_exit)"
	sed 's/^/    /' "$case_i_dir/stderr"
elif ! grep -Fq "persist-review-state:" "$case_i_dir/stderr"; then
	fail "(i) refuses multi-document input (missing usage-error message)"
	sed 's/^/    /' "$case_i_dir/stderr"
elif [[ -e "$case_i_dir/.review-plan" ]]; then
	fail "(i) refuses multi-document input (a file was written despite rejection)"
	while IFS= read -r _diag_line; do echo "    $_diag_line"; done < <(ls -la "$case_i_dir/.review-plan")
else
	pass "(i) refuses multi-document input, writes nothing"
fi

# ---------------------------------------------------------------------------
# (j) well-typed but incomplete envelope ({"schema_version": 2} only):
#     refuse rather than silently persisting an unusable state file
# ---------------------------------------------------------------------------

case_j_dir="$TMPDIR_ROOT/case-j"
make_scratch_repo "$case_j_dir"
printf '{"schema_version": 2}' >"$case_j_dir/envelope.json"

set +e
(
	cd "$case_j_dir" && persist_state "$case_j_dir/envelope.json" \
		"docs/dev_plans/example-plan.md" \
		"deadbeefcafebabe0000000000000000000000" \
		"20260714-000011" \
		"claude"
) >"$case_j_dir/stdout" 2>"$case_j_dir/stderr"
j_exit=$?
set -e

if [[ $j_exit -ne 2 ]]; then
	fail "(j) refuses incomplete envelope missing summary/findings/related (expected exit 2, got $j_exit)"
	sed 's/^/    /' "$case_j_dir/stderr"
elif ! grep -Fq "missing required top-level keys" "$case_j_dir/stderr"; then
	fail "(j) refuses incomplete envelope missing summary/findings/related (missing the documented missing-keys message)"
	sed 's/^/    /' "$case_j_dir/stderr"
elif [[ -e "$case_j_dir/.review-plan" ]]; then
	fail "(j) refuses incomplete envelope missing summary/findings/related (a file was written despite rejection)"
	while IFS= read -r _diag_line; do echo "    $_diag_line"; done < <(ls -la "$case_j_dir/.review-plan")
else
	pass "(j) refuses incomplete envelope missing summary/findings/related, writes nothing"
fi

# ---------------------------------------------------------------------------
# (k) a real SIGTERM delivered mid-`mv` leaves no stray temp file
#
# Regression coverage for a code-review finding on the persist-common.sh
# extraction: the original inline atomic-write code registered
# `trap cleanup_tmp EXIT`, which fires on ANY process termination including
# signals. The extracted persist_atomic_write initially only did explicit
# `rm -f` on controlled failure returns (write/mv command itself failing),
# dropping signal-interruption coverage -- fixed by registering an EXIT trap
# once the temp file exists. Case (c)/(c-supplementary) above simulate a
# *controlled* failure via a permission-bit trick, which already went
# through the explicit-rm path even before that fix and would NOT have
# caught this regression. This case instead sends a real SIGTERM while a
# shimmed, deliberately slow `mv` is mid-flight, exercising the trap itself.
# ---------------------------------------------------------------------------

if [[ "$(id -u)" -eq 0 ]]; then
	echo "SKIP: (k) SIGTERM mid-mv leaves no stray temp file (running as root)"
else
	case_k_dir="$TMPDIR_ROOT/case-k"
	make_scratch_repo "$case_k_dir"
	sample_envelope >"$case_k_dir/envelope.json"

	slow_bin="$case_k_dir/slow-bin"
	mkdir -p "$slow_bin"
	cat >"$slow_bin/mv" <<'EOF'
#!/bin/sh
sleep 2
exec /bin/mv "$@"
EOF
	chmod +x "$slow_bin/mv"

	set +e
	(
		cd "$case_k_dir" || exit 1
		PATH="$slow_bin:$PATH" bash "$SCRIPT" --harness claude \
			--plan-path "docs/dev_plans/example-plan.md" \
			--plan-hash "deadbeefcafebabe0000000000000000000000" \
			--run-id "20260716-000001" \
			<"$case_k_dir/envelope.json" >"$case_k_dir/stdout" 2>"$case_k_dir/stderr" &
		k_pid=$!
		sleep 0.5
		kill -TERM "$k_pid" 2>/dev/null
		wait "$k_pid"
	)
	k_exit=$?
	set -e

	stray="$(compgen -G "$case_k_dir/.review-plan/*.tmp.*" 2>/dev/null || true)"
	if [[ $k_exit -lt 128 ]]; then
		fail "(k) SIGTERM mid-mv leaves no stray temp file (process did not appear to be signaled, exit=$k_exit -- mv shim may be too fast; not a real test of the trap)"
	elif [[ -n "$stray" ]]; then
		fail "(k) SIGTERM mid-mv leaves no stray temp file (found: $stray)"
	else
		pass "(k) SIGTERM mid-mv leaves no stray temp file"
	fi
fi

# ---------------------------------------------------------------------------
# (R8-G4b) a duplicated TOP-LEVEL envelope key must be refused, not persisted.
#
# The other STATE-FILE caller of the duplicate-key wire rule (round 8, F7): the
# helper was registered for all four persist-common.sh callers in round 7 and
# wired into only the two LENS ones, so an externally supplied envelope
# spelling a key twice silently lost the earlier assignment on the way in.
# ---------------------------------------------------------------------------

case_r8g4b_dir="$TMPDIR_ROOT/case-r8g4b"
make_scratch_repo "$case_r8g4b_dir"
cat >"$case_r8g4b_dir/envelope.json" <<'JSON'
{
  "schema_version": 2,
  "summary": {"raw": 1, "merged": 0, "unique": 1, "related": 0, "dropped": 0},
  "findings": [],
  "findings": [{"severity": "Minor", "category": "naming", "file": "src/foo.py", "line": 12, "lenses": ["logic"], "summary": "s", "evidence": "e", "suggestion": "x"}],
  "related": []
}
JSON

if (
	cd "$case_r8g4b_dir" && persist_state "$case_r8g4b_dir/envelope.json" \
		"docs/dev_plans/example-plan.md" \
		"deadbeefcafebabe0000000000000000000000" \
		"20260714-000009" \
		"claude"
) >"$case_r8g4b_dir/stdout" 2>"$case_r8g4b_dir/stderr"; then
	fail "(R8-G4b) a duplicated envelope key must exit 2 (script exited 0 and persisted)"
else
	r8g4b_err="$(cat "$case_r8g4b_dir/stderr")"
	if [[ "$r8g4b_err" == *"duplicate key"* && "$r8g4b_err" == *"findings"* ]] &&
		[[ ! -f "$case_r8g4b_dir/.review-plan/latest-claude.json" ]]; then
		pass "(R8-G4b) a duplicated top-level envelope key exits 2, names the key, and persists nothing"
	else
		fail "(R8-G4b) err='$r8g4b_err' target-exists=$([[ -f "$case_r8g4b_dir/.review-plan/latest-claude.json" ]] && echo yes || echo no)"
	fi
fi

echo ""
echo "Summary: $pass_count passed, $fail_count failed"

if [[ $fail_count -ne 0 ]]; then
	exit 1
fi
exit 0
