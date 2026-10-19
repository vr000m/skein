#!/usr/bin/env bash
# Reviewed-base contract: PR, bare and three-dot targets resolve a merge base;
# two-dot keeps its literal left endpoint. The resolver diffs base..head.
# shellcheck disable=SC1090,SC1091,SC2016,SC2030,SC2031,SC2034,SC2154

set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
CODEX_MD="$ROOT_DIR/plugins/skein-codex/skills/review-gauntlet/SKILL.md"
CLAUDE_MD="$ROOT_DIR/plugins/skein/skills/review-gauntlet/SKILL.md"
CODEX_SKILL_DIR="$ROOT_DIR/plugins/skein-codex/skills/review-gauntlet"
CLAUDE_PLUGIN_ROOT="$ROOT_DIR/plugins/skein"
RESOLVER="$CODEX_SKILL_DIR/lib/resolve-plan.sh"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/skein-pr-base.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

pass_count=0
fail_count=0

pass() {
	echo "PASS: $1"
	pass_count=$((pass_count + 1))
}

fail() {
	echo "FAIL: $1"
	fail_count=$((fail_count + 1))
}

extract_function() {
	local source="$1" name="$2" out="$3"
	sed -n "/^${name}() {$/,/^}$/p" "$source" >"$out"
	[[ -s "$out" ]] && grep -q '^}$' "$out"
}

CODEX_SCOPE_FN="$WORKDIR/codex-scope.sh"
CLAUDE_SCOPE_FN="$WORKDIR/claude-scope.sh"
CODEX_SINK_FN="$WORKDIR/codex-sink.sh"
CLAUDE_SINK_FN="$WORKDIR/claude-sink.sh"
extract_function "$CODEX_MD" resolve_review_scope "$CODEX_SCOPE_FN" || {
	echo "FAIL: could not extract Codex resolve_review_scope"
	exit 1
}
extract_function "$CODEX_MD" run_design_delta_sink "$CODEX_SINK_FN" || {
	echo "FAIL: could not extract Codex run_design_delta_sink"
	exit 1
}
if ! extract_function "$CLAUDE_MD" resolve_review_scope "$CLAUDE_SCOPE_FN"; then
	: >"$CLAUDE_SCOPE_FN"
fi
extract_function "$CLAUDE_MD" run_design_delta_sink "$CLAUDE_SINK_FN" || {
	echo "FAIL: could not extract Claude run_design_delta_sink"
	exit 1
}

git_config() {
	git -C "$1" config user.name test
	git -C "$1" config user.email test@example.invalid
	git -C "$1" config commit.gpgsign false
}

write_plan() {
	local path="$1" title="$2"
	printf '# %s\n\n<!-- reviewed: 2026-10-18 @ aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa -->\n\n## Findings\n\nNone.\n' \
		"$title" >"$path"
}

make_fixture() {
	local repo="$1" movement="$2" empty_tree disconnected
	mkdir -p "$repo/docs/dev_plans"
	git -C "$repo" init -q -b main
	git_config "$repo"
	printf 'base\n' >"$repo/README.md"
	write_plan "$repo/docs/dev_plans/20261018-base-only-plan.md" Base-original
	git -C "$repo" add README.md docs/dev_plans/20261018-base-only-plan.md
	git -C "$repo" commit -qm base
	git -C "$repo" switch -qc feature/topic
	write_plan "$repo/docs/dev_plans/20261018-right-plan.md" Right
	git -C "$repo" add docs/dev_plans/20261018-right-plan.md
	git -C "$repo" commit -qm right-plan
	git -C "$repo" switch -q main
	case "$movement" in
	unmoved) ;;
	advanced-plan)
		write_plan "$repo/docs/dev_plans/20261018-base-only-plan.md" Base-advanced
		git -C "$repo" add docs/dev_plans/20261018-base-only-plan.md
		git -C "$repo" commit -qm base-plan
		;;
	advanced-unrelated)
		printf 'advanced\n' >>"$repo/README.md"
		git -C "$repo" add README.md
		git -C "$repo" commit -qm base-unrelated
		;;
	esac
	git -C "$repo" update-ref refs/remotes/origin/main "$(git -C "$repo" rev-parse main)"
	git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
	empty_tree="$(git -C "$repo" mktree </dev/null)"
	disconnected="$(printf 'disconnected\n' | git -C "$repo" commit-tree "$empty_tree")"
	git -C "$repo" update-ref refs/heads/disconnected "$disconnected"
	git -C "$repo" switch -q feature/topic
}

gh() {
	printf '{"baseRefOid":"%s","headRefOid":"%s","headRefName":"feature/topic"}\n' "$GH_BASE" "$GH_HEAD"
}

scope_cell() {
	local fn="$1" target_kind="$2" movement="$3" object_state="$4"
	local repo="$WORKDIR/matrix-${target_kind}-${movement}-${object_state}-$RANDOM"
	local fork main_tip head disconnected missing target expected actual
	make_fixture "$repo" "$movement"
	fork="$(git -C "$repo" merge-base main feature/topic)"
	main_tip="$(git -C "$repo" rev-parse main)"
	head="$(git -C "$repo" rev-parse feature/topic)"
	disconnected="$(git -C "$repo" rev-parse disconnected)"
	missing=1111111111111111111111111111111111111111
	case "$object_state" in
	local)
		GH_BASE="$main_tip"
		expected="$fork"
		;;
	missing)
		GH_BASE="$missing"
		expected=""
		;;
	merge-fails)
		GH_BASE="$disconnected"
		expected=""
		;;
	esac
	GH_HEAD="$head"
	case "$target_kind" in
	pr) target=pr:42 ;;
	bare)
		target=branch:feature/topic
		if [[ "$object_state" == missing ]]; then
			git -C "$repo" symbolic-ref -d refs/remotes/origin/HEAD
			git -C "$repo" update-ref -d refs/remotes/origin/main
			git -C "$repo" update-ref -d refs/heads/main
		elif [[ "$object_state" == merge-fails ]]; then
			git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/heads/disconnected
		fi
		;;
	three-dot)
		case "$object_state" in
		local) target=branch:main...feature/topic ;;
		missing) target=branch:missing...feature/topic ;;
		merge-fails) target=branch:disconnected...feature/topic ;;
		esac
		;;
	two-dot)
		case "$object_state" in
		local)
			target=branch:main..feature/topic
			expected="$main_tip"
			;;
		missing)
			target=branch:missing..feature/topic
			expected=""
			;;
		merge-fails)
			target=branch:disconnected..feature/topic
			expected="$disconnected"
			;;
		esac
		;;
	esac
	actual="$({
		cd "$repo"
		canonical_target="$target"
		. "$fn"
		resolve_review_scope
		printf '%s\n' "$resolved_base_oid"
	})"
	[[ "$actual" == "$expected" ]]
}

run_matrix() {
	local fn="$1" label="$2" target movement objects
	for target in pr bare three-dot two-dot; do
		for movement in unmoved advanced-plan advanced-unrelated; do
			for objects in local missing merge-fails; do
				if ! scope_cell "$fn" "$target" "$movement" "$objects"; then
					fail "$label reviewed-base cell target=$target base=$movement objects=$objects"
					return 1
				fi
			done
		done
	done
	pass "$label reviewed-base 4x3x3 state space"
}

run_matrix "$CODEX_SCOPE_FN" Codex || true
if [[ -s "$CLAUDE_SCOPE_FN" ]]; then
	run_matrix "$CLAUDE_SCOPE_FN" Claude || true
else
	fail "Claude reviewed-base producer block awaits conductor mirror"
fi

# Real diff fixture: a base-only plan after the fork makes base-tip..head
# ambiguous, while merge-base..head selects the PR's one changed plan.
resolver_repo="$WORKDIR/resolver"
make_fixture "$resolver_repo" advanced-plan
fork="$(git -C "$resolver_repo" merge-base main feature/topic)"
main_tip="$(git -C "$resolver_repo" rev-parse main)"
head="$(git -C "$resolver_repo" rev-parse feature/topic)"
good_json="$($RESOLVER --repo-root "$resolver_repo" --base "$fork" --head "$head" --branch feature/topic)"
tip_json="$($RESOLVER --repo-root "$resolver_repo" --base "$main_tip" --head "$head" --branch feature/topic)"
if jq -e '.status == "unique" and .plan == "docs/dev_plans/20261018-right-plan.md"' <<<"$good_json" >/dev/null &&
	jq -e '.status == "ambiguous"' <<<"$tip_json" >/dev/null; then
	pass "resolver uses merge-base..head; base-tip mutation is ambiguous"
else
	fail "resolver merge-base fixture or base-tip mutation"
fi

mutant="$WORKDIR/scope-mutant.sh"
sed 's/merge-base --end-of-options "$pr_base_oid" "$resolved_head_oid"/rev-parse --verify --quiet --end-of-options "${pr_base_oid}^{commit}"/' \
	"$CODEX_SCOPE_FN" >"$mutant"
if scope_cell "$mutant" pr advanced-plan local; then
	fail "mutation using PR base tip survived the advanced-base cell"
else
	pass "advanced-base cell catches the PR base-tip mutation"
fi

write_round() {
	local dir="$1"
	mkdir -p "$dir/round-1"
	jq -cn '{claimed:[],design_deltas:[{file:"lib/a.sh",summary:"merge-base-delta",decision:"d",rationale:"r",cells:"c"}]}' \
		>"$dir/round-1/fixer-report.json"
}

sink_advanced_cell() {
	local sink_fn="$1" harness="$2" repo
	local base_tip head ledger_path run_dir plan
	repo="$WORKDIR/sink-${harness}-$RANDOM"
	make_fixture "$repo" advanced-plan
	base_tip="$(git -C "$repo" rev-parse main)"
	head="$(git -C "$repo" rev-parse feature/topic)"
	plan="$repo/docs/dev_plans/20261018-right-plan.md"
	GH_BASE="$base_tip"
	GH_HEAD="$head"
	(
		cd "$repo"
		if [[ "$harness" == codex ]]; then
			SKILL_DIR="$CODEX_SKILL_DIR"
			. "$CODEX_SKILL_DIR/lib/gauntlet-common.sh"
		else
			export CLAUDE_PLUGIN_ROOT
			. "$CLAUDE_PLUGIN_ROOT/skills/review-gauntlet/lib/gauntlet-common.sh"
		fi
		. "$sink_fn"
		canonical_target=pr:42
		ledger_path="$(gc_ledger_path "$canonical_target" "$harness")"
		if [[ "$harness" == codex ]]; then
			"$CODEX_SKILL_DIR/lib/convergence-ledger.sh" --init --ledger "$ledger_path" --target "$canonical_target" >/dev/null
			run_dir="$("$CODEX_SKILL_DIR/lib/convergence-ledger.sh" --run-dir --ledger "$ledger_path")"
		else
			"$CLAUDE_PLUGIN_ROOT/skills/review-gauntlet/lib/convergence-ledger.sh" --init --ledger "$ledger_path" --target "$canonical_target" >/dev/null
			run_dir="$("$CLAUDE_PLUGIN_ROOT/skills/review-gauntlet/lib/convergence-ledger.sh" --run-dir --ledger "$ledger_path")"
		fi
		jq '.rounds = [{}]' "$ledger_path" >"$ledger_path.tmp"
		mv "$ledger_path.tmp" "$ledger_path"
		write_round "$run_dir"
		PLAN_PATH=""
		run_design_delta_sink
	) >"$repo/sink.out" 2>"$repo/sink.err"
	grep -Fq 'Summary: "merge-base-delta"' "$plan" &&
		! find "$repo/.gauntlet" -maxdepth 1 -name 'design-deltas-*.md' -print -quit | grep -q .
}

sink_sidecar_cell() {
	local sink_fn="$1" object_state="$2" repo
	local head ledger_path run_dir plan sidecar
	repo="$WORKDIR/sink-sidecar-${object_state}-$RANDOM"
	make_fixture "$repo" advanced-plan
	head="$(git -C "$repo" rev-parse feature/topic)"
	plan="$repo/docs/dev_plans/20261018-right-plan.md"
	case "$object_state" in
	missing) GH_BASE=1111111111111111111111111111111111111111 ;;
	merge-fails) GH_BASE="$(git -C "$repo" rev-parse disconnected)" ;;
	esac
	GH_HEAD="$head"
	(
		cd "$repo"
		SKILL_DIR="$CODEX_SKILL_DIR"
		. "$CODEX_SKILL_DIR/lib/gauntlet-common.sh"
		. "$sink_fn"
		canonical_target=pr:42
		ledger_path="$(gc_ledger_path "$canonical_target" codex)"
		"$CODEX_SKILL_DIR/lib/convergence-ledger.sh" --init --ledger "$ledger_path" --target "$canonical_target" >/dev/null
		run_dir="$("$CODEX_SKILL_DIR/lib/convergence-ledger.sh" --run-dir --ledger "$ledger_path")"
		jq '.rounds = [{}]' "$ledger_path" >"$ledger_path.tmp"
		mv "$ledger_path.tmp" "$ledger_path"
		write_round "$run_dir"
		PLAN_PATH=""
		run_design_delta_sink
	) >"$repo/sink.out" 2>"$repo/sink.err"
	sidecar="$(find "$repo/.gauntlet" -maxdepth 1 -name 'design-deltas-*.md' -print -quit)"
	[[ -n "$sidecar" ]] && grep -Fq 'Summary: "merge-base-delta"' "$sidecar" &&
		! grep -Fq 'Summary: "merge-base-delta"' "$plan"
}

if sink_advanced_cell "$CODEX_SINK_FN" codex; then
	pass "Codex PR sink resolves the merge base after a plan-touching base advance"
else
	fail "Codex PR sink advanced-base resolution"
fi
for object_state in missing merge-fails; do
	if sink_sidecar_cell "$CODEX_SINK_FN" "$object_state"; then
		pass "Codex PR sink routes $object_state base state to the sidecar"
	else
		fail "Codex PR sink $object_state sidecar fallback"
	fi
done
if sink_advanced_cell "$CLAUDE_SINK_FN" claude; then
	pass "Claude PR sink resolves the merge base after a plan-touching base advance"
else
	fail "Claude PR sink still uses baseRefOid tip; conductor mirror required"
fi

echo
echo "$pass_count passed, $fail_count failed"
[[ "$fail_count" -eq 0 ]]
