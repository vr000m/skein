#!/usr/bin/env bash
# read-release-template.sh — Step 1b's presence oracle, commit precondition and
# jq validation gates, extracted from SKILL.md prose. Pure over injected inputs
# (grilled decision 9/18): presence facts arrive as argv, the committed template
# bytes on stdin; the script probes nothing itself. Pinned jq arrives as an
# absolute path in RELEASE_JQ (required only when a template is present).
#
# Usage:
#   read-release-template.sh --site <step1b-precondition|step1b-validate|
#       step5-reverify|step6-reverify>
#       --worktree <absent|present-untracked|present-tracked-clean|
#                   present-tracked-dirty|present-not-regular>
#       --head-commit <present|absent> [--mode <six-digit-mode>]
#       --head-sha <40-hex>
#     (--head-sha is REQUIRED: SKILL.md's Scope paragraph and Step 1b's
#      single-HEAD-resolution rule make the 40-hex check a precondition of the
#      presence oracle, so an omitted value must not silently skip it)
#     (validate/reverify sites read the committed template bytes on stdin)
#
# Stdout: one JSON object {case,decision,exit_code,failed_gate,rows,script,site}.
# Exit: 0 ok, 1 validation failure, 2 environment failure (decision 20).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugins/skein/skills/release/lib/release-common.sh
. "$HERE/release-common.sh"

SCRIPT="read-release-template"
site="" worktree="" head_commit="" mode="" head_sha=""

usage_fail() {
	echo "read-release-template.sh: $1" >&2
	release_emit "$SCRIPT" "${site:-unknown}" "environment-failure" 2 "bad-arguments" null untemplated
	exit 2
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--site) site="${2-}" ;;
	--worktree) worktree="${2-}" ;;
	--head-commit) head_commit="${2-}" ;;
	--mode) mode="${2-}" ;;
	--head-sha) head_sha="${2-}" ;;
	*) usage_fail "unknown argument: $1" ;;
	esac
	shift 2 || usage_fail "missing value for an argument"
done

case "$site" in
step1b-precondition | step1b-validate | step5-reverify | step6-reverify) ;;
*) usage_fail "unknown --site" ;;
esac
case "$worktree" in
absent | present-untracked | present-tracked-clean | present-tracked-dirty | present-not-regular) ;;
*) usage_fail "unknown --worktree" ;;
esac
case "$head_commit" in
present | absent) ;;
*) usage_fail "unknown --head-commit" ;;
esac

finish() { # decision code gate case
	release_emit "$SCRIPT" "$site" "$1" "$2" "${3-}" null "${4-templated}"
	exit "$2"
}

# SHA-256 (or other non-SHA-1) hard stop runs before the presence oracle, and
# it runs unconditionally: --head-sha is mandatory, so omitting it can never
# turn the hard stop off.
[[ -n "$head_sha" ]] || usage_fail "--head-sha is required"
if [[ ! "$head_sha" =~ ^[0-9a-f]{40}$ ]]; then
	echo "SHA-256 (or other non-SHA-1) repositories are not supported" >&2
	finish "hard-stop" 1 "non-sha1-repository"
fi

# Item 2: presence oracle (two-sided) and type.
if [[ "$worktree" == "absent" && "$head_commit" == "absent" ]]; then
	finish "absent-noop" 0 "" untemplated
fi
if [[ "$worktree" == "present-not-regular" ]]; then
	finish "precondition-failed" 1 "not-regular-file"
fi
if [[ "$head_commit" == "present" && "$mode" != "100644" && "$mode" != "100755" ]]; then
	finish "precondition-failed" 1 "tracked-mode"
fi

# Item 3: commit precondition.
case "$worktree" in
present-untracked) finish "precondition-failed" 1 "untracked" ;;
absent | present-tracked-dirty) finish "precondition-failed" 1 "tracked-but-dirty" ;;
esac
[[ "$head_commit" == "present" ]] || finish "precondition-failed" 1 "untracked"

if [[ "$site" == "step1b-precondition" ]]; then
	finish "precondition-ok" 0
fi

# Item 1/4: pin jq (present branch only), then the gate sequence on stdin bytes.
release_require_exe RELEASE_JQ || {
	echo "RELEASE_JQ must be an absolute path to an executable jq" >&2
	finish "environment-failure" 2 "jq-unresolvable"
}

tmp="$(mktemp "${TMPDIR:-/tmp}/release-template.XXXXXX")" || finish "environment-failure" 2 "tmpfile"
trap 'rm -f "$tmp"' EXIT
cat >"$tmp" || finish "environment-failure" 2 "stdin-unreadable"

if gate="$(release_validate_gates "$RELEASE_JQ" "$tmp")"; then
	finish "template-valid" 0
fi
finish "gate-failed" 1 "$gate"
