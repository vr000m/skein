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
# THE CLASS IS THE UNION OF BOTH SHAPES (round 9, F4): a child of `/tmp` or
# `/var/tmp` whose first component begins with a filename character OR a `$`
# — the static (`/tmp/name`), the PID/RANDOM (`/tmp/$$`, `/var/tmp/$$-foo`)
# and the expansion (`/tmp/$RANDOM/x`, `/tmp/${v}.json`) spellings alike.
#
# BARE `/tmp` (or `/var/tmp`) WITH NO CHILD COMPONENT STAYS LEGAL: it names no
# file, and using it as a CWD is required by the cwd-invariance matrix in
# tests/gauntlet/test-gate-timeout.sh (R7-G1a). A line is exempt IFF its first
# non-blank character is `#` — prose describing the banned shape is not the
# banned shape, but a `#` anywhere else on the line exempts nothing.
#
# Run from `just lint-scripts`. Exit 0 clean, 1 with the offending lines.
#
# Why a lint and not a test: the sites are inside the test suite itself, and a
# test asserting a test's own temp-path construction is circular.
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The class is the UNION of the static and the expansion shapes (round 9, F4):
# `$` belongs in it because `/tmp/$$` and `/tmp/$RANDOM/x` are the ORIGINAL
# threat this lint was written for, and the round-8 widening REPLACED that
# alternative instead of ORing it — so the three shapes the header still
# claims to cover all passed clean.
#
# The comment exemption is a LINE predicate, not a prefix class (round 9, F5).
# `^[^#]*` exempted any line carrying a `#` anywhere to the left of the path —
# inside a string, in a `jq` filter, in a `${v#pfx}` expansion, or as a
# trailing comment — so appending ` # ok` to an offending line silently
# disabled the lint for it. Only a line whose first non-blank character is `#`
# is prose; the second grep drops exactly those, matching on the
# `path:line:` prefix `grep -rn` emits.
hits="$(grep -rn --include='*.sh' -E '(/tmp|/var/tmp)/[A-Za-z0-9._$-]' \
	scripts tests plugins |
	grep -vE '^[^:]*:[0-9]+:[[:space:]]*#' || true)"

if [[ -n "$hits" ]]; then
	echo "lint-temp-paths: hard-coded temp path(s) below /tmp found -- use mktemp:" >&2
	printf '%s\n' "$hits" >&2
	exit 1
fi
exit 0
