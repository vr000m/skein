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
AUTO_FN="$WORKDIR/auto-fn.sh"
sed -n '/^prepare_auto_chain_full_state() {$/,/^}$/p' "$SKILL_MD" >"$AUTO_FN"
if [[ ! -s "$AUTO_FN" ]] || ! grep -q '^}$' "$AUTO_FN"; then
	echo "FAIL: could not extract prepare_auto_chain_full_state from $SKILL_MD"
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

run_dropped_reporting_probe() {
	local sink_fn="$1" reason_slug reason repo base_oid reviewed_head shim_root
	for reason_slug in sidecar state-symlink mkdir temp-create temp-update final-move no-envelope; do
		case "$reason_slug" in
		sidecar) reason="design-delta sidecar is tracked, non-regular, or cannot be classified" ;;
		state-symlink) reason="refusing symlinked design-delta state directory" ;;
		mkdir) reason="cannot create .gauntlet directory" ;;
		temp-create) reason="cannot create a private design-delta sidecar temp file" ;;
		temp-update) reason="cannot update sidecar temp file" ;;
		final-move) reason="cannot replace sidecar" ;;
		no-envelope) reason="writer returned no usable result envelope" ;;
		esac
		repo="$WORKDIR/dropped-report-$reason_slug-$RANDOM"
		init_fixture "$repo"
		base_oid="$(git -C "$repo" rev-parse main)"
		reviewed_head="$(git -C "$repo" rev-parse feature/widget)"
		shim_root="$repo/skill-shim"
		mkdir -p "$shim_root"
		cp -R "$LIB" "$shim_root/lib"
		if [[ "$reason_slug" == no-envelope ]]; then
			cat >"$shim_root/lib/write-design-deltas.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
		else
			cat >"$shim_root/lib/write-design-deltas.sh" <<'SH'
#!/usr/bin/env bash
jq -cn --arg reason "$DROP_REASON" '{sink:"dropped",path:"",reason:$reason}'
SH
		fi
		chmod +x "$shim_root/lib/write-design-deltas.sh"
		(
			cd "$repo"
			SKILL_DIR="$shim_root"
			# shellcheck source=/dev/null
			. "$shim_root/lib/gauntlet-common.sh"
			# shellcheck source=/dev/null
			. "$sink_fn"
			canonical_target=branch:feature/widget
			ledger_path="$(gc_ledger_path "$canonical_target" codex)"
			"$shim_root/lib/convergence-ledger.sh" --init --ledger "$ledger_path" --target "$canonical_target" \
				--review-base "$base_oid" --review-head "$reviewed_head" --review-branch feature/widget >/dev/null
			run_dir="$("$shim_root/lib/convergence-ledger.sh" --run-dir --ledger "$ledger_path")"
			jq '.rounds = [{}]' "$ledger_path" >"$ledger_path.tmp"
			mv "$ledger_path.tmp" "$ledger_path"
			write_round "$run_dir" 1 dropped-delta
			PLAN_PATH=""
			DROP_REASON="$reason" run_design_delta_sink
		) >"$repo/dropped.out" 2>"$repo/dropped.err" || return 1
		grep -Fxq "warning: Design deltas: 1 dropped — $reason" "$repo/dropped.err" || return 1
		! grep -Fq 'Design deltas: none' "$repo/dropped.out" || return 1
	done
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
		target_key="$(printf '%s' "$(basename "${ledger_path%.json}")" | gc_sha1)"
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
	[[ "$before" != "$(hash_file "$plan")" ]] &&
		grep -Fq 'Summary: "current-delta"' "$plan" &&
		! grep -Eq 'stale-delta|stale-array' "$plan"
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

run_collection_failure_probe() {
	local sink_fn="$1" repo base_oid reviewed_head jq_real shim_dir
	repo="$WORKDIR/collection-failure-$RANDOM"
	init_fixture "$repo"
	base_oid="$(git -C "$repo" rev-parse main)"
	reviewed_head="$(git -C "$repo" rev-parse feature/widget)"
	jq_real="$(command -v jq)"
	shim_dir="$repo/jq-shim"
	mkdir -p "$shim_dir"
	cat >"$shim_dir/jq" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == -s ]] && exit 9
exec "$REAL_JQ" "$@"
SH
	chmod +x "$shim_dir/jq"
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
		PLAN_PATH=""
		REAL_JQ="$jq_real" PATH="$shim_dir:$PATH" run_design_delta_sink
	) >"$repo/collection.out" 2>"$repo/collection.err"
	grep -Fq 'Design deltas: unknown — collection failed or the items file is unreadable' "$repo/collection.err" &&
		! grep -Fq 'Design deltas: none' "$repo/collection.out"
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

run_quick_no_report_probe() {
	local quick_fn="$1" sink_fn="$2" repo base_oid reviewed_head
	repo="$WORKDIR/quick-no-report-$RANDOM"
	init_fixture "$repo"
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
		resolved_base_oid="$base_oid"
		resolved_head_oid="$reviewed_head"
		review_branch=feature/widget
		prepare_quick_design_delta_state
		PLAN_PATH=""
		design_delta_quick_round="$round_n"
		run_design_delta_sink
	) >"$repo/quick-none.out" 2>"$repo/quick-none.err"
	grep -Fxq 'Design deltas: none' "$repo/quick-none.out"
}

run_quick_scope_generation_probe() {
	local quick_fn="$1" repo base_oid reviewed_head advanced_head first_ledger second_ledger
	repo="$WORKDIR/quick-scope-generation-$RANDOM"
	init_fixture "$repo"
	base_oid="$(git -C "$repo" rev-parse main)"
	reviewed_head="$(git -C "$repo" rev-parse feature/widget)"
	(
		cd "$repo"
		# shellcheck source=/dev/null
		. "$LIB/gauntlet-common.sh"
		# shellcheck source=/dev/null
		. "$quick_fn"
		canonical_target=branch:feature/widget
		resolved_base_oid="$base_oid"
		resolved_head_oid="$reviewed_head"
		review_branch=feature/widget
		prepare_quick_design_delta_state || exit 1
		first_ledger="$ledger_path"
		jq -e --arg head "$reviewed_head" '.review_scope.head_oid == $head' "$first_ledger" >/dev/null || exit 1
		printf 'advance\n' >advance.txt
		git add advance.txt
		git commit -qm advance
		advanced_head="$(git rev-parse HEAD)"
		resolved_head_oid="$advanced_head"
		prepare_quick_design_delta_state || exit 1
		second_ledger="$ledger_path"
		[[ "$second_ledger" != "$first_ledger" && -f "$first_ledger" ]] || exit 1
		jq -e --arg head "$advanced_head" '.review_scope.head_oid == $head' "$second_ledger" >/dev/null || exit 1
		prepare_quick_design_delta_state || exit 1
		[[ "$ledger_path" == "$second_ledger" ]] || exit 1
	) >"$repo/generation.out" 2>"$repo/generation.err"
}

run_quick_legacy_bind_probe() {
	local quick_fn="$1" repo base_oid reviewed_head legacy_path
	repo="$WORKDIR/quick-legacy-bind-$RANDOM"
	init_fixture "$repo"
	base_oid="$(git -C "$repo" rev-parse main)"
	reviewed_head="$(git -C "$repo" rev-parse feature/widget)"
	(
		cd "$repo"
		# shellcheck source=/dev/null
		. "$LIB/gauntlet-common.sh"
		# shellcheck source=/dev/null
		. "$quick_fn"
		canonical_target=branch:feature/widget
		legacy_path="$(gc_ledger_path "$canonical_target" codex)"
		"$LIB/convergence-ledger.sh" --init --ledger "$legacy_path" --target "$canonical_target" >/dev/null
		jq '.quick_owner = "codex-quick-v1"' "$legacy_path" >"$legacy_path.tmp"
		mv "$legacy_path.tmp" "$legacy_path"
		jq -e 'has("review_scope") | not' "$legacy_path" >/dev/null
		resolved_base_oid="$base_oid"
		resolved_head_oid="$reviewed_head"
		review_branch=feature/widget
		prepare_quick_design_delta_state || exit 1
		[[ "$ledger_path" == "$legacy_path" ]] || exit 1
		jq -e --arg base "$base_oid" --arg head "$reviewed_head" '
			.review_scope == {base_oid:$base,head_oid:$head,branch:"feature/widget"}
		' "$legacy_path" >/dev/null || exit 1
		prepare_quick_design_delta_state || exit 1
		[[ "$ledger_path" == "$legacy_path" ]] || exit 1
	) >"$repo/legacy.out" 2>"$repo/legacy.err"
}

run_full_ledger_collision_probe() {
	local quick_fn="$1" terminal="$2" repo base_oid reviewed_head legacy_path before
	repo="$WORKDIR/quick-full-collision-$terminal-$RANDOM"
	init_fixture "$repo"
	base_oid="$(git -C "$repo" rev-parse main)"
	reviewed_head="$(git -C "$repo" rev-parse feature/widget)"
	(
		cd "$repo"
		# Extracted fixture functions are runtime paths.
		# shellcheck disable=SC1091
		. "$LIB/gauntlet-common.sh"
		# shellcheck disable=SC1090
		. "$quick_fn"
		canonical_target=branch:feature/widget
		resolved_base_oid="$base_oid"
		resolved_head_oid="$reviewed_head"
		review_branch=feature/widget
		legacy_path="$(gc_ledger_path "$canonical_target" codex)"
		"$LIB/convergence-ledger.sh" --init --ledger "$legacy_path" --target "$canonical_target" \
			--review-base "$base_oid" --review-head "$reviewed_head" --review-branch feature/widget >/dev/null
		if [[ "$terminal" == terminal ]]; then
			"$LIB/convergence-ledger.sh" --ledger "$legacy_path" --target "$canonical_target" --count 0 \
				--structural 0 --local 0 --pass-type full --quarantine 0 --unresolved 0 >/dev/null
		fi
		before="$(hash_file "$legacy_path")"
		if prepare_quick_design_delta_state; then exit 1; fi
		[[ "$before" == "$(hash_file "$legacy_path")" ]]
	)
}

run_auto_scope_probe() {
	local auto_fn="$1" terminal="$2" repo base_oid old_head new_head canonical_path before
	repo="$WORKDIR/auto-scope-$terminal-$RANDOM"
	init_fixture "$repo"
	base_oid="$(git -C "$repo" rev-parse main)"
	old_head="$(git -C "$repo" rev-parse feature/widget)"
	printf 'advance\n' >"$repo/advance"
	git -C "$repo" add advance
	git -C "$repo" commit -qm advance
	new_head="$(git -C "$repo" rev-parse feature/widget)"
	(
		cd "$repo"
		# Extracted fixture functions are runtime paths.
		# shellcheck disable=SC1091
		. "$LIB/gauntlet-common.sh"
		# shellcheck disable=SC1090
		. "$auto_fn"
		canonical_target=branch:feature/widget
		canonical_path="$(gc_ledger_path "$canonical_target" codex)"
		"$LIB/convergence-ledger.sh" --init --ledger "$canonical_path" --target "$canonical_target" \
			--review-base "$base_oid" --review-head "$old_head" --review-branch feature/widget >/dev/null
		if [[ "$terminal" == terminal ]]; then
			"$LIB/convergence-ledger.sh" --ledger "$canonical_path" --target "$canonical_target" --count 0 \
				--structural 0 --local 0 --pass-type full --quarantine 0 --unresolved 0 >/dev/null
		fi
		before="$(hash_file "$canonical_path")"
		resolved_base_oid="$base_oid"
		resolved_head_oid="$new_head"
		review_branch=feature/widget
		prepare_auto_chain_full_state
		[[ "$ledger_path" != "$canonical_path" && "$before" == "$(hash_file "$canonical_path")" ]] || exit 1
		jq -e --arg head "$new_head" '.review_scope.head_oid == $head' "$ledger_path" >/dev/null || exit 1
		selected="$ledger_path"
		prepare_auto_chain_full_state
		[[ "$ledger_path" == "$selected" ]] || exit 1
	)
}

run_private_temp_hardlink_probe() {
	local sink_fn="$1" pattern="$2" repo base_oid reviewed_head source before shim
	repo="$WORKDIR/hardlink-${pattern//[^a-z]/-}-$RANDOM"
	init_fixture "$repo"
	base_oid="$(git -C "$repo" rev-parse main)"
	reviewed_head="$(git -C "$repo" rev-parse feature/widget)"
	source="$repo/hardlink-source"
	printf 'external-or-tracked-bytes\n' >"$source"
	git -C "$repo" add hardlink-source
	before="$(hash_file "$source")"
	shim="$repo/shim"
	mkdir -p "$shim"
	cat >"$shim/mktemp" <<'SH'
#!/usr/bin/env bash
path="$($REAL_MKTEMP "$@")" || exit 1
if [[ "$1" == *"$ATTACK_PATTERN"* ]]; then
  rm -f -- "$path"
  ln "$HARDLINK_SOURCE" "$path"
fi
printf '%s\n' "$path"
SH
	chmod +x "$shim/mktemp"
	(
		cd "$repo"
		# Extracted fixture functions are runtime paths.
		# shellcheck disable=SC1091
		. "$LIB/gauntlet-common.sh"
		# shellcheck disable=SC1090
		. "$sink_fn"
		canonical_target=branch:feature/widget
		ledger_path="$(gc_ledger_path "$canonical_target" codex)"
		"$LIB/convergence-ledger.sh" --init --ledger "$ledger_path" --target "$canonical_target" \
			--review-base "$base_oid" --review-head "$reviewed_head" --review-branch feature/widget >/dev/null
		run_dir="$("$LIB/convergence-ledger.sh" --run-dir --ledger "$ledger_path")"
		jq '.rounds = [{}]' "$ledger_path" >"$ledger_path.tmp"
		mv "$ledger_path.tmp" "$ledger_path"
		write_round "$run_dir" 1 hardlink-delta
		PLAN_PATH="docs/dev_plans/$PLAN_NAME"
		REAL_MKTEMP="$(command -v mktemp)" ATTACK_PATTERN="$pattern" HARDLINK_SOURCE="$source" \
		PATH="$shim:$PATH" run_design_delta_sink
	) >"$repo/hardlink.out" 2>"$repo/hardlink.err"
	[[ "$before" == "$(hash_file "$source")" ]] && ! grep -Fq hardlink-delta "$source"
}

run_report_failure_matrix_probe() {
	local quick_fn="$1" sink_fn="$2" states="${3:-unsafe malformed non-array directory fifo socket}" mode state repo base_oid reviewed_head report matrix_rc
	for mode in full quick; do
		for state in $states; do
			repo="$WORKDIR/report-failure-$mode-$state-$RANDOM"
			init_fixture "$repo"
			base_oid="$(git -C "$repo" rev-parse main)"
			reviewed_head="$(git -C "$repo" rev-parse feature/widget)"
			matrix_rc=0
			(
				cd "$repo"
				# shellcheck source=/dev/null
				. "$LIB/gauntlet-common.sh"
				# shellcheck source=/dev/null
				. "$quick_fn"
				# shellcheck source=/dev/null
				. "$sink_fn"
				canonical_target=branch:feature/widget
				resolved_base_oid="$base_oid"
				resolved_head_oid="$reviewed_head"
				review_branch=feature/widget
				prepare_quick_design_delta_state
				report="$run_dir/round-$round_n/fixer-report.json"
				mkdir -p "${report%/*}"
				case "$state" in
				unsafe)
					printf '{"design_deltas":[]}\n' >"$repo/outside-report.json"
					ln -s "$repo/outside-report.json" "$report"
					;;
				malformed) printf '{bad json\n' >"$report" ;;
				non-array) printf '{"design_deltas":{}}\n' >"$report" ;;
				directory) mkdir "$report" ;;
				fifo) mkfifo "$report" ;;
				socket)
					(cd "${report%/*}" && python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' "${report##*/}") || exit 77
					;;
				esac
				PLAN_PATH=""
				if [[ "$mode" == quick ]]; then
					design_delta_quick_round="$round_n"
				else
					jq '.rounds = [{}]' "$ledger_path" >"$ledger_path.tmp"
					mv "$ledger_path.tmp" "$ledger_path"
					unset design_delta_quick_round
				fi
				run_design_delta_sink
			) >"$repo/matrix.out" 2>"$repo/matrix.err" || matrix_rc=$?
			if [[ "${matrix_rc:-0}" -eq 77 && "$state" == socket ]]; then
				continue
			fi
			[[ "${matrix_rc:-0}" -eq 0 ]] || return 1
			matrix_rc=0
			grep -Fq 'Design deltas: unknown — one or more selected fixer reports could not be collected' "$repo/matrix.err" || return 1
			! grep -Fq 'Design deltas: none' "$repo/matrix.out" || return 1
		done
	done
}

run_transient_legacy_scope_probe() {
	local sink_fn="$1" repo ledger_path scope_file
	repo="$WORKDIR/transient-legacy-scope-$RANDOM"
	init_fixture "$repo"
	(
		cd "$repo"
		# shellcheck source=/dev/null
		. "$LIB/gauntlet-common.sh"
		# shellcheck source=/dev/null
		. "$sink_fn"
		canonical_target=branch:missing-ref
		ledger_path="$(gc_ledger_path "$canonical_target" codex)"
		"$LIB/convergence-ledger.sh" --init --ledger "$ledger_path" --target "$canonical_target" >/dev/null
		run_dir="$("$LIB/convergence-ledger.sh" --run-dir --ledger "$ledger_path")"
		jq '.rounds = [{}]' "$ledger_path" >"$ledger_path.tmp"
		mv "$ledger_path.tmp" "$ledger_path"
		write_round "$run_dir" 1 transient-scope
		target_key="$(printf '%s' "$(basename "${ledger_path%.json}")" | gc_sha1)"
		ledger_run_id="$(jq -r .run_id "$ledger_path")"
		scope_file="${ledger_path%/*}/design-deltas-$target_key-codex-${ledger_run_id:0:12}.scope.json"
		PLAN_PATH=""
		unset round_base round_head resolved_base_oid resolved_head_oid pr_head_ref
		run_design_delta_sink
		[[ ! -e "$scope_file" ]]
		canonical_target=branch:feature/widget
		run_design_delta_sink
		jq -e '.base_oid | test("^[0-9a-f]{40}$")' "$scope_file" >/dev/null
		jq -e '.head_oid | test("^[0-9a-f]{40}$")' "$scope_file" >/dev/null
	) >"$repo/transient.out" 2>"$repo/transient.err"
}

make_bad_write_type() {
	local path="$1" kind="$2"
	case "$kind" in
	directory) mkdir -p "$path" ;;
	fifo) mkfifo "$path" ;;
	socket)
		(
			cd "$(dirname "$path")" || exit 1
			python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' "$(basename "$path")" 2>/dev/null
		)
		;;
	*) return 1 ;;
	esac
}

run_nonregular_working_path_probe() {
	local sink_fn="$1" only_kind="${2:-}" only_bad_type="${3:-}" kind bad_type repo plan before base_oid reviewed_head path cell_rc
	for kind in items deltas resolution scope scope-temp; do
		[[ -z "$only_kind" || "$kind" == "$only_kind" ]] || continue
		for bad_type in directory fifo socket; do
			[[ -z "$only_bad_type" || "$bad_type" == "$only_bad_type" ]] || continue
			repo="$WORKDIR/nonregular-$kind-$bad_type-$RANDOM"
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
				write_round "$run_dir" 1 nonregular
				target_key="$(printf '%s' "$(basename "${ledger_path%.json}")" | gc_sha1)"
				state_dir="$(dirname "$ledger_path")"
				ledger_run_id="$(jq -r .run_id "$ledger_path")"
				run_id="codex-${ledger_run_id:0:12}"
				case "$kind" in
				items) path="$state_dir/design-deltas-$target_key.items.jsonl" ;;
				deltas) path="$state_dir/design-deltas-$target_key.deltas.json" ;;
				resolution) path="$state_dir/design-deltas-$target_key.resolution.json" ;;
				scope) path="$state_dir/design-deltas-$target_key-$run_id.scope.json" ;;
				scope-temp) path="$state_dir/.design-delta-scope-$target_key-$run_id.tmp" ;;
				esac
				if ! make_bad_write_type "$path" "$bad_type"; then
					[[ "$bad_type" == socket ]] && exit 77
					exit 1
				fi
				PLAN_PATH=""
				run_design_delta_sink
				case "$bad_type" in
				fifo) [[ -p "$path" ]] ;;
				directory) [[ -d "$path" ]] ;;
				socket) [[ -S "$path" ]] ;;
				esac
			) >"$repo/nonregular.out" 2>"$repo/nonregular.err" && cell_rc=0 || cell_rc=$?
			if [[ "$cell_rc" -eq 77 ]]; then
				pass "sink socket row skipped for $kind (socket unavailable at fixture path)"
				continue
			elif [[ "$cell_rc" -ne 0 ]]; then
				echo "nonregular cell failed: $kind/$bad_type" >&2
				return 1
			fi
			[[ "$before" == "$(hash_file "$plan")" ]] || {
				echo "nonregular plan changed: $kind/$bad_type" >&2
				return 1
			}
			grep -Fq 'refusing non-regular design delta write path' "$repo/nonregular.err" || return 1
		done
	done
}

run_icase_tracked_probe() {
	local sink_fn="$1" kind repo plan before base_oid reviewed_head lower upper rel_upper before_upper
	for kind in items deltas scope; do
		repo="$WORKDIR/icase-$kind-$RANDOM"
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
			write_round "$run_dir" 1 icase
			target_key="$(printf '%s' "$(basename "${ledger_path%.json}")" | gc_sha1)"
			state_dir="$(dirname "$ledger_path")"
			ledger_run_id="$(jq -r .run_id "$ledger_path")"
			run_id="codex-${ledger_run_id:0:12}"
			case "$kind" in
			items) lower="$state_dir/design-deltas-$target_key.items.jsonl" ;;
			deltas) lower="$state_dir/design-deltas-$target_key.deltas.json" ;;
			scope) lower="$state_dir/design-deltas-$target_key-$run_id.scope.json" ;;
			esac
			upper="${lower/\.gauntlet\//.Gauntlet/}"
			mkdir -p "${upper%/*}"
			printf 'case sentinel\n' >"$upper"
			rel_upper="${upper#"$repo"/}"
			git add -f -- "$rel_upper"
			before_upper="$(hash_file "$upper")"
			PLAN_PATH=""
			GIT_INDEX_FILE=/nonexistent GIT_DIR=/nonexistent GIT_WORK_TREE="$WORKDIR" run_design_delta_sink
			[[ "$before_upper" == "$(hash_file "$upper")" ]]
		) >"$repo/icase.out" 2>"$repo/icase.err" || return 1
		[[ "$before" == "$(hash_file "$plan")" ]] || return 1
	done
}

run_review_scope_control_probe() {
	local sink_fn="$1" source escaped branch_json repo plan before base_oid reviewed_head ledger_path run_dir
	for source in ledger persisted; do
		for escaped in '\u0000' '\u0001' '\u001f' '\u007f' '\r' '\n'; do
			repo="$WORKDIR/scope-control-$source-${escaped//\\/}-$RANDOM"
			init_fixture "$repo"
			plan="$repo/docs/dev_plans/$PLAN_NAME"
			before="$(hash_file "$plan")"
			base_oid="$(git -C "$repo" rev-parse main)"
			reviewed_head="$(git -C "$repo" rev-parse feature/widget)"
			branch_json="\"feature/widget${escaped}bad\""
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
				if [[ "$source" == ledger ]]; then
					jq --argjson branch "$branch_json" '.review_scope.branch = $branch' "$ledger_path" >"$ledger_path.tmp"
					mv "$ledger_path.tmp" "$ledger_path"
				else
					target_key="$(printf '%s' "$(basename "${ledger_path%.json}")" | gc_sha1)"
					ledger_run_id="$(jq -r .run_id "$ledger_path")"
					run_id="codex-${ledger_run_id:0:12}"
					scope_file="${ledger_path%/*}/design-deltas-$target_key-$run_id.scope.json"
					jq -cn --arg run_id "$run_id" --arg target "$canonical_target" --arg base_oid "$base_oid" --arg head_oid "$reviewed_head" \
						--argjson branch "$branch_json" '{run_id:$run_id,target:$target,base_oid:$base_oid,head_oid:$head_oid,branch:$branch}' >"$scope_file"
				fi
				write_round "$run_dir" 1 control-delta
				PLAN_PATH="docs/dev_plans/$PLAN_NAME"
				run_design_delta_sink
			) >"$repo/scope.out" 2>"$repo/scope.err"
			[[ "$before" == "$(hash_file "$plan")" ]] || return 1
			if [[ "$source" == ledger ]]; then
				grep -Fq 'invalid reviewed scope in ledger' "$repo/scope.err" || return 1
			else
				grep -Fq 'invalid persisted design delta scope' "$repo/scope.err" || return 1
			fi
		done
	done
}

run_normal_scope_probe() {
	local sink_fn="$1" repo plan base_oid reviewed_head
	repo="$WORKDIR/scope-normal-$RANDOM"
	init_fixture "$repo"
	plan="$repo/docs/dev_plans/$PLAN_NAME"
	base_oid="$(git -C "$repo" rev-parse main)"
	reviewed_head="$(git -C "$repo" rev-parse feature/widget)"
	(
		cd "$repo"
		# shellcheck source=/dev/null
		. "$LIB/gauntlet-common.sh"
		# shellcheck source=/dev/null
		. "$sink_fn"
		canonical_target=branch:feature/widget-name
		ledger_path="$(gc_ledger_path "$canonical_target" codex)"
		"$LIB/convergence-ledger.sh" --init --ledger "$ledger_path" --target "$canonical_target" \
			--review-base "$base_oid" --review-head "$reviewed_head" --review-branch feature/widget-name >/dev/null
		run_dir="$("$LIB/convergence-ledger.sh" --run-dir --ledger "$ledger_path")"
		jq '.rounds = [{}]' "$ledger_path" >"$ledger_path.tmp"
		mv "$ledger_path.tmp" "$ledger_path"
		write_round "$run_dir" 1 normal-scope-delta
		PLAN_PATH="docs/dev_plans/$PLAN_NAME"
		run_design_delta_sink
	) >"$repo/scope.out" 2>"$repo/scope.err"
	grep -Fq 'Summary: "normal-scope-delta"' "$plan"
}

run_tracked_working_path_probe() {
	local sink_fn="$1" only_kind="${2:-}" env_mode kind repo plan before base_oid reviewed_head path rel sentinel before_path
	for env_mode in clean hostile; do
		for kind in items deltas resolution scope scope-temp; do
			[[ -z "$only_kind" || "$kind" == "$only_kind" ]] || continue
			repo="$WORKDIR/tracked-$env_mode-$kind-$RANDOM"
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
				write_round "$run_dir" 1 tracked-path-delta
				target_key="$(printf '%s' "$(basename "${ledger_path%.json}")" | gc_sha1)"
				state_dir="$(dirname "$ledger_path")"
				ledger_run_id="$(jq -r .run_id "$ledger_path")"
				run_id="codex-${ledger_run_id:0:12}"
				case "$kind" in
				items) path="$state_dir/design-deltas-$target_key.items.jsonl" ;;
				deltas) path="$state_dir/design-deltas-$target_key.deltas.json" ;;
				resolution) path="$state_dir/design-deltas-$target_key.resolution.json" ;;
				scope) path="$state_dir/design-deltas-$target_key-$run_id.scope.json" ;;
				scope-temp) path="$state_dir/.design-delta-scope-$target_key-$run_id.tmp" ;;
				esac
				sentinel="sentinel-$env_mode-$kind"
				printf '%s\n' "$sentinel" >"$path"
				rel="${path#"$repo"/}"
				git add -f -- "$rel"
				before_path="$(hash_file "$path")"
				PLAN_PATH=""
				if [[ "$env_mode" == hostile ]]; then
					GIT_INDEX_FILE=/nonexistent GIT_DIR=/nonexistent GIT_WORK_TREE="$WORKDIR" \
						GIT_CEILING_DIRECTORIES="$repo" run_design_delta_sink
				else
					run_design_delta_sink
				fi
				[[ "$before_path" == "$(hash_file "$path")" ]]
			) >"$repo/tracked.out" 2>"$repo/tracked.err" || return 1
			[[ "$before" == "$(hash_file "$plan")" ]] || return 1
			grep -Fq 'tracked or indeterminate design delta' "$repo/tracked.err" ||
				grep -Fq 'refusing to write tracked design delta path' "$repo/tracked.err" || return 1
		done
	done
}

run_corrupt_index_working_path_probe() {
	local sink_fn="$1" repo base_oid reviewed_head
	repo="$WORKDIR/corrupt-index-$RANDOM"
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
		target_key="$(printf '%s' "$(basename "${ledger_path%.json}")" | gc_sha1)"
		items="${ledger_path%/*}/design-deltas-$target_key.items.jsonl"
		printf 'corrupt-index-sentinel\n' >"$items"
		before_items="$(hash_file "$items")"
		printf 'not an index\n' >.git/index
		PLAN_PATH=""
		run_design_delta_sink
		[[ "$before_items" == "$(hash_file "$items")" ]]
	) >"$repo/corrupt.out" 2>"$repo/corrupt.err"
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

	target_key="$(printf '%s' "$(basename "${ledger_path%.json}")" | gc_sha1)"
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
	target_key="$(printf '%s' "$(basename "${ledger_path%.json}")" | gc_sha1)"
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

if run_dropped_reporting_probe "$SINK_FN"; then
	pass "all non-empty writer failure envelopes and a missing envelope print a dropped count and reason"
else
	fail "dropped design-delta terminal reporting state space"
fi

if run_reset_failure_probe "$SINK_FN"; then
	pass "legacy predictable scratch files are ignored while private collection succeeds"
else
	fail "legacy predictable scratch files contaminated private collection"
fi

if run_invalid_round_count_probe "$SINK_FN"; then
	pass "malformed ledger round count fails closed without a none claim"
else
	fail "malformed ledger round count became an empty delta run"
fi

if run_collection_failure_probe "$SINK_FN"; then
	pass "failed jq collection with a non-empty items file reports unknown, never none"
else
	fail "collection failure was collapsed to zero deltas"
fi

if run_quick_round_probe "$QUICK_FN" "$SINK_FN"; then
	pass "quick mode initializes empty state, reuses its ledger, and keeps content-addressed sections"
else
	fail "quick-mode startup or section identity contract"
fi

if run_quick_no_report_probe "$QUICK_FN" "$SINK_FN"; then
	pass "quick mode without a fixer report prints Design deltas: none"
else
	fail "quick-mode no-report terminal output"
fi

if run_quick_scope_generation_probe "$QUICK_FN"; then
	pass "quick mode reuses an exact-scope generation and selects a new generation after branch advancement"
else
	fail "quick-mode scope-keyed ledger generation"
fi

if run_quick_legacy_bind_probe "$QUICK_FN"; then
	pass "quick mode atomically binds a legacy pre-scope ledger once"
else
	fail "quick-mode legacy review_scope binding"
fi
for collision_state in nonterminal terminal; do
	if run_full_ledger_collision_probe "$QUICK_FN" "$collision_state"; then
		pass "quick mode refuses a $collision_state full target ledger without quick ownership provenance"
	else
		fail "quick/full $collision_state target-ledger separation"
	fi
	if run_auto_scope_probe "$AUTO_FN" "$collision_state"; then
		pass "auto-chain selects and reuses a new generation after a $collision_state ledger's scope moves"
	else
		fail "auto-chain $collision_state scope generation"
	fi
done

if run_report_failure_matrix_probe "$QUICK_FN" "$SINK_FN"; then
	pass "full and quick report-failure table maps unsafe, malformed, non-array, and non-regular inputs to unknown, never zero"
else
	fail "total fixer-report collection-result state space"
fi

if run_transient_legacy_scope_probe "$SINK_FN"; then
	pass "legacy scope persistence retries after transient OID resolution failure"
else
	fail "legacy scope persisted empty OIDs or did not retry"
fi

if run_review_scope_control_probe "$SINK_FN"; then
	pass "ledger and persisted review_scope branch controls fail closed before jq -r extraction"
else
	fail "review_scope control-byte sink matrix"
fi

if run_normal_scope_probe "$SINK_FN"; then
	pass "normal slash-and-hyphen review_scope branch reaches the plan sink"
else
	fail "normal review_scope branch"
fi

for hardlink_pattern in .design-delta-items. .design-delta-array. .design-delta-resolution. .design-delta-scope.; do
	if run_private_temp_hardlink_probe "$SINK_FN" "$hardlink_pattern"; then
		pass "private sink temp $hardlink_pattern refuses a hardlink alias without changing its tracked source"
	else
		fail "private sink temp hardlink contract: $hardlink_pattern"
	fi
done

if run_corrupt_index_working_path_probe "$SINK_FN"; then
	pass "an indeterminate trackedness result from a corrupt index fails closed"
else
	fail "corrupt-index trackedness result"
fi

seam_mutant="$WORKDIR/seam-mutant.sh"
sed 's/if \[\[ "${design_delta_sidecar_only:-false}" == true \]\]; then/if false; then/' "$SINK_FN" >"$seam_mutant"
if run_seam_sidecar_probe "$seam_mutant"; then
	fail "mutation seam-sidecar-only survived its regression probe"
else
	pass "mutation seam-sidecar-only is caught by the executed sink probe"
fi

dropped_reporting_mutant="$WORKDIR/dropped-reporting-mutant.sh"
sed 's/"sidecar", "dropped"/"sidecar"/' "$SINK_FN" >"$dropped_reporting_mutant"
if run_dropped_reporting_probe "$dropped_reporting_mutant"; then
	fail "mutation rejecting the dropped sink token survived its reporting cells"
else
	pass "dropped-result cells catch removal of the distinct sink token"
fi

collection_reset_mutant="$WORKDIR/collection-reset-mutant.sh"
awk '
  { print }
  /report_unknown_design_deltas "collection failed or the items file is unreadable"/ {
    getline
    print "    printf '\''[]\\n'\'' > \"$run_deltas_file\""
  }
' "$SINK_FN" >"$collection_reset_mutant"
if run_collection_failure_probe "$collection_reset_mutant"; then
	fail "mutation restoring reset-to-empty collection behaviour survived its regression probe"
else
	pass "mutation restoring reset-to-empty collection behaviour is caught"
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

quick_scope_mutant="$WORKDIR/quick-scope-mutant.sh"
sed '/quick_scope_json=/{n;s/head_oid:\$head/head_oid:""/;}' "$QUICK_FN" >"$quick_scope_mutant"
if run_quick_scope_generation_probe "$quick_scope_mutant"; then
	fail "mutation removing head identity from the quick generation key survived branch advancement"
else
	pass "branch-advancement probe catches an incomplete quick generation key"
fi

quick_legacy_mutant="$WORKDIR/quick-legacy-mutant.sh"
sed 's/--bind-review-scope/--last-decision/' "$QUICK_FN" >"$quick_legacy_mutant"
if run_quick_legacy_bind_probe "$quick_legacy_mutant"; then
	fail "mutation removing legacy scope binding survived the migration probe"
else
	pass "legacy migration probe catches removal of one-time scope binding"
fi

quick_provenance_mutant="$WORKDIR/quick-provenance-mutant.sh"
sed 's/\.quick_owner == "codex-quick-v1" and has("review_scope")/has("review_scope")/' "$QUICK_FN" >"$quick_provenance_mutant"
if run_full_ledger_collision_probe "$quick_provenance_mutant" nonterminal; then
	fail "mutation removing quick ownership provenance survived the full-ledger collision probe"
else
	pass "full-ledger collision probe catches removal of quick ownership provenance"
fi

auto_scope_mutant="$WORKDIR/auto-scope-mutant.sh"
sed 's@  if \[\[ "$auto_chain_ledger_rc" -ne 4 \]\] && ! jq -e --argjson scope "$scope_json" .*@  if false; then@' \
	"$AUTO_FN" >"$auto_scope_mutant"
if run_auto_scope_probe "$auto_scope_mutant" nonterminal; then
	fail "mutation removing auto-chain scope comparison survived the moved-scope probe"
else
	pass "moved-scope probe catches removal of auto-chain scope comparison"
fi

collection_total_mutant="$WORKDIR/collection-total-mutant.sh"
sed '/if \[\[ "\$collection_complete" != true \]\]; then/,/^[[:space:]]*fi$/d' "$SINK_FN" >"$collection_total_mutant"
if run_report_failure_matrix_probe "$QUICK_FN" "$collection_total_mutant"; then
	fail "mutation removing total collection completeness survived the report-failure table"
else
	pass "report-failure table catches removal of total collection completeness"
fi

nonregular_report_mutant="$WORKDIR/nonregular-report-mutant.sh"
awk '
	/if \[\[ ! -f "\$report" \]\]; then/ {
		print "    [[ -f \"$report\" ]] || continue"
		skipping = 1
		next
	}
	skipping && /^[[:space:]]*fi$/ { skipping = 0; next }
	!skipping { print }
' "$SINK_FN" >"$nonregular_report_mutant"
if run_report_failure_matrix_probe "$QUICK_FN" "$nonregular_report_mutant" directory; then
	fail "mutation accepting existing non-regular fixer reports survived the state table"
else
	pass "report-failure table catches removal of the regular-file predicate"
fi

scope_empty_mutant="$WORKDIR/scope-empty-mutant.sh"
sed 's/if \[\[ -n "$BASE_OID" && -n "$HEAD_OID" \]\]; then/if true; then/' "$SINK_FN" >"$scope_empty_mutant"
if run_transient_legacy_scope_probe "$scope_empty_mutant"; then
	fail "mutation persisting empty legacy scope survived the retry probe"
else
	pass "mutation persisting empty legacy scope is caught"
fi

scope_control_mutant="$WORKDIR/scope-control-mutant.sh"
sed 's/and (\.branch | control_free)/and (.branch | type == "string")/g' "$SINK_FN" >"$scope_control_mutant"
if run_review_scope_control_probe "$scope_control_mutant"; then
	fail "mutation removing sink scope control validation survived its state-space probe"
else
	pass "mutation removing sink scope control validation is caught"
fi

hardlink_mutant="$WORKDIR/hardlink-mutant.sh"
sed 's/\[\[ "$links" == 1 \]\]/true/' "$SINK_FN" >"$hardlink_mutant"
if run_private_temp_hardlink_probe "$hardlink_mutant" .design-delta-items.; then
	fail "mutation removing the single-link invariant survived the items-temp hardlink cell"
else
	pass "items-temp hardlink cell catches removal of the single-link invariant"
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
check "report symlink: terminal sink reports unknown and remains non-load-bearing" bash -c \
	'grep -Fq "Design deltas: unknown" "$1" && ! grep -Fq "Design deltas: none" "$2"' _ \
	"$WORKDIR/symlink.err" "$WORKDIR/symlink.out"

echo
echo "$pass_count passed, $fail_count failed"
[[ "$fail_count" -eq 0 ]]
