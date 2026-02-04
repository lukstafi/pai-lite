#!/usr/bin/env bash
# pai-lite/adapters/agent-duo.sh - agent-duo (claude + codex) integration
set -euo pipefail

#------------------------------------------------------------------------------
# Source shared helpers
#------------------------------------------------------------------------------

_ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "$_ADAPTER_DIR/helpers.sh" ]]; then
  # shellcheck source=helpers.sh
  source "$_ADAPTER_DIR/helpers.sh"
fi

#------------------------------------------------------------------------------
# Agent-duo specific aliases
#------------------------------------------------------------------------------

adapter_agent_duo_list_sessions() { adapter_list_sessions "$@"; }
adapter_agent_duo_has_sessions() { adapter_has_sessions "$@"; }
adapter_agent_duo_session_count() { adapter_session_count "$@"; }

#------------------------------------------------------------------------------
# Agent-duo port key mappings
#------------------------------------------------------------------------------

_DUO_PORT_KEYS=(ORCHESTRATOR_PORT Orchestrator CLAUDE_PORT Claude CODEX_PORT Codex)

#------------------------------------------------------------------------------
# Slot chunking helpers
#------------------------------------------------------------------------------

adapter_agent_duo_slot_summary() {
  adapter_slot_summary "$@"
}

adapter_agent_duo_all_terminals() {
  adapter_all_terminals "$1" "${_DUO_PORT_KEYS[@]}"
}

adapter_agent_duo_aggregated_status() {
  local project_dir="${1:-.}"
  adapter_aggregated_status "$project_dir"
}

#------------------------------------------------------------------------------
# Session state reader (duo-specific: claude + codex agents)
#------------------------------------------------------------------------------

adapter_agent_duo_read_session_state() {
  local sync_dir="$1"
  local feature="${2:-}"

  [[ -d "$sync_dir" ]] || return 1

  # Read basic state
  local phase="" round="" session="" mode=""
  eval "$(adapter_read_basic_state "$sync_dir")"

  # Output header
  adapter_output_session_header "$session" "$feature"

  # Display agent status (claude + codex)
  if [[ -f "$sync_dir/claude.status" ]] || [[ -f "$sync_dir/codex.status" ]]; then
    echo ""
    echo "**Agents:**"

    if [[ -f "$sync_dir/claude.status" ]]; then
      local claude_status="" claude_timestamp="" claude_message=""
      eval "$(adapter_read_agent_status "$sync_dir/claude.status" "claude")"
      local formatted
      formatted=$(adapter_format_agent_status "$claude_status" "$claude_message")
      [[ -n "$formatted" ]] && echo "- Claude: $formatted"
    fi

    if [[ -f "$sync_dir/codex.status" ]]; then
      local codex_status="" codex_timestamp="" codex_message=""
      eval "$(adapter_read_agent_status "$sync_dir/codex.status" "codex")"
      local formatted
      formatted=$(adapter_format_agent_status "$codex_status" "$codex_message")
      [[ -n "$formatted" ]] && echo "- Codex: $formatted"
    fi
  fi

  # Output terminals
  local ports_file="$sync_dir/ports"
  if [[ -f "$ports_file" ]]; then
    echo ""
    echo "**Terminals:**"
    adapter_output_terminals "$sync_dir" "${_DUO_PORT_KEYS[@]}"
  fi

  # Output runtime
  adapter_output_runtime "$phase" "$round"

  # Display worktree information if available
  local worktrees_file="$sync_dir/worktrees.json"
  if [[ -f "$worktrees_file" ]] && command -v python3 >/dev/null 2>&1; then
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

  # Output error warning
  adapter_output_error_warning "$sync_dir"
}

#------------------------------------------------------------------------------
# Main adapter interface
#------------------------------------------------------------------------------

adapter_agent_duo_read_state() {
  local project_dir="${1:-.}"
  local feature_filter="${2:-}"

  local session_count first=1
  session_count=$(adapter_session_count "$project_dir")

  [[ $session_count -gt 0 ]] || return 1

  echo "**Mode:** agent-duo ($session_count sessions)"
  echo ""

  while IFS=: read -r feature root_worktree peer_sync_path; do
    # If filter specified, skip non-matching sessions
    if [[ -n "$feature_filter" && "$feature" != "$feature_filter" ]]; then
      continue
    fi

    if [[ $first -eq 0 ]]; then
      echo ""
      echo "---"
      echo ""
    fi
    first=0

    echo "### Task: $feature"
    echo "**Root:** $root_worktree"
    adapter_agent_duo_read_session_state "$peer_sync_path" "$feature"
  done < <(adapter_list_sessions "$project_dir")
}

adapter_agent_duo_start() {
  local project_dir="${1:-.}"
  local task_id="${2:-}"
  local session_name="${3:-}"

  echo "agent-duo start: Use the agent-duo CLI to launch sessions." >&2
  echo "" >&2

  local session_count
  session_count=$(adapter_session_count "$project_dir")
  if [[ $session_count -gt 0 ]]; then
    echo "Project has $session_count active sessions." >&2
    echo "" >&2
  fi

  if [[ -n "$task_id" && -n "$session_name" ]]; then
    echo "Suggested command:" >&2
    echo "  cd $project_dir && agent-duo start --session $session_name --task $task_id" >&2
  elif [[ -n "$task_id" ]]; then
    echo "Suggested command:" >&2
    echo "  cd $project_dir && agent-duo start --task $task_id" >&2
  else
    echo "Usage:" >&2
    echo "  cd $project_dir && agent-duo start <feature1> <feature2> ... [--auto-run]" >&2
  fi

  echo "" >&2
  echo "After starting, pai-lite will automatically detect sessions via .agent-sessions/" >&2
  return 1
}

adapter_agent_duo_stop() {
  local project_dir="${1:-.}"
  local feature="${2:-}"

  echo "agent-duo stop: Use the agent-duo CLI to stop sessions." >&2
  echo "" >&2

  local session_count
  session_count=$(adapter_session_count "$project_dir")

  if [[ $session_count -eq 0 ]]; then
    echo "No active agent-duo sessions detected in $project_dir" >&2
    echo "Usage:" >&2
    echo "  cd $project_dir && agent-duo stop [--feature <name>]" >&2
    return 1
  fi

  echo "Project has $session_count active sessions." >&2
  echo "" >&2

  if [[ -n "$feature" ]]; then
    echo "To stop specific feature:" >&2
    echo "  cd $project_dir && agent-duo stop --feature $feature" >&2
  else
    echo "Active sessions:" >&2
    while IFS=: read -r feat _ _; do
      echo "  - $feat" >&2
    done < <(adapter_list_sessions "$project_dir")
    echo "" >&2
    echo "To stop all:" >&2
    echo "  cd $project_dir && agent-duo stop" >&2
    echo "" >&2
    echo "To stop specific feature:" >&2
    echo "  cd $project_dir && agent-duo stop --feature <feature-name>" >&2
  fi

  return 1
}

#------------------------------------------------------------------------------
# Additional helper functions
#------------------------------------------------------------------------------

adapter_agent_duo_watch_phase() {
  local project_dir="${1:-.}"
  local feature_filter="${2:-}"

  local session_count
  session_count=$(adapter_session_count "$project_dir")

  if [[ $session_count -eq 0 ]]; then
    echo "No agent-duo sessions found in $project_dir" >&2
    return 1
  fi

  echo "Watching agent-duo phase changes in $project_dir ($session_count sessions)..."
  echo "Press Ctrl+C to stop."
  echo ""

  declare -A prev_phases prev_rounds

  while true; do
    local any_active=0

    while IFS=: read -r feature _ peer_sync_path; do
      if [[ -n "$feature_filter" && "$feature" != "$feature_filter" ]]; then
        continue
      fi

      if [[ ! -d "$peer_sync_path" ]]; then
        if [[ -n "${prev_phases[$feature]:-}" ]]; then
          echo "[$feature] Session ended"
          unset "prev_phases[$feature]" "prev_rounds[$feature]"
        fi
        continue
      fi

      any_active=1
      local phase="" round=""
      phase=$(adapter_read_state_file "$peer_sync_path/phase")
      round=$(adapter_read_state_file "$peer_sync_path/round")

      if [[ "$phase" != "${prev_phases[$feature]:-}" || "$round" != "${prev_rounds[$feature]:-}" ]]; then
        local timestamp
        timestamp=$(date "+%Y-%m-%d %H:%M:%S")
        echo "[$timestamp] [$feature] Phase: $phase, Round: $round"
        prev_phases[$feature]="$phase"
        prev_rounds[$feature]="$round"
      fi
    done < <(adapter_list_sessions "$project_dir")

    if [[ $any_active -eq 0 ]]; then
      echo "All sessions ended"
      break
    fi

    sleep 5
  done
}

adapter_agent_duo_get_status() {
  local project_dir="${1:-.}"
  local feature_filter="${2:-}"

  local session_count
  session_count=$(adapter_session_count "$project_dir")

  if [[ $session_count -eq 0 ]]; then
    echo "inactive"
    return 1
  fi

  # If specific feature requested, return just that status
  if [[ -n "$feature_filter" ]]; then
    while IFS=: read -r feature _ peer_sync_path; do
      if [[ "$feature" == "$feature_filter" ]]; then
        adapter_get_phase_status "$peer_sync_path"
        return 0
      fi
    done < <(adapter_list_sessions "$project_dir")
    echo "inactive"
    return 1
  fi

  echo "active ($session_count sessions)"
}
