#!/usr/bin/env bash
# Test harness for scripts/persist-deep-review-state.sh
# (`/deep-review`'s Review State persistence script).
#
# Contract under test (see the script's own header for the full contract):
#
#   scripts/persist-deep-review-state.sh --harness claude|codex --run-id <id> \
#       --base-commit <sha> --head-commit <sha> --diff-hash <sha> \
#       --review-focus-hash <sha-or-empty> [lenses.json|-]
#
#     Reads the raw per-lens status/findings JSON object (one key per lens,
#     e.g. logic/security/spec/architecture/documentation) from the
#     positional lenses-path argument, or stdin when it is "-" or omitted.
#     Root-anchors via git rev-parse --show-toplevel.
#     Wraps the input as the `lenses` key of a new top-level object alongside
#     schema_version (stamped 1 by the script) and the five run-metadata
#     fields, writing atomically (temp file + rename) to
#     .deep-review/latest-<harness>.json.
#     Exit 0 on success; exit 2 on a usage error; exit 1 on a best-effort
#     write failure, printing "Could not persist findings JSON: <reason>"
#     to stderr.
#
# Covers:
#   (a) synthetic per-lens payload + required flags -> written file has all
#       documented top-level keys (schema_version, run_id, base_commit,
#       head_commit, diff_hash, review_focus_hash, lenses), including the
#       empty-string --review-focus-hash case, and leaves no stray temp
#       files behind.
#   (b) a pre-existing malformed/corrupt file at the target path is
#       successfully overwritten with the new state object.
#   (c) a UID-robust simulated write failure (target path's parent path
#       component is a regular file, not a directory) makes the script exit
#       non-zero, print "Could not persist findings JSON: <reason>" to
#       stderr, and leave no stray temp files behind.
#   (d) a pre-existing symlink at the target file path (pointing outside the
#       scratch repo) is refused rather than written through (defense-in-depth
#       symlink hardening; skipped when running as root).
#   (e) a pre-existing symlink at .deep-review/ itself (pointing outside the
#       scratch repo) is refused the same way (skipped when running as root).
#   (f) a pre-existing directory (not a symlink, not a regular file) at the
#       target path is refused with a clear "Could not persist findings
#       JSON: ..." message rather than the mv-into-directory false-success,
#       and the pre-existing directory is left untouched (no stray temp file
#       moved inside it).
#   (g) a multi-document input ("{} {}", two concatenated JSON objects) is
#       refused with exit 2 and a clear usage-error message, and no file is
#       written at the target path.
#   (h) a real SIGTERM delivered mid-`mv` (via a deliberately slow `mv`
#       shim) leaves no stray temp file behind -- regression coverage for
#       persist_atomic_write's EXIT trap (skipped when running as root).
#
# Exit 0 on all-pass, 1 on any failure.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/persist-deep-review-state.sh"

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
	fail "preflight (scripts/persist-deep-review-state.sh not found at $SCRIPT)"
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

# A minimal, structurally valid raw per-lens payload (the shape the
# orchestrator assembles after Step 2 — see SKILL.md's Review State suggested
# schema).
sample_lenses() {
	cat <<'JSON'
{
  "logic": {
    "status": "completed",
    "model": "opus",
    "effort": "high",
    "findings": []
  },
  "security": {
    "status": "skipped",
    "reason": "no Review Focus specs to check"
  }
}
JSON
}

# persist_state <lenses_file> <harness> <run_id> <base_commit> <head_commit> <diff_hash> <review_focus_hash>
#   Invokes the script under test per the CLI contract documented in its own
#   header. Runs from a subshell with a fixed cwd so WORKTREE_ROOT resolves
#   to the scratch repo, not $REPO_ROOT.
persist_state() {
	local lenses_file="$1" harness="$2" run_id="$3" base_commit="$4" head_commit="$5" diff_hash="$6" review_focus_hash="$7"
	bash "$SCRIPT" --harness "$harness" --run-id "$run_id" \
		--base-commit "$base_commit" --head-commit "$head_commit" \
		--diff-hash "$diff_hash" --review-focus-hash "$review_focus_hash" \
		<"$lenses_file"
}

# Sets up a scratch git worktree so WORKTREE_ROOT-anchored writes (and the
# .deep-review/ directory they create) don't touch this repository's own
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

# no_stray_temp_files <dir>
#   Fails (echoing details) if any leftover *.tmp*/temp-named artifact from
#   the script's mktemp pattern (".latest-<harness>.json.XXXXXX") remains in
#   <dir>/.deep-review.
stray_temp_files() {
	local dir="$1"
	find "$dir/.deep-review" -maxdepth 1 -name '.latest-*.json.*' 2>/dev/null
}

# ---------------------------------------------------------------------------
# (a) writes a file with all required top-level keys, empty review-focus-hash
#     tolerated, and no stray temp files left behind
# ---------------------------------------------------------------------------

case_a_dir="$TMPDIR_ROOT/case-a"
make_scratch_repo "$case_a_dir"
sample_lenses >"$case_a_dir/lenses.json"

if (
	cd "$case_a_dir" && persist_state "$case_a_dir/lenses.json" \
		"claude" "2026-07-15T00:00:00Z" "abc1234" "def5678" "sha256:deadbeef" ""
) >"$case_a_dir/stdout" 2>"$case_a_dir/stderr"; then
	target="$case_a_dir/.deep-review/latest-claude.json"
	if [[ ! -f "$target" ]]; then
		fail "(a) writes required top-level keys (no file at $target)"
	else
		missing_keys=""
		for key in schema_version run_id base_commit head_commit diff_hash review_focus_hash lenses; do
			if ! jq -e --arg k "$key" 'has($k)' "$target" >/dev/null 2>&1; then
				missing_keys="$missing_keys $key"
			fi
		done
		if [[ -z "$missing_keys" ]]; then
			if [[ "$(jq -r '.schema_version' "$target")" == "1" ]]; then
				pass "(a) writes required top-level keys (schema_version=1, empty review_focus_hash tolerated)"
			else
				fail "(a) writes required top-level keys (schema_version is not 1)"
				sed 's/^/    /' "$target"
			fi
		else
			fail "(a) writes required top-level keys (missing:$missing_keys)"
			sed 's/^/    /' "$target"
		fi
	fi
	stray="$(stray_temp_files "$case_a_dir")"
	if [[ -z "$stray" ]]; then
		pass "(a) leaves no stray temp files behind after success"
	else
		fail "(a) leaves no stray temp files behind after success (found: $stray)"
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
sample_lenses >"$case_b_dir/lenses.json"
mkdir -p "$case_b_dir/.deep-review"
printf '{not valid json,,,' >"$case_b_dir/.deep-review/latest-claude.json"

if (
	cd "$case_b_dir" && persist_state "$case_b_dir/lenses.json" \
		"claude" "2026-07-15T00:00:01Z" "abc1234" "def5678" "sha256:deadbeef" "sha256:focus"
) >"$case_b_dir/stdout" 2>"$case_b_dir/stderr"; then
	target="$case_b_dir/.deep-review/latest-claude.json"
	if jq -e 'has("schema_version") and has("lenses")' "$target" >/dev/null 2>&1; then
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
# (c) simulated write failure (UID-robust: parent path component is a file),
#     and no stray temp files left behind after the failure
# ---------------------------------------------------------------------------

case_c_dir="$TMPDIR_ROOT/case-c"
make_scratch_repo "$case_c_dir"
sample_lenses >"$case_c_dir/lenses.json"
# .deep-review is a regular file, not a directory, so mkdir for
# .deep-review/latest-claude.json must fail regardless of permission bits
# (root-proof; no reliance on chmod).
printf 'not a directory\n' >"$case_c_dir/.deep-review"

set +e
(
	cd "$case_c_dir" && persist_state "$case_c_dir/lenses.json" \
		"claude" "2026-07-15T00:00:02Z" "abc1234" "def5678" "sha256:deadbeef" "sha256:focus"
) >"$case_c_dir/stdout" 2>"$case_c_dir/stderr"
c_exit=$?
set -e

if [[ $c_exit -eq 0 ]]; then
	fail "(c) write failure exits non-zero (script exited 0 with $case_c_dir/.deep-review as a plain file)"
	sed 's/^/    /' "$case_c_dir/stdout"
elif grep -Fq "Could not persist findings JSON:" "$case_c_dir/stderr"; then
	pass "(c) write failure exits non-zero and prints the documented stderr message"
else
	fail "(c) write failure exits non-zero, but stderr is missing the documented message"
	sed 's/^/    /' "$case_c_dir/stderr"
fi

# Since .deep-review is itself a plain file here (not a directory), there is
# no .deep-review/ directory for a temp file to have landed in — the
# stray-temp-file check for this failure mode is covered by the permission-bit
# variant below instead, where .deep-review/ does exist as a directory.

# Supplementary permission-bit variant (skipped when running as root, where
# permission bits don't block writes). This variant exercises the mktemp
# failure path with an actual (unwritable) .deep-review/ directory present,
# so it also verifies no stray temp file is left behind.
if [[ "$(id -u)" -eq 0 ]]; then
	echo "SKIP: (c-supplementary) permission-bit write failure (running as root)"
else
	case_c2_dir="$TMPDIR_ROOT/case-c-perm"
	make_scratch_repo "$case_c2_dir"
	sample_lenses >"$case_c2_dir/lenses.json"
	mkdir -p "$case_c2_dir/.deep-review"
	chmod 0555 "$case_c2_dir/.deep-review"

	set +e
	(
		cd "$case_c2_dir" && persist_state "$case_c2_dir/lenses.json" \
			"claude" "2026-07-15T00:00:03Z" "abc1234" "def5678" "sha256:deadbeef" "sha256:focus"
	) >"$case_c2_dir/stdout" 2>"$case_c2_dir/stderr"
	c2_exit=$?
	set -e

	if [[ $c2_exit -eq 0 ]]; then
		fail "(c-supplementary) write failure exits non-zero (read-only .deep-review dir, script exited 0)"
		sed 's/^/    /' "$case_c2_dir/stdout"
	elif grep -Fq "Could not persist findings JSON:" "$case_c2_dir/stderr"; then
		pass "(c-supplementary) write failure exits non-zero and prints the documented stderr message (permission-bit variant)"
	else
		fail "(c-supplementary) write failure exits non-zero, but stderr is missing the documented message"
		sed 's/^/    /' "$case_c2_dir/stderr"
	fi

	stray="$(chmod 0755 "$case_c2_dir/.deep-review" && stray_temp_files "$case_c2_dir")"
	if [[ -z "$stray" ]]; then
		pass "(c-supplementary) leaves no stray temp files behind after failure"
	else
		fail "(c-supplementary) leaves no stray temp files behind after failure (found: $stray)"
	fi
fi

# ---------------------------------------------------------------------------
# (d) symlinked target file: refuse to write through it
# ---------------------------------------------------------------------------

if [[ "$(id -u)" -eq 0 ]]; then
	echo "SKIP: (d) refuses to write through a symlinked target file (running as root)"
else
	case_d_dir="$TMPDIR_ROOT/case-d"
	make_scratch_repo "$case_d_dir"
	sample_lenses >"$case_d_dir/lenses.json"
	outside_target="$TMPDIR_ROOT/case-d-outside-target.json"
	printf 'outside content\n' >"$outside_target"
	mkdir -p "$case_d_dir/.deep-review"
	ln -s "$outside_target" "$case_d_dir/.deep-review/latest-claude.json"

	set +e
	(
		cd "$case_d_dir" && persist_state "$case_d_dir/lenses.json" \
			"claude" "2026-07-15T00:00:04Z" "abc1234" "def5678" "sha256:deadbeef" "sha256:focus"
	) >"$case_d_dir/stdout" 2>"$case_d_dir/stderr"
	d_exit=$?
	set -e

	if [[ $d_exit -eq 0 ]]; then
		fail "(d) refuses to write through a symlinked target file (script exited 0)"
		sed 's/^/    /' "$case_d_dir/stdout"
	elif ! grep -Fq "Could not persist findings JSON:" "$case_d_dir/stderr"; then
		fail "(d) refuses to write through a symlinked target file (missing documented stderr message)"
		sed 's/^/    /' "$case_d_dir/stderr"
	elif [[ "$(cat "$outside_target")" != "outside content" ]]; then
		fail "(d) refuses to write through a symlinked target file (outside file was overwritten)"
	else
		pass "(d) refuses to write through a symlinked target file"
	fi
fi

# ---------------------------------------------------------------------------
# (e) symlinked .deep-review/ directory: refuse to write through it
# ---------------------------------------------------------------------------

if [[ "$(id -u)" -eq 0 ]]; then
	echo "SKIP: (e) refuses to write through a symlinked .deep-review/ directory (running as root)"
else
	case_e_dir="$TMPDIR_ROOT/case-e"
	make_scratch_repo "$case_e_dir"
	sample_lenses >"$case_e_dir/lenses.json"
	outside_dir="$TMPDIR_ROOT/case-e-outside-dir"
	mkdir -p "$outside_dir"
	ln -s "$outside_dir" "$case_e_dir/.deep-review"

	set +e
	(
		cd "$case_e_dir" && persist_state "$case_e_dir/lenses.json" \
			"claude" "2026-07-15T00:00:05Z" "abc1234" "def5678" "sha256:deadbeef" "sha256:focus"
	) >"$case_e_dir/stdout" 2>"$case_e_dir/stderr"
	e_exit=$?
	set -e

	if [[ $e_exit -eq 0 ]]; then
		fail "(e) refuses to write through a symlinked .deep-review/ directory (script exited 0)"
		sed 's/^/    /' "$case_e_dir/stdout"
	elif ! grep -Fq "Could not persist findings JSON:" "$case_e_dir/stderr"; then
		fail "(e) refuses to write through a symlinked .deep-review/ directory (missing documented stderr message)"
		sed 's/^/    /' "$case_e_dir/stderr"
	elif [[ -f "$outside_dir/latest-claude.json" ]]; then
		fail "(e) refuses to write through a symlinked .deep-review/ directory (outside dir was written into)"
	else
		pass "(e) refuses to write through a symlinked .deep-review/ directory"
	fi
fi

# ---------------------------------------------------------------------------
# (f) pre-existing directory at the target path: refuse rather than mv-into
# ---------------------------------------------------------------------------

case_f_dir="$TMPDIR_ROOT/case-f"
make_scratch_repo "$case_f_dir"
sample_lenses >"$case_f_dir/lenses.json"
mkdir -p "$case_f_dir/.deep-review/latest-claude.json"

set +e
(
	cd "$case_f_dir" && persist_state "$case_f_dir/lenses.json" \
		"claude" "2026-07-15T00:00:06Z" "abc1234" "def5678" "sha256:deadbeef" "sha256:focus"
) >"$case_f_dir/stdout" 2>"$case_f_dir/stderr"
f_exit=$?
set -e

if [[ $f_exit -eq 0 ]]; then
	fail "(f) refuses to write when the target path is a pre-existing directory (script exited 0)"
	sed 's/^/    /' "$case_f_dir/stdout"
elif ! grep -Fq "Could not persist findings JSON:" "$case_f_dir/stderr"; then
	fail "(f) refuses to write when the target path is a pre-existing directory (missing documented stderr message)"
	sed 's/^/    /' "$case_f_dir/stderr"
elif [[ ! -d "$case_f_dir/.deep-review/latest-claude.json" ]]; then
	fail "(f) refuses to write when the target path is a pre-existing directory (target directory no longer present)"
elif [[ -n "$(find "$case_f_dir/.deep-review/latest-claude.json" -mindepth 1 2>/dev/null)" ]]; then
	fail "(f) refuses to write when the target path is a pre-existing directory (a stray temp file was moved inside it)"
	ls -la "$case_f_dir/.deep-review/latest-claude.json" | sed 's/^/    /'
else
	pass "(f) refuses to write when the target path is a pre-existing directory, and leaves it untouched"
fi

# ---------------------------------------------------------------------------
# (g) multi-document input ("{} {}"): refuse rather than silently persisting
#     a concatenated multi-document blob
# ---------------------------------------------------------------------------

case_g_dir="$TMPDIR_ROOT/case-g"
make_scratch_repo "$case_g_dir"
printf '{} {}' >"$case_g_dir/lenses.json"

set +e
(
	cd "$case_g_dir" && persist_state "$case_g_dir/lenses.json" \
		"claude" "2026-07-15T00:00:07Z" "abc1234" "def5678" "sha256:deadbeef" "sha256:focus"
) >"$case_g_dir/stdout" 2>"$case_g_dir/stderr"
g_exit=$?
set -e

if [[ $g_exit -ne 2 ]]; then
	fail "(g) refuses multi-document input (expected exit 2, got $g_exit)"
	sed 's/^/    /' "$case_g_dir/stderr"
elif ! grep -Fq "persist-deep-review-state:" "$case_g_dir/stderr"; then
	fail "(g) refuses multi-document input (missing usage-error message)"
	sed 's/^/    /' "$case_g_dir/stderr"
elif [[ -e "$case_g_dir/.deep-review" ]]; then
	fail "(g) refuses multi-document input (a file was written despite rejection)"
	ls -la "$case_g_dir/.deep-review" | sed 's/^/    /'
else
	pass "(g) refuses multi-document input, writes nothing"
fi

# ---------------------------------------------------------------------------
# (h) a real SIGTERM delivered mid-`mv` leaves no stray temp file
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
	echo "SKIP: (h) SIGTERM mid-mv leaves no stray temp file (running as root)"
else
	case_h_dir="$TMPDIR_ROOT/case-h"
	make_scratch_repo "$case_h_dir"
	sample_lenses >"$case_h_dir/lenses.json"

	slow_bin="$case_h_dir/slow-bin"
	mkdir -p "$slow_bin"
	cat >"$slow_bin/mv" <<'EOF'
#!/bin/sh
sleep 2
exec /bin/mv "$@"
EOF
	chmod +x "$slow_bin/mv"

	set +e
	(
		cd "$case_h_dir" || exit 1
		PATH="$slow_bin:$PATH" bash "$SCRIPT" --harness claude --run-id t \
			--base-commit aaa --head-commit bbb --diff-hash ccc --review-focus-hash "" \
			"$case_h_dir/lenses.json" >"$case_h_dir/stdout" 2>"$case_h_dir/stderr" &
		h_pid=$!
		sleep 0.5
		kill -TERM "$h_pid" 2>/dev/null
		wait "$h_pid"
	)
	h_exit=$?
	set -e

	stray="$(stray_temp_files "$case_h_dir")"
	if [[ $h_exit -lt 128 ]]; then
		fail "(h) SIGTERM mid-mv leaves no stray temp file (process did not appear to be signaled, exit=$h_exit -- mv shim may be too fast; not a real test of the trap)"
	elif [[ -n "$stray" ]]; then
		fail "(h) SIGTERM mid-mv leaves no stray temp file (found: $stray)"
	else
		pass "(h) SIGTERM mid-mv leaves no stray temp file"
	fi
fi

# ---------------------------------------------------------------------------
# (i)/(j) Phase 2 extension: --from-collector
#
# Plan: docs/dev_plans/20260823-feature-review-skills-resilience.md, Phase 2
# ("`persist-deep-review-state.sh`: new `--from-collector` flag... persist
# maps the collector shape to `.lenses`... existing positional `lenses.json`
# input retained test-only"). New flag; ASSUMPTION (not yet implemented at
# the time this suite was written, per the Phase 2 test-writer's scope):
# `--from-collector` reads `scripts/collect-lens-results.sh`'s per-lens
# object straight off stdin (no positional path allowed alongside it) and
# writes it into the `lenses` key of the persisted envelope exactly as
# received (the same wrap-and-stamp shape as positional input, i.e. schema
# metadata added, `lenses` key populated verbatim from the collector JSON).
# If the real flag's semantics differ, this case's assertions are the
# concrete thing to revisit — the case is intentionally isolated so a
# semantic mismatch fails only (i)/(j), not (a)-(h).
# ---------------------------------------------------------------------------

# Synthetic collect-lens-results.sh-shaped payload: object keyed by lens,
# each value {status, reviewed, assigned, unreviewed[], findings[]} per the
# plan's R4 collector contract.
sample_collector_output() {
	cat <<'JSON'
{
  "logic": {
    "status": "completed",
    "reviewed": 3,
    "assigned": 3,
    "unreviewed": [],
    "findings": []
  },
  "security": {
    "status": "partial",
    "reviewed": 2,
    "assigned": 5,
    "unreviewed": ["u3", "u4", "u5"],
    "findings": []
  }
}
JSON
}

case_i_dir="$TMPDIR_ROOT/case-i"
make_scratch_repo "$case_i_dir"

if (
	cd "$case_i_dir" && sample_collector_output | bash "$SCRIPT" --harness claude --run-id "cont-1" \
		--base-commit aaa --head-commit bbb --diff-hash ccc --review-focus-hash "" --from-collector
) >"$case_i_dir/stdout" 2>"$case_i_dir/stderr"; then
	target="$case_i_dir/.deep-review/latest-claude.json"
	if [[ ! -f "$target" ]]; then
		fail "(i) --from-collector writes a state file with the collector shape under .lenses (no file at $target)"
	elif jq -e '.lenses.logic.status == "completed" and .lenses.security.status == "partial" and (.lenses.security.unreviewed | length) == 3' "$target" >/dev/null 2>&1; then
		pass "(i) --from-collector maps collect-lens-results.sh's per-lens shape into .lenses verbatim"
	else
		fail "(i) --from-collector maps collect-lens-results.sh's per-lens shape into .lenses verbatim (unexpected shape)"
		sed 's/^/    /' "$target"
	fi
else
	fail "(i) --from-collector maps collect-lens-results.sh's per-lens shape into .lenses verbatim (script exited non-zero -- --from-collector may not be implemented yet)"
	sed 's/^/    /' "$case_i_dir/stderr"
fi

# (j) regression: the pre-existing positional lenses.json path (no
# --from-collector) must still work unchanged -- it is retained test-only
# per the plan, but must not have been removed or broken by adding the flag.
case_j_dir="$TMPDIR_ROOT/case-j"
make_scratch_repo "$case_j_dir"
sample_lenses >"$case_j_dir/lenses.json"

if (
	cd "$case_j_dir" && persist_state "$case_j_dir/lenses.json" \
		"claude" "2026-07-15T00:00:08Z" "abc1234" "def5678" "sha256:deadbeef" ""
) >"$case_j_dir/stdout" 2>"$case_j_dir/stderr"; then
	target="$case_j_dir/.deep-review/latest-claude.json"
	if [[ -f "$target" ]] && jq -e '.lenses.logic.status == "completed"' "$target" >/dev/null 2>&1; then
		pass "(j) positional lenses.json input still works after --from-collector is added (regression)"
	else
		fail "(j) positional lenses.json input still works after --from-collector is added (regression) (unexpected shape at $target)"
	fi
else
	fail "(j) positional lenses.json input still works after --from-collector is added (regression) (script exited non-zero)"
	sed 's/^/    /' "$case_j_dir/stderr"
fi

# ---------------------------------------------------------------------------
# (R8-G4a) a duplicated LENS KEY in the input must be refused, not persisted.
#
# The duplicate-key rule was extracted into persist-common.sh in round 7 and
# registered for all four callers, but only the two LENS callers were wired.
# The two STATE-FILE callers are the worse case: this input is an externally
# supplied per-lens KEYED document whose .lenses.<lens>.status entries drive
# --continue resumption, so a hand-built lenses.json spelling one lens twice
# silently lost the earlier lens's status. At a970c3a this persisted happily.
# ---------------------------------------------------------------------------

case_r8g4a_dir="$TMPDIR_ROOT/case-r8g4a"
make_scratch_repo "$case_r8g4a_dir"
cat >"$case_r8g4a_dir/lenses.json" <<'JSON'
{
  "logic": {"status": "completed", "model": "opus", "effort": "high", "findings": []},
  "logic": {}
}
JSON

if (
	cd "$case_r8g4a_dir" && persist_state "$case_r8g4a_dir/lenses.json" \
		"claude" "2026-07-15T00:00:09Z" "abc1234" "def5678" "sha256:deadbeef" ""
) >"$case_r8g4a_dir/stdout" 2>"$case_r8g4a_dir/stderr"; then
	fail "(R8-G4a) a duplicated lens key must exit 2 (script exited 0 and persisted)"
else
	r8g4a_err="$(cat "$case_r8g4a_dir/stderr")"
	if [[ "$r8g4a_err" == *"duplicate key"* && "$r8g4a_err" == *"logic"* ]] &&
		[[ ! -f "$case_r8g4a_dir/.deep-review/latest-claude.json" ]]; then
		pass "(R8-G4a) a duplicated lens key exits 2, names the lens, and persists nothing"
	else
		fail "(R8-G4a) err='$r8g4a_err' target-exists=$([[ -f "$case_r8g4a_dir/.deep-review/latest-claude.json" ]] && echo yes || echo no)"
	fi
fi

# ---------------------------------------------------------------------------
# (R8-G4c) STRUCTURAL: the duplicate-key rule is a WIRE rule, so the caller set
# is DERIVED, never listed. Two mechanical assertions:
#   1. every script that sources persist-common.sh calls
#      persist_assert_no_duplicate_keys (the header's "all four" claim, checked
#      rather than asserted). Since R11/F3 the two LENS callers reach
#      persist-common.sh INDIRECTLY, through lib/lens-common.sh, so the
#      sourcing probe accepts either spelling -- the rule is about which
#      scripts have the helper in scope, and that set is unchanged at four.
#      Matching only the direct spelling would have quietly dropped the two
#      lens scripts out of the derived set and passed with a count of 2;
#   2. every script that calls persist_validate_json_shape also calls the
#      duplicate-key helper, so the shape/duplicate pairing cannot be half-added
#      by a fifth caller.
# ---------------------------------------------------------------------------

r8g4c_sourcers=""
r8g4c_missing_dup=""
r8g4c_missing_pair=""
for r8g4c_f in "$REPO_ROOT"/scripts/*.sh; do
	# The SOURCING form only — a mention in a comment or a bundle map is not
	# a caller.
	grep -qE '^[[:space:]]*(\.|source)[[:space:]].*(persist|lens)-common\.sh' "$r8g4c_f" || continue
	r8g4c_base="$(basename "$r8g4c_f")"
	r8g4c_sourcers="$r8g4c_sourcers $r8g4c_base"
	grep -q 'persist_assert_no_duplicate_keys "' "$r8g4c_f" ||
		r8g4c_missing_dup="$r8g4c_missing_dup $r8g4c_base"
	if grep -q 'persist_validate_json_shape "' "$r8g4c_f" &&
		! grep -q 'persist_assert_no_duplicate_keys "' "$r8g4c_f"; then
		r8g4c_missing_pair="$r8g4c_missing_pair $r8g4c_base"
	fi
done
r8g4c_count="$(printf '%s' "$r8g4c_sourcers" | wc -w | tr -d ' ')"
if [[ "$r8g4c_count" -eq 4 && -z "$r8g4c_missing_dup" && -z "$r8g4c_missing_pair" ]]; then
	pass "(R8-G4c) all four persist-common.sh callers (two direct, two via lens-common.sh) enforce the duplicate-key rule, and every shape gate is paired with it:$r8g4c_sourcers"
else
	fail "(R8-G4c) callers=$r8g4c_count ($r8g4c_sourcers) missing-duplicate-rule:${r8g4c_missing_dup:- none} unpaired-shape-gate:${r8g4c_missing_pair:- none}"
fi

echo ""
echo "Summary: $pass_count passed, $fail_count failed"

if [[ $fail_count -ne 0 ]]; then
	exit 1
fi
exit 0
