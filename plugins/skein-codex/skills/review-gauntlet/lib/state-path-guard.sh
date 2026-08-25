#!/usr/bin/env bash
# state-path-guard.sh — THE containment policy for every path the
# review-gauntlet skill writes into its own state tree (`.gauntlet/`, and any
# sibling repo-rooted location a gate is pointed at).
#
# Lives in review-gauntlet's lib/ dir in BOTH plugin mirrors, byte-identical
# (GAUNTLET_LIB_PARITY_FILES in tests/parity/test-applier-bundle-parity.sh).
# It has no harness-specific anchor to resolve — it is sourced by its siblings
# through `${BASH_SOURCE[0]%/*}`-style directory resolution, never through a
# plugin-root substitution — so both copies are the same file and stay that
# way.
#
# Source this file; it does not run on its own (no top-level side effects).
# Never uses `exit` — only `return` — since it runs inside the caller's shell.
#
# Provides:
#   gauntlet_assert_no_symlink <path> <label>
#     0 when <path> is safe to create/write, 1 with a diagnostic on stderr
#     otherwise. <label> prefixes the diagnostic so each caller keeps its own
#     wording (`convergence-ledger: …`, `gate_run_bounded: …`, `run-gate: …`).
#     The caller decides what to do with a refusal; this function never exits.
#
# WHY ONE FUNCTION AND NOT A COPY PER CALLER (round 6, F1/F2/F3). Round 5
# closed "gate-bounded.sh has no symlink guard" by writing a NEW, WEAKER copy
# of a walk that already existed twice in the tree: a leaf + immediate-parent
# test with no `..` rejection, versus convergence-ledger.sh's `..` rejection
# plus a two-pass in-worktree ancestor walk. Two writers into ONE state tree
# then applied TWO policies — and the weaker one covered the deeper path, so
# `.gauntlet -> /somewhere/else` was refused by the ledger and followed by the
# gate, which wrote its envelope and tool output outside the repo. The defect
# was never "the gate's walk is short"; it was that the walk was a
# copy-per-caller, so every new caller re-derived a policy and got it wrong.
# The policy now has exactly one owner, in a parity-enforced file.
#
# WHY NOT gauntlet-common.sh: it is the documented anchor-divergent EXCLUSION
# from mirror parity (it resolves a harness-specific plugin-root anchor, and
# the two mirrors spell that anchor differently on purpose), so a guard placed
# there is never byte-compared between
# the mirrors and can silently drift — which is the exact failure this file
# exists to end. WHY NOT scripts/lib/auto-fix-common.sh's af_assert_no_symlink:
# that file is not on the gauntlet's lib path, and bundling it in would drag
# the whole auto-fix surface into the gauntlet lib.
#
# `.gauntlet/` is gitignored (.gitignore:9), but a *tracked* symlink at that
# path still materialises on checkout, and `mkdir -p` follows it — so a
# malicious clone could point it outside the repo and have a state write land
# on an arbitrary user-writable file. Impact is bounded (the attacker chooses
# the directory, not the contents), but the asymmetry inside one change set —
# some state writes guarded, others not — is the actual defect.
#
# PARENT-WALK BOUND. Inside a git worktree the walk stops AT the worktree
# root — the root itself and everything above it is never `-L`-tested by the
# loop: that span is the whole reach of a checkout, and testing past it would
# reject legitimate paths under platform symlinks (macOS `/var` ->
# `/private/var`, `/tmp` -> `/private/tmp`) that have nothing to do with the
# repo. Outside a worktree only the path and its immediate parent are
# checked — the two positions the threat actually occupies — for the same
# reason.
#
# ANCESTORS THAT DO NOT EXIST YET ARE STILL WALKED. Callers guard and then
# `mkdir -p`, so the components `mkdir -p` is about to create are exactly the
# ones an attacker wants a symlink under. An ancestor that cannot be
# canonicalised is NOT evidence of safety: the walk continues upward with
# containment undecided until it reaches one that exists.
#
# RESIDUAL, documented rather than claimed away: the guard -> write (or
# guard -> mkdir) window is a TOCTOU. Closing it needs openat(O_NOFOLLOW),
# which portable bash lacks.
gauntlet_assert_no_symlink() {
	local path="$1" label="${2:-state-path-guard}"

	# Absolutise first. Everything below reasons about ANCESTORS, and a
	# relative path's ancestor chain terminates at "." rather than at the
	# filesystem root, so a relative spelling would silently shorten the
	# walk. Absolutising against $PWD resolves no component; a $PWD that is
	# itself a symlinked alias is fine here because pass 1 below
	# CANONICALISES each ancestor (`cd … && pwd -P`) and so still finds the
	# worktree root through the alias — and this guard's failure direction is
	# fail-CLOSED (a `-L` hit refuses loudly), unlike the lexical
	# prefix-matching in persist_path_is_inside_root, which needs both cwd
	# spellings because ITS failure direction is fail-open.
	[[ "$path" == /* ]] || path="$PWD/$path"

	# Then refuse any `..` component, before a single other check runs.
	#
	# This is not tidiness. Every check below is LEXICAL -- it looks at path
	# components without resolving them -- and lexical reasoning is unsound
	# the moment `..` is in play, because `..` does not mean "the parent
	# component" on disk: `$repo/link/../.gauntlet` with `link` a symlink is
	# NOT `$repo/.gauntlet`, it is a directory beside `link`'s TARGET,
	# somewhere else entirely. So a `..` lets a path re-enter the tree at a
	# position no component of its own spelling names, which is exactly what
	# an ancestor walk cannot see. Resolving it first is no fix either: the
	# resolution itself follows the symlink we are trying to catch.
	#
	# There is no legitimate caller that needs it -- every caller composes
	# its path from a repo root and a fixed subpath -- so the fail-closed
	# answer is to reject the SHAPE. The `/$path/` wrapping makes the
	# slash-delimited match cover the first and last components too, so an
	# ordinary filename that merely contains dots (`a..b.json`) is untouched.
	case "/$path/" in
	*/../*)
		echo "$label: refusing a state path containing '..': $path" >&2
		return 1
		;;
	esac

	if [[ -L "$path" ]]; then
		echo "$label: refusing to operate on symlink: $path" >&2
		return 1
	fi

	local parent
	parent="$(dirname "$path")"
	if [[ -L "$parent" ]]; then
		echo "$label: refusing to operate on symlink: $parent" >&2
		return 1
	fi

	# Decide whether to keep walking. The extra parents are only worth
	# checking when this path lives INSIDE a git worktree, because a
	# checkout is the only way an attacker materialises a symlink here. A
	# path outside a worktree (a test fixture, a temp dir) is bounded at the
	# immediate parent: walking further would reject perfectly ordinary
	# platform symlinks — macOS puts $TMPDIR under `/var`, which IS a
	# symlink to `/private/var` — and turn the guard into a false refusal.
	local root_canon="" git_root
	if git_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
		root_canon="$(cd "$git_root" 2>/dev/null && pwd -P)" || root_canon=""
	fi
	[[ -n "$root_canon" ]] || return 0

	# TWO passes, and the split is the whole fix. Three round-4 defects meet
	# here, and each one is a way of getting the containment decision wrong:
	#
	# F7 — the old code advanced `parent` past the already-checked parent and
	#   applied `-L` BEFORE the root-equality break, so when the checked
	#   parent WAS the root the first iteration tested the ROOT'S PARENT. On
	#   macOS a repo under $TMPDIR sits below `/var` -> `/private/var`, so a
	#   perfectly legitimate write was refused.
	#
	# Codex addendum — the containment probe treated an ancestor it could not
	#   `cd` into as PROOF OF SAFETY (`|| return 0`). For
	#   `"$repo/link/sub/new/ledger.json"` with `link` a symlink out of the
	#   repo, `$repo/link/sub/new` does not exist, the probe bailed out with
	#   success, and `mkdir -p` then followed `link` and wrote outside the
	#   worktree. A not-yet-existing ancestor is exactly what `mkdir -p` is
	#   about to create: it must be WALKED, never trusted.
	#
	# The trap under both — a symlinked ancestor CANONICALISES TO SOMEWHERE
	#   ELSE. Any "is this canonical parent still under the root?" test breaks
	#   on the one ancestor it exists to catch: `link` resolves outside the
	#   root, reads as out-of-scope, and gates itself out of its own check.
	#
	# So containment is decided ONCE, and lexically, before any -L test runs:
	#
	#   Pass 1 climbs from the path's parent looking for an ancestor whose
	#   CANONICAL form equals the worktree root. Its only output is a yes/no
	#   and, on yes, the root's spelling AS THIS PATH SPELLS IT ($probe) --
	#   which is what makes the stop point immune to symlinks anywhere above
	#   it. Unreadable ancestors are climbed past, not treated as an answer.
	#   No `return 1` and no diagnostic can come out of this pass.
	#
	#   Pass 2 -L-tests every component from the path's parent up to, but
	#   NOT including, $probe. Everything strictly inside the worktree is
	#   tested, including ancestors that do not exist yet; nothing at or above
	#   the root ever is.
	#
	# A path that is not under the worktree at all never reaches pass 2 (pass
	# 1 walks it to `/` and answers no), so an out-of-tree fixture is not
	# refused on a platform symlink it never touches.
	local probe="$parent" probe_canon inside=0
	while [[ "$probe" != "/" && "$probe" != "." ]]; do
		if probe_canon="$(cd "$probe" 2>/dev/null && pwd -P)"; then
			if [[ "$probe_canon" == "$root_canon" ]]; then
				inside=1
				break
			fi
		fi
		probe="$(dirname "$probe")"
	done
	[[ "$inside" -eq 1 ]] || return 0

	while [[ "$parent" != "$probe" && "$parent" != "/" && "$parent" != "." ]]; do
		if [[ -L "$parent" ]]; then
			echo "$label: refusing to operate on symlink: $parent" >&2
			return 1
		fi
		parent="$(dirname "$parent")"
	done

	return 0
}
