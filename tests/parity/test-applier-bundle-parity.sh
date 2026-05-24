#!/usr/bin/env bash
# Verify the bundled auto-fix pipeline stays byte-identical to canonical
# scripts/ across every skill mirror, the bundle step is idempotent, and a
# bundled lib resolves its allowlist to the bundled copy (not a flattened
# path). The canonical source of the bundle map is scripts/bundle-appliers.sh;
# keep SHARED / applier_for in sync with it.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$ROOT_DIR/scripts"

SHARED=(
	reconcile-findings.sh
	audit-auto-fix-eligibility.sh
	render-reconciled-report.sh
	plan-scope-detect.sh
	auto-fix-allowlist.json
	lib/auto-fix-common.sh
)

MIRRORS=(.claude .codex)
SKILLS=(deep-review review-plan)

applier_for() {
	case "$1" in
	deep-review) printf 'apply-auto-fix-code.sh\n' ;;
	review-plan) printf 'apply-auto-fix-plan.sh\n' ;;
	*) return 1 ;;
	esac
}

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

# --- 1. Byte-identity: canonical vs every bundled copy, all mirrors ---------
for skill in "${SKILLS[@]}"; do
	applier="$(applier_for "$skill")"
	files=("${SHARED[@]}" "$applier")
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
		done < <(find "$dest" -type f 2>/dev/null)
	done
done

# --- 2. Drift-injection: prove the comparison detects a mutated copy --------
drift_tmp="$(mktemp -d)"
trap 'rm -rf "$drift_tmp"' EXIT
cp "$SRC/reconcile-findings.sh" "$drift_tmp/canonical"
cp "$SRC/reconcile-findings.sh" "$drift_tmp/mutated"
printf '\n# injected drift\n' >>"$drift_tmp/mutated"
if cmp -s "$drift_tmp/canonical" "$drift_tmp/mutated"; then
	fail "drift-injection (cmp did not detect a mutated copy)"
else
	pass "drift-injection (cmp detects mutation)"
fi

# --- 3. Idempotency: re-running the bundler against an in-sync tree no-ops ---
if command -v git >/dev/null 2>&1 && git -C "$ROOT_DIR" rev-parse >/dev/null 2>&1; then
	bash "$SRC/bundle-appliers.sh" >/dev/null
	if git -C "$ROOT_DIR" diff --quiet -- '.claude/skills/*/scripts' '.codex/skills/*/scripts'; then
		pass "idempotency (re-bundle produced no diff)"
	else
		fail "idempotency (re-bundle changed the working tree; canonical edits not committed?)"
	fi
else
	echo "SKIP: idempotency (not a git work tree)"
fi

# --- 4. Lib-resolution: bundled lib resolves allowlist to the bundled copy --
for skill in "${SKILLS[@]}"; do
	lib="$ROOT_DIR/.claude/skills/$skill/scripts/lib/auto-fix-common.sh"
	expected="$ROOT_DIR/.claude/skills/$skill/scripts/auto-fix-allowlist.json"
	if [[ ! -f "$lib" ]]; then
		fail "lib-resolution (missing bundled lib for $skill)"
		continue
	fi
	resolved="$(bash -c 'source "$1"; printf "%s\n" "$AF_ALLOWLIST_PATH"' _ "$lib")"
	if [[ "$resolved" == "$expected" ]]; then
		pass "lib-resolution $skill (allowlist -> bundled copy)"
	else
		fail "lib-resolution $skill (resolved $resolved, expected $expected)"
	fi
done

echo ""
echo "Summary: $pass_count passed, $fail_count failed"
[[ "$fail_count" -eq 0 ]]
