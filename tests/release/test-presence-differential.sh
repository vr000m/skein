#!/usr/bin/env bash
# Differential test (round-3 architecture fix 9, lighter alternative chosen
# over a full factoring refactor — self-classified `local`). Step 1b's
# presence oracle is implemented twice with different architectures:
# read-release-template.sh decides from a table over injected argv facts
# (worktree/head-commit/mode); resolve-template-marker.sh's
# resolve_current_template() re-derives the same items 2/3 by probing git
# directly against a real repo (Audit A2's marker-absent fallback). SKILL.md's
# marker-absent fallback claims these are "the same Step 1b items 2, 3 and 4
# gates" — a claim maintained only by hand today. This test builds a real git
# repo for each tests/release/fixtures/presence/state-*.json fixture and runs
# BOTH implementations against it, asserting they classify each state the
# same way (ABSENT vs INVALID); it does not cover item 4 (jq validation),
# which none of these four states reach on either implementation.

# `A && pass || bad` is the suite idiom; pass never fails.
# shellcheck disable=SC2015
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
LIB="${RELEASE_LIB_DIR:-$ROOT/plugins/skein/skills/release/lib}"
FIX="$HERE/fixtures"
# shellcheck source=tests/release/lib.sh disable=SC1091
. "$HERE/lib.sh"

fail=0
pass() { echo "PASS: $1"; }
bad() {
	echo "FAIL: $1" >&2
	fail=1
}

real() { python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$(command -v "$1")"; }
JQ_REAL="$(real jq)"
GIT_REAL="$(real git)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/skein-presence-diff.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

TPL_CONTENT='{"title_format":"canonical"}'

# build_state <state> <dest> — construct a real git repo matching that
# state's presence facts (fixtures/presence/state-<state>.json). Prints HEAD.
build_state() {
	local state="$1" dest="$2"
	(
		release_git_env
		"$GIT_REAL" -c commit.gpgsign=false init -q --object-format=sha1 -b main "$dest" || exit 1
		printf '# Changelog\n' >"$dest/CHANGELOG.md"
		"$GIT_REAL" -C "$dest" add CHANGELOG.md
		GIT_AUTHOR_DATE="2026-01-01T00:00:00Z" GIT_COMMITTER_DATE="2026-01-01T00:00:00Z" \
			"$GIT_REAL" -C "$dest" -c commit.gpgsign=false commit -q --no-verify -m "base" || exit 1
		case "$state" in
		i) : ;; # never committed, never in the worktree
		ii)
			printf '%s' "$TPL_CONTENT" >"$dest/.release-template.json"
			"$GIT_REAL" -C "$dest" add .release-template.json
			GIT_AUTHOR_DATE="2026-01-02T00:00:00Z" GIT_COMMITTER_DATE="2026-01-02T00:00:00Z" \
				"$GIT_REAL" -C "$dest" -c commit.gpgsign=false commit -q --no-verify -m "add template" || exit 1
			rm "$dest/.release-template.json" # uncommitted worktree deletion
			;;
		iii)
			printf '%s' "$TPL_CONTENT" >"$dest/.release-template.json" # never `git add`
			;;
		iv)
			printf '%s' "$TPL_CONTENT" >"$dest/.release-template.json"
			"$GIT_REAL" -C "$dest" add .release-template.json
			GIT_AUTHOR_DATE="2026-01-02T00:00:00Z" GIT_COMMITTER_DATE="2026-01-02T00:00:00Z" \
				"$GIT_REAL" -C "$dest" -c commit.gpgsign=false commit -q --no-verify -m "add template" || exit 1
			printf '%s' '{"title_format":"bare"}' >"$dest/.release-template.json" # dirty vs HEAD
			;;
		*)
			echo "unknown state: $state" >&2
			exit 2
			;;
		esac
	) || return 1
	"$GIT_REAL" -C "$dest" rev-parse HEAD
}

# normalize_read <decision> <exit-code> — read-release-template.sh's
# vocabulary, collapsed to the shared ABSENT|INVALID|OTHER classification.
normalize_read() {
	case "$1:$2" in
	absent-noop:0) echo ABSENT ;;
	precondition-failed:1) echo INVALID ;;
	*) echo "OTHER($1:$2)" ;;
	esac
}

# normalize_resolve <row-status> — resolve_current_template() is exercised
# ONLY through a2-classify (step3-recovery's own markerless path short-circuits
# straight to the no-template sentinel without ever calling it — see
# resolve_source's `[[ "$site" == "step3-recovery" ]]` branch — so this
# differential test drives the site the finding is actually about). A
# `template-marker-unresolvable` row is CUR_STATE=invalid; `ok`/`drifted` both
# mean CUR_STATE=absent (fell through to the canonical-shape comparison) —
# neither of these four fixture states reaches CUR_STATE=valid.
normalize_resolve() {
	case "$1" in
	template-marker-unresolvable) echo INVALID ;;
	ok | drifted) echo ABSENT ;;
	*) echo "OTHER($1)" ;;
	esac
}

for s in i ii iii iv; do
	state_file="$FIX/presence/state-$s.json"
	wt="$("$JQ_REAL" -r '.worktree' "$state_file")"
	head="$("$JQ_REAL" -r '.head_commit' "$state_file")"
	mode="$("$JQ_REAL" -r '.mode // ""' "$state_file")"

	repo="$TMP/repo-$s"
	head_sha="$(build_state "$s" "$repo")" || {
		bad "state $s: repo build failed"
		continue
	}

	read_args=(--site step1b-validate --worktree "$wt" --head-commit "$head" --head-sha "$head_sha")
	[[ -n "$mode" ]] && read_args+=(--mode "$mode")
	read_out="$(RELEASE_JQ="$JQ_REAL" "$LIB/read-release-template.sh" "${read_args[@]}" </dev/null 2>/dev/null)"
	read_code=$?
	read_norm="$(normalize_read "$("$JQ_REAL" -r '.decision' <<<"$read_out")" "$read_code")"

	# Minimal a2-classify inputs: one markerless candidate, --tags/--peeled
	# irrelevant to marker resolution here (no marker in the body), a
	# CHANGELOG with nothing to match (the ok/drifted outcome is not what
	# this test checks — only whether the row falls through to the canonical
	# fallback (`ok`/`drifted`, i.e. CUR_STATE=absent) or fails closed
	# (`template-marker-unresolvable`, i.e. CUR_STATE=invalid)).
	bodies_dir="$TMP/bodies-$s"
	mkdir -p "$bodies_dir"
	printf 'no marker here\n' >"$bodies_dir/v9.9.9.md"
	printf '[{"tagName":"v9.9.9","name":"v9.9.9"}]' >"$TMP/list-$s.json"
	printf '["v9.9.9"]' >"$TMP/tags-$s.json"
	printf '{}' >"$TMP/peeled-$s.json"
	printf '# Changelog\n' >"$TMP/changelog-$s.md"
	resolve_out="$(RELEASE_JQ="$JQ_REAL" RELEASE_GIT="$GIT_REAL" "$LIB/resolve-template-marker.sh" \
		--site a2-classify --repo "$repo" --release-list "$TMP/list-$s.json" \
		--bodies-dir "$bodies_dir" --peeled "$TMP/peeled-$s.json" --tags "$TMP/tags-$s.json" \
		--changelog "$TMP/changelog-$s.md" --web-base-url "https://github.com/example/repo" \
		--head-sha "$head_sha" 2>/dev/null)"
	resolve_norm="$(normalize_resolve "$("$JQ_REAL" -r '.rows[0].status' <<<"$resolve_out")")"

	[[ "$read_norm" == "$resolve_norm" && "$read_norm" != OTHER* ]] &&
		pass "presence differential state $s: both implementations agree ($read_norm)" ||
		bad "presence differential state $s: read=$read_norm resolve=$resolve_norm (want equal, non-OTHER)"
done

exit "$fail"
