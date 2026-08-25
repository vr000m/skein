#!/usr/bin/env bash
# lint-temp-paths.sh — refuse PREDICTABLE temp paths anywhere in the tree.
#
# `/tmp/<literal>.$$` and `/tmp/<literal>.$RANDOM` are guessable by any other
# user on the host: a pre-planted symlink at that path is FOLLOWED by bash's
# `>`/`2>` redirect, so the redirect truncates and overwrites whatever the
# running user can write, and a subsequent `rm -f` removes the evidence. It is
# the same threat class persist_atomic_write, ledger_assert_no_symlink and
# gate_assert_no_symlink all defend against; a script that opts out of
# `mktemp` opts out of all of it.
#
# Run from `just lint-scripts`. Exit 0 clean, 1 with the offending lines.
#
# Why a lint and not a test: the sites are inside the test suite itself, and a
# test asserting a test's own temp-path construction is circular.
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC2016  # the '$' here is regex syntax, not a shell expansion.
hits="$(grep -rn --include='*.sh' -E '/tmp/[A-Za-z0-9._-]*\$(\$|RANDOM)' \
	scripts tests plugins || true)"

if [[ -n "$hits" ]]; then
	echo "lint-temp-paths: predictable temp path(s) found -- use mktemp:" >&2
	printf '%s\n' "$hits" >&2
	exit 1
fi
exit 0
