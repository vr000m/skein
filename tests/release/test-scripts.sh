#!/usr/bin/env bash
# Golden comparisons and negative cases for the release skill's extracted lib/
# scripts (Phase 2, grilled decisions 9/10/14/17/20). Runs against the Claude
# mirror's lib/ only; RELEASE_LIB_PARITY_FILES byte-parity is the transitive
# guarantee for the Codex copy. Static inputs come from tests/release/fixtures/,
# expected values from tests/release/golden/ (frozen at golden_capture_commit).

# `A && pass || bad` is the suite idiom; pass never fails.
# shellcheck disable=SC2015
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
LIB="${RELEASE_LIB_DIR:-$ROOT/plugins/skein/skills/release/lib}"
FIX="$HERE/fixtures"
GOLDEN="$HERE/golden"
# shellcheck source=tests/release/lib.sh disable=SC1091
. "$HERE/lib.sh"

fail=0
pass() { echo "PASS: $1"; }
bad() {
	echo "FAIL: $1" >&2
	fail=1
}

real() { python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$(command -v "$1")"; }
JQ_REAL="$(real jq)"
GIT_REAL="$(real git)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/skein-release-scripts.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# compare_golden <golden-file> <actual-json> <actual-exit>
# Key-set equality against schema.json, then a `jq -S` projection equality.
# Prints the differing key and returns non-zero on any mismatch.
compare_golden() {
	local golden="$1" actual="$2" code="$3" k
	local want_keys got_keys
	want_keys="$(jq -c '.keys | sort' "$GOLDEN/schema.json")"
	got_keys="$(jq -c 'keys' "$golden")"
	[[ "$got_keys" == "$want_keys" ]] || {
		echo "key set of golden differs from schema.json" >&2
		return 1
	}
	got_keys="$(jq -c 'keys' <<<"$actual" 2>/dev/null)" || {
		echo "actual stdout is not JSON" >&2
		return 1
	}
	[[ "$got_keys" == "$want_keys" ]] || {
		echo "key set of actual output differs (missing key)" >&2
		return 1
	}
	for k in $(jq -r '.keys[]' "$GOLDEN/schema.json"); do
		[[ "$(jq -S -c --arg k "$k" '.[$k]' "$golden")" == "$(jq -S -c --arg k "$k" '.[$k]' <<<"$actual")" ]] || {
			echo "key '$k' differs" >&2
			return 1
		}
	done
	[[ "$(jq -r '.exit_code' "$golden")" == "$code" ]] || {
		echo "key 'exit_code' differs from process exit status" >&2
		return 1
	}
	return 0
}

expect_golden() { # name actual code
	if compare_golden "$GOLDEN/$1.json" "$2" "$3" 2>"$TMP/why"; then
		pass "golden $1"
	else
		bad "golden $1: $(cat "$TMP/why")"
	fi
}

# run_read <stdin-file|-> <worktree> <head> <mode> <site> [extra args...]
run_read() {
	local stdin_file="$1" wt="$2" head="$3" mode="$4" site="$5"
	shift 5
	local args=(--site "$site" --worktree "$wt" --head-commit "$head")
	[[ -n "$mode" ]] && args+=(--mode "$mode")
	if [[ "$stdin_file" == "-" ]]; then
		"$LIB/read-release-template.sh" "${args[@]}" "$@" </dev/null
	else
		"$LIB/read-release-template.sh" "${args[@]}" "$@" <"$stdin_file"
	fi
}

read_case() { # golden-name stdin wt head mode site [env-jq]
	local out code
	if [[ "${7-pinned}" == "unset" ]]; then
		out="$(env -u RELEASE_JQ "$LIB/read-release-template.sh" --site "$6" --worktree "$3" --head-commit "$4" ${5:+--mode "$5"} <"${2/#-//dev/null}" 2>/dev/null)"
		code=$?
	else
		out="$(RELEASE_JQ="$JQ_REAL" run_read "$2" "$3" "$4" "$5" "$6" 2>/dev/null)"
		code=$?
	fi
	expect_golden "$1" "$out" "$code"
}

TPL="$FIX/templated/.release-template.json"

# --- read-release-template.sh goldens -------------------------------------
read_case jq-gate-templated "$TPL" present-tracked-clean present 100644 step1b-validate
read_case jq-gate-untemplated - absent absent "" step1b-validate unset
read_case jq-gate-templated-jq-unset "$TPL" present-tracked-clean present 100644 step1b-validate unset
for g in empty:jq-empty shape:shape enum:enum unknown-key:unknown-key duplicate-key:duplicate-key; do
	read_case "jq-gate-invalid-${g%%:*}" "$FIX/invalid/${g#*:}.json" present-tracked-clean present 100644 step1b-validate
done
read_case commit-precondition-templated - present-tracked-clean present 100644 step1b-precondition
read_case commit-precondition-untemplated - absent absent "" step1b-precondition unset
for s in ii iii iv; do
	wt="$(jq -r '.worktree' "$FIX/presence/state-$s.json")"
	head="$(jq -r '.head_commit' "$FIX/presence/state-$s.json")"
	mode="$(jq -r '.mode // ""' "$FIX/presence/state-$s.json")"
	read_case "commit-precondition-state-$s" - "$wt" "$head" "$mode" step1b-precondition
done

# --- resolve-template-marker.sh goldens -----------------------------------
for c in templated untemplated; do
	release_build_repo "$c" "$TMP/repo-$c" || bad "fixture build $c"
done
run_a2() { # case
	local c="$1" web
	web="$(cat "$FIX/untemplated/web-base-url.txt")"
	RELEASE_JQ="$JQ_REAL" RELEASE_GIT="$GIT_REAL" "$LIB/resolve-template-marker.sh" --site a2-classify \
		--repo "$TMP/repo-$c" --release-list "$FIX/$c/release-list.json" --bodies-dir "$FIX/$c/bodies" \
		--peeled "$FIX/$c/peeled-commits.json" --changelog "$FIX/$c/CHANGELOG.md" --web-base-url "$web"
}
out="$(run_a2 untemplated 2>/dev/null)"
expect_golden a2-marker-absent "$out" $?
out="$(run_a2 templated 2>/dev/null)"
expect_golden a2-templated "$out" $?

# --- freeze check (grilled decision 14) -----------------------------------
frozen="$(jq -r '.golden_capture_commit' "$ROOT/tests/parity/.release-baseline-meta.json" 2>/dev/null)"
if [[ ! "$frozen" =~ ^[0-9a-f]{40}$ ]]; then
	bad "golden_capture_commit is missing or not a 40-hex SHA in tests/parity/.release-baseline-meta.json"
elif git -C "$ROOT" diff --quiet "$frozen" -- tests/release/golden/ 2>/dev/null; then
	pass "goldens byte-identical to golden_capture_commit"
else
	bad "tests/release/golden/ differs from golden_capture_commit $frozen"
fi

# --- permanent self-test: the comparison can fail (G9-style) --------------
sample="$GOLDEN/a2-templated.json"
actual_ok="$(jq -S -c . "$sample")"
tamper_field="$(jq -S -c '.decision = "tampered"' "$sample")"
tamper_exit="$(jq -S -c '.exit_code = 2' "$sample")"
tamper_drop="$(jq -S -c 'del(.rows)' "$sample")"
compare_golden "$sample" "$actual_ok" 0 2>/dev/null && pass "self-test: identical golden passes the comparison" || bad "self-test: identical golden failed"
compare_golden "$sample" "$tamper_field" 0 2>"$TMP/w1" && bad "self-test: changed field not detected" || { grep -q "'decision'" "$TMP/w1" && pass "self-test: changed field detected by key name" || bad "self-test: changed field detected without naming the key"; }
compare_golden "$sample" "$tamper_exit" 0 2>"$TMP/w2" && bad "self-test: changed exit_code not detected" || { grep -q "exit_code" "$TMP/w2" && pass "self-test: changed exit_code detected by key name" || bad "self-test: exit_code mismatch not named"; }
compare_golden "$sample" "$tamper_drop" 0 2>"$TMP/w3" && bad "self-test: dropped key not detected" || { grep -q "missing key" "$TMP/w3" && pass "self-test: dropped key detected" || bad "self-test: dropped key not named"; }

# --- negative cases and the exit-code contract ----------------------------
expect_code() { # name want-code got-code
	[[ "$2" == "$3" ]] && pass "$1 (exit $3)" || bad "$1: want exit $2, got $3"
}
for label in unset relative missing nonexec symlink; do
	case "$label" in
	unset) val="" ;;
	relative) val="jq" ;;
	missing) val="$TMP/no-such-jq" ;;
	nonexec)
		: >"$TMP/notexec"
		val="$TMP/notexec"
		;;
	symlink)
		ln -sf "$JQ_REAL" "$TMP/jq-link"
		val="$TMP/jq-link"
		;;
	esac
	if [[ "$label" == unset ]]; then
		env -u RELEASE_JQ "$LIB/read-release-template.sh" --site step1b-validate --worktree present-tracked-clean --head-commit present --mode 100644 <"$TPL" >/dev/null 2>&1
	else
		RELEASE_JQ="$val" "$LIB/read-release-template.sh" --site step1b-validate --worktree present-tracked-clean --head-commit present --mode 100644 <"$TPL" >/dev/null 2>&1
	fi
	expect_code "read-release-template with RELEASE_JQ $label" 2 $?
	web="$(cat "$FIX/untemplated/web-base-url.txt")"
	if [[ "$label" == unset ]]; then
		env -u RELEASE_JQ RELEASE_GIT="$GIT_REAL" "$LIB/resolve-template-marker.sh" --site a2-classify --repo "$TMP/repo-untemplated" --release-list "$FIX/untemplated/release-list.json" --bodies-dir "$FIX/untemplated/bodies" --peeled "$FIX/untemplated/peeled-commits.json" --changelog "$FIX/untemplated/CHANGELOG.md" --web-base-url "$web" >/dev/null 2>&1
	else
		RELEASE_JQ="$val" RELEASE_GIT="$GIT_REAL" "$LIB/resolve-template-marker.sh" --site a2-classify --repo "$TMP/repo-untemplated" --release-list "$FIX/untemplated/release-list.json" --bodies-dir "$FIX/untemplated/bodies" --peeled "$FIX/untemplated/peeled-commits.json" --changelog "$FIX/untemplated/CHANGELOG.md" --web-base-url "$web" >/dev/null 2>&1
	fi
	expect_code "resolve-template-marker with RELEASE_JQ $label" 2 $?
	if [[ "$label" == unset ]]; then
		env -u RELEASE_GIT RELEASE_JQ="$JQ_REAL" "$LIB/resolve-template-marker.sh" --site a2-classify --repo "$TMP/repo-untemplated" --release-list "$FIX/untemplated/release-list.json" --bodies-dir "$FIX/untemplated/bodies" --peeled "$FIX/untemplated/peeled-commits.json" --changelog "$FIX/untemplated/CHANGELOG.md" --web-base-url "$web" >/dev/null 2>&1
	else
		RELEASE_GIT="$val" RELEASE_JQ="$JQ_REAL" "$LIB/resolve-template-marker.sh" --site a2-classify --repo "$TMP/repo-untemplated" --release-list "$FIX/untemplated/release-list.json" --bodies-dir "$FIX/untemplated/bodies" --peeled "$FIX/untemplated/peeled-commits.json" --changelog "$FIX/untemplated/CHANGELOG.md" --web-base-url "$web" >/dev/null 2>&1
	fi
	expect_code "resolve-template-marker with RELEASE_GIT $label" 2 $?
done

# SHA-256 hard stop runs before the presence oracle, whatever the template state.
RELEASE_JQ="$JQ_REAL" "$LIB/read-release-template.sh" --site step1b-validate --worktree absent --head-commit absent \
	--head-sha "$(printf 'a%.0s' {1..64})" </dev/null >"$TMP/sha256.out" 2>/dev/null
expect_code "read-release-template SHA-256 hard stop" 1 $?
[[ "$(jq -r '.failed_gate' "$TMP/sha256.out")" == "non-sha1-repository" ]] && pass "SHA-256 hard stop names its gate" || bad "SHA-256 hard stop gate name"

# Untemplated path succeeds with RELEASE_JQ unset, on every site (decision 18 state (i)).
for s in step1b-precondition step1b-validate step5-reverify step6-reverify; do
	env -u RELEASE_JQ "$LIB/read-release-template.sh" --site "$s" --worktree absent --head-commit absent </dev/null >/dev/null 2>&1
	expect_code "untemplated $s with RELEASE_JQ unset" 0 $?
done
# Re-verify sites replay the identical item 2/3/4 sequence.
for s in step5-reverify step6-reverify; do
	out="$(RELEASE_JQ="$JQ_REAL" run_read "$TPL" present-tracked-clean present 100644 "$s" 2>/dev/null)"
	[[ "$(jq -r '.decision' <<<"$out")" == "template-valid" ]] && pass "$s validates a templated repo" || bad "$s did not validate a templated repo"
done

# step3-recovery: bound marker, absent marker, unresolvable marker.
rec() { RELEASE_JQ="$JQ_REAL" RELEASE_GIT="$GIT_REAL" "$LIB/resolve-template-marker.sh" --site step3-recovery --repo "$TMP/repo-$1" --tag "$2" --body-file "$3" --peeled "$FIX/$1/peeled-commits.json" 2>/dev/null; }
[[ "$(rec templated v1.0.0 "$FIX/templated/bodies/v1.0.0.lf.md" | jq -r .decision)" == "marker-bound" ]] && pass "step3-recovery: marker-bound" || bad "step3-recovery marker-bound"
[[ "$(rec untemplated v0.1.0 "$FIX/untemplated/bodies/v0.1.0.md" | jq -r .decision)" == "marker-absent-canonical" ]] && pass "step3-recovery: marker-absent-canonical" || bad "step3-recovery marker-absent-canonical"
[[ "$(rec templated v1.2.0 "$FIX/templated/bodies/v1.2.0.lf.md" | jq -r .decision)" == "template-marker-unresolvable" ]] && pass "step3-recovery: unresolvable" || bad "step3-recovery unresolvable"

exit "$fail"
