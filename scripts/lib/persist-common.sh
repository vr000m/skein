#!/usr/bin/env bash
# persist-common.sh — shared helpers for the persistence scripts.
#
# FOUR callers, not two (G8). Keep this list exact: it is the only place
# that records which helpers exist for whom, and `grep -rn
# 'persist-common.sh' scripts/ plugins/` must return exactly these sourcing
# sites (plus the bundled copies of the same four scripts).
#
#   STATE-FILE callers — write one latest-state JSON document per harness:
#     scripts/persist-review-state.sh
#     scripts/persist-deep-review-state.sh
#   LENS callers — Phase 2's disk-first streamed lens results, one
#   append-only JSONL attempt file per (run-id, lens, attempt):
#     scripts/persist-lens-result.sh      (writer)
#     scripts/collect-lens-results.sh     (reader/merge)
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
#                                          persist_jsonl_append), so an
#                                          atomic replace-in-place would be
#                                          the wrong primitive there.
#                                          (persist_fail is internal to this
#                                          file, used only by
#                                          persist_atomic_write.)
#   - persist_lens_state_dir,
#     persist_lens_run_dir,
#     persist_path_is_inside_root,
#     persist_path_physical_match,
#     PERSIST_UNIT_JQ_GATE,
#     persist_jsonl_append,
#     persist_validate_id,
#     persist_validate_unit              — LENS callers only. These exist
#                                          solely so the writer and the
#                                          reader derive the same directory
#                                          and enforce the same charset on
#                                          both sides of the wire.
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
#   persist_lens_state_dir <root> <skill>
#                              — print `<root>/.deep-review/lenses` for
#                                --skill deep-review or `<root>/.review-plan/lenses`
#                                for --skill review-plan. Used by
#                                `persist-lens-result.sh` and
#                                `collect-lens-results.sh` (Phase 2) so both
#                                scripts derive the same per-run-id attempt-file
#                                directory from an explicit --root (never cwd).
#                                Returns 1 with no output for an unknown skill.
#   persist_validate_id <value> <label> <kind>
#                              — validate <value> against a charset
#                                whitelist (kind = name|run-id). Prints
#                                "<label>: invalid ..." to stderr and
#                                returns 2 on failure. See persist_validate_id
#                                itself for the exact charsets and rationale.
#   persist_jsonl_append <path> <json_line>
#                              — append one line to <path>, creating parent
#                                directories as needed. Deliberately a plain
#                                `>>` append, not `persist_atomic_write`'s
#                                temp-file-then-rename: the lens attempt-file
#                                contract is one writer per file (no `flock`,
#                                no cross-writer atomicity assumption), so
#                                atomic replace-in-place would be the wrong
#                                primitive here — every call must add a line,
#                                never replace the file's prior contents.
#                                Returns 1 on any mkdir/write failure.
#   persist_validate_unit <value> <label>
#                              — validate ONE review unit arriving as a
#                                standalone ARGV token. This function owns the
#                                ARGV rules and nothing else, which is why it
#                                takes no wire selector. A narrow
#                                blacklist, NOT a persist_validate_id-style
#                                whitelist: units are free-form review
#                                targets (file paths for deep-review, plan
#                                sections for review-plan). The FILE/JSON
#                                wire's rules are owned solely by
#                                PERSIST_UNIT_JQ_GATE — see the function for
#                                why the two are not the same rule set.
#   persist_units_csv_to_json <csv> <label>
#                              — the ONLY splitter for an argv units CSV.
#                                Prints a compact JSON array; returns 2 with a
#                                diagnostic on any violation. Nothing else in
#                                the tree may split a units CSV.
#   PERSIST_UNIT_JQ_GATE       — the FILE/JSON wire's unit rules as a jq
#                                filter over an ARRAY of units, so the reader
#                                and the writer enforce one rule set from one
#                                source. See the definition for the rules.
#   persist_lens_run_dir <root> <skill> <run-id>
#                              — print the per-run lens directory
#                                (`persist_lens_state_dir`/<run-id>). Every
#                                per-run lens artefact — the attempt files AND
#                                the units file the orchestrator writes for
#                                `collect-lens-results.sh --expected-file` —
#                                lives here, so there is exactly one helper
#                                deriving it.
#   persist_path_is_inside_root <path> <root>
#                              — 0 when <path> is LEXICALLY under <root> (or
#                                under its absolutised or canonicalised
#                                form), 1 otherwise. Relative spellings of
#                                either argument are absolutised against
#                                $PWD first — absolutising resolves no
#                                component, so the lexical property is kept —
#                                and a `..`-bearing path is fail-closed to
#                                "inside". Gates the repo-rooted symlink
#                                guard so an out-of-tree fixture path is not
#                                refused on a platform symlink it never
#                                touches.
#   persist_path_physical_match <abs-path> <root>...
#                              — 0 when some physical-prefix spelling of
#                                <abs-path> (an EXISTING ancestor prefix
#                                replaced by its `pwd -P` form, tail kept)
#                                is or lies under one of the <root>s. The
#                                absolute half of "both spellings"
#                                (round 7, F5); used only by
#                                persist_path_is_inside_root.

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

# Phase 2 (disk-first streamed lens results): shared path/append helpers for
# scripts/persist-lens-result.sh (writer) and scripts/collect-lens-results.sh
# (reader). The two consumers are ASYMMETRIC about --root, on purpose:
#   * the WRITER hard-errors without --root (`persist-lens-result: --root is
#     required`). A lens subagent's cwd at spawn time is not guaranteed to be
#     the repo root, so the orchestrator must resolve the root once and bake
#     it into the command it hands the lens -- a cwd fallback there would
#     scatter attempt files under whatever directory the lens happened to
#     start in.
#   * the READER makes --root OPTIONAL and falls back to persist_root_dir
#     when cwd is inside a git worktree, because the collector is invoked by
#     the orchestrator itself, from the repo. Outside a worktree it refuses
#     rather than falling back to `pwd`, since reading a different
#     `.deep-review/lenses` than the one written to would report every lens
#     `missing` (see collect-lens-results.sh's G12c note).
# This helper itself never consults cwd: it takes <root> as an argument, so
# the fallback policy stays with each consumer.
#
# SKILL->STATE-DIR MAPPING (4 sites). The same skill -> state-directory mapping
# (.deep-review for deep-review, .review-plan for review-plan) is spelled out in
# FOUR places, deliberately NOT consolidated: they differ in root source
# ($AF_COMMON_ROOT vs an explicit argument) and in failure exit code (2 vs
# 1), so merging them would be a behaviour change at four call sites for no
# functional gain. A NEW SKILL must therefore be registered in all four:
#   scripts/lib/persist-common.sh      persist_lens_state_dir  (per-run lens attempt dirs)
#   scripts/lib/auto-fix-common.sh     af_manifest_dir         (auto-fix manifests)
#   scripts/persist-deep-review-state.sh  OUT_DIR
#   scripts/persist-review-state.sh       OUT_DIR
persist_lens_state_dir() {
	local root="$1" skill="$2"
	case "$skill" in
	deep-review) printf '%s/.deep-review/lenses\n' "$root" ;;
	review-plan) printf '%s/.review-plan/lenses\n' "$root" ;;
	*)
		echo "persist-common: unknown --skill '$skill' (expected deep-review or review-plan)" >&2
		return 1
		;;
	esac
}

# Every PER-RUN lens artefact lives under one directory, and this is the only
# place that derives it. Round 4 (F2) folded the orchestrator-written units
# file (`collect-lens-results.sh --expected-file`) in here too: it had been
# given a path literal invented in SKILL.md prose
# (`<repo-root>/.skein/lens-runs/<run-id>/expected.json`), a THIRD state root
# owned by no helper and absent from .gitignore, so every collect run left an
# untracked file in `git status`. Both real state roots are already
# gitignored, so moving it here needed no .gitignore change.
#
# No collision with attempt discovery: collect-lens-results.sh matches
# `<lens>.<attempt>.jsonl` basenames only, and `expected.json` is neither.
persist_lens_run_dir() {
	local root="$1" skill="$2" run_id="$3"
	local lenses_dir
	lenses_dir="$(persist_lens_state_dir "$root" "$skill")" || return 1
	printf '%s/%s\n' "$lenses_dir" "$run_id"
}

# persist_path_physical_match <abs-path> <root>...
#
# 0 when SOME physical-prefix spelling of <abs-path> is one of the <root>s or
# lies under it; 1 otherwise. A physical-prefix spelling replaces an EXISTING
# ancestor prefix of <abs-path> with that ancestor's physical form
# (`cd … && pwd -P`) and re-appends the rest of the path untouched. This is
# what resolves a directory ALIAS in the prefix (`/tmp` -> `/private/tmp`,
# `/var` -> `/private/var`) so an absolute in-root path spelled through the
# alias still matches a physical --root (round 7, F5).
#
# EVERY existing ancestor is tried, not just the deepest. The deepest one
# alone is not enough: for `<alias-cwd>/escapelink/payload.json` the deepest
# existing ancestor IS the escaping symlink, whose physical form lands
# outside the root, so the path would gate itself out of its own guard --
# exactly the failure the LEXICAL rule elsewhere in this file exists to
# avoid. One level shallower, the alias resolves and the ESCAPE stays in the
# lexical tail, so the path answers "inside" and reaches
# af_assert_no_symlink, which then refuses it.
#
# The comparison happens INSIDE the walk rather than through a returned list
# of spellings: a path component may legitimately contain a newline, so there
# is no safe line-delimited carrier for the candidates.
#
# Adding spellings only moves paths from unguarded to guarded (the header's
# fail-closed direction), which is precisely why canonicalisation is safe as
# an ADDITIONAL alternative and unsafe as a replacement.
persist_path_physical_match() {
	local p="$1"
	shift
	local d="$p" tail="" c r
	while [[ "$d" != "/" && "$d" != "." ]]; do
		if c="$(cd "$d" 2>/dev/null && pwd -P)"; then
			for r in "$@"; do
				[[ -n "$r" ]] || continue
				case "$c$tail" in
				"$r" | "$r"/*) return 0 ;;
				esac
			done
		fi
		tail="/$(basename "$d")$tail"
		d="$(dirname "$d")"
	done
	return 1
}

# persist_path_is_inside_root <path> <root>
#
# LEXICAL on purpose. Canonicalising <path> first would resolve a symlinked
# ancestor and report a path that escapes the root as "outside", skipping the
# very guard that exists to catch it — the escape would gate itself out. The
# root IS canonicalised, so both spellings of an in-root path match.
#
# ABSOLUTISING IS NOT CANONICALISING, and only the second is forbidden here.
# Prefixing a relative path with the cwd resolves no component, so the lexical
# property above is untouched; refusing to do it, however, meant no relative
# spelling could EVER match an absolute root, so the function answered
# "outside" and BOTH r4 symlink guards — collect-lens-results.sh's
# --expected-file and persist-lens-result.sh's --json-file — were skipped for
# every relative path, and for every run with a relative --root (round 5/R3).
# Whether a path is guarded must depend on what the path IS, not on how it is
# spelled.
#
# BOTH CWD SPELLINGS, and that is round 6/F4. `$PWD` is the LOGICAL cwd: a
# process started from a symlinked directory alias keeps the alias in `$PWD`,
# while `--root` is typically `git rev-parse --show-toplevel` or another
# PHYSICAL path. Anchoring only against `$PWD` then made the lexical prefix
# match fail, the function answered "outside", and both callers skipped
# af_assert_no_symlink ENTIRELY — fail-OPEN, on exactly the in-tree path the
# guard exists to protect. So a relative <path> (and a relative <root>) is
# anchored against `$PWD` AND `pwd -P`, and "inside" wins if either matches.
# Adding alternatives can only move paths from unguarded to guarded, so the
# change direction is fail-closed; the worst case stays a loud refusal on an
# exotic out-of-tree fixture, which can always be respelled.
#
# THE SAME RULE COVERS ABSOLUTE SPELLINGS (round 7, F5). Round 6 fixed the
# RELATIVE branch only, so an in-root file named by an ABSOLUTE path that
# runs through a symlinked directory alias (`$PWD/.gauntlet/x` where the cwd
# was reached through `/tmp` -> `/private/tmp`, or `$TMPDIR` under `/var` ->
# `/private/var`) still prefix-matched nothing against a physical `--root`,
# answered "outside", and skipped both file-transport guards entirely. An
# absolute <path> is now also matched through persist_path_physical_match:
# every EXISTING ancestor prefix canonicalised in turn, with the rest of the
# path kept lexical. Same fail-closed direction — an added alternative can
# only move paths from unguarded to guarded.
#
# DELIBERATE ASYMMETRY WITH gauntlet_assert_no_symlink (review-gauntlet's
# lib/state-path-guard.sh): it is not a lexical prefix match but a
# CANONICALISING two-pass walk whose containment bound is derived from the
# PATH's own ancestors (`git -C` on each, round 7) rather than from the cwd
# at all — and its failure direction is fail-CLOSED. Prefix-matching
# containment needs every spelling it can get; a canonicalising walk that
# never consults the cwd needs none.
#
# `..` IS FAIL-CLOSED TO "INSIDE". A path with a `..` component can re-enter
# the tree at a position no component of its own spelling names, so
# containment cannot be decided lexically at all; this returns 0 — guarded —
# for any such path. The worst case is a loud refusal on an exotic
# out-of-tree fixture path (which can always be respelled without `..`),
# never a silent bypass. Note the deliberate asymmetry with
# ledger_assert_no_symlink, which REJECTS `..` outright: the ledger composes
# its own path from a repo root and can afford to, whereas
# --expected-file/--json-file accept caller-supplied fixture paths, so the
# strongest safe answer here is "guard it".
#
# Used to scope the repo-rooted symlink guard: a state path under <root> is
# guarded, an out-of-tree path (a test fixture, a payload in $TMPDIR) is not.
# Without the scope the guard would refuse ordinary platform symlinks — macOS
# puts $TMPDIR under `/var`, which IS a symlink to `/private/var`.
persist_path_is_inside_root() {
	local path="$1" root="$2" root_canon root_abs
	local pwd_logical pwd_physical path_abs path_physical p r
	[[ -n "$root" ]] || return 1

	# BOTH cwd spellings. $PWD is the LOGICAL cwd: started from a symlinked
	# directory alias, it keeps the alias, while `pwd -P` gives the physical
	# path. A relative <path> is therefore absolutised twice, and "inside" is
	# answered if EITHER spelling matches. See the header for why adding
	# alternatives is the fail-closed direction here.
	pwd_logical="$PWD"
	pwd_physical="$(pwd -P 2>/dev/null)" || pwd_physical="$pwd_logical"

	# Absolutise both sides, resolving nothing. `.` and `./x` are normalised
	# so a `--root .` run does not build `$PWD/.` and then fail to
	# prefix-match its own children.
	if [[ "$path" == /* ]]; then
		path_abs="$path"
		path_physical="$path"
	elif [[ "$path" == "." ]]; then
		path_abs="$pwd_logical"
		path_physical="$pwd_physical"
	else
		path_abs="$pwd_logical/${path#./}"
		path_physical="$pwd_physical/${path#./}"
	fi
	if [[ "$root" == /* ]]; then
		root_abs="$root"
	elif [[ "$root" == "." ]]; then
		root_abs="$pwd_logical"
	else
		root_abs="$pwd_logical/${root#./}"
	fi

	case "$path_abs" in
	*/../* | */..) return 0 ;;
	esac

	root_canon="$(cd "$root" 2>/dev/null && pwd -P)" || root_canon="$root"
	for p in "$path_abs" "$path_physical"; do
		for r in "$root" "$root_abs" "$root_canon"; do
			case "$p" in
			"$r" | "$r"/*) return 0 ;;
			esac
		done
	done

	# Round 7, F5. The lexical spellings above cover a RELATIVE path (the
	# round-6 fix absolutised it against both cwd spellings). An ABSOLUTE
	# path already carries its own prefix, and if that prefix runs through a
	# directory alias -- `$PWD/.gauntlet/x` where the cwd was reached via
	# `/tmp` -> `/private/tmp`, or a fixture under `$TMPDIR` below
	# `/var` -> `/private/var` -- it prefix-matches nothing against a
	# physical --root, the function answers "outside", and BOTH file-transport
	# guards are skipped. Same fail-open, same guard, different spelling. So
	# try the physical-prefix spellings too; see the helper's header for why
	# every existing ancestor is tried and why this can only move paths from
	# unguarded to guarded.
	for p in "$path_abs" "$path_physical"; do
		if persist_path_physical_match "$p" "$root" "$root_abs" "$root_canon"; then
			return 0
		fi
	done
	return 1
}

# PERSIST_UNIT_JQ_GATE — the FILE/JSON wire's unit rules, as a jq filter whose
# input and output are the units ARRAY. Errors (with a message) on a
# violation, so callers use `jq ... || <diagnostic>; exit 2`.
#
# The rules are deliberately thin, and that is the round-4 correction. A unit
# is a STRING, not a CSV field: on this wire it is carried as a JSON string
# from the orchestrator's file-write tool, through jq, into a JSON document,
# and back out through jq. It never passes through a shell and it is never
# joined with a delimiter, so a comma, a newline or a leading `-` are all just
# bytes in a name. A NUL is NOT (round 5) -- see below: that rule is about the
# REPORTING path, not about splitting.
#
# What round 3 enforced here, and why each rule left:
#   * no comma — the collector used to hold assigned units as a COMMA-JOINED
#     STRING and re-split it. It no longer joins them at all, and the rule was
#     hard-failing a real review-plan heading:
#     `## Post-completion follow-ups (A3/A5, 2026-05-24)` (F10). The comma
#     rule now lives only where a comma really is a separator: the `--expected`
#     and `--units` CSV spellings on argv.
#   * no leading `-` — a flag-injection rule for a value that reaches a
#     COMMAND LINE. On this wire it never does; a git path or a plan heading
#     may legitimately start with `-`. Retained for source=argv only.
#   * no newline — an artefact of the old bash round-trip: a line-oriented
#     `jq -R` turned an embedded newline into two JSON documents and aborted
#     the whole collection (F11). Nothing is line-split on this wire any
#     more, and the reporting path is newline-safe by construction (it is
#     NUL-delimited, which is precisely why it chose that delimiter).
#
# What survives are the two rules that are properties of a UNIT rather than of
# a transport, and they share one rationale — an assigned unit that cannot be
# reported strands its lens short of `completed` forever:
#   * non-empty — an empty unit can never be reported as reviewed.
#   * no NUL — persist-lens-result.sh's payload extractor is a NUL-delimited
#     jq -> `read -d ''` stream and a bash variable cannot hold a NUL at all,
#     so the byte is structurally unrepresentable on the REPORTING path. It
#     is assignable but not reportable. Round 4 dropped this rule alongside
#     the newline one on the rationale that "nothing splits on either byte any
#     more" (F9); that rationale is sound for assignment and false for
#     reporting. Round 5 (R4/R5) restored it HERE, on the assignment side, so
#     the failure is a loud exit 2 at assignment time rather than a silent,
#     permanent `partial`.
# shellcheck disable=SC2034  # sourced by the two lens callers, not used here.
PERSIST_UNIT_JQ_GATE='
	if type != "array" then error("units must be an array") else . end
	| if any(.[]; type != "string")
	  then error("units must be an array of strings") else . end
	| if any(.[]; length == 0)
	  then error("a unit must not be an empty string") else . end
	| if any(.[]; contains("\u0000"))
	  then error("a unit must not contain a NUL byte") else . end
'

# persist_validate_id <value> <label> <kind>
#   kind = name   : lens names, attempt-file basename component and an
#                   `--expected <lens>:<units>` key -> ':' MUST be excluded
#                   (it is the --expected/--attempts field separator).
#   kind = run-id : path segment only -> ':' allowed so an ISO-8601 run-id
#                   ("2026-03-17T14:30:00Z", as both deep-review mirrors'
#                   Suggested schema shows) keeps working.
#
# Charset is a whitelist, not a metachar blacklist -- a blacklist has to
# enumerate `* ? [ ] { } \ ~ ! space newline` and still misses locale/shell
# surprises. The leading-char class rejects `..`, `.`, any dotfile, and any
# leading `-` (flag-injection into the very scripts that consume the value)
# without a second special-case check. `/` and glob metachars are outside
# both classes, so path traversal, absolute paths, and glob-pattern
# interpolation are structurally impossible. 64-char cap keeps
# `<lens>.<attempt>.jsonl` inside every filesystem's NAME_MAX.
# Uses `[[ =~ ]]` only -- bash 3.2 safe.
persist_validate_id() {
	local value="$1" label="$2" kind="$3"
	local pattern
	case "$kind" in
	name) pattern='^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' ;;
	run-id) pattern='^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$' ;;
	*)
		echo "$label: persist_validate_id: unknown kind '$kind'" >&2
		return 2
		;;
	esac
	if [[ ! "$value" =~ $pattern ]]; then
		if [[ "$kind" == "run-id" ]]; then
			echo "$label: invalid run-id '$value' (allowed: letters, digits, '.', '_', '-', ':', first char alphanumeric, max 64)" >&2
		else
			echo "$label: invalid name '$value' (allowed: letters, digits, '.', '_', '-', first char alphanumeric, max 64)" >&2
		fi
		return 2
	fi
	return 0
}

# persist_validate_unit <value> <label>
#
# Validate ONE review unit. A unit is NOT an id: unlike a lens name or a
# run-id it is a free-form review target — deep-review passes diff-derived
# FILE PATHS, review-plan passes PLAN SECTION headings — so paths with
# spaces, parentheses, `#`, `+` or non-ASCII characters are all legitimate
# and a persist_validate_id-style whitelist would reject real input. This is
# therefore a deliberately NARROW BLACKLIST of the characters that make an
# interpolated string dangerous, not a whitelist of the characters that make
# one safe.
#
# THIS FUNCTION OWNS THE ARGV RULES, AND ONLY THEM, AND ITS SIGNATURE NOW SAYS
# SO. Round 5 (R8) deleted the `file` arm that used to restate
# PERSIST_UNIT_JQ_GATE's per-element rule in bash, which left a <source>
# parameter with exactly one legal value — a parameter expressing no choice,
# whose only remaining job was rejecting a word nothing meant any more, and
# whose presence invited a future reader to conclude "there is another wire"
# and invent one. Round 6 (F7) dropped it. The FILE/JSON wire has a different
# owner: PERSIST_UNIT_JQ_GATE, above, is that wire's sole rule set, expressed
# once in jq over the whole array. Do not add a wire selector back here; add a
# rule to whichever owner the wire already has.
#
# What this function adds ON TOP of the gate's rules: leading
# `-`, `$`, backtick, `"`, `\`, newline and comma. Each is a property of THIS
# wire, not of a unit — a git path or a plan heading may legally begin with
# `-` or contain a comma, and both are accepted on the file/JSON transports.
#
# The gate's NUL rule is deliberately NOT restated here, and that is not the
# `file`-arm mistake repeating itself. A NUL cannot reach argv at all: execve()
# terminates every argument at the first NUL, and a bash variable cannot hold
# one, so `[[ "$value" == *$'\0'* ]]` is `*""*` — a pattern that matches EVERY
# value. A restated rule here would reject all units, not NUL-bearing ones.
# The rule lives once, in PERSIST_UNIT_JQ_GATE, on the wire that can carry the
# byte.
#
#   argv — the unit arrived on a command line the orchestrator ASSEMBLED AS
#          SHELL TEXT (`--expected "<lens>:<unit>,<unit>"`). Substitution
#          happens in the orchestrator's shell BEFORE this script is entered,
#          so no in-script check can see the pre-substitution text; what this
#          check buys is defence in depth against a unit that is echoed back
#          into another command line, and a loud failure that names the
#          offending text. Adds: `$`, backtick, `"`, `\` and newline —
#          precisely the five characters that let interpolated text trigger
#          substitution or escape its quoting. Double quotes around the
#          argument stop word-splitting and globbing; they do NOT stop
#          substitution, which is why quoting alone was not a fix.
#
# The PRIMARY control for diff-derived units is not this function: it is
# keeping them off argv entirely via --expected-file. This is layer 2.
#
# Prints "<label>: invalid unit ..." to stderr and returns 2 on failure.
persist_validate_unit() {
	local value="$1" label="$2"

	if [[ -z "$value" ]]; then
		echo "$label: invalid unit: empty unit name" >&2
		return 2
	fi
	# Comma: on argv a unit list IS comma-separated (`--expected
	# <lens>:<u1>,<u2>`, `--units <csv>`), so a comma-bearing unit would
	# silently split into two. That is a property of THIS wire.
	if [[ "$value" == *,* ]]; then
		echo "$label: invalid unit '$value' (unit lists on the command line are comma-separated; a unit passed on argv must not contain a comma - pass it via the units file instead)" >&2
		return 2
	fi
	# Leading '-': the value reaches a command line, where it would be
	# parsed as a flag.
	if [[ "$value" == -* ]]; then
		echo "$label: invalid unit '$value' (a unit passed on the command line must not start with '-'; it would be parsed as a flag - pass it via the units file instead)" >&2
		return 2
	fi
	# Newline first: it is the one character that cannot be shown usefully
	# inside the quoted echo below.
	if [[ "$value" == *$'\n'* ]]; then
		echo "$label: invalid unit: a unit passed on the command line must not contain a newline" >&2
		return 2
	fi
	if [[ "$value" == *'$'* || "$value" == *'`'* || "$value" == *'"'* || "$value" == *\\* ]]; then
		printf '%s: invalid unit %s (a unit passed on the command line must not contain a dollar sign, backtick, double quote or backslash - pass diff-derived units via --expected-file instead)\n' \
			"$label" "$value" >&2
		return 2
	fi

	return 0
}

# persist_units_csv_to_json <csv> <label>
#
# The ONLY splitter for an argv units CSV in this tree. Prints a compact JSON
# array on stdout; returns 2 with a diagnostic on any violation.
#
# Round 5 (R1/R2). The argv CSV wire had grown one ad-hoc splitter per call
# site, and collect-lens-results.sh had grown TWO for a single value: an
# `IFS=',' read -r -a` pass to VALIDATE and a `jq -R 'split(",")'` pass to
# BUILD. They agree on every input but one — a single trailing comma, which
# `read -a` drops and jq keeps as an empty element. The dropped element was
# never validated, so `--expected 'logic:a,b,'` assigned a lens an EMPTY unit
# that nothing can ever report, stranding it at `partial` forever. Meanwhile
# persist-lens-result.sh's `--units` split in jq and validated with the FILE
# wire's gate, so it accepted `-foo` and `src/$(id).ts` that the reader
# refused.
#
# The split happens exactly ONCE, in jq, and every element it produces is then
# run through the ARGV rules — so the elements validated are exactly the
# elements persisted, and writer and reader accept and reject identical CSVs.
#
# `jq -n --arg`, deliberately NOT `jq -R`: `-R` is line-oriented, so an
# embedded newline emits TWO documents and the caller's `--argjson` aborts
# with exit 1 instead of the contract's exit 2. `--arg` carries the byte
# string whole, so the newline survives to be REJECTED below by a rule that
# names it.
persist_units_csv_to_json() {
	local csv="$1" label="$2" units_json u
	if [[ -z "$csv" ]]; then
		printf '[]\n'
		return 0
	fi
	if ! units_json="$(jq -n -c --arg csv "$csv" '$csv | split(",")')"; then
		echo "$label: could not parse the unit list '$csv'" >&2
		return 2
	fi
	# NUL-delimited jq stream into `read -d ''`, so an element containing a
	# newline is ONE element rather than two. (The newline is then rejected
	# by the argv rules; the framing must be right first, or the diagnostic
	# would name the wrong text.)
	while IFS= read -r -d '' u; do
		persist_validate_unit "$u" "$label" || return 2
	done < <(printf '%s' "$units_json" | jq -j '.[] | ., "\u0000"')
	printf '%s\n' "$units_json"
	return 0
}

persist_jsonl_append() {
	local path="$1" line="$2"
	local dir
	dir="$(dirname "$path")"
	if ! mkdir -p "$dir" 2>/dev/null; then
		echo "persist-common: could not create $dir" >&2
		return 1
	fi
	if ! printf '%s\n' "$line" >>"$path"; then
		echo "persist-common: could not append to $path" >&2
		return 1
	fi
	return 0
}
