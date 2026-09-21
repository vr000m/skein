#!/usr/bin/env bash
# Self-tests for RELEASE_LAGGING_MIRROR_OK (release-skill restructure, grilled
# decision 23). Per plane: acknowledged drift -> exit 0 with the stderr
# annotation; unacknowledged drift -> non-zero; unrecognised plane -> non-zero.
# Plus: the variable UNSET restores hard-fail behaviour on all three planes.
# The `release-skill-md` plane's pytest-side skip is covered in
# tests/parity/test_release_skill_contract.py.

set -eu

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0
FAIL=0
TMP="$(mktemp -d "${TMPDIR:-/tmp}/skein-release-lagging.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

_pass() {
	PASS=$((PASS + 1))
	echo "PASS: $1"
}
_fail() {
	FAIL=$((FAIL + 1))
	echo "FAIL: $1" >&2
}

# A fake root holding real scripts + plugins so check-prompt-parity.sh passes
# everything except the release plane under test.
make_root() {
	local root="$1"
	mkdir -p "$root"
	cp -R "$REPO_ROOT/scripts" "$root/scripts"
	cp -R "$REPO_ROOT/plugins" "$root/plugins"
}

run_prompt_parity() {
	local root="$1"
	shift
	(cd "$root" && env "$@" MANAGED_SKILLS=release "$root/scripts/check-prompt-parity.sh") 2>&1
}

# --- release-skill-md plane ------------------------------------------------
root="$TMP/skillmd"
make_root "$root"
printf '\nextra drift line\n' >>"$root/plugins/skein/skills/release/SKILL.md"

if out="$(run_prompt_parity "$root" RELEASE_LAGGING_MIRROR_OK=)"; then
	_fail "release-skill-md: unset variable must hard-fail on drift"
else
	_pass "release-skill-md: unset variable hard-fails on drift"
fi
if out="$(run_prompt_parity "$root" RELEASE_LAGGING_MIRROR_OK=release-skill-md)" &&
	grep -q 'expected lagging-mirror drift: release-skill-md (RELEASE_LAGGING_MIRROR_OK)' <<<"$out"; then
	_pass "release-skill-md: acknowledged drift exits 0 with annotation"
else
	_fail "release-skill-md: acknowledged drift should exit 0 with annotation; out=$out"
fi
if out="$(run_prompt_parity "$root" RELEASE_LAGGING_MIRROR_OK=release-lib)"; then
	_fail "release-skill-md: acknowledging a different plane must not mask drift"
else
	_pass "release-skill-md: acknowledging another plane does not mask drift"
fi
if out="$(run_prompt_parity "$root" RELEASE_LAGGING_MIRROR_OK=release-skill-mdx)"; then
	_fail "unrecognised plane name must be an error"
else
	_pass "unrecognised plane name is an error (prompt parity)"
fi
if grep -q 'unrecognised RELEASE_LAGGING_MIRROR_OK plane' <<<"$out"; then
	_pass "unrecognised plane error names the variable"
else
	_fail "unrecognised plane error should name the variable; out=$out"
fi

# --- release-references plane ---------------------------------------------
root="$TMP/refs"
make_root "$root"
mkdir -p "$root/plugins/skein/skills/release/references"
echo "only on claude" >"$root/plugins/skein/skills/release/references/x.md"
if out="$(run_prompt_parity "$root" RELEASE_LAGGING_MIRROR_OK=)"; then
	_fail "release-references: unset variable must hard-fail on drift"
else
	_pass "release-references: unset variable hard-fails on drift"
fi
# The real Claude mirror already carries anchors the Codex mirror lacks, so the
# release-skill-md plane is acknowledged alongside the plane under test.
if out="$(run_prompt_parity "$root" RELEASE_LAGGING_MIRROR_OK=release-skill-md,release-references)" &&
	grep -q 'expected lagging-mirror drift: release-references (RELEASE_LAGGING_MIRROR_OK)' <<<"$out"; then
	_pass "release-references: acknowledged drift exits 0 with annotation"
else
	_fail "release-references: acknowledged drift should exit 0 with annotation; out=$out"
fi
if out="$(run_prompt_parity "$root" RELEASE_LAGGING_MIRROR_OK=release-skill-md)"; then
	_fail "release-references: acknowledging another plane must not mask drift"
else
	_pass "release-references: acknowledging another plane does not mask drift"
fi

# --- release-lib plane (tests/parity/test-applier-bundle-parity.sh) --------
lib_root="$TMP/lib"
mkdir -p "$lib_root/plugins/skein/skills/release/lib" "$lib_root/plugins/skein-codex/skills/release/lib"
echo "#!/usr/bin/env bash" >"$lib_root/plugins/skein/skills/release/lib/x.sh"
run_bundle_parity() {
	env "$@" PARITY_RELEASE_LIB_ROOT="$lib_root" bash "$REPO_ROOT/tests/parity/test-applier-bundle-parity.sh" 2>&1
}
if out="$(run_bundle_parity RELEASE_LAGGING_MIRROR_OK=)"; then
	_fail "release-lib: unset variable must hard-fail on drift"
else
	_pass "release-lib: unset variable hard-fails on drift"
fi
if out="$(run_bundle_parity RELEASE_LAGGING_MIRROR_OK=release-lib)" &&
	grep -q 'expected lagging-mirror drift: release-lib' <<<"$out"; then
	_pass "release-lib: acknowledged drift exits 0 with annotation"
else
	_fail "release-lib: acknowledged drift should exit 0 with annotation; out=$out"
fi
if out="$(run_bundle_parity RELEASE_LAGGING_MIRROR_OK=release-references)"; then
	_fail "release-lib: acknowledging another plane must not mask drift"
else
	_pass "release-lib: acknowledging another plane does not mask drift"
fi
if out="$(run_bundle_parity RELEASE_LAGGING_MIRROR_OK=release-libx)"; then
	_fail "release-lib: unrecognised plane name must be an error"
else
	_pass "release-lib: unrecognised plane name is an error"
fi

echo ""
echo "Summary: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
