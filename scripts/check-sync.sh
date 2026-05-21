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

CODEX_DIFF=0
CLAUDE_DIFF=0
GUIDE_DIFF=0

read -r -a managed_skills <<<"$MANAGED_SKILLS"
for skill in "${managed_skills[@]}"; do
	if [[ ! -d "$GLOBAL_CODEX_SKILLS_DIR/$skill" ]]; then
		echo "skip: .codex/skills/$skill global dir not yet bootstrapped (run promote-skills or bootstrap-skills)"
	elif [[ ! -d "$ROOT_DIR/.codex/skills/$skill" ]]; then
		echo "drift: .codex/skills/$skill missing from repo but exists globally"
		CODEX_DIFF=1
	elif ! diff -ru --exclude='content-guidelines.md' "$GLOBAL_CODEX_SKILLS_DIR/$skill" "$ROOT_DIR/.codex/skills/$skill" >/dev/null; then
		echo "drift: .codex/skills/$skill differs from global authority"
		CODEX_DIFF=1
	fi

	if [[ ! -d "$GLOBAL_CLAUDE_SKILLS_DIR/$skill" ]]; then
		echo "skip: .claude/skills/$skill global dir not yet bootstrapped (run promote-skills or bootstrap-skills)"
	elif [[ ! -d "$ROOT_DIR/.claude/skills/$skill" ]]; then
		echo "drift: .claude/skills/$skill missing from repo but exists globally"
		CLAUDE_DIFF=1
	elif ! diff -ru --exclude='content-guidelines.md' "$GLOBAL_CLAUDE_SKILLS_DIR/$skill" "$ROOT_DIR/.claude/skills/$skill" >/dev/null; then
		echo "drift: .claude/skills/$skill differs from global authority"
		CLAUDE_DIFF=1
	fi
done

claude_only_skills=()
if [[ -n "${CLAUDE_ONLY_SKILLS// /}" ]]; then
	read -r -a claude_only_skills <<<"$CLAUDE_ONLY_SKILLS"
fi
if [[ -n "${CLAUDE_ONLY_SKILLS// /}" ]]; then
	for skill in "${claude_only_skills[@]}"; do
		if [[ ! -d "$GLOBAL_CLAUDE_SKILLS_DIR/$skill" ]]; then
			echo "skip: .claude/skills/$skill global dir not yet bootstrapped (run promote-skills or bootstrap-skills)"
		elif [[ ! -d "$ROOT_DIR/.claude/skills/$skill" ]]; then
			echo "drift: .claude/skills/$skill missing from repo but exists globally"
			CLAUDE_DIFF=1
		elif ! diff -ru "$GLOBAL_CLAUDE_SKILLS_DIR/$skill" "$ROOT_DIR/.claude/skills/$skill" >/dev/null; then
			echo "drift: .claude/skills/$skill differs from global authority"
			CLAUDE_DIFF=1
		fi
	done
fi

if [[ " $MANAGED_SKILLS " == *" content-review "* ]]; then
	CANONICAL_REFERENCES_DIR="$ROOT_DIR/.codex/skills/content-review/references"
	REPO_CLAUDE_REFERENCES_DIR="$ROOT_DIR/.claude/skills/content-review/references"
	GLOBAL_CODEX_REFERENCES_DIR="$GLOBAL_CODEX_SKILLS_DIR/content-review/references"
	GLOBAL_CLAUDE_REFERENCES_DIR="$GLOBAL_CLAUDE_SKILLS_DIR/content-review/references"
	REQUIRED_REFERENCE_FILES=("content-guidelines.md" "writing-style-rules.md")

	if [[ ! -d "$CANONICAL_REFERENCES_DIR" ]]; then
		echo "drift: missing canonical repo content-review references dir at $CANONICAL_REFERENCES_DIR"
		GUIDE_DIFF=1
	fi

	for required_reference in "${REQUIRED_REFERENCE_FILES[@]}"; do
		if [[ ! -f "$CANONICAL_REFERENCES_DIR/$required_reference" ]]; then
			echo "drift: missing canonical repo $required_reference at $CANONICAL_REFERENCES_DIR/$required_reference"
			GUIDE_DIFF=1
		fi
	done

	for canonical_file in "$CANONICAL_REFERENCES_DIR"/*; do
		if [[ ! -f "$canonical_file" ]]; then
			continue
		fi

		reference_name="$(basename "$canonical_file")"
		repo_claude_file="$REPO_CLAUDE_REFERENCES_DIR/$reference_name"
		global_codex_file="$GLOBAL_CODEX_REFERENCES_DIR/$reference_name"
		global_claude_file="$GLOBAL_CLAUDE_REFERENCES_DIR/$reference_name"

		if [[ ! -f "$repo_claude_file" ]]; then
			echo "drift: missing repo claude $reference_name at $repo_claude_file"
			GUIDE_DIFF=1
		fi

		if [[ ! -f "$global_codex_file" ]]; then
			echo "drift: missing global codex $reference_name at $global_codex_file"
			GUIDE_DIFF=1
		fi

		if [[ ! -f "$global_claude_file" ]]; then
			echo "drift: missing global claude $reference_name at $global_claude_file"
			GUIDE_DIFF=1
		fi

		if [[ -f "$repo_claude_file" ]] && ! cmp -s "$canonical_file" "$repo_claude_file"; then
			echo "drift: repo claude $reference_name differs from repo canonical copy"
			GUIDE_DIFF=1
		fi

		if [[ -f "$global_codex_file" ]] && ! cmp -s "$canonical_file" "$global_codex_file"; then
			echo "drift: global codex $reference_name differs from repo canonical copy"
			GUIDE_DIFF=1
		fi

		if [[ -f "$global_claude_file" ]] && ! cmp -s "$canonical_file" "$global_claude_file"; then
			echo "drift: global claude $reference_name differs from repo canonical copy"
			GUIDE_DIFF=1
		fi
	done
fi

CLAUDE_MD_DIFF=0
REPO_CLAUDE_MD="$ROOT_DIR/.claude/CLAUDE.md"
if [[ -f "$GLOBAL_CLAUDE_MD" && -f "$REPO_CLAUDE_MD" ]]; then
	if ! cmp -s "$GLOBAL_CLAUDE_MD" "$REPO_CLAUDE_MD"; then
		echo "drift: CLAUDE.md differs between global and repo"
		CLAUDE_MD_DIFF=1
	fi
elif [[ -f "$GLOBAL_CLAUDE_MD" && ! -f "$REPO_CLAUDE_MD" ]]; then
	echo "drift: CLAUDE.md exists globally but not in repo (run just sync-skills)"
	CLAUDE_MD_DIFF=1
elif [[ ! -f "$GLOBAL_CLAUDE_MD" && -f "$REPO_CLAUDE_MD" ]]; then
	echo "drift: CLAUDE.md exists in repo but not globally (run just promote-skills)"
	CLAUDE_MD_DIFF=1
fi

CODEX_AGENTS_DIFF=0
REPO_CODEX_AGENTS="$ROOT_DIR/.codex/AGENTS.md"
if [[ -f "$GLOBAL_CODEX_AGENTS" && -f "$REPO_CODEX_AGENTS" ]]; then
	if ! cmp -s "$GLOBAL_CODEX_AGENTS" "$REPO_CODEX_AGENTS"; then
		echo "drift: AGENTS.md differs between global and repo"
		CODEX_AGENTS_DIFF=1
	fi
elif [[ -f "$GLOBAL_CODEX_AGENTS" && ! -f "$REPO_CODEX_AGENTS" ]]; then
	echo "drift: AGENTS.md exists globally but not in repo (run just sync-skills)"
	CODEX_AGENTS_DIFF=1
elif [[ ! -f "$GLOBAL_CODEX_AGENTS" && -f "$REPO_CODEX_AGENTS" ]]; then
	echo "drift: AGENTS.md exists in repo but not globally (run just promote-skills)"
	CODEX_AGENTS_DIFF=1
fi

if [[ "$CODEX_DIFF" -eq 1 || "$CLAUDE_DIFF" -eq 1 || "$GUIDE_DIFF" -eq 1 || "$CLAUDE_MD_DIFF" -eq 1 || "$CODEX_AGENTS_DIFF" -eq 1 ]]; then
	echo "check-sync failed"
	exit 1
fi

echo "check-sync passed"
