#!/usr/bin/env bash
set -euo pipefail

# fan-out.sh — Worktree setup, agent spawning, monitoring, and cleanup
# Companion script for the /fan-out skill.

DEFAULT_CMD="codex"
DEFAULT_PROMPT_FLAG="-p"
DEFAULT_PROMPT_MODE="inline"
DEFAULT_PERMS_FLAG=""
DEFAULT_MODEL=""

usage() {
  cat <<'EOF'
Usage: fan-out.sh <command> [options]

Commands:
  setup   <base-branch> <task-slug> <repo-root>    Create branch + worktree
  spawn   <worktree-path> <prompt-file> <log-file> [--model MODEL]  Launch codex
  status  <state-file>                              Check agent PIDs
  cancel  <state-file> [task-id]                    Kill agent(s)
  cleanup <state-file>                              Remove worktrees and branches
  help                                              Show this message

Environment:
  FANOUT_CMD=codex                Override command (default: codex)
  FANOUT_PROMPT_FLAG=-p           Override prompt flag (default: -p)
  FANOUT_PROMPT_MODE=inline|file  Whether to pass inline prompt text or a file path
  FANOUT_PERMS_FLAG=              Permission flag(s), if needed
  FANOUT_EXTRA_ARGS=              Extra args appended to the command
  FANOUT_MODEL=                   Default model (optional)
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

  local prompt_value
  if [[ "$prompt_mode" == "file" ]]; then
    prompt_value="$prompt_file"
  else
    prompt_value="$(cat "$prompt_file")"
  fi

  local -a cmd_args
  cmd_args=("$cmd" "$prompt_flag" "$prompt_value")
  if [[ -n "$perms_flag" ]]; then
    read -r -a perms_split <<< "$perms_flag"
    cmd_args+=("${perms_split[@]}")
  fi
  if [[ -n "$model" ]]; then
    cmd_args+=("--model" "$model")
  fi
  if [[ -n "$extra_args" ]]; then
    read -r -a extra_split <<< "$extra_args"
    cmd_args+=("${extra_split[@]}")
  fi

  # Launch codex in the worktree directory.
  # Unset Codex session markers so child agents run as independent sessions.
  # exec replaces the subshell so $! is the codex process PID (not a wrapper),
  # which lets cancel verify the process identity before sending SIGTERM.
  (
    cd "$worktree_path"
    unset CODEX_SHELL CODEX_THREAD_ID CODEX_INTERNAL_ORIGINATOR_OVERRIDE
    exec "${cmd_args[@]}" > "$log_file" 2>&1
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
