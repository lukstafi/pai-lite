#!/usr/bin/env bash
# pai-lite/adapters/helpers.sh - Shared functions for agent-duo and agent-solo adapters
#
# This file provides common functionality for adapters that use the .peer-sync/
# state format and .agent-sessions/ parallel task registry.

set -euo pipefail

#------------------------------------------------------------------------------
# Parallel task discovery via .agent-sessions/ registry
#------------------------------------------------------------------------------

# List all active sessions for a project (parallel task mode)
# Returns: feature:root_worktree:peer_sync_path per line
adapter_list_sessions() {
  local project_dir="${1:-.}"
  local sessions_dir="$project_dir/.agent-sessions"

  # Check for parallel task mode (new multi-session)
  if [[ -d "$sessions_dir" ]]; then
    for session_link in "$sessions_dir"/*.session; do
      [[ -L "$session_link" ]] || continue

      local filename feature peer_sync_path root_worktree
      filename="$(basename "$session_link")"
      feature="${filename%.session}"
      peer_sync_path="$(readlink "$session_link" 2>/dev/null)" || continue

      # Validate the symlink target exists
      [[ -d "$peer_sync_path" ]] || continue

      root_worktree="$(dirname "$peer_sync_path")"
      echo "$feature:$root_worktree:$peer_sync_path"
    done
    return 0
  fi

  # Fallback to legacy single-session mode
  local sync_dir="$project_dir/.peer-sync"
  if [[ -d "$sync_dir" ]]; then
    local feature=""
    [[ -f "$sync_dir/feature" ]] && feature=$(cat "$sync_dir/feature" 2>/dev/null | tr -d '\n')
    [[ -z "$feature" ]] && feature="default"
    echo "$feature:$project_dir:$sync_dir"
  fi
}

# Check if project uses parallel task mode
adapter_is_parallel_mode() {
  local project_dir="${1:-.}"
  [[ -d "$project_dir/.agent-sessions" ]]
}

# Get session count for a project
# Args: project_dir [mode_filter]
# mode_filter: optional, e.g., "solo" to count only solo sessions
adapter_session_count() {
  local project_dir="${1:-.}"
  local mode_filter="${2:-}"
  local count=0

  while IFS=: read -r _ _ peer_sync_path; do
    if [[ -n "$mode_filter" ]]; then
      local mode=""
      [[ -f "$peer_sync_path/mode" ]] && mode=$(cat "$peer_sync_path/mode" 2>/dev/null | tr -d '\n')
      [[ "$mode" == "$mode_filter" ]] || continue
    fi
    ((count++)) || true  # Avoid exit on arithmetic returning 0
  done < <(adapter_list_sessions "$project_dir")
  echo "$count"
}

#------------------------------------------------------------------------------
# State file reading helpers
#------------------------------------------------------------------------------

# Read a single-line state file, stripping newlines
# Returns empty string if file doesn't exist
adapter_read_state_file() {
  local file="$1"
  [[ -f "$file" ]] && cat "$file" 2>/dev/null | tr -d '\n'
}

# Read basic state from .peer-sync directory
# Sets variables: phase, round, session, feature, mode
# Usage: eval "$(adapter_read_basic_state "$sync_dir")"
adapter_read_basic_state() {
  local sync_dir="$1"

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

  # Output as shell variable assignments
  printf 'phase=%q round=%q session=%q feature=%q mode=%q' \
    "$phase" "$round" "$session" "$feature" "$mode"
}

# Read agent status from pipe-delimited status file
# Format: status|timestamp|message
# Usage: eval "$(adapter_read_agent_status "$sync_dir/claude.status" "claude")"
# Sets: ${prefix}_status, ${prefix}_timestamp, ${prefix}_message
adapter_read_agent_status() {
  local status_file="$1"
  local prefix="$2"

  local status="" timestamp="" message=""

  if [[ -f "$status_file" ]]; then
    local status_line
    status_line=$(cat "$status_file" 2>/dev/null)
    IFS='|' read -r status timestamp message <<< "$status_line"
  fi

  printf '%s_status=%q %s_timestamp=%q %s_message=%q' \
    "$prefix" "$status" "$prefix" "$timestamp" "$prefix" "$message"
}

# Format agent status for display
# Args: status message
# Returns: "status - message" or just "status"
adapter_format_agent_status() {
  local status="$1"
  local message="${2:-}"

  if [[ -n "$status" ]]; then
    if [[ -n "$message" ]]; then
      echo "$status - $message"
    else
      echo "$status"
    fi
  fi
}

#------------------------------------------------------------------------------
# Ports file parsing
#------------------------------------------------------------------------------

# Parse ports file and output terminal URLs
# Args: sync_dir port_keys...
# port_keys are pairs of: KEY_NAME Label
# Example: adapter_output_terminals "$sync_dir" ORCHESTRATOR_PORT Orchestrator CLAUDE_PORT Claude
adapter_output_terminals() {
  local sync_dir="$1"
  shift

  local ports_file="$sync_dir/ports"
  if [[ -f "$ports_file" ]]; then
    # Build associative array of key->label mappings
    declare -A labels
    while [[ $# -ge 2 ]]; do
      labels["$1"]="$2"
      shift 2
    done

    while IFS='=' read -r key value; do
      if [[ -n "${labels[$key]:-}" ]]; then
        echo "- ${labels[$key]}: http://localhost:$value"
      fi
    done < "$ports_file"
  fi
}

# Get all terminal URLs for parallel mode
# Args: project_dir port_keys... [mode_filter]
# Returns: "feature label|url" per line
adapter_all_terminals() {
  local project_dir="$1"
  shift

  # Collect port key mappings
  declare -A labels
  local mode_filter=""
  while [[ $# -ge 2 ]]; do
    labels["$1"]="$2"
    shift 2
  done
  [[ $# -eq 1 ]] && mode_filter="$1"

  if adapter_is_parallel_mode "$project_dir"; then
    while IFS=: read -r feature _ peer_sync_path; do
      if [[ -n "$mode_filter" ]]; then
        local mode=""
        [[ -f "$peer_sync_path/mode" ]] && mode=$(cat "$peer_sync_path/mode" 2>/dev/null | tr -d '\n')
        [[ "$mode" == "$mode_filter" ]] || continue
      fi

      local ports_file="$peer_sync_path/ports"
      if [[ -f "$ports_file" ]]; then
        while IFS='=' read -r key value; do
          if [[ -n "${labels[$key]:-}" ]]; then
            echo "$feature ${labels[$key]}|http://localhost:$value"
          fi
        done < "$ports_file"
      fi
    done < <(adapter_list_sessions "$project_dir")
  else
    # Legacy mode
    local ports_file="$project_dir/.peer-sync/ports"
    if [[ -f "$ports_file" ]]; then
      while IFS='=' read -r key value; do
        if [[ -n "${labels[$key]:-}" ]]; then
          echo "${labels[$key]}|http://localhost:$value"
        fi
      done < "$ports_file"
    fi
  fi
}

#------------------------------------------------------------------------------
# Slot summary helpers
#------------------------------------------------------------------------------

# Get summary info for slot display when multiple tasks are chunked
# Args: project_dir [mode_filter]
adapter_slot_summary() {
  local project_dir="${1:-.}"
  local mode_filter="${2:-}"

  if adapter_is_parallel_mode "$project_dir"; then
    local session_count=0 features=""

    while IFS=: read -r feature _ peer_sync_path; do
      if [[ -n "$mode_filter" ]]; then
        local mode=""
        [[ -f "$peer_sync_path/mode" ]] && mode=$(cat "$peer_sync_path/mode" 2>/dev/null | tr -d '\n')
        [[ "$mode" == "$mode_filter" ]] || continue
      fi

      ((session_count++)) || true
      if [[ -n "$features" ]]; then
        features="$features, $feature"
      else
        features="$feature"
      fi
    done < <(adapter_list_sessions "$project_dir")

    if [[ $session_count -eq 0 ]]; then
      echo "(no sessions)"
    elif [[ $session_count -eq 1 ]]; then
      echo "$features"
    else
      echo "$features ($session_count parallel tasks)"
    fi
  else
    # Legacy mode
    local sync_dir="$project_dir/.peer-sync"
    local feature=""
    [[ -f "$sync_dir/feature" ]] && feature=$(cat "$sync_dir/feature" 2>/dev/null | tr -d '\n')
    echo "${feature:-active session}"
  fi
}

# Get aggregated phase/status for slot display
# Args: project_dir [mode_filter]
adapter_aggregated_status() {
  local project_dir="${1:-.}"
  local mode_filter="${2:-}"

  if adapter_is_parallel_mode "$project_dir"; then
    local session_count=0 work_count=0 review_count=0 other_count=0

    while IFS=: read -r _ _ peer_sync_path; do
      if [[ -n "$mode_filter" ]]; then
        local mode=""
        [[ -f "$peer_sync_path/mode" ]] && mode=$(cat "$peer_sync_path/mode" 2>/dev/null | tr -d '\n')
        [[ "$mode" == "$mode_filter" ]] || continue
      fi

      ((session_count++)) || true
      local phase=""
      [[ -f "$peer_sync_path/phase" ]] && phase=$(cat "$peer_sync_path/phase" 2>/dev/null | tr -d '\n')
      case "$phase" in
        work) ((work_count++)) || true ;;
        review|pr-comments) ((review_count++)) || true ;;
        *) ((other_count++)) || true ;;
      esac
    done < <(adapter_list_sessions "$project_dir")

    if [[ $session_count -eq 0 ]]; then
      echo "inactive"
    elif [[ $work_count -gt 0 ]]; then
      echo "working ($work_count of $session_count)"
    elif [[ $review_count -gt 0 ]]; then
      echo "reviewing ($review_count of $session_count)"
    else
      echo "active ($session_count sessions)"
    fi
  else
    # Caller should handle legacy mode with their get_status function
    echo "active"
  fi
}

#------------------------------------------------------------------------------
# Output formatting helpers
#------------------------------------------------------------------------------

# Output session/feature header info
adapter_output_session_header() {
  local session="$1"
  local feature="$2"

  [[ -n "$session" ]] && echo "**Session:** $session"
  [[ -n "$feature" ]] && echo "**Feature:** $feature"
}

# Output runtime section
adapter_output_runtime() {
  local phase="$1"
  local round="$2"

  if [[ -n "$phase" || -n "$round" ]]; then
    echo ""
    echo "**Runtime:**"
    [[ -n "$phase" ]] && echo "- Phase: $phase"
    [[ -n "$round" ]] && echo "- Round: $round"
  fi
}

# Output error log warning if present
adapter_output_error_warning() {
  local sync_dir="$1"

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

#------------------------------------------------------------------------------
# Status helpers
#------------------------------------------------------------------------------

# Get phase/round status string
# Returns: "phase (round N)" or "phase" or "active"
adapter_get_phase_status() {
  local sync_dir="$1"

  local phase="" round=""
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
