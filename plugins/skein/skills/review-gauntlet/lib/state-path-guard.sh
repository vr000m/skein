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
# exists to end.
#
# WHY NOT scripts/lib/auto-fix-common.sh's af_assert_no_symlink (round 7, F4).
# Not for reachability: `scripts/lib/auto-fix-common.sh` IS in BUNDLE_SHARED
# (scripts/lib/bundle-map.sh) and review-gauntlet IS in BUNDLE_SKILLS, so a
# bundled copy of it sits in this skill's `scripts/lib/` in both mirrors. An
# earlier version of this paragraph claimed otherwise and was checkably false,
# which is worse than no rationale at all. The three reasons that are true:
#
#   1. LAYERING. `plugins/*/skills/review-gauntlet/scripts/**` is a GENERATED
#      artifact (`just bundle-appliers`, `just check-sync`, byte-parity
#      enforced). An AUTHORED file sourcing a generated one inverts the
#      dependency: this lib would stop working in the canonical repo layout
#      the moment the bundle map changed, and check-sync would be gating a
#      runtime dependency rather than an artifact.
#   2. `bundled == operative`. bundle-map.sh's rule is that a file is bundled
#      into a skill IFF that skill's SKILL.md invokes it. Sourcing
#      persist_path_is_inside_root would mean adding lib/persist-common.sh to
#      `bundle_extra_for review-gauntlet` for a predicate the gauntlet does
#      not otherwise need, breaking that invariant.
#   3. DIFFERENT QUESTIONS, OPPOSITE FAILURE DIRECTIONS.
#      persist_path_is_inside_root is a SCOPING predicate — lexical,
#      fail-OPEN, and required to answer "outside" for legitimate out-of-tree
#      fixtures. This function is a fail-CLOSED enforcement walk that composes
#      its own paths and rejects `..` outright. Collapsing them would force one
#      failure direction onto the other.
#
# So: one owner per state tree, two implementations, and the boundary written
# down AND test-asserted. af_assert_no_symlink owns the `.deep-review/` /
# `.review-plan/` trees; this function owns `.gauntlet/`. The relation between
# them is asserted by `R7-G2a` in tests/gauntlet/test-gate-timeout.sh, not by
# this paragraph.
#
# `.gauntlet/` is gitignored (.gitignore:9), but a *tracked* symlink at that
# path still materialises on checkout, and `mkdir -p` follows it — so a
# malicious clone could point it outside the repo and have a state write land
# on an arbitrary user-writable file. Impact is bounded (the attacker chooses
# the directory, not the contents), but the asymmetry inside one change set —
# some state writes guarded, others not — is the actual defect.
#
# PARENT-WALK BOUND — THE OUTERMOST CHECKOUT BOUNDARY ON THE PATH'S OWN
# ANCESTOR CHAIN (round 8, F1/F2). The invariant, stated once and in full:
#
#   For a guarded path P, let A(P) be P's lexical ancestor chain (`dirname`
#   repeatedly, up to `/`), and let B be the SHALLOWEST element of A(P) that
#   is not itself a symlink and carries a `.git` entry.
#   gauntlet_assert_no_symlink returns 1 iff P contains a `..` component, or
#   P itself is a symlink, or any element of A(P) strictly below B is a
#   symlink. If no such B exists, only P and `dirname P` are tested. The
#   verdict is a pure function of P's spelling and the `-L`/`-e` state of the
#   named components. NO SUBPROCESS, NO ENVIRONMENT VARIABLE, and no
#   `cd`/`pwd -P` participates.
#
# OUTERMOST, NOT INNERMOST (round 8, F1). Round 7 stopped at the FIRST
# (innermost) worktree-bearing ancestor, which let an attacker CHOOSE the
# bound: plant `.gauntlet -> <dir>` and a `.git` under `<dir>/<run-dir>`, and
# the bound becomes the guarded path's own parent — pass 2's loop body never
# runs and the escaping symlink at `.gauntlet` is never `-L`-tested. A bound
# found further UP can only ADD components to the tested set, never remove
# one, so the shallowest match is the only bound an attacker standing below
# it cannot lower.
#
# A `.git` ENTRY, NOT `git rev-parse` (round 8, F2). `git -C <dir> rev-parse
# --show-toplevel` answers about GIT_DIR/GIT_WORK_TREE when those are
# exported — and git exports them into every hook process — so the answer
# stopped being about <dir> at all: no ancestor matched, the bound vanished,
# and the guard silently degraded to the leaf-plus-parent bound this file
# exists to replace. `-e`/`-L` on `<cand>/.git` cannot be redirected by any
# environment variable. Its error direction is also the safe one: a stray
# `.git` makes the bound SHALLOWER (more components tested, fail-closed); the
# only way to lose a bound is for the victim's own `.git` to be absent.
#
# The walk stops AT that boundary — the boundary and everything above it is
# never `-L`-tested by the loop. Platform aliases (macOS `/tmp` ->
# `/private/tmp`, `/var` -> `/private/var`) sit above every `.git` on any real
# host, so they are never tested and never falsely refused. A path with no
# `.git` anywhere on its chain (a test fixture, a temp dir) is bounded at its
# immediate parent — the two positions the threat actually occupies.
#
# A CANDIDATE THAT IS ITSELF A SYMLINK can never be the boundary
# (`! -L "$cand"`): `…/.gauntlet -> <another checkout>` would otherwise end
# the walk AT the symlink and exempt from pass 2 the one component the guard
# exists to catch.
#
# ANCESTORS THAT DO NOT EXIST YET ARE STILL WALKED. Callers guard and then
# `mkdir -p`, so the components `mkdir -p` is about to create are exactly the
# ones an attacker wants a symlink under. An ancestor that cannot be
# canonicalised is NOT evidence of safety: the walk continues upward with
# containment undecided until it reaches one that exists.
#
# RESIDUALS — THREE, documented rather than claimed away:
#
#   1. TOCTOU. The guard -> write (or guard -> mkdir) window is unclosed.
#      Closing it needs openat(O_NOFOLLOW), which portable bash lacks.
#
#   2. A CHECKOUT WITH NO `.git` ENTRY AT ITS ROOT — a bare repository
#      addressed through an exported GIT_DIR, or a `core.worktree`
#      configuration — presents no filesystem boundary to find, so no bound
#      exists and the guard falls back to the documented out-of-worktree
#      bound: the leaf and its immediate parent. Weaker, never a false
#      refusal.
#
#   3. A WIDENED REFUSAL, deliberate (round 8). When a symlinked ancestor
#      sits BELOW the outermost boundary, round 7 accepted (its bound sat
#      below the symlink, so pass 2 never reached it) and round 8 refuses.
#      The concrete case is `~/proj -> /Volumes/x/proj` WITH a `.git` in
#      $HOME (a dotfiles repo): the bound becomes $HOME, pass 2 reaches
#      `~/proj`, `-L` hits, refusal. That is correct fail-closed behaviour —
#      the guard cannot distinguish that symlink from an attack — and the
#      diagnostic names the offending component. Without a `.git` in $HOME
#      the round-7 behaviour is unchanged (no bound, leaf+parent, accept).
#      Pinned by `R8-G1c` in tests/gauntlet/test-gate-timeout.sh so a later
#      round cannot quietly "fix" it back.
gauntlet_assert_no_symlink() {
	local path="$1" label="${2:-state-path-guard}"

	# Absolutise first. Everything below reasons about ANCESTORS, and a
	# relative path's ancestor chain terminates at "." rather than at the
	# filesystem root, so a relative spelling would silently shorten the
	# walk. Absolutising against $PWD resolves no component, and it is the
	# ONLY thing the cwd is used for: the containment bound below is derived
	# from the path's own ancestors, never from where the process is
	# standing (round 7, F1/F2/F3). A $PWD that is itself a symlinked alias
	# therefore cannot change a verdict for an already-absolute path; for a
	# relative one it merely picks which spelling of the same file is being
	# guarded, and this guard's failure direction is fail-CLOSED (a `-L` hit
	# refuses loudly) either way.
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

	# Decide how far up to walk. The extra parents are only worth checking
	# when this path lives INSIDE a checkout, because a checkout is the only
	# way an attacker materialises a symlink here. A path with no checkout
	# on its chain (a test fixture, a temp dir) is bounded at the immediate
	# parent: walking further would reject perfectly ordinary platform
	# symlinks — macOS puts $TMPDIR under `/var`, which IS a symlink to
	# `/private/var` — and turn the guard into a false refusal.
	#
	# Two round-4 defects still bound the SHAPE of this code, so they are
	# recorded here rather than rediscovered:
	#
	# F7 — the old code advanced `parent` past the already-checked parent and
	#   applied `-L` BEFORE the boundary break, so when the checked parent
	#   WAS the boundary the first iteration tested the BOUNDARY'S PARENT. On
	#   macOS a repo under $TMPDIR sits below `/var` -> `/private/var`, so a
	#   perfectly legitimate write was refused.
	#
	# Codex addendum — the containment probe treated an ancestor it could not
	#   `cd` into as PROOF OF SAFETY (`|| return 0`). For
	#   `"$repo/link/sub/new/ledger.json"` with `link` a symlink out of the
	#   repo, `$repo/link/sub/new` does not exist, the probe bailed out with
	#   success, and `mkdir -p` then followed `link` and wrote outside the
	#   worktree. A not-yet-existing ancestor is exactly what `mkdir -p` is
	#   about to create: it must be WALKED, never trusted. The lexical loop
	#   below walks it for free — `-L` and `-e` on a missing component are
	#   simply false, never an answer.
	#
	# The bound is the OUTERMOST checkout boundary on the path's own lexical
	# ancestor chain: the shallowest ancestor that is not itself a symlink
	# and carries a `.git` entry. Two properties, and both are the round-8
	# fix (F1 and F2 — see the OUTERMOST and `.git` ENTRY paragraphs in this
	# file's header for why each one is the whole finding). `-L "$cand/.git"`
	# is ORed in so a DANGLING `.git` symlink still marks a boundary — the
	# same fail-closed direction. There is deliberately NO early exit: the
	# loop always climbs to `/`, because a shallower boundary must win.
	local cand="$parent" bound=""
	while [[ "$cand" != "/" && "$cand" != "." ]]; do
		if [[ ! -L "$cand" ]] && { [[ -e "$cand/.git" ]] || [[ -L "$cand/.git" ]]; }; then
			bound="$cand"
		fi
		cand="$(dirname "$cand")"
	done
	[[ -n "$bound" ]] || return 0

	# Pass 2: `-L`-test every component from the path's parent up to, but NOT
	# including, $bound. Everything strictly inside the boundary is tested,
	# including ancestors that do not exist yet; nothing at or above the
	# boundary ever is.
	while [[ "$parent" != "$bound" && "$parent" != "/" && "$parent" != "." ]]; do
		if [[ -L "$parent" ]]; then
			echo "$label: refusing to operate on symlink: $parent" >&2
			return 1
		fi
		parent="$(dirname "$parent")"
	done

	return 0
}
