#!/usr/bin/env bash
set -euo pipefail

# pai-lite/adapters/claude-code.sh - Claude Code CLI integration
# Manages Claude Code sessions in tmux with state tracking

#------------------------------------------------------------------------------
# Helper: Get state directory for Claude Code sessions
#------------------------------------------------------------------------------

adapter_claude_code_state_dir() {
  if [[ -n "${PAI_LITE_STATE_DIR:-}" ]]; then
    echo "$PAI_LITE_STATE_DIR/claude-code"
  else
    echo "$HOME/.config/pai-lite/claude-code"
  fi
}

#------------------------------------------------------------------------------
# Helper: Get session state file
#------------------------------------------------------------------------------

adapter_claude_code_session_file() {
  local session_name="$1"
  local state_dir
  state_dir="$(adapter_claude_code_state_dir)"
  echo "$state_dir/${session_name}.state"
}

#------------------------------------------------------------------------------
# Helper: Get session status file
#------------------------------------------------------------------------------

adapter_claude_code_status_file() {
  local session_name="$1"
  local state_dir
  state_dir="$(adapter_claude_code_state_dir)"
  echo "$state_dir/${session_name}.status"
}

#------------------------------------------------------------------------------
# Helper: Check if in git worktree
#------------------------------------------------------------------------------

adapter_claude_code_is_worktree() {
  local dir="$1"
  if [[ ! -d "$dir/.git" ]]; then
    return 1
  fi

  # Check if .git is a file (worktree) or directory (main repo)
  if [[ -f "$dir/.git" ]]; then
    return 0
  else
    return 1
  fi
}

#------------------------------------------------------------------------------
# Helper: Get main repo path from worktree
#------------------------------------------------------------------------------

adapter_claude_code_get_main_repo() {
  local dir="$1"
  if adapter_claude_code_is_worktree "$dir"; then
    # Extract gitdir from .git file, then get the main repo path
    local gitdir
    gitdir=$(grep '^gitdir:' "$dir/.git" | cut -d' ' -f2-)
    # gitdir points to .git/worktrees/<name>, we need to go up to main .git
    local main_git
    main_git=$(dirname "$(dirname "$gitdir")")
    dirname "$main_git"
  else
    echo "$dir"
  fi
}

#------------------------------------------------------------------------------
# Signal: Update agent status
#------------------------------------------------------------------------------

adapter_claude_code_signal() {
  local session_name="$1"
  local status="$2"
  local message="${3:-}"

  local status_file
  status_file="$(adapter_claude_code_status_file "$session_name")"

  # Ensure state directory exists
  local state_dir
  state_dir="$(adapter_claude_code_state_dir)"
  mkdir -p "$state_dir"

  # Validate status
  case "$status" in
    working|paused|done|error|interrupted) ;;
    *)
      echo "Invalid status: $status (valid: working, paused, done, error, interrupted)" >&2
      return 1
      ;;
  esac

  # Write status in format: status|epoch|message
  local epoch
  epoch=$(date +%s)
  echo "${status}|${epoch}|${message}" > "$status_file"
}

#------------------------------------------------------------------------------
# Adapter interface for pai-lite
#------------------------------------------------------------------------------

adapter_claude_code_read_state() {
  local session_name="${1:-}"
  local state_dir
  state_dir="$(adapter_claude_code_state_dir)"

  if ! command -v tmux >/dev/null 2>&1; then
    return 1
  fi

  # Auto-detect session if not specified
  if [[ -z "$session_name" ]]; then
    # Look for claude-related sessions first
    if tmux ls 2>/dev/null | grep -qi 'claude'; then
      session_name=$(tmux ls 2>/dev/null | grep -i 'claude' | head -n 1 | cut -d: -f1)
    else
      # Fall back to first session
      session_name=$(tmux ls 2>/dev/null | head -n 1 | cut -d: -f1)
    fi
  fi

  if [[ -z "$session_name" ]]; then
    return 1
  fi

  if ! tmux has-session -t "$session_name" 2>/dev/null; then
    return 1
  fi

  echo "**Mode:** claude-code"
  echo ""
  echo "**Terminals:**"
  echo "- Claude Code: tmux session '$session_name'"

  # Try to get working directory from tmux
  if tmux display-message -t "$session_name" -p '#{pane_current_path}' 2>/dev/null | grep -q .; then
    local working_dir
    working_dir=$(tmux display-message -t "$session_name" -p '#{pane_current_path}')
    if [[ -n "$working_dir" ]]; then
      echo ""
      echo "**Git:**"

      # Check if it's a git worktree
      if adapter_claude_code_is_worktree "$working_dir"; then
        local main_repo
        main_repo=$(adapter_claude_code_get_main_repo "$working_dir")
        echo "- Working directory: $working_dir (worktree)"
        echo "- Main repository: $main_repo"
      else
        echo "- Working directory: $working_dir"
      fi

      # Check if it's a git repo
      if git -C "$working_dir" rev-parse --git-dir >/dev/null 2>&1; then
        local branch
        branch=$(git -C "$working_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
        echo "- Branch: $branch"
      fi
    fi
  fi

  # Read additional state from state file if available
  local state_file
  state_file="$(adapter_claude_code_session_file "$session_name")"

  if [[ -f "$state_file" ]]; then
    echo ""
    echo "**Runtime:**"

    if grep -q '^task=' "$state_file" 2>/dev/null; then
      local task
      task=$(grep '^task=' "$state_file" | cut -d= -f2-)
      echo "- Task: $task"
    fi

    if grep -q '^started=' "$state_file" 2>/dev/null; then
      local started
      started=$(grep '^started=' "$state_file" | cut -d= -f2-)
      echo "- Started: $started"
    fi

    if grep -q '^context=' "$state_file" 2>/dev/null; then
      local context
      context=$(grep '^context=' "$state_file" | cut -d= -f2-)
      echo "- Context: $context"
    fi

    if grep -q '^notes=' "$state_file" 2>/dev/null; then
      local notes
      notes=$(grep '^notes=' "$state_file" | cut -d= -f2-)
      echo "- Notes: $notes"
    fi
  fi

  # Read status if available
  local status_file
  status_file="$(adapter_claude_code_status_file "$session_name")"

  if [[ -f "$status_file" ]]; then
    local status_line status_text status_epoch status_msg
    status_line=$(cat "$status_file")
    status_text=$(echo "$status_line" | cut -d'|' -f1)
    status_epoch=$(echo "$status_line" | cut -d'|' -f2)
    status_msg=$(echo "$status_line" | cut -d'|' -f3-)

    if [[ -n "$status_text" ]]; then
      echo "- Status: $status_text"
      if [[ -n "$status_msg" ]]; then
        echo "  Message: $status_msg"
      fi
      if [[ -n "$status_epoch" ]]; then
        # Calculate time ago (macOS compatible)
        local now
        now=$(date +%s)
        local diff=$((now - status_epoch))
        local mins=$((diff / 60))
        if [[ $mins -lt 60 ]]; then
          echo "  Updated: ${mins}m ago"
        else
          local hours=$((mins / 60))
          echo "  Updated: ${hours}h ago"
        fi
      fi
    fi
  fi

  # Check for agent-duo integration
  if [[ -n "$working_dir" ]] && [[ -d "$working_dir/.peer-sync" ]]; then
    echo ""
    echo "**Integration:**"
    echo "- Part of agent-duo session"
    if [[ -f "$working_dir/.peer-sync/feature" ]]; then
      local feature
      feature=$(cat "$working_dir/.peer-sync/feature")
      echo "- Feature: $feature"
    fi
    if [[ -f "$working_dir/.peer-sync/mode" ]]; then
      local mode
      mode=$(cat "$working_dir/.peer-sync/mode")
      echo "- Mode: $mode"
    fi
  fi

  return 0
}

adapter_claude_code_start() {
  local session_name="${1:-claude-$(date +%s)}"
  local project_dir="${2:-.}"
  local task_id="${3:-}"

  local state_dir state_file
  state_dir="$(adapter_claude_code_state_dir)"
  state_file="$(adapter_claude_code_session_file "$session_name")"

  if ! command -v tmux >/dev/null 2>&1; then
    echo "claude-code start: tmux is required but not installed." >&2
    return 1
  fi

  # Check if session already exists
  if tmux has-session -t "$session_name" 2>/dev/null; then
    echo "Claude Code session '$session_name' already exists." >&2
    echo "Attach with: tmux attach -t $session_name" >&2
    return 1
  fi

  # Ensure state directory exists
  mkdir -p "$state_dir"

  # Create state file
  cat > "$state_file" <<EOF
session=$session_name
started=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
project_dir=$project_dir
mode=interactive
EOF

  if [[ -n "$task_id" ]]; then
    echo "task=$task_id" >> "$state_file"
  fi

  # Create tmux session
  echo "Creating Claude Code tmux session '$session_name' in $project_dir" >&2
  tmux new-session -d -s "$session_name" -c "$project_dir"

  # Set initial status
  adapter_claude_code_signal "$session_name" "working" "session started"

  # Optionally start Claude Code CLI if available
  if command -v claude >/dev/null 2>&1; then
    tmux send-keys -t "$session_name" "claude"
    tmux send-keys -t "$session_name" C-m
  fi

  echo "Claude Code session started. Attach with: tmux attach -t $session_name"
  return 0
}

adapter_claude_code_stop() {
  local session_name="${1:-}"

  if ! command -v tmux >/dev/null 2>&1; then
    echo "claude-code stop: tmux is not available." >&2
    return 1
  fi

  # Auto-detect session if not specified
  if [[ -z "$session_name" ]]; then
    if tmux ls 2>/dev/null | grep -qi 'claude'; then
      session_name=$(tmux ls 2>/dev/null | grep -i 'claude' | head -n 1 | cut -d: -f1)
    fi
  fi

  if [[ -z "$session_name" ]]; then
    echo "claude-code stop: no session name provided and no Claude session found." >&2
    return 1
  fi

  if ! tmux has-session -t "$session_name" 2>/dev/null; then
    echo "claude-code stop: session '$session_name' does not exist." >&2
    return 1
  fi

  # Update status before stopping
  adapter_claude_code_signal "$session_name" "done" "session stopped"

  echo "Stopping Claude Code tmux session '$session_name'..." >&2
  tmux kill-session -t "$session_name"

  # Clean up state file
  local state_file
  state_file="$(adapter_claude_code_session_file "$session_name")"
  if [[ -f "$state_file" ]]; then
    echo "Removing state file: $state_file" >&2
    rm -f "$state_file"
  fi

  # Clean up status file
  local status_file
  status_file="$(adapter_claude_code_status_file "$session_name")"
  if [[ -f "$status_file" ]]; then
    rm -f "$status_file"
  fi

  echo "Claude Code session '$session_name' stopped."
  return 0
}

#------------------------------------------------------------------------------
# Health check function
#------------------------------------------------------------------------------

adapter_claude_code_doctor() {
  local all_ok=true

  echo "=== Claude Code Adapter Health Check ==="
  echo ""

  # Check tmux
  if command -v tmux >/dev/null 2>&1; then
    echo "✓ tmux: $(tmux -V)"
  else
    echo "✗ tmux: NOT FOUND (required)"
    all_ok=false
  fi

  # Check claude CLI
  if command -v claude >/dev/null 2>&1; then
    echo "✓ claude: found at $(command -v claude)"
  else
    echo "✗ claude: NOT FOUND"
    echo "  Install: npm install -g @anthropic-ai/claude-code"
    all_ok=false
  fi

  echo ""

  # Count active sessions
  if command -v tmux >/dev/null 2>&1; then
    local session_count
    session_count=$(tmux ls 2>/dev/null | grep -i 'claude' | wc -l | tr -d ' ')
    echo "Active Claude sessions: $session_count"

    if [[ $session_count -gt 0 ]]; then
      echo ""
      echo "Sessions:"
      tmux ls 2>/dev/null | grep -i 'claude' | while IFS=: read -r session_name _rest; do
        echo "  - $session_name"
      done
    fi
  fi

  echo ""

  # Check state directory
  local state_dir
  state_dir="$(adapter_claude_code_state_dir)"

  if [[ -d "$state_dir" ]]; then
    echo "State directory: $state_dir"
    local state_count
    state_count=$(find "$state_dir" -name "*.state" -type f 2>/dev/null | wc -l | tr -d ' ')
    echo "State files: $state_count"
  else
    echo "State directory: $state_dir (not created yet)"
  fi

  echo ""

  if $all_ok; then
    echo "✓ All checks passed"
    return 0
  else
    echo "✗ Some checks failed"
    return 1
  fi
}

#------------------------------------------------------------------------------
# Session restart function
#------------------------------------------------------------------------------

adapter_claude_code_restart() {
  local session_name="${1:-}"

  if [[ -z "$session_name" ]]; then
    echo "claude-code restart: session name required" >&2
    return 1
  fi

  local state_file
  state_file="$(adapter_claude_code_session_file "$session_name")"

  if [[ ! -f "$state_file" ]]; then
    echo "claude-code restart: no state file found for session '$session_name'" >&2
    return 1
  fi

  # Check if session is already running
  if tmux has-session -t "$session_name" 2>/dev/null; then
    echo "Session '$session_name' is already running." >&2
    echo "Attach with: tmux attach -t $session_name" >&2
    return 0
  fi

  # Extract project directory from state file
  local project_dir
  if grep -q '^project_dir=' "$state_file" 2>/dev/null; then
    project_dir=$(grep '^project_dir=' "$state_file" | cut -d= -f2-)
  else
    project_dir="."
  fi

  echo "Restarting Claude Code session '$session_name' in $project_dir..." >&2

  # Create tmux session
  tmux new-session -d -s "$session_name" -c "$project_dir"

  # Update status
  adapter_claude_code_signal "$session_name" "working" "session restarted after crash"

  # Optionally start Claude Code CLI if available
  if command -v claude >/dev/null 2>&1; then
    tmux send-keys -t "$session_name" "claude"
    tmux send-keys -t "$session_name" C-m
  fi

  echo "Session restarted. Attach with: tmux attach -t $session_name"
  return 0
}

#------------------------------------------------------------------------------
# Additional helpers for Claude Code operations
#------------------------------------------------------------------------------

adapter_claude_code_update_state() {
  local session_name="$1"
  local key="$2"
  local value="$3"

  local state_file
  state_file="$(adapter_claude_code_session_file "$session_name")"

  if [[ ! -f "$state_file" ]]; then
    echo "No state file found for session '$session_name'" >&2
    return 1
  fi

  # Update or append key=value
  if grep -q "^${key}=" "$state_file"; then
    # Update existing key (macOS compatible)
    if [[ "$(uname)" == "Darwin" ]]; then
      sed -i '' "s|^${key}=.*|${key}=${value}|" "$state_file"
    else
      sed -i "s|^${key}=.*|${key}=${value}|" "$state_file"
    fi
  else
    # Append new key
    echo "${key}=${value}" >> "$state_file"
  fi
}

adapter_claude_code_list_sessions() {
  if ! command -v tmux >/dev/null 2>&1; then
    echo "tmux is not available."
    return 1
  fi

  echo "Active Claude Code sessions:"
  echo ""

  tmux ls 2>/dev/null | while IFS=: read -r session_name _rest; do
    if [[ "$session_name" =~ claude ]]; then
      echo "Session: $session_name"

      local state_file
      state_file="$(adapter_claude_code_session_file "$session_name")"

      if [[ -f "$state_file" ]]; then
        if grep -q '^started=' "$state_file" 2>/dev/null; then
          echo "  Started: $(grep '^started=' "$state_file" | cut -d= -f2-)"
        fi
        if grep -q '^task=' "$state_file" 2>/dev/null; then
          echo "  Task: $(grep '^task=' "$state_file" | cut -d= -f2-)"
        fi
      fi

      # Show status if available
      local status_file
      status_file="$(adapter_claude_code_status_file "$session_name")"
      if [[ -f "$status_file" ]]; then
        local status_text
        status_text=$(cut -d'|' -f1 < "$status_file")
        echo "  Status: $status_text"
      fi

      echo ""
    fi
  done
}
