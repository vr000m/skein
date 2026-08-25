#!/usr/bin/env bash
# lint-temp-paths.sh — refuse PREDICTABLE temp paths anywhere in the tree.
#
# THE RULE IS "ANY HARD-CODED PATH BELOW /tmp OR /var/tmp", not just the
# `$$`/`$RANDOM` forms (round 8, F10). The old regex encoded "predictable =
# literal PLUS `$$`/`$RANDOM`", so a FULLY STATIC path — which is strictly
# MORE predictable, not less — was invisible to the lint that exists to refuse
# predictability. `tests/gauntlet/test-gate-timeout.sh` was using a static
# `/tmp/<name>/env.json` as a SECURITY fixture's input with an expected
# verdict of "accepted": any local user could pre-create that directory as a
# symlink and flip a security regression test's answer.
#
# Any such path is guessable by another user on the host: a pre-planted
# symlink at it is FOLLOWED by bash's `>`/`2>` redirect, so the redirect
# truncates and overwrites whatever the running user can write, and a
# subsequent `rm -f` removes the evidence. It is the same threat class
# persist_atomic_write, ledger_assert_no_symlink and gate_assert_no_symlink
# all defend against; a script that opts out of `mktemp` opts out of all of
# it.
#
# BARE `/tmp` (or `/var/tmp`) WITH NO CHILD COMPONENT STAYS LEGAL: it names no
# file, and using it as a CWD is required by the cwd-invariance matrix in
# tests/gauntlet/test-gate-timeout.sh (R7-G1a). Whole-line comments are
# skipped too — prose describing the banned shape is not the banned shape.
#
# Run from `just lint-scripts`. Exit 0 clean, 1 with the offending lines.
#
# Why a lint and not a test: the sites are inside the test suite itself, and a
# test asserting a test's own temp-path construction is circular.
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

hits="$(grep -rn --include='*.sh' -E '^[^#]*(/tmp|/var/tmp)/[A-Za-z0-9._-]' \
	scripts tests plugins || true)"

if [[ -n "$hits" ]]; then
	echo "lint-temp-paths: hard-coded temp path(s) below /tmp found -- use mktemp:" >&2
	printf '%s\n' "$hits" >&2
	exit 1
fi
exit 0
