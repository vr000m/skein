#!/usr/bin/env bash
# Verify the bundled auto-fix pipeline stays byte-identical to canonical
# scripts/ across every skill mirror, the bundle step is idempotent, and a
# bundled lib resolves its allowlist to the bundled copy (not a flattened
# path). The canonical source of the bundle map is scripts/bundle-appliers.sh;
# keep SHARED / applier_for in sync with it.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$ROOT_DIR/scripts"

# shellcheck source=scripts/lib/bundle-map.sh
. "$ROOT_DIR/scripts/lib/bundle-map.sh"

MIRRORS=(plugins/skein plugins/skein-codex)

pass_count=0
fail_count=0

fail() {
	echo "FAIL: $1"
	fail_count=$((fail_count + 1))
}

pass() {
	echo "PASS: $1"
	pass_count=$((pass_count + 1))
}

# --- 1. Idempotency: re-running the bundler against an in-sync tree no-ops ---
if command -v git >/dev/null 2>&1 && git -C "$ROOT_DIR" rev-parse >/dev/null 2>&1; then
	bash "$SRC/bundle-appliers.sh" >/dev/null
	if git -C "$ROOT_DIR" diff --quiet -- 'plugins/skein/skills/*/scripts' 'plugins/skein-codex/skills/*/scripts'; then
		pass "idempotency (re-bundle produced no diff)"
	else
		fail "idempotency (re-bundle changed the working tree; canonical edits not committed?)"
	fi
else
	echo "SKIP: idempotency (not a git work tree)"
fi

# --- 2. Byte-identity: canonical vs every bundled copy, all mirrors ---------
for skill in "${BUNDLE_SKILLS[@]}"; do
	applier="$(bundle_applier_for "$skill")"
	files=("${BUNDLE_SHARED[@]}" "$applier")
	# Per-skill extras (review-plan's marker.py + write-review-marker.py) are
	# bundled alongside the shared pipeline; include them so byte-identity is
	# checked and the stale-leftover guard does not flag them as unexpected.
	while IFS= read -r extra; do
		[[ -n "$extra" ]] && files+=("$extra")
	done < <(bundle_extra_for "$skill")
	for mirror in "${MIRRORS[@]}"; do
		dest="$ROOT_DIR/$mirror/skills/$skill/scripts"
		for f in "${files[@]}"; do
			if [[ ! -f "$dest/$f" ]]; then
				fail "missing bundled $mirror/skills/$skill/scripts/$f"
			elif ! cmp -s "$SRC/$f" "$dest/$f"; then
				fail "drift $mirror/skills/$skill/scripts/$f != canonical scripts/$f"
			else
				pass "byte-identical $mirror/skills/$skill/scripts/$f"
			fi
		done
		# No extra files beyond the declared set (stale-leftover guard).
		while IFS= read -r found; do
			rel="${found#"$dest"/}"
			declared=0
			for f in "${files[@]}"; do
				[[ "$rel" == "$f" ]] && declared=1 && break
			done
			[[ "$declared" -eq 0 ]] && fail "unexpected bundled file $mirror/skills/$skill/scripts/$rel"
			# Exclude __pycache__: importing a bundled .py entrypoint writes
			# transient, gitignored .pyc files into the bundle dir; they are
			# not part of the declared set and must not read as drift.
		done < <(find "$dest" -type f -not -path '*/__pycache__/*' 2>/dev/null)
	done
done

# --- 3. Drift-injection: prove the comparison detects a mutated copy --------
drift_tmp="$(mktemp -d)"
trap 'rm -rf "$drift_tmp"' EXIT
printf 'canonical bundle payload\n' >"$drift_tmp/canonical"
printf 'canonical bundle payload\n# injected drift\n' >"$drift_tmp/mutated"
if cmp -s "$drift_tmp/canonical" "$drift_tmp/mutated"; then
	fail "drift-injection (cmp did not detect a mutated copy)"
else
	pass "drift-injection (cmp detects mutation)"
fi

# --- 4. Lib-resolution: bundled lib resolves allowlist to the bundled copy --
for mirror in "${MIRRORS[@]}"; do
	for skill in "${BUNDLE_SKILLS[@]}"; do
		lib="$ROOT_DIR/$mirror/skills/$skill/scripts/lib/auto-fix-common.sh"
		expected="$ROOT_DIR/$mirror/skills/$skill/scripts/auto-fix-allowlist.json"
		if [[ ! -f "$lib" ]]; then
			fail "lib-resolution (missing bundled lib for $mirror/$skill)"
			continue
		fi
		resolved="$(bash -c 'source "$1"; printf "%s\n" "$AF_ALLOWLIST_PATH"' _ "$lib")"
		if [[ "$resolved" == "$expected" ]]; then
			pass "lib-resolution $mirror/$skill (allowlist -> bundled copy)"
		else
			fail "lib-resolution $mirror/$skill (resolved $resolved, expected $expected)"
		fi
	done
done

# --- 5. Skill-identity pin: apply-auto-fix-code.sh's hardcoded SKILL --------
# review-gauntlet has no first-class identity in the auto-fix subsystem — it
# masquerades as `--skill deep-review` (see run-gate.sh route) to match this
# hardcoded value, so it silently inherits deep-review's allowlist. Pin the
# value here so a future change to it fails loudly instead of silently
# shifting review-gauntlet's (and review-plan's) apply policy underneath them.
if grep -qx 'SKILL="deep-review"' "$SRC/apply-auto-fix-code.sh"; then
	pass "skill-identity pin: scripts/apply-auto-fix-code.sh hardcodes SKILL=\"deep-review\""
else
	fail "skill-identity pin: scripts/apply-auto-fix-code.sh no longer hardcodes SKILL=\"deep-review\" — review-gauntlet's run-gate.sh route (--skill deep-review) and review-plan's applier invocation both assume this value"
fi

echo ""
echo "Summary: $pass_count passed, $fail_count failed"
# Non-vacuous-pass guard: if the bundle glob matched zero files we would exit 0
# with nothing checked. Require at least one byte-identity pass.
if [[ "$pass_count" -eq 0 ]]; then
	echo "FAIL: vacuous pass — no bundled files were checked (layout drift?)"
	exit 1
fi
[[ "$fail_count" -eq 0 ]]
