#!/usr/bin/env bash
# Guard that none of the skill's markdown files invoke other agent-spawning
# skills. Catches any mention of /deep-review, /fan-out, or /review-plan used
# as an action. A mention is allowed if it is wrapped in backticks (a code
# reference) OR the line also contains a negation word (not / never / NOT).
#
# Exits 0 when clean, 1 when any disallowed mention is found.

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"

FORBIDDEN='/(deep-review|fan-out|review-plan|conduct)'

fail=0

while IFS= read -r -d '' file; do
    while IFS= read -r match; do
        # Strip "file:line:" prefix left by grep -n -H.
        line_content="${match#*:*:}"

        # Allow if token is inside backticks, e.g. `/review-plan`.
        if [[ "$line_content" =~ \`/((deep-review)|(fan-out)|(review-plan)|(conduct))\` ]]; then
            continue
        fi

        # Allow path-form usage like ".claude/skills/conduct/..." — the slash
        # following the token means it's a directory path, not an invocation.
        if [[ "$line_content" =~ /((deep-review)|(fan-out)|(review-plan)|(conduct))/ ]]; then
            continue
        fi

        # Allow instructional prose telling the *user* to run the other skill,
        # e.g. `Run: /review-plan <plan-path>` emitted at preflight failure.
        if [[ "$line_content" =~ Run:[[:space:]]*/((deep-review)|(fan-out)|(review-plan)|(conduct)) ]]; then
            continue
        fi

        # Allow if line also contains a negation indicator.
        if [[ "$line_content" =~ [^A-Za-z](not|never|NOT|Not)[^A-Za-z] ]]; then
            continue
        fi

        echo "DISALLOWED MENTION: $match" >&2
        fail=1
    done < <(grep -H -n -E "$FORBIDDEN" "$file" || true)
done < <(find "$SKILL_DIR" -type f -name '*.md' -print0)

if [[ $fail -ne 0 ]]; then
    echo "" >&2
    echo "Lines above mention /deep-review, /fan-out, or /review-plan in a" >&2
    echo "way that reads as an invocation. Reword to wrap the token in" >&2
    echo "backticks or explicitly negate the action." >&2
    exit 1
fi

echo "OK: no disallowed skill-spawn mentions in $SKILL_DIR"
exit 0
