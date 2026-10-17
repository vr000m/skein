#!/usr/bin/env bash
# Executes the Codex SKILL.md terminal design-delta sink fence. Covers the
# persisted review scope, stable run identity, and guarded fixer-report reads.
# shellcheck disable=SC2016,SC2034  # bash -c probes are literal; SKILL.md fence consumes conductor variables.

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
check "resume: first delta remains present once" bash -c '[[ "$(grep -Fc "Summary: first-delta" "$1")" -eq 1 ]]' _ "$plan"
check "resume: second delta is added to the same section" grep -Fq 'Summary: second-delta' "$plan"
check "resume: one stable run section is present" bash -c '[[ "$(grep -c "^### Gauntlet design deltas (run codex-" "$1")" -eq 1 ]]' _ "$plan"
check "resume: no sidecar is created after shell state is lost" bash -c '! compgen -G "$1/.gauntlet/design-deltas-*.md" >/dev/null' _ "$repo"

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
