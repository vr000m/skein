#!/usr/bin/env bash
# persist-common.sh — shared helpers for the persistence scripts.
#
# FOUR callers, in TWO groups that reach this file differently (R11/F3).
# Keep this list exact: it is the only place that records which helpers exist
# for whom, and `grep -rn 'persist-common.sh' scripts/ plugins/` must return
# exactly these sourcing sites (plus the bundled copies, and
# scripts/lib/lens-common.sh, which sources this file on the lens group's
# behalf).
#
#   STATE-FILE callers — write one latest-state JSON document per harness.
#   These source this file DIRECTLY:
#     scripts/persist-review-state.sh
#     scripts/persist-deep-review-state.sh
#   LENS callers — Phase 2's disk-first streamed lens results, one
#   append-only JSONL attempt file per (run-id, lens, attempt). These source
#   scripts/lib/lens-common.sh, which sources this file, and must NOT source
#   both:
#     scripts/persist-lens-result.sh      (writer)
#     scripts/collect-lens-results.sh     (reader/merge)
#
# The lens-only helpers that used to live here — persist_lens_state_dir,
# persist_lens_run_dir, persist_path_is_inside_root,
# persist_path_physical_match, persist_validate_id, persist_validate_unit,
# persist_units_csv_to_json, persist_jsonl_append and PERSIST_UNIT_JQ_GATE —
# moved to scripts/lib/lens-common.sh unchanged. The state scripts called
# none of them. Do not move any of them back: what remains here is exactly
# what at least one caller in EACH group uses.
#
# Which helpers belong to whom:
#   - persist_root_dir                   — THREE callers, not four (round 9,
#                                          F8/F9). persist-lens-result.sh
#                                          takes `--root` from the
#                                          orchestrator as a REQUIRED flag and
#                                          derives no root of its own, so it
#                                          must not fall back to a cwd the
#                                          orchestrator did not choose.
#   - persist_require_value,
#     persist_validate_json_shape,
#     persist_assert_no_duplicate_keys   — all four. On the STATE-FILE
#                                          callers it runs directly AFTER the
#                                          shape gate, over the same captured
#                                          `$input`, so a non-object payload
#                                          fails with the clearer shape
#                                          message and neither helper ever
#                                          re-reads the file (round 8, F7).
#   - persist_atomic_write               — STATE-FILE callers only. The lens
#                                          contract is append-only (see
#                                          lens-common.sh's
#                                          persist_jsonl_append), so an
#                                          atomic replace-in-place would be
#                                          the wrong primitive there.
#                                          (persist_fail is internal to this
#                                          file, used only by
#                                          persist_atomic_write.)
#
# Source this file from a caller; it does not run on its own. All four
# callers already `source scripts/lib/auto-fix-common.sh` for
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
#   persist_assert_no_duplicate_keys <json-text> <label> <what>
#                              — 0 when no object key repeats anywhere in
#                                <json-text>, 1 with a diagnostic otherwise.
#                                Detects a repeat for ANY pair of value
#                                shapes by comparing jq --stream EVENT COUNTS
#                                raw vs collapsed (round 8, F4/F5/F6), not by
#                                comparing event paths. Takes TEXT, never a
#                                path: the verdict has to come from the same
#                                bytes the caller goes on to use (round 7,
#                                F7/F8).
#   persist_validate_json_shape <input> <label> <noun> [<object-suffix>]
#                              — validate <input> is syntactically valid
#                                JSON, exactly one top-level document, and a
#                                JSON object. On failure prints
#                                "<label>: <noun> ..." to stderr and returns
#                                2 (the shared usage-error exit code); the
#                                caller does `... || exit 2`. Schema-specific
#                                checks beyond this generic shape (e.g.
#                                persist-review-state.sh's schema_version /
#                                required-keys checks) are the caller's own
#                                responsibility.
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

# jq without --slurp processes a stream of top-level JSON values, applying
# the filter to each one independently — so "{} {}" (two concatenated JSON
# documents) would pass a bare `jq -e .` validity check (its exit status
# reflects only the last value) and then silently flow through as a
# concatenated multi-object blob. Reject anything but exactly one top-level
# document up front, then confirm it's an object.
#
# `jq empty` rather than `jq -e .` (round 10, F10): `-e` reports the
# TRUTHINESS OF THE RESULT, not parse success, so it exits 1 on the valid
# documents `false` and `null` — sending an operator to hunt a syntax error in
# syntactically perfect input. `jq empty` is non-zero iff parsing failed,
# which is the only question this gate asks; the type gate below is what
# rejects a non-object, and with the right message. The multi-document
# reasoning above is unchanged: `jq empty` likewise applies to each top-level
# value independently, which is why the `jq -s 'length'` count gate still
# stands between it and the type gate.
persist_validate_json_shape() {
	local input="$1" label="$2" noun="$3" object_suffix="${4:-}"

	if ! printf '%s' "$input" | jq empty >/dev/null 2>&1; then
		echo "$label: $noun is not valid JSON" >&2
		return 2
	fi

	local doc_count
	doc_count="$(printf '%s' "$input" | jq -s 'length')"
	if [[ "$doc_count" != "1" ]]; then
		echo "$label: $noun must be exactly one JSON document (got $doc_count)" >&2
		return 2
	fi

	if ! printf '%s' "$input" | jq -e 'type == "object"' >/dev/null 2>&1; then
		echo "$label: $noun must be a JSON object${object_suffix}" >&2
		return 2
	fi

	return 0
}

# persist_assert_no_duplicate_keys <json-text> <label> <what>
#
# Refuse a duplicate object key ANYWHERE in <json-text>. jq collapses a
# repeated key to the LAST occurrence before any filter runs, so
# `keys_unsorted` can never see one.
#
# The rule is a COUNT, not a path comparison (round 8, F4/F5/F6).
# `jq --stream` over the RAW text emits every assignment, including the ones
# parsing is about to drop; `jq -c .` first collapses the document, so
# streaming THAT emits only the survivors. A dropped assignment contributes at
# least one event and removes none, so raw > collapsed IFF a key was collapsed
# -- for every pair of value shapes, at every depth. Round 7 compared value-
# event PATHS instead and so only caught duplicates whose two values happened
# to emit a common leaf path: `{"logic":["a","b"],"logic":[]}` emits
# ["logic",0],["logic",1] and ["logic"], shares nothing, and passed.
#
# Takes the payload as TEXT, never a path: the verdict must be computed
# from the same bytes the caller already captured, or it is a TOCTOU
# against a second read (round 7, F7/F8). Being depth-general, it is also
# not order-coupled to any shape gate -- but the STATE-FILE callers still run
# it immediately AFTER persist_validate_json_shape, so a non-object payload
# fails with the clearer shape message first (round 8, F7).
persist_assert_no_duplicate_keys() {
	local json="$1" label="$2" what="$3" raw canon raw_n canon_n hint
	if ! raw="$(printf '%s' "$json" | jq --stream -c '.[0]' 2>/dev/null)"; then
		echo "$label: could not scan $what for duplicate keys" >&2
		return 1
	fi
	if ! canon="$(printf '%s' "$json" | jq -c . 2>/dev/null |
		jq --stream -c '.[0]' 2>/dev/null)"; then
		echo "$label: could not scan $what for duplicate keys" >&2
		return 1
	fi
	raw_n=0
	if [[ -n "$raw" ]]; then
		raw_n="$(printf '%s\n' "$raw" | wc -l | tr -d ' ')"
	fi
	canon_n=0
	if [[ -n "$canon" ]]; then
		canon_n="$(printf '%s\n' "$canon" | wc -l | tr -d ' ')"
	fi
	if [[ "$raw_n" -le "$canon_n" ]]; then
		return 0
	fi
	# Name the offending key: the event paths present in the RAW stream but
	# not in the collapsed one are exactly the dropped assignment's.
	hint="$(comm -13 <(printf '%s\n' "$canon" | sort) <(printf '%s\n' "$raw" | sort) |
		sort -u | tr '\n' ' ')"
	echo "$label: $what has a duplicate key (a repeated key silently drops the earlier assignment): ${hint:-(key path unavailable)}" >&2
	return 1
}

# Shared "Could not persist findings JSON: <reason>" stderr message used by
# every guard/write step in persist_atomic_write below. Only prints the
# message — callers still do their own `return 1`, since a helper can't
# return from its caller's function.
persist_fail() {
	local err="$1" fallback="$2"
	echo "Could not persist findings JSON: ${err:-$fallback}" >&2
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
	#
	# UNBOUNDED ON PURPOSE (round 7, F4). These two calls pass NO <root>, so
	# the walk runs all the way up; the lens call sites
	# (persist-lens-result.sh, collect-lens-results.sh) pass `--root` and are
	# bounded. The asymmetry is one-directional and deliberate: unbounded is
	# strictly stricter — it can only refuse more. These paths are composed
	# by this file from the state root, so there is no caller-supplied
	# fixture path that a longer walk could falsely refuse; the lens call
	# sites DO accept caller-supplied paths (out-of-tree fixtures, payloads
	# under $TMPDIR), which is why they need the bound. Do not "harmonise"
	# these two by adding a root here — that would weaken them.
	if ! af_assert_no_symlink "$out_dir"; then
		persist_fail "" "refusing to write through a symlink at $out_dir"
		return 1
	fi
	if ! af_assert_no_symlink "$out_path"; then
		persist_fail "" "refusing to write through a symlink at $out_path"
		return 1
	fi

	# By this point $out_path is confirmed not to be a symlink. If it
	# still exists but is not a regular file (e.g. a directory), `mv -f`
	# below would silently succeed by moving the temp file *inside* it
	# instead of replacing it — a false success that leaves the
	# advertised path unusable. Reject that case up front.
	if [[ -e "$out_path" && ! -f "$out_path" ]]; then
		persist_fail "" "refusing to overwrite non-regular-file target at $out_path"
		return 1
	fi

	local mkdir_err
	if ! mkdir_err=$({ mkdir -p "$out_dir"; } 2>&1); then
		persist_fail "$mkdir_err" "could not create $out_dir"
		return 1
	fi

	# Atomic write: stage <content> in a temp file created in the same
	# directory as <out_path> (same filesystem, so the final `mv` is an
	# atomic rename), then rename it into place only after the write
	# succeeds. "Last writer wins" for two concurrent runs targeting the
	# same harness's latest file is an accepted, unchanged characteristic
	# — this does not add locking or per-run immutable snapshots.
	if ! PERSIST_TMP_PATH=$(mktemp "$tmp_template" 2>&1); then
		local tmp_err="$PERSIST_TMP_PATH"
		PERSIST_TMP_PATH=""
		persist_fail "$tmp_err" "could not create temp file in $out_dir"
		return 1
	fi
	# Signal-safe cleanup: register an EXIT trap now that the temp file
	# exists, so a SIGINT/SIGTERM/unexpected termination between here and
	# the final `mv` doesn't leak it — matching both pre-extraction
	# scripts' `trap cleanup_tmp EXIT`. PERSIST_TMP_PATH is deliberately
	# global, not local: a trap fires in the shell's top-level context,
	# not this function's, so a `local` would already be out of scope by
	# the time a signal-triggered trap runs. The trap is intentionally
	# never deregistered — both real callers `exit`/finish shortly after
	# this function returns, and once `mv` below succeeds (or the temp
	# file was never created) the trap's own `-e` check makes it a no-op
	# regardless of how or when the script eventually exits.
	trap 'rm -f "$PERSIST_TMP_PATH" 2>/dev/null || true' EXIT

	local write_err
	if ! write_err=$({ printf '%s\n' "$content" >"$PERSIST_TMP_PATH"; } 2>&1); then
		persist_fail "$write_err" "could not write $PERSIST_TMP_PATH"
		return 1
	fi

	local mv_err
	if ! mv_err=$({ mv -f "$PERSIST_TMP_PATH" "$out_path"; } 2>&1); then
		persist_fail "$mv_err" "could not rename $PERSIST_TMP_PATH to $out_path"
		return 1
	fi

	return 0
}
