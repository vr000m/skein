#!/usr/bin/env bash
# render-reconciled-report.sh
#
# Reference renderer for the JSON envelope produced by
# scripts/reconcile-findings.sh. Emits the canonical markdown body
# fragment that the deep-review and review-plan SKILL.md report
# templates describe (the `**Reconciliation**:` line plus per-severity
# finding sections, in canonical order). Header lines (`## Deep Review:
# ...`, `**Overall**: ...`) and trailer lines (`**Next steps**: ...`)
# are skill-specific and NOT emitted here.
#
# Stdin:  JSON envelope on stdin (output of scripts/reconcile-findings.sh).
# Stdout: markdown body fragment.
#
# Contract verified by tests/reconciliation/test-renderer.sh against
# tests/reconciliation/expected/<name>.rendered.md golden files.
#
# The renderer is structural and deterministic: identical input -> byte
# identical output. The orchestrator LLM may use this output verbatim,
# or enrich the per-finding prose, but all fields (Lenses, Evidence,
# Suggestion, Related findings) and the Reconciliation summary line MUST
# be preserved.
#
# `dropped=D` is appended to the Reconciliation line only when D > 0, so
# the common (clean-input) case stays terse.
#
# Dependencies: bash + awk. Uses `jq` when available for safer JSON
# parsing; otherwise the same hand-written parser as
# reconcile-findings.sh.

set -euo pipefail

HAVE_JQ=0
if command -v jq >/dev/null 2>&1; then
	HAVE_JQ=1
fi

input="$(cat)"

# Schema version this renderer understands. MUST match the
# `schema_version` field emitted by scripts/reconcile-findings.sh. Bump
# in lockstep when the envelope shape changes.
EXPECTED_SCHEMA_VERSION=2

# Extract the schema_version with a portable awk match (avoids requiring
# jq for the assertion itself). Missing field is treated as absent and
# rejected so legacy/unversioned envelopes fail loudly rather than
# silently misparse. The regex tolerates pretty-printed multi-line
# envelopes and single-line ones alike.
actual_schema_version="$(printf '%s' "$input" | awk '
	BEGIN { found = "" }
	{
		if (match($0, /"schema_version"[[:space:]]*:[[:space:]]*-?[0-9]+/)) {
			s = substr($0, RSTART, RLENGTH)
			sub(/.*:[[:space:]]*/, "", s)
			found = s
			exit
		}
	}
	END { print found }
')"
if [[ -z "$actual_schema_version" ]]; then
	echo "render-reconciled-report: input envelope missing schema_version (expected $EXPECTED_SCHEMA_VERSION)" >&2
	exit 2
fi
if [[ "$actual_schema_version" != "$EXPECTED_SCHEMA_VERSION" ]]; then
	echo "render-reconciled-report: schema_version mismatch (got $actual_schema_version, expected $EXPECTED_SCHEMA_VERSION)" >&2
	exit 2
fi

if [[ "$HAVE_JQ" -eq 1 ]]; then
	# Pull the summary block as five integers, tab-separated.
	read -r raw merged unique related dropped < <(printf '%s' "$input" | jq -r '
		.summary | [.raw, .merged, .unique, .related, .dropped] | @tsv
	')

	# Findings as a TSV stream, one row per finding. Columns:
	#   severity  category  file  line  lenses(comma-joined)  summary  evidence  suggestion
	# Tabs/newlines inside string fields escaped to keep awk field-splitting safe.
	findings_tsv="$(printf '%s' "$input" | jq -r '
		.findings[]? | [
			.severity, .category, .file,
			((if (.line == null or .line == "") then -1 else .line end) | tostring),
			(.lenses | join(",")),
			.summary, .evidence, .suggestion
		] | map(gsub("\t"; "\\\\t") | gsub("\n"; "\\\\n")) | join("\t")
	')"

	# Related cross-references. Columns: file  line  cat_a  cat_b
	related_tsv="$(printf '%s' "$input" | jq -r '
		.related[]? | [
			.file,
			((if (.line == null or .line == "") then -1 else .line end) | tostring),
			.categories[0], .categories[1]
		] | map(gsub("\t"; "\\\\t") | gsub("\n"; "\\\\n")) | join("\t")
	')"
else
	# Fallback: minimal awk JSON walker. Sufficient for the well-formed
	# envelope produced by reconcile-findings.sh; not a general parser.
	parsed="$(printf '%s' "$input" | awk '
		function unesc(s,    out, i, n, c, nx) {
			out = ""; n = length(s)
			for (i = 1; i <= n; i++) {
				c = substr(s, i, 1)
				if (c == "\\" && i < n) {
					nx = substr(s, i + 1, 1)
					if (nx == "\"") { out = out "\""; i++ }
					else if (nx == "\\") { out = out "\\"; i++ }
					else if (nx == "n") { out = out "\n"; i++ }
					else if (nx == "t") { out = out "\t"; i++ }
					else if (nx == "r") { out = out "\r"; i++ }
					else if (nx == "/") { out = out "/"; i++ }
					else { out = out c }
				} else {
					out = out c
				}
			}
			return out
		}
		function esc(s) { gsub(/\t/, "\\t", s); gsub(/\n/, "\\n", s); return s }
		function read_string(buf, start,    i, n, c, raw) {
			n = length(buf); raw = ""
			for (i = start; i <= n; i++) {
				c = substr(buf, i, 1)
				if (c == "\\" && i < n) { raw = raw substr(buf, i, 2); i++; continue }
				if (c == "\"") { return raw }
				raw = raw c
			}
			return raw
		}
		function read_number(buf, start,    s) {
			s = substr(buf, start)
			if (match(s, /^-?[0-9]+/)) return substr(s, RSTART, RLENGTH)
			return ""
		}
		# Slurp full input.
		{ all = (all == "" ? $0 : all "\n" $0) }
		END {
			# --- summary block ---
			# Single source of truth for summary keys. Adding a new key here
			# (and to the matching jq filter above) is the only edit needed
			# to extend the envelope; ordering is determined by this list,
			# not by hard-coded indexes downstream.
			n_keys = split("raw merged unique related dropped", key_list, " ")
			if (match(all, /"summary"[[:space:]]*:[[:space:]]*\{[^}]*\}/)) {
				sb = substr(all, RSTART, RLENGTH)
				for (k_i = 1; k_i <= n_keys; k_i++) {
					key = key_list[k_i]
					if (match(sb, "\"" key "\"[[:space:]]*:[[:space:]]*-?[0-9]+")) {
						val = substr(sb, RSTART, RLENGTH)
						sub(/.*:[[:space:]]*/, "", val)
						sums[key] = val
					} else {
						sums[key] = "0"
					}
				}
			} else {
				for (k_i = 1; k_i <= n_keys; k_i++) sums[key_list[k_i]] = "0"
			}
			printf "SUMMARY"
			for (k_i = 1; k_i <= n_keys; k_i++) printf "\t%s", sums[key_list[k_i]]
			printf "\n"

			# --- findings array ---
			if (match(all, /"findings"[[:space:]]*:[[:space:]]*\[/)) {
				start = RSTART + RLENGTH
				depth = 1; i = start; n = length(all); buf = ""
				in_str = 0
				while (i <= n && depth > 0) {
					c = substr(all, i, 1)
					if (in_str) {
						if (c == "\\" && i < n) { buf = buf substr(all, i, 2); i += 2; continue }
						if (c == "\"") in_str = 0
						buf = buf c
					} else if (c == "\"") {
						in_str = 1; buf = buf c
					} else if (c == "[") {
						depth++; buf = buf c
					} else if (c == "]") {
						depth--; if (depth == 0) break; buf = buf c
					} else {
						buf = buf c
					}
					i++
				}
				farr = buf
				# Split into objects at top level.
				obj_n = 0; depth = 0; cur = ""; in_str = 0
				for (i = 1; i <= length(farr); i++) {
					c = substr(farr, i, 1)
					if (in_str) {
						if (c == "\\" && i < length(farr)) { cur = cur substr(farr, i, 2); i++; continue }
						if (c == "\"") in_str = 0
						cur = cur c
					} else if (c == "\"") {
						in_str = 1; cur = cur c
					} else if (c == "{") {
						depth++; cur = cur c
					} else if (c == "}") {
						depth--; cur = cur c
						if (depth == 0) { obj_n++; objs[obj_n] = cur; cur = "" }
					} else if (depth > 0) {
						cur = cur c
					}
				}
				for (j = 1; j <= obj_n; j++) {
					o = objs[j]
					sev = jstr(o, "severity"); cat = jstr(o, "category")
					file = jstr(o, "file"); line = jnum(o, "line")
					if (line == "") line = "-1"
					summary = jstr(o, "summary"); evidence = jstr(o, "evidence"); suggestion = jstr(o, "suggestion")
					lenses = jarr_strings(o, "lenses")
					printf "FINDING\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", esc(sev), esc(cat), esc(file), line, esc(lenses), esc(summary), esc(evidence), esc(suggestion)
				}
			}

			# --- related array ---
			if (match(all, /"related"[[:space:]]*:[[:space:]]*\[/)) {
				start = RSTART + RLENGTH
				depth = 1; i = start; n = length(all); buf = ""; in_str = 0
				while (i <= n && depth > 0) {
					c = substr(all, i, 1)
					if (in_str) {
						if (c == "\\" && i < n) { buf = buf substr(all, i, 2); i += 2; continue }
						if (c == "\"") in_str = 0
						buf = buf c
					} else if (c == "\"") {
						in_str = 1; buf = buf c
					} else if (c == "[") {
						depth++; buf = buf c
					} else if (c == "]") {
						depth--; if (depth == 0) break; buf = buf c
					} else {
						buf = buf c
					}
					i++
				}
				rarr = buf
				obj_n = 0; depth = 0; cur = ""; in_str = 0
				for (i = 1; i <= length(rarr); i++) {
					c = substr(rarr, i, 1)
					if (in_str) {
						if (c == "\\" && i < length(rarr)) { cur = cur substr(rarr, i, 2); i++; continue }
						if (c == "\"") in_str = 0
						cur = cur c
					} else if (c == "\"") {
						in_str = 1; cur = cur c
					} else if (c == "{") {
						depth++; cur = cur c
					} else if (c == "}") {
						depth--; cur = cur c
						if (depth == 0) { obj_n++; robjs[obj_n] = cur; cur = "" }
					} else if (depth > 0) {
						cur = cur c
					}
				}
				for (j = 1; j <= obj_n; j++) {
					o = robjs[j]
					file = jstr(o, "file"); line = jnum(o, "line")
					if (line == "") line = "-1"
					cats = jarr_strings(o, "categories")
					split(cats, ca, ",")
					printf "RELATED\t%s\t%s\t%s\t%s\n", esc(file), line, esc(ca[1]), esc(ca[2])
				}
			}
		}
		# --- helpers used in END ---
		function jstr(obj, key,    re, pos) {
			re = "\"" key "\"[[:space:]]*:[[:space:]]*\""
			if (match(obj, re)) {
				pos = RSTART + RLENGTH
				return unesc(read_string(obj, pos))
			}
			return ""
		}
		function jnum(obj, key,    re, pos) {
			re = "\"" key "\"[[:space:]]*:[[:space:]]*"
			if (match(obj, re)) {
				pos = RSTART + RLENGTH
				return read_number(obj, pos)
			}
			return ""
		}
		function jarr_strings(obj, key,    re, pos, depth, i, n, c, buf, in_str, items, out, k, item) {
			re = "\"" key "\"[[:space:]]*:[[:space:]]*\\["
			if (!match(obj, re)) return ""
			pos = RSTART + RLENGTH
			depth = 1; n = length(obj); buf = ""; in_str = 0
			for (i = pos; i <= n && depth > 0; i++) {
				c = substr(obj, i, 1)
				if (in_str) {
					if (c == "\\" && i < n) { buf = buf substr(obj, i, 2); i++; continue }
					if (c == "\"") in_str = 0
					buf = buf c
				} else if (c == "\"") {
					in_str = 1; buf = buf c
				} else if (c == "[") {
					depth++; buf = buf c
				} else if (c == "]") {
					depth--; if (depth == 0) break; buf = buf c
				} else {
					buf = buf c
				}
			}
			# Extract quoted strings from buf in order.
			out = ""; in_str = 0; item = ""; k = 0
			for (i = 1; i <= length(buf); i++) {
				c = substr(buf, i, 1)
				if (in_str) {
					if (c == "\\" && i < length(buf)) { item = item substr(buf, i, 2); i++; continue }
					if (c == "\"") {
						in_str = 0
						k++; items[k] = unesc(item); item = ""
					} else {
						item = item c
					}
				} else if (c == "\"") {
					in_str = 1
				}
			}
			for (i = 1; i <= k; i++) {
				if (i > 1) out = out ","
				out = out items[i]
			}
			return out
		}
	')"

	read -r _ raw merged unique related dropped < <(printf '%s\n' "$parsed" | awk -F '\t' '$1 == "SUMMARY" { print; exit }')
	findings_tsv="$(printf '%s\n' "$parsed" | awk -F '\t' '$1 == "FINDING" { sub(/^FINDING\t/, ""); print }')"
	related_tsv="$(printf '%s\n' "$parsed" | awk -F '\t' '$1 == "RELATED" { sub(/^RELATED\t/, ""); print }')"
fi

# --- Emit body ---

if [[ "${dropped:-0}" -gt 0 ]]; then
	printf '**Reconciliation**: raw=%s merged=%s unique=%s related=%s dropped=%s\n' \
		"$raw" "$merged" "$unique" "$related" "$dropped"
else
	printf '**Reconciliation**: raw=%s merged=%s unique=%s related=%s\n' \
		"$raw" "$merged" "$unique" "$related"
fi

if [[ -z "$findings_tsv" ]]; then
	exit 0
fi

# Persist findings to a file so awk subprocesses can ingest a multi-line
# table without bumping into BSD awk's `-v` newline restriction.
findings_file="$(mktemp)"
related_file="$(mktemp)"
trap 'rm -f "$findings_file" "$related_file"' EXIT
printf '%s\n' "$findings_tsv" >"$findings_file"
printf '%s\n' "$related_tsv" >"$related_file"

# Render finding sections in canonical order: Critical, Important, Minor,
# then any other severities (e.g. unknown) sorted alphabetically.
emit_section() {
	local sev="$1"
	local rows
	rows="$(awk -F '\t' -v sev="$sev" '$1 == sev' "$findings_file")"
	if [[ -z "$rows" ]]; then
		return 0
	fi
	printf '\n### %s\n' "$sev"
	while IFS=$'\t' read -r _r_sev r_cat r_file r_line r_lenses r_summary r_evidence r_suggestion; do
		# Decode \t / \n that the parser escaped so multi-line evidence
		# round-trips into rendered output.
		decode() { printf '%s' "$1" | sed -e 's/\\t/	/g' -e 's/\\n/\
/g'; }
		d_summary="$(decode "$r_summary")"
		d_evidence="$(decode "$r_evidence")"
		d_suggestion="$(decode "$r_suggestion")"
		d_lenses="$(printf '%s' "$r_lenses" | awk -F ',' '{
			out = ""
			for (i = 1; i <= NF; i++) {
				if (i > 1) out = out ", "
				out = out $i
			}
			print out
		}')"
		printf -- '- **%s**: %s at %s:%s\n' "$r_cat" "$d_summary" "$r_file" "$r_line"
		printf -- '  - Lenses: [%s]\n' "$d_lenses"
		printf -- '  - Evidence: %s\n' "$d_evidence"
		printf -- '  - Suggestion: %s\n' "$d_suggestion"
		# Related findings: any cross-reference that touches this finding's
		# (file, line) where one of the two categories is r_cat. The other
		# category's severity is looked up against the findings table.
		if [[ -s "$related_file" ]]; then
			awk -F '\t' \
				-v rfile="$r_file" -v rline="$r_line" -v rcat="$r_cat" \
				-v ffile="$findings_file" '
				BEGIN {
					while ((getline ln < ffile) > 0) {
						if (ln == "") continue
						split(ln, f, "\t")
						sev_of[f[2] SUBSEP f[3] SUBSEP f[4]] = f[1]
					}
					close(ffile)
				}
				$1 == rfile && $2 == rline {
					other = ""
					if ($3 == rcat) other = $4
					else if ($4 == rcat) other = $3
					else next
					sev = sev_of[other SUBSEP rfile SUBSEP rline]
					if (sev == "") sev = "Unknown"
					printf "  - Related findings: **%s** %s at same file:line\n", other, sev
				}
			' "$related_file"
		fi
	done <<<"$rows"
}

emit_section "Critical"
emit_section "Important"
emit_section "Minor"

# Any non-canonical severities -> render under their own header(s),
# alphabetically. Surfaces parser bugs or future severity tiers loudly.
other_sevs="$(printf '%s\n' "$findings_tsv" | awk -F '\t' '
	$1 != "Critical" && $1 != "Important" && $1 != "Minor" && $1 != "" { print $1 }
' | sort -u)"
if [[ -n "$other_sevs" ]]; then
	while IFS= read -r sev; do
		[[ -z "$sev" ]] && continue
		emit_section "$sev"
	done <<<"$other_sevs"
fi
