#!/usr/bin/env bash
set -euo pipefail

adapter_agent_duo_read_state() {
  local project_dir="${1:-.}"
  local sync_dir="$project_dir/.peer-sync"

  [[ -d "$sync_dir" ]] || return 1

  local phase="" round="" session="" feature="" mode=""

  # Read from individual files (primary format)
  [[ -f "$sync_dir/phase" ]] && phase=$(cat "$sync_dir/phase" 2>/dev/null | tr -d '\n')
  [[ -f "$sync_dir/round" ]] && round=$(cat "$sync_dir/round" 2>/dev/null | tr -d '\n')
  [[ -f "$sync_dir/session" ]] && session=$(cat "$sync_dir/session" 2>/dev/null | tr -d '\n')
  [[ -f "$sync_dir/feature" ]] && feature=$(cat "$sync_dir/feature" 2>/dev/null | tr -d '\n')
  [[ -f "$sync_dir/mode" ]] && mode=$(cat "$sync_dir/mode" 2>/dev/null | tr -d '\n')

  # Fallback to JSON state file if individual files don't exist
  if [[ -z "$phase" && -z "$session" ]]; then
    local state_file="$sync_dir/state.json"
    if [[ -f "$state_file" ]] && command -v python3 >/dev/null 2>&1; then
      read -r phase round session feature mode <<<"$(python3 - "$state_file" <<'PY'
import json,sys
try:
    data = json.load(open(sys.argv[1]))
    print(
        data.get("phase",""),
        data.get("round",""),
        data.get("session",""),
        data.get("feature",""),
        data.get("mode","")
    )
except Exception:
    print("", "", "", "", "")
PY
)"
    fi
  fi

  echo "**Mode:** agent-duo"
  [[ -n "$session" ]] && echo "**Session:** $session"
  [[ -n "$feature" ]] && echo "**Feature:** $feature"

  # Display agent status
  if [[ -f "$sync_dir/claude.status" ]] || [[ -f "$sync_dir/codex.status" ]]; then
    echo ""
    echo "**Agents:**"
    if [[ -f "$sync_dir/claude.status" ]]; then
      local claude_status_line claude_agent_status claude_agent_timestamp claude_agent_message
      claude_status_line=$(cat "$sync_dir/claude.status" 2>/dev/null)
      IFS='|' read -r claude_agent_status claude_agent_timestamp claude_agent_message <<< "$claude_status_line"
      if [[ -n "$claude_agent_status" ]]; then
        if [[ -n "$claude_agent_message" ]]; then
          echo "- Claude: $claude_agent_status - $claude_agent_message"
        else
          echo "- Claude: $claude_agent_status"
        fi
      fi
    fi
    if [[ -f "$sync_dir/codex.status" ]]; then
      local codex_status_line codex_agent_status codex_agent_timestamp codex_agent_message
      codex_status_line=$(cat "$sync_dir/codex.status" 2>/dev/null)
      IFS='|' read -r codex_agent_status codex_agent_timestamp codex_agent_message <<< "$codex_status_line"
      if [[ -n "$codex_agent_status" ]]; then
        if [[ -n "$codex_agent_message" ]]; then
          echo "- Codex: $codex_agent_status - $codex_agent_message"
        else
          echo "- Codex: $codex_agent_status"
        fi
      fi
    fi
  fi

  # Parse ports file (shell variable format)
  local ports_file="$sync_dir/ports"
  if [[ -f "$ports_file" ]]; then
    echo ""
    echo "**Terminals:**"
    while IFS='=' read -r key value; do
      case "$key" in
        ORCHESTRATOR_PORT)
          echo "- Orchestrator: http://localhost:$value"
          ;;
        CLAUDE_PORT)
          echo "- Claude: http://localhost:$value"
          ;;
        CODEX_PORT)
          echo "- Codex: http://localhost:$value"
          ;;
      esac
    done < "$ports_file"
  else
    # Fallback to JSON ports file
    local ports_json="$sync_dir/ports.json"
    if [[ -f "$ports_json" ]] && command -v python3 >/dev/null 2>&1; then
      python3 - "$ports_json" <<'PY'
import json,sys
try:
    ports = json.load(open(sys.argv[1]))
    for key,label in [("orchestrator","Orchestrator"),("claude","Claude"),("codex","Codex")]:
        if key in ports:
            print(f"- {label}: http://localhost:{ports[key]}")
except Exception:
    pass
PY
    fi
  fi

  if [[ -n "$phase" || -n "$round" ]]; then
    echo ""
    echo "**Runtime:**"
    [[ -n "$phase" ]] && echo "- Phase: $phase"
    [[ -n "$round" ]] && echo "- Round: $round"
  fi

  # Display worktree information if available
  local worktrees_file="$sync_dir/worktrees.json"
  if [[ -f "$worktrees_file" ]]; then
    if command -v python3 >/dev/null 2>&1; then
      local worktrees_info
      worktrees_info=$(python3 - "$worktrees_file" <<'PY'
import json,sys
try:
    data = json.load(open(sys.argv[1]))
    if "claude" in data or "codex" in data:
        print("yes")
        if "claude" in data:
            print(f"claude:{data['claude']}")
        if "codex" in data:
            print(f"codex:{data['codex']}")
except Exception:
    pass
PY
)
      if [[ -n "$worktrees_info" ]]; then
        echo ""
        echo "**Git:**"
        echo "$worktrees_info" | while IFS=: read -r agent path; do
          [[ "$agent" == "yes" ]] && continue
          echo "- $agent worktree: $path"
        done
      fi
    fi
  fi

  # Check for error state
  if [[ -f "$sync_dir/error.log" ]]; then
    local error_count
    error_count=$(wc -l < "$sync_dir/error.log" 2>/dev/null | tr -d ' ')
    if [[ -n "$error_count" && "$error_count" -gt 0 ]]; then
      echo ""
      echo "**Warnings:**"
      echo "- Error log has $error_count entries"
    fi
  fi
}

adapter_agent_duo_start() {
  local project_dir="${1:-.}"
  local task_id="${2:-}"
  local session_name="${3:-}"

  echo "agent-duo start: Use the agent-duo CLI to launch sessions." >&2
  echo "" >&2

  if [[ -n "$task_id" && -n "$session_name" ]]; then
    echo "Suggested command:" >&2
    echo "  cd $project_dir && agent-duo start --session $session_name --task $task_id" >&2
  elif [[ -n "$task_id" ]]; then
    echo "Suggested command:" >&2
    echo "  cd $project_dir && agent-duo start --task $task_id" >&2
  else
    echo "Usage:" >&2
    echo "  cd $project_dir && agent-duo start [--session <name>] [--task <task-id>]" >&2
  fi

  echo "" >&2
  echo "After starting, pai-lite will automatically detect the session via .peer-sync/" >&2
  return 1
}

adapter_agent_duo_stop() {
  local project_dir="${1:-.}"
  local sync_dir="$project_dir/.peer-sync"

  echo "agent-duo stop: Use the agent-duo CLI to stop sessions." >&2
  echo "" >&2

  # Try to provide helpful context
  if [[ -d "$sync_dir" ]]; then
    local session_name=""
    # Try individual file first
    if [[ -f "$sync_dir/session" ]]; then
      session_name=$(cat "$sync_dir/session" 2>/dev/null | tr -d '\n')
    elif [[ -f "$sync_dir/state.json" ]] && command -v python3 >/dev/null 2>&1; then
      session_name=$(python3 - "$sync_dir/state.json" <<'PY'
import json,sys
try:
    data = json.load(open(sys.argv[1]))
    print(data.get("session",""))
except Exception:
    pass
PY
)
    fi

    if [[ -n "$session_name" ]]; then
      echo "Active session detected: $session_name" >&2
      echo "Suggested command:" >&2
      echo "  cd $project_dir && agent-duo stop --session $session_name" >&2
    else
      echo "Suggested command:" >&2
      echo "  cd $project_dir && agent-duo stop" >&2
    fi
  else
    echo "No active agent-duo session detected in $project_dir" >&2
    echo "Usage:" >&2
    echo "  cd <project-dir> && agent-duo stop [--session <name>]" >&2
  fi

  return 1
}

#------------------------------------------------------------------------------
# Additional helper functions
#------------------------------------------------------------------------------

adapter_agent_duo_watch_phase() {
  local project_dir="${1:-.}"
  local sync_dir="$project_dir/.peer-sync"

  if [[ ! -d "$sync_dir" ]] || { [[ ! -f "$sync_dir/phase" ]] && [[ ! -f "$sync_dir/state.json" ]]; }; then
    echo "No agent-duo session found in $project_dir" >&2
    return 1
  fi

  echo "Watching agent-duo phase changes in $project_dir..."
  echo "Press Ctrl+C to stop."
  echo ""

  local prev_phase="" prev_round=""

  while true; do
    if [[ ! -d "$sync_dir" ]]; then
      echo "Session ended (.peer-sync removed)"
      break
    fi

    local phase="" round=""

    # Try individual files first
    if [[ -f "$sync_dir/phase" ]]; then
      phase=$(cat "$sync_dir/phase" 2>/dev/null | tr -d '\n')
    fi
    if [[ -f "$sync_dir/round" ]]; then
      round=$(cat "$sync_dir/round" 2>/dev/null | tr -d '\n')
    fi

    # Fallback to JSON
    if [[ -z "$phase" && -f "$sync_dir/state.json" ]] && command -v python3 >/dev/null 2>&1; then
      read -r phase round <<<"$(python3 - "$sync_dir/state.json" <<'PY'
import json,sys
try:
    data = json.load(open(sys.argv[1]))
    print(data.get("phase",""), data.get("round",""))
except Exception:
    print("", "")
PY
)"
    fi

    if [[ -z "$phase" && -z "$round" ]]; then
      echo "Session ended (no state files)"
      break
    fi

    if [[ "$phase" != "$prev_phase" || "$round" != "$prev_round" ]]; then
      local timestamp
      timestamp=$(date "+%Y-%m-%d %H:%M:%S")
      echo "[$timestamp] Phase: $phase, Round: $round"
      prev_phase="$phase"
      prev_round="$round"
    fi

    sleep 5
  done
}

adapter_agent_duo_get_status() {
  local project_dir="${1:-.}"
  local sync_dir="$project_dir/.peer-sync"

  if [[ ! -d "$sync_dir" ]]; then
    echo "inactive"
    return 1
  fi

  local phase="" round=""

  # Try individual files first
  [[ -f "$sync_dir/phase" ]] && phase=$(cat "$sync_dir/phase" 2>/dev/null | tr -d '\n')
  [[ -f "$sync_dir/round" ]] && round=$(cat "$sync_dir/round" 2>/dev/null | tr -d '\n')

  # Fallback to JSON
  if [[ -z "$phase" && -f "$sync_dir/state.json" ]] && command -v python3 >/dev/null 2>&1; then
    read -r phase round <<<"$(python3 - "$sync_dir/state.json" <<'PY'
import json,sys
try:
    data = json.load(open(sys.argv[1]))
    print(data.get("phase",""), data.get("round",""))
except Exception:
    print("", "")
PY
)"
  fi

  if [[ -n "$phase" && -n "$round" ]]; then
    echo "$phase (round $round)"
  elif [[ -n "$phase" ]]; then
    echo "$phase"
  else
    echo "active"
  fi
}
