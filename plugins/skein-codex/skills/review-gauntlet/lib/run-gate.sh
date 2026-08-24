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

usage() {
	cat >&2 <<'EOF'
usage: run-gate.sh normalize --gate <name> --autofix-cache <path> [<raw.json>|-]
       run-gate.sh reconcile [<pooled-findings.jsonl>|-]
       run-gate.sh route --autofix-cache <path> [<reconciled-envelope.json>|-]
EOF
}

read_input() {
	# Read the trailing positional (file path or "-"/absent for stdin).
	local path="${1:--}"
	if [[ "$path" == "-" ]]; then
		cat
	else
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
	gc_have_jq

	local raw status duration_s degraded_reason
	raw="$(read_input "$input_path")"
	status="$(printf '%s' "$raw" | jq -r '.status // empty')"
	if [[ -z "$status" ]]; then
		echo "run-gate normalize: gate '$gate' raw output missing .status" >&2
		exit 2
	fi
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

	case "$status" in
	approve | needs-attention) exit 0 ;;
	error | skipped | deferred)
		echo "run-gate normalize: gate '$gate' returned status=$status — not a clean pass, do not count toward convergence" >&2
		if [[ -n "$duration_s" || -n "$degraded_reason" ]]; then
			echo "run-gate normalize: gate '$gate' duration_s=${duration_s:-unknown} degraded_reason=${degraded_reason:-none}" >&2
		fi
		exit 4
		;;
	*)
		echo "run-gate normalize: gate '$gate' returned unrecognised status '$status'" >&2
		exit 2
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
	read_input "$input_path" | "$reconciler"
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
	gc_have_jq

	local reconciled cache_jsonl
	reconciled="$(read_input "$input_path")"
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
