#!/usr/bin/env bash
# delete-skills.sh — surgically remove the 12 skein-managed skills from the
# global Claude and Codex skill dirs. Use after `/plugin install skein@skein`
# (Claude) and `codex plugin add skein@skein` (Codex) to close the duplicate-skill
# window without touching unrelated skills (e.g. pipecat, cloudflare-deploy,
# codex-primary-runtime).
#
# Usage:
#   scripts/delete-skills.sh --dry-run   # print what would be deleted, change nothing
#   scripts/delete-skills.sh             # delete for real
#
# Back up first if you have unmerged local edits in ~/.claude/skills or
# ~/.codex/skills — this script does not back up.

set -euo pipefail

DRY_RUN=0
case "${1:-}" in
  --dry-run) DRY_RUN=1 ;;
  "") ;;
  *) echo "usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

SKEIN=(
  conduct content-draft content-review deep-review dev-plan fan-out
  grill plan-view release review-plan rfc-finder spec-compliance update-docs
)

removed=0
missing=0
for s in "${SKEIN[@]}"; do
  for base in "$HOME/.claude/skills" "$HOME/.codex/skills"; do
    target="$base/$s"
    if [[ -d "$target" ]]; then
      if (( DRY_RUN )); then
        echo "would remove: $target"
      else
        rm -rf "$target"
        echo "removed: $target"
      fi
      removed=$((removed + 1))
    else
      (( DRY_RUN )) && echo "skip (not present): $target"
      missing=$((missing + 1))
    fi
  done
done

if (( DRY_RUN )); then
  echo "dry-run: would remove $removed path(s); $missing already absent"
else
  echo "removed $removed path(s) from ~/.claude/skills and ~/.codex/skills; $missing already absent"
fi
