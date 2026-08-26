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
# THE CLASS IS THE UNION OF BOTH SHAPES (round 9, F4; widened round 10, F6): a
# child of `/tmp` or `/var/tmp` whose first component begins with a filename
# character, a `$`, or a QUOTE — the static (`/tmp/name`), the PID/RANDOM
# (`/tmp/$$`, `/var/tmp/$$-foo`), the expansion (`/tmp/$RANDOM/x`,
# `/tmp/${v}.json`) and the quoted (`/tmp/"$v"/f`, `/tmp/'lit'`) spellings
# alike.
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

# THE PREDICATE READS FILE CONTENT, NEVER `grep -rn`'s PREFIX (round 10,
# F6/F7). Rounds 8 and 9 both tuned a regex applied to `path:line:content`,
# and both left a hole in the same place: the class did not cover a QUOTED
# first component (`/tmp/"$v"/f` — the spelling shellcheck pushes authors
# toward), and the comment exemption matched inside the FILENAME, so a file
# named `a:9:#.sh` exempted its own offending lines. The lint now greps each
# file individually: `grep -n` then emits `lineno:content` with no path, the
# comment exemption is anchored on `^[0-9]+:` and cannot see a filename, and
# the path is re-attached with `printf` purely for the report. The class is
# the union of filename characters, `$`, and the two quote characters. Bare
# `/tmp` with no child component stays legal (see above).
#
# `|| true` on the inner pipeline is MANDATORY: under `set -euo pipefail` a
# file with no match makes `grep` exit 1, which would abort the whole lint
# silently with no output. `-- "$f"` keeps a filename beginning with `-`
# from being read as a grep option; `printf` (not `sed`) re-attaches the path
# so a filename containing `|`, `&` or a backslash cannot alter the
# rendering; `LC_ALL=C sort -z` makes the report order deterministic.
hits="$(
	find scripts tests plugins -type f -name '*.sh' -print0 |
		LC_ALL=C sort -z |
		while IFS= read -r -d '' f; do
			grep -nE "(/tmp|/var/tmp)/[A-Za-z0-9._\$'\"-]" -- "$f" |
				grep -vE '^[0-9]+:[[:space:]]*#' |
				while IFS= read -r line; do printf '%s:%s\n' "$f" "$line"; done || true
		done
)"

if [[ -n "$hits" ]]; then
	echo "lint-temp-paths: hard-coded temp path(s) below /tmp found -- use mktemp:" >&2
	printf '%s\n' "$hits" >&2
	exit 1
fi
exit 0
