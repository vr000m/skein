#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -f "$ROOT_DIR/.env" ]]; then
	# shellcheck disable=SC1091
	source "$ROOT_DIR/.env"
fi

GLOBAL_CODEX_SKILLS_DIR="${GLOBAL_CODEX_SKILLS_DIR:-$HOME/.codex/skills}"
GLOBAL_CLAUDE_SKILLS_DIR="${GLOBAL_CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
MANAGED_SKILLS="${MANAGED_SKILLS:-conduct content-draft content-review deep-review dev-plan fan-out plan-view review-plan rfc-finder spec-compliance update-docs}"
CLAUDE_ONLY_SKILLS="${CLAUDE_ONLY_SKILLS:-}"
GLOBAL_CODEX_AGENTS="${GLOBAL_CODEX_AGENTS:-$HOME/.codex/AGENTS.md}"
GLOBAL_CLAUDE_MD="${GLOBAL_CLAUDE_MD:-$HOME/.claude/CLAUDE.md}"

if [[ "${1:-}" != "--yes" ]]; then
	echo "error: promotion is destructive; rerun with --yes" >&2
	exit 1
fi

read -r -a managed_skills <<<"$MANAGED_SKILLS"
claude_only_skills=()
if [[ -n "${CLAUDE_ONLY_SKILLS// /}" ]]; then
	read -r -a claude_only_skills <<<"$CLAUDE_ONLY_SKILLS"
fi

copy_reference_files_to_global() {
	local repo_references_code="$ROOT_DIR/.codex/skills/content-review/references"
	local global_references_code="$GLOBAL_CODEX_SKILLS_DIR/content-review/references"
	local global_references_claude="$GLOBAL_CLAUDE_SKILLS_DIR/content-review/references"

	mkdir -p "$global_references_code" "$global_references_claude"
	rsync -a --delete "$repo_references_code/" "$global_references_code/"
	rsync -a --delete "$repo_references_code/" "$global_references_claude/"
	echo "Copied canonical repo content-review reference files to global skill directories"
}

for skill in "${managed_skills[@]}"; do
	mkdir -p "$GLOBAL_CODEX_SKILLS_DIR/$skill" "$GLOBAL_CLAUDE_SKILLS_DIR/$skill"
	rsync -a --delete "$ROOT_DIR/.codex/skills/$skill/" "$GLOBAL_CODEX_SKILLS_DIR/$skill/"
	rsync -a --delete "$ROOT_DIR/.claude/skills/$skill/" "$GLOBAL_CLAUDE_SKILLS_DIR/$skill/"
done

if [[ -n "${CLAUDE_ONLY_SKILLS// /}" ]]; then
	for skill in "${claude_only_skills[@]}"; do
		src="$ROOT_DIR/.claude/skills/$skill"
		if [[ ! -d "$src" ]]; then
			echo "warn: Claude-only skill $skill missing at $src, skipping" >&2
			continue
		fi
		mkdir -p "$GLOBAL_CLAUDE_SKILLS_DIR/$skill"
		rsync -a --delete "$src/" "$GLOBAL_CLAUDE_SKILLS_DIR/$skill/"
		echo "Promoted Claude-only skill: $skill"
	done
fi

if [[ " $MANAGED_SKILLS " == *" content-review "* ]]; then
	copy_reference_files_to_global
fi

REPO_CLAUDE_MD="$ROOT_DIR/.claude/CLAUDE.md"
if [[ -f "$REPO_CLAUDE_MD" ]]; then
	mkdir -p "$(dirname "$GLOBAL_CLAUDE_MD")"
	cp "$REPO_CLAUDE_MD" "$GLOBAL_CLAUDE_MD"
	echo "Promoted CLAUDE.md: $REPO_CLAUDE_MD -> $GLOBAL_CLAUDE_MD"
else
	echo "warn: repo CLAUDE.md not found at $REPO_CLAUDE_MD, skipping" >&2
fi

REPO_CODEX_AGENTS="$ROOT_DIR/.codex/AGENTS.md"
if [[ -f "$REPO_CODEX_AGENTS" ]]; then
	mkdir -p "$(dirname "$GLOBAL_CODEX_AGENTS")"
	cp "$REPO_CODEX_AGENTS" "$GLOBAL_CODEX_AGENTS"
	echo "Promoted AGENTS.md: $REPO_CODEX_AGENTS -> $GLOBAL_CODEX_AGENTS"
else
	echo "warn: repo AGENTS.md not found at $REPO_CODEX_AGENTS, skipping" >&2
fi

echo "Promotion complete: repo -> global"
