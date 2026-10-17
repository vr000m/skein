#!/usr/bin/env bash
# Executes the Claude SKILL.md terminal design delta sink fence in scratch
# repos. The Codex twin is pinned by string assertions only; nothing else runs
# the Claude block, so its base/head/branch derivation for `pr:<N>`, a branch
# and a range had no executed coverage.
# shellcheck disable=SC2016,SC2030,SC2031,SC2034  # literal fixtures; per-case subshells set CLAUDE_PLUGIN_ROOT; PLAN_PATH is read by the sourced SKILL.md fence.

set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
PLUGIN_ROOT="$ROOT_DIR/plugins/skein"
# SKILL_MD may be overridden to run the suite against a mutated copy.
SKILL_MD="${SKILL_MD:-$PLUGIN_ROOT/skills/review-gauntlet/SKILL.md}"
LIB="$PLUGIN_ROOT/skills/review-gauntlet/lib"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/skein-sink-claude.XXXXXX")"
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

# The fence defines run_design_delta_sink and then calls it. Keep only the
# definition so each case can set its inputs first.
SINK_FN="$WORKDIR/sink-fn.sh"
sed -n '/^run_design_delta_sink() {$/,/^run_design_delta_sink || true$/p' "$SKILL_MD" | sed '$d' >"$SINK_FN"
if [[ ! -s "$SINK_FN" ]] || ! grep -q '^}$' "$SINK_FN"; then
	echo "FAIL: could not extract run_design_delta_sink from $SKILL_MD"
	exit 1
fi

PLAN_NAME=20261016-feature-widget.md
RANGE_PLAN=20261016-unrelated-name.md

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

write_plan() {
	local repo="$1" name="$2"
	printf '# Plan\n\n## Objective\n\nx\n\n<!-- reviewed: 2026-10-16 @ aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa -->\n\n## Findings\n\nExisting.\n\n## Progress\n\nDone.\n' \
		>"$repo/docs/dev_plans/$name"
	git -C "$repo" add "docs/dev_plans/$name"
	git -C "$repo" commit -qm "plan $name"
}

# new_fixture <name> <plan-name> -> repo on feature/widget with one changed plan
new_fixture() {
	local repo="$WORKDIR/$1"
	init_repo "$repo"
	git -C "$repo" switch -qc feature/widget
	write_plan "$repo" "$2"
	printf '%s\n' "$repo"
}

# write_round <run-dir> <n> <summary>
write_round() {
	mkdir -p "$1/round-$2"
	jq -cn --arg summary "$3" \
		'{claimed:[],design_deltas:[{file:"lib/a.sh",summary:$summary,decision:"d",rationale:"r",cells:"c"}]}' \
		>"$1/round-$2/fixer-report.json"
}

# run_sink <repo> <target> <rounds> [plan-path] [path-prefix]
# Prints the sink's stdout then "rc=<n>"; stderr goes to $WORKDIR/sink.err.
# The ledger gets <rounds> completed-round entries. A setup_hook function
# defined by the caller runs with the run dir to create the round dirs.
run_sink() {
	local repo="$1" target="$2" rounds="$3" plan="${4:-}" prefix="${5:-}"
	(
		cd "$repo"
		export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
		[[ -z "$prefix" ]] || export PATH="$prefix:$PATH"
		# shellcheck source=/dev/null
		. "$LIB/gauntlet-common.sh"
		canonical_target="$target"
		ledger_path="$(gc_ledger_path "$canonical_target" claude)"
		"$LIB/convergence-ledger.sh" --init --force --ledger "$ledger_path" --target "$canonical_target" >/dev/null
		run_dir="$("$LIB/convergence-ledger.sh" --run-dir --ledger "$ledger_path")"
		jq --argjson n "$rounds" '.rounds = [range($n) | {}]' "$ledger_path" >"$ledger_path.tmp"
		mv "$ledger_path.tmp" "$ledger_path"
		if declare -F setup_hook >/dev/null; then setup_hook "$run_dir"; fi
		PLAN_PATH="$plan"
		# shellcheck source=/dev/null
		. "$SINK_FN"
		set +e
		run_design_delta_sink
		echo "rc=$?"
	) 2>"$WORKDIR/sink.err"
}

# plan_has <repo> <needle> [plan-name]
plan_has() {
	grep -Fq -- "$2" "$1/docs/dev_plans/${3:-$PLAN_NAME}"
}

# --- 1. implicit branch target: plan found from the diff, rounds in order ----
repo="$(new_fixture implicit "$PLAN_NAME")"
setup_hook() {
	write_round "$1" 2 round-two
	write_round "$1" 10 round-ten
	write_round "$1" 11 beyond-ledger
}
out="$(run_sink "$repo" branch:feature/widget 10)"
unset -f setup_hook
check "implicit branch: prints the plan path" grep -Fq "Design deltas: docs/dev_plans/$PLAN_NAME" <<<"$out"
check "implicit branch: sink exits 0" grep -Fq 'rc=0' <<<"$out"
check "implicit branch: round 2 delta written" plan_has "$repo" 'Summary: round-two'
check "implicit branch: round 10 delta written" plan_has "$repo" 'Summary: round-ten'
check "implicit branch: a round beyond the ledger is not read" bash -c '! grep -Fq "beyond-ledger" "$1"' _ "$repo/docs/dev_plans/$PLAN_NAME"
check "implicit branch: rounds are in numeric order" bash -c '
	two="$(grep -n "Summary: round-two" "$1" | cut -d: -f1)"
	ten="$(grep -n "Summary: round-ten" "$1" | cut -d: -f1)"
	[[ -n "$two" && -n "$ten" && "$two" -lt "$ten" ]]' _ "$repo/docs/dev_plans/$PLAN_NAME"

# --- 2. a finished sink leaves the run dir clearable by a fresh --init -------
(
	cd "$repo"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	# shellcheck source=/dev/null
	. "$LIB/gauntlet-common.sh"
	lp="$(gc_ledger_path branch:feature/widget claude)"
	"$LIB/convergence-ledger.sh" --init --force --ledger "$lp" --target branch:feature/widget >/dev/null 2>"$WORKDIR/init.err"
	echo "$lp" >"$WORKDIR/init.ledger"
)
lp="$(cat "$WORKDIR/init.ledger")"
check "fresh --init clears the stale run dir with no warning" bash -c '
	! grep -q "leaving" "$1" && [[ ! -e "${2%.json}" ]]' _ "$WORKDIR/init.err" "$lp"

# --- 3. explicit range endpoints (two-dot and three-dot) ---------------------
# The plan name has no branch-slug match, so only the range diff can find it.
range_n=0
for range in 'branch:main..feature/widget' 'branch:main...feature/widget'; do
	range_n=$((range_n + 1))
	repo="$(new_fixture "range-$range_n" "$RANGE_PLAN")"
	setup_hook() { write_round "$1" 1 range-delta; }
	out="$(run_sink "$repo" "$range" 1)"
	unset -f setup_hook
	check "range $range: plan from the range diff" grep -Fq "Design deltas: docs/dev_plans/$RANGE_PLAN" <<<"$out"
	check "range $range: delta written" plan_has "$repo" 'Summary: range-delta' "$RANGE_PLAN"
done

# --- 4. pr:<N> through a fake gh ---------------------------------------------
# The checkout sits on a branch with an extra, unrelated plan. A HEAD-based
# derivation would see two changed plans and report "ambiguous"; the PR's own
# base/head OIDs see exactly one.
repo="$(new_fixture pr "$RANGE_PLAN")"
base_oid="$(git -C "$repo" rev-parse main)"
head_oid="$(git -C "$repo" rev-parse feature/widget)"
git -C "$repo" switch -qc elsewhere
write_plan "$repo" 20261016-other-thing.md
fake_bin="$WORKDIR/fake-gh-bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/gh" <<EOF
#!/usr/bin/env bash
[[ "\$1 \$2 \$3" == "pr view 42" ]] || exit 2
printf '{"baseRefOid":"$base_oid","headRefOid":"$head_oid","headRefName":"feature/widget"}\n'
EOF
chmod +x "$fake_bin/gh"
setup_hook() { write_round "$1" 1 pr-delta; }
out="$(run_sink "$repo" pr:42 1 "" "$fake_bin")"
unset -f setup_hook
check "pr: plan from gh base/head OIDs, not the checked-out HEAD" grep -Fq "Design deltas: docs/dev_plans/$RANGE_PLAN" <<<"$out"
check "pr: delta written" plan_has "$repo" 'Summary: pr-delta' "$RANGE_PLAN"

# gh failure: the sink must degrade to the sidecar and leave the plan alone.
repo="$(new_fixture pr-fail "$RANGE_PLAN")"
fail_bin="$WORKDIR/fail-gh-bin"
mkdir -p "$fail_bin"
printf '#!/usr/bin/env bash\nexit 1\n' >"$fail_bin/gh"
chmod +x "$fail_bin/gh"
before="$(git -C "$repo" hash-object "$repo/docs/dev_plans/$RANGE_PLAN")"
setup_hook() { write_round "$1" 1 sidecar-delta; }
out="$(run_sink "$repo" pr:42 1 "" "$fail_bin")"
unset -f setup_hook
check "pr: gh failure leaves the plan unchanged" bash -c '[[ "$(git -C "$1" hash-object "$1/docs/dev_plans/$2")" == "$3" ]]' _ "$repo" "$RANGE_PLAN" "$before"
check "pr: gh failure routes deltas to the .gauntlet sidecar" bash -c 'grep -Fq "Design deltas: .gauntlet/design-deltas-" <<<"$1"' _ "$out"
check "pr: sidecar holds the delta" bash -c 'grep -Fl "Summary: sidecar-delta" "$1"/.gauntlet/design-deltas-*.md >/dev/null' _ "$repo"

# --- 5. explicit --plan ------------------------------------------------------
repo="$(new_fixture explicit 20261016-nothing-relevant.md)"
write_plan "$repo" "$PLAN_NAME"
setup_hook() { write_round "$1" 1 explicit-delta; }
out="$(run_sink "$repo" branch:feature/widget 1 "docs/dev_plans/$PLAN_NAME")"
unset -f setup_hook
check "explicit --plan wins over resolution" grep -Fq "Design deltas: docs/dev_plans/$PLAN_NAME" <<<"$out"

# --- 6. missing context: warn and skip, never write below / -----------------
repo="$(new_fixture unset "$PLAN_NAME")"
out="$(
	cd "$repo"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	unset canonical_target ledger_path run_dir
	# shellcheck source=/dev/null
	. "$SINK_FN"
	run_design_delta_sink 2>&1
	echo "rc=$?"
)"
check "unset context: sink warns and skips" grep -Fq 'skipping' <<<"$out"
check "unset context: sink exits 0" grep -Fq 'rc=0' <<<"$out"
check "unset context: no filesystem-root write attempted" bash -c '! grep -Eq "Read-only file system|Permission denied" <<<"$1"' _ "$out"

# --- 7. a symlinked working file is refused, never followed ------------------
repo="$(new_fixture symlink "$PLAN_NAME")"
outside="$WORKDIR/outside-target"
: >"$outside"
setup_hook() {
	ln -s "$outside" "${1%/*}/design-deltas-${1##*/}.items.jsonl"
	write_round "$1" 1 symlink-delta
}
out="$(run_sink "$repo" branch:feature/widget 1)"
unset -f setup_hook
check "symlinked working file: nothing written through the link" bash -c '[[ ! -s "$1" ]]' _ "$outside"
check "symlinked working file: sink still exits 0" grep -Fq 'rc=0' <<<"$out"
check "symlinked working file: the refusal is reported" grep -Fq 'refusing to operate on symlink' "$WORKDIR/sink.err"

echo
echo "$pass_count passed, $fail_count failed"
[[ "$fail_count" -eq 0 ]]
