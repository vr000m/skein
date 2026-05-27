#!/usr/bin/env bash
set -eu

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MANIFEST="$REPO_ROOT/tests/parity/codex-test-equivalents.txt"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

note() {
	echo "NOTE: $*" >&2
}

commit_files() {
	git -C "$REPO_ROOT" show --name-only --format= "$1" -- plugins/skein/skills/conduct plugins/skein-codex/skills/conduct
}

touches_runtime() {
	local sha="$1"
	local runtime="$2"
	commit_files "$sha" | grep -q "^\\.$runtime/skills/conduct/"
}

touches_both_mirrors() {
	local sha="$1"
	touches_runtime "$sha" "claude" && touches_runtime "$sha" "codex"
}

phase_subject_matches() {
	local subject="$1"
	local phase="$2"
	case "$subject" in
	conduct"(phase $phase)"* | conduct"(phase $phase "* | conduct": phase $phase "* | conduct": phase $phase —"*)
		return 0
		;;
	esac
	return 1
}

find_strict_boundary() {
	local runtime="$1"
	local phase="$2"
	local path=".$runtime/skills/conduct"
	local sha subject body
	while IFS= read -r sha; do
		subject="$(git -C "$REPO_ROOT" show -s --format=%s "$sha")"
		body="$(git -C "$REPO_ROOT" show -s --format=%B "$sha")"
		phase_subject_matches "$subject" "$phase" || continue
		echo "$body" | grep -q "Conducted-By: $runtime" || continue
		touches_runtime "$sha" "$runtime" || continue
		if touches_both_mirrors "$sha"; then
			fail "mixed-mirror-commit at $sha: phase-boundary commits must touch one mirror tree only"
		fi
		echo "$sha"
		return 0
	done < <(git -C "$REPO_ROOT" log --format=%H -- "$path")
	return 1
}

find_legacy_boundary() {
	local runtime="$1"
	local phase="$2"
	local path=".$runtime/skills/conduct"
	local sha subject
	[[ "$runtime" == "codex" && "$phase" == "1" ]] || return 1
	while IFS= read -r sha; do
		subject="$(git -C "$REPO_ROOT" show -s --format=%s "$sha")"
		case "$subject" in
		*"progress-aware"* | *"Progress-aware"* | *"phase 1"* | *"Phase 1"*)
			touches_runtime "$sha" "$runtime" || continue
			if touches_both_mirrors "$sha"; then
				fail "mixed-mirror-commit at $sha: phase-boundary commits must touch one mirror tree only"
			fi
			echo "$sha"
			return 0
			;;
		esac
	done < <(git -C "$REPO_ROOT" log --format=%H -- "$path")
	return 1
}

check_boundary() {
	local runtime="$1"
	local phase="$2"
	local sha
	if sha="$(find_strict_boundary "$runtime" "$phase")"; then
		echo "PASS: phase $phase $runtime boundary $sha"
		return
	fi
	if sha="$(find_legacy_boundary "$runtime" "$phase")"; then
		echo "PASS: phase $phase $runtime boundary $sha [unverified-by-trailer]"
		return
	fi
	fail "missing phase $phase $runtime boundary commit"
}

test_file_for_area() {
	case "$1" in
	progress-detector) echo "test_progress_detector.py" ;;
	diff-stat-canonicalisation) echo "test_diff_stat_canonicalisation.py" ;;
	conductor-harness) echo "test_conductor_harness.py" ;;
	autonomous-mode) echo "test_autonomous_mode.py" ;;
	ci-parity) echo "test_ci_parity.py" ;;
	schema-migration) echo "test_schema_migration.py" ;;
	*) fail "unknown manifest area: $1" ;;
	esac
}

has_test() {
	local runtime="$1"
	local file="$2"
	local test_name="$3"
	local path="$REPO_ROOT/.$runtime/skills/conduct/tests/$file"
	[[ -f "$path" ]] || return 1
	grep -q "^def $test_name\\b" "$path"
}

check_manifest() {
	[[ -f "$MANIFEST" ]] || fail "missing manifest: $MANIFEST"
	local area="" file="" line claude_test codex_test
	while IFS= read -r line || [[ -n "$line" ]]; do
		case "$line" in
		"") continue ;;
		"# area: "*)
			area="${line#"# area: "}"
			file="$(test_file_for_area "$area")"
			continue
			;;
		"#"*) continue ;;
		esac
		[[ -n "$area" ]] || fail "manifest test before area header: $line"
		local codex_file="$file"
		if [[ "$line" == *_codex_equivalent=* ]]; then
			claude_test="${line%%_codex_equivalent=*}"
			codex_test="${line#*=}"
			if [[ "$codex_test" == *"::"* ]]; then
				codex_file="${codex_test%%::*}"
				codex_test="${codex_test#*::}"
			fi
		else
			claude_test="$line"
			codex_test="$line"
		fi
		has_test "claude" "$file" "$claude_test" || fail "manifest references missing Claude test $file::$claude_test"
		has_test "codex" "$codex_file" "$codex_test" || fail "manifest references missing Codex test $codex_file::$codex_test for Claude $claude_test"
	done <"$MANIFEST"
	echo "PASS: codex test-equivalents manifest"
}

main() {
	for phase in 1 2 3; do
		check_boundary "claude" "$phase"
		check_boundary "codex" "$phase"
	done
	check_manifest
}

main "$@"
