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
# PARENT-WALK BOUND, AND IT COMES FROM THE PATH (round 7, F1/F2/F3). The
# bound is the innermost git worktree root among the PATH's OWN lexical
# ancestors, found by asking each existing, non-symlink ancestor with
# `git -C <ancestor> rev-parse --show-toplevel` which worktree it is in. The
# process cwd is never consulted. It used to be: a bare `git rev-parse`
# answered about the CALLER's cwd, so one and the same path was refused from
# inside the repo and ACCEPTED from anywhere else — the guard silently
# degraded to the leaf-plus-immediate-parent bound this file exists to
# replace. The verdict is now a function of the path's spelling and the
# filesystem alone.
#
# Inside a worktree the walk stops AT the worktree root — the root itself and
# everything above it is never `-L`-tested by the loop: that span is the whole
# reach of a checkout, and testing past it would reject legitimate paths under
# platform symlinks (macOS `/var` -> `/private/var`, `/tmp` ->
# `/private/tmp`) that have nothing to do with the repo. Outside a worktree
# only the path and its immediate parent are checked — the two positions the
# threat actually occupies — for the same reason.
#
# CANDIDATE ANCESTORS THAT ARE THEMSELVES SYMLINKS are skipped on both sides
# of that question (`! -L "$cand"` when asking git, `! -L "$probe"` when
# accepting the match). An ancestor that is itself a symlink can never be the
# containment boundary: `…/.gauntlet -> <another worktree root>` would
# otherwise end the walk AT the symlink and exempt from pass 2 the one
# component the guard exists to catch.
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
#
# SECOND RESIDUAL, stated honestly: when a worktree root is reachable only
# through a symlinked spelling of its own path (`~/proj -> /Volumes/x/proj`,
# and the guarded path spelled `~/proj/.gauntlet/x`), no NON-symlink lexical
# ancestor canonicalises to the root, so no candidate matches and the guard
# falls back to the documented out-of-worktree bound — the leaf and its
# immediate parent. That is the same bound this spelling already received from
# every cwd but one before round 7; it is a weaker check, never a false
# refusal.
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

	# Decide whether to keep walking. The extra parents are only worth
	# checking when this path lives INSIDE a git worktree, because a
	# checkout is the only way an attacker materialises a symlink here. A
	# path outside a worktree (a test fixture, a temp dir) is bounded at the
	# immediate parent: walking further would reject perfectly ordinary
	# platform symlinks — macOS puts $TMPDIR under `/var`, which IS a
	# symlink to `/private/var` — and turn the guard into a false refusal.
	# The candidate root comes from the PATH's own lexical ancestors (round
	# 7, F1/F2/F3): each ancestor that exists and is not itself a symlink is
	# asked, with `git -C`, which worktree IT is in. A bare `git rev-parse`
	# here answered about the process cwd instead, so the same path was
	# refused from one cwd and accepted from another. `git -C <missing>`
	# fails immediately, so a not-yet-existing tail costs nothing; the depth
	# is bounded by the path.
	#
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
	local cand="$parent" cand_root probe probe_canon inside=0
	while [[ "$cand" != "/" && "$cand" != "." ]]; do
		# A candidate ancestor that is ITSELF a symlink can never be the
		# containment boundary: `.gauntlet -> <another worktree root>`
		# would otherwise end the walk AT the symlink and exempt it from
		# pass 2 — the one component the guard exists to catch. Same rule
		# on the accepting side (`! -L "$probe"`).
		if [[ ! -L "$cand" ]] && cand_root="$(git -C "$cand" rev-parse --show-toplevel 2>/dev/null)"; then
			cand_root="$(cd "$cand_root" 2>/dev/null && pwd -P)" || cand_root=""
			if [[ -n "$cand_root" ]]; then
				probe="$parent"
				while [[ "$probe" != "/" && "$probe" != "." ]]; do
					if probe_canon="$(cd "$probe" 2>/dev/null && pwd -P)"; then
						if [[ "$probe_canon" == "$cand_root" && ! -L "$probe" ]]; then
							inside=1
							break
						fi
					fi
					probe="$(dirname "$probe")"
				done
				[[ "$inside" -eq 1 ]] && break
			fi
		fi
		cand="$(dirname "$cand")"
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
