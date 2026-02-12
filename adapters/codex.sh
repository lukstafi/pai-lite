#!/usr/bin/env bash
set -euo pipefail

# ludics/adapters/codex.sh - OpenAI Codex integration
# Supports both tmux-based CLI sessions and API-based usage

#------------------------------------------------------------------------------
# Helper: Get state directory for Codex sessions
#------------------------------------------------------------------------------

adapter_codex_state_dir() {
  if [[ -n "${LUDICS_STATE_DIR:-}" ]]; then
    echo "$LUDICS_STATE_DIR/codex"
  else
    echo "$HOME/.config/ludics/codex"
  fi
}

#------------------------------------------------------------------------------
# Helper: Get session state file
#------------------------------------------------------------------------------

adapter_codex_session_file() {
  local session_name="${1:-default}"
  local state_dir
  state_dir="$(adapter_codex_state_dir)"
  echo "$state_dir/${session_name}.state"
}

#------------------------------------------------------------------------------
# Helper: Get session status file
#------------------------------------------------------------------------------

adapter_codex_status_file() {
  local session_name="$1"
  local state_dir
  state_dir="$(adapter_codex_state_dir)"
  echo "$state_dir/${session_name}.status"
}

#------------------------------------------------------------------------------
# Helper: Check if in git worktree
#------------------------------------------------------------------------------

adapter_codex_is_worktree() {
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

adapter_codex_get_main_repo() {
  local dir="$1"
  if adapter_codex_is_worktree "$dir"; then
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

adapter_codex_signal() {
  local session_name="$1"
  local status="$2"
  local message="${3:-}"

  local status_file
  status_file="$(adapter_codex_status_file "$session_name")"

  # Ensure state directory exists
  local state_dir
  state_dir="$(adapter_codex_state_dir)"
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
# Adapter interface for ludics
#------------------------------------------------------------------------------

adapter_codex_read_state() {
  local session_name="${1:-}"
  local state_dir state_file

  state_dir="$(adapter_codex_state_dir)"

  # Try to detect active tmux session first
  if command -v tmux >/dev/null 2>&1 && [[ -z "$session_name" ]]; then
    # Look for tmux sessions that might be Codex-related
    if tmux ls 2>/dev/null | grep -qi 'codex'; then
      session_name=$(tmux ls 2>/dev/null | grep -i 'codex' | head -n 1 | cut -d: -f1)
    fi
  fi

  # If still no session, try to find state files
  if [[ -z "$session_name" ]] && [[ -d "$state_dir" ]]; then
    local latest_state
    latest_state=$(find "$state_dir" -name "*.state" -type f -print0 2>/dev/null | \
                   xargs -0 ls -t 2>/dev/null | head -n 1)
    if [[ -n "$latest_state" ]]; then
      session_name=$(basename "$latest_state" .state)
    fi
  fi

  echo "**Mode:** codex"

  # Determine if using API mode or tmux mode
  local mode="unknown"
  local has_tmux_session=false

  if [[ -n "$session_name" ]] && command -v tmux >/dev/null 2>&1; then
    if tmux has-session -t "$session_name" 2>/dev/null; then
      has_tmux_session=true
      mode="tmux"
    fi
  fi

  # Check state file for mode
  if [[ -n "$session_name" ]]; then
    state_file="$(adapter_codex_session_file "$session_name")"
    if [[ -f "$state_file" ]] && grep -q '^mode=' "$state_file" 2>/dev/null; then
      mode=$(grep '^mode=' "$state_file" | cut -d= -f2-)
    fi
  fi

  # Display mode-specific information
  if [[ "$mode" == "tmux" ]] || [[ "$has_tmux_session" == true ]]; then
    echo ""
    echo "**Terminals:**"
    echo "- Codex: tmux session '$session_name'"

    # Try to get working directory from tmux
    if tmux display-message -t "$session_name" -p '#{pane_current_path}' 2>/dev/null | grep -q .; then
      local working_dir
      working_dir=$(tmux display-message -t "$session_name" -p '#{pane_current_path}')
      if [[ -n "$working_dir" ]]; then
        echo ""
        echo "**Git:**"

        # Check if it's a git worktree
        if adapter_codex_is_worktree "$working_dir"; then
          local main_repo
          main_repo=$(adapter_codex_get_main_repo "$working_dir")
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
  elif [[ "$mode" == "api" ]]; then
    echo ""
    echo "**Mode:** API-based (no tmux session)"
  fi

  # Read additional state from state file if available
  if [[ -n "$session_name" ]] && [[ -f "$state_file" ]]; then
    echo ""
    echo "**Runtime:**"

    # Parse state file (simple key=value format)
    if grep -q '^model=' "$state_file" 2>/dev/null; then
      local model
      model=$(grep '^model=' "$state_file" | cut -d= -f2-)
      echo "- Model: $model"
    fi

    if grep -q '^mode=' "$state_file" 2>/dev/null; then
      local mode_display
      mode_display=$(grep '^mode=' "$state_file" | cut -d= -f2-)
      echo "- Mode: $mode_display"
    fi

    if grep -q '^started=' "$state_file" 2>/dev/null; then
      local started
      started=$(grep '^started=' "$state_file" | cut -d= -f2-)
      echo "- Started: $started"
    fi

    if grep -q '^task=' "$state_file" 2>/dev/null; then
      local task
      task=$(grep '^task=' "$state_file" | cut -d= -f2-)
      echo "- Task: $task"
    fi

    if grep -q '^context=' "$state_file" 2>/dev/null; then
      local context
      context=$(grep '^context=' "$state_file" | cut -d= -f2-)
      echo "- Context: $context"
    fi
  fi

  # Read status if available
  if [[ -n "$session_name" ]]; then
    local status_file
    status_file="$(adapter_codex_status_file "$session_name")"

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
  fi

  # Check for ttyd server
  if [[ -n "$session_name" ]] && [[ -f "$state_file" ]]; then
    if grep -q '^ttyd_pid=' "$state_file" 2>/dev/null; then
      local ttyd_pid ttyd_port
      ttyd_pid=$(grep '^ttyd_pid=' "$state_file" | cut -d= -f2-)
      ttyd_port=$(grep '^ttyd_port=' "$state_file" 2>/dev/null | cut -d= -f2-)

      # Check if ttyd is still running
      if kill -0 "$ttyd_pid" 2>/dev/null; then
        echo ""
        echo "**Web Terminal:**"
        echo "- ttyd running on port $ttyd_port (PID: $ttyd_pid)"
        echo "- URL: $(ludics_get_url "$ttyd_port")"
      fi
    fi
  fi

  # Check for API-based usage via environment
  if [[ -n "${OPENAI_API_KEY:-}" ]]; then
    echo ""
    echo "**API:**"
    echo "- OpenAI API: configured"
  fi

  # Check for agent-duo integration
  if [[ -n "${working_dir:-}" ]] && [[ -d "$working_dir/.peer-sync" ]]; then
    echo ""
    echo "**Integration:**"
    echo "- Part of agent-duo session"
    if [[ -f "$working_dir/.peer-sync/feature" ]]; then
      local feature
      feature=$(cat "$working_dir/.peer-sync/feature")
      echo "- Feature: $feature"
    fi
    if [[ -f "$working_dir/.peer-sync/mode" ]]; then
      local duo_mode
      duo_mode=$(cat "$working_dir/.peer-sync/mode")
      echo "- Mode: $duo_mode"
    fi
  fi

  # If no active session found
  if [[ -z "$session_name" ]] && [[ ! -d "$state_dir" || -z "$(find "$state_dir" -name "*.state" -type f 2>/dev/null)" ]]; then
    return 1
  fi

  return 0
}

adapter_codex_start() {
  local session_name="${1:-codex-$(date +%s)}"
  local project_dir="${2:-.}"
  local task_id="${3:-}"

  local state_dir state_file
  state_dir="$(adapter_codex_state_dir)"
  state_file="$(adapter_codex_session_file "$session_name")"

  # Ensure state directory exists
  mkdir -p "$state_dir"

  # Check if tmux is available for session management
  if command -v tmux >/dev/null 2>&1; then
    # Check if session already exists
    if tmux has-session -t "$session_name" 2>/dev/null; then
      echo "Codex session '$session_name' already exists. Attach with: tmux attach -t $session_name" >&2
      return 1
    fi

    # Create state file
    cat > "$state_file" <<EOF
session=$session_name
started=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
project_dir=$project_dir
model=codex
mode=tmux
EOF

    if [[ -n "$task_id" ]]; then
      echo "task=$task_id" >> "$state_file"
    fi

    # Create tmux session
    echo "Creating Codex tmux session '$session_name' in $project_dir" >&2
    tmux new-session -d -s "$session_name" -c "$project_dir"

    # Set initial status
    adapter_codex_signal "$session_name" "working" "session started"

    # Could potentially start a Codex CLI here if one exists
    # tmux send-keys -t "$session_name" "codex"
    # tmux send-keys -t "$session_name" C-m

    echo "Codex session started. Attach with: tmux attach -t $session_name"
    return 0
  else
    echo "codex start: tmux not available. For API-based usage, ensure OPENAI_API_KEY is set." >&2

    # Create minimal state file for API usage
    cat > "$state_file" <<EOF
session=$session_name
started=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
project_dir=$project_dir
model=codex
mode=api
EOF

    if [[ -n "$task_id" ]]; then
      echo "task=$task_id" >> "$state_file"
    fi

    echo "Created state file for Codex API usage at: $state_file"
    return 0
  fi
}

adapter_codex_stop() {
  local session_name="${1:-}"

  # If no session specified, try to find one
  if [[ -z "$session_name" ]]; then
    if command -v tmux >/dev/null 2>&1; then
      session_name=$(tmux ls 2>/dev/null | grep -i 'codex' | head -n 1 | cut -d: -f1)
    fi
  fi

  if [[ -z "$session_name" ]]; then
    echo "codex stop: no session name provided and no active Codex session found." >&2
    return 1
  fi

  # Stop ttyd if running
  adapter_codex_stop_ttyd "$session_name"

  # Update status before stopping
  adapter_codex_signal "$session_name" "done" "session stopped"

  # Stop tmux session if it exists
  if command -v tmux >/dev/null 2>&1 && tmux has-session -t "$session_name" 2>/dev/null; then
    echo "Stopping Codex tmux session '$session_name'..." >&2
    tmux kill-session -t "$session_name"
  fi

  # Clean up state file
  local state_file
  state_file="$(adapter_codex_session_file "$session_name")"
  if [[ -f "$state_file" ]]; then
    echo "Removing state file: $state_file" >&2
    rm -f "$state_file"
  fi

  # Clean up status file
  local status_file
  status_file="$(adapter_codex_status_file "$session_name")"
  if [[ -f "$status_file" ]]; then
    rm -f "$status_file"
  fi

  echo "Codex session '$session_name' stopped."
  return 0
}

#------------------------------------------------------------------------------
# ttyd server support
#------------------------------------------------------------------------------

adapter_codex_start_ttyd() {
  local session_name="${1:-}"
  local port="${2:-7681}"

  if [[ -z "$session_name" ]]; then
    echo "codex start-ttyd: session name required" >&2
    return 1
  fi

  if ! command -v ttyd >/dev/null 2>&1; then
    echo "codex start-ttyd: ttyd is not installed" >&2
    echo "  Install: brew install ttyd" >&2
    return 1
  fi

  if ! command -v tmux >/dev/null 2>&1; then
    echo "codex start-ttyd: tmux is required" >&2
    return 1
  fi

  if ! tmux has-session -t "$session_name" 2>/dev/null; then
    echo "codex start-ttyd: session '$session_name' does not exist" >&2
    return 1
  fi

  local state_file
  state_file="$(adapter_codex_session_file "$session_name")"

  if [[ ! -f "$state_file" ]]; then
    echo "codex start-ttyd: no state file found for session '$session_name'" >&2
    return 1
  fi

  # Check if ttyd is already running for this session
  if grep -q '^ttyd_pid=' "$state_file" 2>/dev/null; then
    local existing_pid
    existing_pid=$(grep '^ttyd_pid=' "$state_file" | cut -d= -f2-)
    if kill -0 "$existing_pid" 2>/dev/null; then
      echo "ttyd is already running for session '$session_name' (PID: $existing_pid)" >&2
      return 1
    fi
  fi

  # Find available port if the requested one is in use
  while ! nc -z localhost "$port" 2>/dev/null; do
    # Port is available
    break
  done 2>/dev/null || {
    # nc failed, port might be available
    :
  }

  # Check if port is actually in use
  if lsof -i ":$port" >/dev/null 2>&1; then
    echo "Port $port is in use, trying next port..." >&2
    port=$((port + 1))
  fi

  echo "Starting ttyd server for session '$session_name' on port $port..." >&2

  # Start ttyd in background
  ttyd -p "$port" tmux attach -t "$session_name" >/dev/null 2>&1 &
  local ttyd_pid=$!

  # Wait a moment for ttyd to start
  sleep 1

  # Verify ttyd started successfully
  if ! kill -0 "$ttyd_pid" 2>/dev/null; then
    echo "Failed to start ttyd server" >&2
    return 1
  fi

  # Save ttyd info to state file
  if grep -q '^ttyd_pid=' "$state_file"; then
    # Update existing (macOS compatible)
    if [[ "$(uname)" == "Darwin" ]]; then
      sed -i '' "s|^ttyd_pid=.*|ttyd_pid=${ttyd_pid}|" "$state_file"
      sed -i '' "s|^ttyd_port=.*|ttyd_port=${port}|" "$state_file"
    else
      sed -i "s|^ttyd_pid=.*|ttyd_pid=${ttyd_pid}|" "$state_file"
      sed -i "s|^ttyd_port=.*|ttyd_port=${port}|" "$state_file"
    fi
  else
    # Append new
    echo "ttyd_pid=$ttyd_pid" >> "$state_file"
    echo "ttyd_port=$port" >> "$state_file"
  fi

  echo "ttyd server started (PID: $ttyd_pid)"
  echo "Access web terminal at: $(ludics_get_url "$port")"
  return 0
}

adapter_codex_stop_ttyd() {
  local session_name="${1:-}"

  if [[ -z "$session_name" ]]; then
    echo "codex stop-ttyd: session name required" >&2
    return 1
  fi

  local state_file
  state_file="$(adapter_codex_session_file "$session_name")"

  if [[ ! -f "$state_file" ]]; then
    # No state file, nothing to stop
    return 0
  fi

  if grep -q '^ttyd_pid=' "$state_file" 2>/dev/null; then
    local ttyd_pid
    ttyd_pid=$(grep '^ttyd_pid=' "$state_file" | cut -d= -f2-)

    if kill -0 "$ttyd_pid" 2>/dev/null; then
      echo "Stopping ttyd server (PID: $ttyd_pid)..." >&2
      kill "$ttyd_pid" 2>/dev/null || true
      sleep 1

      # Force kill if still running
      if kill -0 "$ttyd_pid" 2>/dev/null; then
        kill -9 "$ttyd_pid" 2>/dev/null || true
      fi
    fi

    # Remove ttyd info from state file (macOS compatible)
    if [[ "$(uname)" == "Darwin" ]]; then
      sed -i '' '/^ttyd_pid=/d' "$state_file"
      sed -i '' '/^ttyd_port=/d' "$state_file"
    else
      sed -i '/^ttyd_pid=/d' "$state_file"
      sed -i '/^ttyd_port=/d' "$state_file"
    fi
  fi

  return 0
}

#------------------------------------------------------------------------------
# Health check function
#------------------------------------------------------------------------------

adapter_codex_doctor() {
  local all_ok=true

  echo "=== Codex Adapter Health Check ==="
  echo ""

  # Check tmux
  if command -v tmux >/dev/null 2>&1; then
    echo "✓ tmux: $(tmux -V)"
  else
    echo "✗ tmux: NOT FOUND (required for interactive mode)"
    all_ok=false
  fi

  # Check codex CLI
  if command -v codex >/dev/null 2>&1; then
    echo "✓ codex: found at $(command -v codex)"
  else
    echo "✗ codex: NOT FOUND"
    echo "  Install: npm install -g @openai/codex"
    all_ok=false
  fi

  # Check ttyd (optional)
  if command -v ttyd >/dev/null 2>&1; then
    echo "✓ ttyd: $(ttyd --version 2>&1 | head -1)"
  else
    echo "⚠ ttyd: NOT FOUND (optional - for web terminal access)"
    echo "  Install: brew install ttyd"
  fi

  # Check API key
  if [[ -n "${OPENAI_API_KEY:-}" ]]; then
    echo "✓ OPENAI_API_KEY: configured"
  else
    echo "⚠ OPENAI_API_KEY: not set (required for API mode)"
  fi

  echo ""

  # Count active sessions
  if command -v tmux >/dev/null 2>&1; then
    local session_count
    session_count=$(tmux ls 2>/dev/null | grep -ci 'codex')
    echo "Active Codex sessions: $session_count"

    if [[ $session_count -gt 0 ]]; then
      echo ""
      echo "Sessions:"
      tmux ls 2>/dev/null | grep -i 'codex' | while IFS=: read -r session_name _rest; do
        echo "  - $session_name"
      done
    fi
  fi

  echo ""

  # Check state directory
  local state_dir
  state_dir="$(adapter_codex_state_dir)"

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

adapter_codex_restart() {
  local session_name="${1:-}"

  if [[ -z "$session_name" ]]; then
    echo "codex restart: session name required" >&2
    return 1
  fi

  local state_file
  state_file="$(adapter_codex_session_file "$session_name")"

  if [[ ! -f "$state_file" ]]; then
    echo "codex restart: no state file found for session '$session_name'" >&2
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

  echo "Restarting Codex session '$session_name' in $project_dir..." >&2

  # Create tmux session
  tmux new-session -d -s "$session_name" -c "$project_dir"

  # Update status
  adapter_codex_signal "$session_name" "working" "session restarted after crash"

  # Optionally start Codex CLI if available
  if command -v codex >/dev/null 2>&1; then
    tmux send-keys -t "$session_name" "codex"
    tmux send-keys -t "$session_name" C-m
  fi

  # Restart ttyd if it was running before
  if grep -q '^ttyd_port=' "$state_file" 2>/dev/null; then
    local ttyd_port
    ttyd_port=$(grep '^ttyd_port=' "$state_file" | cut -d= -f2-)
    echo "Restarting ttyd server..." >&2
    # Remove old ttyd info first
    if [[ "$(uname)" == "Darwin" ]]; then
      sed -i '' '/^ttyd_pid=/d' "$state_file"
      sed -i '' '/^ttyd_port=/d' "$state_file"
    else
      sed -i '/^ttyd_pid=/d' "$state_file"
      sed -i '/^ttyd_port=/d' "$state_file"
    fi
    adapter_codex_start_ttyd "$session_name" "$ttyd_port"
  fi

  echo "Session restarted. Attach with: tmux attach -t $session_name"
  return 0
}

#------------------------------------------------------------------------------
# Additional helpers for Codex-specific operations
#------------------------------------------------------------------------------

adapter_codex_update_state() {
  local session_name="$1"
  local key="$2"
  local value="$3"

  local state_file
  state_file="$(adapter_codex_session_file "$session_name")"

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

adapter_codex_list_sessions() {
  local state_dir
  state_dir="$(adapter_codex_state_dir)"

  if [[ ! -d "$state_dir" ]]; then
    echo "No Codex sessions found."
    return 0
  fi

  echo "Active Codex sessions:"
  echo ""

  find "$state_dir" -name "*.state" -type f 2>/dev/null | while read -r state_file; do
    local session_name
    session_name=$(basename "$state_file" .state)

    echo "Session: $session_name"
    if grep -q '^started=' "$state_file" 2>/dev/null; then
      echo "  Started: $(grep '^started=' "$state_file" | cut -d= -f2-)"
    fi
    if grep -q '^task=' "$state_file" 2>/dev/null; then
      echo "  Task: $(grep '^task=' "$state_file" | cut -d= -f2-)"
    fi
    if grep -q '^mode=' "$state_file" 2>/dev/null; then
      echo "  Mode: $(grep '^mode=' "$state_file" | cut -d= -f2-)"
    fi

    # Show status if available
    local status_file
    status_file="$(adapter_codex_status_file "$session_name")"
    if [[ -f "$status_file" ]]; then
      local status_text
      status_text=$(cut -d'|' -f1 < "$status_file")
      echo "  Status: $status_text"
    fi

    # Show ttyd info if running
    if grep -q '^ttyd_pid=' "$state_file" 2>/dev/null; then
      local ttyd_pid ttyd_port
      ttyd_pid=$(grep '^ttyd_pid=' "$state_file" | cut -d= -f2-)
      ttyd_port=$(grep '^ttyd_port=' "$state_file" 2>/dev/null | cut -d= -f2-)
      if kill -0 "$ttyd_pid" 2>/dev/null; then
        echo "  Web terminal: $(ludics_get_url "$ttyd_port")"
      fi
    fi

    echo ""
  done
}
