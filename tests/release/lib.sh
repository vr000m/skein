#!/usr/bin/env bash
# Deterministic git-state builder for the release-skill fixture tests
# (docs/dev_plans/20260917-refactor-release-skill-structure.md, Phase 1.5,
# grilled decisions 9 and 19). Sourced, not executed. Static inputs live in
# tests/release/fixtures/; this builds git state only where a script genuinely
# needs it, in a caller-supplied empty directory. Nothing under tests/ ever
# carries a nested .git.
#
# Determinism: no ambient git config, fixed identity and dates, SHA-1 object
# format, fixed branch name, signing off. Two builds of the same case yield the
# same HEAD SHA (asserted by tests/release/test-lib.sh).

RELEASE_FIXTURES_DIR="${RELEASE_FIXTURES_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fixtures}"

release_git_env() {
	export GIT_CONFIG_GLOBAL=/dev/null
	export GIT_CONFIG_NOSYSTEM=1
	export GIT_AUTHOR_NAME="Release Fixture"
	export GIT_AUTHOR_EMAIL="fixture@example.invalid"
	export GIT_COMMITTER_NAME="Release Fixture"
	export GIT_COMMITTER_EMAIL="fixture@example.invalid"
}

# release_commit <repo> <message> <iso-date>
release_commit() {
	GIT_AUTHOR_DATE="$3" GIT_COMMITTER_DATE="$3" \
		git -C "$1" -c commit.gpgsign=false commit -q --no-verify -m "$2"
}

# release_build_repo <templated|untemplated> <empty-dest-dir>
# Commit 1 carries CHANGELOG.md (+ .release-template.json when templated);
# commit 2 adds NOTES.md. Prints nothing; HEAD is commit 2.
release_build_repo() {
	local case_name="$1" dest="$2" src
	src="$RELEASE_FIXTURES_DIR/$case_name"
	[[ -d "$src" ]] || {
		echo "unknown fixture case: $case_name" >&2
		return 2
	}
	(
		release_git_env
		git -c commit.gpgsign=false init -q --object-format=sha1 -b main "$dest" || exit 1
		cp "$src/CHANGELOG.md" "$dest/CHANGELOG.md"
		git -C "$dest" add CHANGELOG.md
		if [[ -f "$src/.release-template.json" ]]; then
			cp "$src/.release-template.json" "$dest/.release-template.json"
			git -C "$dest" add .release-template.json
		fi
		release_commit "$dest" "release fixture: commit 1" "2026-01-01T00:00:00Z" || exit 1
		printf 'notes\n' >"$dest/NOTES.md"
		git -C "$dest" add NOTES.md
		release_commit "$dest" "release fixture: commit 2" "2026-02-01T00:00:00Z" || exit 1
	)
}

# release_peeled_commits <repo> : prints `<commit1> <commit2>` (oldest first).
release_peeled_commits() {
	git -C "$1" rev-list --reverse HEAD | tr '\n' ' ' | sed 's/ $//'
	echo
}
