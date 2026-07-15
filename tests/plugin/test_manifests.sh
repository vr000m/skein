#!/usr/bin/env bash
# Phase 2 acceptance test: assert the four plugin/marketplace manifests exist,
# are valid JSON, declare the expected `skein` plugin name, and (Codex side)
# carry the full interface.* field set per the plan. Per Phase 1 findings,
# `codex plugin validate` does not exist, so this script validates with `jq`
# alone — it does not shell out to the Codex CLI.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

CLAUDE_MARKETPLACE=".claude-plugin/marketplace.json"
CLAUDE_PLUGIN="plugins/skein/.claude-plugin/plugin.json"
CODEX_MARKETPLACE=".agents/plugins/marketplace.json"
CODEX_PLUGIN="plugins/skein-codex/.codex-plugin/plugin.json"

MANIFESTS=(
	"$CLAUDE_MARKETPLACE"
	"$CLAUDE_PLUGIN"
	"$CODEX_MARKETPLACE"
	"$CODEX_PLUGIN"
)

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq is required for this test"

# --- 1. Each manifest exists and parses as JSON ----------------------------
for manifest in "${MANIFESTS[@]}"; do
	if [[ ! -f "$manifest" ]]; then
		fail "missing manifest: $manifest"
	fi
	if ! jq empty "$manifest" >/dev/null 2>&1; then
		fail "invalid JSON: $manifest"
	fi
	echo "ok: $manifest exists and is valid JSON"
done

# --- 2. Plugin manifests declare name == "skein" ---------------------------
for plugin_manifest in "$CLAUDE_PLUGIN" "$CODEX_PLUGIN"; do
	name="$(jq -r '.name // ""' "$plugin_manifest")"
	if [[ "$name" != "skein" ]]; then
		fail "$plugin_manifest: expected .name == \"skein\", got \"$name\""
	fi
	echo "ok: $plugin_manifest declares name=skein"
done

# --- 3a. Claude marketplace references the skein plugin --------------------
claude_entry="$(jq -r '
	[.plugins[]? | select(.name == "skein")] | length
' "$CLAUDE_MARKETPLACE")"
if [[ "$claude_entry" != "1" ]]; then
	fail "$CLAUDE_MARKETPLACE: expected exactly one .plugins[] entry with name=skein, got $claude_entry"
fi
claude_source="$(jq -r '
	[.plugins[]? | select(.name == "skein") | (.source // "")][0] // ""
' "$CLAUDE_MARKETPLACE")"
case "$claude_source" in
	*"./plugins/skein"*) ;;
	*) fail "$CLAUDE_MARKETPLACE: skein entry source must contain ./plugins/skein, got \"$claude_source\"" ;;
esac
echo "ok: $CLAUDE_MARKETPLACE references skein at ./plugins/skein"

# --- 3b. Codex marketplace references the skein plugin --------------------
codex_entry_count="$(jq -r '
	[.plugins[]? | select(.name == "skein")] | length
' "$CODEX_MARKETPLACE")"
if [[ "$codex_entry_count" != "1" ]]; then
	fail "$CODEX_MARKETPLACE: expected exactly one .plugins[] entry with name=skein, got $codex_entry_count"
fi
codex_source_path="$(jq -r '
	[.plugins[]? | select(.name == "skein") | (.source.path // "")][0] // ""
' "$CODEX_MARKETPLACE")"
if [[ "$codex_source_path" != "./plugins/skein-codex" ]]; then
	fail "$CODEX_MARKETPLACE: skein entry .source.path must be ./plugins/skein-codex, got \"$codex_source_path\""
fi
echo "ok: $CODEX_MARKETPLACE references skein at ./plugins/skein-codex"

# --- 4. The two marketplace files live at distinct canonical paths --------
if [[ "$CLAUDE_MARKETPLACE" == "$CODEX_MARKETPLACE" ]]; then
	fail "marketplace paths collide: $CLAUDE_MARKETPLACE"
fi
[[ -f "$CLAUDE_MARKETPLACE" ]] || fail "missing $CLAUDE_MARKETPLACE"
[[ -f "$CODEX_MARKETPLACE" ]] || fail "missing $CODEX_MARKETPLACE"
echo "ok: marketplace files live at distinct canonical paths"

# --- 5. Codex policy.installation is one of the allowed enum values -------
codex_installation="$(jq -r '
	[.plugins[]? | select(.name == "skein") | (.policy.installation // "")][0] // ""
' "$CODEX_MARKETPLACE")"
case "$codex_installation" in
	NOT_AVAILABLE|AVAILABLE|INSTALLED_BY_DEFAULT) ;;
	*) fail "$CODEX_MARKETPLACE: policy.installation must be NOT_AVAILABLE|AVAILABLE|INSTALLED_BY_DEFAULT, got \"$codex_installation\"" ;;
esac
echo "ok: $CODEX_MARKETPLACE policy.installation = $codex_installation"

# --- 6. Codex plugin manifest carries required interface.* + skills fields -
REQUIRED_INTERFACE_FIELDS=(
	displayName
	shortDescription
	longDescription
	developerName
	category
	capabilities
	defaultPrompt
)

for field in "${REQUIRED_INTERFACE_FIELDS[@]}"; do
	# Use `has` + non-empty check via jq. `null` and "" both fail.
	present="$(jq --arg f "$field" '
		(.interface // {}) | has($f) and (.[$f] != null) and (.[$f] != "")
	' "$CODEX_PLUGIN")"
	if [[ "$present" != "true" ]]; then
		fail "$CODEX_PLUGIN: interface.$field must be present and non-empty"
	fi
	echo "ok: $CODEX_PLUGIN interface.$field present"
done

# Codex-only: Codex's plugin schema requires an explicit `skills` pointer.
# Claude Code auto-discovers skills inside the plugin's `skills/` directory
# without an explicit field, so $CLAUDE_PLUGIN is intentionally not checked
# here (verified via Phase 1 spike + Phase 4 live install).
skills_value="$(jq -r '.skills // ""' "$CODEX_PLUGIN")"
if [[ "$skills_value" != "./skills/" ]]; then
	fail "$CODEX_PLUGIN: top-level .skills must equal \"./skills/\", got \"$skills_value\""
fi
echo "ok: $CODEX_PLUGIN .skills = ./skills/"

# Skill-count invariant: both plugin halves must ship the same 14 managed
# skills (one directory per skill under skills/). This is a structural
# floor — it does not verify the plugin actually loads under the harness
# (that's a manual smoke step), but it catches a missing or extra skill
# dir at commit time.
EXPECTED_SKILL_COUNT=14
claude_skill_count=$(find "plugins/skein/skills" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
codex_skill_count=$(find "plugins/skein-codex/skills" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
if [[ "$claude_skill_count" != "$EXPECTED_SKILL_COUNT" ]]; then
	fail "plugins/skein/skills/ has $claude_skill_count entries, expected $EXPECTED_SKILL_COUNT"
fi
if [[ "$codex_skill_count" != "$EXPECTED_SKILL_COUNT" ]]; then
	fail "plugins/skein-codex/skills/ has $codex_skill_count entries, expected $EXPECTED_SKILL_COUNT"
fi
echo "ok: both plugin halves expose $EXPECTED_SKILL_COUNT skill directories"

echo "test_manifests.sh: all assertions passed"
