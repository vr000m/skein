#!/usr/bin/env bash
# Resolve the development plan associated with a review-gauntlet run.
# shellcheck disable=SC2016  # jq programs use jq variables, not shell variables.

set -euo pipefail

usage() {
	echo "usage: resolve-plan.sh --repo-root <dir> --base <ref> --branch <name> [--head <ref>] [--plan <path>]" >&2
}

die_usage() {
	echo "resolve-plan: $1" >&2
	usage
	exit 1
}

die_env() {
	echo "resolve-plan: $1" >&2
	exit 2
}

REPO_ROOT=""
BASE=""
BRANCH=""
BRANCH_SEEN=0
HEAD="HEAD"
PLAN=""
PLAN_SEEN=0

while [[ $# -gt 0 ]]; do
	case "$1" in
	--repo-root | --base | --branch | --head | --plan)
		flag="$1"
		shift
		[[ $# -gt 0 ]] || die_usage "$flag requires a value"
		case "$flag" in
		--repo-root) REPO_ROOT="$1" ;;
		--base) BASE="$1" ;;
		--branch)
			BRANCH="$1"
			BRANCH_SEEN=1
			;;
		--head) HEAD="$1" ;;
		--plan)
			PLAN="$1"
			PLAN_SEEN=1
			;;
		esac
		;;
	-h | --help)
		usage
		exit 1
		;;
	*) die_usage "unknown argument: $1" ;;
	esac
	shift
done

[[ -n "$REPO_ROOT" ]] || die_usage "--repo-root is required"
[[ -n "$BASE" ]] || die_usage "--base is required"
[[ "$BRANCH_SEEN" -eq 1 ]] || die_usage "--branch is required"
[[ -n "$HEAD" ]] || die_usage "--head requires a non-empty ref"

GIT="$(command -v git || true)"
JQ="$(command -v jq || true)"
[[ -n "$GIT" && -x "$GIT" ]] || die_env "git is required"
[[ -n "$JQ" && -x "$JQ" ]] || die_env "jq is required"
[[ -d "$REPO_ROOT" ]] || die_env "repo root is not a directory: $REPO_ROOT"

REPO_ROOT="$(cd "$REPO_ROOT" 2>/dev/null && pwd -P)" || die_env "cannot resolve repo root"
git_root="$($GIT -C "$REPO_ROOT" rev-parse --show-toplevel 2>/dev/null)" || die_env "repo root is not a git worktree"
git_root="$(cd "$git_root" 2>/dev/null && pwd -P)" || die_env "cannot resolve git worktree root"
[[ "$git_root" == "$REPO_ROOT" ]] || die_env "repo root is not the git worktree root"

emit() {
	local status="$1" plan="$2" reason="$3"
	"$JQ" -cn --arg status "$status" --arg plan "$plan" --arg reason "$reason" \
		'{status:$status,plan:$plan,reason:$reason}'
}

has_parent_component() {
	case "/$1/" in
	*/../*) return 0 ;;
	*) return 1 ;;
	esac
}

regular_nonsymlink_file() {
	local path="$1" rel="$2" found current part
	local -a parts
	[[ -f "$path" ]] || return 1
	current="$REPO_ROOT"
	IFS='/' read -r -a parts <<<"$rel"
	for part in "${parts[@]}"; do
		current="$current/$part"
		# find -P classifies each named component without following a symlink leaf.
		found="$(find -P "$current" -prune -type l -print 2>/dev/null || true)"
		[[ -z "$found" ]] || return 1
	done
	found="$(find -P "$path" -prune -type f -print 2>/dev/null || true)"
	[[ "$found" == "$path" ]]
}

normalize_explicit_plan() {
	local input="$1" rel abs
	[[ -n "$input" ]] || return 1
	has_parent_component "$input" && return 1
	if [[ "$input" == /* ]]; then
		case "$input" in
		"$REPO_ROOT"/*) rel="${input#"$REPO_ROOT"/}" ;;
		*) return 1 ;;
		esac
	else
		rel="${input#./}"
	fi
	[[ -n "$rel" && "$rel" != /* ]] || return 1
	has_parent_component "$rel" && return 1
	abs="$REPO_ROOT/$rel"
	regular_nonsymlink_file "$abs" "$rel" || return 1
	printf '%s\n' "$rel"
}

if [[ "$PLAN_SEEN" -eq 1 ]]; then
	explicit_plan="$(normalize_explicit_plan "$PLAN")" || die_usage "--plan must name a regular non-symlink file inside repo root without '..'"
	emit explicit "$explicit_plan" "explicit plan"
	exit 0
fi

if ! base_oid="$($GIT -C "$REPO_ROOT" rev-parse --verify --quiet "$BASE^{commit}")"; then
	emit none "" "base ref not found"
	exit 0
fi
if ! head_oid="$($GIT -C "$REPO_ROOT" rev-parse --verify --quiet "$HEAD^{commit}")"; then
	emit none "" "head ref not found"
	exit 0
fi

is_plan_candidate() {
	[[ "$1" =~ ^docs/dev_plans/[0-9]{8}-[^/]+\.md$ ]]
}

slug="$(printf '%s' "$BRANCH" | tr '[:upper:]' '[:lower:]')"
slug="$(printf '%s' "$slug" | sed -E 's#^(feature|bug|fix|chore|docs)/##')"

filter_slug() {
	local candidate name lower stem
	for candidate in "$@"; do
		name="${candidate##*/}"
		lower="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
		stem="${lower%.md}"
		if [[ -n "$slug" && "-$stem-" == *"-$slug-"* ]]; then
			printf '%s\n' "$candidate"
		fi
	done
}

diff_candidates=()
diff_succeeded=0
while IFS= read -r -d '' candidate; do
	if [[ -z "$candidate" ]]; then
		diff_succeeded=1
		continue
	fi
	is_plan_candidate "$candidate" && diff_candidates+=("$candidate")
done < <(
	if "$GIT" -C "$REPO_ROOT" -c core.quotepath=false diff --name-only -z --diff-filter=d "$base_oid"..."$head_oid" 2>/dev/null; then
		# Git cannot emit an empty pathname. A second NUL after its final path is
		# therefore an unambiguous success record that survives process substitution.
		printf '\0'
	fi
)
[[ "$diff_succeeded" -eq 1 ]] || die_env "cannot diff base '$BASE' against head '$HEAD'"

if [[ "${#diff_candidates[@]}" -eq 1 ]]; then
	emit unique "${diff_candidates[0]}" "one changed plan"
	exit 0
fi

if [[ "${#diff_candidates[@]}" -gt 1 ]]; then
	narrowed=()
	while IFS= read -r line; do
		if [[ -n "$line" ]]; then
			narrowed+=("$line")
		fi
	done < <(filter_slug ${diff_candidates[@]+"${diff_candidates[@]}"})
	if [[ "${#narrowed[@]}" -eq 1 ]]; then
		emit unique "${narrowed[0]}" "branch slug matched one changed plan"
	else
		emit ambiguous "" "multiple changed plans"
	fi
	exit 0
fi

emit none "" "no changed plan"
