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
# --head-sha is mandatory (SKILL.md Scope / Step 1b single-HEAD resolution), so
# every read-release-template.sh call in this suite supplies a valid SHA-1.
FAKE_HEAD_SHA="$(printf '0%.0s' {1..40})"
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
	local args=(--site "$site" --worktree "$wt" --head-commit "$head" --head-sha "$FAKE_HEAD_SHA")
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
		out="$(env -u RELEASE_JQ "$LIB/read-release-template.sh" --site "$6" --worktree "$3" --head-commit "$4" --head-sha "$FAKE_HEAD_SHA" ${5:+--mode "$5"} <"${2/#-//dev/null}" 2>/dev/null)"
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
# `golden_capture_commit` is the original manual pre-extraction capture and
# stays a strict ancestor of phase2_first_commit forever (pytest asserts
# this). A disclosed, separately-reviewed correction to a golden's bytes
# (never an in-phase edit — decision 14) is recorded as
# `golden_recapture_commit` instead of overwriting `golden_capture_commit`,
# so the freeze check diffs against the LATER of the two when a recapture is
# on record, and against the original otherwise.
meta_file="$ROOT/tests/parity/.release-baseline-meta.json"
frozen="$(jq -r '.golden_capture_commit' "$meta_file" 2>/dev/null)"
recapture="$(jq -r '.golden_recapture_commit // empty' "$meta_file" 2>/dev/null)"
if [[ ! "$frozen" =~ ^[0-9a-f]{40}$ ]]; then
	bad "golden_capture_commit is missing or not a 40-hex SHA in tests/parity/.release-baseline-meta.json"
elif [[ -n "$recapture" && ! "$recapture" =~ ^[0-9a-f]{40}$ ]]; then
	bad "golden_recapture_commit is present but not a 40-hex SHA in tests/parity/.release-baseline-meta.json"
else
	pin="$frozen"
	[[ -n "$recapture" ]] && pin="$recapture"
	if git -C "$ROOT" diff --quiet "$pin" -- tests/release/golden/ 2>/dev/null; then
		pass "goldens byte-identical to $pin"
	else
		bad "tests/release/golden/ differs from $pin"
	fi
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
		env -u RELEASE_JQ "$LIB/read-release-template.sh" --site step1b-validate --worktree present-tracked-clean --head-commit present --head-sha "$FAKE_HEAD_SHA" --mode 100644 <"$TPL" >/dev/null 2>&1
	else
		RELEASE_JQ="$val" "$LIB/read-release-template.sh" --site step1b-validate --worktree present-tracked-clean --head-commit present --head-sha "$FAKE_HEAD_SHA" --mode 100644 <"$TPL" >/dev/null 2>&1
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
	env -u RELEASE_JQ "$LIB/read-release-template.sh" --site "$s" --worktree absent --head-commit absent --head-sha "$FAKE_HEAD_SHA" </dev/null >/dev/null 2>&1
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

# --- round-1 review-gauntlet regressions ----------------------------------
# A symlink-free scratch root: release_require_exe rejects symlinked PARENT
# components too, and $TMPDIR itself is symlinked on macOS (/var -> /private/var).
TMP_REAL="$(cd -P "$TMP" && pwd -P)"
WEB="$(cat "$FIX/untemplated/web-base-url.txt")"

a2_run() { # repo-case release-list bodies-dir peeled changelog [git]
	RELEASE_JQ="$JQ_REAL" RELEASE_GIT="${6:-$GIT_REAL}" "$LIB/resolve-template-marker.sh" \
		--site a2-classify --repo "$TMP/repo-$1" --release-list "$2" --bodies-dir "$3" \
		--peeled "$4" --changelog "$5" --web-base-url "$WEB" 2>/dev/null
}

# L5: --head-sha is mandatory, so the SHA-256 hard stop can never be skipped.
RELEASE_JQ="$JQ_REAL" "$LIB/read-release-template.sh" --site step1b-validate \
	--worktree present-tracked-clean --head-commit present --mode 100644 <"$TPL" >/dev/null 2>&1
expect_code "read-release-template without --head-sha" 2 $?

# L2: a CRLF marker-bearing body binds its marker exactly like the LF variant.
lf_dec="$(rec templated v1.0.0 "$FIX/templated/bodies/v1.0.0.lf.md" | jq -r .decision)"
crlf_dec="$(rec templated v1.0.0 "$FIX/templated/bodies/v1.0.0.crlf.md" | jq -r .decision)"
[[ "$crlf_dec" == "marker-bound" && "$crlf_dec" == "$lf_dec" ]] &&
	pass "step3-recovery: CRLF body binds its marker (== LF result)" ||
	bad "step3-recovery CRLF body: got '$crlf_dec', LF gave '$lf_dec'"

# C3: Step 3 recovery with zero markers selects the no-template sentinel even
# when the repo HAS a valid current template (that fallback is Audit A2's only).
[[ "$(rec templated v0.1.0 "$FIX/untemplated/bodies/v0.1.0.md" | jq -r .decision)" == "marker-absent-canonical" ]] &&
	pass "step3-recovery: zero markers ignore a present current template" ||
	bad "step3-recovery zero markers selected the current template"

# C6: a markerless step3-recovery reaches no gate run, so it must not need jq.
env -u RELEASE_JQ RELEASE_GIT="$GIT_REAL" "$LIB/resolve-template-marker.sh" --site step3-recovery \
	--repo "$TMP/repo-untemplated" --tag v0.1.0 --body-file "$FIX/untemplated/bodies/v0.1.0.md" \
	--peeled "$FIX/untemplated/peeled-commits.json" >/dev/null 2>&1
expect_code "step3-recovery markerless with RELEASE_JQ unset" 0 $?

# C5: a failed `git ls-tree` is the UNANSWERED tri-state, never template absence.
cat >"$TMP_REAL/git-no-ls-tree" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do [[ "\$a" == "ls-tree" ]] && exit 128; done
exec "$GIT_REAL" "\$@"
STUB
chmod +x "$TMP_REAL/git-no-ls-tree"
out="$(a2_run untemplated "$FIX/untemplated/release-list.json" "$FIX/untemplated/bodies" \
	"$FIX/untemplated/peeled-commits.json" "$FIX/untemplated/CHANGELOG.md" "$TMP_REAL/git-no-ls-tree")"
[[ "$(jq -r '[.rows[].status] | unique | join(",")' <<<"$out")" == "template-marker-unresolvable" ]] &&
	pass "a2-classify: unreadable ls-tree fails closed, never 'absent'" ||
	bad "a2-classify ls-tree failure did not fail closed: $out"

# C9: every release-list entry must carry string tagName and name.
printf '[{"tagName":"v0.1.0","name":null}]\n' >"$TMP/bad-list.json"
a2_run untemplated "$TMP/bad-list.json" "$FIX/untemplated/bodies" \
	"$FIX/untemplated/peeled-commits.json" "$FIX/untemplated/CHANGELOG.md" >"$TMP/badlist.out"
expect_code "a2-classify rejects a non-string release name" 1 $?
[[ "$(jq -r '.failed_gate' "$TMP/badlist.out")" == "release-list-shape" ]] &&
	pass "a2-classify names the release-list gate" || bad "a2-classify release-list gate name"

# C7: `v01.2.3` is a non-release tag (strict SemVer), never a classified row.
jq '. + [{"tagName":"v01.2.3","name":"v01.2.3"}]' "$FIX/untemplated/release-list.json" >"$TMP/lz-list.json"
jq '. + {"v01.2.3":"b66041d9cf88e611c0127e98b0e6c2ac7a8a434d"}' "$FIX/untemplated/peeled-commits.json" >"$TMP/lz-peeled.json"
mkdir -p "$TMP/lz-bodies" && cp "$FIX/untemplated/bodies/"*.md "$TMP/lz-bodies/"
cp "$FIX/untemplated/bodies/v0.1.0.md" "$TMP/lz-bodies/v01.2.3.md"
out="$(a2_run untemplated "$TMP/lz-list.json" "$TMP/lz-bodies" "$TMP/lz-peeled.json" "$FIX/untemplated/CHANGELOG.md")"
[[ "$(jq -r '[.rows[].version] | join(",")' <<<"$out")" == "0.1.0,0.2.0" ]] &&
	pass "a2-classify excludes a leading-zero version from the union" ||
	bad "a2-classify admitted a leading-zero version: $out"

# L6: one missing body classifies its row; it never aborts the whole audit.
mkdir -p "$TMP/gap-bodies" && cp "$FIX/untemplated/bodies/v0.2.0.md" "$TMP/gap-bodies/"
out="$(a2_run untemplated "$FIX/untemplated/release-list.json" "$TMP/gap-bodies" \
	"$FIX/untemplated/peeled-commits.json" "$FIX/untemplated/CHANGELOG.md")"
code=$?
[[ "$code" == 0 && "$(jq -r '.rows | length' <<<"$out")" == 2 &&
"$(jq -r '.rows[] | select(.version == "0.1.0") | .status' <<<"$out")" == "template-marker-unresolvable" &&
"$(jq -r '.rows[] | select(.version == "0.2.0") | .status' <<<"$out")" == "ok" ]] &&
	pass "a2-classify: a missing body classifies its row, audit continues" ||
	bad "a2-classify aborted (exit $code) on a missing body: $out"

# L1: whats_new:false makes a PRESENT `## What's New` paragraph drift.
mkdir -p "$TMP/wn-bodies" && cp "$FIX/templated/bodies/"*.lf.md "$TMP/wn-bodies/"
{
	printf '## What%ss New\n\nAlpha lands.\n\n' "'"
	cat "$FIX/templated/bodies/v1.0.0.lf.md"
} >"$TMP/wn-bodies/v1.0.0.lf.md"
out="$(a2_run templated "$FIX/templated/release-list.json" "$TMP/wn-bodies" \
	"$FIX/templated/peeled-commits.json" "$FIX/templated/CHANGELOG.md")"
[[ "$(jq -r '.rows[] | select(.version == "1.0.0") | .status' <<<"$out")" == "drifted" ]] &&
	pass "a2-classify: whats_new:false + present summary is drift" ||
	bad "a2-classify treated a present summary as ok under whats_new:false: $out"

# C8: the CHANGELOG header match tolerates whitespace/punctuation drift.
sed 's/^## \[0\.1\.0\] - /##  [0.1.0]  – /' "$FIX/untemplated/CHANGELOG.md" >"$TMP/drifted-changelog.md"
out="$(a2_run untemplated "$FIX/untemplated/release-list.json" "$FIX/untemplated/bodies" \
	"$FIX/untemplated/peeled-commits.json" "$TMP/drifted-changelog.md")"
[[ "$(jq -r '.rows[] | select(.version == "0.1.0") | .status' <<<"$out")" == "ok" ]] &&
	pass "a2-classify: tolerant CHANGELOG-header retry (Step 1 item 5)" ||
	bad "a2-classify did not retry a drifted CHANGELOG header: $out"

# S2: release_emit JSON-escapes free-form text (`failed_gate` carries notes).
# shellcheck source=plugins/skein/skills/release/lib/release-common.sh disable=SC1091
. "$LIB/release-common.sh"
evil='he said "hi" \ and
a newline'
emitted="$(release_emit demo demo-site demo-decision 1 "$evil")"
if jq -e . <<<"$emitted" >/dev/null 2>&1 && [[ "$(jq -r '.failed_gate' <<<"$emitted")" == "$evil" ]]; then
	pass "release_emit escapes quotes/backslashes/newlines in free-form text"
else
	bad "release_emit did not round-trip a free-form note: $emitted"
fi

# S3: a symlinked PARENT component of a pinned executable is rejected.
mkdir -p "$TMP_REAL/realbin" && printf '#!/bin/sh\nexit 0\n' >"$TMP_REAL/realbin/jq" && chmod +x "$TMP_REAL/realbin/jq"
ln -sfn "$TMP_REAL/realbin" "$TMP_REAL/linkbin"
RELEASE_JQ="$TMP_REAL/linkbin/jq" "$LIB/read-release-template.sh" --site step1b-validate \
	--worktree present-tracked-clean --head-commit present --head-sha "$FAKE_HEAD_SHA" --mode 100644 \
	<"$TPL" >/dev/null 2>&1
expect_code "read-release-template rejects a symlinked parent component" 2 $?

exit "$fail"
