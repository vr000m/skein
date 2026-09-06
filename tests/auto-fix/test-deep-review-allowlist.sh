#!/usr/bin/env bash
# Allowlist gating regression for scripts/apply-auto-fix-code.sh.
#
# Acceptance Criteria covered:
#   AC #1 — allowlisted kind (unused_import) lands a commit with the right
#           subject + trailer and the manifest records status=applied.
#   AC #2 — non-allowlisted kinds (refactor_method, dead_branch) leave the
#           working tree clean and the manifest records status=rejected_kind.
#
# Also exercises adversarial rejects: mechanical_replace-reject-multiline
# (multi-line `before` rejected pre-apply) and
# unused_var-reject-test-file-read (var read by a test file → re-verify
# catches before apply).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

require_applier

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# --- AC #1: unused_import accept ----------------------------------------
case1="$scratch/c1"
mkdir -p "$case1"
make_repo "$case1" >/dev/null
printf 'from os import path\n' >"$case1/a.py"
git -C "$case1" add a.py
git -C "$case1" commit -q -m "add a.py"
before_head="$(head_sha "$case1")"

cp "$FIXTURES_DIR/unused_import-accept.jsonl" "$case1/findings.json"
run_applier "$case1" --test-cmd "true" "$case1/findings.json"

if [[ $LAST_RC -ne 0 ]]; then
	fail "unused_import-accept: applier exited $LAST_RC (expected 0)"
	echo "$LAST_OUT" | sed 's/^/  /'
else
	after_head="$(head_sha "$case1")"
	if [[ "$after_head" == "$before_head" ]]; then
		fail "unused_import-accept: HEAD did not advance"
	else
		subject="$(git -C "$case1" log -1 --format=%s)"
		body="$(git -C "$case1" log -1 --format=%B)"
		if [[ "$subject" != "auto-fix(deep-review): unused_import at a.py:1" ]]; then
			fail "unused_import-accept: subject mismatch: $subject"
		else
			pass "unused_import-accept: subject matches"
		fi
		if grep -Fq "Auto-Fixed-By: deep-review" <<<"$body"; then
			pass "unused_import-accept: trailer present"
		else
			fail "unused_import-accept: missing 'Auto-Fixed-By: deep-review' trailer"
		fi
		manifest="$(find "$case1/.deep-review" -name 'auto-fix-*.json' -print -quit 2>/dev/null || true)"
		if [[ -z "${manifest:-}" ]]; then
			fail "unused_import-accept: no manifest under .deep-review/"
		elif grep -q '"status": *"applied"' "$manifest" || grep -q '"status":"applied"' "$manifest"; then
			pass "unused_import-accept: manifest status=applied"
		else
			fail "unused_import-accept: manifest missing status=applied"
			sed 's/^/  /' "$manifest"
		fi
		if [[ -s "$case1/a.py" ]]; then
			fail "unused_import-accept: a.py not emptied (rewrite did not apply)"
		else
			pass "unused_import-accept: a.py rewritten"
		fi
	fi
fi

# --- AC #2: non-allowlisted kind → rejected, no commit ------------------
reject_case() {
	local label="$1" fixture="$2" expected_status="$3"
	local d="$scratch/$label"
	mkdir -p "$d"
	make_repo "$d" >/dev/null
	printf 'x = 1\n' >"$d/a.py"
	git -C "$d" add a.py
	git -C "$d" commit -q -m "add a.py"
	local before
	before="$(head_sha "$d")"
	cp "$FIXTURES_DIR/$fixture" "$d/findings.json"
	run_applier "$d" --test-cmd "true" "$d/findings.json"

	local after
	after="$(head_sha "$d")"
	if [[ "$after" != "$before" ]]; then
		fail "$label: HEAD advanced on rejected kind (commit was $after)"
		return
	fi
	pass "$label: HEAD preserved"

	# File should be unchanged on rejected_kind (no edit attempted).
	if [[ "$(cat "$d/a.py")" != "x = 1" ]]; then
		fail "$label: file modified despite rejection"
	else
		pass "$label: file untouched"
	fi

	local manifest
	manifest="$(find "$d/.deep-review" -name 'auto-fix-*.json' -print -quit 2>/dev/null || true)"
	if [[ -z "${manifest:-}" ]]; then
		fail "$label: missing manifest"
		return
	fi
	if grep -q "\"$expected_status\"" "$manifest"; then
		pass "$label: manifest status=$expected_status"
	else
		fail "$label: manifest missing status=$expected_status"
		sed 's/^/  /' "$manifest"
	fi
}

reject_case "refactor_method" "refactor_method-reject-kind.jsonl" "rejected_kind"
reject_case "dead_branch" "dead_branch-reject-kind.jsonl" "rejected_kind"

# --- Adversarial: multi-line mechanical_replace rejected pre-apply ------
adversarial_multiline() {
	local d="$scratch/multiline"
	mkdir -p "$d"
	make_repo "$d" >/dev/null
	printf 'a = 1\nb = 2\n' >"$d/a.py"
	git -C "$d" add a.py
	git -C "$d" commit -q -m "add a.py"
	local before
	before="$(head_sha "$d")"
	cp "$FIXTURES_DIR/mechanical_replace-reject-multiline.jsonl" "$d/findings.json"
	run_applier "$d" --test-cmd "true" "$d/findings.json"
	local after
	after="$(head_sha "$d")"
	if [[ "$after" != "$before" ]]; then
		fail "multiline mechanical_replace: HEAD advanced"
		return
	fi
	pass "multiline mechanical_replace: HEAD preserved"
	local manifest
	manifest="$(find "$d/.deep-review" -name 'auto-fix-*.json' -print -quit 2>/dev/null || true)"
	if [[ -n "${manifest:-}" ]] && grep -q "rejected_multiline" "$manifest"; then
		pass "multiline mechanical_replace: manifest status=rejected_multiline"
	else
		fail "multiline mechanical_replace: manifest missing status=rejected_multiline"
		[[ -n "${manifest:-}" ]] && sed 's/^/  /' "$manifest"
	fi
}
adversarial_multiline

# --- Adversarial: unused_var with test-file read → rejected_revar -------
adversarial_unused_var_test_read() {
	local d="$scratch/unused_var_test_read"
	mkdir -p "$d"
	make_repo "$d" >/dev/null
	# Fixture refers to src_pkg/a.py with var `my_var`. The lens claimed
	# `my_var` had zero reads, but tests/test_a.py references it. Phase 5
	# decided test reads are still blocking reads, so the applier's
	# re-verification must catch this and record `rejected_revar`.
	mkdir -p "$d/src_pkg" "$d/tests"
	printf 'my_var = 1\n' >"$d/src_pkg/a.py"
	printf 'from src_pkg.a import my_var\nassert my_var == 1\n' >"$d/tests/test_a.py"
	git -C "$d" add src_pkg/a.py tests/test_a.py
	git -C "$d" commit -q -m "add src_pkg and tests"
	local before
	before="$(head_sha "$d")"
	cp "$FIXTURES_DIR/unused_var-reject-test-file-read.jsonl" "$d/findings.json"
	run_applier "$d" --test-cmd "true" "$d/findings.json"
	local after
	after="$(head_sha "$d")"
	if [[ "$after" != "$before" ]]; then
		fail "unused_var test-read: HEAD advanced (should drop on re-verify)"
		return
	fi
	pass "unused_var test-read: HEAD preserved"
	# a.py should be intact — no apply happened.
	if grep -q "my_var = 1" "$d/src_pkg/a.py"; then
		pass "unused_var test-read: src_pkg/a.py untouched"
	else
		fail "unused_var test-read: src_pkg/a.py was modified despite re-verify"
	fi
	local manifest
	manifest="$(find "$d/.deep-review" -name 'auto-fix-*.json' -print -quit 2>/dev/null || true)"
	if [[ -n "${manifest:-}" ]] && grep -q "rejected_revar" "$manifest"; then
		pass "unused_var test-read: manifest status=rejected_revar"
	else
		fail "unused_var test-read: manifest missing status=rejected_revar"
		[[ -n "${manifest:-}" ]] && sed 's/^/  /' "$manifest"
	fi
}
adversarial_unused_var_test_read

summary_and_exit
