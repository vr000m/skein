#!/usr/bin/env bash
# Executes the Codex SKILL.md terminal design-delta sink fence. Covers the
# persisted review scope, stable run identity, and guarded fixer-report reads.
# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2154  # extracted SKILL.md functions assign caller-owned state.

set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
SKILL_DIR="$ROOT_DIR/plugins/skein-codex/skills/review-gauntlet"
SKILL_MD="${SKILL_MD:-$SKILL_DIR/SKILL.md}"
LIB="$SKILL_DIR/lib"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/skein-sink-codex.XXXXXX")"
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

check() {
	local label="$1"
	shift
	if "$@"; then
		pass "$label"
	else
		fail "$label"
	fi
}

SINK_FN="$WORKDIR/sink-fn.sh"
sed -n '/^run_design_delta_sink() {$/,/^run_design_delta_sink || true$/p' "$SKILL_MD" | sed '$d' >"$SINK_FN"
if [[ ! -s "$SINK_FN" ]] || ! grep -q '^}$' "$SINK_FN"; then
	echo "FAIL: could not extract run_design_delta_sink from $SKILL_MD"
	exit 1
fi
QUICK_FN="$WORKDIR/quick-fn.sh"
sed -n '/^prepare_quick_design_delta_state() {$/,/^}$/p' "$SKILL_MD" >"$QUICK_FN"
if [[ ! -s "$QUICK_FN" ]] || ! grep -q '^}$' "$QUICK_FN"; then
	echo "FAIL: could not extract prepare_quick_design_delta_state from $SKILL_MD"
	exit 1
fi

PLAN_NAME=20261016-feature-widget.md

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
	printf '# Plan\n\n## Objective\n\nx\n\n<!-- reviewed: 2026-10-16 @ aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa -->\n\n## Findings\n\nExisting.\n\n## Progress\n\nDone.\n' \
		>"$repo/docs/dev_plans/$PLAN_NAME"
	git -C "$repo" add "docs/dev_plans/$PLAN_NAME"
	git -C "$repo" commit -qm plan
}

write_round() {
	local run_dir="$1" round="$2" summary="$3"
	mkdir -p "$run_dir/round-$round"
	jq -cn --arg summary "$summary" \
		'{claimed:[],design_deltas:[{file:"lib/a.sh",summary:$summary,decision:"d",rationale:"r",cells:"c"}]}' \
		>"$run_dir/round-$round/fixer-report.json"
}

hash_file() {
	shasum -a 256 "$1" | awk '{print $1}'
}

run_seam_sidecar_probe() {
	local sink_fn="$1" repo plan before base_oid reviewed_head sidecar
	repo="$WORKDIR/seam-sidecar-$RANDOM"
	init_fixture "$repo"
	plan="$repo/docs/dev_plans/$PLAN_NAME"
	before="$(hash_file "$plan")"
	base_oid="$(git -C "$repo" rev-parse main)"
	reviewed_head="$(git -C "$repo" rev-parse feature/widget)"
	(
		cd "$repo"
		# shellcheck source=/dev/null
		. "$LIB/gauntlet-common.sh"
		# shellcheck source=/dev/null
		. "$sink_fn"
		canonical_target=branch:feature/widget
		ledger_path="$(gc_ledger_path "$canonical_target" codex)"
		"$LIB/convergence-ledger.sh" --init --ledger "$ledger_path" --target "$canonical_target" \
			--review-base "$base_oid" --review-head "$reviewed_head" --review-branch feature/widget >/dev/null
		run_dir="$("$LIB/convergence-ledger.sh" --run-dir --ledger "$ledger_path")"
		jq '.rounds = [{}]' "$ledger_path" >"$ledger_path.tmp"
		mv "$ledger_path.tmp" "$ledger_path"
		write_round "$run_dir" 1 seam-delta
		PLAN_PATH=""
		design_delta_sidecar_only=true
		run_design_delta_sink
	) >"$repo/seam.out" 2>"$repo/seam.err"
	sidecar="$(find "$repo/.gauntlet" -maxdepth 1 -name 'design-deltas-*.md' -print | head -1)"
	[[ "$before" == "$(hash_file "$plan")" ]] &&
		[[ -n "$sidecar" ]] && grep -Fq 'Summary: "seam-delta"' "$sidecar" &&
		grep -Fq 'Design deltas: .gauntlet/design-deltas-' "$repo/seam.out"
}

run_reset_failure_probe() {
	local sink_fn="$1" repo plan before base_oid reviewed_head
	repo="$WORKDIR/reset-failure-$RANDOM"
	init_fixture "$repo"
	plan="$repo/docs/dev_plans/$PLAN_NAME"
	before="$(hash_file "$plan")"
	base_oid="$(git -C "$repo" rev-parse main)"
	reviewed_head="$(git -C "$repo" rev-parse feature/widget)"
	(
		cd "$repo"
		# shellcheck source=/dev/null
		. "$LIB/gauntlet-common.sh"
		# shellcheck source=/dev/null
		. "$sink_fn"
		canonical_target=branch:feature/widget
		ledger_path="$(gc_ledger_path "$canonical_target" codex)"
		"$LIB/convergence-ledger.sh" --init --ledger "$ledger_path" --target "$canonical_target" \
			--review-base "$base_oid" --review-head "$reviewed_head" --review-branch feature/widget >/dev/null
		run_dir="$("$LIB/convergence-ledger.sh" --run-dir --ledger "$ledger_path")"
		jq '.rounds = [{}]' "$ledger_path" >"$ledger_path.tmp"
		mv "$ledger_path.tmp" "$ledger_path"
		write_round "$run_dir" 1 current-delta
		target_key="$(basename "${ledger_path%.json}")"
		state_dir="$(dirname "$ledger_path")"
		delta_items_file="$state_dir/design-deltas-$target_key.items.jsonl"
		jq -cn '{file:"stale",summary:"stale-delta",decision:"d",rationale:"r",cells:"c"}' >"$delta_items_file"
		chmod 400 "$delta_items_file"
		printf '[{"file":"stale","summary":"stale-array","decision":"d","rationale":"r","cells":"c"}]\n' \
			>"$state_dir/design-deltas-$target_key.deltas.json"
		printf '{"status":"unique","plan":"docs/dev_plans/%s","reason":"stale"}\n' "$PLAN_NAME" \
			>"$state_dir/design-deltas-$target_key.resolution.json"
		PLAN_PATH=""
		run_design_delta_sink
	) >"$repo/reset.out" 2>"$repo/reset.err"
	[[ "$before" == "$(hash_file "$plan")" ]] &&
		grep -Fq 'cannot initialize design delta collection' "$repo/reset.err" &&
		! grep -Eq 'stale-delta|stale-array|current-delta' "$plan"
}

run_invalid_round_count_probe() {
	local sink_fn="$1" repo base_oid reviewed_head
	repo="$WORKDIR/invalid-round-count-$RANDOM"
	init_fixture "$repo"
	base_oid="$(git -C "$repo" rev-parse main)"
	reviewed_head="$(git -C "$repo" rev-parse feature/widget)"
	(
		cd "$repo"
		# shellcheck source=/dev/null
		. "$LIB/gauntlet-common.sh"
		# shellcheck source=/dev/null
		. "$sink_fn"
		canonical_target=branch:feature/widget
		ledger_path="$(gc_ledger_path "$canonical_target" codex)"
		"$LIB/convergence-ledger.sh" --init --ledger "$ledger_path" --target "$canonical_target" \
			--review-base "$base_oid" --review-head "$reviewed_head" --review-branch feature/widget >/dev/null
		run_dir="$("$LIB/convergence-ledger.sh" --run-dir --ledger "$ledger_path")"
		jq '.rounds = "malformed"' "$ledger_path" >"$ledger_path.tmp"
		mv "$ledger_path.tmp" "$ledger_path"
		PLAN_PATH=""
		run_design_delta_sink
	) >"$repo/round-count.out" 2>"$repo/round-count.err"
	grep -Fq 'ledger round count is not an integer' "$repo/round-count.err" &&
		! grep -Fq 'Design deltas: none' "$repo/round-count.out"
}

run_quick_round_probe() {
	local quick_fn="$1" sink_fn="$2" repo plan base_oid reviewed_head ledger_run_id quick_a_hash quick_b_hash
	repo="$WORKDIR/quick-round-$RANDOM"
	init_fixture "$repo"
	plan="$repo/docs/dev_plans/$PLAN_NAME"
	base_oid="$(git -C "$repo" rev-parse main)"
	reviewed_head="$(git -C "$repo" rev-parse feature/widget)"
	(
		cd "$repo"
		# shellcheck source=/dev/null
		. "$LIB/gauntlet-common.sh"
		# shellcheck source=/dev/null
		. "$quick_fn"
		# shellcheck source=/dev/null
		. "$sink_fn"
		canonical_target=branch:feature/widget
		ledger_path="$(gc_ledger_path "$canonical_target" codex)"
		[[ ! -e "$ledger_path" ]]
		resolved_base_oid="$base_oid"
		resolved_head_oid="$reviewed_head"
		review_branch=feature/widget
		prepare_quick_design_delta_state
		[[ -f "$ledger_path" && -d "$run_dir" && "$round_n" -eq 1 ]]
		ledger_run_id="$(jq -r '.run_id' "$ledger_path")"
		write_round "$run_dir" "$round_n" quick-one
		quick_a_hash="$(gc_sha1 <"$run_dir/round-$round_n/fixer-report.json")"
		PLAN_PATH=""
		design_delta_quick_round="$round_n"
		run_design_delta_sink
		prepare_quick_design_delta_state
		write_round "$run_dir" "$round_n" quick-two
		quick_b_hash="$(gc_sha1 <"$run_dir/round-$round_n/fixer-report.json")"
		design_delta_quick_round="$round_n"
		run_design_delta_sink
		prepare_quick_design_delta_state
		write_round "$run_dir" "$round_n" quick-one
		design_delta_quick_round="$round_n"
		run_design_delta_sink
		jq -e '.rounds | length == 0' "$ledger_path" >/dev/null
		write_round "$run_dir" 1 full-one
		jq '.rounds = [{}]' "$ledger_path" >"$ledger_path.tmp"
		mv "$ledger_path.tmp" "$ledger_path"
		unset design_delta_quick_round
		run_design_delta_sink
		printf '%s\n%s\n%s\n' "$ledger_run_id" "$quick_a_hash" "$quick_b_hash" >"$repo/quick-run-id"
	) >"$repo/quick.out" 2>"$repo/quick.err"
	if [[ ! -f "$repo/quick-run-id" ]]; then
		sed -n '1,80p' "$repo/quick.err" >&2
		return 1
	fi
	ledger_run_id="$(sed -n '1p' "$repo/quick-run-id")"
	quick_a_hash="$(sed -n '2p' "$repo/quick-run-id")"
	quick_b_hash="$(sed -n '3p' "$repo/quick-run-id")"
	[[ "$quick_a_hash" != "$quick_b_hash" ]] &&
		[[ "$(grep -Fc "### Gauntlet design deltas (run codex-${ledger_run_id:0:12}-quick-${quick_a_hash:0:12})" "$plan")" -eq 1 ]] &&
		[[ "$(grep -Fc "### Gauntlet design deltas (run codex-${ledger_run_id:0:12}-quick-${quick_b_hash:0:12})" "$plan")" -eq 1 ]] &&
		[[ "$(grep -Fc "### Gauntlet design deltas (run codex-${ledger_run_id:0:12})" "$plan")" -eq 1 ]] &&
		[[ "$(grep -Fc 'Summary: "quick-one"' "$plan")" -eq 1 ]] &&
		[[ "$(grep -Fc 'Summary: "quick-two"' "$plan")" -eq 1 ]] &&
		[[ "$(grep -Fc 'Summary: "full-one"' "$plan")" -eq 1 ]] &&
		[[ "$(grep -Fc 'Design deltas: docs/dev_plans/' "$repo/quick.out")" -eq 4 ]]
}

# A resume after the reviewed branch moves must reuse the first sink call's
# immutable base/head scope and the ledger's stable run id.
repo="$WORKDIR/resume"
init_fixture "$repo"
base_oid="$(git -C "$repo" rev-parse main)"
reviewed_head="$(git -C "$repo" rev-parse feature/widget)"
(
	cd "$repo"
	# shellcheck source=/dev/null
	. "$LIB/gauntlet-common.sh"
	# shellcheck source=/dev/null
	. "$SINK_FN"
	canonical_target=branch:feature/widget
	ledger_path="$(gc_ledger_path "$canonical_target" codex)"
	"$LIB/convergence-ledger.sh" --init --ledger "$ledger_path" --target "$canonical_target" \
		--review-base "$base_oid" --review-head "$reviewed_head" --review-branch feature/widget >/dev/null
	run_dir="$("$LIB/convergence-ledger.sh" --run-dir --ledger "$ledger_path")"
	jq '.rounds = [{}]' "$ledger_path" >"$ledger_path.tmp"
	mv "$ledger_path.tmp" "$ledger_path"
	write_round "$run_dir" 1 first-delta
	PLAN_PATH=""
	ledger_run_id="$(jq -r '.run_id' "$ledger_path")"
	printf 'unrelated\n' >unrelated.txt
	git add unrelated.txt
	git commit -qm 'move reviewed branch'
	unset round_base round_head resolved_base_oid resolved_head_oid pr_head_ref
	run_design_delta_sink

	jq '.rounds += [{}]' "$ledger_path" >"$ledger_path.tmp"
	mv "$ledger_path.tmp" "$ledger_path"
	write_round "$run_dir" 2 second-delta
	run_design_delta_sink

	target_key="$(basename "${ledger_path%.json}")"
	scope_file="${ledger_path%/*}/design-deltas-$target_key-codex-${ledger_run_id:0:12}.scope.json"
	printf '%s\n' "$ledger_path" "$scope_file" >"$WORKDIR/resume-paths"
) >"$WORKDIR/resume.out" 2>"$WORKDIR/resume.err"

plan="$repo/docs/dev_plans/$PLAN_NAME"
ledger_path="$(sed -n '1p' "$WORKDIR/resume-paths")"
scope_file="$(sed -n '2p' "$WORKDIR/resume-paths")"
check "resume: the ledger run id survives appended rounds" bash -c '[[ "$(jq -r .run_id "$1")" =~ ^[0-9a-f]{20}$ ]]' _ "$ledger_path"
check "resume: ledger initialization owns the immutable reviewed head" bash -c '[[ "$(jq -r .review_scope.head_oid "$1")" == "$2" ]]' _ "$ledger_path" "$reviewed_head"
check "resume: persisted scope keeps the original reviewed head" bash -c '[[ "$(jq -r .head_oid "$1")" == "$2" ]]' _ "$scope_file" "$reviewed_head"
check "resume: first delta remains present once" bash -c '[[ "$(grep -Fc "Summary: \"first-delta\"" "$1")" -eq 1 ]]' _ "$plan"
check "resume: second delta is added to the same section" grep -Fq 'Summary: "second-delta"' "$plan"
check "resume: one stable run section is present" bash -c '[[ "$(grep -c "^### Gauntlet design deltas (run codex-" "$1")" -eq 1 ]]' _ "$plan"
check "resume: no sidecar is created after shell state is lost" bash -c '! compgen -G "$1/.gauntlet/design-deltas-*.md" >/dev/null' _ "$repo"

# A literal range target is split before it reaches the resolver. The narrowed
# branch slug is the range head, never the raw `base..head` string.
repo="$WORKDIR/range"
init_fixture "$repo"
(
	cd "$repo"
	# shellcheck source=/dev/null
	. "$LIB/gauntlet-common.sh"
	# shellcheck source=/dev/null
	. "$SINK_FN"
	canonical_target=branch:main..feature/widget
	ledger_path="$(gc_ledger_path "$canonical_target" codex)"
	"$LIB/convergence-ledger.sh" --init --ledger "$ledger_path" --target "$canonical_target" >/dev/null
	run_dir="$("$LIB/convergence-ledger.sh" --run-dir --ledger "$ledger_path")"
	jq '.rounds = [{}]' "$ledger_path" >"$ledger_path.tmp"
	mv "$ledger_path.tmp" "$ledger_path"
	write_round "$run_dir" 1 range-delta
	PLAN_PATH=""
	unset round_base round_head resolved_base_oid resolved_head_oid pr_head_ref
	run_design_delta_sink
) >"$WORKDIR/range.out" 2>"$WORKDIR/range.err"
check "range target: split head slug resolves the diff-touched plan" grep -Fq 'Summary: "range-delta"' "$repo/docs/dev_plans/$PLAN_NAME"
check "range target: guarded Git revision calls avoid sidecar fallback" bash -c '! compgen -G "$1/.gauntlet/design-deltas-*.md" >/dev/null' _ "$repo"

# An explicit two-dot range uses its resolved left endpoint, not its merge base.
repo="$WORKDIR/two-dot-base"
init_fixture "$repo"
git -C "$repo" switch -q main
git -C "$repo" switch -qc left
printf 'left-only\n' >"$repo/left.txt"
git -C "$repo" add left.txt
git -C "$repo" commit -qm left
left_oid="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" switch -q feature/widget
merge_base="$(git -C "$repo" merge-base left feature/widget)"
(
	cd "$repo"
	# shellcheck source=/dev/null
	. "$LIB/gauntlet-common.sh"
	# shellcheck source=/dev/null
	. "$SINK_FN"
	canonical_target=branch:left..feature/widget
	ledger_path="$(gc_ledger_path "$canonical_target" codex)"
	"$LIB/convergence-ledger.sh" --init --ledger "$ledger_path" --target "$canonical_target" >/dev/null
	run_dir="$("$LIB/convergence-ledger.sh" --run-dir --ledger "$ledger_path")"
	jq '.rounds = [{}]' "$ledger_path" >"$ledger_path.tmp"
	mv "$ledger_path.tmp" "$ledger_path"
	write_round "$run_dir" 1 two-dot-delta
	PLAN_PATH=""
	unset round_base round_head resolved_base_oid resolved_head_oid pr_head_ref
	run_design_delta_sink
	target_key="$(basename "${ledger_path%.json}")"
	ledger_run_id="$(jq -r .run_id "$ledger_path")"
	printf '%s\n' "${ledger_path%/*}/design-deltas-$target_key-codex-${ledger_run_id:0:12}.scope.json" >"$WORKDIR/two-dot-scope-path"
) >"$WORKDIR/two-dot.out" 2>"$WORKDIR/two-dot.err"
scope_file="$(sed -n '1p' "$WORKDIR/two-dot-scope-path")"
check "two-dot range: fixture left endpoint differs from merge base" bash -c '[[ "$1" != "$2" ]]' _ "$left_oid" "$merge_base"
check "two-dot range: persisted review base is the resolved left endpoint" bash -c '[[ "$(jq -r .base_oid "$1")" == "$2" ]]' _ "$scope_file" "$left_oid"
check "two-dot range: diff-touched plan receives the delta" grep -Fq 'Summary: "two-dot-delta"' "$repo/docs/dev_plans/$PLAN_NAME"

if run_seam_sidecar_probe "$SINK_FN"; then
	pass "seam escalation: sink is sidecar-only and leaves the tracked plan unchanged"
else
	fail "seam escalation: sink edited the plan or lost its sidecar delta"
fi

if run_reset_failure_probe "$SINK_FN"; then
	pass "reset failure: sink aborts before stale working files are consumed"
else
	fail "reset failure: sink consumed stale state or omitted its warning"
fi

if run_invalid_round_count_probe "$SINK_FN"; then
	pass "malformed ledger round count fails closed without a none claim"
else
	fail "malformed ledger round count became an empty delta run"
fi

if run_quick_round_probe "$QUICK_FN" "$SINK_FN"; then
	pass "quick mode initializes empty state, reuses its ledger, and keeps content-addressed sections"
else
	fail "quick-mode startup or section identity contract"
fi

seam_mutant="$WORKDIR/seam-mutant.sh"
sed 's/if \[\[ "${design_delta_sidecar_only:-false}" == true \]\]; then/if false; then/' "$SINK_FN" >"$seam_mutant"
if run_seam_sidecar_probe "$seam_mutant"; then
	fail "mutation seam-sidecar-only survived its regression probe"
else
	pass "mutation seam-sidecar-only is caught by the executed sink probe"
fi

reset_mutant="$WORKDIR/reset-mutant.sh"
sed '/cannot initialize design delta collection/{n;/return 0/d;}' "$SINK_FN" >"$reset_mutant"
if run_reset_failure_probe "$reset_mutant"; then
	fail "mutation reset-fail-closed survived its regression probe"
else
	pass "mutation reset-fail-closed is caught by the executed sink probe"
fi

round_count_mutant="$WORKDIR/round-count-mutant.sh"
sed '/ledger round count is not an integer/{N;d;}' "$SINK_FN" >"$round_count_mutant"
if run_invalid_round_count_probe "$round_count_mutant"; then
	fail "mutation malformed-round fail-closed survived its regression probe"
else
	pass "mutation malformed-round fail-closed is caught by the executed sink probe"
fi

quick_mutant="$WORKDIR/quick-mutant.sh"
sed 's/if \[\[ -n "${design_delta_quick_round:-}" \]\]; then/if false; then/' "$SINK_FN" >"$quick_mutant"
if run_quick_round_probe "$QUICK_FN" "$quick_mutant"; then
	fail "mutation quick-round collection survived its regression probe"
else
	pass "mutation quick-round collection is caught by the executed sink probe"
fi

quick_identity_mutant="$WORKDIR/quick-identity-mutant.sh"
sed 's/section_run_id="${run_id}-quick-${quick_report_digest:0:12}"/section_run_id="${run_id}-quick-round-${design_delta_quick_round}"/' "$SINK_FN" >"$quick_identity_mutant"
if run_quick_round_probe "$QUICK_FN" "$quick_identity_mutant"; then
	fail "mutation quick-section identity survived its regression probe"
else
	pass "mutation quick-section identity is caught by the executed sink probe"
fi

quick_init_mutant="$WORKDIR/quick-init-mutant.sh"
sed 's/ --init / --last-decision /' "$QUICK_FN" >"$quick_init_mutant"
if run_quick_round_probe "$quick_init_mutant" "$SINK_FN"; then
	fail "mutation removing quick-mode plain init survived its regression probe"
else
	pass "mutation removing quick-mode plain init is caught by the empty-state probe"
fi

# A fixer report is an input read, so a symlink at that path must be refused
# and its external target must never be consumed as review data.
repo="$WORKDIR/report-symlink"
init_fixture "$repo"
base_oid="$(git -C "$repo" rev-parse main)"
reviewed_head="$(git -C "$repo" rev-parse feature/widget)"
outside_report="$WORKDIR/outside-report.json"
jq -cn '{claimed:[],design_deltas:[{file:"escape",summary:"escaped-delta",decision:"d",rationale:"r",cells:"c"}]}' >"$outside_report"
outside_hash="$(shasum -a 256 "$outside_report" | awk '{print $1}')"
(
	cd "$repo"
	# shellcheck source=/dev/null
	. "$LIB/gauntlet-common.sh"
	# shellcheck source=/dev/null
	. "$SINK_FN"
	canonical_target=branch:feature/widget
	ledger_path="$(gc_ledger_path "$canonical_target" codex)"
	"$LIB/convergence-ledger.sh" --init --ledger "$ledger_path" --target "$canonical_target" \
		--review-base "$base_oid" --review-head "$reviewed_head" --review-branch feature/widget >/dev/null
	run_dir="$("$LIB/convergence-ledger.sh" --run-dir --ledger "$ledger_path")"
	jq '.rounds = [{}]' "$ledger_path" >"$ledger_path.tmp"
	mv "$ledger_path.tmp" "$ledger_path"
	mkdir -p "$run_dir/round-1"
	ln -s "$outside_report" "$run_dir/round-1/fixer-report.json"
	PLAN_PATH=""
	resolved_base_oid="$base_oid"
	resolved_head_oid="$reviewed_head"
	run_design_delta_sink
) >"$WORKDIR/symlink.out" 2>"$WORKDIR/symlink.err"

check "report symlink: sink refuses the input" grep -Fq 'refusing to operate on symlink' "$WORKDIR/symlink.err"
if [[ "$(shasum -a 256 "$outside_report" | awk '{print $1}')" == "$outside_hash" ]]; then
	pass "report symlink: external JSON is unchanged"
else
	fail "report symlink: external JSON changed"
fi
check "report symlink: external delta is not written to the plan" bash -c '! grep -Fq escaped-delta "$1"' _ "$repo/docs/dev_plans/$PLAN_NAME"
check "report symlink: terminal sink remains non-load-bearing" grep -Fq 'Design deltas: none' "$WORKDIR/symlink.out"

echo
echo "$pass_count passed, $fail_count failed"
[[ "$fail_count" -eq 0 ]]
