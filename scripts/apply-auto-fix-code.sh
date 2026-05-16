#!/usr/bin/env bash
# apply-auto-fix-code.sh — `/deep-review` trivial-tier auto-fix applier.
#
# Usage:
#   scripts/apply-auto-fix-code.sh --test-cmd <cmd> <envelope.json>
#   AUTO_FIX_TEST_CMD=<cmd> scripts/apply-auto-fix-code.sh <envelope.json>
#
# Reads a reconciled v2 finding envelope annotated with `auto_fix_status`
# (typically produced by `scripts/audit-auto-fix-eligibility.sh`). For each
# finding whose status is `would_apply` AND whose kind is in the
# `deep-review` allowlist, the applier:
#
#   1. Re-verifies eligibility (kind, multi-line guard, unused_var test-file
#      reads). Mismatch → drops to surfaced with a specific reject status.
#   2. Asserts the file:line still byte-matches `auto_fix.before` (drift).
#   3. Saves a `git hash-object -w` blob of every touched path (rollback).
#   4. Rewrites the line `before` → `after` in place.
#   5. Stages the file and runs the explicit test command exactly once.
#   6. On pass: commits with subject `auto-fix(deep-review): <kind> at
#      <file>:<line>` and trailer `Auto-Fixed-By: deep-review`.
#   7. On fail: restores touched paths from the saved blob, unstages them,
#      leaves HEAD unchanged, records `status: test_failed` with the test
#      output truncated to the last 2000 bytes.
#
# Writes a manifest at `.deep-review/auto-fix-<unix>.json` listing every
# attempted fix.
#
# Dependencies: git, jq, awk.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/lib/auto-fix-common.sh disable=SC1091
. "$SCRIPT_ROOT/scripts/lib/auto-fix-common.sh"
# Manifest + working tree live under the caller's repository, not the
# scripts repo. This matters when the applier is invoked from a sibling
# checkout (or from a test scratch repo). The lib owns AF_ALLOWLIST_PATH;
# the caller owns AF_COMMON_ROOT (must be set before af_manifest_init).
if WORKTREE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
	ROOT_DIR="$WORKTREE_ROOT"
else
	ROOT_DIR="$(pwd)"
fi
# shellcheck disable=SC2034  # required by lib's af_manifest_init
AF_COMMON_ROOT="$ROOT_DIR"

SKILL="deep-review"

usage() {
	cat >&2 <<'EOF'
usage: scripts/apply-auto-fix-code.sh --test-cmd <cmd> <envelope.json>
       AUTO_FIX_TEST_CMD=<cmd> scripts/apply-auto-fix-code.sh <envelope.json>
EOF
}

TEST_CMD="${AUTO_FIX_TEST_CMD:-}"
ENVELOPE_PATH=""

while [[ $# -gt 0 ]]; do
	case "$1" in
	--test-cmd)
		shift
		[[ $# -gt 0 ]] || {
			usage
			exit 2
		}
		TEST_CMD="$1"
		;;
	--help | -h)
		usage
		exit 0
		;;
	-)
		ENVELOPE_PATH="-"
		;;
	*)
		if [[ -n "$ENVELOPE_PATH" && "$ENVELOPE_PATH" != "-" ]]; then
			echo "apply-auto-fix-code: multiple envelope paths" >&2
			exit 2
		fi
		ENVELOPE_PATH="$1"
		;;
	esac
	shift
done

if [[ -z "$TEST_CMD" ]]; then
	echo "apply-auto-fix-code: --test-cmd <cmd> (or AUTO_FIX_TEST_CMD env) is required before any edit" >&2
	exit 2
fi

if [[ -z "$ENVELOPE_PATH" ]]; then
	usage
	exit 2
fi

af_have_jq

if [[ "$ENVELOPE_PATH" == "-" ]]; then
	envelope="$(cat)"
else
	envelope="$(cat "$ENVELOPE_PATH")"
fi

schema_version="$(printf '%s' "$envelope" | jq -r '.schema_version // empty')"
if [[ "$schema_version" != "2" ]]; then
	echo "apply-auto-fix-code: schema_version mismatch (got ${schema_version:-missing}, expected 2)" >&2
	exit 2
fi

af_manifest_init "$SKILL"
# Acquire an advisory lock via atomic mkdir so concurrent applier runs in
# the same repo serialise. Without this, two invocations can interleave at
# the index/HEAD level, producing a commit whose tree no longer matches
# what the test command saw. The lock dir is removed on EXIT alongside the
# manifest flush.
AF_LOCKDIR="$ROOT_DIR/.git/auto-fix-code.lock"
if ! mkdir "$AF_LOCKDIR" 2>/dev/null; then
	echo "apply-auto-fix-code: another applier appears to be running (lock at $AF_LOCKDIR); refusing to start" >&2
	exit 8
fi
# Ensure the manifest is always flushed and the lock is always released,
# even if `set -euo pipefail` aborts us mid-batch (awk exit code, mktemp
# failure, git add failure).
trap 'af_manifest_write; rmdir "$AF_LOCKDIR" 2>/dev/null || true' EXIT

# Truncate captured test output to last 2000 bytes.
#
# Note: the captured tail lands in the manifest JSON as the `evidence`
# field on test_failed entries. Operators should treat the manifest as
# potentially containing whatever the test command printed — including
# environment-derived tokens if the suite logs them. .deep-review/ is
# gitignored so the manifest never enters the commit, but the file
# persists on disk until manually cleared.
truncate_tail() {
	local raw="$1"
	local size
	size="${#raw}"
	if ((size > 2000)); then
		printf '...%s' "${raw: -2000}"
	else
		printf '%s' "$raw"
	fi
}

# Resolve a finding-supplied path against ROOT_DIR with a containment guard.
# Rejects absolute paths and any `..` segment to prevent semi-trusted lens
# output from directing writes outside the repo. Symlink-following is handled
# separately (af_save_blob / af_apply_replacement guard against `-L`).
resolve_path() {
	local p="$1"
	if [[ -z "$p" || "$p" = /* ]]; then
		return 1
	fi
	if [[ "$p" =~ (^|/)\.\.(/|$) ]]; then
		return 1
	fi
	printf '%s\n' "$ROOT_DIR/$p"
}

# Iterate findings carrying auto_fix_status: would_apply.
findings_json="$(printf '%s' "$envelope" | jq -c '.findings[]? | select(.auto_fix_status == "would_apply" and (has("auto_fix")))')"

if [[ -z "$findings_json" ]]; then
	af_manifest_write
	echo "apply-auto-fix-code: no would_apply findings; manifest at $(af_manifest_path)" >&2
	exit 0
fi

while IFS= read -r finding; do
	[[ -n "$finding" ]] || continue
	kind="$(printf '%s' "$finding" | jq -r '.auto_fix.kind')"
	before="$(printf '%s' "$finding" | jq -r '.auto_fix.before')"
	after="$(printf '%s' "$finding" | jq -r '.auto_fix.after')"
	file="$(printf '%s' "$finding" | jq -r '.file // ""')"
	line="$(printf '%s' "$finding" | jq -r '(.line // "") | tostring')"

	if ! abs_path="$(resolve_path "$file")"; then
		af_manifest_record "$kind" "$file" "$line" "rejected_path" "" ""
		continue
	fi

	# Re-check allowlist (defence in depth — the auditor may have used a
	# different allowlist version).
	if ! af_allowlist_contains "$SKILL" "$kind"; then
		af_manifest_record "$kind" "$file" "$line" "rejected_kind" "" ""
		continue
	fi

	# mechanical_replace: reject multi-line before.
	stripped_before="${before%$'\n'}"
	if [[ "$kind" == "mechanical_replace" && "$stripped_before" == *$'\n'* ]]; then
		af_manifest_record "$kind" "$file" "$line" "rejected_multiline" "" ""
		continue
	fi

	# unused_var: re-verify by counting non-test references.
	if [[ "$kind" == "unused_var" ]]; then
		# Extract var name from `before`. Strategy: take the bareword after
		# common declaration keywords (`let`, `const`, `var`, `my`), or fall
		# back to the LHS of an `=` assignment. If neither matches, treat as
		# rejected_revar to avoid an unsafe apply.
		var_name=""
		# shellcheck disable=SC2001
		stripped_line="$(printf '%s' "$stripped_before" | sed -e 's/^[[:space:]]*//')"
		if [[ "$stripped_line" =~ ^(let|const|var|my)[[:space:]]+([A-Za-z_][A-Za-z0-9_]*) ]]; then
			var_name="${BASH_REMATCH[2]}"
		elif [[ "$stripped_line" =~ ^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*[:=] ]]; then
			var_name="${BASH_REMATCH[1]}"
		fi
		if [[ -z "$var_name" ]]; then
			af_manifest_record "$kind" "$file" "$line" "rejected_revar" "" ""
			continue
		fi
		# Count references in non-test files. Anything under a tests/ tree at
		# any depth, or with a test_/_test stem, is excluded. Use the
		# `:(exclude)…` pathspec form rather than `:!…` glob: the latter
		# relies on `*` not crossing `/`, which means a top-level
		# tests/test_a.py only excludes by accident of intra-segment
		# matching. The explicit form below is depth-agnostic.
		refs="$(git -C "$ROOT_DIR" grep -nIw -- "$var_name" \
			':(exclude)tests/' \
			':(exclude)**/tests/' \
			':(exclude)**/test_*' \
			':(exclude)**/*_test*' \
			':(exclude)test_*' \
			':(exclude)*_test*' \
			2>/dev/null || true)"
		# Drop the declaration line itself from the count. Match a literal
		# `<file>:<line>:` prefix rather than splitting on `:` — file paths
		# may legitimately contain a colon, which would defeat split-based
		# field comparison and inflate the ref count.
		ref_count="$(printf '%s\n' "$refs" |
			awk -v prefix="$file:$line:" 'NF { if (index($0, prefix) == 1) next; print }' |
			grep -c '^' || true)"
		if [[ "$ref_count" -gt 0 ]]; then
			af_manifest_record "$kind" "$file" "$line" "rejected_revar" "" ""
			continue
		fi
	fi

	if [[ ! -f "$abs_path" ]]; then
		af_manifest_record "$kind" "$file" "$line" "drift" "" ""
		continue
	fi

	# Multi-line aware drift + apply: extract N lines starting at `line` and
	# compare them to the (newline-stripped) `before` block. The applier
	# already rejected multi-line for `mechanical_replace` above.
	if [[ "$stripped_before" == *$'\n'* ]]; then
		nlines="$(printf '%s\n' "$stripped_before" | grep -c '^' || true)"
	else
		nlines=1
	fi
	actual="$(awk -v start="$line" -v n="$nlines" '
		NR >= start && NR < start + n {
			if (out != "") out = out "\n"
			out = out $0
		}
		END { print out }
	' "$abs_path" 2>/dev/null || true)"
	if [[ "$actual" != "$stripped_before" ]]; then
		af_manifest_record "$kind" "$file" "$line" "drift" "" ""
		continue
	fi

	# Save the pre-apply blob (rollback handle).
	before_sha="$(af_save_blob "$abs_path")"

	stripped_after="${after%$'\n'}"
	tmp_apply="$(mktemp)"
	# When `after` is empty, delete the matched line(s) entirely. When it
	# is non-empty, emit the replacement once in place of the match block.
	# Capture awk's exit code explicitly: under `set -e` an `exit 5` from
	# the inner program (target line past EOF — race between drift check
	# and apply) would otherwise abort the whole batch before we could
	# restore from the saved blob.
	apply_rc=0
	if [[ -z "$stripped_after" && -z "$after" ]]; then
		awk -v start="$line" -v n="$nlines" '
			BEGIN { printed = 0 }
			NR >= start && NR < start + n { printed = 1; next }
			{ print }
			END { if (!printed) exit 5 }
		' "$abs_path" >"$tmp_apply" || apply_rc=$?
	else
		AF_REPL="$stripped_after" awk -v start="$line" -v n="$nlines" '
			BEGIN { printed = 0; repl = ENVIRON["AF_REPL"] }
			NR == start { print repl; printed = 1; next }
			NR > start && NR < start + n { next }
			{ print }
			END { if (!printed) exit 5 }
		' "$abs_path" >"$tmp_apply" || apply_rc=$?
	fi
	if [[ "$apply_rc" -ne 0 ]] || [[ ! -s "$tmp_apply" && "${stripped_after:-}" != "" ]]; then
		rm -f "$tmp_apply"
		af_restore_blob "$abs_path" "$before_sha"
		af_manifest_record "$kind" "$file" "$line" "drift" "" "$before_sha"
		continue
	fi
	mv "$tmp_apply" "$abs_path"

	# Stage the file. Use `git add` so the test command sees a coherent index
	# and the upcoming commit picks up exactly this change.
	git -C "$ROOT_DIR" add -- "$abs_path"

	# Run the test command exactly once. No retry.
	test_output_file="$(mktemp)"
	test_rc=0
	(
		cd "$ROOT_DIR"
		bash -c "$TEST_CMD"
	) >"$test_output_file" 2>&1 || test_rc=$?

	if [[ "$test_rc" -ne 0 ]]; then
		# Restore from blob, unstage, leave HEAD alone, record test_failed.
		af_restore_blob "$abs_path" "$before_sha"
		evidence="$(truncate_tail "$(cat "$test_output_file")")"
		rm -f "$test_output_file"
		af_manifest_record "$kind" "$file" "$line" "test_failed" "" "$before_sha" "$evidence"
		continue
	fi
	rm -f "$test_output_file"

	# Commit the fix with the canonical subject and trailer.
	subject="auto-fix($SKILL): $kind at $file:$line"
	trailer="Auto-Fixed-By: $SKILL"
	commit_sha="$(af_commit_one "$subject" "$trailer")"
	af_manifest_record "$kind" "$file" "$line" "applied" "$commit_sha" "$before_sha"
done <<<"$findings_json"

af_manifest_write
echo "apply-auto-fix-code: manifest written to $(af_manifest_path)" >&2
