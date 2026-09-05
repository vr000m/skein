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
fanout_assert_inside_repo() {
  local path="$1" root="$2" label="$3"

  [[ "$path" == /* ]] || path="$PWD/$path"
  [[ "$root" == /* ]] || root="$PWD/$root"
  # Normalise the spelling before any test: `[[ -L "$p/" ]]` is always false,
  # and a '//' run makes `${p%/*}` strip an empty component instead of a real
  # one, so the verdict must not depend on how the caller typed the path.
  while [[ "$path" == *//* ]]; do path="${path//\/\///}"; done
  while [[ "$path" == */ && "$path" != "/" ]]; do path="${path%/}"; done
  while [[ "$root" == *//* ]]; do root="${root//\/\///}"; done
  while [[ "$root" == */ && "$root" != "/" ]]; do root="${root%/}"; done

  # Every check below is lexical, and lexical reasoning is unsound once '..' is
  # in play: `$root/link/../.fanout` with `link` a symlink names a directory
  # beside link's TARGET, not a child of $root. Reject the shape.
  case "/$path/" in
  */../*)
    echo "fan-out: refusing $label containing '..': $path" >&2
    return 1
    ;;
  esac

  if [[ "$path" != "$root"/* ]]; then
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

    # Consume once, before either verdict: the file must not survive this call,
    # so a re-run that did not write a fresh one fails closed above instead of
    # silently reusing a slug from an earlier run or an earlier plan.
    rm -f "$slug_file"

    if [[ "$one_line" -ne 0 ]]; then
      echo "fan-out: refusing task slug (slug file must hold exactly one line): $slug_file" >&2
      exit 1
    fi
  fi

  # Fail closed on any slug that is not <task-id>-<lowercase-slug>. The caller is
  # expected to validate before substituting, so this is the boundary that stops a
  # plan-derived string from reaching git.
  if [[ ! "$task_slug" =~ ^[0-9]+-[a-z0-9-]+$ ]]; then
    echo "fan-out: refusing task slug (must match ^[0-9]+-[a-z0-9-]+\$): $task_slug" >&2
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
print(state.get('repo_root', '.'))
PYEOF
)

  # Remove worktrees and branches
  python3 - "$state_file" <<'PYEOF' | while IFS='|' read -r worktree branch; do
import json, sys

with open(sys.argv[1]) as f:
    state = json.load(f)
for a in state.get('agents', []):
    print(a.get('worktree', '') + '|' + a.get('branch', ''))
PYEOF
    if [[ -n "$worktree" && -d "$worktree" ]]; then
      echo "Removing worktree: $worktree"
      git -C "$repo_root" worktree remove "$worktree" --force 2>/dev/null || true
    fi
    if [[ -n "$branch" ]]; then
      echo "Removing branch: $branch"
      git -C "$repo_root" branch -d "$branch" 2>/dev/null || \
        echo "  Branch $branch not fully merged; use -D to force delete" >&2
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
