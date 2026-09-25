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
# A symlink-free scratch root: release_require_exe rejects symlinked PARENT
# components too, and $TMPDIR itself is symlinked on macOS (/var -> /private/var).
# Any test candidate meant to exercise release_require_exe's leaf-condition
# checks (missing/nonexec/symlink) must be built under this, not raw $TMP — a
# symlinked $TMP would let the parent-symlink check short-circuit before the
# leaf condition the test claims to exercise ever runs, passing vacuously.
TMP_REAL="$(cd -P "$TMP" && pwd -P)"

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
for c in templated untemplated none-label; do
	release_build_repo "$c" "$TMP/repo-$c" || bad "fixture build $c"
done
# repo_head <case> — resolve-template-marker.sh's --head-sha is mandatory
# (round-2 fix 4, matching read-release-template.sh's contract) and, unlike
# read-release-template.sh's stdin-only sites, it does real `git ls-tree`/
# `rev-parse` reads against --repo, so it needs the fixture repo's ACTUAL
# HEAD, never FAKE_HEAD_SHA.
repo_head() { "$GIT_REAL" -C "$TMP/repo-$1" rev-parse HEAD; }
run_a2() { # case
	local c="$1" web
	web="$(cat "$FIX/untemplated/web-base-url.txt")"
	RELEASE_JQ="$JQ_REAL" RELEASE_GIT="$GIT_REAL" "$LIB/resolve-template-marker.sh" --site a2-classify \
		--repo "$TMP/repo-$c" --release-list "$FIX/$c/release-list.json" --bodies-dir "$FIX/$c/bodies" \
		--peeled "$FIX/$c/peeled-commits.json" --tags "$FIX/$c/tags.json" --changelog "$FIX/$c/CHANGELOG.md" \
		--web-base-url "$web" --head-sha "$(repo_head "$c")"
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
	missing) val="$TMP_REAL/no-such-jq" ;;
	nonexec)
		: >"$TMP_REAL/notexec"
		val="$TMP_REAL/notexec"
		;;
	symlink)
		ln -sf "$JQ_REAL" "$TMP_REAL/jq-link"
		val="$TMP_REAL/jq-link"
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
		env -u RELEASE_JQ RELEASE_GIT="$GIT_REAL" "$LIB/resolve-template-marker.sh" --site a2-classify --repo "$TMP/repo-untemplated" --release-list "$FIX/untemplated/release-list.json" --bodies-dir "$FIX/untemplated/bodies" --peeled "$FIX/untemplated/peeled-commits.json" --changelog "$FIX/untemplated/CHANGELOG.md" --web-base-url "$web" --head-sha "$(repo_head untemplated)" >/dev/null 2>&1
	else
		RELEASE_JQ="$val" RELEASE_GIT="$GIT_REAL" "$LIB/resolve-template-marker.sh" --site a2-classify --repo "$TMP/repo-untemplated" --release-list "$FIX/untemplated/release-list.json" --bodies-dir "$FIX/untemplated/bodies" --peeled "$FIX/untemplated/peeled-commits.json" --changelog "$FIX/untemplated/CHANGELOG.md" --web-base-url "$web" --head-sha "$(repo_head untemplated)" >/dev/null 2>&1
	fi
	expect_code "resolve-template-marker with RELEASE_JQ $label" 2 $?
	if [[ "$label" == unset ]]; then
		env -u RELEASE_GIT RELEASE_JQ="$JQ_REAL" "$LIB/resolve-template-marker.sh" --site a2-classify --repo "$TMP/repo-untemplated" --release-list "$FIX/untemplated/release-list.json" --bodies-dir "$FIX/untemplated/bodies" --peeled "$FIX/untemplated/peeled-commits.json" --changelog "$FIX/untemplated/CHANGELOG.md" --web-base-url "$web" --head-sha "$(repo_head untemplated)" >/dev/null 2>&1
	else
		RELEASE_GIT="$val" RELEASE_JQ="$JQ_REAL" "$LIB/resolve-template-marker.sh" --site a2-classify --repo "$TMP/repo-untemplated" --release-list "$FIX/untemplated/release-list.json" --bodies-dir "$FIX/untemplated/bodies" --peeled "$FIX/untemplated/peeled-commits.json" --changelog "$FIX/untemplated/CHANGELOG.md" --web-base-url "$web" --head-sha "$(repo_head untemplated)" >/dev/null 2>&1
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
rec() { RELEASE_JQ="$JQ_REAL" RELEASE_GIT="$GIT_REAL" "$LIB/resolve-template-marker.sh" --site step3-recovery --repo "$TMP/repo-$1" --tag "$2" --body-file "$3" --peeled "$FIX/$1/peeled-commits.json" --head-sha "$(repo_head "$1")" 2>/dev/null; }
[[ "$(rec templated v1.0.0 "$FIX/templated/bodies/v1.0.0.lf.md" | jq -r .decision)" == "marker-bound" ]] && pass "step3-recovery: marker-bound" || bad "step3-recovery marker-bound"
[[ "$(rec untemplated v0.1.0 "$FIX/untemplated/bodies/v0.1.0.md" | jq -r .decision)" == "marker-absent-canonical" ]] && pass "step3-recovery: marker-absent-canonical" || bad "step3-recovery marker-absent-canonical"
[[ "$(rec templated v1.2.0 "$FIX/templated/bodies/v1.2.0.lf.md" | jq -r .decision)" == "template-marker-unresolvable" ]] && pass "step3-recovery: unresolvable" || bad "step3-recovery unresolvable"

# --- round-1 review-gauntlet regressions ----------------------------------
# TMP_REAL is defined once, near TMP's own creation above.
WEB="$(cat "$FIX/untemplated/web-base-url.txt")"

a2_run() { # repo-case release-list bodies-dir peeled changelog [git] [tags]
	RELEASE_JQ="$JQ_REAL" RELEASE_GIT="${6:-$GIT_REAL}" "$LIB/resolve-template-marker.sh" \
		--site a2-classify --repo "$TMP/repo-$1" --release-list "$2" --bodies-dir "$3" \
		--peeled "$4" --tags "${7:-$FIX/$1/tags.json}" --changelog "$5" --web-base-url "$WEB" \
		--head-sha "$(repo_head "$1")" 2>/dev/null
}

# L5: --head-sha is mandatory, so the SHA-256 hard stop can never be skipped.
RELEASE_JQ="$JQ_REAL" "$LIB/read-release-template.sh" --site step1b-validate \
	--worktree present-tracked-clean --head-commit present --mode 100644 <"$TPL" >/dev/null 2>&1
expect_code "read-release-template without --head-sha" 2 $?

# round-2 fix 4: resolve-template-marker.sh's --head-sha is equally mandatory
# now (it used to self-resolve HEAD; see the script's HEAD_SHA comment).
RELEASE_JQ="$JQ_REAL" RELEASE_GIT="$GIT_REAL" "$LIB/resolve-template-marker.sh" --site a2-classify \
	--repo "$TMP/repo-untemplated" --release-list "$FIX/untemplated/release-list.json" \
	--bodies-dir "$FIX/untemplated/bodies" --peeled "$FIX/untemplated/peeled-commits.json" \
	--changelog "$FIX/untemplated/CHANGELOG.md" --web-base-url "$WEB" >/dev/null 2>&1
expect_code "resolve-template-marker without --head-sha" 2 $?

# L2: a CRLF marker-bearing body binds its marker exactly like the LF variant.
lf_dec="$(rec templated v1.0.0 "$FIX/templated/bodies/v1.0.0.lf.md" | jq -r .decision)"
crlf_dec="$(rec templated v1.0.0 "$FIX/templated/bodies/v1.0.0.crlf.md" | jq -r .decision)"
[[ "$crlf_dec" == "marker-bound" && "$crlf_dec" == "$lf_dec" ]] &&
	pass "step3-recovery: CRLF body binds its marker (== LF result)" ||
	bad "step3-recovery CRLF body: got '$crlf_dec', LF gave '$lf_dec'"

# round-2 fix 1 root cause: resolve_source's ok/drifted comparison read the RAW
# $bfile (not the CR-normalized SRC_SCAN), so a CRLF marker line's `-->$` never
# matched and a correctly-composed CRLF release misclassified `drifted`
# ("exact CHANGELOG bytes"). The CRLF fixture was previously exercised only via
# step3-recovery (above), never through a2-classify's own comparison path —
# that gap is what let the bug ship. Swap v1.0.0's classified body for the
# CRLF variant and require the SAME `ok` status the LF golden already pins.
mkdir -p "$TMP/crlf-bodies" && cp "$FIX/templated/bodies/"*.lf.md "$TMP/crlf-bodies/"
cp "$FIX/templated/bodies/v1.0.0.crlf.md" "$TMP/crlf-bodies/v1.0.0.lf.md"
out="$(a2_run templated "$FIX/templated/release-list.json" "$TMP/crlf-bodies" \
	"$FIX/templated/peeled-commits.json" "$FIX/templated/CHANGELOG.md")"
[[ "$(jq -r '.rows[] | select(.version == "1.0.0") | .status' <<<"$out")" == "ok" ]] &&
	pass "a2-classify: a CRLF marker-bearing body classifies ok (== LF result)" ||
	bad "a2-classify misclassified a CRLF body: $out"

# C3: Step 3 recovery with zero markers selects the no-template sentinel even
# when the repo HAS a valid current template (that fallback is Audit A2's only).
[[ "$(rec templated v0.1.0 "$FIX/untemplated/bodies/v0.1.0.md" | jq -r .decision)" == "marker-absent-canonical" ]] &&
	pass "step3-recovery: zero markers ignore a present current template" ||
	bad "step3-recovery zero markers selected the current template"

# C6: a markerless step3-recovery reaches no gate run, so it must not need jq.
env -u RELEASE_JQ RELEASE_GIT="$GIT_REAL" "$LIB/resolve-template-marker.sh" --site step3-recovery \
	--repo "$TMP/repo-untemplated" --tag v0.1.0 --body-file "$FIX/untemplated/bodies/v0.1.0.md" \
	--peeled "$FIX/untemplated/peeled-commits.json" --head-sha "$(repo_head untemplated)" >/dev/null 2>&1
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

# User-requested fix 2a: a --release-list tag absent from --tags is an
# input-consistency bug, never a legitimate "no previous release" — must fail
# closed with a named gate rather than silently emitting prev: null.
jq -c '.[0].tagName = "v0.9.9"' "$FIX/untemplated/release-list.json" >"$TMP/rl-tag-mismatch.json"
a2_run untemplated "$TMP/rl-tag-mismatch.json" "$FIX/untemplated/bodies" \
	"$FIX/untemplated/peeled-commits.json" "$FIX/untemplated/CHANGELOG.md" >"$TMP/rl-tag-mismatch.out"
expect_code "a2-classify fails closed on a release-list tag absent from --tags" 1 $?
[[ "$(jq -r '.failed_gate' "$TMP/rl-tag-mismatch.out")" == "tag-not-in-inventory" ]] &&
	pass "a2-classify names the tag-not-in-inventory gate" ||
	bad "a2-classify tag-not-in-inventory gate name: $(cat "$TMP/rl-tag-mismatch.out")"

# User-requested fix 2b: two --release-list entries sharing a tagName drove
# two classification passes for the same version and silently discarded the
# second title — must fail closed with a named uniqueness gate instead.
jq -c '. + [{"tagName":"v0.1.0","name":"a second title for the same tag"}]' \
	"$FIX/untemplated/release-list.json" >"$TMP/rl-dup-tag.json"
a2_run untemplated "$TMP/rl-dup-tag.json" "$FIX/untemplated/bodies" \
	"$FIX/untemplated/peeled-commits.json" "$FIX/untemplated/CHANGELOG.md" >"$TMP/rl-dup-tag.out"
expect_code "a2-classify fails closed on a duplicate release-list tagName" 1 $?
[[ "$(jq -r '.failed_gate' "$TMP/rl-dup-tag.out")" == "release-list-duplicate-tag" ]] &&
	pass "a2-classify names the release-list-duplicate-tag gate" ||
	bad "a2-classify release-list-duplicate-tag gate name: $(cat "$TMP/rl-dup-tag.out")"

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

# round-2 fix 5: release_emit must never hand-splice an empty/malformed `rows`
# or a non-integer `exit_code` into unquoted JSON positions — that produces
# invalid JSON (`"rows":,`) on a nominally-successful exit, e.g. when an
# upstream `jq` pipeline under `set -uo pipefail` (no `-e`) silently emptied
# `$rows` before the caller ever inspected it.
emitted="$(release_emit demo demo-site demo-decision 0 "" "")"
if jq -e . <<<"$emitted" >/dev/null 2>&1 && [[ "$(jq -c '.rows' <<<"$emitted")" == "[]" ]]; then
	pass "release_emit defaults an empty rows to []"
else
	bad "release_emit did not produce valid JSON for an empty rows: $emitted"
fi
emitted="$(release_emit demo demo-site demo-decision "not-a-number" "" "[]")"
if jq -e . <<<"$emitted" >/dev/null 2>&1 && [[ "$(jq -r '.exit_code' <<<"$emitted")" =~ ^[0-9]+$ ]]; then
	pass "release_emit rejects a non-integer exit_code without breaking JSON"
else
	bad "release_emit did not produce valid JSON for a non-integer exit_code: $emitted"
fi

# S3: a symlinked PARENT component of a pinned executable is rejected.
mkdir -p "$TMP_REAL/realbin" && printf '#!/bin/sh\nexit 0\n' >"$TMP_REAL/realbin/jq" && chmod +x "$TMP_REAL/realbin/jq"
ln -sfn "$TMP_REAL/realbin" "$TMP_REAL/linkbin"
RELEASE_JQ="$TMP_REAL/linkbin/jq" "$LIB/read-release-template.sh" --site step1b-validate \
	--worktree present-tracked-clean --head-commit present --head-sha "$FAKE_HEAD_SHA" --mode 100644 \
	<"$TPL" >/dev/null 2>&1
expect_code "read-release-template rejects a symlinked parent component" 2 $?

# --- round-3 review-gauntlet regressions ----------------------------------

# Round-3 fix 2 root cause: the missing-body row set `any_templated=1`
# unconditionally, even though this candidate's body was never read and so
# neither a marker nor a current template could have participated in its
# classification — contradicting audit-inference.md's field contract that
# `case` is "templated" only when one of those actually did. The L6 fixture
# above (untemplated repo, v0.1.0's body missing, v0.2.0 present and `ok`) is
# exactly this scenario; assert `case` on top of L6's own `out`/`code`.
[[ "$code" == 0 && "$(jq -r '.case' <<<"$out")" == "untemplated" ]] &&
	pass "a2-classify: a missing body in an untemplated repo keeps case=untemplated" ||
	bad "a2-classify: missing body wrongly flipped case to templated: $out"

# Round-3 fix 4 root cause: Audit PREV was derived from --peeled's KEYS, but
# A1.1 explicitly permits a tag's peeled identity to be recorded "unavailable"
# while the tag stays in the origin inventory — unavailability costs only
# that tag's own origin anchor, never its membership in the PREV-candidate
# pool. Remove v0.1.0 from --peeled (simulating an unavailable peeled
# identity) while it stays in --tags; v0.2.0 never referenced v0.1.0's peeled
# SHA directly, so its own classification (and its `prev` field) must be
# unaffected.
jq 'del(.["v0.1.0"])' "$FIX/untemplated/peeled-commits.json" >"$TMP/peeled-no-v010.json"
out="$(a2_run untemplated "$FIX/untemplated/release-list.json" "$FIX/untemplated/bodies" \
	"$TMP/peeled-no-v010.json" "$FIX/untemplated/CHANGELOG.md")"
[[ "$(jq -r '.rows[] | select(.version == "0.2.0") | .prev' <<<"$out")" == "v0.1.0" &&
"$(jq -r '.rows[] | select(.version == "0.2.0") | .status' <<<"$out")" == "ok" ]] &&
	pass "a2-classify: an unavailable peeled identity does not falsify an adjacent candidate's PREV" ||
	bad "a2-classify: removing v0.1.0 from --peeled falsified 0.2.0's classification: $out"

# Round-3 fix 5 root cause: the --peeled shape gate lived only inside
# resolve_source's marker-present branch, past the SITE's own actual first
# read of --peeled — a markerless a2-classify run never reaches that branch,
# so a malformed --peeled (e.g. a bare array, exactly the shape the gate
# exists to reject) silently exited 0 with every row's `prev` null instead of
# failing closed. --tags is valid here; only --peeled is malformed.
printf '["v0.1.0","v0.2.0"]' >"$TMP/peeled-bad-shape.json"
out="$(a2_run untemplated "$FIX/untemplated/release-list.json" "$FIX/untemplated/bodies" \
	"$TMP/peeled-bad-shape.json" "$FIX/untemplated/CHANGELOG.md")"
code=$?
[[ "$code" == 1 && "$(jq -r '.failed_gate' <<<"$out")" == "peeled-shape" ]] &&
	pass "a2-classify: a bare-array --peeled fails closed at the hoisted shape gate" ||
	bad "a2-classify: bare-array --peeled did not fail closed (exit $code): $out"

# Round-3 Codex fix 1 root cause: the marker strip removed only the matched
# marker LINE, never validating what preceded it — a body with TWO blank
# lines before an otherwise validly-bound marker still compared `ok`, because
# `trim_edges` later trims the resulting stray trailing blank line away,
# making the two-blank-line body byte-identical, post-comparison, to the
# one-blank-line body SKILL.md:168 actually requires.
mkdir -p "$TMP/sep-bodies" && cp "$FIX/templated/bodies/"*.lf.md "$TMP/sep-bodies/"
awk '/^<!-- release-template-sha:/ { print ""; print; next } { print }' \
	"$FIX/templated/bodies/v1.0.0.lf.md" >"$TMP/sep-bodies/v1.0.0.lf.md"
out="$(a2_run templated "$FIX/templated/release-list.json" "$TMP/sep-bodies" \
	"$FIX/templated/peeled-commits.json" "$FIX/templated/CHANGELOG.md")"
[[ "$(jq -r '.rows[] | select(.version == "1.0.0") | .status' <<<"$out")" == "template-marker-unresolvable" &&
"$(jq -r '.rows[] | select(.version == "1.0.0") | .note' <<<"$out")" == "marker-shaped line is not preceded by exactly one blank line" ]] &&
	pass "a2-classify: two blank lines before the marker is not ok" ||
	bad "a2-classify: a double-blank-line separator was not caught: $out"

# Round-3 Codex fix 3 root cause: `section_exact`'s header match was a bare
# `index($0, "## [$1]") == 1` prefix check, so a malformed header carrying
# the target version's brackets but arbitrary trailing text (never even
# whitespace/punctuation drift — Step 1 item 5's documented tolerance) matched
# and started extraction from the wrong place. Insert exactly such a line
# ahead of the real `## [0.1.0] - 2026-01-01` section; a correct implementation
# must skip it and still classify `ok` against the real section's content.
{
	printf '# Changelog\n\n'
	printf '## [0.2.0] - 2026-02-01\n\n### Added\n\n- Second thing.\n\n'
	printf '## [0.1.0]bogus\n\nBOGUS CONTENT THAT MUST NOT BE READ\n\n'
	printf '## [0.1.0] - 2026-01-01\n\n### Added\n\n- First thing.\n'
} >"$TMP/prefix-changelog.md"
out="$(a2_run untemplated "$FIX/untemplated/release-list.json" "$FIX/untemplated/bodies" \
	"$FIX/untemplated/peeled-commits.json" "$TMP/prefix-changelog.md")"
[[ "$(jq -r '.rows[] | select(.version == "0.1.0") | .status' <<<"$out")" == "ok" ]] &&
	pass "a2-classify: a malformed header prefix does not hijack section extraction" ||
	bad "a2-classify: a malformed CHANGELOG header prefix hijacked extraction: $out"

# Round-3 deep-review logic fix 6 root cause: `section_exact`/`section_tolerant`
# read the raw $changelog while the release BODY was already CR-normalized
# into SRC_SCAN — a correctly-composed CRLF release (both CHANGELOG and body
# CRLF) previously matched only because both sides were raw; normalizing one
# side without the other reopened the same class of mismatch the body-side
# fix (round-2 fix 1) closed. Build a CRLF CHANGELOG alongside the existing
# CRLF v1.0.0 body ($TMP/crlf-bodies, built above by the round-2 regression)
# and require the same `ok` the LF/LF golden already pins.
sed $'s/$/\r/' "$FIX/templated/CHANGELOG.md" >"$TMP/CHANGELOG.crlf.md"
out="$(a2_run templated "$FIX/templated/release-list.json" "$TMP/crlf-bodies" \
	"$FIX/templated/peeled-commits.json" "$TMP/CHANGELOG.crlf.md")"
[[ "$(jq -r '.rows[] | select(.version == "1.0.0") | .status' <<<"$out")" == "ok" ]] &&
	pass "a2-classify: a CRLF CHANGELOG paired with a CRLF body still classifies ok" ||
	bad "a2-classify: CRLF CHANGELOG + CRLF body misclassified: $out"

# Regression: a What's New paragraph followed by CHANGELOG content with no
# "### "/"## " subsection before the compare line (flat prose or bullets
# directly under the version header) must not be swallowed along with the
# summary — the skip has to end at the paragraph's trailing blank line, not
# only at the next anchor line. Covers both real-world heading styles: no
# blank line between the heading and the paragraph, and a blank line
# between them.
cat >"$TMP/flat-changelog.md" <<'CHANGELOGEOF'
# Changelog

## [0.2.0] - 2026-02-01

Second thing, described in plain prose with no subsection heading.

## [0.1.0] - 2026-01-01

### Added

- First thing.
CHANGELOGEOF
mkdir -p "$TMP/flat-bodies" && cp "$FIX/untemplated/bodies/v0.1.0.md" "$TMP/flat-bodies/"
printf "## What%ss New\nThis adds the second thing.\n\nSecond thing, described in plain prose with no subsection heading.\n\n**Full diff:** %s/compare/v0.1.0...v0.2.0\n" \
	"'" "$WEB" >"$TMP/flat-bodies/v0.2.0.md"
out="$(a2_run untemplated "$FIX/untemplated/release-list.json" "$TMP/flat-bodies" \
	"$FIX/untemplated/peeled-commits.json" "$TMP/flat-changelog.md")"
[[ "$(jq -r '.rows[] | select(.version == "0.2.0") | .status' <<<"$out")" == "ok" ]] &&
	pass "a2-classify: a What's New paragraph before flat (no-subsection) CHANGELOG content classifies ok" ||
	bad "a2-classify: flat CHANGELOG content swallowed with the What's New summary: $out"

# Same case, but the heading is followed by a blank line before the
# paragraph (the other real-world style) — must classify ok too.
printf "## What%ss New\n\nThis adds the second thing.\n\nSecond thing, described in plain prose with no subsection heading.\n\n**Full diff:** %s/compare/v0.1.0...v0.2.0\n" \
	"'" "$WEB" >"$TMP/flat-bodies/v0.2.0.md"
out="$(a2_run untemplated "$FIX/untemplated/release-list.json" "$TMP/flat-bodies" \
	"$FIX/untemplated/peeled-commits.json" "$TMP/flat-changelog.md")"
[[ "$(jq -r '.rows[] | select(.version == "0.2.0") | .status' <<<"$out")" == "ok" ]] &&
	pass "a2-classify: blank-line-after-heading What's New style before flat CHANGELOG content classifies ok" ||
	bad "a2-classify: blank-line-after-heading style misclassified flat content: $out"

# Regression: the What's-New/CHANGELOG split's compare-line boundary anchor
# must be parametrized by the classification source's own compare_line_label
# (SKILL.md Step 3 item 1 / the A2 ok/drifted bullet), never a fixed
# diff-or-changelog alternation. The none-label fixture's template sets
# compare_line_label:"none", under which no compare-line boundary exists at
# all -- so a `## What's New` paragraph whose prose happens to open with bold
# text shaped like a compare trailer (`**Full diff:**`) must stay ordinary
# summary prose, not get mistaken for the boundary and leaked into the
# CHANGELOG-content comparison below it.
out="$(a2_run none-label "$FIX/none-label/release-list.json" "$FIX/none-label/bodies" \
	"$FIX/none-label/peeled-commits.json" "$FIX/none-label/CHANGELOG.md")"
[[ "$(jq -r '.rows[] | select(.version == "0.2.0") | .status' <<<"$out")" == "ok" ]] &&
	pass "a2-classify: compare_line_label:none ignores a Full-diff-shaped line inside the What's New paragraph" ||
	bad "a2-classify: compare_line_label:none boundary anchor not parametrized by label: $out"

exit "$fail"
