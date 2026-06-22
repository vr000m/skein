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

# AF_ALLOWLIST_PATH — derived from this file's location. The allowlist lives
# next to the lib regardless of where the applier is invoked from. Callers do
# NOT override this; the lib owns the allowlist source-of-truth.
AF_LIB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AF_ALLOWLIST_PATH="$AF_LIB_ROOT/scripts/auto-fix-allowlist.json"
readonly AF_LIB_ROOT AF_ALLOWLIST_PATH

# AF_COMMON_ROOT — caller-supplied. Where manifest dirs (.deep-review,
# .review-plan) live, i.e. the operator's repo root. Callers MUST set this
# before invoking af_manifest_init; the assertion in af_manifest_init catches
# omissions loudly rather than letting a future caller silently write
# manifests into the lib's own directory tree.

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
	# Optional root bound: stop walking parents at <root>. When unset, walk
	# all the way to `/`. The auditor passes its AUDIT_ROOT so test fixtures
	# under symlinked prefixes (e.g. macOS `/tmp` → `/private/tmp`) are not
	# rejected on a parent dir the auto-fix surface doesn't touch. The
	# appliers omit the bound: their writes go via `git hash-object -w` which
	# dereferences anywhere along the path, so they prefer the stricter walk.
	local root="${2:-}"
	if [[ -L "$path" ]]; then
		echo "auto-fix: refusing to operate on symlink: $path" >&2
		return 6
	fi
	local root_canon=""
	if [[ -n "$root" ]]; then
		root_canon="$(cd "$root" 2>/dev/null && pwd -P)" || root_canon=""
	fi
	# A symlinked parent dir is equally dangerous — git hash-object dereferences.
	local parent parent_canon
	parent="$(dirname "$path")"
	while [[ "$parent" != "/" && "$parent" != "." ]]; do
		if [[ -L "$parent" ]]; then
			echo "auto-fix: refusing to operate under symlinked parent: $parent" >&2
			return 6
		fi
		if [[ -n "$root_canon" ]]; then
			parent_canon="$(cd "$parent" 2>/dev/null && pwd -P)" || parent_canon=""
			if [[ "$parent_canon" == "$root_canon" ]]; then
				break
			fi
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
	if [[ -z "${AF_COMMON_ROOT:-}" ]]; then
		echo "auto-fix: AF_COMMON_ROOT must be set before af_manifest_init (this is the operator's repo root)" >&2
		return 2
	fi
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
	# Suffix with PID to avoid collisions on second-level granularity even
	# in the (currently impossible) case where two appliers of the same kind
	# bypass the advisory mkdir lock and start within the same second.
	AF_MANIFEST_PATH="$dir/auto-fix-$(date +%s)-$$.json"
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

# ---- Path / scope helpers (shared by auditor + plan applier) ----------------

# af_canonical_existing_path <path> [<root>]
#   Echo the canonical absolute path of <path> after asserting (a) it exists,
#   (b) it is not a symlink and has no symlinked parent, and (c) it resolves
#   under <root>. <root> defaults to AF_COMMON_ROOT. Returns non-zero on any
#   failure; the auditor passes its own AUDIT_ROOT explicitly because that
#   root differs from AF_COMMON_ROOT when --plan is supplied.
af_canonical_existing_path() {
	local path="$1"
	local root="${2:-${AF_COMMON_ROOT:-}}"
	if [[ -z "$root" ]]; then
		return 1
	fi
	if [[ ! -e "$path" ]]; then
		return 1
	fi
	# Pass <root> so parent symlinks above <root> (e.g. /tmp → /private/tmp
	# on macOS test fixtures) don't reject otherwise-valid paths.
	af_assert_no_symlink "$path" "$root" >/dev/null 2>&1 || return 1
	local dir base canon root_canon
	dir="$(dirname "$path")"
	base="$(basename "$path")"
	dir="$(cd "$dir" 2>/dev/null && pwd -P)" || return 1
	canon="$dir/$base"
	root_canon="$(cd "$root" 2>/dev/null && pwd -P)" || return 1
	case "$canon" in
	"$root_canon" | "$root_canon"/*) printf '%s\n' "$canon" ;;
	*) return 1 ;;
	esac
}

# af_parse_plan_scope <scope>
#   Parse `<path>:<start>[-<end>]`. On success, sets AF_SCOPE_PATH /
#   AF_SCOPE_START / AF_SCOPE_END and returns 0. On a malformed scope
#   (including missing `:<line>`) clears the AF_SCOPE_* vars and returns 1.
#   Anchored regex form so 'a:b.md' (no integer line) is classified as
#   malformed instead of silently splitting into path='a' / range='b.md'.
# shellcheck disable=SC2034  # AF_SCOPE_END is consumed by callers (auditor scope_parts; applier parse_plan_scope wrapper)
af_parse_plan_scope() {
	local scope="$1"
	AF_SCOPE_PATH=""
	AF_SCOPE_START=""
	AF_SCOPE_END=""
	if [[ "$scope" =~ ^(.+):([0-9]+)-([0-9]+)$ ]]; then
		AF_SCOPE_PATH="${BASH_REMATCH[1]}"
		AF_SCOPE_START="${BASH_REMATCH[2]}"
		AF_SCOPE_END="${BASH_REMATCH[3]}"
	elif [[ "$scope" =~ ^(.+):([0-9]+)$ ]]; then
		AF_SCOPE_PATH="${BASH_REMATCH[1]}"
		AF_SCOPE_START="${BASH_REMATCH[2]}"
		AF_SCOPE_END="${BASH_REMATCH[2]}"
	else
		return 1
	fi
}

# AF_FORBIDDEN_HEADINGS — plan-section scope-forbid list. Single source of
# truth. Operative only on the review-plan auto-fix path (the deep-review
# auditor/applier never consult it); it is byte-bundled into the deep-review
# scripts/ subtree as a side effect of the shared-lib bundling, where it is
# inert. Matched against `scripts/plan-scope-detect.sh` output (exact
# string match for these entries; `### Phase N:` is matched separately as a
# regex below to allow any digit count). Auditor and applier MUST consult
# this array via af_heading_is_forbidden to avoid the bug class where
# auditor `would_apply` disagrees with applier `rejected_scope`.
AF_FORBIDDEN_HEADINGS=(
	"## Requirements"
	"## Acceptance Criteria"
	"### Files to Modify"
	"### New Files to Create"
	"### Architecture Decisions"
	"### Integration Seams"
	"## Architecture & Call Flow"
)
readonly AF_FORBIDDEN_HEADINGS

af_heading_is_forbidden() {
	local heading="$1"
	if [[ "$heading" =~ ^###[[:space:]]+Phase[[:space:]]+[0-9]+: ]]; then
		return 0
	fi
	local h
	for h in "${AF_FORBIDDEN_HEADINGS[@]}"; do
		if [[ "$heading" == "$h" ]]; then
			return 0
		fi
	done
	return 1
}

# af_stack_is_forbidden <detector> <plan-file> <line>
#   Resolve the enclosing heading stack via <detector> (typically
#   $SCRIPT_ROOT/scripts/plan-scope-detect.sh) in --stack mode and return:
#     0 — any ancestor heading is in the forbid list
#     1 — no ancestor heading is forbidden
#     2 — detector failed (caller should propagate non-zero)
#   Stderr from the detector is captured and surfaced on failure rather
#   than swallowed.
af_stack_is_forbidden() {
	local detector="$1"
	local path="$2"
	local line="$3"
	local heading stack_out stack_rc
	stack_out="$("$detector" --stack "$path" "$line" 2>&1)"
	stack_rc=$?
	if [[ "$stack_rc" -ne 0 ]]; then
		echo "auto-fix: plan-scope-detect --stack failed (rc=$stack_rc) for $path:$line: $stack_out" >&2
		return 2
	fi
	while IFS= read -r heading; do
		[[ -n "$heading" ]] || continue
		if af_heading_is_forbidden "$heading"; then
			return 0
		fi
	done <<<"$stack_out"
	return 1
}

# ---- Python import-statement helpers (shared by auditor + code applier) -----

# af_canonical_import_records — reads import lines on stdin and emits
# normalised binding tuples (one per line, sorted unique). Tuples are:
#     import\t<module>\t<alias>             — for `import X [as Y]`
#     from\t<module>\t<name>\t<alias>       — for `from X import Y [as Z]`
# The module path participates in the tuple so an alias-preserving module
# swap (`import old as t` → `import new as t`) is correctly detected as a
# semantic change. Exits 1 if any input line is not a recognisable import
# statement, or if no records were emitted.
af_canonical_import_records() {
	awk '
		function trim(s) {
			sub(/^[[:space:]]+/, "", s)
			sub(/[[:space:]]+$/, "", s)
			return s
		}
		function strip_comment(s) {
			sub(/[[:space:]]+#.*/, "", s)
			return trim(s)
		}
		function emit_import_item(item,  n, alias_parts, module, alias) {
			item = trim(item)
			if (item == "") return
			if (item ~ /[[:space:]]+as[[:space:]]+/) {
				n = split(item, alias_parts, /[[:space:]]+as[[:space:]]+/)
				module = trim(alias_parts[1])
				alias = trim(alias_parts[n])
			} else {
				module = item
				alias = ""
			}
			if (module !~ /^[_A-Za-z][_A-Za-z0-9.]*$/) { invalid = 1; return }
			if (alias != "" && alias !~ /^[_A-Za-z][_A-Za-z0-9]*$/) { invalid = 1; return }
			print "import\t" module "\t" alias
			seen = 1
		}
		function emit_from_item(module, item,  n, alias_parts, name, alias) {
			item = trim(item)
			if (item == "" || item == "*") { invalid = 1; return }
			if (item ~ /[[:space:]]+as[[:space:]]+/) {
				n = split(item, alias_parts, /[[:space:]]+as[[:space:]]+/)
				name = trim(alias_parts[1])
				alias = trim(alias_parts[n])
			} else {
				name = item
				alias = ""
			}
			if (module !~ /^\.?[_A-Za-z][_A-Za-z0-9.]*$/ && module !~ /^\.+[_A-Za-z][_A-Za-z0-9.]*$/) { invalid = 1; return }
			if (name !~ /^[_A-Za-z][_A-Za-z0-9]*$/) { invalid = 1; return }
			if (alias != "" && alias !~ /^[_A-Za-z][_A-Za-z0-9]*$/) { invalid = 1; return }
			print "from\t" module "\t" name "\t" alias
			seen = 1
		}
		{
			line = strip_comment($0)
			if (line == "") next
			if (line ~ /^import[[:space:]]+/) {
				sub(/^import[[:space:]]+/, "", line)
				count = split(line, items, /,/)
				for (i = 1; i <= count; i++) emit_import_item(items[i])
			} else if (line ~ /^from[[:space:]]+[^[:space:]]+[[:space:]]+import[[:space:]]+/) {
				module = line
				sub(/^from[[:space:]]+/, "", module)
				sub(/[[:space:]]+import[[:space:]].*$/, "", module)
				sub(/^from[[:space:]]+[^[:space:]]+[[:space:]]+import[[:space:]]+/, "", line)
				count = split(line, items, /,/)
				for (i = 1; i <= count; i++) emit_from_item(module, items[i])
			} else {
				invalid = 1
			}
		}
		END { if (invalid || !seen) exit 1 }
	' | sort -u
}

# af_same_import_symbol_set <before> <after>
#   True iff both sides canonicalise to the same set of import bindings.
#   Either side failing to canonicalise (non-import line, malformed
#   identifier) returns non-zero — used by the import_sort kind gate to
#   reject both semantic changes and non-import cited lines.
af_same_import_symbol_set() {
	local before="$1" after="$2" before_records after_records
	before_records="$(printf '%s\n' "$before" | af_canonical_import_records)" || return 1
	after_records="$(printf '%s\n' "$after" | af_canonical_import_records)" || return 1
	[[ "$before_records" == "$after_records" ]]
}
