#!/usr/bin/env bash
set -euo pipefail

# fan-out.sh — Worktree setup, agent spawning, monitoring, and cleanup
# Companion script for the /fan-out skill.

DEFAULT_MODEL="opus"

usage() {
  cat <<'EOF'
Usage: fan-out.sh <command> [options]

Commands:
  setup   <base-branch> <task-slug> <repo-root>    Create branch + worktree
  spawn   <worktree-path> <prompt-file> <log-file> [--model MODEL]  Launch claude -p
  status  <state-file>                              Check agent PIDs
  cancel  <state-file> [task-id]                    Kill agent(s)
  cleanup <state-file>                              Remove worktrees and branches
  help                                              Show this message

Environment:
  FANOUT_MODEL=opus|sonnet|haiku   Override default model (opus)
EOF
}

slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//' | sed 's/-$//' | cut -c1-50
}

# --- setup: create branch + worktree ---
cmd_setup() {
  local base_branch="$1"
  local task_slug="$2"
  local repo_root="$3"

  local slug
  slug="$(slugify "$task_slug")"
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

  # Parse optional --model flag
  shift 3
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --model) model="$2"; shift 2 ;;
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

  # Launch claude in the worktree directory.
  # Unset CLAUDECODE to allow spawning from within a Claude Code session.
  # exec replaces the subshell so $! is the claude process PID (not a wrapper),
  # which lets cancel verify the process identity before sending SIGTERM.
  (
    cd "$worktree_path"
    unset CLAUDECODE
    exec claude -p "$(cat "$prompt_file")" \
      --dangerously-skip-permissions \
      --model "$model" \
      > "$log_file" 2>&1
  ) &

  local pid=$!
  echo "$pid"
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
