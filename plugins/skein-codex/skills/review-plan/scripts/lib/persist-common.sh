#!/usr/bin/env bash
# persist-common.sh — shared helpers for the state-file persistence scripts
# (`scripts/persist-review-state.sh`, `scripts/persist-deep-review-state.sh`).
#
# Source this file from a persist script; it does not run on its own.
# Both callers already `source scripts/lib/auto-fix-common.sh` for
# af_assert_no_symlink; this file assumes that's already sourced too.
#
# Helpers provided:
#   persist_root_dir
#                              — print the git worktree root, falling back to
#                                the current working directory when not
#                                inside a git worktree.
#   persist_require_value "$@"
#                              — call immediately after `shift` consumes a
#                                flag token, before reading $1 as its value;
#                                exits 2 via the caller's own `usage`
#                                function (which must already be defined) if
#                                no value token remains.
#   persist_atomic_write <out_dir> <out_path> <tmp_template> <content>
#                              — guard against a pre-existing symlink or
#                                non-regular-file target, then write <content>
#                                to <out_path> atomically (temp file + `mv -f`).
#                                Returns 1 with a "Could not persist findings
#                                JSON: <reason>" stderr message on any
#                                failure; the caller is responsible for
#                                `exit 1` on a non-zero return.

# Root-anchor. Falls back to cwd when not inside a git worktree, matching
# scripts/apply-auto-fix-plan.sh's pre-existing WORKTREE_ROOT precedent.
persist_root_dir() {
	local worktree_root
	if worktree_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
		printf '%s\n' "$worktree_root"
	else
		pwd
	fi
}

# Pass the caller's remaining positional args as "$@" (i.e. call as
# `persist_require_value "$@"` right after `shift`) so $# here reflects how
# many value tokens are left.
persist_require_value() {
	if [[ $# -lt 1 ]]; then
		usage
		exit 2
	fi
}

# <tmp_template> is an mktemp template supplied by the caller, not derived
# here — it must live inside <out_dir> so the final `mv` is a same-filesystem
# atomic rename, but each of the two current callers uses a different naming
# convention (review-plan: "$OUT_PATH.tmp.XXXXXX"; deep-review:
# "$OUT_DIR/.latest-$HARNESS.json.XXXXXX") that its own tests' leftover-temp-
# file checks already assert on. Taking the template as a parameter keeps
# both callers' existing on-disk naming, and test coverage, unchanged.
persist_atomic_write() {
	local out_dir="$1" out_path="$2" tmp_template="$3" content="$4"

	# Symlink guards (defense-in-depth): refuse to write through a
	# pre-existing symlink at either the target file or its parent
	# directory. Both callers' target directories are gitignored, but a
	# *tracked* symlink at that exact path would still materialize on
	# checkout — without this guard a malicious clone could point it
	# outside the repo and have the write clobber an arbitrary
	# user-writable file. Delegates to auto-fix-common.sh's
	# af_assert_no_symlink, which walks the full parent-directory chain
	# (not just the immediate target).
	if ! af_assert_no_symlink "$out_dir"; then
		echo "Could not persist findings JSON: refusing to write through a symlink at $out_dir" >&2
		return 1
	fi
	if ! af_assert_no_symlink "$out_path"; then
		echo "Could not persist findings JSON: refusing to write through a symlink at $out_path" >&2
		return 1
	fi

	# By this point $out_path is confirmed not to be a symlink. If it
	# still exists but is not a regular file (e.g. a directory), `mv -f`
	# below would silently succeed by moving the temp file *inside* it
	# instead of replacing it — a false success that leaves the
	# advertised path unusable. Reject that case up front.
	if [[ -e "$out_path" && ! -f "$out_path" ]]; then
		echo "Could not persist findings JSON: refusing to overwrite non-regular-file target at $out_path" >&2
		return 1
	fi

	local mkdir_err
	if ! mkdir_err=$({ mkdir -p "$out_dir"; } 2>&1); then
		echo "Could not persist findings JSON: ${mkdir_err:-could not create $out_dir}" >&2
		return 1
	fi

	# Atomic write: stage <content> in a temp file created in the same
	# directory as <out_path> (same filesystem, so the final `mv` is an
	# atomic rename), then rename it into place only after the write
	# succeeds. A killed/interrupted process leaves the previous good
	# <out_path> untouched. This fixes crash/interrupt corruption only;
	# "last writer wins" for two concurrent runs targeting the same
	# harness's latest file is an accepted, unchanged characteristic —
	# this does not add locking or per-run immutable snapshots.
	local tmp_path=""
	if ! tmp_path=$(mktemp "$tmp_template" 2>&1); then
		local tmp_err="$tmp_path"
		echo "Could not persist findings JSON: ${tmp_err:-could not create temp file in $out_dir}" >&2
		return 1
	fi

	local write_err
	if ! write_err=$({ printf '%s\n' "$content" >"$tmp_path"; } 2>&1); then
		echo "Could not persist findings JSON: ${write_err:-could not write $tmp_path}" >&2
		rm -f "$tmp_path" 2>/dev/null || true
		return 1
	fi

	local mv_err
	if ! mv_err=$({ mv -f "$tmp_path" "$out_path"; } 2>&1); then
		echo "Could not persist findings JSON: ${mv_err:-could not rename $tmp_path to $out_path}" >&2
		rm -f "$tmp_path" 2>/dev/null || true
		return 1
	fi

	return 0
}
