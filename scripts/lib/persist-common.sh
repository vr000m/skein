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
#   - persist_root_dir, persist_require_value,
#     persist_validate_json_shape        — all four.
#   - persist_atomic_write               — STATE-FILE callers only. The lens
#                                          contract is append-only (see
#                                          persist_jsonl_append), so an
#                                          atomic replace-in-place would be
#                                          the wrong primitive there.
#                                          (persist_fail is internal to this
#                                          file, used only by
#                                          persist_atomic_write.)
#   - persist_lens_state_dir,
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
#   persist_validate_unit <value> <label> <source>
#                              — validate ONE review unit (source =
#                                argv|file). A narrow blacklist, NOT a
#                                persist_validate_id-style whitelist: units
#                                are free-form review targets (file paths for
#                                deep-review, plan sections for review-plan).
#                                See the function for the exact rules and why
#                                the two sources differ.

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
persist_validate_json_shape() {
	local input="$1" label="$2" noun="$3" object_suffix="${4:-}"

	if ! printf '%s' "$input" | jq -e . >/dev/null 2>&1; then
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

# persist_validate_unit <value> <label> <source>
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
# <source> selects how far the blacklist goes, because the two transports
# have genuinely different threat surfaces:
#
#   file — the unit arrived inside a JSON file (`collect-lens-results.sh
#          --expected-file`), written by the orchestrator with its file-write
#          tool and read back with jq. It never passes through a shell, so
#          only the two END-TO-END WIRE rules apply:
#            * no comma: unit lists are comma-joined and unescaped
#              everywhere downstream (collector --expected,
#              persist-lens-result.sh --units); a comma-bearing unit would
#              silently split into two.
#            * no leading '-': a unit that reaches a command line later
#              would be parsed as a flag.
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
	local value="$1" label="$2" source="${3:-argv}"

	case "$source" in
	argv | file) ;;
	*)
		echo "$label: persist_validate_unit: unknown source '$source'" >&2
		return 2
		;;
	esac

	if [[ -z "$value" ]]; then
		echo "$label: invalid unit: empty unit name" >&2
		return 2
	fi
	if [[ "$value" == *,* ]]; then
		echo "$label: invalid unit '$value' (unit lists are comma-joined and unescaped end-to-end; a unit must not contain a comma)" >&2
		return 2
	fi
	if [[ "$value" == -* ]]; then
		echo "$label: invalid unit '$value' (a unit must not start with '-'; it would be parsed as a flag)" >&2
		return 2
	fi

	if [[ "$source" == "argv" ]]; then
		# Newline first: it is the one character that cannot be shown
		# usefully inside the quoted echo below.
		if [[ "$value" == *$'\n'* ]]; then
			echo "$label: invalid unit: a unit passed on the command line must not contain a newline" >&2
			return 2
		fi
		if [[ "$value" == *'$'* || "$value" == *'`'* || "$value" == *'"'* || "$value" == *\\* ]]; then
			printf '%s: invalid unit %s (a unit passed on the command line must not contain a dollar sign, backtick, double quote or backslash - pass diff-derived units via --expected-file instead)\n' \
				"$label" "$value" >&2
			return 2
		fi
	fi

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
