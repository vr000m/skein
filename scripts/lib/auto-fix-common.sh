#!/usr/bin/env bash
# auto-fix-common.sh — shared helpers for the deep-review and review-plan
# auto-fix appliers (`scripts/apply-auto-fix-code.sh`,
# `scripts/apply-auto-fix-plan.sh`).
#
# Source this file from an applier; it does not run on its own.
#
# Helpers provided:
#   af_have_jq                 — exit 2 if jq is missing.
#   af_allowlist_kinds <skill> — print newline-separated kinds for a skill.
#   af_allowlist_contains <skill> <kind>
#                              — return 0/1 whether kind is in the allowlist.
#   af_save_blob <path>        — `git hash-object -w` the file and echo the sha.
#   af_restore_blob <path> <sha>
#                              — restore the file's content from a saved blob.
#                                Unstages the path with `git restore --staged`.
#   af_apply_replacement <path> <line> <before> <after>
#                              — single-line literal replacement at file:line.
#                                Fails non-zero if the line does not byte-match.
#   af_commit_one <subject> <trailer>
#                              — `git commit -m <subject> --trailer <trailer>`,
#                                echo the resulting commit sha.
#   af_manifest_dir <skill>    — print the manifest directory for a skill.
#   af_manifest_path <skill>   — print the manifest path for the current run.
#   af_manifest_init <skill>   — create manifest dir; reset internal entries.
#   af_manifest_record <kind> <file> <line> <status> <commit_sha> <before_sha> [<evidence>]
#                              — append one entry to the in-memory manifest.
#   af_manifest_write          — write the manifest JSON to disk.
#
# The helpers prefer the jq pipeline. jq is required for any v2 auto_fix
# applier work (matching `audit-auto-fix-eligibility.sh` and the reconciler).

set -euo pipefail

if [[ -z "${AF_COMMON_ROOT:-}" ]]; then
	AF_COMMON_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
AF_ALLOWLIST_PATH="$AF_COMMON_ROOT/scripts/auto-fix-allowlist.json"

af_have_jq() {
	if ! command -v jq >/dev/null 2>&1; then
		echo "auto-fix: jq is required to apply v2 auto_fix envelopes" >&2
		exit 2
	fi
}

af_allowlist_kinds() {
	local skill="$1"
	af_have_jq
	jq -r --arg skill "$skill" '.[$skill][]?' "$AF_ALLOWLIST_PATH"
}

af_allowlist_contains() {
	local skill="$1"
	local kind="$2"
	af_have_jq
	jq -e --arg skill "$skill" --arg kind "$kind" '.[$skill] | index($kind)' \
		"$AF_ALLOWLIST_PATH" >/dev/null
}

# Refuse to touch a path that is (or whose parent is) a symlink. Lens-supplied
# paths must resolve to real in-tree files; symlinks would let an attacker
# direct git hash-object reads or restore writes through to out-of-tree
# targets. resolve_path already rejects absolute/`..` paths textually; this is
# the runtime-state guard for the symlink case.
af_assert_no_symlink() {
	local path="$1"
	if [[ -L "$path" ]]; then
		echo "auto-fix: refusing to operate on symlink: $path" >&2
		return 6
	fi
	# A symlinked parent dir is equally dangerous — git hash-object dereferences.
	local parent
	parent="$(dirname "$path")"
	while [[ "$parent" != "/" && "$parent" != "." ]]; do
		if [[ -L "$parent" ]]; then
			echo "auto-fix: refusing to operate under symlinked parent: $parent" >&2
			return 6
		fi
		parent="$(dirname "$parent")"
	done
	return 0
}

af_save_blob() {
	local path="$1"
	af_assert_no_symlink "$path" || return $?
	git hash-object -w "$path"
}

af_restore_blob() {
	local path="$1"
	local sha="$2"
	af_assert_no_symlink "$path" || return $?
	# Restore working-tree content from the saved blob, then unstage so the
	# index matches HEAD again (the touched path may have been `git add`-ed
	# during the apply attempt).
	git cat-file blob "$sha" >"$path"
	git restore --staged -- "$path" 2>/dev/null || true
}

# Single-line literal replacement at file:line. `before` may carry a trailing
# newline (the lens-emitted block typically does); both `before` and the
# file line are normalised to drop a single trailing newline before comparing.
af_apply_replacement() {
	local path="$1"
	local line="$2"
	local before="$3"
	local after="$4"
	if [[ ! -f "$path" ]]; then
		return 3
	fi
	af_assert_no_symlink "$path" || return $?
	# Strip a single trailing newline from `before` and `after` so a v1
	# producer that ends every literal with "\n" matches a file line that
	# does not include the newline.
	before="${before%$'\n'}"
	after="${after%$'\n'}"
	if [[ "$before" == *$'\n'* ]]; then
		# Multi-line — caller should have routed to a different path.
		return 4
	fi
	local actual
	actual="$(awk -v target="$line" 'NR == target { print; found=1; exit } END { if (!found) exit 1 }' "$path")" || return 2
	if [[ "$actual" != "$before" ]]; then
		return 2
	fi
	# Rewrite the file with the line replaced. Pass `after` via the environment
	# rather than `awk -v` to avoid awk's backslash-escape interpretation of
	# attacker-controlled strings (a literal `\n` in `after` would otherwise
	# become a real newline and break the single-line invariant).
	local tmp
	tmp="$(mktemp)"
	AF_REPL="$after" awk -v target="$line" '
		BEGIN { repl = ENVIRON["AF_REPL"] }
		NR == target { print repl; next }
		{ print }
	' "$path" >"$tmp"
	mv "$tmp" "$path"
}

af_commit_one() {
	local subject="$1"
	local trailer="$2"
	# `git commit --trailer` requires git >= 2.32. Fall back to interpret-trailers
	# via a message file if --trailer is unsupported.
	if git commit -m "$subject" --trailer "$trailer" >/dev/null 2>&1; then
		:
	else
		local msg
		msg="$(printf '%s\n\n%s\n' "$subject" "$trailer")"
		git commit -m "$msg" >/dev/null
	fi
	git rev-parse HEAD
}

af_manifest_dir() {
	local skill="$1"
	case "$skill" in
	deep-review) printf '%s' "$AF_COMMON_ROOT/.deep-review" ;;
	review-plan) printf '%s' "$AF_COMMON_ROOT/.review-plan" ;;
	*)
		echo "auto-fix: unknown skill: $skill" >&2
		return 2
		;;
	esac
}

AF_MANIFEST_PATH=""
AF_MANIFEST_ENTRIES=()

af_manifest_init() {
	local skill="$1"
	local dir
	dir="$(af_manifest_dir "$skill")"
	# Refuse to follow a pre-existing symlink at the manifest dir path.
	# Without this, an attacker who plants .deep-review/ or .review-plan/
	# as a symlink to e.g. ~/.ssh redirects every manifest write through it.
	if [[ -L "$dir" ]]; then
		echo "auto-fix: refusing to write manifest under symlinked dir: $dir" >&2
		return 6
	fi
	mkdir -p "$dir"
	AF_MANIFEST_PATH="$dir/auto-fix-$(date +%s).json"
	AF_MANIFEST_ENTRIES=()
}

af_manifest_path() {
	printf '%s\n' "$AF_MANIFEST_PATH"
}

af_manifest_record() {
	# kind file line status commit_sha before_sha [evidence]
	af_have_jq
	local kind="$1" file="$2" line="$3" status="$4" commit_sha="$5" before_sha="$6"
	local evidence="${7:-}"
	local entry
	entry="$(jq -n \
		--arg kind "$kind" \
		--arg file "$file" \
		--arg line "$line" \
		--arg status "$status" \
		--arg commit_sha "$commit_sha" \
		--arg before_sha "$before_sha" \
		--arg evidence "$evidence" \
		'{kind: $kind, file: $file, line: ($line | tonumber? // $line), status: $status, commit_sha: $commit_sha, before_sha: $before_sha} + (if $evidence == "" then {} else {evidence: $evidence} end)')"
	AF_MANIFEST_ENTRIES+=("$entry")
}

af_manifest_write() {
	af_have_jq
	if [[ -z "$AF_MANIFEST_PATH" ]]; then
		echo "auto-fix: manifest path not initialised" >&2
		return 2
	fi
	if [[ "${#AF_MANIFEST_ENTRIES[@]}" -eq 0 ]]; then
		printf '[]\n' >"$AF_MANIFEST_PATH"
		return 0
	fi
	printf '%s\n' "${AF_MANIFEST_ENTRIES[@]}" | jq -s '.' >"$AF_MANIFEST_PATH"
}
