#!/usr/bin/env bash
# run-gate.sh — thin gate-output dispatcher for the review-gauntlet
# conductor. This script does NOT review anything itself; the operative
# review is done by the gates the conductor configures for the current
# harness (see SKILL.md for the current gate list, which differs between
# Claude and Codex) and by the fixer/conductor. This script only:
#   1. normalizes one gate's raw JSON output into the common finding schema
#      (file, line, category, severity, confidence, summary, evidence),
#      stripping any `auto_fix` proposal aside into a side cache so the
#      pooled-findings payload handed to the reconciler is auto_fix-free
#      (the reconciler requires --skill only when auto_fix is present, and
#      this gauntlet is neither deep-review nor review-plan);
#   2. pipes the pooled, auto_fix-free findings through this skill's own
#      BUNDLED copy of reconcile-findings.sh (never a relative path into
#      ../../deep-review/scripts), invoked WITHOUT --skill;
#   3. after reconciliation, routes each finding by re-attaching any cached
#      auto_fix proposal and delegating eligibility/apply to the bundled
#      audit-auto-fix-eligibility.sh / apply-auto-fix-code.sh (never
#      reimplementing the allowlist) — findings the applier can't handle
#      (no auto_fix, or an ineligible kind) are reported back as
#      "substantive", for the fixer subagent to edit directly.
#
# Usage:
#   run-gate.sh normalize --gate <name> --autofix-cache <path> [<raw.json>|-]
#       Reads one gate's raw output
#       {gate, status, findings:[{file,line,category,severity,confidence,
#       summary,evidence,auto_fix?}], notes}. A non-clean status
#       (error|skipped|deferred) is reported to stderr and the exit code
#       distinguishes it (see EXIT CODES) — it must never be silently
#       treated as a clean pass by the caller. Emits normalized,
#       auto_fix-free findings as JSON-Lines on stdout (one per gate
#       invocation); appends any finding that carried an auto_fix block,
#       unstripped, to --autofix-cache (JSON-Lines, created if absent).
#
#   run-gate.sh reconcile [<pooled-findings.jsonl>|-]
#       Pipes the pooled, auto_fix-free JSON-Lines findings (concatenated
#       across every gate's `normalize` stdout) through the bundled
#       reconcile-findings.sh, called without --skill. Emits the reconciled
#       v2 envelope JSON on stdout.
#
#   run-gate.sh status-row [--gate <name>] [<envelope.json>|-]
#       Reads one gate's ENVELOPE (the object `gate_run_bounded`/lib/
#       gate-bounded.sh writes on every exit path: {status, notes, findings,
#       gate, duration_s, degraded_reason} — NOT the raw tool-out) and emits
#       exactly one tab-separated table row on stdout: `gate <TAB> status
#       <TAB> duration_s <TAB> findings <TAB> degraded_reason`. `findings` is
#       the length of the envelope's `.findings` array. `duration_s` and
#       `degraded_reason` render as the literal `-` when null/absent — never
#       the raw JSON token `null`, never empty. This is the ONLY thing that
#       builds a gate-status row (SKILL.md only says where to print rows it
#       gets by calling this — see R7 in the dev plan).
#
#       A zero-byte, missing, unreadable, or non-object envelope payload
#       (e.g. `[]`) does NOT abort or emit nothing: it emits one all-`-` row
#       with `status` = `error` and exits 0, so the gate still accounts for
#       itself in the operator's table (row-count == slot-count is a
#       SKILL.md-asserted invariant this subcommand exists to guarantee).
#       Optional `--gate <name>` replaces column 1 on BOTH the normal and the
#       fallback row, so even a zero-byte envelope can still name its slot.
#
#   run-gate.sh route --autofix-cache <path> [<reconciled-envelope.json>|-]
#       Re-attaches any cached auto_fix proposal to each reconciled finding
#       by matching (file, line, category), runs the bundled
#       audit-auto-fix-eligibility.sh --skill deep-review to annotate
#       eligibility (reusing its allowlist decision — this script does not
#       duplicate allowlist logic), and emits two JSON arrays on stdout:
#         {
#           "trivial_envelope": { ...v2 envelope of only would_apply findings,
#                                  ready for apply-auto-fix-code.sh },
#           "substantive_findings": [ ...findings the fixer must edit
#                                      directly: no auto_fix, or an
#                                      auto_fix_status other than
#                                      would_apply ]
#         }
#       `--skill deep-review` here is intentional, not a gauntlet identity
#       claim: apply-auto-fix-code.sh is hardcoded to skill identity
#       "deep-review" (see Phase 2 dev-plan note), so the eligibility audit
#       must be run under that same identity for its allowlist decision to
#       match what the applier will actually do.
#
# EXIT CODES: 0 success. 2 usage/validation error. 4 a gate's raw status
# was error/skipped/deferred (normalize only — findings, if any, are still
# emitted; the caller must not count this round as a clean pass).
#
# Dependencies: bash + jq. Bundled-script resolution is via
# gauntlet-common.sh (runtime-specific anchor; aborts rather than
# falling back to a hand copy or a relative deep-review path).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugins/skein/skills/review-gauntlet/lib/gauntlet-common.sh disable=SC1091
. "$SCRIPT_DIR/gauntlet-common.sh"
# shellcheck source=plugins/skein/skills/review-gauntlet/lib/state-path-guard.sh disable=SC1091
. "$SCRIPT_DIR/state-path-guard.sh"

usage() {
	cat >&2 <<'EOF'
usage: run-gate.sh normalize --gate <name> --autofix-cache <path> [<raw.json>|-]
       run-gate.sh reconcile [<pooled-findings.jsonl>|-]
       run-gate.sh route --autofix-cache <path> [<reconciled-envelope.json>|-]
       run-gate.sh status-row [--gate <name>] [<envelope.json>|-]
EOF
}

read_input() {
	# Read the trailing positional (file path or "-"/absent for stdin).
	#
	# A NAMED PATH HERE IS A `.gauntlet/` STATE PATH (round 8, F3) — SKILL.md
	# composes it from the same `$gate_out_dir` as --autofix-cache — and it is
	# the file the `auto_fix` blocks ORIGINATE in (`normalize` strips them into
	# the cache; `route` re-attaches them). Guarding the flag and not the
	# positional was the same asymmetry round 7's F9 closed one hop
	# downstream. The guard lives at the SINGLE open, not per subcommand, so a
	# new subcommand cannot inherit an unguarded read. `-` is stdin: no path,
	# nothing to guard.
	#
	# NEVER exits: `cmd_status_row` must still emit exactly one row (F4), so a
	# refusal has to come back as a return status its caller can absorb.
	local path="${1:--}"
	if [[ "$path" == "-" ]]; then
		cat
	else
		gauntlet_assert_no_symlink "$path" run-gate || return 1
		cat "$path"
	fi
}

cmd_normalize() {
	local gate="" cache="" input_path="-"
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--gate)
			shift
			[[ $# -gt 0 ]] || {
				usage
				exit 2
			}
			gate="$1"
			;;
		--autofix-cache)
			shift
			[[ $# -gt 0 ]] || {
				usage
				exit 2
			}
			cache="$1"
			;;
		--help | -h)
			usage
			exit 0
			;;
		*)
			input_path="$1"
			;;
		esac
		shift
	done
	if [[ -z "$gate" || -z "$cache" ]]; then
		echo "run-gate normalize: --gate <name> and --autofix-cache <path> are required" >&2
		usage
		exit 2
	fi
	# Same state tree, same containment policy (round 6, G1 sweep). SKILL.md
	# composes --autofix-cache from the very `$gate_out_dir` gate_run_bounded
	# writes its envelope into, and this command CREATES that file
	# (`printf '' >"$cache"`) and later APPENDS to it — so it is a state-tree
	# writer with exactly the exposure gate-bounded.sh has, and had no guard
	# at all. It sits here: after the flags are known to be present (so it is
	# not guarding a guess) and before the first filesystem effect.
	gauntlet_assert_no_symlink "$cache" run-gate || exit 2
	gc_have_jq

	local raw status duration_s degraded_reason
	raw="$(read_input "$input_path")" || exit 2
	status="$(printf '%s' "$raw" | jq -r '.status // empty')"
	if [[ -z "$status" ]]; then
		echo "run-gate normalize: gate '$gate' raw output missing .status" >&2
		exit 2
	fi
	# R11/F16: the status ALPHABET is validated here, beside the presence
	# check, not in the `case` after the findings loop.
	#
	# INVARIANT. Old: partial emission was documented for exit 4 only, but an
	# unrecognised status also exited 2 from the trailing `case` — AFTER the
	# loop had streamed findings to stdout and appended auto_fix entries to
	# the cache, leaving a half-populated cache that `route` later reads.
	# New: exit 2 (validation) has no side effects; only exit 4 does. Every
	# exit-2 arm in this command now precedes the cache creation at
	# `[[ -e "$cache" ]] || printf ''` below.
	#
	# The trailing `case` keeps only the clean/not-clean split, which is a
	# post-emission REPORT (it needs duration_s/degraded_reason and the
	# findings already emitted), not a validation.
	case "$status" in
	approve | needs-attention | error | skipped | deferred) ;;
	*)
		echo "run-gate normalize: gate '$gate' returned unrecognised status '$status'" >&2
		exit 2
		;;
	esac
	# gate_run_bounded (lib/gate-bounded.sh) stamps every envelope it
	# writes with optional duration_s/degraded_reason — surface them here
	# as a stderr note alongside the non-clean-status report below. stdout
	# stays per-finding JSONL only; status-row (Phase 3) reads the
	# envelope directly for the tabular form.
	duration_s="$(printf '%s' "$raw" | jq -r '.duration_s // empty')"
	degraded_reason="$(printf '%s' "$raw" | jq -r '.degraded_reason // empty')"

	[[ -e "$cache" ]] || printf '' >"$cache"

	# Emit each finding twice: the auto_fix-free version to stdout (pooled
	# for reconcile), and — only when an auto_fix block is present — the
	# full finding appended to the cache (for `route` to re-attach later).
	# The pooled/reconcile-bound copy carries `lens: <gate>` (not `gate`) so
	# it slots directly into the bundled reconciler's existing (file, line,
	# category) merge + cross-lens corroboration, which reads `.lens` — no
	# reconciler modification needed to treat each gate as a "lens".
	printf '%s' "$raw" | jq -c --arg gate "$gate" '
		.findings[]? | . + {gate: $gate}
	' | while IFS= read -r finding; do
		[[ -n "$finding" ]] || continue
		gc_normalize_finding "$finding" | jq -c --arg gate "$gate" '. + {lens: $gate}'
		if printf '%s' "$finding" | jq -e 'has("auto_fix")' >/dev/null 2>&1; then
			printf '%s\n' "$finding" >>"$cache"
		fi
	done

	# Status is already known to be in the alphabet (validated above, before
	# any side effect), so this is a two-way split with no error arm.
	case "$status" in
	approve | needs-attention) exit 0 ;;
	*)
		echo "run-gate normalize: gate '$gate' returned status=$status — not a clean pass, do not count toward convergence" >&2
		if [[ -n "$duration_s" || -n "$degraded_reason" ]]; then
			echo "run-gate normalize: gate '$gate' duration_s=${duration_s:-unknown} degraded_reason=${degraded_reason:-none}" >&2
		fi
		exit 4
		;;
	esac
}

cmd_reconcile() {
	local input_path="-"
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--help | -h)
			usage
			exit 0
			;;
		*)
			input_path="$1"
			;;
		esac
		shift
	done
	local reconciler
	reconciler="$(gc_bundled_script reconcile-findings.sh)"
	# Deliberately no --skill: this gauntlet is neither deep-review nor
	# review-plan, and findings reaching this point are already
	# auto_fix-free (stripped in `normalize`), so the reconciler never
	# requires --skill here.
	# Captured, not piped: a pipeline swallows read_input's status, so a
	# refused (symlinked) envelope path would reconcile an empty stream and
	# exit 0 (round 8, F3).
	local pooled
	pooled="$(read_input "$input_path")" || exit 2
	if [[ -n "$pooled" ]]; then
		# Re-terminate: command substitution stripped the trailing
		# newline the reconciler's line reader needs on the last record.
		printf '%s\n' "$pooled" | "$reconciler"
	else
		printf '' | "$reconciler"
	fi
}

cmd_route() {
	local cache="" input_path="-"
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--autofix-cache)
			shift
			[[ $# -gt 0 ]] || {
				usage
				exit 2
			}
			cache="$1"
			;;
		--help | -h)
			usage
			exit 0
			;;
		*)
			input_path="$1"
			;;
		esac
		shift
	done
	if [[ -z "$cache" ]]; then
		echo "run-gate route: --autofix-cache <path> is required" >&2
		usage
		exit 2
	fi
	# Round 7, F9: same state tree, same policy — and a READ is guarded too,
	# because this file's content becomes `.auto_fix` proposals below, which
	# apply-auto-fix-code.sh later applies to the working tree. An
	# attacker-planted symlink at the cache path would otherwise feed chosen
	# JSON into the auto-fix stream. `cmd_normalize` guards the same flag,
	# composed from the same `$gate_out_dir`; guarding one and not the other
	# was the whole defect.
	gauntlet_assert_no_symlink "$cache" run-gate || exit 2
	gc_have_jq

	local reconciled cache_jsonl
	reconciled="$(read_input "$input_path")" || exit 2
	# R11/F17: shape-gate the reconciled envelope before it reaches
	# `jq -n --argjson reconciled` below. `--argjson` on empty or non-JSON
	# input fails inside jq, so the operator saw a raw
	# `jq: Invalid JSON text passed to --argjson` with no indication of which
	# run-gate command or which input produced it. `cmd_normalize` (:177) and
	# `cmd_reconcile` (:249) already validate their input; `cmd_status_row`
	# (:434) already uses exactly this `[[ -z ]] || ! jq -e 'type == "object"'`
	# idiom. Route was the one reader with neither. Same exit-2 usage class,
	# same `run-gate:`-prefixed diagnostic as its siblings.
	if [[ -z "$reconciled" ]] || ! printf '%s' "$reconciled" | jq -e 'type == "object"' >/dev/null 2>&1; then
		echo "run-gate route: reconciled input is empty or not a JSON object" >&2
		exit 2
	fi
	if [[ -e "$cache" ]]; then
		cache_jsonl="$(cat "$cache")"
	else
		cache_jsonl=""
	fi

	# Re-attach any cached auto_fix proposal by matching (file, line,
	# category) — the same structural signature reconcile-findings.sh
	# itself groups on.
	local cache_array
	cache_array="$(printf '%s' "$cache_jsonl" | jq -cs 'if length == 0 then [] else . end')"

	# Warn if two cached findings share a (file, line, category) signature: the
	# re-attach below builds a last-writer-wins map, so a collision silently
	# drops one gate's auto_fix proposal. Surface it rather than lose it quietly.
	# Partition on the SAME BEL-joined signature the re-attach map below
	# uses, so the collision set is exactly the set of proposals the map would
	# collapse — a display-only "|" join here could split/merge differently
	# when a field contains a literal separator. Emit a human-readable
	# file:line:category for the operator warning.
	local sig_collisions
	sig_collisions="$(printf '%s' "$cache_array" | jq -r '
		def sig: [.file, (.line|tostring), .category] | join("\u0007");
		group_by(sig) | map(select(length > 1)) | .[]
		| (.[0] | [.file, (.line|tostring), .category] | join(":"))
	')"
	if [[ -n "$sig_collisions" ]]; then
		while IFS= read -r sig; do
			[[ -n "$sig" ]] || continue
			echo "run-gate route: WARNING multiple cached auto_fix proposals share signature ($sig); last one wins" >&2
		done <<<"$sig_collisions"
	fi

	local envelope_with_autofix
	envelope_with_autofix="$(
		jq -n \
			--argjson reconciled "$reconciled" \
			--argjson cache "$cache_array" \
			'
			def sig: [.file, (.line|tostring), .category] | join("\u0007");
			($cache | map({(sig): .auto_fix}) | add // {}) as $by_sig
			| $reconciled
			| .findings |= map(
				. as $f
				| ($f | sig) as $s
				# Guardrail 1 (design-conflict findings are never auto-fixed) is a
				# fixer-subagent judgment call, not something the trivial applier can
				# make -- it only knows the mechanical allowlist, never the dev-plan
				# design intent. So an architecture/design-relevant finding must never
				# even reach the auditor with an auto_fix block attached, regardless
				# of what kind the gate proposed: drop the cached proposal here, by
				# construction, forcing it to substantive_findings (the fixer path,
				# where the dev-plan is in context) instead of the trivial applier.
				# This is a floor under Guardrail 1, not a replacement for it.
				| if ($by_sig[$s] // null) != null and (($f.category // "") | ascii_downcase | test("architecture|design")) then .
				elif ($by_sig[$s] // null) != null then . + {auto_fix: $by_sig[$s]}
				else . end
			)
		'
	)"

	# Delegate eligibility classification to the bundled auditor — never
	# reimplement the allowlist here. --skill deep-review matches the
	# applier's hardcoded skill identity (see script header comment).
	local auditor
	auditor="$(gc_bundled_script audit-auto-fix-eligibility.sh)"
	local annotated
	annotated="$(printf '%s' "$envelope_with_autofix" | "$auditor" --skill deep-review -)"

	printf '%s' "$annotated" | jq -c '
		{
			trivial_envelope: (. + {findings: [.findings[] | select(.auto_fix_status? == "would_apply")]}),
			substantive_findings: [.findings[] | select((.auto_fix_status? // "") != "would_apply")]
		}
	'
}

cmd_status_row() {
	local input_path="-" gate=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--gate)
			shift
			[[ $# -gt 0 ]] || {
				usage
				exit 2
			}
			gate="$1"
			;;
		--help | -h)
			usage
			exit 0
			;;
		*)
			input_path="$1"
			;;
		esac
		shift
	done
	gc_have_jq

	local envelope
	# `|| true` (NOT `2>/dev/null || true`) — round 9, F11. The STATUS must
	# be absorbed so F4 still holds: a refused or unreadable envelope prints
	# exactly one `error` row and exits 0, so the slot never vanishes from
	# the operator's table. The DIAGNOSTIC must not be: a symlink refusal
	# from read_input's guard is the one condition an operator has to act on,
	# and swallowing it rendered it identically to "the gate produced
	# nothing". A missing-file `cat` error now also reaches stderr, naming
	# the path the generic row cannot.
	envelope="$(read_input "$input_path" || true)"

	# F4: a zero-byte, missing/unreadable, or non-object envelope (including
	# valid-but-wrong-shape JSON like `[]`) must still produce exactly one
	# row — never nothing, never a non-zero exit — so the gate never
	# vanishes from the operator's table. `--gate <name>`, when supplied,
	# names the slot even on this fallback row.
	if [[ -z "$envelope" ]] || ! printf '%s' "$envelope" | jq -e 'type == "object"' >/dev/null 2>&1; then
		local gate_col="${gate:--}"
		printf '%s\t%s\t%s\t%s\t%s\n' "$gate_col" "error" "-" "-" "envelope missing or unreadable"
		return 0
	fi

	# `//"-"` covers both an absent key and an explicit JSON null — the one
	# rendering rule this subcommand exists to guarantee: the raw token
	# "null" must never appear in a printed row, and neither may an empty
	# field silently stand in for "no value here". `scalar_or` extends the
	# same guarantee to a non-scalar value (see F6 below). `--gate <name>`,
	# when supplied, overrides column 1 (the orchestrator is authoritative on
	# slot identity — same argument as gate_run_bounded's --gate).
	printf '%s' "$envelope" | jq -r --arg gate_override "$gate" '
		# F6: @tsv ERRORS on a non-scalar column, and under `set -euo
		# pipefail` that error killed the subcommand -- rc != 0 and NO ROW,
		# the exact disappearance the F4 fallback above exists to prevent.
		# An envelope may be an object and still carry a non-scalar field
		# (SKILL.md has the conductor hand-build the gate-2/gate-3
		# envelopes), so every column is rendered total: a non-scalar value
		# degrades to the column default instead of aborting the row.
		def scalar_or($d):
			if type == "string" or type == "number" or type == "boolean"
			then tostring
			else $d
			end;
		((.status // "-") | scalar_or(null)) as $status
		| [
			(if ($gate_override | length) > 0 then $gate_override
			 else ((.gate // "-") | scalar_or("-")) end),
			($status // "error"),
			((.duration_s // "-") | scalar_or("-")),
			(if (.findings | type) == "array" then (.findings | length | tostring) else "-" end),
			(if $status == null then "malformed envelope: non-scalar status"
			 else ((.degraded_reason // "-") | scalar_or("-")) end)
		] | @tsv
	'
}

if [[ $# -eq 0 ]]; then
	usage
	exit 2
fi

subcommand="$1"
shift
case "$subcommand" in
normalize) cmd_normalize "$@" ;;
reconcile) cmd_reconcile "$@" ;;
route) cmd_route "$@" ;;
status-row) cmd_status_row "$@" ;;
--help | -h)
	usage
	exit 0
	;;
*)
	echo "run-gate: unknown subcommand: $subcommand" >&2
	usage
	exit 2
	;;
esac
