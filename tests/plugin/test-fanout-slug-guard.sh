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

# --- Summary -----------------------------------------------------------------
echo
echo "test-fanout-slug-guard.sh: $PASS_COUNT passed, $FAIL_COUNT failed"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
	exit 1
fi

exit 0
