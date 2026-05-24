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

REPO_CODEX_DIR="$ROOT_DIR/.codex/skills"
REPO_CLAUDE_DIR="$ROOT_DIR/.claude/skills"
REPO_CLAUDE_MD="$ROOT_DIR/.claude/CLAUDE.md"
REPO_CODEX_AGENTS="$ROOT_DIR/.codex/AGENTS.md"

require_dir() {
	local path="$1"
	local name="$2"
	if [[ ! -d "$path" ]]; then
		echo "error: missing $name at $path" >&2
		exit 1
	fi
}

sync_repo_reference_copies() {
	local repo_references_code="$REPO_CODEX_DIR/content-review/references"
	local repo_references_claude="$REPO_CLAUDE_DIR/content-review/references"

	if [[ ! -d "$repo_references_code" ]]; then
		echo "error: missing canonical content-review references dir at $repo_references_code" >&2
		exit 1
	fi

	mkdir -p "$repo_references_claude"
	rsync -a --delete "$repo_references_code/" "$repo_references_claude/"
	echo "Restored repo content-review reference files from canonical source"
}

sync_skill() {
	local source_root="$1"
	local target_root="$2"
	local skill="$3"
	local source_dir="$source_root/$skill"
	local target_dir="$target_root/$skill"

	if [[ ! -d "$source_dir" ]]; then
		echo "skip: $source_dir not found (run promote-skills or bootstrap-skills to seed it)"
		return
	fi
	mkdir -p "$target_dir"
	case "$skill" in
	content-review)
		rsync -a --delete --exclude='references/' --exclude='__pycache__' "$source_dir/" "$target_dir/"
		;;
	deep-review | review-plan)
		# The bundled scripts/ subtree is a generated mirror of canonical
		# scripts/; never let a stale global copy clobber the repo. It is
		# regenerated from canonical by sync_repo_bundled_appliers below.
		rsync -a --delete --exclude='scripts/' --exclude='__pycache__' "$source_dir/" "$target_dir/"
		;;
	*)
		rsync -a --delete --exclude='__pycache__' "$source_dir/" "$target_dir/"
		;;
	esac
}

sync_repo_bundled_appliers() {
	local bundler="$ROOT_DIR/scripts/bundle-appliers.sh"
	if [[ ! -x "$bundler" ]]; then
		echo "warn: $bundler not found/executable, skipping applier re-bundle" >&2
		return
	fi
	"$bundler" >/dev/null
	echo "Regenerated bundled auto-fix appliers from canonical scripts/"
}

require_dir "$GLOBAL_CODEX_SKILLS_DIR" "GLOBAL_CODEX_SKILLS_DIR"
require_dir "$GLOBAL_CLAUDE_SKILLS_DIR" "GLOBAL_CLAUDE_SKILLS_DIR"
require_dir "$REPO_CODEX_DIR" "repo codex skills dir"
require_dir "$REPO_CLAUDE_DIR" "repo claude skills dir"

read -r -a managed_skills <<<"$MANAGED_SKILLS"
for skill in "${managed_skills[@]}"; do
	codex_exists=0
	claude_exists=0
	[[ -d "$GLOBAL_CODEX_SKILLS_DIR/$skill" ]] && codex_exists=1
	[[ -d "$GLOBAL_CLAUDE_SKILLS_DIR/$skill" ]] && claude_exists=1

	if [[ "$codex_exists" -eq 0 && "$claude_exists" -eq 0 ]]; then
		echo "skip: $skill not found in either global dir (run promote-skills or bootstrap-skills to seed it)"
		continue
	fi
	if [[ "$codex_exists" -eq 0 || "$claude_exists" -eq 0 ]]; then
		echo "skip: $skill missing from one global dir (codex=$codex_exists, claude=$claude_exists); skipping both to avoid half-sync"
		continue
	fi

	sync_skill "$GLOBAL_CODEX_SKILLS_DIR" "$REPO_CODEX_DIR" "$skill"
	sync_skill "$GLOBAL_CLAUDE_SKILLS_DIR" "$REPO_CLAUDE_DIR" "$skill"
done

claude_only_skills=()
if [[ -n "${CLAUDE_ONLY_SKILLS// /}" ]]; then
	read -r -a claude_only_skills <<<"$CLAUDE_ONLY_SKILLS"
fi
if [[ -n "${CLAUDE_ONLY_SKILLS// /}" ]]; then
	for skill in "${claude_only_skills[@]}"; do
		if [[ ! -d "$GLOBAL_CLAUDE_SKILLS_DIR/$skill" ]]; then
			echo "skip: $skill not found in global claude dir (run promote-skills or bootstrap-skills to seed it)"
			continue
		fi
		sync_skill "$GLOBAL_CLAUDE_SKILLS_DIR" "$REPO_CLAUDE_DIR" "$skill"
	done
fi

if [[ " $MANAGED_SKILLS " == *" content-review "* ]]; then
	sync_repo_reference_copies
fi

sync_repo_bundled_appliers

if [[ -f "$GLOBAL_CLAUDE_MD" ]]; then
	cp "$GLOBAL_CLAUDE_MD" "$REPO_CLAUDE_MD"
	echo "Synced CLAUDE.md: $GLOBAL_CLAUDE_MD -> $REPO_CLAUDE_MD"
else
	echo "warn: global CLAUDE.md not found at $GLOBAL_CLAUDE_MD, skipping" >&2
fi

if [[ -f "$GLOBAL_CODEX_AGENTS" ]]; then
	cp "$GLOBAL_CODEX_AGENTS" "$REPO_CODEX_AGENTS"
	echo "Synced AGENTS.md: $GLOBAL_CODEX_AGENTS -> $REPO_CODEX_AGENTS"
else
	if [[ -f "$REPO_CODEX_AGENTS" ]]; then
		echo "warn: global AGENTS.md not found at $GLOBAL_CODEX_AGENTS, skipping" >&2
	fi
fi

echo "Sync complete: global -> repo"
