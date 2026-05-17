#!/usr/bin/env bash
# audit-auto-fix-eligibility.sh
#
# Annotate a reconciled v2 finding envelope with auto_fix_status values.
# This script does not edit files and does not apply fixes.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALLOWLIST_PATH="$ROOT_DIR/scripts/auto-fix-allowlist.json"
PLAN_SCOPE_DETECT="$ROOT_DIR/scripts/plan-scope-detect.sh"
AUDIT_ROOT="$ROOT_DIR"

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

if [[ -n "$PLAN_PATH" ]]; then
	plan_dir="$(dirname "$PLAN_PATH")"
	if [[ "$plan_dir" != /* ]]; then
		plan_dir="$(pwd)/$plan_dir"
	fi
	if plan_root="$(git -C "$plan_dir" rev-parse --show-toplevel 2>/dev/null)"; then
		AUDIT_ROOT="$plan_root"
	else
		AUDIT_ROOT="$(cd "$plan_dir" && pwd -P)"
	fi
fi

resolve_path() {
	local path="$1"
	if [[ "$path" = /* ]]; then
		printf '%s\n' "$path"
	elif [[ -e "$path" ]]; then
		printf '%s\n' "$path"
	else
		printf '%s\n' "$AUDIT_ROOT/$path"
	fi
}

resolve_repo_path() {
	local path="$1"
	if [[ -z "$path" || "$path" = /* ]]; then
		return 1
	fi
	if [[ "$path" =~ (^|/)\.\.(/|$) ]]; then
		return 1
	fi
	printf '%s\n' "$AUDIT_ROOT/$path"
}

assert_no_symlink() {
	local path="$1"
	if [[ -L "$path" ]]; then
		return 1
	fi
	local root_canon parent parent_canon
	root_canon="$(cd "$AUDIT_ROOT" && pwd -P)"
	parent="$(dirname "$path")"
	while [[ "$parent" != "/" && "$parent" != "." ]]; do
		parent_canon="$(cd "$parent" 2>/dev/null && pwd -P)" || return 1
		case "$parent_canon" in
		"$root_canon" | "$root_canon"/*)
			if [[ -L "$parent" ]]; then
				return 1
			fi
			;;
		esac
		if [[ "$parent_canon" == "$root_canon" ]]; then
			break
		fi
		parent="$(dirname "$parent")"
	done
	return 0
}

canonical_existing_path() {
	local path="$1"
	if [[ ! -e "$path" ]]; then
		return 1
	fi
	assert_no_symlink "$path" || return 1
	local dir base canon root_canon
	dir="$(dirname "$path")"
	base="$(basename "$path")"
	dir="$(cd "$dir" && pwd -P)"
	canon="$dir/$base"
	root_canon="$(cd "$AUDIT_ROOT" && pwd -P)"
	case "$canon" in
	"$root_canon" | "$root_canon"/*) printf '%s\n' "$canon" ;;
	*) return 1 ;;
	esac
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
	local nlines
	if [[ "$before" == *$'\n'* ]]; then
		nlines="$(printf '%s\n' "$before" | grep -c '^' || true)"
	else
		nlines=1
	fi
	actual="$(awk -v start="$line" -v n="$nlines" '
		NR >= start && NR < start + n {
			if (out != "") out = out "\n"
			out = out $0
			found = 1
		}
		END { if (!found) exit 1; print out }
	' "$path")" || return 1
	[[ "$actual" == "$before" ]]
}

range_in_comment_or_docstring() {
	local path="$1"
	local start="$2"
	local nlines="$3"
	awk -v start="$start" -v n="$nlines" '
		function count_pat(s, pat,  c) {
			c = 0
			while (match(s, pat)) {
				c++
				s = substr(s, RSTART + RLENGTH)
			}
			return c
		}
		{
			line_ok = in_doc || ($0 ~ /^[[:space:]]*(#|\/\/)/)
			triple_count = count_pat($0, "\"\"\"") + count_pat($0, "\047\047\047")
			if (triple_count > 0) {
				line_ok = 1
			}
			if (NR >= start && NR < start + n && !line_ok) {
				bad = 1
			}
			if (triple_count % 2 == 1) {
				in_doc = !in_doc
			}
		}
		END { exit bad ? 1 : 0 }
	' "$path"
}

import_symbols() {
	awk '
		function trim(s) {
			sub(/^[[:space:]]+/, "", s)
			sub(/[[:space:]]+$/, "", s)
			return s
		}
		function emit_binding(item,  n, parts, alias_parts, token) {
			item = trim(item)
			if (item == "" || item == "*") return
			if (item ~ /[[:space:]]+as[[:space:]]+/) {
				n = split(item, alias_parts, /[[:space:]]+as[[:space:]]+/)
				token = trim(alias_parts[n])
			} else {
				split(item, parts, /[[:space:]]+/)
				token = parts[1]
				sub(/\..*$/, "", token)
			}
			if (token ~ /^[A-Za-z_][A-Za-z0-9_]*$/) print token
		}
		{
			line = $0
			sub(/[[:space:]]+#.*/, "", line)
			line = trim(line)
			if (line ~ /^import[[:space:]]+/) {
				sub(/^import[[:space:]]+/, "", line)
				count = split(line, items, /,/)
				for (i = 1; i <= count; i++) emit_binding(items[i])
			} else if (line ~ /^from[[:space:]].*[[:space:]]import[[:space:]]+/) {
				sub(/^from[[:space:]].*[[:space:]]import[[:space:]]+/, "", line)
				count = split(line, items, /,/)
				for (i = 1; i <= count; i++) emit_binding(items[i])
			}
		}
	' | sort -u
}

canonical_import_records() {
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

same_import_symbol_set() {
	local before="$1"
	local after="$2"
	local before_records after_records
	before_records="$(printf '%s\n' "$before" | canonical_import_records)" || return 1
	after_records="$(printf '%s\n' "$after" | canonical_import_records)" || return 1
	[[ "$before_records" == "$after_records" ]]
}

unused_import_has_reference() {
	local before="$1"
	local file="$2"
	local line="$3"
	local symbols symbol refs ref_count
	symbols="$(printf '%s\n' "$before" | import_symbols)"
	[[ -n "$symbols" ]] || return 0
	while IFS= read -r symbol; do
		[[ -n "$symbol" ]] || continue
		refs="$(git -C "$AUDIT_ROOT" grep -nIw -- "$symbol" 2>/dev/null || true)"
		ref_count="$(printf '%s\n' "$refs" |
			awk -v prefix="$file:$line:" '
				NF {
					if (index($0, prefix) == 1) next
					content = $0
					sub(/^[^:]*:[0-9]+:/, "", content)
					if (content ~ /^[[:space:]]*(#|\/\/)/) next
					print
				}
			' |
			grep -c '^' || true)"
		if [[ "$ref_count" -gt 0 ]]; then
			return 0
		fi
	done <<<"$symbols"
	return 1
}

unused_var_has_reference() {
	local before="$1"
	local file="$2"
	local line="$3"
	local stripped_line var_name refs ref_count
	before="${before%$'\n'}"
	stripped_line="$(printf '%s' "$before" | sed -e 's/^[[:space:]]*//')"
	var_name=""
	if [[ "$stripped_line" =~ ^(let|const|var|my)[[:space:]]+([A-Za-z_][A-Za-z0-9_]*) ]]; then
		var_name="${BASH_REMATCH[2]}"
	elif [[ "$stripped_line" =~ ^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*[:=] ]]; then
		var_name="${BASH_REMATCH[1]}"
	fi
	[[ -n "$var_name" ]] || return 0
	refs="$(git -C "$AUDIT_ROOT" grep -nIw -- "$var_name" 2>/dev/null || true)"
	ref_count="$(printf '%s\n' "$refs" |
		awk -v prefix="$file:$line:" 'NF { if (index($0, prefix) == 1) next; print }' |
		grep -c '^' || true)"
	[[ "$ref_count" -gt 0 ]]
}

scope_parts() {
	local scope="$1"
	SCOPE_PATH=""
	SCOPE_START=""
	SCOPE_END=""
	# Anchored regex form, mirroring parse_plan_scope in apply-auto-fix-plan.sh
	# so the auditor and applier classify malformed scopes identically. The
	# previous ${scope%:*} / ${scope##*:} pair misclassified a missing-line
	# scope ('a:b.md') as path='a' / range='b.md' rather than as malformed.
	if [[ "$scope" =~ ^(.+):([0-9]+)-([0-9]+)$ ]]; then
		SCOPE_PATH="${BASH_REMATCH[1]}"
		SCOPE_START="${BASH_REMATCH[2]}"
		SCOPE_END="${BASH_REMATCH[3]}"
	elif [[ "$scope" =~ ^(.+):([0-9]+)$ ]]; then
		SCOPE_PATH="${BASH_REMATCH[1]}"
		SCOPE_START="${BASH_REMATCH[2]}"
		SCOPE_END="${BASH_REMATCH[2]}"
	fi
}

# Resolve the enclosing heading stack at <line> via the shared resolver, then
# test every ancestor against the same forbidden-heading list the applier uses.
# Keeping the auditor and applier on one resolver avoids a class of bug where
# `would_apply` from the auditor disagrees with `rejected_scope` at apply.
review_plan_scope_forbidden() {
	local path="$1"
	local line="$2"
	local heading
	local stack_out stack_rc
	stack_out="$("$PLAN_SCOPE_DETECT" --stack "$path" "$line" 2>&1)"
	stack_rc=$?
	if [[ "$stack_rc" -ne 0 ]]; then
		return 2
	fi
	while IFS= read -r heading; do
		[[ -n "$heading" ]] || continue
		# Phase headings: any digit count.
		if [[ "$heading" =~ ^###[[:space:]]+Phase[[:space:]]+[0-9]+: ]]; then
			return 0
		fi
		case "$heading" in
		"## Requirements" | "## Acceptance Criteria" | \
			"### Files to Modify" | "### New Files to Create" | \
			"### Architecture Decisions" | "### Integration Seams")
			return 0
			;;
		esac
	done <<<"$stack_out"
	return 1
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
			after="$(printf '%s' "$finding" | jq -r '.auto_fix.after')"
			scope="$(printf '%s' "$finding" | jq -r '.auto_fix.scope')"
			if ! jq -e --arg skill "$SKILL" --arg kind "$kind" '.[$skill] | index($kind)' "$ALLOWLIST_PATH" >/dev/null; then
				status="rejected_kind"
			elif [[ "$SKILL" == "deep-review" ]]; then
				file="$(printf '%s' "$finding" | jq -r '.file // ""')"
				line="$(printf '%s' "$finding" | jq -r '(.line // "") | tostring')"
				path="$(resolve_path "$file")"
				if ! line_matches_before "$path" "$line" "$before"; then
					rc=$?
					if [[ "$rc" -eq 2 ]]; then
						status="unsupported"
					else
						status="drift"
					fi
				else
					stripped_before="${before%$'\n'}"
					if [[ "$stripped_before" == *$'\n'* ]]; then
						nlines="$(printf '%s\n' "$stripped_before" | grep -c '^' || true)"
					else
						nlines=1
					fi
					case "$kind" in
					mechanical_replace)
						if [[ "$stripped_before" == *$'\n'* ]]; then
							status="rejected_multiline"
						else
							status="would_apply"
						fi
						;;
					docstring_typo)
						if range_in_comment_or_docstring "$path" "$line" "$nlines"; then
							status="would_apply"
						else
							status="rejected_kind_scope"
						fi
						;;
					import_sort)
						if same_import_symbol_set "$stripped_before" "${after%$'\n'}"; then
							status="would_apply"
						else
							status="rejected_semantic_change"
						fi
						;;
					unused_import)
						if unused_import_has_reference "$stripped_before" "$file" "$line"; then
							status="rejected_revar"
						else
							status="would_apply"
						fi
						;;
					unused_var)
						if unused_var_has_reference "$stripped_before" "$file" "$line"; then
							status="rejected_revar"
						else
							status="would_apply"
						fi
						;;
					*)
						status="would_apply"
						;;
					esac
				fi
			else
				scope_parts "$scope"
				if [[ ! "$SCOPE_START" =~ ^[0-9]+$ || ! "$SCOPE_END" =~ ^[0-9]+$ ]]; then
					status="malformed"
				elif [[ "$SCOPE_START" != "$SCOPE_END" ]]; then
					status="unsupported"
				else
					if ! path="$(resolve_repo_path "$SCOPE_PATH")"; then
						status="rejected_path"
					elif ! finding_path="$(resolve_repo_path "$(printf '%s' "$finding" | jq -r '.file // ""')")"; then
						status="rejected_path"
					elif [[ -n "$PLAN_PATH" ]]; then
						plan_path="$(resolve_path "$PLAN_PATH")"
						if ! path_canon="$(canonical_existing_path "$path")" ||
							! finding_canon="$(canonical_existing_path "$finding_path")" ||
							! plan_canon="$(canonical_existing_path "$plan_path")"; then
							status="rejected_path"
						elif [[ "$path_canon" != "$finding_canon" || "$finding_canon" != "$plan_canon" ]]; then
							status="rejected_path"
						fi
					elif ! path_canon="$(canonical_existing_path "$path")" ||
						! finding_canon="$(canonical_existing_path "$finding_path")"; then
						status="rejected_path"
					elif [[ "$path_canon" != "$finding_canon" ]]; then
						status="rejected_path"
					fi
					if [[ -n "$status" ]]; then
						:
					elif [[ ! -f "$path" ]]; then
						status="drift"
					elif ! iconv -f utf-8 -t utf-8 <"$path" >/dev/null 2>&1; then
						# Catch malformed-UTF-8 plans pre-apply so the
						# applier doesn't reach marker_failed and trigger
						# a batch rollback for an issue the auditor could
						# have surfaced.
						status="unsupported"
					else
						scope_status=0
						review_plan_scope_forbidden "$path" "$SCOPE_START" || scope_status=$?
						if [[ "$scope_status" -eq 0 ]]; then
							status="rejected_scope"
						elif [[ "$scope_status" -eq 2 ]]; then
							status="unsupported"
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
