#!/usr/bin/env bash
# gauntlet-common.sh — shared helpers for review-gauntlet's bundled scripts
# (`run-gate.sh`, `convergence-ledger.sh`).
#
# Source this file; it does not run on its own (no top-level side effects).
#
# Helpers provided:
#   gc_have_jq                        — exit 2 if jq is missing.
#   gc_bundled_scripts_dir            — echo this skill's own bundled
#                                        scripts/ dir, anchored via
#                                        ${CLAUDE_PLUGIN_ROOT} when set, else
#                                        derived from this file's own
#                                        location. Aborts (non-zero + stderr)
#                                        if the directory is absent — never
#                                        falls back to a hand copy or to
#                                        ../../deep-review/scripts.
#   gc_bundled_script <basename>      — echo the absolute path to a bundled
#                                        script/asset by basename, resolved
#                                        under gc_bundled_scripts_dir.
#                                        Aborts if the file itself is absent.
#   gc_strip_auto_fix <json-line>     — echo the finding with any `auto_fix`
#                                        key removed (jq `del(.auto_fix)`).
#   gc_normalize_finding <json>       — echo a finding normalised to exactly
#                                        the common schema keys
#                                        (file, line, category, severity,
#                                        confidence, summary, evidence),
#                                        defaulting absent keys to null/"".
#   gc_quarantine_record <ledger> <file> <line> <category> <blast_radius> <reason>
#                                      — append one quarantine entry to the
#                                        JSON array at <ledger> (created if
#                                        absent) so the conductor can decide
#                                        quarantine-continue vs halt.
#
# Dependencies: bash + jq. jq is required — the gauntlet's finding schema is
# JSON throughout, matching the reconciler and appliers this skill bundles.

set -euo pipefail

gc_have_jq() {
	if ! command -v jq >/dev/null 2>&1; then
		echo "gauntlet: jq is required" >&2
		exit 2
	fi
}

# GC_LIB_DIR — this file's own directory, used only as the last-resort
# derivation base when CLAUDE_PLUGIN_ROOT is unset (e.g. direct script
# invocation during development/testing outside the installed plugin tree).
GC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly GC_LIB_DIR

gc_bundled_scripts_dir() {
	local dir
	if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
		dir="${CLAUDE_PLUGIN_ROOT}/skills/review-gauntlet/scripts"
	else
		# GC_LIB_DIR is .../review-gauntlet/scripts/lib; the bundled scripts
		# dir is its parent.
		dir="$(cd "$GC_LIB_DIR/.." && pwd)"
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

gc_strip_auto_fix() {
	local line="$1"
	gc_have_jq
	printf '%s' "$line" | jq -c 'del(.auto_fix)'
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

gc_quarantine_record() {
	local ledger="$1" file="$2" line="$3" category="$4" blast_radius="$5" reason="$6"
	gc_have_jq
	if [[ ! -e "$ledger" ]]; then
		printf '[]\n' >"$ledger"
	fi
	local entry tmp
	entry="$(jq -n \
		--arg file "$file" \
		--arg line "$line" \
		--arg category "$category" \
		--arg blast_radius "$blast_radius" \
		--arg reason "$reason" \
		'{file: $file, line: ($line | tonumber? // $line), category: $category, blast_radius: $blast_radius, reason: $reason}')"
	tmp="$(mktemp)"
	jq --argjson entry "$entry" '. + [$entry]' "$ledger" >"$tmp"
	mv "$tmp" "$ledger"
}
