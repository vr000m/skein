#!/usr/bin/env bash
# test-fanout-slug-guard.sh — regression suite for the task-slug guard in
# plugins/skein/skills/fan-out/fan-out.sh cmd_setup.
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
# SLUG FILE. `setup --slug-file <path> <repo-root>` is the transport the skill
# uses, so no plan-derived byte is ever spelled in a shell command. The file
# must sit inside the repo root and must not be reached through a symlink; it
# must hold exactly one line, read raw (a normalising read such as `tr -d '\n'`
# would rewrite a hostile `1-foo\n-bar` into a shape the slug guard accepts);
# and it is consumed -- deleted -- on every path, so a stale file from an
# earlier run can never be picked up.
#
# CLEANUP REPO ROOT. `cleanup` drives worktree removal, branch deletion and an
# `rm -rf` from a repo_root parsed out of the state file, which is an ordinary
# file in the tree. Checking that value against itself proves nothing, so the
# trust anchor is git: a repo_root that is not the root of a real checkout is
# refused before any destructive command runs. That belongs here because it is
# the same "never trust a value the tree can author" boundary as the slug file.
#
# CLEANUP TARGETS. The same file names a `worktree` and a `branch` per agent,
# and both used to reach git. Neither does now. `git worktree list --porcelain`
# is the only authority: an entry is a target iff its path is a sibling of the
# repo root named `<repo-name>-fanout-*` AND git has it attached to a branch
# under `refs/heads/fanout/`, and the branch deleted is the one git attached to
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
FANOUT_SH="$REPO_ROOT/plugins/skein/skills/fan-out/fan-out.sh"

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

# run_setup_slug_file <path> — the --slug-file transport form.
run_setup_slug_file() {
	local out rc
	set +e
	out="$(bash "$FANOUT_SH" setup main --slug-file "$1" "$SCRATCH" 2>&1)"
	rc=$?
	set -e
	printf '%s\n%s\n' "$rc" "$out"
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

# --- (k) --slug-file transport ----------------------------------------------
FANOUT_DIR="$SCRATCH/.fanout"
mkdir -p "$FANOUT_DIR"
SLUG_FILE="$FANOUT_DIR/next.slug"

# (k1) a one-line file is accepted, the slug is used verbatim, and the file is
# consumed by the call that read it.
printf '1-from-file\n' >"$SLUG_FILE"
k1_raw="$(run_setup_slug_file "$SLUG_FILE")"
k1_rc="$(printf '%s' "$k1_raw" | head -1)"
k1_out="$(printf '%s' "$k1_raw" | tail -n +2)"
if [[ "$k1_rc" -eq 0 && -d "$k1_out" ]] && assert_verbatim "(k1)" '1-from-file' "$k1_out"; then
	if [[ -e "$SLUG_FILE" ]]; then
		fail "(k1) the slug file survived the call that read it"
	else
		pass "(k1) a one-line slug file is accepted, used verbatim and consumed"
	fi
elif [[ "$k1_rc" -ne 0 || ! -d "$k1_out" ]]; then
	fail "(k1) rc=$k1_rc out='$k1_out'"
fi
if [[ -n "$k1_out" && -d "$k1_out" ]]; then
	git -C "$SCRATCH" worktree remove --force "$k1_out" >/dev/null 2>&1 || true
	git -C "$SCRATCH" branch -D 'fanout/main-1-from-file' >/dev/null 2>&1 || true
fi

# expect_refused_slug_file <label> <needle> — write the caller's exact bytes,
# expect a refusal carrying <needle>, and expect the file to be gone either way.
expect_refused_slug_file() {
	local label="$1" needle="$2" raw rc out
	raw="$(run_setup_slug_file "$SLUG_FILE")"
	rc="$(printf '%s' "$raw" | head -1)"
	out="$(printf '%s' "$raw" | tail -n +2)"
	if [[ "$rc" -eq 0 || "$out" != *"$needle"* ]]; then
		fail "$label (rc=$rc out='$out')"
	elif [[ -e "$SLUG_FILE" && -f "$SLUG_FILE" ]]; then
		fail "$label: the slug file survived a refused call"
	else
		pass "$label"
	fi
}

# (k2) two lines: the transport carries one slug, never a list.
printf '1-one\n2-two\n' >"$SLUG_FILE"
expect_refused_slug_file "(k2) a two-line slug file is refused" "refusing task slug"

# (k3) the validation-bypass fixture. A normalising read (`tr -d '\n'`) would
# splice these two lines into the valid slug '1-foo-bar'; a raw read must not.
printf '1-foo\n-bar\n' >"$SLUG_FILE"
expect_refused_slug_file "(k3) a slug file holding '1-foo\\n-bar' is refused" "refusing task slug"

# (k4) no file at all: fail closed, never fall back to some other slug.
rm -f "$SLUG_FILE"
k4_raw="$(run_setup_slug_file "$SLUG_FILE")"
k4_rc="$(printf '%s' "$k4_raw" | head -1)"
k4_out="$(printf '%s' "$k4_raw" | tail -n +2)"
if [[ "$k4_rc" -ne 0 && "$k4_out" == *"missing slug file"* ]]; then
	pass "(k4) a missing slug file is refused"
else
	fail "(k4) rc=$k4_rc out='$k4_out'"
fi

# (k5) a symlinked slug file is refused without being read: a tracked symlink
# at a gitignored path still materialises on checkout.
printf '1-linked\n' >"$WORKDIR/outside.slug"
ln -s "$WORKDIR/outside.slug" "$SLUG_FILE"
k5_raw="$(run_setup_slug_file "$SLUG_FILE")"
k5_rc="$(printf '%s' "$k5_raw" | head -1)"
k5_out="$(printf '%s' "$k5_raw" | tail -n +2)"
if [[ "$k5_rc" -ne 0 && "$k5_out" == *"symlink"* && -e "$WORKDIR/outside.slug" ]]; then
	pass "(k5) a symlinked slug file is refused and its target is untouched"
else
	fail "(k5) rc=$k5_rc out='$k5_out'"
fi
rm -f "$SLUG_FILE"

# (k6) a slug file outside the repo root is refused: the transport is a repo
# path by contract, so an out-of-tree one is a caller error, not a shortcut.
printf '1-outside\n' >"$WORKDIR/outside.slug"
k6_raw="$(run_setup_slug_file "$WORKDIR/outside.slug")"
k6_rc="$(printf '%s' "$k6_raw" | head -1)"
k6_out="$(printf '%s' "$k6_raw" | tail -n +2)"
if [[ "$k6_rc" -ne 0 && "$k6_out" == *"outside the repo root"* && -e "$WORKDIR/outside.slug" ]]; then
	pass "(k6) a slug file outside the repo root is refused"
else
	fail "(k6) rc=$k6_rc out='$k6_out'"
fi

# --- (k7-k9) the "exactly one line" rule at its three boundaries -------------
# The single-line test is a byte comparison against the read value with and
# without one trailing newline, so its edges are: no trailing newline at all
# (accepted -- the value IS the whole file), a second trailing newline
# (refused -- a blank line is a second line), and CRLF (refused -- the \r is a
# byte of the slug, which the slug guard then rejects).

# (k7) no trailing newline: accepted and used verbatim.
printf '1-no-newline' >"$SLUG_FILE"
k7_raw="$(run_setup_slug_file "$SLUG_FILE")"
k7_rc="$(printf '%s' "$k7_raw" | head -1)"
k7_out="$(printf '%s' "$k7_raw" | tail -n +2)"
if [[ "$k7_rc" -eq 0 && -d "$k7_out" ]] && assert_verbatim "(k7)" '1-no-newline' "$k7_out"; then
	if [[ -e "$SLUG_FILE" ]]; then
		fail "(k7) the slug file survived the call that read it"
	else
		pass "(k7) a slug file with no trailing newline is accepted and consumed"
	fi
elif [[ "$k7_rc" -ne 0 || ! -d "$k7_out" ]]; then
	fail "(k7) rc=$k7_rc out='$k7_out'"
fi
if [[ -n "$k7_out" && -d "$k7_out" ]]; then
	git -C "$SCRATCH" worktree remove --force "$k7_out" >/dev/null 2>&1 || true
	git -C "$SCRATCH" branch -D 'fanout/main-1-no-newline' >/dev/null 2>&1 || true
fi

# (k8) two trailing newlines: the blank second line is a second line.
printf '1-foo\n\n' >"$SLUG_FILE"
expect_refused_slug_file "(k8) a slug file with two trailing newlines is refused" "refusing task slug"

# (k9) CRLF: the '\r' is part of the value, so the slug guard refuses it.
printf '1-foo\r\n' >"$SLUG_FILE"
expect_refused_slug_file "(k9) a CRLF-terminated slug file is refused" "refusing task slug"

# (k10) a symlinked slug DIRECTORY is refused. The leaf stays a regular file in
# this fixture, so a leaf-only `-L` test would pass it; the containment walk
# checks every component, which is what stops the consume-once `rm -f` from
# resolving through the swapped ancestor and unlinking a file outside the
# checkout. Both halves are asserted: the call is refused, and the outside
# target still exists afterwards.
mkdir -p "$WORKDIR/elsewhere"
printf '1-outside-dir\n' >"$WORKDIR/elsewhere/next.slug"
rm -f "$SLUG_FILE"
rmdir "$FANOUT_DIR"
ln -s "$WORKDIR/elsewhere" "$FANOUT_DIR"
k10_raw="$(run_setup_slug_file "$SLUG_FILE")"
k10_rc="$(printf '%s' "$k10_raw" | head -1)"
k10_out="$(printf '%s' "$k10_raw" | tail -n +2)"
if [[ "$k10_rc" -ne 0 && "$k10_out" == *"symlink"* && -f "$WORKDIR/elsewhere/next.slug" ]]; then
	pass "(k10) a symlinked slug directory is refused and the outside target survives"
else
	fail "(k10) rc=$k10_rc out='$k10_out'"
fi
rm -f "$FANOUT_DIR"
mkdir -p "$FANOUT_DIR"

# --- (l) cleanup anchors repo_root at a real git checkout -------------------
# The state file is an ordinary file in the tree, so cleanup must not take its
# repo_root on trust: the containment guard alone would be asking whether that
# value is inside itself. A repo_root naming a directory that is not a git
# checkout root is refused before anything is removed.
NOT_A_REPO="$WORKDIR/not-a-repo"
mkdir -p "$NOT_A_REPO/.fanout"
printf 'decoy\n' >"$NOT_A_REPO/.fanout/next.slug"
L_STATE="$WORKDIR/l-state.json"
printf '{"repo_root": "%s", "agents": []}\n' "$NOT_A_REPO" >"$L_STATE"
set +e
l_out="$(bash "$FANOUT_SH" cleanup "$L_STATE" 2>&1)"
l_rc=$?
set -e
if [[ "$l_rc" -ne 0 && "$l_out" == *"refusing repo_root"* ]] &&
	[[ -d "$NOT_A_REPO/.fanout" && -f "$NOT_A_REPO/.fanout/next.slug" && -f "$L_STATE" ]]; then
	pass "(l) cleanup refuses a state-file repo_root that is not a git checkout root"
else
	fail "(l) rc=$l_rc out='$l_out' (.fanout survived: $([[ -d "$NOT_A_REPO/.fanout" ]] && echo yes || echo no))"
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

# --- (o) setup normalises its repo-root argument once -----------------------
# A root spelled `<repo>/.` has basename `.`, so an unnormalised build put the
# worktree INSIDE the checkout, where cleanup (which does normalise) then
# refused to touch it. The printed path must be a sibling, and cleanup must
# remove it.
mkdir -p "$FANOUT_DIR"
printf '4-dot-root\n' >"$SLUG_FILE"
set +e
o_wt="$(bash "$FANOUT_SH" setup main --slug-file "$SLUG_FILE" "$SCRATCH/." 2>&1)"
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
if [[ "$o_rc" -eq 0 && "$o_wt" == "$WORKDIR/repo-fanout-4-dot-root" && ! -d "$o_wt" ]] &&
	! git -C "$SCRATCH" rev-parse --verify --quiet 'refs/heads/fanout/main-4-dot-root' >/dev/null; then
	pass "(o) setup with a repo root spelled '<repo>/.' builds a sibling worktree cleanup can remove"
else
	fail "(o) rc=$o_rc wt='$o_wt' cleanup='$o_out'"
fi

# (o2) a relative repo root is refused outright: `git -C` makes it meaningless
# and every guard reasons about absolute paths.
mkdir -p "$FANOUT_DIR"
printf '4-relative\n' >"$SLUG_FILE"
set +e
o2_out="$(bash "$FANOUT_SH" setup main --slug-file "$SLUG_FILE" "relative/repo" 2>&1)"
o2_rc=$?
set -e
if [[ "$o2_rc" -ne 0 && "$o2_out" == *"refusing repo root"* ]]; then
	pass "(o2) setup refuses a relative repo root"
else
	fail "(o2) rc=$o2_rc out='$o2_out'"
fi
rm -f "$SLUG_FILE"

# --- Summary -----------------------------------------------------------------
echo
echo "test-fanout-slug-guard.sh: $PASS_COUNT passed, $FAIL_COUNT failed"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
	exit 1
fi

exit 0
