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

echo ""
echo "Summary: $pass_count passed, $fail_count failed"

if [[ $fail_count -ne 0 ]]; then
	exit 1
fi
exit 0
