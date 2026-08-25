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

# --- 6. Authored-lib mirror parity: review-gauntlet's lib/ scripts are hand- --
# maintained in both plugins (not canonical-bundled from scripts/), so byte-
# identity has to be checked mirror-to-mirror directly. run-gate.sh,
# convergence-ledger.sh, and gate-bounded.sh are documented as byte-identical
# across runtimes (gate-bounded.sh is harness-neutral: it has no
# runtime-specific anchor to resolve, so both copies are the same file);
# gauntlet-common.sh legitimately diverges (it resolves a runtime-specific
# anchor: ${CLAUDE_PLUGIN_ROOT} on Claude, $SKILL_DIR on Codex) so it is
# intentionally excluded from this check.
GAUNTLET_LIB_PARITY_FILES=(run-gate.sh convergence-ledger.sh gate-bounded.sh)
for f in "${GAUNTLET_LIB_PARITY_FILES[@]}"; do
	claude_f="$ROOT_DIR/plugins/skein/skills/review-gauntlet/lib/$f"
	codex_f="$ROOT_DIR/plugins/skein-codex/skills/review-gauntlet/lib/$f"
	if [[ ! -f "$claude_f" ]] || [[ ! -f "$codex_f" ]]; then
		fail "gauntlet lib mirror parity: missing $f in one or both plugins"
	elif ! cmp -s "$claude_f" "$codex_f"; then
		fail "gauntlet lib mirror parity: $f differs between plugins/skein and plugins/skein-codex"
	else
		pass "gauntlet lib mirror parity: $f byte-identical across plugins"
	fi
done

# ENUMERATION HALF (r2 finding #17). GAUNTLET_LIB_PARITY_FILES above is
# hand-maintained, so the byte-identity loop only covers files someone
# remembered to register: a future lib/*.sh would be exempt from mirror
# parity forever, silently. Walk the canonical lib/ and fail on any basename
# outside the declared set. `gauntlet-common.sh` is the one documented
# exclusion — it carries the harness-divergent path anchor
# (${CLAUDE_PLUGIN_ROOT} vs $SKILL_DIR), so it is deliberately NOT
# byte-identical across mirrors. Mirrors scripts/check-sync.sh's own
# stale-leftover guard in check_bundle_dir.
GAUNTLET_LIB_ANCHOR_DIVERGENT=(gauntlet-common.sh)
# PARITY_GAUNTLET_LIB_ROOT repoints ONLY §6's lib enumeration at a fixture
# tree. It is the minimum override needed to make this guard testable: there
# is no way to introduce a Codex-only lib file into the real repo just to
# assert it is caught, and overriding the whole ROOT_DIR would drag every
# other section of this suite into the fixture too. Unset in normal runs.
GAUNTLET_LIB_ROOT="${PARITY_GAUNTLET_LIB_ROOT:-$ROOT_DIR}"
GAUNTLET_LIB_CLAUDE_DIR="$GAUNTLET_LIB_ROOT/plugins/skein/skills/review-gauntlet/lib"
GAUNTLET_LIB_CODEX_DIR="$GAUNTLET_LIB_ROOT/plugins/skein-codex/skills/review-gauntlet/lib"

# G9: the enumeration is the UNION of both mirrors' lib/, not just the
# Claude side. Walking only the canonical tree left a hole the byte-identity
# loop above cannot cover: a lib/*.sh added SOLELY to the Codex mirror is not
# in GAUNTLET_LIB_PARITY_FILES (so it is never byte-compared) and never
# appeared in the enumeration (so it was never reported unregistered) — the
# guard passed vacuously on exactly the file it exists to catch. The
# byte-identity loop's "missing in one or both plugins" arm only fires for
# DECLARED files; the union enumeration is what routes an undeclared
# Codex-only file into any failure at all. scripts/check-sync.sh:60-61
# already runs check_bundle_dir against both paths — this follows it.
while IFS= read -r lib_base; do
	[[ -n "$lib_base" ]] || continue
	declared=0
	for d in "${GAUNTLET_LIB_PARITY_FILES[@]}" "${GAUNTLET_LIB_ANCHOR_DIVERGENT[@]}"; do
		[[ "$lib_base" == "$d" ]] && declared=1 && break
	done
	if [[ "$declared" -eq 0 ]]; then
		fail "gauntlet lib enumeration: $lib_base is not in GAUNTLET_LIB_PARITY_FILES (nor the documented anchor-divergent exclusion) -- register it or its mirror parity is never checked"
	else
		pass "gauntlet lib enumeration: $lib_base is registered"
	fi

	# Mirror-presence: a lib file in one mirror and not the other is a
	# parity failure in its own right, independent of registration.
	in_claude=0
	in_codex=0
	[[ -f "$GAUNTLET_LIB_CLAUDE_DIR/$lib_base" ]] && in_claude=1
	[[ -f "$GAUNTLET_LIB_CODEX_DIR/$lib_base" ]] && in_codex=1
	if [[ "$in_claude" -eq 1 && "$in_codex" -eq 1 ]]; then
		pass "gauntlet lib mirror presence: $lib_base exists in both mirrors"
	elif [[ "$in_claude" -eq 1 ]]; then
		fail "gauntlet lib mirror presence: $lib_base exists only in plugins/skein -- add it to plugins/skein-codex or remove it"
	else
		fail "gauntlet lib mirror presence: $lib_base exists only in plugins/skein-codex -- add it to plugins/skein or remove it"
	fi
done < <({
	find "$GAUNTLET_LIB_CLAUDE_DIR" -maxdepth 1 -type f -name '*.sh' 2>/dev/null
	find "$GAUNTLET_LIB_CODEX_DIR" -maxdepth 1 -type f -name '*.sh' 2>/dev/null
} | while IFS= read -r p; do basename "$p"; done | sort -u)

# ---------------------------------------------------------------------------
# (G9) Self-test: the union enumeration must actually catch a Codex-ONLY lib
# file. Before this fix the enumeration walked only plugins/skein, so such a
# file was neither byte-compared (not in GAUNTLET_LIB_PARITY_FILES) nor
# reported unregistered -- the guard passed vacuously on exactly the case it
# exists to catch.
#
# Run against a FIXTURE lib tree via PARITY_GAUNTLET_LIB_ROOT (there is no
# way to add a Codex-only lib file to the real repo just to assert it is
# caught), and only when this process is not itself the fixture run.
# ---------------------------------------------------------------------------
if [[ -z "${PARITY_GAUNTLET_LIB_ROOT:-}" ]]; then
	g9_fixture="$(mktemp -d)"
	mkdir -p "$g9_fixture/plugins/skein/skills/review-gauntlet/lib" \
		"$g9_fixture/plugins/skein-codex/skills/review-gauntlet/lib"
	for g9_f in "${GAUNTLET_LIB_PARITY_FILES[@]}" "${GAUNTLET_LIB_ANCHOR_DIVERGENT[@]}"; do
		printf '%s\n' '#!/usr/bin/env bash' >"$g9_fixture/plugins/skein/skills/review-gauntlet/lib/$g9_f"
		cp "$g9_fixture/plugins/skein/skills/review-gauntlet/lib/$g9_f" \
			"$g9_fixture/plugins/skein-codex/skills/review-gauntlet/lib/$g9_f"
	done
	# The orphan: present in the Codex mirror ONLY, and undeclared.
	printf '%s\n' '#!/usr/bin/env bash' >"$g9_fixture/plugins/skein-codex/skills/review-gauntlet/lib/orphan.sh"

	g9_rc=0
	g9_out="$(PARITY_GAUNTLET_LIB_ROOT="$g9_fixture" bash "${BASH_SOURCE[0]}" 2>&1)" || g9_rc=$?

	if [[ "$g9_rc" -ne 0 ]]; then
		pass "G9: a Codex-only lib file makes the enumeration fail (rc=$g9_rc)"
	else
		fail "G9: a Codex-only lib file must make the enumeration fail (got rc=0)"
	fi
	if printf '%s\n' "$g9_out" | grep -q 'orphan.sh'; then
		pass "G9: the failure names the offending Codex-only basename"
	else
		fail "G9: the failure does not name orphan.sh"
	fi
	if printf '%s\n' "$g9_out" | grep -q 'mirror presence: orphan.sh exists only in plugins/skein-codex'; then
		pass "G9: the Codex-only file is reported as a mirror-presence failure"
	else
		fail "G9: no mirror-presence failure was reported for orphan.sh"
	fi
	rm -rf "$g9_fixture"
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
