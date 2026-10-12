#!/usr/bin/env bash
# report-hook.sh - the guarded entry point behind the `--report` flag of
# review-gauntlet and deep-review.
#
# It guards the output path, captures the diff stat, runs render-report.py, and
# ALWAYS exits 0: a guard refusal, a missing python3, a failing git, or a
# failing renderer each log a warning on stderr and skip the report. A report
# failure never changes a run's terminal token or exit code. The hook never
# calls gh, never writes ledger or state files, and writes only the report
# (through the renderer) plus a scratch diff-stat file under mktemp that it
# removes on every exit path. With --cleanup it also deletes the scratch
# --envelope and --suppress-keys files it was handed, on every exit path.
#
# Usage:
#   report-hook.sh --root <dir> --out <file>
#       [--ledger <path>] [--round N=<envelope>]... [--envelope <path>]
#       [--suppress-keys <file>] [--base <oid> --head <oid>] [--cleanup]
#
#   --root/--out    repo root and the report path. --out must sit directly
#                   under <root>/.gauntlet or <root>/.deep-review.
#   --base/--head   diff scope as two commit ids. With neither (or only one),
#                   the report renders "diff scope unavailable".
#   --cleanup       after rendering, whatever the outcome (success, guard
#                   refusal, renderer failure, bad arguments), delete the
#                   --envelope and --suppress-keys files. Each is deleted only
#                   when it is a regular, non-symlink file named
#                   `skein-report-*` directly inside the system temp dir
#                   (`${TMPDIR:-/tmp}`) with no `..` in its path; anything
#                   else is left in place with a warning. This lets skill
#                   prose drop scratch files without an `rm` of its own.
#   other flags     passed to render-report.py unchanged.
#
# stdout: `report written: <out>` on success; nothing otherwise.
# stderr: `report-hook: warning: ...` lines.
#
# Environment overrides (for tests; ignored unless SKEIN_REPORT_TEST=1):
#   SKEIN_REPORT_RENDERER  path to an executable that replaces render-report.py
#   SKEIN_REPORT_NOW       fixed timestamp for the diff-stat header and report
#
# First-layer containment (the renderer re-checks as defence in depth): the
# bundled sibling lib/auto-fix-common.sh is sourced inside a SUBSHELL, because
# that lib runs `set -euo pipefail` and `readonly` at top level and must never
# reach this shell, then `af_assert_no_symlink <out> <root>` runs there. A
# textual check then refuses `..` and any --out whose parent is not
# <root>/.gauntlet or <root>/.deep-review. The hook sources nothing authored.

# No `set -e`: every step below handles its own failure. The EXIT trap is what
# guarantees the exit-0 contract, whatever happens (including an unbound
# variable under `set -u`).
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIFF_TMP=""
CLEANUP=0
CLEANUP_PATHS=()

# Test-only overrides are honoured only under SKEIN_REPORT_TEST=1, so a stray
# environment variable can never swap the renderer or pin the timestamp.
TEST_MODE=0
[[ "${SKEIN_REPORT_TEST:-}" == "1" ]] && TEST_MODE=1

warn() {
	printf 'report-hook: warning: %s\n' "$*" >&2
}

# shellcheck disable=SC2317,SC2329  # invoked indirectly through the EXIT trap
cleanup() {
	[[ -n "$DIFF_TMP" ]] && rm -f "$DIFF_TMP"
	if [[ "$CLEANUP" -eq 1 ]]; then
		local p
		for p in ${CLEANUP_PATHS[@]+"${CLEANUP_PATHS[@]}"}; do
			cleanup_scratch "$p"
		done
	fi
	exit 0
}
trap cleanup EXIT

# norm_path <path> — absolutise against $PWD (no symlink resolution), collapse
# runs of `/`, and drop a trailing `/`.
norm_path() {
	local p="$1"
	[[ "$p" == /* ]] || p="$PWD/$p"
	while [[ "$p" == *//* ]]; do p="${p//\/\///}"; done
	while [[ "$p" == */ && "$p" != "/" ]]; do p="${p%/}"; done
	printf '%s' "$p"
}

has_dotdot() {
	case "/$1/" in
	*/../*) return 0 ;;
	*) return 1 ;;
	esac
}

# cleanup_scratch <path> — delete one scratch input named by --cleanup, only
# when it is a regular non-symlink `skein-report-*` file directly inside the
# system temp dir. Anything else is left in place with a warning.
# shellcheck disable=SC2317,SC2329  # invoked indirectly through cleanup (EXIT trap)
cleanup_scratch() {
	local p="$1" p_n tmp_n
	[[ -n "$p" ]] || return 0
	tmp_n="$(norm_path "${TMPDIR:-/tmp}")"
	p_n="$(norm_path "$p")"
	if has_dotdot "$p" || [[ "${p_n%/*}" != "$tmp_n" || "${p_n##*/}" != skein-report-* ]]; then
		warn "--cleanup: not deleting $p (only skein-report-* files directly in $tmp_n)"
		return 0
	fi
	if [[ -L "$p_n" || ! -f "$p_n" ]]; then
		[[ -e "$p_n" || -L "$p_n" ]] || return 0
		warn "--cleanup: not deleting $p (not a regular file)"
		return 0
	fi
	rm -f -- "$p_n" || warn "--cleanup: could not delete $p"
}

# prescan_cleanup <args...> — record --cleanup and the scratch inputs before
# the real parse, so a parse that stops early still cleans up.
prescan_cleanup() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--cleanup)
			CLEANUP=1
			shift
			;;
		--envelope | --suppress-keys)
			[[ $# -ge 2 ]] || return 0
			CLEANUP_PATHS+=("$2")
			shift 2
			;;
		--root | --out | --base | --head | --ledger | --round)
			[[ $# -ge 2 ]] || return 0
			shift 2
			;;
		*) shift ;;
		esac
	done
}

# first_layer_guard <root> <out> — 0 when the output path may be written.
first_layer_guard() {
	local root="$1" out="$2" root_n out_n parent
	if [[ -z "$root" || -z "$out" ]]; then
		warn "--root and --out are required; skipping the report"
		return 1
	fi
	if has_dotdot "$root" || has_dotdot "$out"; then
		warn "refusing a path containing '..' (root=$root out=$out); skipping the report"
		return 1
	fi
	root_n="$(norm_path "$root")"
	out_n="$(norm_path "$out")"
	parent="${out_n%/*}"
	if [[ "$parent" != "$root_n/.gauntlet" && "$parent" != "$root_n/.deep-review" ]]; then
		warn "refusing --out $out: its parent must be <root>/.gauntlet or <root>/.deep-review; skipping the report"
		return 1
	fi
	if [[ ! -f "$HOOK_DIR/lib/auto-fix-common.sh" ]]; then
		warn "bundled lib/auto-fix-common.sh is missing next to the hook; skipping the report"
		return 1
	fi
	# Subshell: the lib sets `set -euo pipefail` and readonly variables.
	if ! (
		# shellcheck source=scripts/lib/auto-fix-common.sh disable=SC1091
		. "$HOOK_DIR/lib/auto-fix-common.sh" &&
			af_assert_no_symlink "$out_n" "$root_n"
	); then
		warn "symlink guard refused $out; skipping the report"
		return 1
	fi
	return 0
}

# capture_diff_stat <root> <base> <head> — set DIFF_TMP to a mktemp file holding
# a header line plus `git diff --stat`. A git failure still yields a file, with
# mode=failed, so the report can say why the scope is unavailable.
capture_diff_stat() {
	local root="$1" base="$2" head="$3" now tmp_root mode="range"
	now=""
	[[ "$TEST_MODE" -eq 1 ]] && now="${SKEIN_REPORT_NOW:-}"
	[[ -n "$now" ]] || now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	tmp_root="${TMPDIR:-/tmp}"
	if ! DIFF_TMP="$(mktemp "${tmp_root%/}/skein-report-diffstat.XXXXXX")"; then
		DIFF_TMP=""
		warn "could not create a scratch file; the report will say the diff scope is unavailable"
		return 0
	fi
	local stat_out=""
	if [[ ! "$base" =~ ^[0-9a-fA-F]{4,64}$ || ! "$head" =~ ^[0-9a-fA-F]{4,64}$ ]]; then
		mode="failed"
		warn "--base/--head must be commit ids; the report will say the diff scope is unavailable"
	elif ! stat_out="$(git -C "$root" diff --no-color --stat=200 "${base}...${head}" -- 2>/dev/null)"; then
		mode="failed"
		stat_out=""
		warn "git diff --stat ${base}...${head} failed; the report will say the diff scope is unavailable"
	fi
	{
		printf '# diff-stat mode=%s base=%s head=%s time=%s\n' "$mode" "$base" "$head" "$now"
		[[ -z "$stat_out" ]] || printf '%s\n' "$stat_out"
	} >"$DIFF_TMP"
}

main() {
	local root="" out="" base="" head="" arg
	local -a pass_args=()

	prescan_cleanup "$@"
	while [[ $# -gt 0 ]]; do
		arg="$1"
		case "$arg" in
		--cleanup)
			shift
			;;
		--root | --out | --base | --head | --ledger | --round | --envelope | --suppress-keys)
			if [[ $# -lt 2 ]]; then
				warn "$arg needs a value; skipping the report"
				return 0
			fi
			case "$arg" in
			--root) root="$2" ;;
			--out) out="$2" ;;
			--base) base="$2" ;;
			--head) head="$2" ;;
			*) pass_args+=("$arg" "$2") ;;
			esac
			shift 2
			;;
		*)
			warn "unknown argument $arg; skipping the report"
			return 0
			;;
		esac
	done

	if ! command -v python3 >/dev/null 2>&1; then
		warn "python3 not found; skipping the report"
		return 0
	fi

	first_layer_guard "$root" "$out" || return 0
	# A latest-run pathname must never keep showing an older report when this
	# invocation cannot produce a replacement.
	if [[ -e "$out" ]] && ! rm -f -- "$out"; then
		warn "could not invalidate the existing report $out; skipping the report"
		return 0
	fi

	if ! git -C "$root" check-ignore -q -- "$out" 2>/dev/null; then
		warn "$out is not git-ignored (or git could not check it); do not commit the report"
	fi

	if [[ -n "$base" && -n "$head" ]]; then
		capture_diff_stat "$root" "$base" "$head"
		[[ -z "$DIFF_TMP" ]] || pass_args+=(--diff-stat "$DIFF_TMP")
	elif [[ -n "$base" || -n "$head" ]]; then
		warn "--base and --head must be given together; the report will say the diff scope is unavailable"
	fi

	local rc=0
	if [[ "$TEST_MODE" -eq 1 && -n "${SKEIN_REPORT_RENDERER:-}" ]]; then
		"$SKEIN_REPORT_RENDERER" ${pass_args[@]+"${pass_args[@]}"} --root "$root" --out "$out" || rc=$?
	else
		python3 "$HOOK_DIR/render-report.py" ${pass_args[@]+"${pass_args[@]}"} --root "$root" --out "$out" || rc=$?
	fi
	if [[ "$rc" -ne 0 ]]; then
		warn "renderer failed (exit $rc); the report was not written"
		return 0
	fi
	printf 'report written: %s\n' "$out"
	return 0
}

main "$@" || true
exit 0
