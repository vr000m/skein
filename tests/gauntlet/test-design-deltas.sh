#!/usr/bin/env bash
# Contract coverage for review-gauntlet plan resolution and design-delta writes.
# shellcheck disable=SC2016  # jq, awk, Markdown, and sed programs are literal.

set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
RESOLVER="$ROOT_DIR/plugins/skein-codex/skills/review-gauntlet/lib/resolve-plan.sh"
WRITER="$ROOT_DIR/plugins/skein-codex/skills/review-gauntlet/lib/write-design-deltas.sh"
STATE_GUARD="$ROOT_DIR/plugins/skein-codex/skills/review-gauntlet/lib/state-path-guard.sh"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/skein-design-deltas.XXXXXX")"
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

assert_json() {
	local json="$1" filter="$2" label="$3"
	if jq -e "$filter" >/dev/null 2>&1 <<<"$json"; then
		pass "$label"
	else
		fail "$label: $json"
	fi
}

init_repo() {
	local repo="$1"
	mkdir -p "$repo/docs/dev_plans"
	git -C "$repo" init -q -b main
	git -C "$repo" config user.name test
	git -C "$repo" config user.email test@example.invalid
	git -C "$repo" config commit.gpgsign false
	printf '# Plans\n' >"$repo/docs/dev_plans/README.md"
	git -C "$repo" add docs/dev_plans/README.md
	git -C "$repo" commit -qm base
}

add_plan() {
	local repo="$1" name="$2"
	printf '# %s\n' "$name" >"$repo/docs/dev_plans/$name"
}

commit_plans() {
	local repo="$1" message="$2"
	git -C "$repo" add docs/dev_plans
	git -C "$repo" commit -qm "$message"
}

resolve_case() {
	local repo="$1" branch="$2"
	"$RESOLVER" --repo-root "$repo" --base main --branch "$branch"
}

run_resolver_tests() {
	local repo out rc base_oid feature_oid

	repo="$WORKDIR/explicit"
	init_repo "$repo"
	add_plan "$repo" 20261016-feature-widget.md
	out="$("$RESOLVER" --repo-root "$repo" --base missing-base --branch feature/widget --plan docs/dev_plans/20261016-feature-widget.md)"
	assert_json "$out" '.status == "explicit" and .plan == "docs/dev_plans/20261016-feature-widget.md"' "resolve explicit plan before unknown base"

	set +e
	"$RESOLVER" --repo-root "$repo" --base main --branch feature/widget --plan ../outside.md >/dev/null 2>&1
	rc=$?
	set -e
	if [[ "$rc" -eq 1 ]]; then
		pass "resolve rejects explicit path escape"
	else
		fail "resolve explicit escape exit $rc, expected 1"
	fi

	ln -s 20261016-feature-widget.md "$repo/docs/dev_plans/20261016-link.md"
	set +e
	"$RESOLVER" --repo-root "$repo" --base main --branch feature/widget --plan docs/dev_plans/20261016-link.md >/dev/null 2>&1
	rc=$?
	set -e
	if [[ "$rc" -eq 1 ]]; then
		pass "resolve rejects explicit symlink"
	else
		fail "resolve explicit symlink exit $rc, expected 1"
	fi

	repo="$WORKDIR/diff-unique"
	init_repo "$repo"
	git -C "$repo" switch -qc feature/widget
	add_plan "$repo" 20261016-feature-widget.md
	commit_plans "$repo" plan
	out="$(resolve_case "$repo" feature/widget)"
	assert_json "$out" '.status == "unique" and .plan == "docs/dev_plans/20261016-feature-widget.md"' "resolve one changed plan"

	repo="$WORKDIR/diff-narrow"
	init_repo "$repo"
	git -C "$repo" switch -qc feature/widget
	add_plan "$repo" 20261016-feature-widget.md
	add_plan "$repo" 20261016-feature-other.md
	commit_plans "$repo" plans
	out="$(resolve_case "$repo" feature/widget)"
	assert_json "$out" '.status == "unique" and (.plan | contains("widget"))' "resolve changed plans by branch slug"

	repo="$WORKDIR/diff-ambiguous"
	init_repo "$repo"
	git -C "$repo" switch -qc feature/shared
	add_plan "$repo" 20261016-feature-shared-one.md
	add_plan "$repo" 20261016-feature-shared-two.md
	commit_plans "$repo" plans
	out="$(resolve_case "$repo" feature/shared)"
	assert_json "$out" '.status == "ambiguous" and .plan == ""' "resolve ambiguous changed plans"

	repo="$WORKDIR/detached"
	init_repo "$repo"
	git -C "$repo" switch -qc feature/widget
	add_plan "$repo" 20261016-feature-widget.md
	commit_plans "$repo" plan
	git -C "$repo" checkout -q --detach
	out="$("$RESOLVER" --repo-root "$repo" --base main --branch "")"
	assert_json "$out" '.status == "unique" and (.plan | contains("widget"))' "resolve detached head with empty branch"

	repo="$WORKDIR/unknown-base"
	init_repo "$repo"
	out="$("$RESOLVER" --repo-root "$repo" --base missing-base --branch feature/widget)"
	assert_json "$out" '.status == "none" and .plan == "" and .reason == "base ref not found"' "resolve unknown base as none"

	repo="$WORKDIR/head-ref"
	init_repo "$repo"
	base_oid="$(git -C "$repo" rev-parse HEAD)"
	git -C "$repo" switch -qc feature/widget
	add_plan "$repo" 20261016-feature-widget.md
	commit_plans "$repo" plan
	feature_oid="$(git -C "$repo" rev-parse HEAD)"
	git -C "$repo" switch -q main
	out="$("$RESOLVER" --repo-root "$repo" --base "$base_oid" --head "$feature_oid" --branch feature/widget)"
	assert_json "$out" '.status == "unique" and (.plan | contains("widget"))' "resolve uses explicit reviewed head"

	repo="$WORKDIR/zero-unique"
	init_repo "$repo"
	add_plan "$repo" 20261016-feature-widget.md
	commit_plans "$repo" plan
	git -C "$repo" switch -qc feature/widget
	out="$(resolve_case "$repo" feature/widget)"
	assert_json "$out" '.status == "unique" and (.plan | contains("widget"))' "resolve zero-diff plan by branch slug"

	repo="$WORKDIR/none"
	init_repo "$repo"
	git -C "$repo" switch -qc feature/widget
	out="$(resolve_case "$repo" feature/widget)"
	assert_json "$out" '.status == "none" and .plan == ""' "resolve no plan"
}

write_resolution() {
	local repo="$1" status="$2" plan="$3"
	jq -cn --arg status "$status" --arg plan "$plan" '{status:$status,plan:$plan,reason:"test"}' >"$repo/resolution.json"
}

write_standard_deltas() {
	local repo="$1" summary="$2"
	jq -cn --arg summary "$summary" '[{file:"lib/a.sh",summary:$summary,decision:"keep writer strict",rationale:"preserve round trip",cells:"open x populated"}]' >"$repo/deltas.json"
}

run_writer_id() {
	local writer="$1" repo="$2" run_id="$3"
	"$writer" --repo-root "$repo" --resolution "$repo/resolution.json" --deltas "$repo/deltas.json" --run-id "$run_id" --target-key ledger-codex-widget
}

hash_file() {
	shasum -a 256 "$1" | awk '{print $1}'
}

hash_above_unique_marker() {
	local plan="$1" marker_line
	marker_line="$(awk '/^<!-- reviewed: .* -->$/{print NR; exit}' "$plan")"
	head -n "$((marker_line - 1))" "$plan" | shasum -a 256 | awk '{print $1}'
}

write_shape_plan() {
	local repo="$1" markers="$2" findings="$3" plan
	plan="$repo/docs/dev_plans/20261016-feature-widget.md"
	{
		printf '# Plan\n\n## Objective\n\nProtected prefix.\n\n'
		if [[ "$findings" == "above-only" ]]; then
			printf '## Findings\n\nAbove marker only.\n\n'
		fi
		if [[ "$markers" -ge 1 ]]; then
			printf '<!-- reviewed: 2026-10-16 @ first -->\n\n'
		fi
		case "$findings" in
		none | above-only) ;;
		one-below) printf '## Findings\n\nExisting finding.\n\n' ;;
		two-below) printf '## Findings\n\nFirst.\n\n## Findings\n\nSecond.\n\n' ;;
		inside-fence) printf '```markdown\n## Findings\n```\n\n' ;;
		esac
		if [[ "$markers" -eq 2 ]]; then
			printf '<!-- reviewed: 2026-10-16 @ second -->\n\n'
		fi
		printf '## Progress\n\nDone.\n'
	} >"$plan"
}

matrix_case() {
	local writer="$1" markers="$2" findings="$3" repo plan sidecar expected_sink
	local before_plan before_prefix after_prefix out first_hash rerun_hash count label
	label="matrix markers=$markers findings=$findings"
	repo="$WORKDIR/matrix-${writer##*/}-$markers-$findings-$RANDOM"
	init_repo "$repo"
	write_shape_plan "$repo" "$markers" "$findings"
	plan="$repo/docs/dev_plans/20261016-feature-widget.md"
	sidecar="$repo/.gauntlet/design-deltas-ledger-codex-widget.md"
	write_resolution "$repo" unique docs/dev_plans/20261016-feature-widget.md
	write_standard_deltas "$repo" first
	before_plan="$(hash_file "$plan")"
	before_prefix=""
	if [[ "$markers" -eq 1 ]]; then
		before_prefix="$(hash_above_unique_marker "$plan")"
	fi
	if [[ "$markers" -eq 1 && "$findings" == "one-below" ]]; then
		expected_sink=plan
	else
		expected_sink=sidecar
	fi

	out="$(run_writer_id "$writer" "$repo" run-one)"
	assert_json "$out" ".sink == \"$expected_sink\"" "$label fresh routes to $expected_sink"
	if [[ "$markers" -eq 1 ]]; then
		after_prefix="$(hash_above_unique_marker "$plan")"
		if [[ "$before_prefix" == "$after_prefix" ]]; then
			pass "$label fresh preserves bytes above marker"
		else
			fail "$label fresh changed bytes above marker"
		fi
	elif [[ "$expected_sink" == "sidecar" && "$before_plan" == "$(hash_file "$plan")" ]]; then
		pass "$label fresh leaves ambiguous plan unchanged"
	else
		fail "$label fresh changed ambiguous plan"
	fi
	first_hash="$(hash_file "$plan")"
	[[ -f "$sidecar" ]] && first_hash="$first_hash:$(hash_file "$sidecar")"

	out="$(run_writer_id "$writer" "$repo" run-one)"
	assert_json "$out" ".sink == \"$expected_sink\"" "$label same run routes to $expected_sink"
	rerun_hash="$(hash_file "$plan")"
	[[ -f "$sidecar" ]] && rerun_hash="$rerun_hash:$(hash_file "$sidecar")"
	if [[ "$first_hash" == "$rerun_hash" ]]; then
		pass "$label same run is byte-idempotent"
	else
		fail "$label same run changed bytes"
	fi

	write_standard_deltas "$repo" second
	out="$(run_writer_id "$writer" "$repo" run-two)"
	assert_json "$out" ".sink == \"$expected_sink\"" "$label different run routes to $expected_sink"
	if [[ "$expected_sink" == "plan" ]]; then
		count="$(grep -Ec '^### Gauntlet design deltas \(run run-(one|two)\)$' "$plan")"
	else
		count="$(grep -Ec '^### Gauntlet design deltas \(run run-(one|two)\)$' "$sidecar")"
	fi
	if [[ "$count" -eq 2 ]]; then
		pass "$label different runs accumulate"
	else
		fail "$label different runs did not accumulate"
	fi
}

run_matrix_tests() {
	local markers findings
	for markers in 0 1 2; do
		for findings in none above-only one-below two-below inside-fence; do
			matrix_case "$WRITER" "$markers" "$findings"
		done
	done
}

run_replacement_test() {
	local repo plan once twice count
	repo="$WORKDIR/replacement"
	init_repo "$repo"
	write_shape_plan "$repo" 1 one-below
	plan="$repo/docs/dev_plans/20261016-feature-widget.md"
	write_resolution "$repo" unique docs/dev_plans/20261016-feature-widget.md
	write_standard_deltas "$repo" original
	run_writer_id "$WRITER" "$repo" run-one >/dev/null
	write_standard_deltas "$repo" replacement
	run_writer_id "$WRITER" "$repo" run-one >/dev/null
	once="$(hash_file "$plan")"
	run_writer_id "$WRITER" "$repo" run-one >/dev/null
	twice="$(hash_file "$plan")"
	count="$(grep -Fc '### Gauntlet design deltas (run run-one)' "$plan")"
	if [[ "$count" -eq 1 && "$once" == "$twice" ]] && grep -Fq 'Summary: replacement' "$plan" && ! grep -Fq 'Summary: original' "$plan"; then
		pass "same run replacement is stable and unique"
	else
		fail "same run replacement is not stable and unique"
	fi
}

run_sanitization_probe() {
	local writer="$1" repo plan line summary
	repo="$WORKDIR/sanitize-${writer##*/}-$RANDOM"
	init_repo "$repo"
	write_shape_plan "$repo" 1 one-below
	plan="$repo/docs/dev_plans/20261016-feature-widget.md"
	write_resolution "$repo" unique docs/dev_plans/20261016-feature-widget.md
	jq -cn --arg long "$(printf 'x%.0s' {1..501})" '[{
	  file:"bad\u0000\u001b\u2028\u2029<tag>&-->`name",
	  summary:$long,
	  decision:"# heading\r\nnext",
	  rationale:42,
	  cells:"- item"
	}, {
	  file:"12. list",
	  summary:null,
	  decision:false,
	  rationale:[],
	  cells:{}
	}]' >"$repo/deltas.json"
	run_writer_id "$writer" "$repo" run-one >/dev/null
	line="$(grep '^- File:' "$plan" | head -1)"
	summary="${line#*Summary: }"
	summary="${summary%%; Decision:*}"
	[[ ${#summary} -eq 500 ]] || return 1
	[[ "$line" == *"bad&lt;tag&gt;&amp;--&gt;'name"* ]] || return 1
	[[ "$line" == *"Decision: '# heading  next"* ]] || return 1
	[[ "$line" == *"Rationale: (invalid)"* ]] || return 1
	[[ "$line" == *"Cells: '- item"* ]] || return 1
	grep -Fq "File: '12. list" "$plan" || return 1
	[[ "$(grep -Fo '(invalid)' "$plan" | wc -l | tr -d ' ')" -ge 5 ]] || return 1
	! grep '^- File:' "$plan" | grep -q '`\|-->' || return 1
	[[ -z "$(LC_ALL=C tr -d '\11\12\40-\176' <"$plan")" ]] || return 1
}

run_sanitization_test() {
	if run_sanitization_probe "$WRITER"; then
		pass "untrusted fields are one-line capped escaped plain text"
	else
		fail "untrusted field sanitization contract"
	fi
}

run_sidecar_probe() {
	local writer="$1" repo sidecar
	repo="$WORKDIR/sidecar-probe-${writer##*/}-$RANDOM"
	init_repo "$repo"
	write_shape_plan "$repo" 0 none
	write_resolution "$repo" unique docs/dev_plans/20261016-feature-widget.md
	write_standard_deltas "$repo" first
	run_writer_id "$writer" "$repo" run-one >/dev/null
	write_standard_deltas "$repo" second
	run_writer_id "$writer" "$repo" run-two >/dev/null
	sidecar="$repo/.gauntlet/design-deltas-ledger-codex-widget.md"
	[[ "$(grep -Ec '^### Gauntlet design deltas \(run run-(one|two)\)$' "$sidecar")" -eq 2 ]]
}

run_marker_probe() {
	local writer="$1" repo plan before out
	repo="$WORKDIR/marker-probe-${writer##*/}-$RANDOM"
	init_repo "$repo"
	write_shape_plan "$repo" 2 one-below
	plan="$repo/docs/dev_plans/20261016-feature-widget.md"
	write_resolution "$repo" unique docs/dev_plans/20261016-feature-widget.md
	write_standard_deltas "$repo" first
	before="$(hash_file "$plan")"
	out="$(run_writer_id "$writer" "$repo" run-one)"
	jq -e '.sink == "sidecar"' >/dev/null <<<"$out" && [[ "$before" == "$(hash_file "$plan")" ]]
}

run_head_probe() {
	local resolver="$1" repo base_oid feature_oid out
	repo="$WORKDIR/head-probe-${resolver##*/}-$RANDOM"
	init_repo "$repo"
	base_oid="$(git -C "$repo" rev-parse HEAD)"
	git -C "$repo" switch -qc feature/widget
	add_plan "$repo" 20261016-feature-widget.md
	commit_plans "$repo" plan
	feature_oid="$(git -C "$repo" rev-parse HEAD)"
	git -C "$repo" switch -q main
	out="$("$resolver" --repo-root "$repo" --base "$base_oid" --head "$feature_oid" --branch feature/widget)"
	jq -e '.status == "unique" and (.plan | contains("widget"))' >/dev/null <<<"$out"
}

mutation_expect_failure() {
	local name="$1" probe="$2" mutant="$3" rc
	set +e
	"$probe" "$mutant" >/dev/null 2>&1
	rc=$?
	set -e
	if [[ "$rc" -ne 0 ]]; then
		pass "mutation $name is caught by $probe"
	else
		fail "mutation $name survived $probe"
	fi
}

run_mutation_checks() {
	local mutant_dir marker_mutant sidecar_mutant sanitize_mutant resolver_mutant
	mutant_dir="$WORKDIR/mutants"
	mkdir -p "$mutant_dir"
	cp "$STATE_GUARD" "$mutant_dir/state-path-guard.sh"

	marker_mutant="$mutant_dir/marker-writer.sh"
	sed -e 's/if (marker_count == 1) {/if (marker_count >= 1) {/' \
		-e 's/marker_line = NR/if (marker_count == 1) marker_line = NR/' \
		-e 's/if \[\[ "$marker_count" -ne 1 \]\]; then/if [[ "$marker_count" -eq 0 ]]; then/' \
		"$WRITER" >"$marker_mutant"
	chmod +x "$marker_mutant"
	mutation_expect_failure marker-count run_marker_probe "$marker_mutant"

	sidecar_mutant="$mutant_dir/sidecar-writer.sh"
	sed 's#upsert_section "$sidecar" "$output_tmp" 0 0 || die_env "cannot update sidecar temp file"#cp "$payload" "$output_tmp" || die_env "cannot update sidecar temp file"#' \
		"$WRITER" >"$sidecar_mutant"
	chmod +x "$sidecar_mutant"
	mutation_expect_failure sidecar-upsert run_sidecar_probe "$sidecar_mutant"

	sanitize_mutant="$mutant_dir/sanitize-writer.sh"
	sed '/gsub("<"; "&lt;")/d' "$WRITER" >"$sanitize_mutant"
	chmod +x "$sanitize_mutant"
	mutation_expect_failure sanitization run_sanitization_probe "$sanitize_mutant"

	resolver_mutant="$mutant_dir/head-resolver.sh"
	sed 's/"$base_oid"\.\.\."$head_oid"/"$base_oid"...HEAD/' "$RESOLVER" >"$resolver_mutant"
	chmod +x "$resolver_mutant"
	mutation_expect_failure reviewed-head run_head_probe "$resolver_mutant"
}

run_symlink_test() {
	local repo outside rc
	repo="$WORKDIR/symlink-state"
	init_repo "$repo"
	write_shape_plan "$repo" 0 none
	write_resolution "$repo" ambiguous ""
	write_standard_deltas "$repo" first
	outside="$WORKDIR/outside-state"
	mkdir -p "$outside"
	ln -s "$outside" "$repo/.gauntlet"
	set +e
	run_writer_id "$WRITER" "$repo" run-one >/dev/null 2>&1
	rc=$?
	set -e
	if [[ "$rc" -eq 2 && ! -e "$outside/design-deltas-ledger-codex-widget.md" ]]; then
		pass "write refuses a symlinked .gauntlet"
	else
		fail "write symlink refusal exit $rc or escaped write"
	fi
}

run_empty_test() {
	local repo out
	repo="$WORKDIR/empty"
	init_repo "$repo"
	write_shape_plan "$repo" 1 one-below
	write_resolution "$repo" unique docs/dev_plans/20261016-feature-widget.md
	jq -cn '[]' >"$repo/deltas.json"
	out="$(run_writer_id "$WRITER" "$repo" run-one)"
	assert_json "$out" '.sink == "none" and (keys | length) == 1' "write treats empty deltas as a no-op"
}

run_resolver_tests
run_matrix_tests
run_replacement_test
run_sanitization_test
run_symlink_test
run_empty_test
run_mutation_checks

echo
echo "$pass_count passed, $fail_count failed"
[[ "$fail_count" -eq 0 ]]
