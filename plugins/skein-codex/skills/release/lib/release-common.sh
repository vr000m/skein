#!/usr/bin/env bash
# release-common.sh — shared helpers for the release skill's extracted lib/
# scripts (read-release-template.sh, resolve-template-marker.sh). Sourced,
# never executed; no top-level side effects. Harness-neutral: no plugin-root
# anchor, so both mirrors carry a byte-identical copy (RELEASE_LIB_PARITY_FILES
# in tests/parity/test-applier-bundle-parity.sh).
#
# Exit-code vocabulary (grilled decision 20): 0 ok, 1 validation failure,
# 2 environment failure.

# release_require_exe <VAR_NAME> — the pinned-executable re-check (grilled
# decision 17): the env var must hold an absolute path to an existing,
# executable, non-symlink regular file **whose parent components are also
# symlink-free**. A non-symlink leaf under a symlinked directory is still a
# redirectable path (SKILL.md's "require every executable and path component to
# be ... non-symlink"), so the physical resolution of the containing directory
# must equal the spelling given. Returns 2 otherwise.
release_require_exe() {
	local value="${!1-}" dir resolved
	[[ -n "$value" ]] || return 2
	[[ "$value" == /* ]] || return 2
	[[ ! -L "$value" ]] || return 2
	[[ -f "$value" && -x "$value" ]] || return 2
	dir="${value%/*}"
	[[ -n "$dir" ]] || dir="/"
	resolved="$(cd -P -- "$dir" 2>/dev/null && pwd -P)" || return 2
	[[ "$resolved" == "$dir" ]] || return 2
	return 0
}

# release_json_escape <string> — minimal RFC 8259 string-body escaping, without
# jq (jq may be unset on the untemplated path). Free-form values (notes, gate
# text, git mode strings) reach release_emit, so every interpolated string is
# escaped here rather than trusted to be a controlled token.
release_json_escape() {
	local s="${1-}" out="" ch
	s="${s//\\/\\\\}"
	s="${s//\"/\\\"}"
	s="${s//$'\n'/\\n}"
	s="${s//$'\r'/\\r}"
	s="${s//$'\t'/\\t}"
	if [[ "$s" == *[$'\001'-$'\037\177']* ]]; then
		while [[ -n "$s" ]]; do
			ch="${s:0:1}"
			[[ "$ch" == [$'\001'-$'\037\177'] ]] && printf -v ch '\\u%04x' "'$ch"
			out+="$ch"
			s="${s:1}"
		done
		s="$out"
	fi
	printf '%s' "$s"
}

# release_emit <script> <site> <decision> <exit-code> <failed-gate|""> [rows-json]
# Prints the decision JSON to stdout WITHOUT needing jq (jq may be unset on the
# untemplated path). Every interpolated string goes through
# release_json_escape, because `failed_gate` carries free-form note text at
# some call sites; `rows` is already-valid JSON and is spliced verbatim.
# `case` is "untemplated" only for the absent-noop / canonical-only decisions.
release_emit() {
	local script="$1" site="$2" decision="$3" code="$4" gate="${5-}" rows="${6-null}" case_name="${7-templated}"
	local gate_json="null"
	[[ -n "$gate" ]] && gate_json="\"$(release_json_escape "$gate")\""
	# `code` and `rows` are hand-spliced (unquoted) into the JSON below, not
	# through release_json_escape — a string escaper doesn't make an invalid
	# NUMBER or a malformed/empty ARRAY into valid JSON at those two positions.
	# A caller can hand this an empty `rows` when an upstream `jq` pipeline
	# failed under `set -uo pipefail` (no `-e`): resolve-template-marker.sh's
	# `"$JQ" -c 'sort_by(.version)' <<<"$rows"` would leave `$rows` empty on a
	# failure that this function's own exit code never sees, producing invalid
	# JSON `"rows":,` on a nominally-zero exit. Gate both here, once, so every
	# call site is protected without needing jq itself (deliberately absent on
	# the untemplated path).
	[[ "$code" =~ ^-?[0-9]+$ ]] || code=1
	[[ -n "$rows" && ("$rows" == null || "$rows" =~ ^[[:space:]]*[\[{]) ]] || rows="[]"
	printf '{"case":"%s","decision":"%s","exit_code":%s,"failed_gate":%s,"rows":%s,"script":"%s","site":"%s"}\n' \
		"$(release_json_escape "$case_name")" "$(release_json_escape "$decision")" \
		"$code" "$gate_json" "$rows" \
		"$(release_json_escape "$script")" "$(release_json_escape "$site")"
}

# jq programs are single-quoted on purpose (they contain $vars for jq).
# The excluded_sections bound is 200 characters: jq's `length` on a string
# counts counts codepoints, not bytes (a byte bound would
# require `utf8bytelength`).
# shellcheck disable=SC2016
# release_validate_gates <jq> <file> — the Step 1b item 4 jq gate sequence,
# each gate reading the template bytes on stdin only (redirect from <file>, no
# file operand, nothing spliced into a command line). Prints the failing gate
# name on stdout and returns 1; prints nothing and returns 0 when every gate
# passes.
release_validate_gates() {
	local jq="$1" file="$2"
	"$jq" empty <"$file" >/dev/null 2>&1 || {
		echo "jq-empty"
		return 1
	}
	"$jq" -se 'length == 1' <"$file" >/dev/null 2>&1 || {
		echo "single-document"
		return 1
	}
	"$jq" -e 'type == "object"' <"$file" >/dev/null 2>&1 || {
		echo "object-type"
		return 1
	}
	"$jq" -n --stream -e '[inputs] as $raw | ($raw | fromstream(.[])) as $obj | ($obj | [tostream]) as $canon | ($raw|length) == ($canon|length)' <"$file" >/dev/null 2>&1 || {
		echo "duplicate-key"
		return 1
	}
	"$jq" -e '(keys - ["title_format","compare_line_label","excluded_sections","whats_new"]) == []' <"$file" >/dev/null 2>&1 || {
		echo "unknown-key"
		return 1
	}
	"$jq" -e '((has("title_format")|not) or (.title_format == "bare" or .title_format == "canonical")) and ((has("compare_line_label")|not) or (.compare_line_label == "Full diff" or .compare_line_label == "Full changelog" or .compare_line_label == "none"))' <"$file" >/dev/null 2>&1 || {
		echo "enum"
		return 1
	}
	"$jq" -e '(has("whats_new")|not) or (.whats_new | type == "boolean")' <"$file" >/dev/null 2>&1 || {
		echo "whats-new-type"
		return 1
	}
	"$jq" -e '(has("excluded_sections")|not) or (.excluded_sections as $es | ($es|type) == "array" and ($es|length) <= 20 and ($es|all(.[]; (type == "string") and (length >= 1) and (length <= 200) and test("^### [^\\n]+$") and ((test("[\\x00-\\x1F\\x7F]"))|not))) and (($es|unique|length) == ($es|length)))' <"$file" >/dev/null 2>&1 || {
		echo "excluded-sections-shape"
		return 1
	}
	return 0
}
