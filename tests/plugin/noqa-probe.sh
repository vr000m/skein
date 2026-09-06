#!/usr/bin/env bash
# Phase 4 validation probe: reproduce (and later prove the fix for) the
# format-on-edit.sh hook stripping an unused `# noqa` comment.
#
# The hook runs `ruff check --fix` on any *.py file it's handed via the
# PostToolUse tool_input JSON. When a project's ruff config selects RUF100
# ("unused noqa"), `--fix` silently deletes the `# noqa` comment. This probe
# builds a scratch project that selects RUF100 on purpose, feeds a file with
# an unused `# noqa` through the hook, and reports whether it survived.
#
# Usage: [HOOK_PATH=/path/to/format-on-edit.sh] bash tests/plugin/noqa-probe.sh
# HOOK_PATH defaults to $HOME/.claude/hooks/format-on-edit.sh when unset.
#
# Exit 0: `# noqa` survived (fix in place), or an explicit SKIP condition.
# Exit 1: `# noqa` was stripped (reproduction of the bug).

set -euo pipefail

if [ -z "${HOOK_PATH:-}" ] && [ -f "${HOME:-}/.claude/hooks/format-on-edit.sh" ]; then
	HOOK_PATH="$HOME/.claude/hooks/format-on-edit.sh"
fi
if [ -z "${HOOK_PATH:-}" ]; then
	echo "SKIP: HOOK_PATH not set and default hook absent"
	exit 0
fi

if [ ! -f "$HOOK_PATH" ]; then
	echo "SKIP: HOOK_PATH does not point to an existing file: $HOOK_PATH"
	exit 0
fi

if ! command -v ruff >/dev/null 2>&1; then
	echo "SKIP: ruff is not installed"
	exit 0
fi

RUFF_VERSION="$(ruff --version 2>/dev/null || echo unknown)"

SCRATCH="$(mktemp -d)"
# shellcheck disable=SC2329  # invoked indirectly via trap cleanup EXIT
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT

cat >"$SCRATCH/ruff.toml" <<'EOF'
select = ["RUF100"]
EOF

TARGET="$SCRATCH/probe.py"
cat >"$TARGET" <<'EOF'
x = 1  # noqa
EOF

INPUT_JSON=$(printf '{"tool_input":{"file_path":"%s"}}' "$TARGET")

echo "$INPUT_JSON" | bash "$HOOK_PATH" >/dev/null 2>&1 || true

if grep -q '# noqa' "$TARGET"; then
	echo "SURVIVED: # noqa intact after hook run ($RUFF_VERSION)"
	exit 0
else
	echo "STRIPPED: # noqa removed by hook run ($RUFF_VERSION)"
	exit 1
fi
