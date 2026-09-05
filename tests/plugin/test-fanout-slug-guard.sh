#!/usr/bin/env bash
# test-fanout-slug-guard.sh — regression suite for the task-slug guard in
# plugins/skein/skills/fan-out/fan-out.sh cmd_setup.
#
# WHY THIS FILE EXISTS. fan-out's SKILL.md used to carry a ~25-line inline
# decode-and-validate block that re-implemented the slug boundary in prose,
# with a contract that differed from the script's own slugify(). The prose was
# replaced by a short "validate before you substitute" rule, which moves the
# enforcing boundary into cmd_setup: the script must fail closed on any slug
# that is not <task-id>-<lowercase-slug>, so a plan-derived string that skipped
# the caller's check never reaches `git worktree add`.
#
# The invariant asserted here: cmd_setup accepts a slug iff it matches
# ^[0-9]+-[a-z0-9-]+$, and refuses everything else with a non-zero exit and a
# "refusing task slug" message on stderr.

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

# run_setup <slug> — echo rc on line 1, combined output on the rest.
run_setup() {
	local out rc
	set +e
	out="$(bash "$FANOUT_SH" setup main "$1" "$SCRATCH" 2>&1)"
	rc=$?
	set -e
	printf '%s\n%s\n' "$rc" "$out"
}

# --- (a) a well-formed slug is accepted -------------------------------------
a_raw="$(run_setup '1-ok-slug')"
a_rc="$(printf '%s' "$a_raw" | head -1)"
a_out="$(printf '%s' "$a_raw" | tail -n +2)"
if [[ "$a_rc" -eq 0 && -d "$a_out" ]]; then
	pass "(a) slug '1-ok-slug' is accepted and a worktree path is printed"
	git -C "$SCRATCH" worktree remove --force "$a_out" >/dev/null 2>&1 || true
else
	fail "(a) rc=$a_rc out='$a_out'"
fi

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

# --- Summary -----------------------------------------------------------------
echo
echo "test-fanout-slug-guard.sh: $PASS_COUNT passed, $FAIL_COUNT failed"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
	exit 1
fi

exit 0
