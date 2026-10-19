#!/usr/bin/env bash
# Whole-contract coverage for bounded sink evidence names and terminal sink
# input types. Executes the authored fence from both harness mirrors.
# shellcheck disable=SC2034  # PLAN_PATH is consumed by the sourced sink fence.

set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/skein-sink-state.XXXXXX")"
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

init_fixture() {
	local repo="$1"
	mkdir -p "$repo/docs/dev_plans"
	git -C "$repo" init -q -b main
	git -C "$repo" config user.name test
	git -C "$repo" config user.email test@example.invalid
	git -C "$repo" config commit.gpgsign false
	printf '# Plans\n' >"$repo/docs/dev_plans/README.md"
	git -C "$repo" add docs/dev_plans/README.md
	git -C "$repo" commit -qm base
	git -C "$repo" switch -qc feature/widget
	printf '# Plan\n\n## Objective\n\nx\n\n<!-- reviewed: 2026-10-16 @ aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa -->\n\n## Findings\n\nExisting.\n' \
		>"$repo/docs/dev_plans/20261016-feature-widget.md"
	git -C "$repo" add docs/dev_plans/20261016-feature-widget.md
	git -C "$repo" commit -qm plan
}

extract_sink() {
	local skill_md="$1" output="$2"
	sed -n '/^run_design_delta_sink() {$/,/^run_design_delta_sink || true$/p' "$skill_md" | sed '$d' >"$output"
	[[ -s "$output" ]] && grep -q '^}$' "$output"
}

run_sink_bounded() {
	local output="$1" error="$2" pid _attempt
	run_design_delta_sink >"$output" 2>"$error" &
	pid=$!
	for _attempt in $(seq 1 30); do
		if ! kill -0 "$pid" 2>/dev/null; then
			wait "$pid"
			return $?
		fi
		sleep 0.1
	done
	kill "$pid" 2>/dev/null || true
	wait "$pid" 2>/dev/null || true
	return 124
}

probe() {
	local author="$1" state="$2" mirror_root skill_dir lib sink repo base head long_stem output error
	case "$author" in
	claude)
		mirror_root="$ROOT_DIR/plugins/skein"
		skill_dir="$mirror_root/skills/review-gauntlet"
		export CLAUDE_PLUGIN_ROOT="$mirror_root"
		;;
	codex)
		skill_dir="$ROOT_DIR/plugins/skein-codex/skills/review-gauntlet"
		export SKILL_DIR="$skill_dir"
		;;
	esac
	lib="$skill_dir/lib"
	sink="$WORKDIR/sink-$author-$state.sh"
	extract_sink "$skill_dir/SKILL.md" "$sink"
	repo="$WORKDIR/$author-$state"
	init_fixture "$repo"
	base="$(git -C "$repo" rev-parse main)"
	head="$(git -C "$repo" rev-parse feature/widget)"
	output="$repo/sink.out"
	error="$repo/sink.err"
	(
		cd "$repo"
		# shellcheck source=/dev/null
		. "$lib/gauntlet-common.sh"
		# shellcheck source=/dev/null
		. "$sink"
		canonical_target=branch:feature/widget
		ledger_path="$(gc_ledger_path "$canonical_target" "$author")"
		"$lib/convergence-ledger.sh" --init --ledger "$ledger_path" --target "$canonical_target" \
			--review-base "$base" --review-head "$head" --review-branch feature/widget >/dev/null
		run_dir="$("$lib/convergence-ledger.sh" --run-dir --ledger "$ledger_path")"
		jq '.rounds = [{}]' "$ledger_path" >"$ledger_path.tmp"
		mv "$ledger_path.tmp" "$ledger_path"
		mkdir -p "$run_dir/round-1"
		jq -cn '{claimed:[],design_deltas:[{file:"lib/a.sh",summary:"state-contract-delta",decision:"d",rationale:"r",cells:"c"}]}' \
			>"$run_dir/round-1/fixer-report.json"
		PLAN_PATH=docs/dev_plans/20261016-feature-widget.md
		case "$state" in
		long-ledger)
			long_stem="$(printf 'l%.0s' $(seq 1 230))"
			mv "$ledger_path" "${ledger_path%/*}/$long_stem.json"
			ledger_path="${ledger_path%/*}/$long_stem.json"
			;;
		ledger-directory)
			rm "$ledger_path"
			mkdir "$ledger_path"
			;;
		ledger-fifo)
			rm "$ledger_path"
			mkfifo "$ledger_path"
			;;
		run-file)
			rm -rf "$run_dir"
			: >"$run_dir"
			;;
		run-missing) rm -rf "$run_dir" ;;
		esac
		run_sink_bounded "$output" "$error"
	)
	case "$state" in
	long-ledger)
		grep -Fq 'Summary: "state-contract-delta"' "$repo/docs/dev_plans/20261016-feature-widget.md" || return 1
		find "$repo/.gauntlet" -maxdepth 1 -name 'design-deltas-*' -exec basename {} \; |
			awk 'length($0) > 255 { exit 1 } END { if (NR == 0) exit 1 }'
		;;
	ledger-*) grep -Fq 'design delta ledger is not a readable regular file' "$error" ;;
	run-*) grep -Fq 'design delta run state is not a readable searchable directory' "$error" ;;
	esac
}

for author in codex claude; do
	for state in long-ledger ledger-directory ledger-fifo run-file run-missing; do
		if probe "$author" "$state"; then
			pass "$author $state"
		else
			fail "$author $state"
		fi
	done
done

echo
echo "$pass_count passed, $fail_count failed"
[[ "$fail_count" -eq 0 ]]
