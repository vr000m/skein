#!/usr/bin/env bash
# finding-key.sh — compute review-gauntlet's regression key for one or more
# findings.
#
# Usage:
#   scripts/finding-key.sh [<findings.jsonl>|-]
#
# Stdin/file: JSON-Lines findings, EXACTLY one object per physical line
# (enforced -- a line holding zero, two, or a non-object document is skipped
# with a stderr warning, never combined into a key), each with at least
# {file, category, summary}. Blank lines and lines that fail to parse as a
# JSON object are skipped silently (same tolerance as reconcile-findings.sh).
# A present-but-non-string file/category/summary (a number, bool, object,
# array) IS malformed: the line is skipped with a stderr warning naming the
# field and its type (see "Total extraction" below). Absent/null is fine —
# that is the documented "" default.
#
# Stdout: one regression key per line, in input order —
#   sha1(len(file):file <US> len(category):category <US> len(summary):summary)
# (`<US>` = ASCII 0x1F, kept purely for legibility when debugging — the
# length prefixes, not the separator, are what make the encoding
# unambiguous). File path is used VERBATIM (never lowercased). Category is
# lowercased. Summary is normalised (see below). Missing file/category/
# summary default to "".
#
# Field identity, precisely:
#   - file: VERBATIM, no case-folding. Every gate reports a git path, which
#     is byte-stable across platforms regardless of local filesystem case
#     sensitivity — lowercasing it would collide two genuinely different
#     files (`Foo.md` vs `foo.md` in the git index / on a case-sensitive
#     filesystem) into one regression key, which can produce a FALSE
#     terminal `regression` — the one failure mode this key is explicitly
#     biased against (see the precision rationale below).
#   - category: lowercased. Gates genuinely disagree on casing convention
#     (`Security` vs `security`), and collapsing that is desirable —
#     unlike file, there is no cross-gate case-sensitive identity to lose.
#   - summary: lowercased + whitespace-collapsed (leading/trailing trim,
#     internal runs of whitespace collapsed to a single space). There is NO
#     digit-stripping — two findings in the same file/category whose
#     summaries differ only in a number ("line 12 unused" vs "line 34
#     unused") must produce DISTINCT keys, biasing this key toward precision
#     (a missed regression degrades to today's cap behaviour; a
#     false-positive regression would halt a healthy convergence loop).
#
# The length-prefixed encoding is deliberately injective regardless of field
# content: a literal `|` or `\x1f` inside a summary can no longer shift a
# field boundary the way a bare separator-joined `printf` could. `LC_ALL=C`
# (set below) makes `${#var}` a byte count and makes case-folding ASCII-only
# — both are determinism gains, so the same finding hashes identically on
# any host locale.
#
# Total extraction (G3 + adversarial addendum). The pre-hash string is
# assembled ENTIRELY INSIDE jq and piped straight to sha1 — it is never
# carried through a bash variable. Two independent defects made that
# necessary, and both are structural, not incidental:
#   - A bash string cannot hold a NUL, so the previous NUL-delimited field
#     reader TRUNCATED any field containing one: `summary:"a\u0000b"` keyed
#     identically to `summary:"a"`. Any in-band delimiter has this problem,
#     because the delimiter has to be a byte the payload may legitimately
#     contain (0x00 for a `read -d ''` loop, 0x0A for a `$( )` capture).
#     Not carrying the fields through bash at all removes the delimiter, and
#     with it the truncation class.
#   - `//` substitutes only null/false, so a NUMBER in .file reached jq's
#     string concat, aborted the filter mid-stream, and left the read loop
#     with nothing — every field resolved to empty and EVERY malformed
#     finding collapsed onto one shared key. A TYPE GATE now runs before the
#     pre-image filter and skips any line whose file/category/summary is
#     present but not a string, naming the field and its type on stderr, so
#     the filter can assume strings. This matters precisely because the key
#     is biased against a FALSE `regression`: a shared key lets a claimed fix
#     on malformed finding A promote the shared key, so malformed finding B
#     in the next round fires the terminal regression stop.
#     NOT `tostring` coercion: that fabricates an identity for malformed
#     model output and silently blesses it.
# Every failure is per-line: skip-and-warn, never a non-zero exit. The
# documented consumer is `finding-key.sh - > "$present_keys_file"`, run under
# `pipefail`, so aborting on one malformed line among fifty would discard the
# forty-nine good keys and take the whole round down with it — the same
# convergence-abort class this diff removes elsewhere. Consumers
# (convergence-ledger.sh --present-keys/--claimed-keys) tolerate a missing
# key — at worst a missed regression, which degrades to today's cap
# behaviour — but not a fabricated shared one.
#
# Invariant: one line in, one key out — OR one diagnostic and no key. Two
# distinct findings never share a key.
#
# This key is DISTINCT BY DESIGN from the reconciler's line-anchored
# (file, line, category) dedup key: a finding that shifts to a different line
# across rounds (the same bug, reported again by a fresh gate pass against a
# changed diff) must still resolve to the SAME regression key, which is
# exactly why `line` is excluded here.
#
# This script is gauntlet-only: registered via `bundle_extra_for
# review-gauntlet` in scripts/lib/bundle-map.sh, NOT `BUNDLE_SHARED` — no
# other skill consumes finding identity in this shape.
#
# Exit codes:
#   0 — every line either produced a key or was skipped (not exactly one
#       JSON object, a non-string field, or an extraction failure), each
#       skip carrying a stderr warning. A skip never emits a key, so a
#       truncated or all-empty key can never reach the ledger.
#   2 — usage error (too many arguments, missing jq/shasum, unreadable
#       input path).
#
# Dependencies: bash + jq + shasum|sha1sum.

set -euo pipefail
export LC_ALL=C

usage() {
	echo "usage: finding-key.sh [<findings.jsonl>|-]" >&2
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
	usage
	exit 0
fi

if [[ $# -gt 1 ]]; then
	usage
	exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
	echo "finding-key: jq is required" >&2
	exit 2
fi
if ! command -v shasum >/dev/null 2>&1 && ! command -v sha1sum >/dev/null 2>&1; then
	echo "finding-key: shasum or sha1sum is required" >&2
	exit 2
fi

fk_sha1() {
	if command -v shasum >/dev/null 2>&1; then
		shasum | awk '{print $1}'
	else
		sha1sum | awk '{print $1}'
	fi
}

input_path="${1:--}"

# The loop below reads from a process substitution rather than the tail of a
# pipeline, so it runs in THIS shell: a fatal extraction failure can `exit`
# the script (inside a pipeline it would only exit a subshell) and the EXIT
# trap that removes the scratch file actually fires. The pipeline form also
# swallowed an unreadable <findings.jsonl> as "empty input, exit 0", so the
# readability check that `cat` used to perform is now explicit.
if [[ "$input_path" != "-" && ! -r "$input_path" ]]; then
	echo "finding-key: cannot read input file: $input_path" >&2
	exit 2
fi

read_input() {
	if [[ "$input_path" == "-" ]]; then
		cat
	else
		cat "$input_path"
	fi
}

# FK_TYPE_GATE — names every one of the three identity fields that is
# PRESENT but not a string, as "<field> is <type>", comma-joined; empty
# output means the line is safe to hash. Absent and null are fine: both have
# jq type "null" and are the documented "" default. This runs BEFORE
# FK_KEY_FILTER so that filter can assume strings, which is why the filter
# carries no `tostring` — coercing a number into an identity would fabricate
# a key for output that is malformed at the source.
# shellcheck disable=SC2016  # jq program: $o is a jq variable, not shell.
FK_TYPE_GATE='
	.[0] as $o
	| ["file", "category", "summary"]
	| map(select(($o[.] | type) | . != "string" and . != "null")
	      | "\(.) is \($o[.] | type)")
	| join(", ")
'

# FK_KEY_FILTER — the ENTIRE pre-hash string, assembled inside jq and never
# carried through a bash variable (see "Total extraction" in the header).
#
#   - FK_TYPE_GATE has already rejected any present-but-non-string field, so
#     `// ""` here handles exactly one case: absent or null, the documented
#     "" default. Values reach the digest verbatim — no coercion, no key
#     churn for well-formed input.
#   - `utf8bytelength` is the exact jq-side equivalent of bash's `${#var}`
#     under `LC_ALL=C` (a BYTE count), so the length prefixes are unchanged.
#   - `ascii_downcase` is the exact equivalent of `tr '[:upper:]'
#     '[:lower:]'` under `LC_ALL=C` (ASCII-only case folding).
#   - `gsub("\\s+"; " ")` then trimming one leading/trailing space is the
#     exact equivalent of `tr -s '[:space:]' ' '` + `sed 's/^ +//; s/ +$//'`
#     under `LC_ALL=C`: Oniguruma's `\s` is the ctype space class, the same
#     six bytes (space TAB LF VT FF CR) `[:space:]` names in the C locale.
#     After the collapse at most ONE space can be leading or trailing, so a
#     single `ltrimstr`/`rtrimstr` is sufficient (and, unlike a `$`-anchored
#     regex, cannot be confused by a trailing newline).
#   - `\u001F` is the ASCII US separator, kept purely for legibility — the
#     length prefixes, not the separator, are what make this injective.
#
# NO digit-stripping: see the summary rationale in the header.
# shellcheck disable=SC2016  # this is a jq program, not shell: $file/$category/
# $summary are jq variables and must NOT be expanded by bash.
FK_KEY_FILTER='
	.[0]
	| (.file // "") as $file
	| ((.category // "") | ascii_downcase) as $category
	| ((.summary // "") | ascii_downcase
	   | gsub("\\s+"; " ") | ltrimstr(" ") | rtrimstr(" ")) as $summary
	| "\($file | utf8bytelength):\($file)\u001F"
	  + "\($category | utf8bytelength):\($category)\u001F"
	  + "\($summary | utf8bytelength):\($summary)"
'

# Scratch file for one line's pre-hash string. A file, not a variable: the
# string may legitimately contain a NUL byte (a finding whose summary does),
# which is exactly what a bash variable cannot hold.
FK_KEY_BUF="$(mktemp "${TMPDIR:-/tmp}/finding-key.XXXXXX")"
trap 'rm -f "$FK_KEY_BUF"' EXIT

# `|| [[ -n "$line" ]]` keeps a final object that lacks a trailing newline:
# without it the last key is silently dropped, and the keys feed
# convergence-ledger.sh --present-keys/--claimed-keys, so a reappearing fixed
# finding on the last line would never fire `regression`. Same idiom as
# collect-lens-results.sh's attempt-file reader.
fk_lineno=0
while IFS= read -r line || [[ -n "$line" ]]; do
	fk_lineno=$((fk_lineno + 1))
	[[ -n "$line" ]] || continue
	# --slurp, then require EXACTLY one document. Without --slurp, jq applies
	# the filter to each top-level document independently and its exit status
	# reflects only the LAST one, so `{...} {...}` on one physical line passed
	# a bare `type == "object"` gate; each field read below then emitted two
	# lines that `$( )` joined with a newline into one key matching NEITHER
	# finding. These keys are the regression identity consumed by
	# convergence-ledger.sh --present-keys/--claimed-keys: skipping a line
	# loses a key (at worst a missed regression), combining two fabricates one
	# (a terminal false stop). Skip, and say so on stderr -- the same
	# tolerance the non-object case already gets, plus a warning.
	if ! printf '%s' "$line" | jq -e -s 'length == 1 and (.[0] | type == "object")' >/dev/null 2>&1; then
		printf 'finding-key: skipping line that is not exactly one JSON object\n' >&2
		continue
	fi
	# Type gate (see FK_TYPE_GATE above). A present-but-non-string identity
	# field is malformed at the source; skip it and say which field and which
	# type, rather than inventing a key for it.
	bad_fields="$(printf '%s' "$line" | jq -r -s "$FK_TYPE_GATE" 2>/dev/null || true)"
	if [[ -n "$bad_fields" ]]; then
		printf 'finding-key: skipping line %d: non-string field(s): %s\n' \
			"$fk_lineno" "$bad_fields" >&2
		continue
	fi
	# ONE jq invocation that emits the WHOLE pre-hash string. Nothing is read
	# back into a bash variable, so there is no delimiter to truncate on and
	# no per-field capture to newline-join (see "Total extraction" in the
	# header). A summary containing a literal newline, or a literal NUL,
	# therefore survives intact all the way into the digest.
	#
	# Fails CLOSED but NOT fatal: a non-zero jq exit means the key for this
	# line is UNKNOWN, and the one thing that must never happen is emitting
	# the all-empty key in its place -- that key is shared by construction,
	# and a shared key is exactly the false-`regression` failure this
	# identity is biased against. Skip the line and warn; do not exit, or one
	# bad line among fifty would take every good key down with it under the
	# consumer's `pipefail`.
	if ! printf '%s' "$line" | jq -j -s "$FK_KEY_FILTER" >"$FK_KEY_BUF"; then
		printf 'finding-key: skipping line %d: key extraction failed\n' "$fk_lineno" >&2
		continue
	fi
	fk_sha1 <"$FK_KEY_BUF"
done < <(read_input)
