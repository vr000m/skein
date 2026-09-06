#!/usr/bin/env bash
set -euo pipefail

# fan-out.sh — Worktree setup, agent spawning, monitoring, and cleanup
# Companion script for the /fan-out skill.

DEFAULT_CMD="codex"
DEFAULT_PROMPT_FLAG="-p"
DEFAULT_PROMPT_MODE="inline"
DEFAULT_PERMS_FLAG=""
DEFAULT_MODEL=""
DEFAULT_EFFORT="medium"

usage() {
	cat <<'EOF'
Usage: fan-out.sh <command> [options]

Commands:
  tasks   --plan <path> [--plan-sha256 <hex>] <repo-root>
          Print one record per Implementation Checklist item as
          <task-id>\t<task-slug>\t<title>. Items are numbered 1-based in file
          order, counting both '- [ ]' and '- [x]' lines, so an ordinal does
          not move when a worker ticks a box mid-run. <path> must sit inside
          <repo-root> with no '..' component and no symlink below the root.
          With --plan-sha256 the plan's shasum -a 256 digest must match.
  setup   <base-branch> --plan <path> --task-id N --plan-sha256 <hex> <repo-root>
          Create branch + worktree for checklist task N. The slug is DERIVED
          here from the plan the caller pinned by digest, never spelled by the
          caller, so a task id can only ever name the task that ordinal
          actually holds in that exact plan revision.
  setup   <base-branch> <task-slug> <repo-root>    Create branch + worktree
          Test-only call shape: the slug is spelled on the command line, so it
          derives nothing and pins nothing. Refused unless
          FANOUT_TEST_LITERAL_SLUG=1 is set. The skill always uses the --plan
          form. <task-slug> must be <task-id>-<slug>: digits, then '-', then
          [a-z0-9-]; and already in slugify normal form (no '--', no leading
          or trailing '-', 50 characters or fewer). Anything slugify would
          rewrite is refused. The same two guards apply to the derived slug.
  spawn   <worktree-path> <prompt-file> <log-file> [--model MODEL] [--effort LEVEL]  Launch codex
  status  <state-file>                              Check agent PIDs
  cancel  <state-file> [task-id]                    Kill agent(s)
  cleanup <state-file>                              Remove worktrees, branches
                                                    and the state file
  help                                              Show this message

Environment:
  FANOUT_CMD=codex                Override command (default: codex)
  FANOUT_PROMPT_FLAG=-p           Override prompt flag (default: -p)
  FANOUT_PROMPT_MODE=inline|file  Whether to pass inline prompt text or a file path
  FANOUT_PERMS_FLAG=              Permission flag(s), if needed
  FANOUT_EXTRA_ARGS=              Extra args appended to the command
  FANOUT_MODEL=                   Default model (optional)
  FANOUT_EFFORT=medium            Default reasoning effort intent (high|medium|low)

If the configured Codex command advertises a first-class --effort flag, fan-out passes
--effort LEVEL. If it does not, fan-out records the intent but does not append an
unsupported flag; use FANOUT_EXTRA_ARGS for runtime-specific config/profile flags
that request reasoning effort in that Codex CLI version.
EOF
}

# `printf '%s\n'` and not `echo`: slugify's input is now plan-derived TITLE text,
# and bash's `echo` eats a leading `-n`/`-e`/`-E` as an option instead of
# printing it. A title such as `-e do the thing` would then slugify from the
# wrong bytes. printf takes its operand as data whatever it starts with. The
# output alphabet is unchanged, so every existing caller sees the same answer.
slugify() {
	printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//' | sed 's/-$//' | cut -c1-50
}

# --- task identity: derive the slug, never accept one ----------------------
#
# WHY THIS EXISTS. The slug used to be derived by the MODEL and handed to this
# script, which meant the script could only check the slug's SHAPE, never its
# MEANING. A slug that passed every shape guard but named a different task than
# the one the user approved -- `7-delete-api` for approved task `7-add-api` --
# was accepted, and setup then force-removes any worktree already standing at
# the derived path. Task identity has to be executable, so the caller now names
# an ORDINAL in a plan revision it pins by digest, and the mapping from ordinal
# to slug is computed here from the plan's own bytes.
#
# ORDINALS COUNT BOTH BOX STATES on purpose. A worker ticking `- [ ]` to `- [x]`
# mid-run must not renumber the tasks still to be set up; numbering only the
# unticked lines would do exactly that.

# Print `<ordinal>\t<title>` for every checklist item in <plan-path>.
#
# The region is the one after a heading whose text contains `Implementation
# Checklist`, ending at the next heading of the same or a higher level (a `###`
# subsection inside a `##` checklist stays in the region; the next `##` ends
# it). Tabs inside a title are folded to spaces because the record itself is
# tab-separated.
fanout_checklist_lines() {
	awk '
    function heading_level(s,   i) {
      if (s !~ /^#+[ \t]/) return 0
      i = 0
      while (substr(s, i + 1, 1) == "#") i++
      return i
    }
    {
      hl = heading_level($0)
      if (!in_region) {
        if (hl > 0 && index($0, "Implementation Checklist") > 0) {
          in_region = 1
          level = hl
        }
        next
      }
      if (hl > 0 && hl <= level) exit
      if ($0 ~ /^[ \t]*- \[[ xX]\][ \t]+/) {
        n++
        title = $0
        sub(/^[ \t]*- \[[ xX]\][ \t]+/, "", title)
        sub(/[ \t]+$/, "", title)
        gsub(/\t/, " ", title)
        printf "%d\t%s\n", n, title
      }
    }
  ' "$1"
}

# Print `<task-id>\t<task-slug>\t<title>` for task <task-id> in <plan-path>.
# Returns non-zero (printing nothing) when the plan has no such ordinal.
#
# The title is UNTRUSTED plan text throughout: it is carried in shell variables
# and printf OPERANDS only, never spelled into a command line, never eval'd, and
# never used as a printf FORMAT.
fanout_task_record() {
	local plan="$1" want="$2" id title
	while IFS=$'\t' read -r id title; do
		[[ "$id" == "$want" ]] || continue
		printf '%s\t%s\t%s\n' "$id" "$id-$(slugify "$title")" "$title"
		return 0
	done < <(fanout_checklist_lines "$plan")
	return 1
}

# Digest a plan file the way `tasks --plan-sha256` and `setup --plan-sha256`
# both expect it. Called only AFTER the containment walk has passed.
fanout_plan_sha256() {
	shasum -a 256 "$1" | awk '{print $1}'
}

# The ONE definition of an accepted task slug: <task-id>-<slug> -- digits, then
# '-', then [a-z0-9-]. Two call sites share it on purpose. cmd_setup validates
# the incoming slug against it, and fanout_worktree_is_ours applies it to the
# suffix of a worktree basename, so cleanup's ownership test can never be
# broader than the names setup is able to produce. Keeping one definition is
# what makes that equality checkable rather than a convention.
FANOUT_TASK_SLUG_RE='^[0-9]+-[a-z0-9-]+$'

# --- containment guard for the plan path -----------------------------------
# Refuses a path that is not lexically inside <repo-root>, that contains a
# '..' component, or that is reached through a symlink at any component
# strictly below <repo-root>.
#
# WHY A LOCAL WALK AND NOT review-gauntlet's lib/state-path-guard.sh: that file
# is the single owner of the `.gauntlet/` tree's policy and ships in THAT
# skill's lib/ directory, which fan-out does not carry; sourcing it across skill
# directories would make this skill's runtime depend on another skill's bundle
# layout. The question asked here is also the narrower one -- a fixed path under
# a repo root the caller already named -- so the walk is bounded at <repo-root>
# instead of at a discovered checkout boundary. Bounding there is also what
# keeps ordinary platform symlinks ABOVE the repo (macOS puts $TMPDIR under
# /var -> /private/var) from turning into a false refusal.
#
# WHY NOT scripts/lib/ EITHER: this repo does share bash helpers by copying
# scripts/lib/*.sh into each skill bundle through scripts/lib/bundle-map.sh.
# Routing this walk through that mechanism would add fan-out to the bundle map
# and to the mirror sync gate for the sake of one function that only fan-out
# calls, so it is deliberately deferred until a second skill needs a
# repo-root-bounded walk. Do not promote it before then.

# Normalise a path's spelling so every later test is spelling-independent:
# collapse '//' runs and '/./' components, and strip a trailing '/' or '/.'.
# `[[ -L "$p/" ]]` is always false and a '//' run makes `${p%/*}` strip an
# empty component instead of a real one, so the verdict must not depend on how
# the caller typed the path. A '.' component is likewise inert, and leaving it
# in place turned a repo root spelled `/a/./b` into a false refusal.
fanout_normalise_path() {
	local p="$1"
	while [[ "$p" == *//* ]]; do p="${p//\/\///}"; done
	while [[ "$p" == *"/./"* ]]; do p="${p//\/.\///}"; done
	while [[ "$p" == */. ]]; do
		p="${p%/.}"
		[[ -n "$p" ]] || p="/"
	done
	while [[ "$p" == */ && "$p" != "/" ]]; do p="${p%/}"; done
	printf '%s' "$p"
}

fanout_assert_inside_repo() {
	local path="$1" root="$2" label="$3"

	[[ "$path" == /* ]] || path="$PWD/$path"
	[[ "$root" == /* ]] || root="$PWD/$root"
	path="$(fanout_normalise_path "$path")"
	root="$(fanout_normalise_path "$root")"

	# Every check below is lexical, and lexical reasoning is unsound once '..' is
	# in play: `$root/link/../plan.md` with `link` a symlink names a file
	# beside link's TARGET, not a child of $root. Reject the shape.
	case "/$path/" in
	*/../*)
		echo "fan-out: refusing $label containing '..': $path" >&2
		return 1
		;;
	esac

	# Containment by prefix STRIP, not by pattern match: `[[ $path != "$root"/* ]]`
	# relies on the reader knowing the quoted operand is literal while the trailing
	# `/*` is a pattern. Stripping is unambiguous -- if removing "$root/" from the
	# front changes nothing, the prefix was not there -- and no byte of $root is
	# ever read as a glob metacharacter.
	if [[ "${path#"$root"/}" == "$path" ]]; then
		echo "fan-out: refusing $label outside the repo root $root: $path" >&2
		return 1
	fi

	local cur="$path" next
	while [[ "$cur" != "$root" && "$cur" != "/" ]]; do
		if [[ -L "$cur" ]]; then
			echo "fan-out: refusing $label reached through a symlink: $cur" >&2
			return 1
		fi
		next="${cur%/*}"
		[[ -n "$next" ]] || next="/"
		# Textual-progress backstop: on the normalised alphabet each step drops at
		# least one component, so this can only fire on a violated premise.
		[[ "$next" != "$cur" ]] || break
		cur="$next"
	done

	return 0
}

# Does <worktree> carry the name cmd_setup would have given it under <repo-root>?
# One half of cleanup's ownership test: before a path from `git worktree list`
# can be a removal target it must be one this script could itself have created
# -- absolute, no '..', a sibling of the repo root, and named
# `<repo-name>-fanout-<task-id>-<slug>`. The suffix is tested with
# $FANOUT_TASK_SLUG_RE, the same expression cmd_setup accepts a slug by, so the
# set of names cleanup will act on is exactly the set setup can create. A
# trailing `-fanout-*` glob was broader than that: it also matched an empty
# suffix (`<repo>-fanout-`) and arbitrary hand-made siblings such as
# `<repo>-fanout-private`, which setup never produces and cleanup must not
# remove. The other half is the branch namespace check at the call site; a path
# passing this alone is not a target. Both operands are expected in the same
# spelling (see fanout_canonical_worktree).
fanout_worktree_is_ours() {
	local wt="$1" root="$2" wt_base root_base suffix

	[[ "$wt" == /* ]] || return 1
	case "/$wt/" in
	*/../*) return 1 ;;
	esac
	wt="$(fanout_normalise_path "$wt")"
	root="$(fanout_normalise_path "$root")"
	[[ "$(dirname "$wt")" == "$(dirname "$root")" ]] || return 1
	wt_base="$(basename "$wt")"
	root_base="$(basename "$root")"
	[[ "$wt_base" == "$root_base-fanout-"* ]] || return 1
	suffix="${wt_base#"$root_base-fanout-"}"
	[[ "$suffix" =~ $FANOUT_TASK_SLUG_RE ]] || return 1
	return 0
}

# Spell a path the way every other spelling of the same directory spells it:
# physical form when it exists (a checkout reached through a symlinked parent --
# macOS puts $TMPDIR under /var -> /private/var -- is listed by git in physical
# form while the state file may name the symlinked one), normalised form when it
# does not. Only used to compare two paths for identity, never to open one.
fanout_canonical_path() {
	local p
	p="$(fanout_normalise_path "$1")"
	if [[ -d "$p" ]]; then
		(cd -P "$p" 2>/dev/null && pwd -P) || printf '%s' "$p"
	else
		printf '%s' "$p"
	fi
}

# Spell a WORKTREE path the way git spells it. Same purpose as
# fanout_canonical_path, but the physical resolution is taken on the PARENT and
# the basename re-appended, so the answer does not change when the worktree
# directory itself is missing -- which is exactly the case cleanup has to handle
# (a worktree deleted by hand is still listed by git, marked `prunable`). git
# prints physical paths, while the state file may name the same worktree through
# a symlinked parent, so both sides go through this before being compared.
fanout_canonical_worktree() {
	local p parent
	p="$(fanout_normalise_path "$1")"
	parent="$(fanout_canonical_path "$(dirname "$p")")"
	[[ "$parent" != "/" ]] || parent=""
	printf '%s/%s' "$parent" "$(basename "$p")"
}

# --- tasks: print the plan's checklist as <id>\t<slug>\t<title> ---
#
# The ONE place the ordinal-to-slug mapping is published. The skill calls this
# once per fan-out, shows the user those records, and then names ordinals from
# it -- so the identity the user approves and the identity `setup` re-derives
# come from the same function over the same bytes.
cmd_tasks() {
	local plan_path="" plan_sha="" repo_root=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--plan)
			if [[ $# -lt 2 ]]; then
				echo "fan-out: tasks --plan requires a value" >&2
				exit 1
			fi
			plan_path="$2"
			shift 2
			;;
		--plan-sha256)
			if [[ $# -lt 2 ]]; then
				echo "fan-out: tasks --plan-sha256 requires a value" >&2
				exit 1
			fi
			plan_sha="$2"
			shift 2
			;;
		-*)
			echo "fan-out: tasks: unknown option: $1" >&2
			exit 1
			;;
		*)
			if [[ -n "$repo_root" ]]; then
				echo "fan-out: tasks takes exactly one <repo-root>" >&2
				exit 1
			fi
			repo_root="$1"
			shift
			;;
		esac
	done

	if [[ -z "$plan_path" ]]; then
		echo "fan-out: tasks requires --plan <path> [--plan-sha256 <hex>] <repo-root>" >&2
		exit 1
	fi

	# Same repo-root discipline as cmd_setup, for the same reason: every guard
	# below reasons lexically about an absolute, '..'-free, normalised root.
	if [[ -z "$repo_root" || "$repo_root" != /* ]]; then
		echo "fan-out: refusing repo root (must be an absolute path): $repo_root" >&2
		exit 1
	fi
	case "/$repo_root/" in
	*/../*)
		echo "fan-out: refusing repo root (contains '..'): $repo_root" >&2
		exit 1
		;;
	esac
	repo_root="$(fanout_normalise_path "$repo_root")"

	fanout_assert_inside_repo "$plan_path" "$repo_root" "plan file" || exit 1

	if [[ ! -f "$plan_path" ]]; then
		echo "fan-out: missing plan file: $plan_path" >&2
		exit 1
	fi

	# Optional here and mandatory on `setup`: this call is what the caller uses to
	# LEARN the digest, so requiring one would be circular. `setup` is the call
	# that acts, and that one always pins.
	if [[ -n "$plan_sha" ]]; then
		local actual_sha
		actual_sha="$(fanout_plan_sha256 "$plan_path")"
		if [[ -z "$actual_sha" || "$actual_sha" != "$plan_sha" ]]; then
			echo "fan-out: refusing plan (sha256 mismatch; the plan changed since it was read): $plan_path" >&2
			exit 1
		fi
	fi

	local id title
	while IFS=$'\t' read -r id title; do
		[[ -n "$id" ]] || continue
		printf '%s\t%s\t%s\n' "$id" "$id-$(slugify "$title")" "$title"
	done < <(fanout_checklist_lines "$plan_path")
}

# --- setup: create branch + worktree ---
cmd_setup() {
	local base_branch="${1:-}"
	shift || true

	# Two call shapes: the derived `--plan <path> --task-id N --plan-sha256 <hex>
	# <repo-root>` form the skill uses, where the caller names an ordinal and the
	# slug is computed here; and the positional `<task-slug> <repo-root>` form,
	# kept for the guard tests that drive the slug regex and fixed-point branches
	# directly.
	local task_slug="" repo_root=""
	local plan_path="" task_id="" plan_sha="" derived=0
	if [[ "${1:-}" == "--plan" ]]; then
		derived=1
		while [[ $# -gt 0 ]]; do
			case "$1" in
			--plan)
				if [[ $# -lt 2 ]]; then
					echo "fan-out: setup --plan requires a value" >&2
					exit 1
				fi
				plan_path="$2"
				shift 2
				;;
			--task-id)
				if [[ $# -lt 2 ]]; then
					echo "fan-out: setup --task-id requires a value" >&2
					exit 1
				fi
				task_id="$2"
				shift 2
				;;
			--plan-sha256)
				if [[ $# -lt 2 ]]; then
					echo "fan-out: setup --plan-sha256 requires a value" >&2
					exit 1
				fi
				plan_sha="$2"
				shift 2
				;;
			-*)
				echo "fan-out: setup: unknown option: $1" >&2
				exit 1
				;;
			*)
				if [[ -n "$repo_root" ]]; then
					echo "fan-out: setup takes exactly one <repo-root>" >&2
					exit 1
				fi
				repo_root="$1"
				shift
				;;
			esac
		done
		# All three are mandatory together: the digest is what makes the ordinal
		# mean anything, so an unpinned --plan is not a lesser form of this call, it
		# is the vulnerability this call shape exists to close.
		if [[ -z "$plan_path" || -z "$task_id" || -z "$plan_sha" ]]; then
			echo "fan-out: setup --plan requires --plan <path> --task-id N --plan-sha256 <hex> <repo-root>" >&2
			exit 1
		fi
	else
		# The positional form spells the slug on the command line, which is exactly
		# what the derived form exists to prevent. It stays only so the guard tests
		# can drive the regex and fixed-point branches directly, and it is refused
		# unless the caller opts in with FANOUT_TEST_LITERAL_SLUG=1.
		if [[ "${FANOUT_TEST_LITERAL_SLUG:-}" != "1" ]]; then
			echo "fan-out: refusing positional slug form (test-only; set FANOUT_TEST_LITERAL_SLUG=1). The skill uses: setup <base-branch> --plan <path> --task-id N --plan-sha256 <hex> <repo-root>" >&2
			exit 1
		fi
		task_slug="${1:-}"
		repo_root="${2:-}"
	fi

	# NORMALISE repo_root ONCE, and reason about that single value everywhere
	# below. Every guard in this file normalises before judging, so if
	# `basename`, `dirname` and `git -C` kept the caller's raw spelling the
	# script would build a path the guards never looked at: `<repo>/.` has
	# basename `.` and dirname `<repo>`, which puts the worktree INSIDE the
	# checkout while the guards reason about the sibling -- and cleanup, which
	# does normalise, then refuses to remove it. Refuse the two shapes cleanup
	# refuses, for the same reason it does: a relative path is meaningless once
	# `git -C` has changed directory, and lexical reasoning is unsound with '..'
	# in play.
	#
	# Deliberately LEXICAL only -- no `cd -P`/`pwd -P`. Resolving to the physical
	# path here would spell the root differently from the slug file the caller
	# names through the same symlinked parent (macOS puts $TMPDIR under
	# /var -> /private/var), and `fanout_assert_inside_repo` would then reject a
	# containment that holds. Identity comparisons that DO need the physical form
	# use `fanout_canonical_path` at the point of comparison instead.
	if [[ -z "$repo_root" || "$repo_root" != /* ]]; then
		echo "fan-out: refusing repo root (must be an absolute path): $repo_root" >&2
		exit 1
	fi
	case "/$repo_root/" in
	*/../*)
		echo "fan-out: refusing repo root (contains '..'): $repo_root" >&2
		exit 1
		;;
	esac
	repo_root="$(fanout_normalise_path "$repo_root")"

	if [[ "$derived" -eq 1 ]]; then
		# A BARE POSITIVE INTEGER and nothing else. This value is compared against
		# awk's own ordinal, which is printed with %d, so anything that is not the
		# same spelling of the same number (`07`, `1 `, `+1`, `1e0`) could only ever
		# fail to match -- refusing it outright says so, instead of reporting the
		# task as absent from the plan.
		if [[ ! "$task_id" =~ ^[1-9][0-9]*$ ]]; then
			echo "fan-out: refusing task id (must be a positive integer): $task_id" >&2
			exit 1
		fi

		# Contain the plan path before reading it, for the same reason the slug
		# transport used to be contained: the path is caller-supplied, and a `..`
		# component or a symlinked directory below the root would let a call name a
		# "plan" outside the checkout the digest was computed against.
		fanout_assert_inside_repo "$plan_path" "$repo_root" "plan file" || exit 1

		if [[ ! -f "$plan_path" ]]; then
			echo "fan-out: missing plan file: $plan_path" >&2
			exit 1
		fi

		# DIGEST AFTER THE WALK, never before: hashing first would open the file
		# through a path the guard has not accepted yet. The digest is what binds
		# the ordinal to a plan REVISION -- without it, editing the checklist
		# between the `tasks` call the user approved and this call would silently
		# re-point every ordinal at a different task.
		local actual_sha
		actual_sha="$(fanout_plan_sha256 "$plan_path")"
		if [[ -z "$actual_sha" || "$actual_sha" != "$plan_sha" ]]; then
			echo "fan-out: refusing plan (sha256 mismatch; the plan changed since it was read): $plan_path" >&2
			exit 1
		fi

		local record
		if ! record="$(fanout_task_record "$plan_path" "$task_id")"; then
			echo "fan-out: no task $task_id in the plan's Implementation Checklist: $plan_path" >&2
			exit 1
		fi
		# Field 2 of `<id>\t<slug>\t<title>`. The title (field 3) is deliberately
		# not used for anything but the record itself.
		task_slug="$(printf '%s' "$record" | cut -f2)"
	fi

	# Fail closed on any slug that is not <task-id>-<lowercase-slug>. In the
	# derived form this is a backstop rather than the primary boundary -- slugify
	# already emits only [a-z0-9-] -- and it is what catches a title that
	# slugifies to nothing (`- [ ] ???` would derive `7-`, which has an empty
	# suffix and must not become a branch).
	#
	# Echoing the value is safe on both paths: the positional form's value came
	# from the caller's own argv, and the derived form's came out of slugify, so
	# its alphabet is already [0-9a-z-].
	if [[ ! "$task_slug" =~ $FANOUT_TASK_SLUG_RE ]]; then
		if [[ "$derived" -eq 1 ]]; then
			echo "fan-out: refusing task slug (must match ^[0-9]+-[a-z0-9-]+\$) derived for task $task_id of $plan_path: $task_slug" >&2
		else
			echo "fan-out: refusing task slug (must match ^[0-9]+-[a-z0-9-]+\$): $task_slug" >&2
		fi
		exit 1
	fi

	# The regex alone is not enough: slugify() collapses runs of '-', strips edge
	# hyphens and truncates to 50 chars, so two distinct slugs that pass the regex
	# (1-foo--bar and 1-foo-bar) can still map to one branch and one worktree.
	# Require the slug to be a slugify fixed point, so the value the caller passed
	# is literally the value used for the branch and the worktree path.
	local slug
	slug="$(slugify "$task_slug")"
	if [[ "$slug" != "$task_slug" ]]; then
		echo "fan-out: refusing task slug (would be rewritten by slugify to '$slug'): $task_slug" >&2
		exit 1
	fi

	# The base branch reaches `git worktree add` as a revision argument; validate it
	# at the same boundary rather than trusting the caller.
	# A leading '-' is rejected outright: `git worktree add` would parse it as an
	# option, and the prefixed check-ref-format call cannot see it.
	if [[ "$base_branch" == -* ]] || ! git check-ref-format "refs/heads/$base_branch" >/dev/null 2>&1; then
		echo "fan-out: refusing base branch: $base_branch" >&2
		exit 1
	fi

	local base_slug
	base_slug="$(slugify "$base_branch")"
	local branch_name="fanout/${base_slug}-${slug}"
	local repo_name
	repo_name="$(basename "$repo_root")"
	local parent_dir
	parent_dir="$(dirname "$repo_root")"
	local worktree_path="${parent_dir}/${repo_name}-fanout-${slug}"

	# If worktree already exists, remove it so we get a clean reset
	if [[ -d "$worktree_path" ]]; then
		echo "WARNING: Removing existing worktree at $worktree_path" >&2
		git -C "$repo_root" worktree remove "$worktree_path" --force 2>/dev/null || true
	fi

	# Create or reset branch to base_branch tip (not HEAD, which may differ)
	git -C "$repo_root" worktree add -q -B "$branch_name" "$worktree_path" "$base_branch"

	echo "$worktree_path"
}

# --- spawn: launch codex agent in background ---
cmd_spawn() {
	local worktree_path="$1"
	local prompt_file="$2"
	local log_file="$3"
	local cmd="${FANOUT_CMD:-$DEFAULT_CMD}"
	local prompt_flag="${FANOUT_PROMPT_FLAG:-$DEFAULT_PROMPT_FLAG}"
	local prompt_mode="${FANOUT_PROMPT_MODE:-$DEFAULT_PROMPT_MODE}"
	local perms_flag="${FANOUT_PERMS_FLAG:-$DEFAULT_PERMS_FLAG}"
	local extra_args="${FANOUT_EXTRA_ARGS:-}"
	local model="${FANOUT_MODEL:-$DEFAULT_MODEL}"
	local effort="${FANOUT_EFFORT:-$DEFAULT_EFFORT}"

	# Parse optional --model / --effort flags
	shift 3
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--model)
			model="$2"
			shift 2
			;;
		--effort)
			effort="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	if [[ ! -d "$worktree_path" ]]; then
		echo "ERROR: Worktree does not exist: $worktree_path" >&2
		return 1
	fi

	if [[ ! -f "$prompt_file" ]]; then
		echo "ERROR: Prompt file does not exist: $prompt_file" >&2
		return 1
	fi

	local prompt_value
	if [[ "$prompt_mode" == "file" ]]; then
		prompt_value="$prompt_file"
	else
		prompt_value="$(cat "$prompt_file")"
	fi

	local -a cmd_args
	cmd_args=("$cmd" "$prompt_flag" "$prompt_value")
	if [[ -n "$perms_flag" ]]; then
		read -r -a perms_split <<<"$perms_flag"
		cmd_args+=("${perms_split[@]}")
	fi
	if [[ -n "$model" ]]; then
		cmd_args+=("--model" "$model")
	fi
	if [[ -n "$effort" ]]; then
		if command_supports_effort "$cmd"; then
			cmd_args+=("--effort" "$effort")
		else
			echo "WARNING: --effort '$effort' requested but the resolved Codex command '$cmd' does not advertise --effort; effort intent NOT applied. Pass a runtime-specific knob via FANOUT_EXTRA_ARGS to honor it." >&2
		fi
	fi
	if [[ -n "$extra_args" ]]; then
		read -r -a extra_split <<<"$extra_args"
		cmd_args+=("${extra_split[@]}")
	fi

	# Launch codex in the worktree directory.
	# Unset Codex session markers so child agents run as independent sessions.
	# exec replaces the subshell so $! is the codex process PID (not a wrapper),
	# which lets cancel verify the process identity before sending SIGTERM.
	(
		cd "$worktree_path"
		unset CODEX_SHELL CODEX_THREAD_ID CODEX_INTERNAL_ORIGINATOR_OVERRIDE
		exec "${cmd_args[@]}" >"$log_file" 2>&1
	) &

	local pid=$!
	echo "$pid"
}

command_supports_effort() {
	local cmd="$1"
	"$cmd" --help 2>/dev/null | grep -q -- '--effort'
}

# --- status: check agent PIDs from state file ---
cmd_status() {
	local state_file="$1"

	if [[ ! -f "$state_file" ]]; then
		echo "No state file found at $state_file" >&2
		return 1
	fi

	# Read agents array from JSON state file (pass path via sys.argv to avoid injection)
	local agent_count
	agent_count=$(
		python3 - "$state_file" <<'PYEOF'
import json, os, sys

with open(sys.argv[1]) as f:
    state = json.load(f)
agents = state.get('agents', [])
print(len(agents))
for a in agents:
    pid = a.get('pid', 0)
    task_id = a.get('task_id', '?')
    task_name = a.get('task_name', 'unknown')
    branch = a.get('branch', 'unknown')
    worktree = a.get('worktree', 'unknown')
    log_file = a.get('log_file', 'unknown')
    if pid <= 0:
        status = 'INVALID_PID'
    else:
        try:
            os.kill(pid, 0)
            status = 'RUNNING'
        except (ProcessLookupError, PermissionError):
            status = 'FINISHED'
        except Exception:
            status = 'UNKNOWN'
    print(f'{task_id}|{task_name}|{branch}|{worktree}|{log_file}|{pid}|{status}')
PYEOF
	)

	# Parse output
	local count
	count=$(echo "$agent_count" | head -1)
	echo ""
	echo "Fan-out status: $count agent(s)"
	echo "==============================="
	echo ""

	echo "$agent_count" | tail -n +2 | while IFS='|' read -r tid tname tbranch tworktree tlog tpid tstatus; do
		echo "Agent $tid: $tname"
		echo "  Branch:   $tbranch"
		echo "  Worktree: $tworktree"
		echo "  Log:      $tlog"
		echo "  PID:      $tpid"
		echo "  Status:   $tstatus"

		# Check for result file
		if [[ -f "$tworktree/.fan-out-result.md" ]]; then
			echo "  Result:   .fan-out-result.md found"
		fi
		echo ""
	done
}

# --- cancel: kill agent(s) ---
cmd_cancel() {
	local state_file="$1"
	local target_id="${2:-all}"

	if [[ ! -f "$state_file" ]]; then
		echo "No state file found at $state_file" >&2
		return 1
	fi

	python3 - "$state_file" "$target_id" <<'PYEOF'
import json, os, signal, subprocess, sys

with open(sys.argv[1]) as f:
    state = json.load(f)

target = sys.argv[2]
killed = 0

for agent in state.get('agents', []):
    tid = str(agent.get('task_id', ''))
    pid = agent.get('pid', 0)
    name = agent.get('task_name', 'unknown')

    if target != 'all' and tid != target:
        continue

    if pid <= 0:
        print(f'Agent {tid} ({name}) has invalid PID {pid} — skipping')
        continue

    try:
        cmdline = subprocess.check_output(["ps", "-p", str(pid), "-o", "command="], text=True).strip()
    except Exception:
        cmdline = ""

    expected_cmd = os.environ.get("FANOUT_CMD", "codex")
    if not cmdline:
        print(f'Agent {tid} ({name}) PID {pid} already finished')
        continue
    if expected_cmd and expected_cmd not in cmdline:
        print(f'Skipping PID {pid} for agent {tid} ({name}); command does not match {expected_cmd!r}')
        continue

    try:
        os.kill(pid, signal.SIGTERM)
        print(f'Killed agent {tid} ({name}) PID {pid}')
        killed += 1
    except ProcessLookupError:
        print(f'Agent {tid} ({name}) PID {pid} already finished')
    except PermissionError:
        print(f'Cannot kill agent {tid} PID {pid} - permission denied')

if killed == 0 and target == 'all':
    print('No running agents to cancel')
elif target != 'all' and killed == 0:
    print(f'Agent {target} not found or already finished')
PYEOF
}

# --- cleanup: remove worktrees and branches ---
cmd_cleanup() {
	local state_file="$1"

	if [[ ! -f "$state_file" ]]; then
		echo "No state file found at $state_file" >&2
		return 1
	fi

	# First check no agents are still running
	local still_running
	still_running=$(
		python3 - "$state_file" <<'PYEOF'
import json, os, sys

with open(sys.argv[1]) as f:
    state = json.load(f)
running = 0
for a in state.get('agents', []):
    pid = a.get('pid', 0)
    if pid <= 0:
        continue
    try:
        os.kill(pid, 0)
        running += 1
    except Exception:
        pass
print(running)
PYEOF
	)

	if [[ "$still_running" -gt 0 ]]; then
		echo "WARNING: $still_running agent(s) still running. Cancel them first with:" >&2
		echo "  fan-out.sh cancel $state_file" >&2
		return 1
	fi

	# Get repo root and agent info from state file
	local repo_root
	repo_root=$(
		python3 - "$state_file" <<'PYEOF'
import json, sys

with open(sys.argv[1]) as f:
    state = json.load(f)
print(state.get('repo_root', ''))
PYEOF
	)

	# ANCHOR TRUST AT THE CHECKOUT, NOT AT THE git CALL. Everything below --
	# worktree removal, branch deletion -- is driven by a
	# value parsed out of a JSON file that any writer in the tree can author.
	# Passing that value as BOTH operands of the containment guard asks whether it
	# is inside itself, which is always true, so the guard has to be anchored
	# against something the state file does not control: git's own idea of where
	# the checkout root is. A repo_root that is not a git checkout, or that names
	# a directory whose checkout root is somewhere else, is refused before any
	# destructive command runs.
	if [[ -z "$repo_root" || "$repo_root" != /* ]]; then
		echo "fan-out: refusing repo_root from state file (must be an absolute path): $repo_root" >&2
		exit 1
	fi
	case "/$repo_root/" in
	*/../*)
		echo "fan-out: refusing repo_root from state file (contains '..'): $repo_root" >&2
		exit 1
		;;
	esac

	local resolved repo_root_phys resolved_phys
	resolved="$(git -C "$repo_root" rev-parse --show-toplevel 2>/dev/null || true)"
	if [[ -z "$resolved" ]]; then
		# Checked before the `cd -P` below because `cd ""` succeeds and leaves $PWD
		# alone, which would silently compare the caller's cwd instead of a root.
		echo "fan-out: refusing repo_root from state file (not the root of a git checkout): $repo_root" >&2
		exit 1
	fi
	# Compare in physical form so a checkout reached through a symlinked parent
	# (macOS $TMPDIR under /var -> /private/var) still matches itself, and run
	# both sides through the guard's own normalisation so the verdict cannot turn
	# on a '//', '/./' or trailing-'/' spelling difference.
	repo_root_phys="$(cd -P "$repo_root" 2>/dev/null && pwd -P || true)"
	resolved_phys="$(cd -P "$resolved" 2>/dev/null && pwd -P || true)"
	repo_root_phys="$(fanout_normalise_path "$repo_root_phys")"
	resolved_phys="$(fanout_normalise_path "$resolved_phys")"
	if [[ -z "$resolved_phys" || -z "$repo_root_phys" || "$resolved_phys" != "$repo_root_phys" ]]; then
		echo "fan-out: refusing repo_root from state file (not the root of a git checkout): $repo_root" >&2
		exit 1
	fi

	# THE STATE FILE IS UNTRUSTED, SO IT CHOOSES NOTHING. Every worktree cleanup
	# removes and every branch it deletes comes from git's own worktree listing
	# for THIS checkout, filtered to what `setup` can produce: a path
	# `fanout_worktree_is_ours` accepts (absolute, no '..', a sibling of the repo
	# root, named `<repo-name>-fanout-<task-id>-<slug>`) that git has attached to a branch under
	# `refs/heads/fanout/`. Both halves must hold, so a worktree that merely
	# borrows the sibling naming pattern, or one sitting on an unrelated branch,
	# is not a target however the state file describes it. There is no second
	# authority: `agents[]` is read for a diagnostic only, and naming a path there
	# cannot make cleanup run a git command against it.
	#
	# Read the listing ONCE, before any removal makes it stale. It is also the
	# whole authority for branch names -- a worktree whose directory was deleted
	# by hand is still listed (git marks the entry `prunable`) and still carries
	# its `branch` line, so there is nothing left for a state-file branch
	# fallback to do and none is kept.
	local owned_map
	owned_map="$(git -C "$repo_root" worktree list --porcelain 2>/dev/null |
		awk '
      /^worktree / { wt = substr($0, 10) }
      /^branch /   { if (wt != "") print wt "\t" substr($0, 8) }
      /^$/         { wt = "" }
    ')"

	# Judge each entry in the spelling git printed it in, against the checkout
	# root in the same physical spelling ($repo_root_phys, resolved above): a
	# `/var` vs `/private/var` difference between the two sides is a spelling
	# difference, never a different directory, and must not decide ownership.
	local owned="" owned_canon="" map_path map_ref map_canon
	while IFS=$'\t' read -r map_path map_ref; do
		[[ -n "$map_path" && -n "$map_ref" ]] || continue
		[[ "$map_ref" == refs/heads/fanout/* ]] || continue
		map_canon="$(fanout_canonical_worktree "$map_path")"
		fanout_worktree_is_ours "$map_canon" "$repo_root_phys" || continue
		owned+="$map_path"$'\t'"${map_ref#refs/heads/}"$'\n'
		owned_canon+="$map_canon"$'\n'
	done <<<"$owned_map"

	# Diagnostic pass over the state file. Anything it names that git does not
	# attribute to fan-out is reported and left exactly as it is; no git command
	# runs for it, and nothing here can add a target to the loop below.
	local named_worktrees named named_canon
	named_worktrees="$(
		python3 - "$state_file" <<'PYEOF'
import json, sys

with open(sys.argv[1]) as f:
    state = json.load(f)
for a in state.get('agents', []):
    print(a.get('worktree', ''))
PYEOF
	)"
	while IFS= read -r named; do
		[[ -n "$named" ]] || continue
		named_canon="$(fanout_canonical_worktree "$named")"
		case $'\n'"$owned_canon" in
		*$'\n'"$named_canon"$'\n'*) continue ;;
		esac
		echo "WARNING: state file names a worktree git does not attribute to fan-out; left alone: $named" >&2
	done <<<"$named_worktrees"

	# Drop stale registrations FIRST. A worktree whose directory was deleted by
	# hand is still registered, and git refuses `branch -d` on a branch it thinks
	# is checked out somewhere, so without this the very case the state-file
	# fallback used to cover would leave the branch behind. Safe here because
	# $owned_map was read above and nothing below re-reads the listing.
	git -C "$repo_root" worktree prune 2>/dev/null || true

	# Remove worktrees and branches
	local worktree branch
	while IFS=$'\t' read -r worktree branch; do
		[[ -n "$worktree" && -n "$branch" ]] || continue
		if [[ -d "$worktree" ]]; then
			echo "Removing worktree: $worktree"
			git -C "$repo_root" worktree remove "$worktree" --force 2>/dev/null || true
		fi
		echo "Removing branch: $branch"
		# `--` so a name that survived the checks above is still never parsed as an
		# option by git itself.
		git -C "$repo_root" branch -d -- "$branch" 2>/dev/null ||
			echo "  Branch $branch not fully merged; use -D to force delete" >&2
	done <<<"$owned"

	# Prune worktree references
	git -C "$repo_root" worktree prune 2>/dev/null || true

	# Remove state file
	rm -f "$state_file"
	echo "Cleanup complete. State file removed."
}

# --- main ---
cmd="${1:-help}"
shift || true

case "$cmd" in
tasks) cmd_tasks "$@" ;;
setup) cmd_setup "$@" ;;
spawn) cmd_spawn "$@" ;;
status) cmd_status "$@" ;;
cancel) cmd_cancel "$@" ;;
cleanup) cmd_cleanup "$@" ;;
help | -h | --help) usage ;;
*)
	echo "Unknown command: $cmd" >&2
	usage
	exit 1
	;;
esac
