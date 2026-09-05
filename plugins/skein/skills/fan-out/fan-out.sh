#!/usr/bin/env bash
set -euo pipefail

# fan-out.sh — Worktree setup, agent spawning, monitoring, and cleanup
# Companion script for the /fan-out skill.

DEFAULT_MODEL="sonnet"
DEFAULT_EFFORT="medium"

usage() {
  cat <<'EOF'
Usage: fan-out.sh <command> [options]

Commands:
  setup   <base-branch> <task-slug> <repo-root>    Create branch + worktree
          Compatibility/test-only call shape: the slug is spelled on the
          command line, so it skips the slug-file containment and
          consume-once guarantees. The skill always uses --slug-file.
  setup   <base-branch> --slug-file <path> <repo-root>
          Same, with the slug read from <path> instead of from the command
          line, so no plan-derived byte is ever spelled in a shell command.
          The file must sit inside <repo-root>, must not be reached through a
          symlink, and must hold exactly one line (one optional trailing
          newline, nothing after it). It is deleted as soon as it is read, so
          every call consumes a file its own caller has just written and a
          stale file from an earlier run cannot be picked up.
          <task-slug> must be <task-id>-<slug>: digits, then '-', then
          [a-z0-9-]; and already in slugify normal form (no '--', no leading
          or trailing '-', 50 characters or fewer). Anything slugify would
          rewrite is refused.
  spawn   <worktree-path> <prompt-file> <log-file> [--model MODEL] [--effort LEVEL]  Launch claude -p
  status  <state-file>                              Check agent PIDs
  cancel  <state-file> [task-id]                    Kill agent(s)
  cleanup <state-file>                              Remove worktrees, branches,
                                                    <repo-root>/.fanout/ and the
                                                    state file
  help                                              Show this message

Environment:
  FANOUT_MODEL=opus|sonnet|haiku   Override default model (sonnet)
  FANOUT_EFFORT=high|medium|low   Override default effort (medium)
EOF
}

slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//' | sed 's/-$//' | cut -c1-50
}

# --- containment guard for the slug-file transport and .fanout/ ------------
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
  # in play: `$root/link/../.fanout` with `link` a symlink names a directory
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
# cleanup reads worktree paths out of the state file, so before handing one to
# `git worktree remove --force` it must be a path this script could itself have
# created: absolute, no '..', a sibling of the repo root, and named
# `<repo-name>-fanout-*`. Anything else is a path the state file chose, not one
# fan-out made, and is skipped rather than removed.
fanout_worktree_is_ours() {
  local wt="$1" root="$2"

  [[ "$wt" == /* ]] || return 1
  case "/$wt/" in
  */../*) return 1 ;;
  esac
  wt="$(fanout_normalise_path "$wt")"
  root="$(fanout_normalise_path "$root")"
  [[ "$(dirname "$wt")" == "$(dirname "$root")" ]] || return 1
  [[ "$(basename "$wt")" == "$(basename "$root")-fanout-"* ]] || return 1
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

# Which branch does THIS checkout have attached to <worktree>? <map> is the
# tab-separated `<path>\t<ref>` listing built once from `git worktree list
# --porcelain`. Prints the short branch name and returns 0 on a hit, returns 1
# otherwise. This is how cleanup learns a branch name from git rather than from
# the state file.
fanout_branch_for_worktree() {
  local wt="$1" map="$2" path ref
  wt="$(fanout_canonical_path "$wt")"
  while IFS=$'\t' read -r path ref; do
    [[ -n "$path" && -n "$ref" ]] || continue
    [[ "$(fanout_canonical_path "$path")" == "$wt" ]] || continue
    printf '%s' "${ref#refs/heads/}"
    return 0
  done <<<"$map"
  return 1
}

# --- setup: create branch + worktree ---
cmd_setup() {
  local base_branch="${1:-}"
  shift || true

  # Two call shapes: the positional `<task-slug> <repo-root>` form, and the
  # `--slug-file <path> <repo-root>` form the skill uses, where the slug never
  # appears in a shell command at all.
  local task_slug="" slug_file="" repo_root=""
  if [[ "${1:-}" == "--slug-file" ]]; then
    if [[ $# -lt 3 ]]; then
      echo "fan-out: setup --slug-file requires <path> <repo-root>" >&2
      exit 1
    fi
    slug_file="$2"
    repo_root="$3"
  else
    task_slug="${1:-}"
    repo_root="${2:-}"
  fi

  if [[ -n "$slug_file" ]]; then
    # Guard the transport before touching it: `.fanout/` is gitignored, but a
    # TRACKED symlink at that path still materialises on checkout, and reading
    # through it would let a malicious clone choose which file is consumed.
    fanout_assert_inside_repo "$slug_file" "$repo_root" "slug file" || exit 1
    fanout_assert_inside_repo "$repo_root/.fanout" "$repo_root" "slug directory" || exit 1

    if [[ ! -f "$slug_file" ]]; then
      # Fail closed rather than falling back: the file is written immediately
      # before this call, so a missing one means no fresh slug exists.
      echo "fan-out: missing slug file: $slug_file" >&2
      exit 1
    fi

    # Read the FIRST LINE RAW -- no `tr -d`, no trimming. Normalising here
    # would rewrite a hostile value (`1-foo\n-bar`) into a shape the guard
    # below accepts, which is the validation bypass this transport exists to
    # avoid. Instead the file's whole content must BE the slug, with at most
    # one trailing newline; anything else is refused.
    local one_line=1
    # `read` returns non-zero on a file with no trailing newline while still
    # assigning the value, so the failure is tolerated, never used to clear it.
    IFS= read -r task_slug <"$slug_file" || true
    if printf '%s\n' "$task_slug" | cmp -s - "$slug_file" ||
      printf '%s' "$task_slug" | cmp -s - "$slug_file"; then
      one_line=0
    fi

    # Re-check for a symlink AFTER the read. bash cannot open with O_NOFOLLOW,
    # so the pre-read guard and the read are two operations with a window
    # between them; re-testing here narrows that window to the read itself and
    # refuses a file that became a symlink across it. The residual race needs a
    # writer already inside the checkout, and all it can win is a refusal:
    # nothing read from the file is echoed on any slug-file refusal path, so an
    # attacker who wins the window learns neither the bytes nor whether they
    # would have been accepted.
    local raced=0
    if [[ -L "$slug_file" ]]; then
      raced=1
    fi

    # Consume once, before either verdict: the file must not survive this call,
    # so a re-run that did not write a fresh one fails closed above instead of
    # silently reusing a slug from an earlier run or an earlier plan. `rm -f`
    # on a symlink unlinks the link itself, never the target.
    rm -f "$slug_file"

    if [[ "$raced" -ne 0 ]]; then
      echo "fan-out: refusing task slug (slug file became a symlink while it was read): $slug_file" >&2
      exit 1
    fi

    if [[ "$one_line" -ne 0 ]]; then
      echo "fan-out: refusing task slug (slug file must hold exactly one line): $slug_file" >&2
      exit 1
    fi
  fi

  # Fail closed on any slug that is not <task-id>-<lowercase-slug>. The caller is
  # expected to validate before substituting, so this is the boundary that stops a
  # plan-derived string from reaching git.
  #
  # In slug-file mode the refusal names the FILE and the rule, never the value:
  # the value is file-derived, and echoing it would hand a writer inside the
  # checkout a read-back oracle for bytes this process refused to use. The
  # positional form may still echo its argv value, which the caller already has.
  if [[ ! "$task_slug" =~ ^[0-9]+-[a-z0-9-]+$ ]]; then
    if [[ -n "$slug_file" ]]; then
      echo "fan-out: refusing task slug (must match ^[0-9]+-[a-z0-9-]+\$) from slug file: $slug_file" >&2
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
    if [[ -n "$slug_file" ]]; then
      echo "fan-out: refusing task slug (not in slugify normal form) from slug file: $slug_file" >&2
    else
      echo "fan-out: refusing task slug (would be rewritten by slugify to '$slug'): $task_slug" >&2
    fi
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

# --- spawn: launch claude agent in background ---
cmd_spawn() {
  local worktree_path="$1"
  local prompt_file="$2"
  local log_file="$3"
  local model="${FANOUT_MODEL:-$DEFAULT_MODEL}"
  local effort="${FANOUT_EFFORT:-$DEFAULT_EFFORT}"

  # Parse optional --model / --effort flags
  shift 3
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --model)
        if [[ $# -lt 2 ]]; then
          echo "ERROR: --model requires a value" >&2
          return 1
        fi
        model="$2"
        shift 2
        ;;
      --effort)
        if [[ $# -lt 2 ]]; then
          echo "ERROR: --effort requires a value" >&2
          return 1
        fi
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

  local -a cmd_args
  cmd_args=(claude -p "$(cat "$prompt_file")" --dangerously-skip-permissions --model "$model")
  if [[ -n "$effort" ]]; then
    if command_supports_effort claude; then
      cmd_args+=(--effort "$effort")
    else
      echo "WARNING: --effort '$effort' requested but the resolved Claude command 'claude' does not advertise --effort; effort intent NOT applied." >&2
    fi
  fi

  # Launch claude in the worktree directory.
  # Unset CLAUDECODE to allow spawning from within a Claude Code session.
  # exec replaces the subshell so $! is the claude process PID (not a wrapper),
  # which lets cancel verify the process identity before sending SIGTERM.
  (
    cd "$worktree_path"
    unset CLAUDECODE
    exec "${cmd_args[@]}" > "$log_file" 2>&1
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
  agent_count=$(python3 - "$state_file" <<'PYEOF'
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

def is_claude_process(pid):
    """Verify PID is still a claude process (not a reused PID)."""
    try:
        result = subprocess.run(
            ['ps', '-p', str(pid), '-o', 'args='],
            capture_output=True, text=True, timeout=5
        )
        return result.returncode == 0 and 'claude' in result.stdout
    except Exception:
        return False

for agent in state.get('agents', []):
    tid = str(agent.get('task_id', ''))
    pid = agent.get('pid', 0)
    name = agent.get('task_name', 'unknown')

    if target != 'all' and tid != target:
        continue

    if pid <= 0:
        print(f'Agent {tid} ({name}) has invalid PID {pid} — skipping')
        continue

    if not is_claude_process(pid):
        print(f'Agent {tid} ({name}) PID {pid} is no longer a claude process — skipping')
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
  still_running=$(python3 - "$state_file" <<'PYEOF'
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
  repo_root=$(python3 - "$state_file" <<'PYEOF'
import json, sys

with open(sys.argv[1]) as f:
    state = json.load(f)
print(state.get('repo_root', ''))
PYEOF
)

  # ANCHOR TRUST AT THE CHECKOUT, NOT AT THE rm. Everything below -- worktree
  # removal, branch deletion, `rm -rf "$repo_root/.fanout"` -- is driven by a
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

  # THE BRANCH NAME COMES FROM GIT, NOT FROM THE STATE FILE. `repo_root` and
  # `worktree` are already anchored above; `branch` was not, and it reached
  # `git branch -d` verbatim, so a state file authored anywhere in the tree
  # could name any merged local branch (or an option-like value). Read git's own
  # worktree listing ONCE, before any removal makes it stale, and derive each
  # branch from the owned worktree it is attached to.
  local owned_map
  owned_map="$(git -C "$repo_root" worktree list --porcelain 2>/dev/null |
    awk '
      /^worktree / { wt = substr($0, 10) }
      /^branch /   { if (wt != "") print wt "\t" substr($0, 8) }
      /^$/         { wt = "" }
    ')"

  # Remove worktrees and branches
  python3 - "$state_file" <<'PYEOF' | while IFS='|' read -r worktree branch; do
import json, sys

with open(sys.argv[1]) as f:
    state = json.load(f)
for a in state.get('agents', []):
    print(a.get('worktree', '') + '|' + a.get('branch', ''))
PYEOF
    # Resolve the branch BEFORE the worktree is removed: once it is gone git has
    # no listing left to derive it from.
    local branch_to_delete=""
    if [[ -n "$worktree" ]] && fanout_worktree_is_ours "$worktree" "$repo_root"; then
      branch_to_delete="$(fanout_branch_for_worktree "$worktree" "$owned_map")" || branch_to_delete=""
    fi

    if [[ -n "$worktree" && -d "$worktree" ]]; then
      if fanout_worktree_is_ours "$worktree" "$repo_root"; then
        echo "Removing worktree: $worktree"
        git -C "$repo_root" worktree remove "$worktree" --force 2>/dev/null || true
      else
        echo "WARNING: skipping worktree the state file names but fan-out could not have created: $worktree" >&2
      fi
    fi

    if [[ -z "$branch_to_delete" && -n "$branch" ]]; then
      # No owned worktree carries this branch any more (the usual case: the
      # worktree was already removed by hand). The state file's own value is
      # usable only in the shape `setup` can produce -- `fanout/` plus a slugify
      # normal-form tail -- so a name fan-out could not have created, including
      # anything option-like, is skipped rather than deleted.
      if [[ "$branch" =~ ^fanout/[a-z0-9-]+$ ]]; then
        branch_to_delete="$branch"
      else
        echo "WARNING: skipping branch the state file names but fan-out could not have created: $branch" >&2
      fi
    fi

    if [[ -n "$branch_to_delete" ]]; then
      echo "Removing branch: $branch_to_delete"
      # `--` so a name that survived the checks above is still never parsed as
      # an option by git itself.
      git -C "$repo_root" branch -d -- "$branch_to_delete" 2>/dev/null || \
        echo "  Branch $branch_to_delete not fully merged; use -D to force delete" >&2
    fi
  done

  # Prune worktree references
  git -C "$repo_root" worktree prune 2>/dev/null || true

  # Remove the slug transport directory. `setup --slug-file` consumes each file
  # it reads, so this only ever removes an aborted run's leftovers -- but the
  # skill creates the directory, so cleanup owns removing it.
  if [[ -n "$repo_root" ]] && fanout_assert_inside_repo "$repo_root/.fanout" "$repo_root" "slug directory"; then
    if [[ -d "$repo_root/.fanout" ]]; then
      echo "Removing slug directory: $repo_root/.fanout"
      rm -rf "$repo_root/.fanout"
    fi
  fi

  # Remove state file
  rm -f "$state_file"
  echo "Cleanup complete. State file removed."
}

# --- main ---
cmd="${1:-help}"
shift || true

case "$cmd" in
  setup)   cmd_setup "$@" ;;
  spawn)   cmd_spawn "$@" ;;
  status)  cmd_status "$@" ;;
  cancel)  cmd_cancel "$@" ;;
  cleanup) cmd_cleanup "$@" ;;
  help|-h|--help) usage ;;
  *) echo "Unknown command: $cmd" >&2; usage; exit 1 ;;
esac
