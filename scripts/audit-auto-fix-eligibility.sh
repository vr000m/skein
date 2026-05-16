#!/usr/bin/env bash
# audit-auto-fix-eligibility.sh
#
# Annotate a reconciled v2 finding envelope with auto_fix_status values.
# This script does not edit files and does not apply fixes.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALLOWLIST_PATH="$ROOT_DIR/scripts/auto-fix-allowlist.json"

usage() {
	echo "usage: scripts/audit-auto-fix-eligibility.sh --skill deep-review|review-plan [--plan path] [envelope.json|-]" >&2
}

SKILL=""
PLAN_PATH=""
ENVELOPE_PATH="-"

while [[ $# -gt 0 ]]; do
	case "$1" in
	--skill)
		shift
		[[ $# -gt 0 ]] || {
			usage
			exit 2
		}
		SKILL="$1"
		;;
	--plan)
		shift
		[[ $# -gt 0 ]] || {
			usage
			exit 2
		}
		PLAN_PATH="$1"
		;;
	--help | -h)
		usage
		exit 0
		;;
	-)
		ENVELOPE_PATH="-"
		;;
	*)
		if [[ "$ENVELOPE_PATH" != "-" ]]; then
			echo "audit-auto-fix-eligibility: multiple envelope paths provided" >&2
			exit 2
		fi
		ENVELOPE_PATH="$1"
		;;
	esac
	shift
done

if [[ "$SKILL" != "deep-review" && "$SKILL" != "review-plan" ]]; then
	echo "audit-auto-fix-eligibility: --skill must be deep-review or review-plan" >&2
	exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
	echo "audit-auto-fix-eligibility: jq is required to annotate v2 auto_fix envelopes" >&2
	exit 2
fi

if [[ "$ENVELOPE_PATH" == "-" ]]; then
	input="$(cat)"
else
	input="$(cat "$ENVELOPE_PATH")"
fi

schema_version="$(printf '%s' "$input" | jq -r '.schema_version // empty')"
if [[ "$schema_version" != "2" ]]; then
	echo "audit-auto-fix-eligibility: schema_version mismatch (got ${schema_version:-missing}, expected 2)" >&2
	exit 2
fi

resolve_path() {
	local path="$1"
	if [[ "$path" = /* ]]; then
		printf '%s\n' "$path"
	elif [[ -e "$path" ]]; then
		printf '%s\n' "$path"
	else
		printf '%s\n' "$ROOT_DIR/$path"
	fi
}

line_matches_before() {
	local path="$1"
	local line="$2"
	local before="$3"
	local actual
	if [[ ! "$line" =~ ^[0-9]+$ || "$line" -lt 1 || ! -f "$path" ]]; then
		return 1
	fi
	before="${before%$'\n'}"
	if [[ "$before" == *$'\n'* ]]; then
		return 2
	fi
	actual="$(awk -v target="$line" 'NR == target { print; found=1; exit } END { if (!found) exit 1 }' "$path")" || return 1
	[[ "$actual" == "$before" ]]
}

scope_parts() {
	local scope="$1"
	local range
	SCOPE_PATH="${scope%:*}"
	range="${scope##*:}"
	SCOPE_START="${range%-*}"
	if [[ "$range" == *-* ]]; then
		SCOPE_END="${range#*-}"
	else
		SCOPE_END="$SCOPE_START"
	fi
}

review_plan_scope_forbidden() {
	local path="$1"
	local line="$2"
	awk -v target="$line" '
		NR > target { exit }
		/^```/ { fenced = !fenced }
		!fenced && /^#{1,6}[[:space:]]+/ {
			hashes = $0
			sub(/[[:space:]].*/, "", hashes)
			level = length(hashes)
			text = $0
			sub(/^#{1,6}[[:space:]]+/, "", text)
			sub(/[[:space:]]+#+[[:space:]]*$/, "", text)
			heading[level] = text
			for (i = level + 1; i <= 6; i++) delete heading[i]
		}
		END {
			for (i = 1; i <= 6; i++) {
				h = heading[i]
				if (h == "Requirements" || h == "Acceptance Criteria" ||
				    h == "Files to Modify" || h == "New Files to Create" ||
				    h == "Architecture Decisions" || h == "Integration Seams" ||
				    h ~ /^Phase [0-9]+:/) {
					exit 0
				}
			}
			exit 1
		}
	' "$path"
}

status_tsv="$(mktemp)"
status_json="$(mktemp)"
trap 'rm -f "$status_tsv" "$status_json"' EXIT

index=0
while IFS= read -r finding; do
	status=""
	if [[ "$(printf '%s' "$finding" | jq -r 'has("auto_fix")')" == "true" ]]; then
		malformed="$(printf '%s' "$finding" | jq -r '
			if (.auto_fix | type) != "object" then "malformed"
			elif (.auto_fix.kind | type) != "string" then "malformed"
			elif (.auto_fix.before | type) != "string" then "malformed"
			elif (.auto_fix.after | type) != "string" then "malformed"
			elif (.auto_fix.scope | type) != "string" then "malformed"
			else empty end
		')"
		if [[ -n "$malformed" ]]; then
			status="malformed"
		else
			kind="$(printf '%s' "$finding" | jq -r '.auto_fix.kind')"
			before="$(printf '%s' "$finding" | jq -r '.auto_fix.before')"
			scope="$(printf '%s' "$finding" | jq -r '.auto_fix.scope')"
			if ! jq -e --arg skill "$SKILL" --arg kind "$kind" '.[$skill] | index($kind)' "$ALLOWLIST_PATH" >/dev/null; then
				status="rejected_kind"
			elif [[ "$SKILL" == "deep-review" ]]; then
				file="$(printf '%s' "$finding" | jq -r '.file // ""')"
				line="$(printf '%s' "$finding" | jq -r '(.line // "") | tostring')"
				path="$(resolve_path "$file")"
				if line_matches_before "$path" "$line" "$before"; then
					status="would_apply"
				else
					rc=$?
					if [[ "$rc" -eq 2 ]]; then
						status="unsupported"
					else
						status="drift"
					fi
				fi
			else
				scope_parts "$scope"
				if [[ ! "$SCOPE_START" =~ ^[0-9]+$ || ! "$SCOPE_END" =~ ^[0-9]+$ ]]; then
					status="malformed"
				elif [[ "$SCOPE_START" != "$SCOPE_END" ]]; then
					status="unsupported"
				else
					path="$(resolve_path "${PLAN_PATH:-$SCOPE_PATH}")"
					if [[ ! -f "$path" ]]; then
						status="drift"
					elif review_plan_scope_forbidden "$path" "$SCOPE_START"; then
						status="rejected_scope"
					elif line_matches_before "$path" "$SCOPE_START" "$before"; then
						status="would_apply"
					else
						rc=$?
						if [[ "$rc" -eq 2 ]]; then
							status="unsupported"
						else
							status="drift"
						fi
					fi
				fi
			fi
		fi
		printf '%s\t%s\n' "$index" "$status" >>"$status_tsv"
	fi
	index=$((index + 1))
done < <(printf '%s' "$input" | jq -c '.findings[]?')

jq -Rs '
	[split("\n")[] | select(length > 0) | split("\t") | select(length == 2) | {index: (.[0] | tonumber), status: .[1]}]
' "$status_tsv" >"$status_json"

printf '%s' "$input" | jq --slurpfile statuses "$status_json" '
	($statuses[0] | map({(.index | tostring): .status}) | add // {}) as $status_by_index |
	.findings |= (
		to_entries
		| map(.value + (if $status_by_index[(.key | tostring)] then {"auto_fix_status": $status_by_index[(.key | tostring)]} else {} end))
	)
'
