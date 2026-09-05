#!/usr/bin/env bash
# test-fanout-slug-guard-codex.sh — regression suite for the task-slug guard in
# plugins/skein-codex/skills/fan-out/fan-out.sh cmd_setup.
#
# WHY THIS FILE EXISTS. fan-out's SKILL.md used to carry a ~25-line inline
# decode-and-validate block that re-implemented the slug boundary in prose,
# with a contract that differed from the script's own slugify(). The prose was
# replaced by a short "validate, then hand the slug over in a file" rule, which
# moves the enforcing boundary into cmd_setup: the script must fail closed on
# any slug that is not <task-id>-<lowercase-slug>, so a plan-derived string that
# skipped the caller's check never reaches `git worktree add`.
#
# The invariant asserted here has three parts.
#
# SLUG. cmd_setup accepts a slug iff it matches ^[0-9]+-[a-z0-9-]+$ AND is a
# fixed point of the script's own slugify() -- no doubled hyphen, no leading or
# trailing hyphen, 50 characters or fewer. The regex alone is not enough:
# slugify() collapses '--', strips edge hyphens and truncates, so without the
# fixed-point half two distinct slugs that both match the regex (1-foo--bar and
# 1-foo-bar) would map to one branch and one worktree. Everything else is
# refused with a non-zero exit and a "refusing task slug" message on stderr.
# Acceptance is asserted the other way round too: an accepted slug is used
# VERBATIM, so the worktree path ends in -fanout-<slug> and the branch is
# refs/heads/fanout/main-<slug>. Without that half the fixed-point guard's
# anti-collision purpose would be untested.
#
# BASE BRANCH. The base branch reaches `git worktree add` as a revision
# argument, so it is validated at the same boundary: a leading '-' (which git
# would parse as an option) and anything `git check-ref-format` rejects are
# refused with "refusing base branch".
#
# TASK BINDING. The shape guards above can only ever say whether a slug is
# WELL-FORMED, never whether it names the task the user approved. While the
# model derived the slug itself, `7-delete-api` and `7-add-api` were equally
# acceptable for approved task 7 -- and setup force-removes whatever worktree
# already stands at the path it derives. So the slug is no longer accepted at
# all in the skill's call shape: `setup <base> --plan <path> --task-id N
# --plan-sha256 <hex> <repo-root>` takes an ORDINAL and a plan DIGEST, and
# re-derives task N's slug from the plan's own bytes with the same function
# `tasks` published them with. The tests below assert the four halves of that:
# ordinals are numbered 1-based over both `- [ ]` and `- [x]` lines (so ticking
# a box mid-run does not renumber later tasks), a mismatched same-ID slug has no
# input that produces it, an absent ordinal and a stale digest both refuse with
# no worktree created, and the plan path is containment-guarded before it is
# read. The positional `setup <base> <slug> <repo-root>` form is kept as a
# test-only entry point, which is how the regex and fixed-point branches above
# are still driven directly.
#
# CLEANUP REPO ROOT. `cleanup` drives worktree removal, branch deletion and an
# `rm -rf` from a repo_root parsed out of the state file, which is an ordinary
# file in the tree. Checking that value against itself proves nothing, so the
# trust anchor is git: a repo_root that is not the root of a real checkout is
# refused before any destructive command runs. That belongs here because it is
# the same "never trust a value the tree can author" boundary as the plan file.
#
# CLEANUP TARGETS. The same file names a `worktree` and a `branch` per agent,
# and both used to reach git. Neither does now. `git worktree list --porcelain`
# is the only authority: an entry is a target iff its path is a sibling of the
# repo root named `<repo-name>-fanout-<task-id>-<slug>` -- the suffix tested with
# the same expression cmd_setup accepts a slug by, so a hand-made sibling with an
# empty or arbitrary suffix is not a target -- AND git has it attached to a
# branch under `refs/heads/fanout/`, and the branch deleted is the one git attached to
# it. That listing keeps a hand-deleted worktree (marked `prunable`) with its
# `branch` line, which is why no state-file fallback is needed. `agents[]` is
# read for a diagnostic only: a worktree it names that git does not attribute
# to fan-out is warned about and left alone, with no git call.
#
# CLEANUP REPO ROOT SPELLING. `setup` normalises its repo-root argument once
# and builds the worktree path from that single value, so the path the script
# creates is the path its own guards judged: a root spelled `<repo>/.` used to
# yield basename `.` and a worktree nested inside the checkout that cleanup
# then refused to remove.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FANOUT_SH="$REPO_ROOT/plugins/skein-codex/skills/fan-out/fan-out.sh"

PASS_COUNT=0
FAIL_COUNT=0

pass() {
	PASS_COUNT=$((PASS_COUNT + 1))
	echo "ok: $1"
}

fail() {
	FAIL_COUNT=$((FAIL_COUNT + 1))
	echo "FAIL: $1" >&2
}

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# --- Scratch repo: one commit on branch main --------------------------------
SCRATCH="$WORKDIR/repo"
mkdir -p "$SCRATCH"
git -C "$SCRATCH" init -q -b main
git -C "$SCRATCH" config user.email "test@example.invalid"
git -C "$SCRATCH" config user.name "slug guard test"
printf 'seed\n' >"$SCRATCH/README.md"
git -C "$SCRATCH" add README.md
git -C "$SCRATCH" commit -q -m "seed"

# run_setup_base <base-branch> <slug> — echo rc on line 1, output on the rest.
run_setup_base() {
	local out rc
	set +e
	out="$(bash "$FANOUT_SH" setup "$1" "$2" "$SCRATCH" 2>&1)"
	rc=$?
	set -e
	printf '%s\n%s\n' "$rc" "$out"
}

# run_setup <slug> — the same against the scratch repo's own branch, main.
run_setup() {
	run_setup_base main "$1"
}

# --- plan fixture: the checklist every task-binding test derives from --------
# Ordinals are assigned over BOTH box states, so the ticked first item is task 1
# and `- [ ] Add API endpoint` is task 7 -- which is the fixture the
# mismatched-same-ID test needs.
PLAN_DIR="$SCRATCH/docs"
mkdir -p "$PLAN_DIR"
PLAN="$PLAN_DIR/plan.md"

write_plan() {
	cat >"$PLAN" <<'PLANEOF'
# Feature plan

## Implementation Checklist

- [x] First done thing
- [ ] Second thing
- [ ] Third thing
- [ ] Fourth thing
- [ ] Fifth thing
- [ ] Sixth thing
- [ ] Add API endpoint
- [ ] rm -rf $(whoami); "drop"

## Notes

- [ ] Not a checklist task
PLANEOF
}

plan_sha() {
	shasum -a 256 "$PLAN" | awk '{print $1}'
}

# run_setup_plan <task-id> <sha> [plan-path] — the derived call shape.
run_setup_plan() {
	local out rc plan="${3:-$PLAN}"
	set +e
	out="$(bash "$FANOUT_SH" setup main --plan "$plan" --task-id "$1" --plan-sha256 "$2" "$SCRATCH" 2>&1)"
	rc=$?
	set -e
	printf '%s\n%s\n' "$rc" "$out"
}

# siblings_named <suffix> — how many sibling dirs `repo-fanout-<suffix>` exist.
# Used to assert that a refused call created no worktree anywhere.
sibling_exists() {
	[[ -e "$WORKDIR/repo-fanout-$1" ]]
}

# assert_verbatim <label> <slug> <printed-path> — the accepted slug is the one
# git actually saw: the worktree basename ends in -fanout-<slug> and the branch
# is refs/heads/fanout/<base-slug>-<slug>. This is the half that makes the
# fixed-point guard's anti-collision claim testable.
assert_verbatim() {
	local label="$1" slug="$2" path="$3"
	if [[ "$path" != *"-fanout-$slug" ]]; then
		fail "$label: worktree path '$path' does not end in -fanout-$slug"
		return 1
	fi
	if ! git -C "$SCRATCH" rev-parse --verify --quiet "refs/heads/fanout/main-$slug" >/dev/null; then
		fail "$label: branch refs/heads/fanout/main-$slug was not created"
		return 1
	fi
	return 0
}

# expect_accepted <label> <slug> — slug is taken verbatim, a worktree is made.
expect_accepted() {
	local label="$1" slug="$2" raw rc out
	raw="$(run_setup "$slug")"
	rc="$(printf '%s' "$raw" | head -1)"
	out="$(printf '%s' "$raw" | tail -n +2)"
	if [[ "$rc" -eq 0 && -d "$out" ]] && assert_verbatim "$label" "$slug" "$out"; then
		pass "$label"
	elif [[ "$rc" -ne 0 || ! -d "$out" ]]; then
		fail "$label (rc=$rc out='$out')"
	fi
	if [[ -n "$out" && -d "$out" ]]; then
		git -C "$SCRATCH" worktree remove --force "$out" >/dev/null 2>&1 || true
		git -C "$SCRATCH" branch -D "fanout/main-$slug" >/dev/null 2>&1 || true
	fi
}

# --- (a) a well-formed slug is accepted and used verbatim -------------------
expect_accepted "(a) slug '1-ok-slug' is accepted and used verbatim" '1-ok-slug'

# --- (b) command substitution in a slug is refused, never expanded ----------
# The literal string below is single-quoted here and passed as one argv value:
# the guard must reject it on its bytes, not evaluate it.
# shellcheck disable=SC2016 # the un-expanded literal IS the fixture
b_raw="$(run_setup '$(echo x)-bad')"
b_rc="$(printf '%s' "$b_raw" | head -1)"
b_out="$(printf '%s' "$b_raw" | tail -n +2)"
if [[ "$b_rc" -ne 0 && "$b_out" == *"refusing task slug"* ]]; then
	pass "(b) a slug containing command substitution is refused"
else
	fail "(b) rc=$b_rc out='$b_out'"
fi

# --- (c) uppercase/underscore slug with no task-ID prefix is refused --------
c_raw="$(run_setup 'Add_Thing')"
c_rc="$(printf '%s' "$c_raw" | head -1)"
c_out="$(printf '%s' "$c_raw" | tail -n +2)"
if [[ "$c_rc" -ne 0 && "$c_out" == *"refusing task slug"* ]]; then
	pass "(c) slug 'Add_Thing' is refused"
else
	fail "(c) rc=$c_rc out='$c_out'"
fi

# expect_refused <label> <slug> — non-zero exit AND the guard's own message.
expect_refused() {
	local label="$1" slug="$2" raw rc out
	raw="$(run_setup "$slug")"
	rc="$(printf '%s' "$raw" | head -1)"
	out="$(printf '%s' "$raw" | tail -n +2)"
	if [[ "$rc" -ne 0 && "$out" == *"refusing task slug"* ]]; then
		pass "$label"
	else
		fail "$label (rc=$rc out='$out')"
	fi
}

# --- (d) the minimal well-formed slug is accepted ---------------------------
expect_accepted "(d) slug '12-a' is accepted" '12-a'

# --- (e) the task-ID-prefix half of the regex is exercised ------------------
expect_refused "(e) slug 'add-thing' with no numeric task-ID prefix is refused" 'add-thing'
expect_refused "(f) an empty slug is refused" ''
expect_refused "(g) slug '1-' with an empty suffix is refused" '1-'

# --- (h) slugify fixed-point half: shapes slugify would rewrite -------------
expect_refused "(h1) slug '1--a' (slugify collapses '--') is refused" '1--a'
expect_refused "(h2) slug '1-a-' (slugify strips the trailing '-') is refused" '1-a-'

# --- (i) 51 characters: slugify truncates at 50, so two long slugs collide --
LONG_SLUG="1-$(printf 'a%.0s' $(seq 1 49))"
expect_refused "(i) a 51-character slug (slugify truncates to 50) is refused" "$LONG_SLUG"

# expect_refused_base <label> <base-branch> — the base-branch guard fires.
expect_refused_base() {
	local label="$1" base="$2" raw rc out
	raw="$(run_setup_base "$base" '1-ok-base')"
	rc="$(printf '%s' "$raw" | head -1)"
	out="$(printf '%s' "$raw" | tail -n +2)"
	if [[ "$rc" -ne 0 && "$out" == *"refusing base branch"* ]]; then
		pass "$label"
	else
		fail "$label (rc=$rc out='$out')"
	fi
}

# --- (j) base-branch guard ---------------------------------------------------
# A leading '-' is the case `git check-ref-format` cannot see: git would parse
# it as an option to `worktree add`, so it is rejected on its own.
expect_refused_base "(j1) base branch '-main' is refused" '-main'
expect_refused_base "(j2) base branch 'ma in' is refused" 'ma in'
expect_refused_base "(j3) base branch 'a..b' is refused" 'a..b'
expect_refused_base "(j4) an empty base branch is refused" ''

# --- (k) task binding: the ordinal, not a slug, is what the caller supplies --
write_plan
K_SHA="$(plan_sha)"

# (k1) ordinal derivation. Every checklist item gets a 1-based ordinal in file
# order, and `tasks` publishes the same <id>\t<slug>\t<title> mapping `setup`
# re-derives from. Assert the first three records exactly.
set +e
k1_out="$(bash "$FANOUT_SH" tasks --plan "$PLAN" --plan-sha256 "$K_SHA" "$SCRATCH" 2>&1)"
k1_rc=$?
set -e
k1_want="$(printf '1\t1-first-done-thing\tFirst done thing\n2\t2-second-thing\tSecond thing\n3\t3-third-thing\tThird thing')"
if [[ "$k1_rc" -eq 0 && "$(printf '%s\n' "$k1_out" | head -3)" == "$k1_want" ]]; then
	pass "(k1) tasks numbers checklist items 1..N in file order with derived slugs"
else
	fail "(k1) rc=$k1_rc out='$k1_out'"
fi

# (k2) THE MOTIVATING FINDING. Approved task 7 is `Add API endpoint`, so
# --task-id 7 can only ever yield `7-add-api-endpoint`. There is no input to the
# derived call shape that yields `7-delete-api-endpoint` for that ordinal: the
# caller supplies an integer and a digest, and the slug comes out of the plan.
k2_raw="$(run_setup_plan 7 "$K_SHA")"
k2_rc="$(printf '%s' "$k2_raw" | head -1)"
k2_out="$(printf '%s' "$k2_raw" | tail -n +2)"
if [[ "$k2_rc" -eq 0 && -d "$k2_out" ]] && assert_verbatim "(k2)" '7-add-api-endpoint' "$k2_out"; then
	if sibling_exists "7-delete-api-endpoint" ||
		git -C "$SCRATCH" rev-parse --verify --quiet 'refs/heads/fanout/main-7-delete-api-endpoint' >/dev/null; then
		fail "(k2) a same-ID mismatched slug was reachable"
	else
		pass "(k2) --task-id 7 derives 7-add-api-endpoint and no same-ID mismatch is expressible"
	fi
elif [[ "$k2_rc" -ne 0 || ! -d "$k2_out" ]]; then
	fail "(k2) rc=$k2_rc out='$k2_out'"
fi
if [[ -n "$k2_out" && -d "$k2_out" ]]; then
	git -C "$SCRATCH" worktree remove --force "$k2_out" >/dev/null 2>&1 || true
	git -C "$SCRATCH" branch -D 'fanout/main-7-add-api-endpoint' >/dev/null 2>&1 || true
fi

# (k2b) the derived form refuses a slug spelled alongside --plan rather than
# quietly preferring one over the other: there is exactly one source of the
# slug in this call shape.
set +e
k2b_out="$(bash "$FANOUT_SH" setup main --plan "$PLAN" --task-id 7 --plan-sha256 "$K_SHA" 7-delete-api-endpoint "$SCRATCH" 2>&1)"
k2b_rc=$?
set -e
if [[ "$k2b_rc" -ne 0 && "$k2b_out" == *"exactly one <repo-root>"* ]] &&
	! sibling_exists "7-delete-api-endpoint"; then
	pass "(k2b) a slug spelled alongside --plan is refused, not used"
else
	fail "(k2b) rc=$k2b_rc out='$k2b_out'"
fi

# (k3) a shell-breaking title slugifies to safe bytes and creates no stray path.
# The plan line is `- [ ] rm -rf $(whoami); "drop"`, task 8. If any stage of the
# pipeline re-parsed the title as shell, the command substitution would run;
# the derived slug must instead be the literal bytes slugified.
k3_raw="$(run_setup_plan 8 "$K_SHA")"
k3_rc="$(printf '%s' "$k3_raw" | head -1)"
k3_out="$(printf '%s' "$k3_raw" | tail -n +2)"
k3_whoami="$(whoami)"
if [[ "$k3_rc" -eq 0 && -d "$k3_out" ]] && assert_verbatim "(k3)" '8-rm-rf-whoami-drop' "$k3_out"; then
	if sibling_exists "8-rm-rf-$k3_whoami-drop"; then
		fail "(k3) the title's command substitution was evaluated"
	elif [[ -e "$SCRATCH/README.md" ]]; then
		pass "(k3) a shell-breaking title slugifies safely and creates no stray path"
	else
		fail "(k3) the scratch repo was damaged by the title"
	fi
elif [[ "$k3_rc" -ne 0 || ! -d "$k3_out" ]]; then
	fail "(k3) rc=$k3_rc out='$k3_out'"
fi
if [[ -n "$k3_out" && -d "$k3_out" ]]; then
	git -C "$SCRATCH" worktree remove --force "$k3_out" >/dev/null 2>&1 || true
	git -C "$SCRATCH" branch -D 'fanout/main-8-rm-rf-whoami-drop' >/dev/null 2>&1 || true
fi

# (k4) an ordinal the checklist does not hold: refused, with no worktree. The
# `## Notes` item below the checklist is why this is not merely an off-by-one
# check -- the region ends at the next same-or-higher heading, so that item is
# not a task and 99 is genuinely absent.
k4_raw="$(run_setup_plan 99 "$K_SHA")"
k4_rc="$(printf '%s' "$k4_raw" | head -1)"
k4_out="$(printf '%s' "$k4_raw" | tail -n +2)"
if [[ "$k4_rc" -ne 0 && "$k4_out" == *"no task 99 in the plan's Implementation Checklist"* ]] &&
	[[ -z "$(find "$WORKDIR" -maxdepth 1 -name 'repo-fanout-99*' 2>/dev/null)" ]]; then
	pass "(k4) an absent task ordinal is refused and creates no worktree"
else
	fail "(k4) rc=$k4_rc out='$k4_out'"
fi

# (k5) a stale digest is refused. The digest is what binds an ordinal to a plan
# REVISION: without it, editing the checklist between the `tasks` call the user
# approved and this call would silently re-point every ordinal.
K5_STALE="$K_SHA"
printf -- '- [ ] Ninth thing\n' >>"$PLAN"
k5_raw="$(run_setup_plan 7 "$K5_STALE")"
k5_rc="$(printf '%s' "$k5_raw" | head -1)"
k5_out="$(printf '%s' "$k5_raw" | tail -n +2)"
if [[ "$k5_rc" -ne 0 && "$k5_out" == *"refusing plan (sha256 mismatch"* ]] &&
	! sibling_exists "7-add-api-endpoint"; then
	pass "(k5) a stale --plan-sha256 after editing the plan is refused with no worktree"
else
	fail "(k5) rc=$k5_rc out='$k5_out'"
fi
write_plan

# (k6) ticking task 1 to `- [x]` leaves task 2's slug unchanged. Numbering only
# the unticked lines would renumber every task behind a box a worker ticked
# mid-run, which is the silent re-pointing (k5) refuses on the digest.
k6_before="$(bash "$FANOUT_SH" tasks --plan "$PLAN" "$SCRATCH" | sed -n '2p')"
sed -i.bak 's/^- \[ \] Second thing$/- [x] Second thing/' "$PLAN"
rm -f "$PLAN.bak"
k6_after="$(bash "$FANOUT_SH" tasks --plan "$PLAN" "$SCRATCH" | sed -n '2p')"
if [[ "$k6_before" == "$(printf '2\t2-second-thing\tSecond thing')" && "$k6_after" == "$k6_before" ]]; then
	pass "(k6) ticking a checklist box leaves the ordinals and slugs unchanged"
else
	fail "(k6) before='$k6_before' after='$k6_after'"
fi
write_plan
K_SHA="$(plan_sha)"

# (k7) a plan path outside the repo root is refused. The digest alone would not
# stop this: an attacker-supplied out-of-tree "plan" can be hashed too.
cp "$PLAN" "$WORKDIR/outside-plan.md"
k7_raw="$(run_setup_plan 7 "$(shasum -a 256 "$WORKDIR/outside-plan.md" | awk '{print $1}')" "$WORKDIR/outside-plan.md")"
k7_rc="$(printf '%s' "$k7_raw" | head -1)"
k7_out="$(printf '%s' "$k7_raw" | tail -n +2)"
if [[ "$k7_rc" -ne 0 && "$k7_out" == *"outside the repo root"* ]] &&
	! sibling_exists "7-add-api-endpoint" && [[ -f "$WORKDIR/outside-plan.md" ]]; then
	pass "(k7) a plan path outside the repo root is refused"
else
	fail "(k7) rc=$k7_rc out='$k7_out'"
fi

# (k8) a '..'-bearing plan path is refused before any read: every containment
# check below it is lexical, and lexical reasoning is unsound with '..' in play.
k8_raw="$(run_setup_plan 7 "$K_SHA" "$SCRATCH/docs/../docs/plan.md")"
k8_rc="$(printf '%s' "$k8_raw" | head -1)"
k8_out="$(printf '%s' "$k8_raw" | tail -n +2)"
if [[ "$k8_rc" -ne 0 && "$k8_out" == *"containing '..'"* ]] && ! sibling_exists "7-add-api-endpoint"; then
	pass "(k8) a '..'-bearing plan path is refused"
else
	fail "(k8) rc=$k8_rc out='$k8_out'"
fi

# (k9) a plan reached through a symlinked directory below the repo root is
# refused, and the file it points at is not read.
ln -s "$WORKDIR" "$SCRATCH/linkdir"
k9_raw="$(run_setup_plan 7 "$(shasum -a 256 "$WORKDIR/outside-plan.md" | awk '{print $1}')" "$SCRATCH/linkdir/outside-plan.md")"
k9_rc="$(printf '%s' "$k9_raw" | head -1)"
k9_out="$(printf '%s' "$k9_raw" | tail -n +2)"
if [[ "$k9_rc" -ne 0 && "$k9_out" == *"symlink"* ]] &&
	! sibling_exists "7-add-api-endpoint" && [[ -f "$WORKDIR/outside-plan.md" ]]; then
	pass "(k9) a plan reached through a symlinked component is refused"
else
	fail "(k9) rc=$k9_rc out='$k9_out'"
fi
rm -f "$SCRATCH/linkdir"

# (k10) --task-id must be a bare positive integer. `07` would never match awk's
# %d-printed ordinal, so refusing it outright says so rather than reporting the
# task as absent; `-1` must never reach a command line as a flag.
k10_idx=0
for k10_id in '07' '0' '-1' '1 ' '+1' 'one' ''; do
	k10_idx=$((k10_idx + 1))
	k10_raw="$(run_setup_plan "$k10_id" "$K_SHA")"
	k10_rc="$(printf '%s' "$k10_raw" | head -1)"
	k10_out="$(printf '%s' "$k10_raw" | tail -n +2)"
	# An empty value is caught one step earlier, by the "all three flags are
	# mandatory together" check, so it names the flag rather than the value.
	if [[ "$k10_rc" -ne 0 ]] &&
		{ [[ "$k10_out" == *"refusing task id"* ]] || [[ "$k10_out" == *"--task-id N"* ]]; } &&
		! sibling_exists "1-first-done-thing"; then
		pass "(k10.$k10_idx) --task-id '$k10_id' is refused"
	else
		fail "(k10.$k10_idx) --task-id '$k10_id': rc=$k10_rc out='$k10_out'"
	fi
done

# (k11) the digest is mandatory on setup: an unpinned --plan is not a lesser
# form of the call, it is the vulnerability the digest exists to close.
set +e
k11_out="$(bash "$FANOUT_SH" setup main --plan "$PLAN" --task-id 7 "$SCRATCH" 2>&1)"
k11_rc=$?
set -e
if [[ "$k11_rc" -ne 0 && "$k11_out" == *"--plan-sha256"* ]] && ! sibling_exists "7-add-api-endpoint"; then
	pass "(k11) setup --plan without --plan-sha256 is refused"
else
	fail "(k11) rc=$k11_rc out='$k11_out'"
fi

# (k12) a missing plan file fails closed rather than falling back to anything.
k12_raw="$(run_setup_plan 7 "$K_SHA" "$SCRATCH/docs/absent.md")"
k12_rc="$(printf '%s' "$k12_raw" | head -1)"
k12_out="$(printf '%s' "$k12_raw" | tail -n +2)"
if [[ "$k12_rc" -ne 0 && "$k12_out" == *"missing plan file"* ]]; then
	pass "(k12) a missing plan file is refused"
else
	fail "(k12) rc=$k12_rc out='$k12_out'"
fi

# (k13) the derived slug still goes through the slug guard. A title that
# slugifies to nothing derives `<id>-`, an empty suffix the regex must refuse
# rather than let become a branch name.
cat >"$SCRATCH/docs/empty-title.md" <<'PLANEOF'
## Implementation Checklist

- [ ] ???
PLANEOF
k13_raw="$(run_setup_plan 1 "$(shasum -a 256 "$SCRATCH/docs/empty-title.md" | awk '{print $1}')" "$SCRATCH/docs/empty-title.md")"
k13_rc="$(printf '%s' "$k13_raw" | head -1)"
k13_out="$(printf '%s' "$k13_raw" | tail -n +2)"
if [[ "$k13_rc" -ne 0 && "$k13_out" == *"refusing task slug"* ]] && ! sibling_exists ""; then
	pass "(k13) a title that slugifies to nothing is refused by the slug guard"
else
	fail "(k13) rc=$k13_rc out='$k13_out'"
fi
rm -f "$SCRATCH/docs/empty-title.md"

# (k14) `tasks` refuses a mismatched digest too, so the enumeration the user
# approves cannot itself be taken from a revision that has already moved.
set +e
k14_out="$(bash "$FANOUT_SH" tasks --plan "$PLAN" --plan-sha256 deadbeef "$SCRATCH" 2>&1)"
k14_rc=$?
set -e
if [[ "$k14_rc" -ne 0 && "$k14_out" == *"refusing plan (sha256 mismatch"* ]]; then
	pass "(k14) tasks refuses a mismatched --plan-sha256"
else
	fail "(k14) rc=$k14_rc out='$k14_out'"
fi

# --- (l) cleanup anchors repo_root at a real git checkout -------------------
# The state file is an ordinary file in the tree, so cleanup must not take its
# repo_root on trust: the containment guard alone would be asking whether that
# value is inside itself. A repo_root naming a directory that is not a git
# checkout root is refused before anything is removed.
NOT_A_REPO="$WORKDIR/not-a-repo"
mkdir -p "$NOT_A_REPO/payload"
printf 'decoy\n' >"$NOT_A_REPO/payload/file.txt"
L_STATE="$WORKDIR/l-state.json"
printf '{"repo_root": "%s", "agents": []}\n' "$NOT_A_REPO" >"$L_STATE"
set +e
l_out="$(bash "$FANOUT_SH" cleanup "$L_STATE" 2>&1)"
l_rc=$?
set -e
if [[ "$l_rc" -ne 0 && "$l_out" == *"refusing repo_root"* ]] &&
	[[ -d "$NOT_A_REPO/payload" && -f "$NOT_A_REPO/payload/file.txt" && -f "$L_STATE" ]]; then
	pass "(l) cleanup refuses a state-file repo_root that is not a git checkout root"
else
	fail "(l) rc=$l_rc out='$l_out' (payload survived: $([[ -d "$NOT_A_REPO/payload" ]] && echo yes || echo no))"
fi

# --- (m) cleanup derives the branch to delete from git, not the state file ---
# The state file is an ordinary file in the tree, so a `branch` value in it is
# not evidence fan-out ever created that branch. cleanup reads
# `git worktree list --porcelain` once and deletes the branch git has attached
# to the OWNED worktree; the state file's own value is used only when the
# worktree is already gone, and then only in the `fanout/<slugify-normal-form>`
# shape `setup` can produce. Anything else is skipped with a warning and no git
# call, so an option-like value never reaches `git branch` as a flag either.

# (m1) happy path, with the state file LYING about the branch: a real
# setup-made worktree whose entry names `main`. The worktree goes, the branch
# git actually attached to it goes, and `main` is untouched.
m1_wt="$(bash "$FANOUT_SH" setup main 3-cleanup-ok "$SCRATCH")"
M1_STATE="$WORKDIR/m1-state.json"
python3 - "$M1_STATE" "$SCRATCH" "$m1_wt" <<'PYEOF'
import json, sys

state = {
    "repo_root": sys.argv[2],
    "agents": [{"task_id": 3, "worktree": sys.argv[3], "branch": "main"}],
}
with open(sys.argv[1], "w") as f:
    json.dump(state, f)
PYEOF
set +e
m1_out="$(bash "$FANOUT_SH" cleanup "$M1_STATE" 2>&1)"
m1_rc=$?
set -e
if [[ "$m1_rc" -eq 0 && ! -d "$m1_wt" ]] &&
	! git -C "$SCRATCH" rev-parse --verify --quiet 'refs/heads/fanout/main-3-cleanup-ok' >/dev/null &&
	git -C "$SCRATCH" rev-parse --verify --quiet refs/heads/main >/dev/null; then
	pass "(m1) cleanup deletes the branch git attached to the worktree, not the one the state file named"
else
	fail "(m1) rc=$m1_rc out='$m1_out'"
fi

# expect_cleanup_skips_branch <label> <branch-value> — the worktree the state
# file names is not one git attributes to fan-out, so it is warned about and
# left alone, and its `branch` value is not consulted at all. Cleanup still
# succeeds and the branch the state file named survives.
GONE_WT="$WORKDIR/repo-fanout-9-gone"
expect_cleanup_skips_branch() {
	local label="$1" branch="$2" state out rc
	state="$WORKDIR/m-skip-state.json"
	python3 - "$state" "$SCRATCH" "$GONE_WT" "$branch" <<'PYEOF'
import json, sys

state = {
    "repo_root": sys.argv[2],
    "agents": [{"task_id": 9, "worktree": sys.argv[3], "branch": sys.argv[4]}],
}
with open(sys.argv[1], "w") as f:
    json.dump(state, f)
PYEOF
	set +e
	out="$(bash "$FANOUT_SH" cleanup "$state" 2>&1)"
	rc=$?
	set -e
	if [[ "$rc" -eq 0 && "$out" == *"git does not attribute to fan-out"* ]] &&
		git -C "$SCRATCH" rev-parse --verify --quiet refs/heads/main >/dev/null; then
		pass "$label"
	else
		fail "$label (rc=$rc out='$out')"
	fi
}

# (m2) a state file naming an ordinary branch: `main` is not a branch fan-out
# creates, so cleanup must not delete it.
expect_cleanup_skips_branch "(m2) cleanup leaves a state-file branch fan-out could not have created" 'main'

# (m3) an option-like value: never consulted, so it can never reach git as a
# flag.
expect_cleanup_skips_branch "(m3) cleanup leaves an option-like state-file branch" '-D'

# --- (n) git's worktree listing is the ONLY authority for cleanup's targets --
# A path that merely LOOKS like a fan-out worktree is not one, a worktree whose
# directory was deleted by hand is still one, and a `fanout/`-shaped branch the
# state file names is not one. All three are decided from
# `git worktree list --porcelain`, never from `agents[]`.

# (n1) a sibling directory named like a fan-out worktree, registered by hand as
# a worktree on a NON-`fanout/` branch and named in the state file: the naming
# pattern alone is not ownership, so it survives with a warning.
N1_WT="$WORKDIR/repo-fanout-zzz"
git -C "$SCRATCH" worktree add -q -b not-a-fanout-branch "$N1_WT" main
N1_STATE="$WORKDIR/n1-state.json"
python3 - "$N1_STATE" "$SCRATCH" "$N1_WT" <<'PYEOF'
import json, sys

state = {
    "repo_root": sys.argv[2],
    "agents": [{"task_id": 8, "worktree": sys.argv[3], "branch": "fanout/main-8-x"}],
}
with open(sys.argv[1], "w") as f:
    json.dump(state, f)
PYEOF
set +e
n1_out="$(bash "$FANOUT_SH" cleanup "$N1_STATE" 2>&1)"
n1_rc=$?
set -e
if [[ "$n1_rc" -eq 0 && "$n1_out" == *"git does not attribute to fan-out"* && -d "$N1_WT" ]] &&
	git -C "$SCRATCH" rev-parse --verify --quiet refs/heads/not-a-fanout-branch >/dev/null; then
	pass "(n1) a sibling worktree on a non-fanout/ branch survives cleanup with a warning"
else
	fail "(n1) rc=$n1_rc out='$n1_out' (dir survived: $([[ -d "$N1_WT" ]] && echo yes || echo no))"
fi
git -C "$SCRATCH" worktree remove --force "$N1_WT" >/dev/null 2>&1 || true
git -C "$SCRATCH" branch -D not-a-fanout-branch >/dev/null 2>&1 || true

# (n2) the real worktree directory deleted by hand before cleanup. git still
# lists the entry (marked `prunable`) with its `branch` line, so the branch is
# still deleted with no state-file fallback in play.
n2_wt="$(bash "$FANOUT_SH" setup main 7-rmrf "$SCRATCH")"
rm -rf "$n2_wt"
N2_STATE="$WORKDIR/n2-state.json"
python3 - "$N2_STATE" "$SCRATCH" "$n2_wt" <<'PYEOF'
import json, sys

state = {
    "repo_root": sys.argv[2],
    "agents": [{"task_id": 7, "worktree": sys.argv[3], "branch": "main"}],
}
with open(sys.argv[1], "w") as f:
    json.dump(state, f)
PYEOF
set +e
n2_out="$(bash "$FANOUT_SH" cleanup "$N2_STATE" 2>&1)"
n2_rc=$?
set -e
if [[ "$n2_rc" -eq 0 ]] &&
	! git -C "$SCRATCH" rev-parse --verify --quiet 'refs/heads/fanout/main-7-rmrf' >/dev/null &&
	git -C "$SCRATCH" rev-parse --verify --quiet refs/heads/main >/dev/null; then
	pass "(n2) a hand-deleted worktree's fanout/ branch is still deleted from git's listing"
else
	fail "(n2) rc=$n2_rc out='$n2_out'"
fi

# (n3) a real `fanout/`-namespaced branch with no worktree, named by the state
# file: the branch regex fallback is gone, so it survives.
git -C "$SCRATCH" branch fanout/production main
N3_STATE="$WORKDIR/n3-state.json"
python3 - "$N3_STATE" "$SCRATCH" "$GONE_WT" <<'PYEOF'
import json, sys

state = {
    "repo_root": sys.argv[2],
    "agents": [{"task_id": 6, "worktree": sys.argv[3], "branch": "fanout/production"}],
}
with open(sys.argv[1], "w") as f:
    json.dump(state, f)
PYEOF
set +e
n3_out="$(bash "$FANOUT_SH" cleanup "$N3_STATE" 2>&1)"
n3_rc=$?
set -e
if [[ "$n3_rc" -eq 0 ]] &&
	git -C "$SCRATCH" rev-parse --verify --quiet 'refs/heads/fanout/production' >/dev/null; then
	pass "(n3) a fanout/-shaped branch named only by the state file survives cleanup"
else
	fail "(n3) rc=$n3_rc out='$n3_out'"
fi
git -C "$SCRATCH" branch -D fanout/production >/dev/null 2>&1 || true

# (n4/n5) the sibling NAME must be one setup could have produced, not merely one
# that starts with `<repo>-fanout-`. Both fixtures sit on a real `fanout/`
# branch, so the branch half of the ownership test passes and the basename is
# the only thing left to refuse them: an EMPTY suffix (`repo-fanout-`) and an
# arbitrary hand-made one (`repo-fanout-private`). setup only ever emits
# `<task-id>-<slug>`, so neither is a cleanup target and both must survive.
n45_idx=0
for n45_suffix in "" "private"; do
	n45_idx=$((n45_idx + 1))
	n45_wt="$WORKDIR/repo-fanout-$n45_suffix"
	n45_branch="fanout/hand-made-$n45_idx"
	git -C "$SCRATCH" worktree add -q -b "$n45_branch" "$n45_wt" main
	n45_state="$WORKDIR/n45-$n45_idx-state.json"
	python3 - "$n45_state" "$SCRATCH" "$n45_wt" "$n45_branch" <<'PYEOF'
import json, sys

state = {
    "repo_root": sys.argv[2],
    "agents": [{"task_id": 9, "worktree": sys.argv[3], "branch": sys.argv[4]}],
}
with open(sys.argv[1], "w") as f:
    json.dump(state, f)
PYEOF
	set +e
	n45_out="$(bash "$FANOUT_SH" cleanup "$n45_state" 2>&1)"
	n45_rc=$?
	set -e
	if [[ "$n45_rc" -eq 0 && -d "$n45_wt" ]] &&
		git -C "$SCRATCH" rev-parse --verify --quiet "refs/heads/$n45_branch" >/dev/null; then
		pass "(n$((3 + n45_idx))) a sibling named 'repo-fanout-$n45_suffix' on a fanout/ branch survives cleanup"
	else
		fail "(n$((3 + n45_idx))) rc=$n45_rc out='$n45_out' (dir survived: $([[ -d "$n45_wt" ]] && echo yes || echo no))"
	fi
	git -C "$SCRATCH" worktree remove --force "$n45_wt" >/dev/null 2>&1 || true
	git -C "$SCRATCH" branch -D "$n45_branch" >/dev/null 2>&1 || true
done

# --- (o) setup normalises its repo-root argument once -----------------------
# A root spelled `<repo>/.` has basename `.`, so an unnormalised build put the
# worktree INSIDE the checkout, where cleanup (which does normalise) then
# refused to touch it. The printed path must be a sibling, and cleanup must
# remove it.
write_plan
O_SHA="$(plan_sha)"
set +e
o_wt="$(bash "$FANOUT_SH" setup main --plan "$PLAN" --task-id 4 --plan-sha256 "$O_SHA" "$SCRATCH/." 2>&1)"
o_rc=$?
set -e
O_STATE="$WORKDIR/o-state.json"
python3 - "$O_STATE" "$SCRATCH" "$o_wt" <<'PYEOF'
import json, sys

state = {
    "repo_root": sys.argv[2],
    "agents": [{"task_id": 4, "worktree": sys.argv[3], "branch": "main"}],
}
with open(sys.argv[1], "w") as f:
    json.dump(state, f)
PYEOF
set +e
o_out="$(bash "$FANOUT_SH" cleanup "$O_STATE" 2>&1)"
set -e
if [[ "$o_rc" -eq 0 && "$o_wt" == "$WORKDIR/repo-fanout-4-fourth-thing" && ! -d "$o_wt" ]] &&
	! git -C "$SCRATCH" rev-parse --verify --quiet 'refs/heads/fanout/main-4-fourth-thing' >/dev/null; then
	pass "(o) setup with a repo root spelled '<repo>/.' builds a sibling worktree cleanup can remove"
else
	fail "(o) rc=$o_rc wt='$o_wt' cleanup='$o_out'"
fi

# (o2) a relative repo root is refused outright: `git -C` makes it meaningless
# and every guard reasons about absolute paths.
set +e
o2_out="$(bash "$FANOUT_SH" setup main --plan "$PLAN" --task-id 4 --plan-sha256 "$O_SHA" "relative/repo" 2>&1)"
o2_rc=$?
set -e
if [[ "$o2_rc" -ne 0 && "$o2_out" == *"refusing repo root"* ]]; then
	pass "(o2) setup refuses a relative repo root"
else
	fail "(o2) rc=$o2_rc out='$o2_out'"
fi

# --- Summary -----------------------------------------------------------------
echo
echo "test-fanout-slug-guard-codex.sh: $PASS_COUNT passed, $FAIL_COUNT failed"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
	exit 1
fi

exit 0
