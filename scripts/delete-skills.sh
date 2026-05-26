#!/usr/bin/env bash
# delete-skills.sh — surgically remove the 11 skein-managed skills from the
# global Claude and Codex skill dirs. Use after `/plugin install skein` (Claude)
# and `codex plugin add skein@skein-local` (Codex) to close the duplicate-skill
# window without touching unrelated skills (e.g. pipecat, cloudflare-deploy,
# codex-primary-runtime).
#
# Back up first if you have unmerged local edits in ~/.claude/skills or
# ~/.codex/skills — this script does not back up.

set -euo pipefail

SKEIN=(
  conduct content-draft content-review deep-review dev-plan fan-out
  plan-view review-plan rfc-finder spec-compliance update-docs
)

for s in "${SKEIN[@]}"; do
  rm -rf "$HOME/.claude/skills/$s"
  rm -rf "$HOME/.codex/skills/$s"
done

echo "removed ${#SKEIN[@]} skein-managed skills from ~/.claude/skills and ~/.codex/skills"
