#!/usr/bin/env bash
# reconcile-findings.sh
#
# Single source of truth for cross-lens finding reconciliation used by
# the `deep-review` and `review-plan` skills.
#
# Stdin:  JSON-Lines findings, one object per line, each with the fields
#         {lens, severity, category, file, line, summary, evidence, suggestion}.
#         Blank lines and lines that are not valid JSON objects are ignored.
#
# Stdout: Canonical JSON of the form:
#   {
#     "summary": {"raw": N, "merged": M, "unique": U, "related": R, "dropped": D},
#     "findings": [ ... reconciled findings, sorted ... ],
#     "related":  [ ... cross-references ... ]
#   }
#
# Sentinel: missing or empty `line` is normalised to -1 in the parse step
# so that absent line numbers sort distinctly from real line 0.
#
# Merge rule:
#   - Group findings by the structural signature (file, line, category).
#   - Findings sharing a signature merge into one. The merged finding's
#     `lenses` is the sorted-unique union of the source lenses; its
#     `severity` is the highest of the group (Critical > Important > Minor);
#     its `summary`/`evidence`/`suggestion` are taken from the
#     highest-severity source (ties broken by alphabetical lens name).
#   - Findings that share (file, line) but differ in category do NOT
#     merge. They emit a `related` cross-reference instead, listing both
#     signatures so the report template can render a "Related findings"
#     callout under each.
#
# Sort order (canonical):
#   severity (Critical, Important, Minor) -> category -> file -> line
#   -> sorted lenses (joined with comma).
#
# Empty input -> emits {"summary":{"raw":0,...},"findings":[],"related":[]}.
#
# Dependencies: bash + awk + sort. `jq`, when present, is used for safer
# JSON parsing; otherwise a careful awk fallback is used. No new install
# requirements are introduced.

set -euo pipefail

HAVE_JQ=0
if command -v jq >/dev/null 2>&1; then
	HAVE_JQ=1
fi

# Read all stdin.
input="$(cat)"

# Severity rank: lower number = higher severity.
sev_rank() {
	case "$1" in
		Critical) echo 0 ;;
		Important) echo 1 ;;
		Minor) echo 2 ;;
		*) echo 3 ;;
	esac
}

# Emit a canonical empty report.
emit_empty() {
	local dropped="${1:-0}"
	cat <<EOF
{
  "summary": {
    "raw": 0,
    "merged": 0,
    "unique": 0,
    "related": 0,
    "dropped": ${dropped}
  },
  "findings": [],
  "related": []
}
EOF
}

if [[ -z "${input// }" ]]; then
	emit_empty 0
	exit 0
fi

# Parse stdin into a TSV stream we can group/sort with awk + sort.
# Columns (tab-separated):
#   sev_rank  severity  category  file  line  lens  summary  evidence  suggestion
# Tabs / newlines inside string fields are escaped as \t / \n so awk's
# field splitting stays correct.

parse_tsv() {
	if [[ "$HAVE_JQ" -eq 1 ]]; then
		# jq path: robust, handles arbitrary JSON. Skip lines that are
		# not JSON objects. Missing/empty `line` -> -1 sentinel so absent
		# values sort distinctly from real line 0.
		printf '%s\n' "$input" | jq -rR '
			. as $line |
			try (fromjson | select(type == "object")) catch empty |
			[
				((if (.severity // "") == "Critical" then 0
				  elif (.severity // "") == "Important" then 1
				  elif (.severity // "") == "Minor" then 2
				  else 3 end) | tostring),
				(.severity // "" | tostring),
				(.category // "" | tostring),
				(.file // "" | tostring),
				((if (.line == null or .line == "") then -1 else .line end) | tostring),
				(.lens // "" | tostring),
				(.summary // "" | tostring),
				(.evidence // "" | tostring),
				(.suggestion // "" | tostring)
			]
			| map(gsub("\t"; "\\t") | gsub("\n"; "\\n"))
			| @tsv
		'
	else
		# awk fallback: minimal parser for flat JSON objects of the
		# expected shape. Handles \", \\, \n, \t escape sequences inside
		# string fields. Missing/empty `line` -> -1 sentinel.
		printf '%s\n' "$input" | awk '
			function unesc(s,    out, i, n, c, nx) {
				# Decode JSON string escapes: \" \\ \n \t \/ \r \b \f.
				out = ""
				n = length(s)
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
						else if (nx == "b") { out = out "\b"; i++ }
						else if (nx == "f") { out = out "\f"; i++ }
						else { out = out c }
					} else {
						out = out c
					}
				}
				return out
			}
			function find_key(json, key,    re, pos) {
				re = "\"" key "\"[[:space:]]*:[[:space:]]*"
				if (match(json, re)) {
					return RSTART + RLENGTH
				}
				return 0
			}
			function read_string(json, start,    i, n, c, esc_n, raw) {
				# Caller has already advanced past the opening ".
				# Walk forward, honouring \\ and \" so the string ends
				# at the FIRST unescaped ".
				n = length(json)
				raw = ""
				for (i = start; i <= n; i++) {
					c = substr(json, i, 1)
					if (c == "\\") {
						# copy the escape pair verbatim; unesc() handles it.
						if (i + 1 <= n) {
							raw = raw substr(json, i, 2)
							i++
							continue
						} else {
							raw = raw c
							continue
						}
					}
					if (c == "\"") {
						return raw
					}
					raw = raw c
				}
				return raw
			}
			function field(json, key,    pos, c, num) {
				pos = find_key(json, key)
				if (pos == 0) return ""
				c = substr(json, pos, 1)
				if (c == "\"") {
					return unesc(read_string(json, pos + 1))
				}
				# numeric or other bare token
				if (match(substr(json, pos), /^-?[0-9]+/)) {
					num = substr(substr(json, pos), RSTART, RLENGTH)
					return num
				}
				return ""
			}
			function esc(s) { gsub(/\t/, "\\t", s); gsub(/\n/, "\\n", s); return s }
			/^[[:space:]]*$/ { next }
			!/^[[:space:]]*\{/ { dropped++; next }
			{
				lens = field($0, "lens")
				severity = field($0, "severity")
				category = field($0, "category")
				file = field($0, "file")
				line = field($0, "line")
				if (line == "") line = "-1"
				summary = field($0, "summary")
				evidence = field($0, "evidence")
				suggestion = field($0, "suggestion")
				if (severity == "Critical") rank = 0
				else if (severity == "Important") rank = 1
				else if (severity == "Minor") rank = 2
				else rank = 3
				printf "%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", rank, esc(severity), esc(category), esc(file), line, esc(lens), esc(summary), esc(evidence), esc(suggestion)
			}
		'
	fi
}

# Count input lines (non-blank) for dropped detection.
input_nonblank=$(printf '%s\n' "$input" | awk 'NF { c++ } END { print c+0 }')

tsv="$(parse_tsv)"

# Count raw input.
raw=0
if [[ -n "$tsv" ]]; then
	raw=$(printf '%s\n' "$tsv" | grep -c '^' || true)
fi

# A line is "dropped" if it contained non-whitespace but didn't parse into a
# row. We compare the count of non-blank input lines against successfully
# parsed rows.
dropped=$(( input_nonblank - raw ))
if [[ "$dropped" -lt 0 ]]; then
	dropped=0
fi
if [[ "$dropped" -gt 0 ]]; then
	echo "warning: $dropped input line(s) failed to parse and were dropped" >&2
fi

if [[ "$raw" -eq 0 ]]; then
	emit_empty "$dropped"
	exit 0
fi

# Group by signature (category, file, line), then merge.
# Sort key for the merge phase: category, file, line, sev_rank, lens.
sorted="$(printf '%s\n' "$tsv" | sort -t $'\t' -k3,3 -k4,4 -k5,5n -k1,1n -k6,6)"

# Build merged groups in a temp file: one merged record per signature.
# Merged record fields:
#   sev_rank severity category file line lenses(comma-joined sorted)
#   summary evidence suggestion
merged_tsv="$(printf '%s\n' "$sorted" | awk -F '\t' '
	function flush(    i, j, n, tmp, sorted_lens, joined, prev) {
		if (count == 0) return
		# Bubble-sort lenses (small N).
		n = count
		for (i = 1; i <= n; i++) sorted_lens[i] = lens_arr[i]
		for (i = 1; i <= n; i++) {
			for (j = i + 1; j <= n; j++) {
				if (sorted_lens[j] < sorted_lens[i]) {
					tmp = sorted_lens[i]; sorted_lens[i] = sorted_lens[j]; sorted_lens[j] = tmp
				}
			}
		}
		joined = ""
		prev = ""
		for (i = 1; i <= n; i++) {
			if (sorted_lens[i] == "") continue
			if (sorted_lens[i] == prev) continue
			if (joined != "") joined = joined ","
			joined = joined sorted_lens[i]
			prev = sorted_lens[i]
		}
		printf "%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", best_rank, best_sev, cur_cat, cur_file, cur_line, joined, best_summary, best_evidence, best_suggestion
		count = 0
		for (i in lens_arr) delete lens_arr[i]
		for (i in sorted_lens) delete sorted_lens[i]
	}
	BEGIN { count = 0 }
	{
		sig = $3 SUBSEP $4 SUBSEP $5
		if (sig != cur_sig) {
			flush()
			cur_sig = sig
			cur_cat = $3; cur_file = $4; cur_line = $5
			best_rank = $1; best_sev = $2
			best_summary = $7; best_evidence = $8; best_suggestion = $9
			best_lens = $6
		} else {
			# Highest severity wins (lowest rank). Tie-break on lens name
			# (alpha desc) so the chosen representative text is stable
			# under shuffled lens-arrival order.
			if ($1 < best_rank || ($1 == best_rank && $6 > best_lens)) {
				best_rank = $1; best_sev = $2
				best_summary = $7; best_evidence = $8; best_suggestion = $9
				best_lens = $6
			}
		}
		count++
		lens_arr[count] = $6
	}
	END { flush() }
')"

# Determine related cross-references: same (file, line) across two or
# more distinct merged signatures (different categories).
# Read merged_tsv into arrays and find groups with >=2 categories per
# (file, line).
related_tsv="$(printf '%s\n' "$merged_tsv" | awk -F '\t' '
	{
		key = $4 SUBSEP $5
		count[key]++
		# Append a record id (line number in merged stream) per key.
		ids[key] = (ids[key] == "" ? NR : ids[key] "," NR)
		cat[NR] = $3
		file[NR] = $4
		line[NR] = $5
	}
	END {
		for (k in count) {
			if (count[k] < 2) continue
			n = split(ids[k], a, ",")
			# Emit, for each (i,j) ordered pair i<j by category,file,line,
			# a cross-reference record.
			for (i = 1; i <= n; i++) {
				for (j = 1; j <= n; j++) {
					if (i == j) continue
					ai = a[i]; aj = a[j]
					# emit one direction; canonical sort applied later.
					printf "%s\t%s\t%s\t%s\t%s\t%s\n", file[ai], line[ai], cat[ai], cat[aj], file[aj], line[aj]
				}
			}
		}
	}
' | sort -u)"

# Final canonical sort of merged findings:
#   sev_rank -> category -> file -> line -> lenses
final_tsv="$(printf '%s\n' "$merged_tsv" | sort -t $'\t' -k1,1n -k3,3 -k4,4 -k5,5n -k6,6)"

merged_count=0
unique_count=0
if [[ -n "$final_tsv" ]]; then
	merged_count=$(printf '%s\n' "$final_tsv" | grep -c '^' || true)
fi

# A "merged" record (in the summary sense) is one that combined findings
# from >=2 distinct lenses (cross-lens dedup). Single-lens duplicates do
# NOT count as merged — those represent a single source emitting the same
# finding twice, not cross-lens reconciliation.
combined_groups=$(printf '%s\n' "$sorted" | awk -F '\t' '
	{
		sig = $3 SUBSEP $4 SUBSEP $5
		# Track distinct lenses per signature.
		key = sig SUBSEP $6
		if (!(key in seen)) {
			seen[key] = 1
			distinct[sig]++
		}
	}
	END {
		merged = 0
		for (s in distinct) if (distinct[s] > 1) merged++
		print merged
	}
')

unique_count="$merged_count"
related_count=0
if [[ -n "$related_tsv" ]]; then
	# Each pair contributes one cross-reference record; count deduped
	# unordered pairs as half (we emitted both directions).
	dir_count=$(printf '%s\n' "$related_tsv" | grep -c '^' || true)
	related_count=$(( dir_count / 2 ))
fi

# Emit JSON. Use jq if present for robust string escaping; otherwise
# build by hand with manual escape.
json_escape() {
	# stdin -> JSON-string-safe (no surrounding quotes)
	awk 'BEGIN { ORS = "" }
		{
			s = $0
			gsub(/\\/, "\\\\", s)
			gsub(/"/, "\\\"", s)
			gsub(/\t/, "\\t", s)
			print s
			# preserve no newline; consumed line-by-line anyway
		}' <<<"$1"
}

emit_findings_pretty() {
	# Pretty-printed findings array body. Returns "[]" if empty,
	# otherwise a multi-line array beginning with "[\n" and ending with
	# "  ]" (caller adds trailing comma/newline).
	if [[ -z "$final_tsv" ]]; then
		printf '[]'
		return
	fi
	printf '%s\n' "$final_tsv" | awk -F '\t' '
		function jesc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
		BEGIN { first = 1; printf "[\n" }
		{
			if (!first) printf ",\n"
			first = 0
			n = split($6, lenses_arr, ",")
			lenses_json = "["
			for (i = 1; i <= n; i++) {
				if (i > 1) lenses_json = lenses_json ", "
				lenses_json = lenses_json "\"" jesc(lenses_arr[i]) "\""
			}
			lenses_json = lenses_json "]"
			sev = jesc($2); cat = jesc($3); file = jesc($4); line = $5
			summary = jesc($7); evidence = jesc($8); suggestion = jesc($9)
			line_field = (line ~ /^-?[0-9]+$/) ? line : ("\"" jesc(line) "\"")
			printf "    {\n"
			printf "      \"severity\": \"%s\",\n", sev
			printf "      \"category\": \"%s\",\n", cat
			printf "      \"file\": \"%s\",\n", file
			printf "      \"line\": %s,\n", line_field
			printf "      \"lenses\": %s,\n", lenses_json
			printf "      \"summary\": \"%s\",\n", summary
			printf "      \"evidence\": \"%s\",\n", evidence
			printf "      \"suggestion\": \"%s\"\n", suggestion
			printf "    }"
		}
		END { printf "\n  ]" }
	'
}

emit_related_pretty() {
	if [[ -z "$related_tsv" ]]; then
		printf '[]'
		return
	fi
	# Filter to one direction per pair: emit when category_self < category_other
	# (so each unordered pair appears exactly once with categories sorted asc).
	local one_dir
	one_dir="$(printf '%s\n' "$related_tsv" | awk -F '\t' '
		{
			# fields: file_a line_a cat_a cat_b file_b line_b
			# canonical pair: smaller category first
			if ($3 < $4) print $0
		}
	' | sort -t $'\t' -k1,1 -k2,2n -k3,3 -k4,4)"
	if [[ -z "$one_dir" ]]; then
		printf '[]'
		return
	fi
	printf '%s\n' "$one_dir" | awk -F '\t' '
		function jesc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
		BEGIN { first = 1; printf "[\n" }
		{
			if (!first) printf ",\n"
			first = 0
			fa = jesc($1); la = $2; ca = jesc($3); cb = jesc($4)
			la_field = (la ~ /^-?[0-9]+$/) ? la : ("\"" jesc(la) "\"")
			printf "    {\n"
			printf "      \"file\": \"%s\",\n", fa
			printf "      \"line\": %s,\n", la_field
			printf "      \"categories\": [\"%s\", \"%s\"]\n", ca, cb
			printf "    }"
		}
		END { printf "\n  ]" }
	'
}

findings_json="$(emit_findings_pretty)"
related_json="$(emit_related_pretty)"

cat <<EOF
{
  "summary": {
    "raw": $raw,
    "merged": $combined_groups,
    "unique": $unique_count,
    "related": $related_count,
    "dropped": $dropped
  },
  "findings": $findings_json,
  "related": $related_json
}
EOF
