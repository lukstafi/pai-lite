#!/usr/bin/env bash
# pai-lite/adapters/agent-solo.sh - agent-solo (coder + reviewer) integration
# Uses the same .peer-sync/ structure as agent-duo but with solo workflow
set -euo pipefail

#------------------------------------------------------------------------------
# Source shared helpers
#------------------------------------------------------------------------------

_ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "$_ADAPTER_DIR/helpers.sh" ]]; then
  # shellcheck disable=SC1091 source=helpers.sh
  source "$_ADAPTER_DIR/helpers.sh"
fi

#------------------------------------------------------------------------------
# Agent-solo specific aliases and config
#------------------------------------------------------------------------------

adapter_agent_solo_list_sessions() { adapter_list_sessions "$@"; }
adapter_agent_solo_has_sessions() { adapter_has_sessions "$@"; }
adapter_agent_solo_session_count() { adapter_session_count "$1" "solo"; }

# Solo port key mappings (coder + reviewer instead of claude + codex)
_SOLO_PORT_KEYS=(ORCHESTRATOR_PORT Orchestrator CODER_PORT Coder REVIEWER_PORT Reviewer)

#------------------------------------------------------------------------------
# Slot chunking helpers
#------------------------------------------------------------------------------

adapter_agent_solo_slot_summary() {
  adapter_slot_summary "$1" "solo"
}

adapter_agent_solo_all_terminals() {
  adapter_all_terminals "$1" "${_SOLO_PORT_KEYS[@]}" "solo"
}

adapter_agent_solo_aggregated_status() {
  local project_dir="${1:-.}"
  adapter_aggregated_status "$project_dir" "solo"
}

#------------------------------------------------------------------------------
# Session state reader (solo-specific: coder + reviewer roles)
#------------------------------------------------------------------------------

adapter_agent_solo_read_session_state() {
  local sync_dir="$1"
  local feature="${2:-}"

  [[ -d "$sync_dir" ]] || return 1

  # Read basic state
  local phase="" round="" session="" mode=""
  eval "$(adapter_read_basic_state "$sync_dir")"

  # Output header
  adapter_output_session_header "$session" "$feature"

  # Display agent status (coder + reviewer)
  if [[ -f "$sync_dir/coder.status" ]] || [[ -f "$sync_dir/reviewer.status" ]]; then
    echo ""
    echo "**Roles:**"

    if [[ -f "$sync_dir/coder.status" ]]; then
      # shellcheck disable=SC2034 # coder_timestamp set via eval
      local coder_status="" coder_timestamp="" coder_message=""
      eval "$(adapter_read_agent_status "$sync_dir/coder.status" "coder")"
      local formatted
      formatted=$(adapter_format_agent_status "$coder_status" "$coder_message")
      [[ -n "$formatted" ]] && echo "- Coder: $formatted"
    fi

    if [[ -f "$sync_dir/reviewer.status" ]]; then
      # shellcheck disable=SC2034 # reviewer_timestamp set via eval
      local reviewer_status="" reviewer_timestamp="" reviewer_message=""
      eval "$(adapter_read_agent_status "$sync_dir/reviewer.status" "reviewer")"
      local formatted
      formatted=$(adapter_format_agent_status "$reviewer_status" "$reviewer_message")
      [[ -n "$formatted" ]] && echo "- Reviewer: $formatted"
    fi
  fi

  # Output terminals
  local ports_file="$sync_dir/ports"
  if [[ -f "$ports_file" ]]; then
    echo ""
    echo "**Terminals:**"
    adapter_output_terminals "$sync_dir" "${_SOLO_PORT_KEYS[@]}"
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
    if "coder" in data or "reviewer" in data:
        print("yes")
        if "coder" in data:
            print(f"coder:{data['coder']}")
        if "reviewer" in data:
            print(f"reviewer:{data['reviewer']}")
except Exception:
    pass
PY
)
    if [[ -n "$worktrees_info" ]]; then
      echo ""
      echo "**Git:**"
      echo "$worktrees_info" | while IFS=: read -r role path; do
        [[ "$role" == "yes" ]] && continue
        echo "- $role worktree: $path"
      done
    fi
  fi

  # Output error warning
  adapter_output_error_warning "$sync_dir"
}

#------------------------------------------------------------------------------
# Main adapter interface
#------------------------------------------------------------------------------

adapter_agent_solo_read_state() {
  local project_dir="${1:-.}"
  local feature_filter="${2:-}"

  local session_count first=1
  session_count=$(adapter_session_count "$project_dir" "solo")

  [[ $session_count -gt 0 ]] || return 1

  echo "**Mode:** agent-solo ($session_count sessions)"
  echo ""

  while IFS=: read -r feature root_worktree peer_sync_path; do
    # If filter specified, skip non-matching sessions
    if [[ -n "$feature_filter" && "$feature" != "$feature_filter" ]]; then
      continue
    fi

    # Check if this is actually a solo session (mode=solo)
    local mode=""
    mode=$(adapter_read_state_file "$peer_sync_path/mode")
    [[ "$mode" == "solo" ]] || continue

    if [[ $first -eq 0 ]]; then
      echo ""
      echo "---"
      echo ""
    fi
    first=0

    echo "### Task: $feature"
    echo "**Root:** $root_worktree"
    adapter_agent_solo_read_session_state "$peer_sync_path" "$feature"
  done < <(adapter_list_sessions "$project_dir")
}

adapter_agent_solo_start() {
  local project_dir="${1:-.}"
  local task_id="${2:-}"
  local session_name="${3:-}"

  echo "agent-solo start: Use the agent-duo CLI with --mode solo to launch sessions." >&2
  echo "" >&2

  local session_count
  session_count=$(adapter_session_count "$project_dir" "solo")
  if [[ $session_count -gt 0 ]]; then
    echo "Project has $session_count solo sessions." >&2
    echo "" >&2
  fi

  if [[ -n "$task_id" && -n "$session_name" ]]; then
    echo "Suggested command:" >&2
    echo "  cd $project_dir && agent-duo start --mode solo --session $session_name --task $task_id" >&2
  elif [[ -n "$task_id" ]]; then
    echo "Suggested command:" >&2
    echo "  cd $project_dir && agent-duo start --mode solo --task $task_id" >&2
  else
    echo "Usage:" >&2
    echo "  cd $project_dir && agent-duo start --mode solo <feature1> <feature2> ... [--auto-run]" >&2
  fi

  echo "" >&2
  echo "After starting, pai-lite will automatically detect sessions via .agent-sessions/" >&2
  return 1
}

adapter_agent_solo_stop() {
  local project_dir="${1:-.}"
  local feature="${2:-}"

  echo "agent-solo stop: Use the agent-duo CLI to stop sessions." >&2
  echo "" >&2

  local session_count
  session_count=$(adapter_session_count "$project_dir" "solo")

  if [[ $session_count -eq 0 ]]; then
    echo "No active agent-solo sessions detected in $project_dir" >&2
    echo "Usage:" >&2
    echo "  cd $project_dir && agent-duo stop --mode solo [--feature <name>]" >&2
    return 1
  fi

  echo "Project has $session_count solo sessions." >&2
  echo "" >&2

  if [[ -n "$feature" ]]; then
    echo "To stop specific feature:" >&2
    echo "  cd $project_dir && agent-duo stop --feature $feature" >&2
  else
    echo "Active solo sessions:" >&2
    while IFS=: read -r feat _ peer_sync_path; do
      local mode=""
      mode=$(adapter_read_state_file "$peer_sync_path/mode")
      [[ "$mode" == "solo" ]] && echo "  - $feat" >&2
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

adapter_agent_solo_watch_phase() {
  local project_dir="${1:-.}"
  local feature_filter="${2:-}"

  local session_count
  session_count=$(adapter_session_count "$project_dir" "solo")

  if [[ $session_count -eq 0 ]]; then
    echo "No agent-solo sessions found in $project_dir" >&2
    return 1
  fi

  echo "Watching agent-solo phase changes in $project_dir ($session_count sessions)..."
  echo "Press Ctrl+C to stop."
  echo ""

  declare -A prev_phases prev_rounds prev_coder_statuses prev_reviewer_statuses

  while true; do
    local any_active=0

    while IFS=: read -r feature _ peer_sync_path; do
      if [[ -n "$feature_filter" && "$feature" != "$feature_filter" ]]; then
        continue
      fi

      # Check if this is a solo session
      local mode=""
      mode=$(adapter_read_state_file "$peer_sync_path/mode")
      [[ "$mode" == "solo" ]] || continue

      if [[ ! -d "$peer_sync_path" ]]; then
        if [[ -n "${prev_phases[$feature]:-}" ]]; then
          echo "[$feature] Session ended"
          unset "prev_phases[$feature]" "prev_rounds[$feature]"
          unset "prev_coder_statuses[$feature]" "prev_reviewer_statuses[$feature]"
        fi
        continue
      fi

      any_active=1
      local phase="" round="" coder_status="" reviewer_status=""

      phase=$(adapter_read_state_file "$peer_sync_path/phase")
      round=$(adapter_read_state_file "$peer_sync_path/round")

      if [[ -f "$peer_sync_path/coder.status" ]]; then
        # shellcheck disable=SC2034 # coder_ts, coder_msg set via eval
        local coder_st="" coder_ts="" coder_msg=""
        eval "$(adapter_read_agent_status "$peer_sync_path/coder.status" "coder")"
        coder_status="$coder_st"
      fi
      if [[ -f "$peer_sync_path/reviewer.status" ]]; then
        # shellcheck disable=SC2034 # reviewer_ts, reviewer_msg set via eval
        local reviewer_st="" reviewer_ts="" reviewer_msg=""
        eval "$(adapter_read_agent_status "$peer_sync_path/reviewer.status" "reviewer")"
        reviewer_status="$reviewer_st"
      fi

      if [[ "$phase" != "${prev_phases[$feature]:-}" || "$round" != "${prev_rounds[$feature]:-}" || \
            "$coder_status" != "${prev_coder_statuses[$feature]:-}" || "$reviewer_status" != "${prev_reviewer_statuses[$feature]:-}" ]]; then
        local timestamp
        timestamp=$(date "+%Y-%m-%d %H:%M:%S")
        echo "[$timestamp] [$feature] Phase: $phase, Round: $round | Coder: ${coder_status:-N/A}, Reviewer: ${reviewer_status:-N/A}"
        prev_phases[$feature]="$phase"
        prev_rounds[$feature]="$round"
        prev_coder_statuses[$feature]="$coder_status"
        prev_reviewer_statuses[$feature]="$reviewer_status"
      fi
    done < <(adapter_list_sessions "$project_dir")

    if [[ $any_active -eq 0 ]]; then
      echo "All sessions ended"
      break
    fi

    sleep 5
  done
}

adapter_agent_solo_get_status() {
  local project_dir="${1:-.}"
  local feature_filter="${2:-}"

  local session_count
  session_count=$(adapter_session_count "$project_dir" "solo")

  if [[ $session_count -eq 0 ]]; then
    echo "inactive"
    return 1
  fi

  # If specific feature requested, return just that status
  if [[ -n "$feature_filter" ]]; then
    while IFS=: read -r feature _ peer_sync_path; do
      if [[ "$feature" == "$feature_filter" ]]; then
        local mode=""
        mode=$(adapter_read_state_file "$peer_sync_path/mode")
        [[ "$mode" == "solo" ]] || continue

        adapter_get_phase_status "$peer_sync_path"
        return 0
      fi
    done < <(adapter_list_sessions "$project_dir")
    echo "inactive"
    return 1
  fi

  echo "active ($session_count solo sessions)"
}
