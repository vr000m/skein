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
# matched and a correctly-composed CRLF release misclassified `drifted` (then
# a body-bytes note; check (2) is now the valid-body predicate). The CRLF fixture was previously exercised only via
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

# V1: a compact body (shorter than its CHANGELOG section) is `ok`, not drift;
# an empty body or one embedding a CHANGELOG version header is still drift.
mkdir -p "$TMP/compact-bodies" && cp "$FIX/templated/bodies/"*.lf.md "$TMP/compact-bodies/"
# The compact content block is "### Added\n\n- Alpha." (19 bytes), genuinely
# shorter than the 1.0.0 CHANGELOG section ("### Added\n\n- Alpha feature.", 28).
printf '### Added\n\n- Alpha.\n\n<!-- release-template-sha: %s -->\n' \
	"$(tr -d '[:space:]' <"$FIX/templated/template-blob-sha.txt")" >"$TMP/compact-bodies/v1.0.0.lf.md"
printf '### Added\n\n- Alpha.' >"$TMP/compact-block.txt"
awk '/^## \[1\.0\.0\]/ { on = 1; next } /^## \[/ { on = 0 }
	on { l[NR] = $0; if (NF) { if (!first) first = NR; last = NR } }
	END { for (i = first; i <= last; i++) printf "%s%s", l[i], (i < last ? "\n" : "") }' \
	"$FIX/templated/CHANGELOG.md" >"$TMP/compact-section.txt"
[[ "$(wc -c <"$TMP/compact-block.txt")" -lt "$(wc -c <"$TMP/compact-section.txt")" ]] &&
	! cmp -s "$TMP/compact-block.txt" "$TMP/compact-section.txt" &&
	pass "a2-classify fixture: the compact block is shorter than, and not, the CHANGELOG section" ||
	bad "a2-classify fixture: the compact block is not genuinely shorter than its CHANGELOG section"
out="$(a2_run templated "$FIX/templated/release-list.json" "$TMP/compact-bodies" \
	"$FIX/templated/peeled-commits.json" "$FIX/templated/CHANGELOG.md")"
[[ "$(jq -r '.rows[] | select(.version == "1.0.0") | .status' <<<"$out")" == "ok" ]] &&
	pass "a2-classify: a compact body shorter than its CHANGELOG section is ok" ||
	bad "a2-classify flagged a compact body as drift: $out"
[[ "$(jq -r '.rows[] | select(.version == "1.1.0") | .note' <<<"$out")" == "body (embeds a CHANGELOG header)" ]] &&
	pass "a2-classify: an embedded CHANGELOG header is still body drift" ||
	bad "a2-classify missed an embedded CHANGELOG header: $out"
# The other half of the V1 contract: a whitespace-only body is still body drift.
printf '   \n\n<!-- release-template-sha: %s -->\n' \
	"$(tr -d '[:space:]' <"$FIX/templated/template-blob-sha.txt")" >"$TMP/compact-bodies/v1.0.0.lf.md"
out="$(a2_run templated "$FIX/templated/release-list.json" "$TMP/compact-bodies" \
	"$FIX/templated/peeled-commits.json" "$FIX/templated/CHANGELOG.md")"
[[ "$(jq -r '.rows[] | select(.version == "1.0.0") | .note' <<<"$out")" == "body (empty)" ]] &&
	pass "a2-classify: a whitespace-only body is still body drift" ||
	bad "a2-classify accepted a whitespace-only body: $out"

# V2: one body-validity predicate (non-empty section, non-empty content ignoring
# compare trailers, no version header, no excluded heading) -- each edge case.
note_of() { jq -r --arg v "$2" '.rows[] | select(.version == $v) | (.status + "|" + (.note // ""))' <<<"$1"; }
u_run() { # <v0.1.0-body-file> [changelog]
	rm -rf "$TMP/u-bodies" && mkdir -p "$TMP/u-bodies" && cp "$FIX/untemplated/bodies/"*.md "$TMP/u-bodies/"
	cp "$1" "$TMP/u-bodies/v0.1.0.md"
	a2_run untemplated "$FIX/untemplated/release-list.json" "$TMP/u-bodies" \
		"$FIX/untemplated/peeled-commits.json" "${2:-$FIX/untemplated/CHANGELOG.md}"
}
printf '### Added\n\n- First.\n\n## [Migration guide](guide.md)\n\nSee the guide.\n' >"$TMP/b-link.md"
[[ "$(note_of "$(u_run "$TMP/b-link.md")" 0.1.0)" == "ok|" ]] &&
	pass "a2-classify: a non-version '## [link](url)' heading in a compact body is ok" ||
	bad "a2-classify rejected a legitimate bracketed heading"
printf '##  [0.1.0] – 2026-01-01\n\n### Added\n\n- First.\n' >"$TMP/b-hdr.md"
[[ "$(note_of "$(u_run "$TMP/b-hdr.md")" 0.1.0)" == "drifted|body (embeds a CHANGELOG header)" ]] &&
	pass "a2-classify: a whitespace/en-dash-drifted version header is still body drift" ||
	bad "a2-classify missed a drifted-spelling version header"
printf '\n\n## What%ss New\n\nOnly a summary.\n' "'" >"$TMP/b-sum.md"
[[ "$(note_of "$(u_run "$TMP/b-sum.md")" 0.1.0)" == "drifted|body (empty)" ]] &&
	pass "a2-classify: a summary-only body behind leading blanks is empty-content drift" ||
	bad "a2-classify let a summary-only body with leading blanks pass"
printf '\377### Added\n\n- First \377 thing.\n' >"$TMP/b-bin.md"
out="$(u_run "$TMP/b-bin.md")"
[[ "$(note_of "$out" 0.1.0)" == "ok|" ]] &&
	pass "a2-classify: a stray invalid-UTF-8 byte does not read as an empty body" ||
	bad "a2-classify mis-handled an invalid-UTF-8 byte: $out"
{
	printf '# Changelog\n\n## [0.2.0] - 2026-02-01\n\n### Added\n\n- Second thing.\n\n## [0.1.0] - 2026-01-01\n'
} >"$TMP/cl-empty.md"
[[ "$(note_of "$(u_run "$FIX/untemplated/bodies/v0.1.0.md" "$TMP/cl-empty.md")" 0.1.0)" == "drifted|body (missing CHANGELOG section)" ]] &&
	pass "a2-classify: a body over an empty CHANGELOG section is drift, not ok" ||
	bad "a2-classify passed a body whose CHANGELOG section is empty"
# A stale compare trailer must not mask an otherwise-empty body.
cp "$FIX/untemplated/bodies/v0.2.0.md" "$TMP/b-stale-src.md"
rm -rf "$TMP/u2" && mkdir -p "$TMP/u2" && cp "$FIX/untemplated/bodies/"*.md "$TMP/u2/"
printf '**Full diff:** https://github.com/example/widgets/compare/v0.0.9...v0.2.0\n' >"$TMP/u2/v0.2.0.md"
out="$(a2_run untemplated "$FIX/untemplated/release-list.json" "$TMP/u2" \
	"$FIX/untemplated/peeled-commits.json" "$FIX/untemplated/CHANGELOG.md")"
[[ "$(note_of "$out" 0.2.0)" == *"body (empty)"* ]] &&
	pass "a2-classify: a stale compare trailer does not mask an empty body" ||
	bad "a2-classify let a compare trailer mask an empty body: $out"
# An active excluded_sections heading left in the body is drift. Build a one-off
# templated fixture case (the shipped templated fixture has no exclusions).
FXX="$TMP/fx-excl"
rm -rf "$FXX" && mkdir -p "$FXX/excl"
printf '{"title_format":"bare","compare_line_label":"none","whats_new":false,"excluded_sections":["### Internal"]}\n' >"$FXX/excl/.release-template.json"
printf '# Changelog\n\n## [1.0.0] - 2026-01-01\n\n### Added\n\n- Alpha.\n\n### Internal\n\n- Plumbing.\n' >"$FXX/excl/CHANGELOG.md"
(RELEASE_FIXTURES_DIR="$FXX" release_build_repo excl "$TMP/repo-excl") || bad "fixture build excl"
excl_blob="$("$GIT_REAL" -C "$TMP/repo-excl" rev-parse HEAD~1:.release-template.json)"
excl_c1="$("$GIT_REAL" -C "$TMP/repo-excl" rev-parse HEAD~1)"
printf '["v1.0.0"]\n' >"$FXX/tags.json"
printf '{"v1.0.0": "%s"}\n' "$excl_c1" >"$FXX/peeled.json"
printf '[{"tagName":"v1.0.0","name":"v1.0.0"}]\n' >"$FXX/list.json"
for variant in clean leaked; do
	rm -rf "$FXX/bodies" && mkdir -p "$FXX/bodies"
	if [[ "$variant" == clean ]]; then
		printf '### Added\n\n- Alpha.\n\n<!-- release-template-sha: %s -->\n' "$excl_blob" >"$FXX/bodies/v1.0.0.lf.md"
		want="ok|"
	else
		printf '### Added\n\n- Alpha.\n\n### Internal\n\n- Plumbing.\n\n<!-- release-template-sha: %s -->\n' "$excl_blob" >"$FXX/bodies/v1.0.0.lf.md"
		want="drifted|body (carries an excluded section)"
	fi
	out="$(a2_run excl "$FXX/list.json" "$FXX/bodies" "$FXX/peeled.json" "$FXX/excl/CHANGELOG.md" "" "$FXX/tags.json")"
	[[ "$(note_of "$out" 1.0.0)" == "$want" ]] &&
		pass "a2-classify: excluded_sections heading in a body ($variant) -> $want" ||
		bad "a2-classify excluded_sections ($variant) expected '$want': $out"
done

# V3: the whole valid-body predicate, table-driven over its clauses (Canonical
# Format item 2): one passing compact body, then each clause failing ALONE.
# Clause (e) -- a compare-shaped line inside the content block -- is enforced
# by the compare-path check (3), so its note is that check's, not a body note.
# Rows: name|changelog-file|body-printf-format|expected status|note
printf '# Changelog\n\n## [1.0.0] - 2026-01-01\n\n### Internal \n\n- Plumbing.\n' >"$FXX/cl-only-excl.md"
# A CHANGELOG `### Internal ` heading (trailing space) is excluded by the
# trimmed comparison exactly as at cut time, so the composed block (Added only)
# round-trips to `ok`.
printf '# Changelog\n\n## [1.0.0] - 2026-01-01\n\n### Added\n\n- Alpha.\n\n### Internal \n\n- Plumbing.\n' >"$FXX/cl-ws-excl.md"
# A section left with only a compare-shaped line after exclusions has nothing to
# publish: composition drops compare-shaped lines, so clause (a) fails.
printf '# Changelog\n\n## [1.0.0] - 2026-01-01\n\n**Full diff:** https://example.invalid/x\n\n### Internal\n\n- Plumbing.\n' >"$FXX/cl-only-cmp.md"
# Cut-time trimmed exclusion, observed through clause (a): the section's only
# non-compare content is a trailing-space `### Internal ` subsection, so the
# trimmed drop_excluded empties it (an untrimmed one would keep it -> ok).
printf '# Changelog\n\n## [1.0.0] - 2026-01-01\n\n**Full diff:** https://example.invalid/x\n\n### Internal \n\n- Plumbing.\n' >"$FXX/cl-ws-excl-cmp.md"
# A section carrying a literal compare-shaped line composes WITHOUT it.
printf '# Changelog\n\n## [1.0.0] - 2026-01-01\n\n### Added\n\n- Alpha.\n\n**Full diff:** https://example.invalid/x\n' >"$FXX/cl-lit-cmp.md"
cl_full="$FXX/excl/CHANGELOG.md"
while IFS='|' read -r name cl fmt want; do
	[[ "$cl" == full ]] && cl="$cl_full"
	[[ "$want" == ok ]] && want="ok|" # read drops the trailing empty field
	rm -rf "$FXX/bodies" && mkdir -p "$FXX/bodies"
	# shellcheck disable=SC2059 # fmt is the table's printf format on purpose
	printf -- "$fmt"'\n\n<!-- release-template-sha: %s -->\n' "$excl_blob" >"$FXX/bodies/v1.0.0.lf.md"
	out="$(a2_run excl "$FXX/list.json" "$FXX/bodies" "$FXX/peeled.json" "$cl" "" "$FXX/tags.json")"
	[[ "$(note_of "$out" 1.0.0)" == "$want" ]] &&
		pass "a2-classify predicate table: $name -> $want" ||
		bad "a2-classify predicate table: $name expected '$want': $out"
done <<EOF
valid compact body|full|### Added\n\n- Alpha (short).|ok|
(a) section empty after exclusion (trailing-space CHANGELOG heading)|$FXX/cl-only-excl.md|### Added\n\n- Alpha.|drifted|body (missing CHANGELOG section)
(b) whitespace-only content|full|   |drifted|body (empty)
(c) embeds a version header|full|## [1.0.0] - 2026-01-01\n\n### Added\n\n- Alpha.|drifted|body (embeds a CHANGELOG header)
(d) excluded heading with trailing space|full|### Added\n\n- Alpha.\n\n### Internal \n\n- Plumbing.|drifted|body (carries an excluded section)
(e) compare-shaped line in the content block|full|### Added\n\n- Alpha.\n\n**Full diff:** https://example.invalid/x|drifted|exact cached-base compare path
(d) trailing-space CHANGELOG heading excluded at cut time (rest is a compare line)|$FXX/cl-ws-excl-cmp.md|### Added\n\n- Alpha.|drifted|body (missing CHANGELOG section)
(d) trailing-space CHANGELOG heading excluded at cut time, composed body audited|$FXX/cl-ws-excl.md|### Added\n\n- Alpha.|ok|
(d) trailing-space CHANGELOG heading leaked into the body|$FXX/cl-ws-excl.md|### Added\n\n- Alpha.\n\n### Internal \n\n- Plumbing.|drifted|body (carries an excluded section)
(a) section holds only a compare-shaped line after exclusion|$FXX/cl-only-cmp.md|### Added\n\n- Alpha.|drifted|body (missing CHANGELOG section)
(e) section's literal compare-shaped line dropped by composition|$FXX/cl-lit-cmp.md|### Added\n\n- Alpha.|ok|
EOF

# V4: version-header clause (c) matches the documented whitespace-tolerant
# header shape and nothing wider. Rows: body-printf-format|expected.
while IFS='|' read -r fmt want; do
	# shellcheck disable=SC2059
	printf -- "$fmt" >"$TMP/b-vh.md"
	[[ "$want" == ok ]] && want="ok|" # read drops the trailing empty field
	got="$(note_of "$(u_run "$TMP/b-vh.md")" 0.1.0)"
	[[ "$got" == "$want" ]] &&
		pass "a2-classify version-header shape '$fmt' -> $want" ||
		bad "a2-classify version-header shape '$fmt' expected '$want', got '$got'"
done <<'EOF'
## [ 0.1.0 ] - 2026-01-01\n\n- First.\n|drifted|body (embeds a CHANGELOG header)
   ## [0.1.0] - 2026-01-01\n\n- First.\n|drifted|body (embeds a CHANGELOG header)
- First.\n\n## [0.1.0]\n|drifted|body (embeds a CHANGELOG header)
- First.\n\n## [Unreleased]\n|drifted|body (embeds a CHANGELOG header)
- First.\n\n## [1.2.3](guide.md)\n|ok|
- First.\n\n## [Migration guide](guide.md)\n|ok|
- First.\n\n## [1.2.3 compatibility notes]\n|ok|
- First.\n\n## [1.2.3-rc.1] - 2026-01-01\n|drifted|body (embeds a CHANGELOG header)
- First.\n\n## [1.2.3+build.5]\n|drifted|body (embeds a CHANGELOG header)
- First.\n\n## [1.2.3-]\n|ok|
- First.\n\n## [1.2.3+] - 2026-01-01\n|ok|
- First.\n\n## [1.2.3-rc.1]\n|drifted|body (embeds a CHANGELOG header)
- First.\n\n## [1.2.3+b1]\n|drifted|body (embeds a CHANGELOG header)
- First.\n\n## [1.2.3-rc.1+b.2] - 2026-01-01\n|drifted|body (embeds a CHANGELOG header)
- First.\n\n## [1.2.3+.]\n|ok|
- First.\n\n## [1.2.3-rc..1]\n|ok|
- First.\n\n## [1.2.3-.rc]\n|ok|
- First.\n\n## [1.2.3-rc.]\n|ok|
- First.\n\n## [1.2.3+b.]\n|ok|
EOF

# V5: a summary-only body whose `## What's New` heading carries trailing
# whitespace (or a typographic apostrophe) is still split as a summary, so its
# content is empty -- the split and has_summary share one heading pattern.
printf '## What%ss New  \n\nOnly a summary.\n' "'" >"$TMP/b-sum-ws.md"
[[ "$(note_of "$(u_run "$TMP/b-sum-ws.md")" 0.1.0)" == "drifted|body (empty)" ]] &&
	pass "a2-classify: summary-only body with a trailing-space heading is empty-content drift" ||
	bad "a2-classify let a trailing-space What's New heading slip past the summary split"
printf '## What\342\200\231s New\n\nOnly a summary.\n' >"$TMP/b-sum-curly.md"
[[ "$(note_of "$(u_run "$TMP/b-sum-curly.md")" 0.1.0)" == "drifted|body (empty)" ]] &&
	pass "a2-classify: summary-only body with a typographic apostrophe is empty-content drift" ||
	bad "a2-classify missed a typographic-apostrophe What's New heading"

# V6: a large valid body (>128KB) is ok -- the content test reads the file in
# one awk pass, so no `grep | grep -q` pipe can SIGPIPE under pipefail.
{
	printf '### Added\n\n'
	for i in $(seq 1 3000); do printf -- '- First thing, padded line %05d of a long compact digest body.\n' "$i"; done
} >"$TMP/b-big.md"
[[ "$(wc -c <"$TMP/b-big.md")" -gt 131072 ]] || bad "a2-classify large-body fixture is not >128KB"
big_ok=1
for _ in 1 2 3 4 5; do
	[[ "$(note_of "$(u_run "$TMP/b-big.md")" 0.1.0)" == "ok|" ]] || big_ok=0
done
[[ "$big_ok" == 1 ]] &&
	pass "a2-classify: a >128KB valid body is ok on every run" ||
	bad "a2-classify misread a >128KB valid body as drift"

# V7: the `## What's New` heading is recognised modulo surrounding whitespace and
# a typographic apostrophe, and nothing wider: `## What was New` / `## Whatxs New`
# are ordinary content, never a summary. Rows: body-printf-format|expected.
while IFS='|' read -r fmt want; do
	# shellcheck disable=SC2059
	printf -- "$fmt" >"$TMP/b-wn.md"
	[[ "$want" == ok ]] && want="ok|"
	got="$(note_of "$(u_run "$TMP/b-wn.md")" 0.1.0)"
	[[ "$got" == "$want" ]] &&
		pass "a2-classify What's New heading '$fmt' -> $want" ||
		bad "a2-classify What's New heading '$fmt' expected '$want', got '$got'"
done <<'EOF'
## What was New\n\n- First.\n|ok|
## Whatxs New\n\n- First.\n|ok|
## What\342\200\230s New\n\nOnly a summary.\n|drifted|body (empty)
EOF
# The same single heading pattern drives whats_new:false check (4).
for variant in was curly; do
	rm -rf "$TMP/wn4" && mkdir -p "$TMP/wn4" && cp "$FIX/templated/bodies/"*.lf.md "$TMP/wn4/"
	if [[ "$variant" == was ]]; then
		hdr='## What was New' want="ok|"
	else
		hdr="$(printf '## What\342\200\231s New')" want="drifted|What's New presence-vs-whats_new"
	fi
	{
		printf '%s\n\nAlpha lands.\n\n' "$hdr"
		cat "$FIX/templated/bodies/v1.0.0.lf.md"
	} >"$TMP/wn4/v1.0.0.lf.md"
	out="$(a2_run templated "$FIX/templated/release-list.json" "$TMP/wn4" \
		"$FIX/templated/peeled-commits.json" "$FIX/templated/CHANGELOG.md")"
	[[ "$(note_of "$out" 1.0.0)" == "$want" ]] &&
		pass "a2-classify whats_new:false + '$variant' heading -> $want" ||
		bad "a2-classify whats_new:false + '$variant' heading expected '$want': $out"
done

# V8: clause (c) reads the WHOLE body, before the summary is split off; an
# indented version header right after the summary is caught either way.
printf '## What%ss New\n\nA summary paragraph.\n   ## [0.1.0] \342\200\223 2026-01-01\n\n- First.\n' "'" >"$TMP/b-sum-hdr.md"
[[ "$(note_of "$(u_run "$TMP/b-sum-hdr.md")" 0.1.0)" == "drifted|body (embeds a CHANGELOG header)" ]] &&
	pass "a2-classify: an indented header hidden behind the summary is still body drift" ||
	bad "a2-classify: the summary split hid an embedded CHANGELOG header"

# V10: a CHANGELOG section ends at any header section_tolerant recognises, not
# only a single-space `## [`: an empty 0.1.0 section directly above
# `##  [0.0.9]  –  date` must not absorb 0.0.9's header and notes.
printf '# Changelog\n\n## [0.2.0] - 2026-02-01\n\n### Added\n\n- Second thing.\n\n## [0.1.0] - 2026-01-01\n\n##  [0.0.9]  \342\200\223  2025-12-01\n\n### Added\n\n- Old thing.\n' >"$TMP/cl-empty-ws-next.md"
[[ "$(note_of "$(u_run "$FIX/untemplated/bodies/v0.1.0.md" "$TMP/cl-empty-ws-next.md")" 0.1.0)" == "drifted|body (missing CHANGELOG section)" ]] &&
	pass "a2-classify: an empty section above a whitespace-drifted header is still missing" ||
	bad "a2-classify: an empty CHANGELOG section absorbed the next release's notes"

# V11: drop_excluded and clause (d) share one heading predicate, so an
# excluded_sections entry that trims to a bare `###` is a heading on both sides.
# Rows: name|section-printf-format|body-printf-format|expected.
FXH="$TMP/fx-excl-bare"
rm -rf "$FXH" && mkdir -p "$FXH/exclbare"
printf '{"title_format":"bare","compare_line_label":"none","whats_new":false,"excluded_sections":["###  "]}\n' >"$FXH/exclbare/.release-template.json"
printf '# Changelog\n\n## [1.0.0] - 2026-01-01\n\n- Placeholder.\n' >"$FXH/exclbare/CHANGELOG.md"
(RELEASE_FIXTURES_DIR="$FXH" release_build_repo exclbare "$TMP/repo-exclbare") || bad "fixture build exclbare"
bare_blob="$("$GIT_REAL" -C "$TMP/repo-exclbare" rev-parse HEAD~1:.release-template.json)"
printf '["v1.0.0"]\n' >"$FXH/tags.json"
printf '{"v1.0.0": "%s"}\n' "$("$GIT_REAL" -C "$TMP/repo-exclbare" rev-parse HEAD~1)" >"$FXH/peeled.json"
printf '[{"tagName":"v1.0.0","name":"v1.0.0"}]\n' >"$FXH/list.json"
while IFS='|' read -r name sec fmt want; do
	[[ "$want" == ok ]] && want="ok|"
	# shellcheck disable=SC2059
	printf -- "# Changelog\n\n## [1.0.0] - 2026-01-01\n\n$sec\n" >"$FXH/cl.md"
	rm -rf "$FXH/bodies" && mkdir -p "$FXH/bodies"
	# shellcheck disable=SC2059
	printf -- "$fmt"'\n\n<!-- release-template-sha: %s -->\n' "$bare_blob" >"$FXH/bodies/v1.0.0.lf.md"
	out="$(a2_run exclbare "$FXH/list.json" "$FXH/bodies" "$FXH/peeled.json" "$FXH/cl.md" "" "$FXH/tags.json")"
	[[ "$(note_of "$out" 1.0.0)" == "$want" ]] &&
		pass "a2-classify bare-### exclusion: $name -> $want" ||
		bad "a2-classify bare-### exclusion: $name expected '$want': $out"
done <<'EOF2'
section only the bare-### subsection is empty after exclusion|### \n\n- Beta.|- Beta.|drifted|body (missing CHANGELOG section)
composed body (bare-### subsection dropped) audits ok|### Added\n\n- Alpha.\n\n### \n\n- Beta.|### Added\n\n- Alpha.|ok|
bare-### subsection leaked into the body|### Added\n\n- Alpha.\n\n### \n\n- Beta.|### Added\n\n- Alpha.\n\n### \n\n- Beta.|drifted|body (carries an excluded section)
EOF2

# V12: clause (d) reads the WHOLE body, like clause (c): a 0-3-space excluded
# heading ends the summary (V14) and a tab-indented one is a summary
# continuation line, but both trim to the heading drop_excluded removes at cut
# time, so both are flagged wherever they sit. whats_new:true, so check (4) is
# silent and the body note alone decides. Rows: name|body-printf-format|expected.
FXW="$TMP/fx-excl-wn"
rm -rf "$FXW" && mkdir -p "$FXW/exclwn"
printf '{"title_format":"bare","compare_line_label":"none","whats_new":true,"excluded_sections":["### Internal"]}\n' >"$FXW/exclwn/.release-template.json"
printf '# Changelog\n\n## [1.0.0] - 2026-01-01\n\n### Added\n\n- Alpha.\n\n### Internal\n\n- Plumbing.\n' >"$FXW/exclwn/CHANGELOG.md"
(RELEASE_FIXTURES_DIR="$FXW" release_build_repo exclwn "$TMP/repo-exclwn") || bad "fixture build exclwn"
wn_blob="$("$GIT_REAL" -C "$TMP/repo-exclwn" rev-parse HEAD~1:.release-template.json)"
printf '["v1.0.0"]\n' >"$FXW/tags.json"
printf '{"v1.0.0": "%s"}\n' "$("$GIT_REAL" -C "$TMP/repo-exclwn" rev-parse HEAD~1)" >"$FXW/peeled.json"
printf '[{"tagName":"v1.0.0","name":"v1.0.0"}]\n' >"$FXW/list.json"
while IFS='|' read -r name fmt want; do
	[[ "$want" == ok ]] && want="ok|"
	rm -rf "$FXW/bodies" && mkdir -p "$FXW/bodies"
	# shellcheck disable=SC2059
	printf -- "$fmt"'\n\n<!-- release-template-sha: %s -->\n' "$wn_blob" >"$FXW/bodies/v1.0.0.lf.md"
	out="$(a2_run exclwn "$FXW/list.json" "$FXW/bodies" "$FXW/peeled.json" "$FXW/exclwn/CHANGELOG.md" "" "$FXW/tags.json")"
	[[ "$(note_of "$out" 1.0.0)" == "$want" ]] &&
		pass "a2-classify summary + excluded heading: $name -> $want" ||
		bad "a2-classify summary + excluded heading: $name expected '$want': $out"
done <<'EOF3'
summary then a clean content block|## What's New\n\nSummary.\n\n### Added\n\n- Alpha.|ok|
summary then a column-one excluded heading|## What's New\n\nSummary.\n### Internal\n\n- Plumbing.\n\n### Added\n\n- Alpha.|drifted|body (carries an excluded section)
summary then a space-indented excluded heading|## What's New\n\nSummary.\n ### Internal\n- Plumbing.\n\n### Added\n\n- Alpha.|drifted|body (carries an excluded section)
summary then a 3-space-indented excluded heading|## What's New\n\nSummary.\n   ### Internal\n\n- Plumbing.|drifted|body (carries an excluded section)
summary then a tab-indented excluded heading|## What's New\n\nSummary.\n\t### Internal\n- Plumbing.\n\n### Added\n\n- Alpha.|drifted|body (carries an excluded section)
EOF3

# V13: the section boundary is bounded like has_version_header: up to 3 leading
# spaces, no tab. A 4-space or tab-indented `## [0.0.1]` is a code-block line of
# the 0.1.0 section, not the next header, so the section stays non-empty (ok);
# a 3-space-indented one is a header and ends the (then empty) section.
# Rows: name|0.1.0-section-printf-format|expected.
while IFS='|' read -r name sec want; do
	[[ "$want" == ok ]] && want="ok|"
	# shellcheck disable=SC2059
	printf -- "# Changelog\n\n## [0.2.0] - 2026-02-01\n\n### Added\n\n- Second thing.\n\n## [0.1.0] - 2026-01-01\n\n$sec\n" >"$TMP/cl-code.md"
	printf -- '- First thing.\n' >"$TMP/b-code.md"
	got="$(note_of "$(u_run "$TMP/b-code.md" "$TMP/cl-code.md")" 0.1.0)"
	[[ "$got" == "$want" ]] &&
		pass "a2-classify section boundary: $name -> $want" ||
		bad "a2-classify section boundary: $name expected '$want', got '$got'"
done <<'EOF4'
4-space code line first|    ## [0.0.1] example header in a code block\n- First thing.|ok|
tab code line first|\t## [0.0.1] example header in a code block\n- First thing.|ok|
3-space header ends an empty section|   ## [0.0.1] - 2025-12-01\n\n- Old thing.|drifted|body (missing CHANGELOG section)
EOF4

# V14: the What's New summary ends at ANY heading line under the shared
# HEADING_INDENT_RE bound (0-3 spaces, no tab) -- the same bound the section
# boundary and clause (c) use. Whole space: indent {0,1,3,4 spaces, tab} x level
# {##,###} x position {directly after the summary, after a blank line}. A 4-space
# or tab-indented line directly after the paragraph is not a heading (Markdown
# reads it as a paragraph continuation), so it stays in the summary and the
# content block is empty; after a blank line every variant is content.
for ind in 0 1 3 4 tab; do
	case "$ind" in tab) pfx=$'\t' ;; *) pfx="$(printf '%*s' "$ind" '')" ;; esac
	for lvl in '##' '###'; do
		for pos in adjacent blank; do
			sep=""
			[[ "$pos" == blank ]] && sep=$'\n'
			want="ok|"
			[[ "$pos" == adjacent && ("$ind" == 4 || "$ind" == tab) ]] && want="drifted|body (empty)"
			printf "## What's New\n\nSummary.\n%s%s%s Added\n- Alpha.\n" "$sep" "$pfx" "$lvl" >"$TMP/b-split.md"
			got="$(note_of "$(u_run "$TMP/b-split.md")" 0.1.0)"
			[[ "$got" == "$want" ]] &&
				pass "a2-classify summary split: indent=$ind $lvl $pos -> $want" ||
				bad "a2-classify summary split: indent=$ind $lvl $pos expected '$want', got '$got'"
		done
	done
done
# An ATX heading has 1-6 hashes: hash count {1..8} x position {directly after the
# summary, after a blank line}. 7+ hashes is paragraph text, so directly after
# the summary it is a continuation line (content empty); after a blank line it
# is an ordinary content paragraph (ok).
for n in 1 2 3 4 5 6 7 8; do
	hashes="$(printf '%*s' "$n" '' | tr ' ' '#')"
	for pos in adjacent blank; do
		sep=""
		[[ "$pos" == blank ]] && sep=$'\n'
		want="ok|"
		[[ "$pos" == adjacent && "$n" -gt 6 ]] && want="drifted|body (empty)"
		printf "## What's New\n\nSummary.\n%s%s Still text\n" "$sep" "$hashes" >"$TMP/b-lvl.md"
		got="$(note_of "$(u_run "$TMP/b-lvl.md")" 0.1.0)"
		[[ "$got" == "$want" ]] &&
			pass "a2-classify summary split: $n hashes $pos -> $want" ||
			bad "a2-classify summary split: $n hashes $pos expected '$want', got '$got'"
	done
done
# The What's New heading itself takes the same bound: 3 leading spaces is still a
# summary heading (summary-only body -> empty content); 4 is a code block, so the
# body is ordinary content.
while IFS='|' read -r fmt want; do
	[[ "$want" == ok ]] && want="ok|"
	# shellcheck disable=SC2059
	printf -- "$fmt" >"$TMP/b-wn-ind.md"
	got="$(note_of "$(u_run "$TMP/b-wn-ind.md")" 0.1.0)"
	[[ "$got" == "$want" ]] &&
		pass "a2-classify indented What's New heading '$fmt' -> $want" ||
		bad "a2-classify indented What's New heading '$fmt' expected '$want', got '$got'"
done <<'EOF5'
   ## What's New\n\nOnly a summary.\n|drifted|body (empty)
    ## What's New\n\nOnly a summary.\n|ok|
EOF5
# Clause (a) ignores compare-shaped lines with no template too: a CHANGELOG
# section holding only a `**Full diff:**` line has nothing to publish.
printf '# Changelog\n\n## [0.2.0] - 2026-02-01\n\n### Added\n\n- Second thing.\n\n## [0.1.0] - 2026-01-01\n\n**Full diff:** https://example.invalid/stale\n' >"$TMP/cl-only-cmp-untpl.md"
[[ "$(note_of "$(u_run "$FIX/untemplated/bodies/v0.1.0.md" "$TMP/cl-only-cmp-untpl.md")" 0.1.0)" == "drifted|body (missing CHANGELOG section)" ]] &&
	pass "a2-classify: a section holding only a compare-shaped line is a missing section" ||
	bad "a2-classify: a compare-only CHANGELOG section was treated as publishable content"

# V9 (prose re-sync side) lives in tests/parity/test_release_skill_contract.py
# (Claude/Codex, region-scoped) and tests/pi/test_orchestration_routes.py (Pi):
# this suite asserts script behaviour only.

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
# content block the valid-body predicate reads.
out="$(a2_run none-label "$FIX/none-label/release-list.json" "$FIX/none-label/bodies" \
	"$FIX/none-label/peeled-commits.json" "$FIX/none-label/CHANGELOG.md")"
[[ "$(jq -r '.rows[] | select(.version == "0.2.0") | .status' <<<"$out")" == "ok" ]] &&
	pass "a2-classify: compare_line_label:none ignores a Full-diff-shaped line inside the What's New paragraph" ||
	bad "a2-classify: compare_line_label:none boundary anchor not parametrized by label: $out"

# V15 (audit side of the summary-semantics invariant): summary shape x label ->
# audit class. The re-sync side of the same rows is pinned in
# tests/parity/test_release_skill_contract.py (Step 3 item 1's summary-discard
# rule has no compare-shaped trigger; the recovery boundary is the audit split),
# so every row audited `ok` is one re-sync preserves, and the one row re-sync
# cannot keep (its own compare line opening the summary) is one audit flags.
# Rows: name|case|body-printf-format (%s = this case's canonical trailer)|expected.
while IFS='|' read -r name c fmt want; do
	[[ "$want" == ok ]] && want="ok|"
	trailer=""
	[[ "$c" == untemplated ]] && trailer="$(printf '\n\n**Full diff:** %s/compare/v0.1.0...v0.2.0' "$WEB")"
	rm -rf "$TMP/v15" && mkdir -p "$TMP/v15" && cp "$FIX/$c/bodies/v0.1.0.md" "$TMP/v15/"
	# shellcheck disable=SC2059
	printf -- "$fmt"'\n' "$trailer" >"$TMP/v15/v0.2.0.md"
	got="$(note_of "$(a2_run "$c" "$FIX/$c/release-list.json" "$TMP/v15" \
		"$FIX/$c/peeled-commits.json" "$FIX/$c/CHANGELOG.md")" 0.2.0)"
	[[ "$got" == "$want" ]] &&
		pass "a2-classify summary semantics: $name -> $want" ||
		bad "a2-classify summary semantics: $name expected '$want', got '$got'"
done <<'EOF6'
normal summary, label none|none-label|## What's New\n\nSummary.\n\n### Added\n\n- Second thing.%s|ok|
compare-shaped line first, label none|none-label|## What's New\n**Full diff:** not published.\nMore summary.\n\n### Added\n\n- Second thing.%s|ok|
compare-shaped line only, label none|none-label|## What's New\n\n**Full diff:** not published.\n\n### Added\n\n- Second thing.%s|ok|
leading blank lines, label none|none-label|## What's New\n\n\nSummary.\n\n### Added\n\n- Second thing.%s|ok|
other-label compare-shaped line first, label Full diff|untemplated|## What's New\n**Full changelog:** see below.\n\n### Added\n\n- Second thing.%s|ok|
own-label compare line first, label Full diff|untemplated|## What's New\n**Full diff:** stale.\n\n### Added\n\n- Second thing.%s|drifted|exact cached-base compare path
EOF6

# Regression (adversarial-review finding): `awk -v anchor="$compare_anchor"`
# runs awk's own C-string escape processing on the VALUE before it becomes a
# dynamic regexp -- a single un-doubled backslash-asterisk (`\*`) is consumed
# down to nothing, silently widening the compare-line anchor to match ANY
# line starting with the bare label text, no markdown bold required. Under
# the default "Full diff" label, a What's New paragraph whose prose merely
# MENTIONS "Full diff:" (no `**`) must NOT be mistaken for the compare-line
# boundary -- only the literal bold `**Full diff:**` trailer may terminate
# the scan.
mkdir -p "$TMP/anchor-bodies" && cp "$FIX/untemplated/bodies/v0.1.0.md" "$TMP/anchor-bodies/"
printf "## What%ss New\n\nSee the Full diff: link below for the full context.\n\n### Added\n\n- Second thing.\n\n**Full diff:** %s/compare/v0.1.0...v0.2.0\n" \
	"'" "$WEB" >"$TMP/anchor-bodies/v0.2.0.md"
out="$(a2_run untemplated "$FIX/untemplated/release-list.json" "$TMP/anchor-bodies" \
	"$FIX/untemplated/peeled-commits.json" "$FIX/untemplated/CHANGELOG.md")"
[[ "$(jq -r '.rows[] | select(.version == "0.2.0") | .status' <<<"$out")" == "ok" ]] &&
	pass "a2-classify: a bare (non-bold) 'Full diff:' mention inside the summary paragraph is not mistaken for the compare-line boundary" ||
	bad "a2-classify: awk -v backslash-escape consumption widened the compare-line anchor: $out"

# --- resync-gate / resync-summary: the re-sync decisions as script output ----
# Step A4's offer gate, Step 3 item 3's hard stop (resync-gate) and Step 3
# item 1's summary recovery/discard plus Step 3 item 3's preserve decision
# (resync-summary) are computed by the same functions a2-classify runs
# (section_publishable, whats_new_split, body_invalid_reason). Each table below
# is paired with a differential against a2-classify on the same inputs.
gate_run() { # repo-case version changelog
	RELEASE_JQ="$JQ_REAL" RELEASE_GIT="$GIT_REAL" "$LIB/resolve-template-marker.sh" --site resync-gate \
		--repo "$TMP/repo-$1" --head-sha "$(repo_head "$1")" --changelog "$3" --version "$2" 2>/dev/null
}
rsum_run() { # repo-case tag body-file peeled changelog [headingless-summary]
	local extra=()
	[[ -n "${6-}" ]] && extra=(--headingless-summary "$6")
	RELEASE_JQ="$JQ_REAL" RELEASE_GIT="$GIT_REAL" "$LIB/resolve-template-marker.sh" --site resync-summary \
		--repo "$TMP/repo-$1" --tag "$2" --body-file "$3" --peeled "$4" --head-sha "$(repo_head "$1")" \
		--changelog "$5" ${extra[@]+"${extra[@]}"} 2>/dev/null
}
# rsum_to_a2_body_note <resync-summary-json> — the body note a2-classify must
# report for the same body: a2 reads clauses (c)/(d) over the WHOLE body
# (summary + content block), resync-summary over the content block and the
# summary separately (invalid_reason / discard), in the same clause order.
rsum_to_a2_body_note() {
	jq -r '.rows | . as $r |
		if ($r.invalid_reason == "body (missing CHANGELOG section)" or $r.invalid_reason == "body (empty)") then $r.invalid_reason
		elif ($r.invalid_reason == "body (embeds a CHANGELOG header)" or $r.discard == "version-header") then "body (embeds a CHANGELOG header)"
		elif ($r.invalid_reason == "body (carries an excluded section)" or $r.discard == "excluded-heading") then "body (carries an excluded section)"
		else "-" end' <<<"$1"
}

# A second templated fixture with a set compare label, for the recovery-label
# half of resync-summary (FXX/excl above is label none).
FXL="$TMP/fx-fcl"
rm -rf "$FXL" && mkdir -p "$FXL/fcl"
printf '{"compare_line_label":"Full changelog","excluded_sections":["### Internal"]}\n' >"$FXL/fcl/.release-template.json"
cp "$FXX/excl/CHANGELOG.md" "$FXL/fcl/CHANGELOG.md"
(RELEASE_FIXTURES_DIR="$FXL" release_build_repo fcl "$TMP/repo-fcl") || bad "fixture build fcl"
fcl_blob="$("$GIT_REAL" -C "$TMP/repo-fcl" rev-parse HEAD~1:.release-template.json)"
printf '{"v1.0.0": "%s"}\n' "$("$GIT_REAL" -C "$TMP/repo-fcl" rev-parse HEAD~1)" >"$FXL/peeled.json"
ex_marker="<!-- release-template-sha: $excl_blob -->"
fcl_marker="<!-- release-template-sha: $fcl_blob -->"

# G1: resync-gate table. Rows: name|repo-case|version|changelog-printf|stops.
# untemplated = no template (sentinel); excl = current template excludes
# `### Internal`. Every row is cross-checked against a2-classify's clause (a)
# on the same CHANGELOG (untemplated: v0.1.0 via u_run; excl: a marker-bound
# body whose classification source is the same committed template).
while IFS='|' read -r name c v fmt want; do
	# shellcheck disable=SC2059
	printf -- "$fmt" >"$TMP/g-cl.md"
	got="$(gate_run "$c" "$v" "$TMP/g-cl.md" | jq -r '.rows.stops')"
	[[ "$got" == "$want" ]] &&
		pass "resync-gate: $name -> stops=$want" ||
		bad "resync-gate: $name expected stops=$want, got '$got'"
	if [[ "$c" == untemplated ]]; then
		a2out="$(u_run "$FIX/untemplated/bodies/v0.1.0.md" "$TMP/g-cl.md")"
	else
		rm -rf "$TMP/g-bodies" && mkdir -p "$TMP/g-bodies"
		printf '### Added\n\n- Alpha.\n\n%s\n' "$ex_marker" >"$TMP/g-bodies/v1.0.0.lf.md"
		a2out="$(a2_run excl "$FXX/list.json" "$TMP/g-bodies" "$FXX/peeled.json" "$TMP/g-cl.md" "" "$FXX/tags.json")"
	fi
	a2stop=false
	[[ "$(note_of "$a2out" "$v")" == *"body (missing CHANGELOG section)"* ]] && a2stop=true
	[[ "$a2stop" == "$got" ]] &&
		pass "resync-gate == a2-classify clause (a): $name" ||
		bad "resync-gate disagrees with a2-classify clause (a): $name (gate=$got a2=$a2stop)"
done <<'EOG'
empty section|untemplated|0.1.0|# Changelog\n\n## [0.2.0] - 2026-02-01\n\n- Second.\n\n## [0.1.0] - 2026-01-01\n\n|true
only compare lines|untemplated|0.1.0|# Changelog\n\n## [0.1.0] - 2026-01-01\n\n**Full diff:** https://x.invalid/a\n**Full changelog:** https://x.invalid/b\n|true
missing section|untemplated|0.1.0|# Changelog\n\n## [0.2.0] - 2026-02-01\n\n- Second.\n|true
prose without subsections|untemplated|0.1.0|# Changelog\n\n## [0.1.0] - 2026-01-01\n\nJust prose under the header.\n|false
all content excluded|excl|1.0.0|# Changelog\n\n## [1.0.0] - 2026-01-01\n\n### Internal\n\n- Plumbing.\n|true
compare line plus excluded only|excl|1.0.0|# Changelog\n\n## [1.0.0] - 2026-01-01\n\n**Full diff:** https://x.invalid/a\n\n### Internal\n\n- Plumbing.\n|true
indented excluded heading (trimmed)|excl|1.0.0|# Changelog\n\n## [1.0.0] - 2026-01-01\n\n  ### Internal  \n\n- Plumbing.\n|true
subsection survives exclusion|excl|1.0.0|# Changelog\n\n## [1.0.0] - 2026-01-01\n\n### Added\n\n- Alpha.\n\n### Internal\n\n- Plumbing.\n|false
prose plus all subsections excluded|excl|1.0.0|# Changelog\n\n## [1.0.0] - 2026-01-01\n\nProse.\n\n### Internal\n\n- Plumbing.\n|false
EOG
# The stop reason names clause (a)'s punch-list note verbatim.
printf '# Changelog\n\n## [1.0.0] - 2026-01-01\n\n### Internal\n\n- Plumbing.\n' >"$TMP/g-cl.md"
[[ "$(gate_run excl 1.0.0 "$TMP/g-cl.md" | jq -r '.rows.reason')" == "body (missing CHANGELOG section)" ]] &&
	pass "resync-gate: stop reason is clause (a)'s note" || bad "resync-gate: stop reason"
# A present-but-invalid current template stops too (Step 1b would hard-stop the
# re-sync first), and resync-summary refuses it outright.
cp -R "$TMP/repo-excl" "$TMP/repo-exdirty"
printf '{"bogus": 1}\n' >"$TMP/repo-exdirty/.release-template.json"
gout="$(gate_run exdirty 1.0.0 "$FXX/excl/CHANGELOG.md")"
[[ "$(jq -r '.rows.stops' <<<"$gout")" == true && "$(jq -r '.rows.reason' <<<"$gout")" == "template ("* ]] &&
	pass "resync-gate: an invalid current template stops the re-sync" ||
	bad "resync-gate: invalid current template not a stop: $gout"
printf '### Added\n\n- Alpha.\n' >"$TMP/rs-plain.md"
rsum_run exdirty v1.0.0 "$TMP/rs-plain.md" "$FXX/peeled.json" "$FXX/excl/CHANGELOG.md" >"$TMP/rs.out"
expect_code "resync-summary refuses an invalid current template" 1 $?
[[ "$(jq -r '.failed_gate' "$TMP/rs.out")" == "current-template-invalid" ]] &&
	pass "resync-summary names the current-template gate" || bad "resync-summary current-template gate name"
# Argument contract: a non-strict --version is an environment failure.
gate_run untemplated 1.0 "$FIX/untemplated/CHANGELOG.md" >/dev/null
expect_code "resync-gate rejects a non-strict --version" 2 $?

# R1: resync-summary table. Rows: name|repo-case|body-printf (%s = the case's
# marker; untemplated bodies ignore it)|expected
# "summary_present,discard,content_block_valid,invalid_reason,preserve".
while IFS='|' read -r name c fmt want; do
	case "$c" in
	excl) mk="$ex_marker" pl="$FXX/peeled.json" tg=v1.0.0 cl="$FXX/excl/CHANGELOG.md" ;;
	fcl) mk="$fcl_marker" pl="$FXL/peeled.json" tg=v1.0.0 cl="$FXX/excl/CHANGELOG.md" ;;
	*) mk="" pl="$FIX/untemplated/peeled-commits.json" tg=v0.1.0 cl="$FIX/untemplated/CHANGELOG.md" ;;
	esac
	# shellcheck disable=SC2059
	printf -- "$fmt" "$mk" >"$TMP/rs-body.md"
	got="$(rsum_run "$c" "$tg" "$TMP/rs-body.md" "$pl" "$cl" |
		jq -r '.rows | [.summary_present, (.discard // "-"), .content_block_valid, (.invalid_reason // "-"), .preserve] | map(tostring) | join(",")')"
	[[ "$got" == "$want" ]] &&
		pass "resync-summary: $name -> $want" ||
		bad "resync-summary: $name expected '$want', got '$got'"
done <<'EOR'
h1 boundary|untemplated|## What's New\nSummary.\n# Added\n- First thing.\n|true,-,true,-,true
h2 boundary|untemplated|## What's New\nSummary.\n## Added\n- First thing.\n|true,-,true,-,true
h3 boundary|untemplated|## What's New\nSummary.\n### Added\n- First thing.\n|true,-,true,-,true
h4 boundary|untemplated|## What's New\nSummary.\n#### Added\n- First thing.\n|true,-,true,-,true
h5 boundary|untemplated|## What's New\nSummary.\n##### Added\n- First thing.\n|true,-,true,-,true
h6 boundary|untemplated|## What's New\nSummary.\n###### Added\n- First thing.\n|true,-,true,-,true
7 hashes continue the summary|untemplated|## What's New\nSummary.\n####### Added\n- First thing.\n|true,-,false,body (empty),false
4-space heading continues the summary|untemplated|## What's New\nSummary.\n    ### Added\n- First thing.\n|true,-,false,body (empty),false
tab heading continues the summary|untemplated|## What's New\nSummary.\n\t### Added\n- First thing.\n|true,-,false,body (empty),false
blank-line boundary over flat content|untemplated|## What's New\n\nSummary.\n\n- First thing.\n|true,-,true,-,true
no summary, compact block|untemplated|### Added\n\n- First.\n|false,-,true,-,true
own-label compare line opens the summary (empty summary is audit drift)|untemplated|## What's New\n**Full diff:** stale.\n\n### Added\n- First thing.\n|true,audit-drift,false,body (carries a compare-shaped line),false
stale own-label trailer is dropped|untemplated|### Added\n\n- First thing.\n\n**Full diff:** https://stale.invalid/x\n|false,-,true,-,true
other-label trailer stays content|untemplated|### Added\n\n- First thing.\n\n**Full changelog:** https://stale.invalid/x\n|false,-,false,body (carries a compare-shaped line),false
version header in the content block|untemplated|## What's New\nSummary.\n## [0.0.9] - 2025-01-01\n- First thing.\n|true,-,false,body (embeds a CHANGELOG header),false
summary-only body|untemplated|## What's New\nOnly a summary.\n|true,-,false,body (empty),false
3-space heading, typographic apostrophe|untemplated|   ## What’s New\nSummary.\n\n- First thing.\n|true,-,true,-,true
label none: compare-shaped line is summary prose|excl|## What's New\n**Full diff:** not published.\nMore.\n\n### Added\n\n- Alpha.\n\n%s\n|true,-,true,-,true
excluded heading in the summary (4-space)|excl|## What's New\nSummary.\n    ### Internal\n\n### Added\n\n- Alpha.\n\n%s\n|true,excluded-heading,true,-,true
excluded heading in the summary (tab)|excl|## What's New\nSummary.\n\t### Internal\n\n### Added\n\n- Alpha.\n\n%s\n|true,excluded-heading,true,-,true
excluded heading in the content block|excl|### Added\n\n- Alpha.\n\n### Internal\n\n- Plumbing.\n\n%s\n|false,-,false,body (carries an excluded section),false
label none: a compare-shaped line is never stripped|excl|### Added\n\n- Alpha.\n\n**Full diff:** https://x.invalid/a\n\n%s\n|false,-,false,body (carries a compare-shaped line),false
label set: own trailer dropped|fcl|### Added\n\n- Alpha.\n\n**Full changelog:** https://x.invalid/a\n\n%s\n|false,-,true,-,true
label set: compare boundary ends the summary|fcl|## What's New\nSummary.\n**Full changelog:** https://x.invalid/a\n\n%s\n|true,-,false,body (empty),false
sentinel recovery, Full changelog current: its compare line in the summary is audit drift|fcl|## What's New\nSummary.\n**Full changelog:** https://x.invalid/a\n|true,audit-drift,false,body (empty),false
label set: Full diff line is content|fcl|### Added\n\n- Alpha.\n\n**Full diff:** https://x.invalid/a\n\n%s\n|false,-,false,body (carries a compare-shaped line),false
EOR
# The bound Full changelog recovery template really selects its label: the
# summary ends at its compare line (codex round-7 test finding: the row above
# once ran under the sentinel because it carried no marker).
printf "## What's New\nSummary.\n**Full changelog:** https://x.invalid/a\n\n%s\n" "$fcl_marker" >"$TMP/rs-body.md"
[[ "$(rsum_run fcl v1.0.0 "$TMP/rs-body.md" "$FXL/peeled.json" "$FXX/excl/CHANGELOG.md" | jq -r '[.rows.recovery_template, .rows.recovery_label, .rows.summary_text] | join("|")')" == "marker|Full changelog|Summary." ]] &&
	pass "resync-summary: a bound Full changelog template ends the summary at its own compare line" ||
	bad "resync-summary: Full changelog recovery boundary"
# Section missing -> clause (a) -> never preserved.
printf '# Changelog\n\n## [0.2.0] - 2026-02-01\n\n- Second.\n' >"$TMP/rs-nosec.md"
[[ "$(rsum_run untemplated v0.1.0 "$TMP/rs-plain.md" "$FIX/untemplated/peeled-commits.json" "$TMP/rs-nosec.md" | jq -r '.rows.invalid_reason + "," + (.rows.preserve|tostring)')" == "body (missing CHANGELOG section),false" ]] &&
	pass "resync-summary: a missing CHANGELOG section is never preserved" || bad "resync-summary: missing section preserved"
# summary_text / discard_line / content_block_text carry the exact split.
printf "## What's New\nFirst line.\nSecond line.\n    ### Internal\n\n### Added\n\n- Alpha.\n\n%s\n" "$ex_marker" >"$TMP/rs-body.md"
rs="$(rsum_run excl v1.0.0 "$TMP/rs-body.md" "$FXX/peeled.json" "$FXX/excl/CHANGELOG.md")"
split_texts="$(jq -r '[.rows.summary_text, .rows.discard_line, .rows.content_block_text] | join("|")' <<<"$rs")"
[[ "$split_texts" == $'First line.\nSecond line.\n    ### Internal|    ### Internal|### Added\n\n- Alpha.' ]] &&
	pass "resync-summary: summary_text, discard_line and content_block_text are the exact split" ||
	bad "resync-summary: split texts wrong: $rs"
# Marker handling: a bound marker is stripped (recovery template = its blob,
# label none); a CRLF copy decides identically; an unbound strict marker is
# parsed under the sentinel, named in rows.recovery_note (failed_gate stays
# null on exit 0) and peeled off the content block (logic round-7 finding).
printf '### Added\r\n\r\n- Alpha.\r\n\r\n%s\r\n' "$ex_marker" >"$TMP/rs-crlf.md"
printf '### Added\n\n- Alpha.\n\n%s\n' "$ex_marker" >"$TMP/rs-lf.md"
lf="$(rsum_run excl v1.0.0 "$TMP/rs-lf.md" "$FXX/peeled.json" "$FXX/excl/CHANGELOG.md" | jq -c '.rows')"
crlf="$(rsum_run excl v1.0.0 "$TMP/rs-crlf.md" "$FXX/peeled.json" "$FXX/excl/CHANGELOG.md" | jq -c '.rows')"
[[ "$(jq -r '[.recovery_template, .recovery_label, .marker_stripped, .content_block_text] | map(tostring) | join("|")' <<<"$lf")" == $'marker|none|true|### Added\n\n- Alpha.' ]] &&
	pass "resync-summary: a bound marker is stripped and selects its template's label" ||
	bad "resync-summary: bound marker handling: $lf"
[[ "$lf" == "$crlf" ]] && pass "resync-summary: CRLF body == LF body" || bad "resync-summary: CRLF differs: $crlf vs $lf"
printf '### Added\n\n- Alpha.\n\n<!-- release-template-sha: %s -->\n' "$(printf 'a%.0s' {1..40})" >"$TMP/rs-unbound.md"
ub="$(rsum_run excl v1.0.0 "$TMP/rs-unbound.md" "$FXX/peeled.json" "$FXX/excl/CHANGELOG.md")"
[[ "$(jq -r '[.rows.recovery_template, .rows.marker_stripped, .failed_gate, (.rows.recovery_note != null), (.rows.peeled_marker_line | test("^<!-- release-template-sha: a{40} -->$")), .rows.content_block_text, .rows.preserve] | map(tostring) | join("|")' <<<"$ub")" == $'sentinel|false|null|true|true|### Added\n\n- Alpha.|true' ]] &&
	pass "resync-summary: an unbound marker is peeled off and reported in rows.recovery_note" ||
	bad "resync-summary: unbound marker handling: $ub"
# The peel happens before the stale-trailer drop, so a valid compact body with
# a stale own-label trailer and an unbound marker is preserved.
printf '### Added\n\n- Alpha.\n\n**Full diff:** https://stale.invalid/x\n\n<!-- release-template-sha: %s -->\n' "$(printf 'a%.0s' {1..40})" >"$TMP/rs-unbound2.md"
[[ "$(rsum_run excl v1.0.0 "$TMP/rs-unbound2.md" "$FXX/peeled.json" "$FXX/excl/CHANGELOG.md" | jq -r '[.rows.content_block_text, .rows.preserve] | map(tostring) | join("|")')" == $'### Added\n\n- Alpha.|true' ]] &&
	pass "resync-summary: an unbound marker does not defeat the stale-trailer drop" ||
	bad "resync-summary: unbound marker blocked the trailer drop"
# Headingless summary: the proved prefix is the discard rule's input and leaves
# the content block; a version header in it discards it. A prefix that does not
# match the body is refused.
printf 'Prefix line.\n## [0.0.9] - 2025-01-01\n\n### Added\n\n- First thing.\n' >"$TMP/rs-hl.md"
printf 'Prefix line.\n## [0.0.9] - 2025-01-01\n' >"$TMP/rs-hl-prefix.txt"
hl="$(rsum_run untemplated v0.1.0 "$TMP/rs-hl.md" "$FIX/untemplated/peeled-commits.json" "$FIX/untemplated/CHANGELOG.md" "$TMP/rs-hl-prefix.txt")"
[[ "$(jq -r '[.rows.summary_kind, .rows.discard, .rows.discard_line, .rows.content_block_valid] | map(tostring) | join("|")' <<<"$hl")" == "headingless|version-header|## [0.0.9] - 2025-01-01|true" ]] &&
	pass "resync-summary: a headingless summary with a version header is discarded" ||
	bad "resync-summary: headingless discard: $hl"
printf 'Not the prefix.\n' >"$TMP/rs-hl-bad.txt"
rsum_run untemplated v0.1.0 "$TMP/rs-hl.md" "$FIX/untemplated/peeled-commits.json" "$FIX/untemplated/CHANGELOG.md" "$TMP/rs-hl-bad.txt" >/dev/null
expect_code "resync-summary refuses a headingless summary that is not the body's prefix" 1 $?

# D1 (the agreement invariant): resync-summary's split == a2-classify's split.
# On every corpus body a2-classify's full status/note is derived from
# resync-summary's output alone: the body note via rsum_to_a2_body_note, check
# (3) from content_block_text (with the exact canonical trailer appended -- or,
# under label none, no trailer -- a2's compare check fails exactly when a
# compare-shaped line is left in resync-summary's content block), and check (4)
# from summary_present (excl's template sets whats_new:false; untemplated has
# no presence check). A split, boundary label or marker strip that drifted
# between the two sites breaks at least one row (see the mutation note below).
expected_a2() { # resync-summary-json whats-new-false(0|1)
	local parts=() bn want j
	bn="$(rsum_to_a2_body_note "$1")"
	[[ "$bn" == "-" ]] || parts+=("$bn")
	[[ "$(jq -r '.rows.content_block_text | split("\n") | any(test("^[*][*]Full (diff|changelog):[*][*]"))' <<<"$1")" == true ]] &&
		parts+=("exact cached-base compare path")
	[[ "$2" == 1 && "$(jq -r '.rows.summary_present' <<<"$1")" == true ]] && parts+=("What's New presence-vs-whats_new")
	want="ok|"
	if ((${#parts[@]})); then
		want="drifted|"
		for j in "${!parts[@]}"; do
			((j)) && want+=", "
			want+="${parts[$j]}"
		done
	fi
	printf '%s' "$want"
}
corpus=(
	'### Added\n\n- Item.'
	"## What's New\nSummary.\n### Added\n- Item."
	"## What's New\n\nSummary.\n\n- Item."
	"## What's New\nSummary.\n    ### Added\n- Item."
	"## What's New\nSummary.\n\t### Internal\n\n### Added\n\n- Item."
	"## What's New\nSummary.\n    ### Internal\n\n### Added\n\n- Item."
	"## What's New\nSummary.\n####### Seven\n\n- Item."
	"## What's New\n**Full diff:** not published.\nMore.\n\n### Added\n\n- Item."
	"## What's New\n**Full changelog:** see below.\n\n### Added\n\n- Item."
	"## What's New\nSummary.\n**Full diff:** stale.\n\n### Added\n- Item."
	"## What's New\n\n\nSummary.\n# H1\n- Item."
	"## What's New\nSummary.\n###### H6\n- Item."
	'### Added\n\n- Item.\n\n### Internal\n\n- Plumbing.'
	'### Added\n\n- Item.\n\n## [0.0.9] - 2025-01-01'
	"## What's New\nOnly summary."
	"   ## What’s New\nSummary.\n\n- Item."
	"    ## What's New\nSummary.\n\n- Item."
	"## What's New\nSummary.\n## [0.0.9] - 2025-01-01\n- Item."
	'- Item.\n**Full changelog:** mid\n- More.'
	"## What's New\nSummary.\n   ### Internal\n- Item."
	"\n\n## What's New\nSummary.\n\n### Added\n- Item."
)
for i in "${!corpus[@]}"; do
	core="${corpus[$i]}"
	# excl: marker-bound v1.0.0, label none, whats_new false, `### Internal` excluded.
	rm -rf "$TMP/d-ex" && mkdir -p "$TMP/d-ex"
	# shellcheck disable=SC2059
	printf -- "$core"'\n\n%s\n' "$ex_marker" >"$TMP/d-ex/v1.0.0.lf.md"
	a2="$(note_of "$(a2_run excl "$FXX/list.json" "$TMP/d-ex" "$FXX/peeled.json" "$FXX/excl/CHANGELOG.md" "" "$FXX/tags.json")" 1.0.0)"
	want="$(expected_a2 "$(rsum_run excl v1.0.0 "$TMP/d-ex/v1.0.0.lf.md" "$FXX/peeled.json" "$FXX/excl/CHANGELOG.md")" 1)"
	[[ "$a2" == "$want" ]] &&
		pass "split agreement (excl, label none) corpus #$i: $want" ||
		bad "split agreement (excl, label none) corpus #$i: a2 '$a2' != resync-derived '$want'"
	# untemplated: v0.2.0 with its exact canonical trailer, sentinel label Full diff.
	rm -rf "$TMP/d-un" && mkdir -p "$TMP/d-un" && cp "$FIX/untemplated/bodies/v0.1.0.md" "$TMP/d-un/"
	# shellcheck disable=SC2059
	printf -- "$core"'\n\n**Full diff:** %s/compare/v0.1.0...v0.2.0\n' "$WEB" >"$TMP/d-un/v0.2.0.md"
	a2="$(note_of "$(a2_run untemplated "$FIX/untemplated/release-list.json" "$TMP/d-un" \
		"$FIX/untemplated/peeled-commits.json" "$FIX/untemplated/CHANGELOG.md")" 0.2.0)"
	want="$(expected_a2 "$(rsum_run untemplated v0.2.0 "$TMP/d-un/v0.2.0.md" "$FIX/untemplated/peeled-commits.json" "$FIX/untemplated/CHANGELOG.md")" 0)"
	[[ "$a2" == "$want" ]] &&
		pass "split agreement (untemplated, label Full diff) corpus #$i: $want" ||
		bad "split agreement (untemplated, label Full diff) corpus #$i: a2 '$a2' != resync-derived '$want'"
done
# Mutation note: replacing resync-summary's whats_new_split label argument with
# a constant, or its body_stream mode with `keep` for a bound marker, fails rows
# of this differential (verified when it was written); a2-classify alone
# cannot fail it because both sides call the same functions.

# Headingless not-a-summary rule (arch round-7 finding: it was prose-only). A
# proved prefix of only compare-shaped lines, or carrying the recovery label's
# compare line, is not a summary: it stays in the content block, so the block
# carries a compare-shaped line and is regenerated.
printf '**Full diff:** https://x/compare/a...b\n\n### Added\n\n- First thing.\n' >"$TMP/rs-hlc.md"
printf '**Full diff:** https://x/compare/a...b\n' >"$TMP/rs-hlc-prefix.txt"
hlc="$(rsum_run untemplated v0.1.0 "$TMP/rs-hlc.md" "$FIX/untemplated/peeled-commits.json" "$FIX/untemplated/CHANGELOG.md" "$TMP/rs-hlc-prefix.txt")"
[[ "$(jq -r '[.rows.summary_present, .rows.invalid_reason, .rows.preserve] | map(tostring) | join("|")' <<<"$hlc")" == "false|body (carries a compare-shaped line)|false" ]] &&
	pass "resync-summary: a compare-shaped-only headingless prefix is not a summary" ||
	bad "resync-summary: compare-only headingless prefix accepted: $hlc"
printf 'Intro.\n**Full diff:** see below\n\n### Added\n\n- First thing.\n' >"$TMP/rs-hla.md"
printf 'Intro.\n**Full diff:** see below\n' >"$TMP/rs-hla-prefix.txt"
[[ "$(rsum_run untemplated v0.1.0 "$TMP/rs-hla.md" "$FIX/untemplated/peeled-commits.json" "$FIX/untemplated/CHANGELOG.md" "$TMP/rs-hla-prefix.txt" | jq -r '.rows.summary_present')" == false ]] &&
	pass "resync-summary: a headingless prefix carrying the recovery label's compare line is not a summary" ||
	bad "resync-summary: headingless prefix with the recovery compare line accepted"

# Byte safety (codex/logic round-7 findings): a NUL or an invalid UTF-8 byte
# anywhere in the body fails closed -- nothing reused, no text emitted, the
# block regenerated -- and the output is strict JSON.
for bytes_case in nul ff c080; do
	case "$bytes_case" in
	nul) printf '### Added\n\n- before\000after\n' >"$TMP/rs-bytes.md" ;;
	ff) printf "## What's New\nSum\377mary.\n\n### Added\n\n- First.\n" >"$TMP/rs-bytes.md" ;;
	c080) printf '### Added\n\n- \300\200 overlong.\n' >"$TMP/rs-bytes.md" ;;
	esac
	rsum_run untemplated v0.1.0 "$TMP/rs-bytes.md" "$FIX/untemplated/peeled-commits.json" "$FIX/untemplated/CHANGELOG.md" >"$TMP/rs-bytes.out"
	if python3 -c 'import json,sys; r=json.load(open(sys.argv[1],encoding="utf-8",errors="strict"))["rows"]; sys.exit(0 if (r["content_block_text"] is None and r["summary_text"] is None and r["preserve"] is False and r["invalid_reason"]=="body (not valid UTF-8 text)" and (r["discard"]=="invalid-bytes")==r["summary_present"]) else 1)' "$TMP/rs-bytes.out"; then
		pass "resync-summary: byte gate fails closed on $bytes_case"
	else
		bad "resync-summary: byte gate on $bytes_case: $(cat -v "$TMP/rs-bytes.out")"
	fi
done
# Valid multibyte UTF-8 and a mid-line CR pass through byte-exactly; a trailing
# CR per line is removed (the documented LF-normalised contract, codex finding
# on CRLF): the preserved block is what Step 4 shows and Step 6 publishes.
printf '### Added\r\n\r\n- Caf\303\251 \342\200\224 a\rb.\r\n' >"$TMP/rs-utf.md"
[[ "$(rsum_run untemplated v0.1.0 "$TMP/rs-utf.md" "$FIX/untemplated/peeled-commits.json" "$FIX/untemplated/CHANGELOG.md" | jq -j '.rows.content_block_text' | od -An -c | tr -s ' \n' ' ')" == "$(printf '### Added\n\n- Caf\303\251 \342\200\224 a\rb.' | od -An -c | tr -s ' \n' ' ')" ]] &&
	pass "resync-summary: content_block_text is LF-normalised and otherwise byte-exact" ||
	bad "resync-summary: content_block_text bytes changed"
# Serialisation is linear (security/codex finding: the shell escaper went
# quadratic on one control byte): a ~64 KiB body with a form feed and an ESC.
{
	printf '### Added\n\n'
	for _ in $(seq 1 1100); do printf -- '- %s\n' "$(printf 'x%.0s' {1..56})"; done
	printf -- '- form\014feed and esc\033.\n'
} >"$TMP/rs-big.md"
big_start=$SECONDS
big="$(rsum_run untemplated v0.1.0 "$TMP/rs-big.md" "$FIX/untemplated/peeled-commits.json" "$FIX/untemplated/CHANGELOG.md")"
big_secs=$((SECONDS - big_start))
[[ "$big_secs" -le 5 && "$(jq -r '.rows.content_block_text | test("form\ffeed and esc\u001b")' <<<"$big")" == true ]] &&
	pass "resync-summary: a 64 KiB body with control bytes serialises in ${big_secs}s" ||
	bad "resync-summary: large control-byte body took ${big_secs}s or lost bytes"

# resync-gate's no-decision state: an environment failure exits 2 with rows
# null, which SKILL.md's callers must treat as a stop (codex round-7 finding:
# A4 offered a repair on it).
touch "$TMP/not-a-dir"
TMPDIR="$TMP/not-a-dir" RELEASE_JQ="$JQ_REAL" RELEASE_GIT="$GIT_REAL" "$LIB/resolve-template-marker.sh" --site resync-gate \
	--repo "$TMP/repo-untemplated" --head-sha "$(repo_head untemplated)" --changelog "$FIX/untemplated/CHANGELOG.md" --version 0.1.0 >"$TMP/gate-nd.out" 2>/dev/null
expect_code "resync-gate with an unusable TMPDIR is an environment failure" 2 $?
[[ "$(jq -r '[.rows, .failed_gate] | map(tostring) | join("|")' "$TMP/gate-nd.out")" == "null|tmpdir" ]] &&
	pass "resync-gate: no decision means rows null" || bad "resync-gate no-decision shape: $(cat "$TMP/gate-nd.out")"

# M1 -- THE RE-SYNC ROUND TRIP (Guardrail 8 whole-space test). Invariant: any
# body a re-sync composes from resync-summary's rows -- the summary under
# `## What's New` when reusable (present, discard null, current whats_new not
# false), rows.content_block_text when preserve is true else the block
# regenerated from the CHANGELOG section under the current template, a blank
# line plus `**<label>:** <web>/compare/vPREV...vNEW` when the current label is
# not none, a blank line plus the current marker when templated -- is
# classified `ok` by a2-classify under that same current template.
# State space: recovery template x current template over
# {none, Full diff, Full changelog, no-template} (16 pairs, recovery != current
# in 12) x every D1 corpus body, plus headingless prefixes (with
# --headingless-summary) and raw bodies ending in an unbound marker. The
# summary kind (headed/headingless/none), marker state (bound/none/unbound)
# and body shape vary across the corpus. One repo per pair: commit 1 carries
# the recovery template (the tags' peeled commit, so its marker binds through
# the origin anchor), HEAD carries the current one. Pairs run in parallel.
m1_tpl() { # key -> template JSON ("" = no template)
	case "$1" in
	none) printf '{"compare_line_label":"none","excluded_sections":["### Internal"]}\n' ;;
	fd) printf '{"compare_line_label":"Full diff","excluded_sections":["### Internal"]}\n' ;;
	fc) printf '{"compare_line_label":"Full changelog","excluded_sections":["### Internal"]}\n' ;;
	esac
}
m1_label() { case "$1" in none) echo none ;; fc) echo "Full changelog" ;; *) echo "Full diff" ;; esac }
M1_SECTION=$'### Added\n\n- Item.\n\n### Internal\n\n- Plumbing.'
m1_hl=(
	'Prefix para.'
	'**Full diff:** https://x/compare/a...b'
	'Line one.\n\nLine two.'
	'Intro.\n**Full changelog:** see below'
	'Intro.\n**Full diff:** see below'
	'Intro.\n### Heading'
)
m1_raw=(
	'### Added\n\n- Item.\n\n**Full diff:** https://stale.invalid/x\n\n<!-- release-template-sha: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa -->'
	"## What's New\nSummary.\n\n### Added\n\n- Item.\n\n<!-- release-template-sha: bad -->"
	'### Added\n\n- Item.\n<!-- release-template-sha: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa -->\n\n- More.'
)
m1_pair() { # recovery current
	local r="$1" c="$2" d="$TMP/m1-$1-$2" n i k v prev tag rl cl rblob="" cblob="" old rs rc
	local total=$((${#corpus[@]} + ${#m1_hl[@]} + ${#m1_raw[@]}))
	rm -rf "$d" && mkdir -p "$d/repo" "$d/bodies" "$d/old"
	(
		release_git_env
		"$GIT_REAL" -c commit.gpgsign=false init -q --object-format=sha1 -b main "$d/repo"
		{
			printf '# Changelog\n'
			for ((n = total + 1; n >= 1; n--)); do printf '\n## [0.%d.0] - 2026-01-01\n\n%s\n' "$n" "$M1_SECTION"; done
		} >"$d/repo/CHANGELOG.md"
		"$GIT_REAL" -C "$d/repo" add CHANGELOG.md
		if [[ "$r" != notpl ]]; then
			m1_tpl "$r" >"$d/repo/.release-template.json"
			"$GIT_REAL" -C "$d/repo" add .release-template.json
		fi
		"$GIT_REAL" -C "$d/repo" -c commit.gpgsign=false commit -q --no-verify -m recovery
		if [[ "$c" == notpl ]]; then
			[[ "$r" == notpl ]] || "$GIT_REAL" -C "$d/repo" rm -q .release-template.json
		else
			m1_tpl "$c" >"$d/repo/.release-template.json"
			"$GIT_REAL" -C "$d/repo" add .release-template.json
		fi
		"$GIT_REAL" -C "$d/repo" -c commit.gpgsign=false commit -q --no-verify --allow-empty -m current
	) || {
		echo "FAIL: M1 $r->$c: repo build"
		return
	}
	local c1 head
	c1="$("$GIT_REAL" -C "$d/repo" rev-parse HEAD~1)"
	head="$("$GIT_REAL" -C "$d/repo" rev-parse HEAD)"
	[[ "$r" == notpl ]] || rblob="$("$GIT_REAL" -C "$d/repo" rev-parse HEAD~1:.release-template.json)"
	[[ "$c" == notpl ]] || cblob="$("$GIT_REAL" -C "$d/repo" rev-parse HEAD:.release-template.json)"
	rl="$(m1_label "$r")" cl="$(m1_label "$c")"
	jq -n --argjson t "$((total + 1))" '[range(1; $t + 1) | "v0.\(.).0"]' >"$d/tags.json"
	jq -n --argjson t "$((total + 1))" --arg c1 "$c1" '[range(1; $t + 1) | {key: "v0.\(.).0", value: $c1}] | from_entries' >"$d/peeled.json"
	jq -n --argjson t "$((total + 1))" '[range(1; $t + 1) | {tagName: "v0.\(.).0", name: "widgets v0.\(.).0 — Highlight"}]' >"$d/list.json"
	for ((k = 0; k < total; k++)); do
		v="0.$((k + 2)).0" tag="v0.$((k + 2)).0" prev="v0.$((k + 1)).0"
		old="$d/old/$tag.md"
		local hl_arg=()
		if ((k < ${#corpus[@]})); then
			# shellcheck disable=SC2059
			printf -- "${corpus[$k]}" >"$old"
		elif ((k < ${#corpus[@]} + ${#m1_hl[@]})); then
			i=$((k - ${#corpus[@]}))
			# shellcheck disable=SC2059
			printf -- "${m1_hl[$i]}" >"$d/old/$tag.prefix"
			{
				cat "$d/old/$tag.prefix"
				printf '\n\n%s' "$M1_SECTION"
			} >"$old"
			hl_arg=(--headingless-summary "$d/old/$tag.prefix")
		else
			i=$((k - ${#corpus[@]} - ${#m1_hl[@]}))
			# shellcheck disable=SC2059
			printf -- "${m1_raw[$i]}\n" >"$old"
		fi
		if ((k < ${#corpus[@]} + ${#m1_hl[@]})); then
			[[ "$rl" == none ]] || printf '\n\n**%s:** %s/compare/%s...%s' "$rl" "$WEB" "$prev" "$tag" >>"$old"
			[[ -z "$rblob" ]] || printf '\n\n<!-- release-template-sha: %s -->' "$rblob" >>"$old"
			printf '\n' >>"$old"
		fi
		rc=0
		rs="$(RELEASE_JQ="$JQ_REAL" RELEASE_GIT="$GIT_REAL" "$LIB/resolve-template-marker.sh" --site resync-summary \
			--repo "$d/repo" --tag "$tag" --body-file "$old" --peeled "$d/peeled.json" --head-sha "$head" \
			--changelog "$d/repo/CHANGELOG.md" ${hl_arg[@]+"${hl_arg[@]}"} 2>/dev/null)" || rc=$?
		if [[ "$rc" != 0 ]] || ! jq -e '.rows | type == "object"' <<<"$rs" >/dev/null 2>&1; then
			echo "FAIL: M1 $r->$c #$k: resync-summary failed: $rs"
			continue
		fi
		echo "$rs" >"$d/old/$tag.rs.json"
		{
			if [[ "$(jq -r '.rows.summary_present and .rows.discard == null' <<<"$rs")" == true ]]; then
				printf "## What's New\n%s\n\n" "$(jq -j '.rows.summary_text' <<<"$rs")"
			fi
			if [[ "$(jq -r '.rows.preserve' <<<"$rs")" == true ]]; then
				jq -j '.rows.content_block_text' <<<"$rs"
			elif [[ "$c" == notpl ]]; then
				printf '%s' "$M1_SECTION"
			else
				printf '### Added\n\n- Item.'
			fi
			[[ "$cl" == none ]] || printf '\n\n**%s:** %s/compare/%s...%s' "$cl" "$WEB" "$prev" "$tag"
			[[ -z "$cblob" ]] || printf '\n\n<!-- release-template-sha: %s -->' "$cblob"
			printf '\n'
		} >"$d/bodies/$tag.md"
	done
	local a2
	a2="$(RELEASE_JQ="$JQ_REAL" RELEASE_GIT="$GIT_REAL" "$LIB/resolve-template-marker.sh" --site a2-classify \
		--repo "$d/repo" --release-list "$d/list.json" --bodies-dir "$d/bodies" --peeled "$d/peeled.json" \
		--tags "$d/tags.json" --changelog "$d/repo/CHANGELOG.md" --web-base-url "$WEB" --head-sha "$head" 2>/dev/null)"
	for ((k = 0; k < total; k++)); do
		v="0.$((k + 2)).0"
		got="$(note_of "$a2" "$v")"
		if [[ "$got" == "ok|" ]]; then
			echo "PASS: M1 round trip $r->$c #$k: ok"
		else
			echo "FAIL: M1 round trip $r->$c #$k: '$got' (old body $d/old/v$v.md; rows $(cat "$d/old/v$v.rs.json" 2>/dev/null))"
		fi
	done
}
m1_pids=()
for m1_r in none fd fc notpl; do
	for m1_c in none fd fc notpl; do
		m1_pair "$m1_r" "$m1_c" >"$TMP/m1-$m1_r-$m1_c.log" 2>&1 &
		m1_pids+=($!)
	done
done
for m1_pid in "${m1_pids[@]}"; do wait "$m1_pid"; done
m1_pass=0
for m1_log in "$TMP"/m1-*.log; do
	m1_pass=$((m1_pass + $(grep -c '^PASS: ' "$m1_log")))
	if grep -q '^FAIL: ' "$m1_log"; then
		grep '^FAIL: ' "$m1_log" >&2
		fail=1
	fi
done
m1_want=$((16 * (${#corpus[@]} + ${#m1_hl[@]} + ${#m1_raw[@]})))
[[ "$m1_pass" == "$m1_want" ]] &&
	pass "M1 re-sync round trip: $m1_pass/$m1_want composed bodies audit ok under the current template" ||
	bad "M1 re-sync round trip: $m1_pass/$m1_want composed bodies audit ok"

exit "$fail"
