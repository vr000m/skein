#!/usr/bin/env bash
# test-lens-budget.sh — Phase 1 acceptance for `scripts/lens-budget.sh`,
# the ONE budget formula shared (via bundling — see scripts/lib/bundle-map.sh
# bundle_extra_for review-gauntlet in this phase, promoted to BUNDLE_SHARED
# in Phase 2) across the Codex gate, deep-review lenses, and review-plan
# lenses. This suite pins the formula's floors/caps/scaling per plan
# docs/dev_plans/20260823-feature-review-skills-resilience.md, Phase 1, R4a:
#
#   lens      = max(5m, 2m + 45s*files + 10s*(lines/100))       cap 30m
#   plan-lens = max(5m, 2m + 20s*sections)                      cap 30m
#   codex     = max(20m, 2*lens_for_same_files_lines)           cap 45m
#
# Output is a bare integer (seconds) on stdout. An explicit override always
# wins over the computed value — "budgets are one formula, bundled,
# overridable in seconds" (Phase 1 Goal).
#
# The override flag is `--gate-timeout <seconds>` — the one name every
# production caller (both review-gauntlet SKILL.md mirrors) already uses.
# An earlier revision of this suite guessed at a second spelling
# (`--gate-timeout`); that alias was removed so there is one name and one
# behaviour for a script bundled into three skills (G12d).
#
# Exit codes: 0 all assertions pass, 1 any assertion fails.

set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
LENS_BUDGET="$ROOT_DIR/scripts/lens-budget.sh"

pass_count=0
fail_count=0
pass() {
	echo "PASS: $1"
	pass_count=$((pass_count + 1))
}
fail() {
	echo "FAIL: $1"
	fail_count=$((fail_count + 1))
}
assert_eq() {
	local actual="$1" expected="$2" label="$3"
	if [[ "$actual" == "$expected" ]]; then
		pass "$label"
	else
		fail "$label (expected '$expected', got '$actual')"
	fi
}

if [[ ! -x "$LENS_BUDGET" ]]; then
	fail "lens-budget.sh missing or not executable: $LENS_BUDGET"
	echo ""
	echo "Results: $pass_count passed, $fail_count failed"
	exit 1
fi

# --- lens kind: floor, cap, --lines, scaling ------------------------------

# files=3, lines default(0): 120 + 45*3 + 0 = 255 < 300 floor -> 300 (5m).
budget="$("$LENS_BUDGET" --kind lens --files 3)"
assert_eq "$budget" "300" "lens: --files 3 hits the 5m floor (300s)"

# files=122, lines default(0): 120 + 45*122 = 5610 > 1800 cap -> 1800 (30m).
budget="$("$LENS_BUDGET" --kind lens --files 122)"
assert_eq "$budget" "1800" "lens: --files 122 hits the 30m cap (1800s)"

# --lines changes the computed value below the cap: files=5, lines=0 vs
# files=5, lines=1000 (10s * 1000/100 = 100s more).
base="$("$LENS_BUDGET" --kind lens --files 5 --lines 0)"
with_lines="$("$LENS_BUDGET" --kind lens --files 5 --lines 1000)"
assert_eq "$base" "345" "lens: --files 5 --lines 0 computes 2m + 45s*5 = 345s"
assert_eq "$with_lines" "445" "lens: --lines 1000 adds 10s*(1000/100)=100s over the --lines 0 baseline"

# --- plan-lens kind: sections floor/cap -----------------------------------

budget="$("$LENS_BUDGET" --kind plan-lens --sections 5)"
assert_eq "$budget" "300" "plan-lens: --sections 5 hits the 5m floor (300s)"

budget="$("$LENS_BUDGET" --kind plan-lens --sections 50)"
assert_eq "$budget" "1120" "plan-lens: --sections 50 computes 2m + 20s*50 = 1120s"

budget="$("$LENS_BUDGET" --kind plan-lens --sections 100)"
assert_eq "$budget" "1800" "plan-lens: --sections 100 hits the 30m cap (1800s)"

# --- codex kind: 20m floor, 45m cap, mid-range 2x scaling -----------------

# Small files/lines -> underlying lens value floors at 300s; codex = max(1200, 600) = 1200 (20m).
budget="$("$LENS_BUDGET" --kind codex --files 0 --lines 0)"
assert_eq "$budget" "1200" "codex: small files/lines hits the 20m floor (1200s)"

# Large files -> underlying lens value caps at 1800s; codex = max(1200, 3600) capped at 2700 (45m).
budget="$("$LENS_BUDGET" --kind codex --files 122)"
assert_eq "$budget" "2700" "codex: large --files hits the 45m cap (2700s)"

# Mid-range: files=0, lines=7800 -> lens = 120 + 10*(7800/100) = 900s (15m);
# codex = 2*900 = 1800s (30m), strictly between the 1200s floor and 2700s cap.
budget="$("$LENS_BUDGET" --kind codex --files 0 --lines 7800)"
assert_eq "$budget" "1800" "codex: mid-range input (lens=15m) scales to 2x = 30m (1800s), between floor and cap"

# --- output shape: bare integer seconds -----------------------------------

budget="$("$LENS_BUDGET" --kind lens --files 3)"
if [[ "$budget" =~ ^[0-9]+$ ]]; then
	pass "output is a bare integer (seconds), no units suffix or JSON wrapper"
else
	fail "output is not a bare integer: '$budget'"
fi

# --- override beats computed ----------------------------------------------

override_val=777
budget="$("$LENS_BUDGET" --kind lens --files 122 --gate-timeout "$override_val")"
assert_eq "$budget" "$override_val" "lens: an explicit --gate-timeout wins over the computed (would-be-capped) value"

budget="$("$LENS_BUDGET" --kind codex --files 0 --lines 0 --gate-timeout "$override_val")"
assert_eq "$budget" "$override_val" "codex: an explicit --gate-timeout wins over the computed (would-be-floored) value"

# --- missing/invalid --kind is a usage error, not a silent default --------

rc=0
"$LENS_BUDGET" --files 3 >/dev/null 2>&1 || rc=$?
if [[ "$rc" -ge 2 ]]; then
	pass "missing --kind exits with a usage error (rc=$rc), not a silent default"
else
	fail "missing --kind did not exit with a usage error (rc=$rc)"
fi

rc=0
"$LENS_BUDGET" --kind bogus --files 3 >/dev/null 2>&1 || rc=$?
if [[ "$rc" -ge 2 ]]; then
	pass "unrecognised --kind exits with a usage error (rc=$rc)"
else
	fail "unrecognised --kind did not exit with a usage error (rc=$rc)"
fi

# --- override budget validation (finding 4a): reject a non-positive override
# at the boundary — a budget below 1 second means opposite things per
# execution path (GNU `timeout 0s` = unbounded; the shim expires instantly),
# so it must be rejected here rather than passed through.

rc=0
out="$("$LENS_BUDGET" --kind codex --gate-timeout 0 2>/dev/null)" || rc=$?
if [[ "$rc" -ge 2 ]]; then
	pass "codex: --gate-timeout 0 exits with a usage error (rc=$rc)"
else
	fail "codex: --gate-timeout 0 did not exit with a usage error (rc=$rc, stdout='$out')"
fi

stderr_out="$("$LENS_BUDGET" --kind codex --gate-timeout 0 2>&1 >/dev/null)" || true
stdout_out="$("$LENS_BUDGET" --kind codex --gate-timeout 0 2>/dev/null)" || true
if [[ -n "$stderr_out" ]]; then
	pass "codex: --gate-timeout 0 prints a message on stderr"
else
	fail "codex: --gate-timeout 0 produced no stderr message"
fi
if [[ -z "$stdout_out" ]]; then
	pass "codex: --gate-timeout 0 prints nothing on stdout"
else
	fail "codex: --gate-timeout 0 wrote to stdout (expected nothing): '$stdout_out'"
fi

rc=0
"$LENS_BUDGET" --kind codex --gate-timeout 0 >/dev/null 2>&1 || rc=$?
if [[ "$rc" -ge 2 ]]; then
	pass "codex: --gate-timeout 0 exits with a usage error (rc=$rc) — repeated for the second call site"
else
	fail "codex: --gate-timeout 0 did not exit with a usage error (rc=$rc)"
fi

rc=0
"$LENS_BUDGET" --kind lens --gate-timeout -5 >/dev/null 2>&1 || rc=$?
if [[ "$rc" -ge 2 ]]; then
	pass "lens: --gate-timeout -5 exits with a usage error (rc=$rc)"
else
	fail "lens: --gate-timeout -5 did not exit with a usage error (rc=$rc)"
fi

budget="$("$LENS_BUDGET" --kind lens --gate-timeout 1)"
assert_eq "$budget" "1" "lens: --gate-timeout 1 is accepted (boundary value; no over-clamp of an explicit operator override)"

# Regression: the size inputs (--files/--lines/--sections) must still accept
# 0 — the override validation change must not leak across to them.
budget="$("$LENS_BUDGET" --kind lens --files 0 --lines 0)"
assert_eq "$budget" "300" "lens: --files 0 --lines 0 still succeeds at the 300s floor (0 remains legal for size inputs)"

# --- G9 (findings 16/23): zero-padded size inputs and the never-silent rule
# is_nonneg_int accepts "08", but bash's default-base arithmetic reads it as
# octal and errors. `local raw=$((...))` then swallowed that failure in
# `local`'s own return status, so the script printed an error to stderr,
# nothing usable to stdout, and exited 0 — a caller doing
# `budget=$(lens-budget.sh ...)` got an empty budget with success status.

pad_rc=0
pad_out="$("$LENS_BUDGET" --kind lens --files 08 --lines 0 2>/dev/null)" || pad_rc=$?
plain_out="$("$LENS_BUDGET" --kind lens --files 8 --lines 0)"
if [[ "$pad_rc" -eq 0 && "$pad_out" == "$plain_out" ]]; then
	pass "lens: --files 08 is base-10 (same result as --files 8: $plain_out)"
else
	fail "lens: --files 08 must equal --files 8 (rc=$pad_rc, got '$pad_out', want '$plain_out')"
fi

pad_rc=0
pad_out="$("$LENS_BUDGET" --kind lens --files 0 --lines 0900 2>/dev/null)" || pad_rc=$?
plain_out="$("$LENS_BUDGET" --kind lens --files 0 --lines 900)"
if [[ "$pad_rc" -eq 0 && "$pad_out" == "$plain_out" ]]; then
	pass "lens: --lines 0900 is base-10 (same result as --lines 900: $plain_out)"
else
	fail "lens: --lines 0900 must equal --lines 900 (rc=$pad_rc, got '$pad_out', want '$plain_out')"
fi

pad_rc=0
pad_out="$("$LENS_BUDGET" --kind plan-lens --sections 09 2>/dev/null)" || pad_rc=$?
plain_out="$("$LENS_BUDGET" --kind plan-lens --sections 9)"
if [[ "$pad_rc" -eq 0 && "$pad_out" == "$plain_out" ]]; then
	pass "plan-lens: --sections 09 is base-10 (same result as --sections 9: $plain_out)"
else
	fail "plan-lens: --sections 09 must equal --sections 9 (rc=$pad_rc, got '$pad_out', want '$plain_out')"
fi

pad_rc=0
pad_out="$("$LENS_BUDGET" --kind codex --files 08 --lines 08 2>/dev/null)" || pad_rc=$?
plain_out="$("$LENS_BUDGET" --kind codex --files 8 --lines 8)"
if [[ "$pad_rc" -eq 0 && "$pad_out" == "$plain_out" ]]; then
	pass "codex: zero-padded --files/--lines are base-10 (same result: $plain_out)"
else
	fail "codex: zero-padded --files/--lines must match unpadded (rc=$pad_rc, got '$pad_out', want '$plain_out')"
fi

# The invariant behind all four: exit 0 always implies a usable budget on
# stdout. Never "empty stdout, exit 0".
never_silent_ok=1
for probe in "--kind lens --files 08 --lines 0" \
	"--kind lens --files 0 --lines 0900" \
	"--kind plan-lens --sections 09" \
	"--kind codex --files 08 --lines 08" \
	"--kind lens --files 0 --lines 0" \
	"--kind codex --gate-timeout 900"; do
	probe_rc=0
	# shellcheck disable=SC2086 # probe is a deliberate flag list
	probe_out="$("$LENS_BUDGET" $probe 2>/dev/null)" || probe_rc=$?
	if [[ "$probe_rc" -eq 0 ]] && ! [[ "$probe_out" =~ ^[0-9]+$ ]]; then
		fail "never-silent: '$probe' exited 0 with unusable stdout '$probe_out'"
		never_silent_ok=0
	fi
done
if [[ "$never_silent_ok" -eq 1 ]]; then
	pass "never-silent: exit 0 always implies a bare-integer budget on stdout"
fi

# --- G12d: the --override alias is gone; one name, one behaviour ----------

alias_rc=0
alias_out="$("$LENS_BUDGET" --kind lens --override 777 2>/dev/null)" || alias_rc=$?
if [[ "$alias_rc" -ge 2 && -z "$alias_out" ]]; then
	pass "G12d: the --override alias is rejected as an unrecognised argument (rc=$alias_rc)"
else
	fail "G12d: --override must be rejected (rc=$alias_rc, stdout='$alias_out')"
fi

echo ""
echo "Results: $pass_count passed, $fail_count failed"
[[ "$fail_count" -eq 0 ]]
