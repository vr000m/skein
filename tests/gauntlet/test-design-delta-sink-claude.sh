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
		export CLAUDE_PLUGIN_ROOT="${SINK_PLUGIN_ROOT:-$PLUGIN_ROOT}"
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
		if [[ "${SINK_HOSTILE_GIT:-false}" == true ]]; then
			GIT_INDEX_FILE=/nonexistent GIT_DIR=/nonexistent GIT_WORK_TREE="$WORKDIR" \
				GIT_CEILING_DIRECTORIES="$repo" run_design_delta_sink
		else
			run_design_delta_sink
		fi
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
check "implicit branch: round 2 delta written" plan_has "$repo" 'Summary: "round-two"'
check "implicit branch: round 10 delta written" plan_has "$repo" 'Summary: "round-ten"'
check "implicit branch: a round beyond the ledger is not read" bash -c '! grep -Fq "beyond-ledger" "$1"' _ "$repo/docs/dev_plans/$PLAN_NAME"
check "implicit branch: rounds are in numeric order" bash -c '
	two="$(grep -n "Summary: \"round-two\"" "$1" | cut -d: -f1)"
	ten="$(grep -n "Summary: \"round-ten\"" "$1" | cut -d: -f1)"
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
	check "range $range: delta written" plan_has "$repo" 'Summary: "range-delta"' "$RANGE_PLAN"
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
check "pr: delta written" plan_has "$repo" 'Summary: "pr-delta"' "$RANGE_PLAN"

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
check "pr: sidecar holds the delta" bash -c 'grep -Fl "Summary: \"sidecar-delta\"" "$1"/.gauntlet/design-deltas-*.md >/dev/null' _ "$repo"

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

# --- 8. seam-tripwire escalation is sidecar-only -----------------------------
# The escalation is resumable, and apply-auto-fix-code.sh refuses a dirty
# worktree on --resume, so even a diff-touched plan must stay byte-identical.
# probe_seam [sink-fn] -> 0 when no tracked file changed and the sidecar holds the delta
probe_seam() {
	local repo before out
	repo="$(new_fixture "seam-$RANDOM" "$PLAN_NAME")"
	before="$(git -C "$repo" hash-object "$repo/docs/dev_plans/$PLAN_NAME")"
	setup_hook() { write_round "$1" 1 seam-delta; }
	out="$(SINK_FN="${1:-$SINK_FN}" design_delta_sidecar_only=true run_sink "$repo" branch:feature/widget 1)"
	unset -f setup_hook
	[[ "$(git -C "$repo" hash-object "$repo/docs/dev_plans/$PLAN_NAME")" == "$before" ]] &&
		git -C "$repo" diff --quiet &&
		grep -Fq 'Design deltas: .gauntlet/design-deltas-' <<<"$out" &&
		grep -Fl 'Summary: "seam-delta"' "$repo"/.gauntlet/design-deltas-*.md >/dev/null 2>&1
}
check "seam escalation: plan bytes unchanged, delta lands in the sidecar" probe_seam
# Control: the same fixture without the flag edits the plan, so the probe is not vacuous.
repo="$(new_fixture seam-control "$PLAN_NAME")"
setup_hook() { write_round "$1" 1 seam-delta; }
out="$(run_sink "$repo" branch:feature/widget 1)"
unset -f setup_hook
check "seam control: without the flag the diff-touched plan is the sink" plan_has "$repo" 'Summary: "seam-delta"'
seam_mutant="$WORKDIR/seam-mutant.sh"
sed 's/if \[\[ "${design_delta_sidecar_only:-false}" == true \]\]; then/if false; then/' "$SINK_FN" >"$seam_mutant"
check "mutation: dropping the sidecar-only branch is caught" bash -c '! cmp -s "$1" "$2"' _ "$SINK_FN" "$seam_mutant"
if probe_seam "$seam_mutant"; then
	fail "mutation seam-sidecar-only survived its regression probe"
else
	pass "mutation seam-sidecar-only is caught by the executed sink probe"
fi

# The writer must receive --sidecar-only (never a forged --resolution) and
# report its own reason. A shim plugin root logs the writer's argv and stdout.
shim_root="$WORKDIR/shim-root"
mkdir -p "$shim_root/skills/review-gauntlet"
cp -R "$LIB" "$shim_root/skills/review-gauntlet/lib"
cat >"$shim_root/skills/review-gauntlet/lib/write-design-deltas.sh" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >"$WORKDIR/writer.args"
"$LIB/write-design-deltas.sh" "\$@" | tee "$WORKDIR/writer.out"
exit "\${PIPESTATUS[0]}"
SHIM
chmod +x "$shim_root/skills/review-gauntlet/lib/write-design-deltas.sh"
# probe_seam_handoff [sink-fn] -> 0 when the writer ran in sidecar-only mode and gave the reason
probe_seam_handoff() {
	local repo before out
	repo="$(new_fixture "seam-handoff-$RANDOM" "$PLAN_NAME")"
	before="$(git -C "$repo" hash-object "$repo/docs/dev_plans/$PLAN_NAME")"
	: >"$WORKDIR/writer.args"
	: >"$WORKDIR/writer.out"
	setup_hook() { write_round "$1" 1 seam-delta; }
	out="$(SINK_FN="${1:-$SINK_FN}" SINK_PLUGIN_ROOT="$shim_root" design_delta_sidecar_only=true run_sink "$repo" branch:feature/widget 1)"
	unset -f setup_hook
	grep -Fq 'rc=0' <<<"$out" &&
		[[ "$(git -C "$repo" hash-object "$repo/docs/dev_plans/$PLAN_NAME")" == "$before" ]] &&
		grep -Fq -- '--sidecar-only' "$WORKDIR/writer.args" &&
		! grep -Fq -- '--resolution' "$WORKDIR/writer.args" &&
		[[ "$(jq -r '.reason' "$WORKDIR/writer.out")" == 'seam-tripwire escalation is sidecar-only' ]] &&
		grep -Fl 'Summary: "seam-delta"' "$repo"/.gauntlet/design-deltas-*.md >/dev/null 2>&1
}
check "seam escalation: writer gets --sidecar-only and reports its own reason" probe_seam_handoff
# Mutant: the previous forged status-none resolution passed through --resolution.
forged_mutant="$WORKDIR/forged-mutant.sh"
forged_src="$(cat "$SINK_FN")"
forged_old='writer_args+=(--sidecar-only)'
forged_new='jq -cn '"'"'{status:"none",plan:"",reason:"seam-tripwire escalation is sidecar-only"}'"'"' >"$resolution_file"; writer_args+=(--resolution "$resolution_file")'
printf '%s\n' "${forged_src/"$forged_old"/$forged_new}" >"$forged_mutant"
check "mutation: sidecar-only handoff was rewritten" bash -c 'grep -Fq -- "$3" "$1" && ! grep -Fq -- "$3" "$2"' _ "$SINK_FN" "$forged_mutant" "$forged_old"
if probe_seam_handoff "$forged_mutant"; then
	fail "mutation forged-resolution survived its regression probe"
else
	pass "mutation forged-resolution is caught by the executed sink probe"
fi

# --- 9. a non-integer ledger round count fails closed ------------------------
# probe_rounds [sink-fn] -> 0 when the sink warns, exits 0 and leaves the plan alone
probe_rounds() {
	local repo before out
	repo="$(new_fixture "rounds-$RANDOM" "$PLAN_NAME")"
	before="$(git -C "$repo" hash-object "$repo/docs/dev_plans/$PLAN_NAME")"
	setup_hook() {
		write_round "$1" 1 rounds-delta
		# `.rounds | length` of a number is its absolute value: 1.5 here.
		jq '.rounds = 1.5' "$ledger_path" >"$ledger_path.tmp" && mv "$ledger_path.tmp" "$ledger_path"
	}
	out="$(SINK_FN="${1:-$SINK_FN}" run_sink "$repo" branch:feature/widget 1)"
	unset -f setup_hook
	grep -Fq 'rc=0' <<<"$out" &&
		grep -Fq 'ledger round count is not an integer' "$WORKDIR/sink.err" &&
		[[ "$(git -C "$repo" hash-object "$repo/docs/dev_plans/$PLAN_NAME")" == "$before" ]]
}
check "non-integer round count: warning, exit 0, plan unchanged" probe_rounds
# probe_rounds_array [sink-fn] -> 0 when a non-array .rounds fails closed.
# `.rounds | length` of the string "x" is the integer 1, so only the array
# check refuses it.
probe_rounds_array() {
	local repo before out
	repo="$(new_fixture "rounds-array-$RANDOM" "$PLAN_NAME")"
	before="$(git -C "$repo" hash-object "$repo/docs/dev_plans/$PLAN_NAME")"
	setup_hook() {
		write_round "$1" 1 rounds-delta
		jq '.rounds = "x"' "$ledger_path" >"$ledger_path.tmp" && mv "$ledger_path.tmp" "$ledger_path"
	}
	out="$(SINK_FN="${1:-$SINK_FN}" run_sink "$repo" branch:feature/widget 1)"
	unset -f setup_hook
	grep -Fq 'rc=0' <<<"$out" &&
		! grep -Fq 'Design deltas:' <<<"$out" &&
		grep -Fq 'ledger round count is not an integer' "$WORKDIR/sink.err" &&
		[[ "$(git -C "$repo" hash-object "$repo/docs/dev_plans/$PLAN_NAME")" == "$before" ]]
}
check "non-array rounds: warning, exit 0, no Design deltas line, plan unchanged" probe_rounds_array
array_mutant="$WORKDIR/rounds-array-mutant.sh"
sed 's/\.rounds | select(type == "array") | length/.rounds | length/' "$SINK_FN" >"$array_mutant"
check "mutation: rounds array check was rewritten" bash -c '! cmp -s "$1" "$2"' _ "$SINK_FN" "$array_mutant"
if probe_rounds_array "$array_mutant"; then
	fail "mutation rounds-array survived its regression probe"
else
	pass "mutation rounds-array is caught by the executed sink probe"
fi
rounds_mutant="$WORKDIR/rounds-mutant.sh"
sed 's/if \[\[ ! "$round_count" =~ ^\[0-9\]+\$ \]\]; then/if false; then/' "$SINK_FN" >"$rounds_mutant"
check "mutation: rounds integer check was rewritten" bash -c '! cmp -s "$1" "$2"' _ "$SINK_FN" "$rounds_mutant"
if probe_rounds "$rounds_mutant"; then
	fail "mutation rounds-integer survived its regression probe"
else
	pass "mutation rounds-integer is caught by the executed sink probe"
fi

# --- 10. a two-dot range records its left endpoint as the review base -------
# The resolver diffs base...head, so plan resolution is the same either way;
# the observable is the persisted scope's base_oid.
# probe_two_dot [sink-fn] -> 0 when base_oid is the left endpoint, not merge-base
probe_two_dot() {
	local repo out side_oid mb_oid
	repo="$(new_fixture "two-dot-$RANDOM" "$RANGE_PLAN")"
	git -C "$repo" switch -qc side main
	printf 'side\n' >"$repo/side.txt"
	git -C "$repo" add side.txt
	git -C "$repo" commit -qm side
	git -C "$repo" switch -q feature/widget
	side_oid="$(git -C "$repo" rev-parse side)"
	mb_oid="$(git -C "$repo" merge-base side feature/widget)"
	[[ "$side_oid" != "$mb_oid" ]] || return 1
	setup_hook() { write_round "$1" 1 two-dot-delta; }
	out="$(SINK_FN="${1:-$SINK_FN}" run_sink "$repo" branch:side..feature/widget 1)"
	unset -f setup_hook
	grep -Fq 'rc=0' <<<"$out" &&
		[[ "$(jq -r '.base_oid' "$repo"/.gauntlet/design-deltas-*.scope.json)" == "$side_oid" ]]
}
check "two-dot range: left endpoint is the recorded review base" probe_two_dot
two_dot_mutant="$WORKDIR/two-dot-mutant.sh"
sed 's/if \[\[ "$range_kind" == two-dot \]\]; then/if false; then/' "$SINK_FN" >"$two_dot_mutant"
check "mutation: two-dot base rule was rewritten" bash -c '! cmp -s "$1" "$2"' _ "$SINK_FN" "$two_dot_mutant"
if probe_two_dot "$two_dot_mutant"; then
	fail "mutation two-dot-left-endpoint survived its regression probe"
else
	pass "mutation two-dot-left-endpoint is caught by the executed sink probe"
fi

# --- 11. option guards on range ends and PR numbers --------------------------
real_git="$(command -v git)"
log_bin="$WORKDIR/log-bin"
mkdir -p "$log_bin"
cat >"$log_bin/git" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$WORKDIR/git.log"
exec "$real_git" "\$@"
EOF
cat >"$log_bin/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$WORKDIR/gh.log"
exit 1
EOF
chmod +x "$log_bin/git" "$log_bin/gh"

# probe_dash_range <target> [sink-fn] -> 0 when the dash end only reaches git after --end-of-options
probe_dash_range() {
	local repo before out
	repo="$(new_fixture "dash-$RANDOM" "$PLAN_NAME")"
	before="$(git -C "$repo" hash-object "$repo/docs/dev_plans/$PLAN_NAME")"
	: >"$WORKDIR/git.log"
	setup_hook() { write_round "$1" 1 dash-delta; }
	out="$(SINK_FN="${2:-$SINK_FN}" run_sink "$repo" "$1" 1 "" "$log_bin")"
	unset -f setup_hook
	grep -Fq 'rc=0' <<<"$out" &&
		[[ "$(git -C "$repo" hash-object "$repo/docs/dev_plans/$PLAN_NAME")" == "$before" ]] &&
		grep -Eq '^(-C [^ ]+ )?(merge-base|rev-parse --verify --quiet) .*--all' "$WORKDIR/git.log" &&
		! grep -E '^(-C [^ ]+ )?(merge-base|rev-parse --verify --quiet) ' "$WORKDIR/git.log" | grep -F -- '--all' | grep -vqF -- '--end-of-options'
}
dash_mutant="$WORKDIR/dash-mutant.sh"
sed 's/ --end-of-options / /' "$SINK_FN" >"$dash_mutant"
check "mutation: option guard was removed" bash -c '! cmp -s "$1" "$2"' _ "$SINK_FN" "$dash_mutant"
for dash_target in 'branch:--all..feature/widget' 'branch:main..--all'; do
	check "dash range end $dash_target: reaches git only after --end-of-options" probe_dash_range "$dash_target"
	if probe_dash_range "$dash_target" "$dash_mutant"; then
		fail "mutation option-guard survived for $dash_target"
	else
		pass "mutation option-guard is caught for $dash_target"
	fi
done

# probe_dropped [sink-fn] -> 0 when a writer "dropped" result prints count + reason, never "none"
probe_dropped() {
	local repo out slug reason dropped_root
	for slug in sidecar sidecar-temp became-tracked; do
		case "$slug" in
		sidecar) reason="design-delta sidecar is tracked, non-regular, or cannot be classified" ;;
		sidecar-temp) reason="design-delta sidecar temp path is tracked, non-regular, indeterminate, or occupied" ;;
		became-tracked) reason="design-delta sidecar became tracked, non-regular, or indeterminate before replace" ;;
		esac
		dropped_root="$WORKDIR/dropped-root-$slug-$RANDOM"
		mkdir -p "$dropped_root/skills/review-gauntlet"
		cp -R "$LIB" "$dropped_root/skills/review-gauntlet/lib"
		cat >"$dropped_root/skills/review-gauntlet/lib/write-design-deltas.sh" <<SHIM
#!/usr/bin/env bash
jq -cn --arg reason "$reason" '{sink:"dropped",path:"",reason:\$reason}'
SHIM
		chmod +x "$dropped_root/skills/review-gauntlet/lib/write-design-deltas.sh"
		repo="$(new_fixture "dropped-$slug-$RANDOM" "$PLAN_NAME")"
		setup_hook() { write_round "$1" 1 dropped-delta; }
		out="$(SINK_FN="${1:-$SINK_FN}" SINK_PLUGIN_ROOT="$dropped_root" run_sink "$repo" branch:feature/widget 1)"
		unset -f setup_hook
		grep -Fq 'rc=0' <<<"$out" || return 1
		grep -Fxq "warning: Design deltas: 1 dropped — $reason" "$WORKDIR/sink.err" || return 1
		! grep -Fq 'Design deltas: none' <<<"$out" || return 1
	done
}
check "dropped writer results print their count and reason, never 'none'" probe_dropped
dropped_mutant="$WORKDIR/dropped-mutant.sh"
sed 's/elif \[\[ "\$sink_name" == "dropped" \]\]; then/elif false; then/' "$SINK_FN" >"$dropped_mutant"
check "mutation: dropped branch was rewritten" bash -c '! cmp -s "$1" "$2"' _ "$SINK_FN" "$dropped_mutant"
if probe_dropped "$dropped_mutant"; then
	fail "mutation dropped-reporting survived its regression probe"
else
	pass "mutation dropped-reporting is caught by the executed sink probe"
fi

# probe_pr_suffix [sink-fn] -> 0 when a non-numeric PR suffix never reaches gh
probe_pr_suffix() {
	local repo out
	repo="$(new_fixture "prsuffix-$RANDOM" "$PLAN_NAME")"
	: >"$WORKDIR/gh.log"
	setup_hook() { write_round "$1" 1 suffix-delta; }
	out="$(SINK_FN="${1:-$SINK_FN}" run_sink "$repo" 'pr:--repo=evil/x' 1 "" "$log_bin")"
	unset -f setup_hook
	grep -Fq 'rc=0' <<<"$out" &&
		grep -Fq 'refused non-numeric PR target' "$WORKDIR/sink.err" &&
		[[ ! -s "$WORKDIR/gh.log" ]]
}
check "pr: a non-numeric suffix is refused before gh runs" probe_pr_suffix
pr_mutant="$WORKDIR/pr-mutant.sh"
sed 's/if \[\[ ! "$pr_number" =~ ^\[0-9\]+\$ \]\]; then/if false; then/' "$SINK_FN" >"$pr_mutant"
check "mutation: PR number check was rewritten" bash -c '! cmp -s "$1" "$2"' _ "$SINK_FN" "$pr_mutant"
if probe_pr_suffix "$pr_mutant"; then
	fail "mutation pr-numeric survived its regression probe"
else
	pass "mutation pr-numeric is caught by the executed sink probe"
fi

# --- 12. a failed working-file reset never consumes stale state ---------------
# probe_reset [sink-fn] -> 0 when an unwritable stale items file aborts the sink
probe_reset() {
	local repo before out
	repo="$(new_fixture "reset-$RANDOM" "$PLAN_NAME")"
	before="$(git -C "$repo" hash-object "$repo/docs/dev_plans/$PLAN_NAME")"
	setup_hook() {
		local items="${1%/*}/design-deltas-${1##*/}.items.jsonl"
		write_round "$1" 1 current-delta
		jq -cn '{file:"stale",summary:"stale-delta",decision:"d",rationale:"r",cells:"c"}' >"$items"
		chmod 400 "$items"
	}
	out="$(SINK_FN="${1:-$SINK_FN}" run_sink "$repo" branch:feature/widget 1)"
	unset -f setup_hook
	grep -Fq 'rc=0' <<<"$out" &&
		grep -Fq 'cannot initialize design delta collection' "$WORKDIR/sink.err" &&
		[[ "$(git -C "$repo" hash-object "$repo/docs/dev_plans/$PLAN_NAME")" == "$before" ]] &&
		! grep -rqF 'stale-delta' "$repo/.gauntlet" --include='design-deltas-*.md'
}
check "reset failure: sink aborts before stale working files are consumed" probe_reset
reset_mutant="$WORKDIR/reset-mutant.sh"
sed '/cannot initialize design delta collection/{n;n;/return 0/d;}' "$SINK_FN" >"$reset_mutant"
check "mutation: reset return was removed" bash -c '! cmp -s "$1" "$2"' _ "$SINK_FN" "$reset_mutant"
if probe_reset "$reset_mutant"; then
	fail "mutation reset-fail-closed survived its regression probe"
else
	pass "mutation reset-fail-closed is caught by the executed sink probe"
fi

# Parameterised twin of the Codex collection-failure cell. This intentionally
# fails until the conductor mirrors the Codex sink block into the Claude skill.
probe_collection_failure() {
	local repo out shim_dir jq_real
	repo="$(new_fixture "collection-failure-$RANDOM" "$PLAN_NAME")"
	shim_dir="$repo/jq-shim"
	jq_real="$(command -v jq)"
	mkdir -p "$shim_dir"
	cat >"$shim_dir/jq" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == -s ]] && exit 9
exec "$REAL_JQ" "$@"
SH
	chmod +x "$shim_dir/jq"
	setup_hook() { write_round "$1" 1 current-delta; }
	out="$(REAL_JQ="$jq_real" SINK_FN="${1:-$SINK_FN}" run_sink "$repo" branch:feature/widget 1 "" "$shim_dir")"
	unset -f setup_hook
	grep -Fq 'Design deltas: unknown — collection failed or the items file is unreadable' "$WORKDIR/sink.err" &&
		! grep -Fq 'Design deltas: none' <<<"$out"
}
check "Claude mirror pending: failed jq collection with non-empty items reports unknown, never none" probe_collection_failure

# --- 13. tracked working paths are immutable under clean/hostile Git env ----
probe_tracked_working_path() {
	local kind="$1" env_mode="$2" repo out path before_path
	repo="$(new_fixture "tracked-$kind-$env_mode-$RANDOM" "$PLAN_NAME")"
	setup_hook() {
		local run_dir="$1" target_key ledger_run_id run_id state_dir rel
		write_round "$run_dir" 1 tracked-delta
		target_key="$(basename "${ledger_path%.json}")"
		ledger_run_id="$(jq -r .run_id "$ledger_path")"
		run_id="claude-${ledger_run_id:0:12}"
		state_dir="$(dirname "$ledger_path")"
		case "$kind" in
		items) path="$state_dir/design-deltas-$target_key.items.jsonl" ;;
		deltas) path="$state_dir/design-deltas-$target_key.deltas.json" ;;
		resolution) path="$state_dir/design-deltas-$target_key.resolution.json" ;;
		scope) path="$state_dir/design-deltas-$target_key-$run_id.scope.json" ;;
		esac
		if [[ "$kind" == scope ]]; then
			jq -cn --arg run_id "$run_id" --arg target branch:feature/widget \
				'{run_id:$run_id,target:$target,base_oid:"",head_oid:"",branch:"feature/widget"}' >"$path"
		else
			printf 'tracked-%s-%s\n' "$kind" "$env_mode" >"$path"
		fi
		rel="${path#"$repo"/}"
		git -C "$repo" add -f -- "$rel"
		printf '%s\n%s\n' "$path" "$(git -C "$repo" hash-object "$path")" >"$WORKDIR/tracked-path-state"
	}
	if [[ "$env_mode" == hostile ]]; then
		out="$(SINK_HOSTILE_GIT=true run_sink "$repo" branch:feature/widget 1)"
	else
		out="$(run_sink "$repo" branch:feature/widget 1)"
	fi
	unset -f setup_hook
	path="$(sed -n '1p' "$WORKDIR/tracked-path-state")"
	before_path="$(sed -n '2p' "$WORKDIR/tracked-path-state")"
	grep -Fq 'rc=0' <<<"$out" &&
		[[ "$before_path" == "$(git -C "$repo" hash-object "$path")" ]] &&
		grep -Eq 'tracked or indeterminate design delta|refusing to write tracked design delta path' "$WORKDIR/sink.err"
}

for tracked_env in clean hostile; do
	for tracked_kind in items deltas resolution scope; do
		check "tracked $tracked_kind ($tracked_env): bytes preserved and refusal reported" \
			probe_tracked_working_path "$tracked_kind" "$tracked_env"
	done
done

echo
echo "$pass_count passed, $fail_count failed"
[[ "$fail_count" -eq 0 ]]
