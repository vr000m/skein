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

# --- 7. Both plugin manifests carry the same version string ----------------
claude_version="$(jq -r '.version // ""' "$CLAUDE_PLUGIN")"
codex_version="$(jq -r '.version // ""' "$CODEX_PLUGIN")"
if [[ -z "$claude_version" ]]; then
	fail "$CLAUDE_PLUGIN: .version is missing or empty"
fi
if [[ -z "$codex_version" ]]; then
	fail "$CODEX_PLUGIN: .version is missing or empty"
fi
if [[ "$claude_version" != "$codex_version" ]]; then
	fail "manifest version mismatch: $CLAUDE_PLUGIN=$claude_version vs $CODEX_PLUGIN=$codex_version"
fi
echo "ok: $CLAUDE_PLUGIN and $CODEX_PLUGIN both declare version=$claude_version"

# --- 8. Every test-running justfile recipe is registered in AGENTS.md ------
# AGENTS.md's Commands block is this repo's runnable contract: there is no CI
# workflow, so a recipe that is not listed there is a suite nobody is told to
# run. `just lens-tests` sat unregistered for its whole life that way. This
# guard closes the class rather than the instance: any recipe whose body
# invokes a `tests/**/*.sh` file must appear as `just <recipe>` inside the
# ```bash fence under `## Commands`.
#
# RECIPE_REGISTRATION_ALLOWLIST exempts helper recipes that run test files but
# are not themselves an entry point a human is expected to invoke (e.g. a
# recipe that exists only to be called by another recipe). It is deliberately
# empty today: every current test-running recipe is a real entry point.
# Adding a name here is a claim that the recipe is not part of the contract —
# state why in a comment next to it.
RECIPE_REGISTRATION_ALLOWLIST=()

agents_commands_block="$(awk '
	/^## Commands$/ { in_section = 1; next }
	in_section && /^```/ { in_fence = !in_fence; if (!in_fence) exit; next }
	in_fence { print }
' AGENTS.md)"

if [[ -z "$agents_commands_block" ]]; then
	fail "AGENTS.md: could not locate a non-empty bash fence under '## Commands'"
fi

# Emit the name of every recipe whose body references a tests/*.sh file.
test_recipes="$(awk '
	/^[a-z][a-z0-9-]*:/ {
		recipe = $0
		sub(/:.*/, "", recipe)
		next
	}
	/^[^[:space:]]/ { recipe = "" }
	recipe != "" && /tests\/.*\.sh/ {
		if (!(recipe in seen)) { seen[recipe] = 1; print recipe }
	}
' justfile)"

if [[ -z "$test_recipes" ]]; then
	fail "justfile: found no recipe running a tests/**/*.sh file — the parser is broken, not the justfile"
fi

unregistered=""
while IFS= read -r recipe; do
	[[ -n "$recipe" ]] || continue
	allowlisted=0
	for allowed in ${RECIPE_REGISTRATION_ALLOWLIST[@]+"${RECIPE_REGISTRATION_ALLOWLIST[@]}"}; do
		if [[ "$recipe" == "$allowed" ]]; then
			allowlisted=1
			break
		fi
	done
	[[ "$allowlisted" -eq 1 ]] && continue
	if ! grep -qE "^just[[:space:]]+${recipe}([[:space:]]|$)" <<<"$agents_commands_block"; then
		unregistered="${unregistered}${unregistered:+, }${recipe}"
	fi
done <<<"$test_recipes"

if [[ -n "$unregistered" ]]; then
	fail "justfile recipes run tests but are not listed in AGENTS.md's Commands block: $unregistered"
fi
echo "ok: every test-running justfile recipe is registered in AGENTS.md"

# --- 9. Each gauntlet-tests member is glossed, not just named (r4 F13) -----
# AGENTS.md's Commands block is the runnable contract (see §8). A gloss that
# reads "... + gate-timeout + lens-budget + regression-stop + finding-key +
# status-row" registers the recipe but tells a reader nothing about what those
# five suites cover, so the contract names them without explaining them. Each
# must carry a short parenthetical gloss.
agents_gauntlet_line="$(grep -E '^just gauntlet-tests' AGENTS.md || true)"
if [[ -z "$agents_gauntlet_line" ]]; then
	fail "AGENTS.md: no 'just gauntlet-tests' line in the Commands block"
fi
for recipe_name in gate-timeout lens-budget regression-stop finding-key status-row; do
	if ! grep -qE "${recipe_name} \(" <<<"$agents_gauntlet_line"; then
		fail "AGENTS.md: gauntlet-tests member '$recipe_name' is named without a parenthetical gloss"
	fi
done
echo "ok: every gauntlet-tests member in AGENTS.md carries a gloss"

# --- 10. CHANGELOG names the units-file transport, not the argv flag (F4) ---
# The 0.6.0 entry still described the assigned-units list as the
# "--expected <lens:units,...>" flag. That flag is shell-substituted before
# the collector is entered, which is precisely why the documented transport
# became a units FILE. A changelog that names the retired form sends a reader
# to the transport the fix removed.
changelog_lens_entry="$(grep -F 'Disk-first streamed lens results' CHANGELOG.md || true)"
if [[ -z "$changelog_lens_entry" ]]; then
	fail "CHANGELOG.md: the disk-first lens-results entry is missing"
fi
if grep -qE -- '--expected <lens' <<<"$changelog_lens_entry"; then
	fail "CHANGELOG.md: the lens-results entry still names the retired '--expected <lens:units,...>' transport"
fi
if ! grep -qF -- '--expected-file' <<<"$changelog_lens_entry"; then
	fail "CHANGELOG.md: the lens-results entry does not name the --expected-file units-file transport"
fi
if ! grep -qE 'lenses/<run-?id>/expected\.json' <<<"$changelog_lens_entry"; then
	fail "CHANGELOG.md: the lens-results entry does not give the units-file path"
fi
echo "ok: CHANGELOG names the units-file transport and its path"

echo "test_manifests.sh: all assertions passed"
