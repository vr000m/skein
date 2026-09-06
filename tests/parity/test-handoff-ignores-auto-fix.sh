#!/usr/bin/env bash
# Regression for trailer collision: the handoff gate in
# tests/parity/check-mirror-handoff.sh matches phase-boundary commits via
# `grep -q "Conducted-By: <runtime>"` (line 51, case-sensitive). Adding the
# new Phase 2 `Auto-Fixed-By: <skill>` trailer must NOT cause an auto-fix
# commit to be mistaken for a conduct phase-boundary commit.
#
# Three scenarios, all evaluated against the same regex the handoff gate
# uses (case-sensitive `Conducted-By: <runtime>`):
#   (a) commit body has only `Auto-Fixed-By: deep-review`       → ignored
#   (b) commit body has both Auto-Fixed-By + Conducted-By       → matched
#   (c) commit body has lowercase `auto-fixed-by:` only         → ignored
#
# This test stays in tests/parity/ (per plan §Phase 2 Test files) but is
# self-contained — it does not modify the live repo's git history.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HANDOFF="$REPO_ROOT/tests/parity/check-mirror-handoff.sh"

pass_count=0
fail_count=0
pass() {
	echo "PASS: $*"
	pass_count=$((pass_count + 1))
}
fail() {
	echo "FAIL: $*" >&2
	fail_count=$((fail_count + 1))
}

# Verify the handoff gate still uses the case-sensitive 'Conducted-By:'
# match we're contracting against. If this assertion ever fails, the
# contract has shifted and this test (and the trailer convention) must be
# revisited.
if [[ ! -f "$HANDOFF" ]]; then
	fail "preflight: $HANDOFF missing"
	echo ""
	echo "Summary: $pass_count passed, $fail_count failed"
	exit 1
fi
if grep -Eq 'grep[[:space:]]+-[a-zA-Z]*q[[:space:]]+"Conducted-By: \$runtime"' "$HANDOFF"; then
	pass "handoff gate still matches case-sensitive 'Conducted-By: <runtime>'"
else
	fail "handoff gate no longer matches the expected regex; trailer contract may have drifted"
	grep -n "Conducted-By" "$HANDOFF" | sed 's/^/  /'
fi

# Mirror the line-51 check locally. The handoff gate runs:
#   echo "$body" | grep -q "Conducted-By: $runtime" || continue
# We re-implement that exact predicate as a function.
handoff_matches() {
	local body="$1" runtime="$2"
	grep -q "Conducted-By: $runtime" <<<"$body"
}

runtime="claude"

# (a) Auto-Fixed-By alone → ignored
body_a="$(printf 'auto-fix(deep-review): unused_import at a.py:1\n\nAuto-Fixed-By: deep-review\n')"
if handoff_matches "$body_a" "$runtime"; then
	fail "(a) Auto-Fixed-By alone was matched as a conduct boundary"
else
	pass "(a) Auto-Fixed-By alone is ignored"
fi

# (b) Both trailers → matched as Conducted-By
body_b="$(printf 'conduct(phase 2): something\n\nAuto-Fixed-By: deep-review\nConducted-By: claude\n')"
if handoff_matches "$body_b" "$runtime"; then
	pass "(b) Conducted-By alongside Auto-Fixed-By is still matched"
else
	fail "(b) Conducted-By was not matched when Auto-Fixed-By is also present"
fi

# (c) Lowercase auto-fixed-by → ignored (case-sensitive)
body_c="$(printf 'auto-fix(deep-review): unused_import at a.py:1\n\nauto-fixed-by: deep-review\n')"
if handoff_matches "$body_c" "$runtime"; then
	fail "(c) lowercase auto-fixed-by was matched (gate must be case-sensitive)"
else
	pass "(c) lowercase auto-fixed-by is ignored"
fi

# Bonus: a lowercase 'conducted-by:' must also be ignored — same case rule.
body_d="$(printf 'conduct(phase 2): something\n\nconducted-by: claude\n')"
if handoff_matches "$body_d" "$runtime"; then
	fail "lowercase conducted-by was matched (gate must be case-sensitive)"
else
	pass "lowercase conducted-by is ignored (case-sensitive)"
fi

echo ""
echo "Summary: $pass_count passed, $fail_count failed"
[[ $fail_count -eq 0 ]] || exit 1
