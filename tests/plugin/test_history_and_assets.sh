#!/usr/bin/env bash
# Phase 3 acceptance test: assert the atomic `git mv` move from
# .claude/skills + .codex/skills to plugins/skein/skills + plugins/skein-codex/skills
# preserved history (renames, not delete+add) and that the tooling cleanup
# (3 deleted scripts) is staged without disturbing scripts/lib/bundle-map.sh.
#
# Runs against the STAGED state — invoked by the conductor before the
# Phase 3 boundary commit. Falls back to inspecting HEAD when nothing is
# staged (i.e. post-commit re-run) so the gate is idempotent.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

fail() {
	echo "fail: $1" >&2
	exit 1
}

# --- Detect mode: pre-commit (staged) vs post-commit (HEAD) ---------------
STAGED_COUNT=$(git diff --cached --name-only | wc -l | tr -d ' ')
if [[ "$STAGED_COUNT" -gt 0 ]]; then
	MODE="staged"
	DIFF_RANGE="--cached"
	echo "ok: running in staged (pre-commit) mode — $STAGED_COUNT staged paths"
else
	MODE="head"
	DIFF_RANGE="HEAD~1..HEAD"
	echo "ok: running in HEAD (post-commit) mode against ${DIFF_RANGE}"
fi

# Collect the rename / delete / add records once with rename detection on.
NAME_STATUS=$(git diff $DIFF_RANGE --name-status -M)

SKILLS=(
	conduct
	content-draft
	content-review
	deep-review
	dev-plan
	fan-out
	plan-view
	review-plan
	rfc-finder
	spec-compliance
	update-docs
)

# --- 1. Rename count + per-skill coverage ---------------------------------
TOTAL_RENAMES=$(printf '%s\n' "$NAME_STATUS" | awk '$1 ~ /^R/' | wc -l | tr -d ' ')
if [[ "$TOTAL_RENAMES" -lt 22 ]]; then
	fail "expected >=22 staged renames, got $TOTAL_RENAMES"
fi
echo "ok: $TOTAL_RENAMES rename entries (>=22 required)"

for skill in "${SKILLS[@]}"; do
	claude_hits=$(printf '%s\n' "$NAME_STATUS" |
		awk -v s="plugins/skein/skills/${skill}/" '$1 ~ /^R/ && $3 ~ "^"s' |
		wc -l | tr -d ' ')
	codex_hits=$(printf '%s\n' "$NAME_STATUS" |
		awk -v s="plugins/skein-codex/skills/${skill}/" '$1 ~ /^R/ && $3 ~ "^"s' |
		wc -l | tr -d ' ')
	if [[ "$claude_hits" -lt 1 ]]; then
		fail "skill '$skill' has no staged rename into plugins/skein/skills/$skill/"
	fi
	if [[ "$codex_hits" -lt 1 ]]; then
		fail "skill '$skill' has no staged rename into plugins/skein-codex/skills/$skill/"
	fi
done
echo "ok: each of the 11 skills has >=1 rename into both plugin halves"

# --- 2. No D/A pairs for skill content ------------------------------------
# Anything that disappears from .claude/skills/** or .codex/skills/** must
# show up as `R old new`, never as `D old` + `A new` (which loses history).
DELETED_SKILL_FILES=$(printf '%s\n' "$NAME_STATUS" |
	awk '$1 == "D" && ($2 ~ /^\.claude\/skills\// || $2 ~ /^\.codex\/skills\//) {print $2}')
if [[ -n "$DELETED_SKILL_FILES" ]]; then
	# A D/A pair must share the post-skill-root suffix. Strip the
	# `.{claude,codex}/skills/` prefix from each deletion and look for an
	# `A` under `plugins/skein{,-codex}/skills/` ending in the same suffix.
	# This avoids false positives from unrelated files that share only a
	# basename (e.g., a deleted `README.md` somewhere matching an added
	# `README.md` elsewhere).
	while IFS= read -r dpath; do
		[[ -z "$dpath" ]] && continue
		suffix="${dpath#.claude/skills/}"
		suffix="${suffix#.codex/skills/}"
		match=$(printf '%s\n' "$NAME_STATUS" |
			awk -v s="$suffix" '$1 == "A" && ($2 ~ ("^plugins/skein/skills/" s "$") || $2 ~ ("^plugins/skein-codex/skills/" s "$")) {print $2; exit}')
		if [[ -n "$match" ]]; then
			fail "D/A pair detected (history lost): D $dpath  /  A $match"
		fi
	done <<<"$DELETED_SKILL_FILES"
fi
echo "ok: no D/A pairs for .claude/skills or .codex/skills content"

# --- 3. History-follow spot checks ----------------------------------------
SPOT_CHECKS=(
	"plugins/skein/skills/plan-view/generate.py"
	"plugins/skein/skills/dev-plan/SKILL.md"
	"plugins/skein-codex/skills/conduct/conductor.py"
)

# references/ spot check — pick any tracked file under content-review/references/
REF_FILE=$(git ls-files --cached -- 'plugins/skein/skills/content-review/references/*' | head -1)
if [[ -z "$REF_FILE" ]]; then
	fail "no tracked file under plugins/skein/skills/content-review/references/ (expected at least one)"
fi
SPOT_CHECKS+=("$REF_FILE")

for path in "${SPOT_CHECKS[@]}"; do
	if [[ -z "$(git ls-files --cached -- "$path")" ]]; then
		fail "spot-check path missing from tracked tree: $path"
	fi
	# `git log --follow` walks committed history. In staged (pre-commit) mode
	# the new path is not yet in any commit, so we look up the OLD path from
	# the rename record and follow that instead — the test is whether history
	# extends past this phase, which the old path's log answers equivalently.
	follow_path="$path"
	if [[ "$MODE" == "staged" ]]; then
		old_path=$(printf '%s\n' "$NAME_STATUS" |
			awk -v p="$path" '$1 ~ /^R/ && $3 == p {print $2; exit}')
		if [[ -n "$old_path" ]]; then
			follow_path="$old_path"
		fi
	fi
	commits=$(git log --follow --oneline -- "$follow_path" | wc -l | tr -d ' ')
	if [[ "$commits" -lt 2 ]]; then
		fail "history too shallow for $path (followed via $follow_path) — git log --follow returned $commits commits (need >=2)"
	fi
	echo "ok: history-follow on $path (via $follow_path) traces $commits commits"
done

# --- 4. Old directories vanished ------------------------------------------
LEFTOVERS=$(git ls-files .claude/skills/ .codex/skills/ 2>/dev/null || true)
if [[ -n "$LEFTOVERS" ]]; then
	fail "tracked files still under old skill dirs:\n$LEFTOVERS"
fi
echo "ok: .claude/skills/ and .codex/skills/ contain no tracked files"

# --- 5. The three deleted scripts are gone --------------------------------
DELETED_SCRIPTS=(
	scripts/promote-skills.sh
	scripts/sync-skills.sh
	scripts/bootstrap-skills.sh
)
STILL_THERE=$(git ls-files -- "${DELETED_SCRIPTS[@]}" 2>/dev/null || true)
if [[ -n "$STILL_THERE" ]]; then
	fail "expected-deleted scripts still tracked:\n$STILL_THERE"
fi
echo "ok: promote-skills.sh, sync-skills.sh, bootstrap-skills.sh all untracked"

# --- 6. scripts/lib/bundle-map.sh untouched -------------------------------
if [[ ! -f scripts/lib/bundle-map.sh ]]; then
	fail "scripts/lib/bundle-map.sh missing — must remain on disk (C2 architecture invariant)"
fi
BMAP_DIFF=$(git diff $DIFF_RANGE -- scripts/lib/bundle-map.sh)
if [[ -n "$BMAP_DIFF" ]]; then
	fail "scripts/lib/bundle-map.sh has changes in this phase (C2 says it must NOT be touched):\n$BMAP_DIFF"
fi
echo "ok: scripts/lib/bundle-map.sh unchanged in this phase"

# --- 7. Codex-mirror SKILL.md content not edited --------------------------
# For renames git suppresses content diffs when similarity is 100%. If git
# reports the move as R100, we have nothing to inspect and that's the win
# condition. If it reports R<100, surface any +/- content-line drift.
CODEX_SKILL_MDS=(
	"plugins/skein-codex/skills/deep-review/SKILL.md"
	"plugins/skein-codex/skills/review-plan/SKILL.md"
)
for path in "${CODEX_SKILL_MDS[@]}"; do
	if [[ -z "$(git ls-files --cached -- "$path")" ]]; then
		fail "expected Codex SKILL.md not tracked: $path"
	fi
	status_line=$(printf '%s\n' "$NAME_STATUS" | awk -v p="$path" '$3 == p {print $1; exit}')
	if [[ "$status_line" == "R100" ]]; then
		echo "ok: skipped content-edit check for $path (rename only, R100)"
		continue
	fi
	# Non-R100 — look for substantive content lines (not diff/rename headers).
	content_changes=$(git diff $DIFF_RANGE -M -- "$path" |
		grep -E '^[+-]' |
		grep -Ecv '^(\+\+\+|---|\+\+\+ b/|--- a/)' || true)
	if [[ "${content_changes:-0}" -gt 0 ]]; then
		fail "$path shows $content_changes content-line changes — must be rename-only"
	fi
	echo "ok: $path has no content-line changes (status=$status_line)"
done

echo "all assertions passed (mode=$MODE)"
