#!/usr/bin/env bash
# gauntlet-common.sh — shared helpers for review-gauntlet's authored scripts
# (`run-gate.sh`, `convergence-ledger.sh`). Lives in the skill's lib/ dir,
# alongside them; the bundled shared pipeline lives in the sibling scripts/.
#
# Source this file; it does not run on its own (no top-level side effects).
#
# Helpers provided:
#   gc_have_jq                        — exit 2 if jq is missing.
#   gc_have_sha                       — exit 2 if neither shasum nor sha1sum
#                                        is available.
#   gc_bundled_scripts_dir            — echo this skill's own bundled
#                                        scripts/ dir, anchored via
#                                        $SKILL_DIR when set, else
#                                        derived from this file's own
#                                        location. Aborts (non-zero + stderr)
#                                        if the directory is absent — never
#                                        falls back to a hand copy or to
#                                        ../../deep-review/scripts.
#   gc_bundled_script <basename>      — echo the absolute path to a bundled
#                                        script/asset by basename, resolved
#                                        under gc_bundled_scripts_dir.
#                                        Aborts if the file itself is absent.
#   gc_normalize_finding <json>       — echo a finding normalised to exactly
#                                        the common schema keys
#                                        (file, line, category, severity,
#                                        confidence, summary, evidence),
#                                        defaulting absent keys to null/"".
#   gc_ledger_path <target> <author>  — echo a target-keyed ledger path under
#                                        the current repo's .gauntlet/ dir.
#
# Dependencies: bash + jq + shasum|sha1sum. jq is required — the gauntlet's
# finding schema is JSON throughout, matching the reconciler and appliers this
# skill bundles.

set -euo pipefail

gc_have_jq() {
	if ! command -v jq >/dev/null 2>&1; then
		echo "gauntlet: jq is required" >&2
		exit 2
	fi
}

gc_have_sha() {
	if command -v shasum >/dev/null 2>&1 || command -v sha1sum >/dev/null 2>&1; then
		return 0
	fi
	echo "gauntlet: shasum or sha1sum is required" >&2
	exit 2
}

gc_sha1() {
	gc_have_sha
	if command -v shasum >/dev/null 2>&1; then
		shasum | awk '{print $1}'
	else
		sha1sum | awk '{print $1}'
	fi
}

# GC_LIB_DIR — this file's own directory, used only as the last-resort
# derivation base when SKILL_DIR is unset (e.g. direct script
# invocation during development/testing outside the installed plugin tree).
GC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly GC_LIB_DIR

gc_bundled_scripts_dir() {
	local dir
	if [[ -n "${SKILL_DIR:-}" ]]; then
		dir="${SKILL_DIR}/scripts"
	else
		# GC_LIB_DIR is .../review-gauntlet/lib (this skill's authored scripts);
		# the bundled shared pipeline lives in the sibling scripts/ dir. If it is
		# not present yet (pre-bundle dev tree), the command substitution yields
		# an empty string and the -d guard below aborts.
		dir="$(cd "$GC_LIB_DIR/../scripts" && pwd)"
	fi
	if [[ ! -d "$dir" ]]; then
		echo "gauntlet: bundled scripts dir not found at $dir — never falling back to a hand copy or ../../deep-review/scripts" >&2
		return 3
	fi
	printf '%s\n' "$dir"
}

gc_bundled_script() {
	local basename="$1"
	local dir path
	dir="$(gc_bundled_scripts_dir)" || return $?
	path="$dir/$basename"
	if [[ ! -e "$path" ]]; then
		echo "gauntlet: bundled script/asset missing: $path — run scripts/bundle-appliers.sh (Phase 6) or check the install; never fall back to a relative deep-review path" >&2
		return 3
	fi
	printf '%s\n' "$path"
}

gc_normalize_finding() {
	local finding="$1"
	gc_have_jq
	printf '%s' "$finding" | jq -c '{
		file: (.file // ""),
		line: (.line // null),
		category: (.category // ""),
		severity: (.severity // ""),
		confidence: (.confidence // null),
		summary: (.summary // ""),
		evidence: (.evidence // "")
	}'
}

gc_ledger_path() {
	local target="${1:-}"
	local author="${2:-}"
	local repo_root slug digest

	if [[ -z "$target" ]]; then
		echo "gauntlet: gc_ledger_path requires a target" >&2
		return 2
	fi
	if [[ "$author" != "claude" && "$author" != "codex" ]]; then
		echo "gauntlet: gc_ledger_path author must be 'claude' or 'codex' (got '$author')" >&2
		return 2
	fi
	if ! repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
		echo "gauntlet: gc_ledger_path must run inside a git worktree" >&2
		return 3
	fi

	slug="$(printf '%s' "$target" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
	if [[ -z "$slug" ]]; then
		slug="target"
	fi
	digest="$(printf '%s' "$target" | gc_sha1)"
	printf '%s/.gauntlet/ledger-%s-%s-%s.json\n' "$repo_root" "$author" "$slug" "${digest:0:12}"
}
