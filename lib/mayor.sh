#!/usr/bin/env bash
set -euo pipefail

# pai-lite/lib/mayor.sh - Mayor session management
# The Mayor is a persistent Claude Code instance running in a dedicated tmux session

#------------------------------------------------------------------------------
# Constants
#------------------------------------------------------------------------------

MAYOR_SESSION_NAME="${PAI_LITE_MAYOR_SESSION:-pai-mayor}"
MAYOR_DEFAULT_PORT="${PAI_LITE_MAYOR_PORT:-7679}"

#------------------------------------------------------------------------------
# Helper: Get Mayor state directory
#------------------------------------------------------------------------------

mayor_state_dir() {
  local harness_dir
  harness_dir="$(pai_lite_state_harness_dir)"
  echo "$harness_dir/mayor"
}

#------------------------------------------------------------------------------
# Helper: Get Mayor state file
#------------------------------------------------------------------------------

mayor_state_file() {
  echo "$(mayor_state_dir)/session.state"
}

#------------------------------------------------------------------------------
# Helper: Get Mayor status file
#------------------------------------------------------------------------------

mayor_status_file() {
  echo "$(mayor_state_dir)/session.status"
}

#------------------------------------------------------------------------------
# Helper: Check if Mayor session is running
#------------------------------------------------------------------------------

mayor_is_running() {
  if ! command -v tmux >/dev/null 2>&1; then
    return 1
  fi
  tmux has-session -t "$MAYOR_SESSION_NAME" 2>/dev/null
}

#------------------------------------------------------------------------------
# Mayor start: Create/restart the Mayor tmux session
#------------------------------------------------------------------------------

mayor_start() {
  local state_dir working_dir state_file
  local use_ttyd=true
  local skip_federation=false

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-ttyd)
        use_ttyd=false
        shift
        ;;
      --skip-federation)
        skip_federation=true
        shift
        ;;
      *)
        shift
        ;;
    esac
  done

  if ! command -v tmux >/dev/null 2>&1; then
    pai_lite_die "mayor start: tmux is required but not installed"
  fi

  # Check federation - only leader should start Mayor
  if [[ "$skip_federation" != "true" ]]; then
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -f "$script_dir/federation.sh" ]]; then
      # shellcheck source=lib/federation.sh
      source "$script_dir/federation.sh"
      if ! federation_should_run_mayor 2>/dev/null; then
        pai_lite_warn "Mayor blocked: not the federation leader"
        echo "Current leader: $(federation_current_leader 2>/dev/null || echo 'unknown')"
        echo "Run 'pai-lite federation status' for details"
        echo ""
        echo "To override, use: pai-lite mayor start --skip-federation"
        return 0
      fi
    fi
  fi

  # Check if session already exists
  if mayor_is_running; then
    pai_lite_warn "Mayor session '$MAYOR_SESSION_NAME' is already running"
    echo "Attach with: tmux attach -t $MAYOR_SESSION_NAME"
    echo "Or view status with: pai-lite mayor status"
    return 0
  fi

  # Ensure state directory exists
  state_dir="$(mayor_state_dir)"
  mkdir -p "$state_dir"
  mkdir -p "$state_dir/memory"
  mkdir -p "$state_dir/memory/projects"

  # Get working directory (harness dir by default)
  working_dir="$(pai_lite_state_harness_dir)"

  # Create state file
  state_file="$(mayor_state_file)"
  cat > "$state_file" <<EOF
session=$MAYOR_SESSION_NAME
started=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
working_dir=$working_dir
status=starting
EOF

  # Create tmux session
  pai_lite_info "Creating Mayor tmux session '$MAYOR_SESSION_NAME' in $working_dir"
  tmux new-session -d -s "$MAYOR_SESSION_NAME" -c "$working_dir"

  # Update status
  mayor_signal "running" "session started"

  # Start Claude Code CLI if available (with -c to continue previous session, fallback to new)
  if command -v claude >/dev/null 2>&1; then
    tmux send-keys -t "$MAYOR_SESSION_NAME" "claude -c || claude" C-m
    pai_lite_info "Started Claude Code in Mayor session"
  else
    pai_lite_warn "claude CLI not found; session started without Claude Code"
  fi

  echo "Mayor session started. Attach with: tmux attach -t $MAYOR_SESSION_NAME"

  # Start ttyd by default unless --no-ttyd was passed
  if [[ "$use_ttyd" == "true" ]]; then
    if command -v ttyd >/dev/null 2>&1; then
      local ttyd_port
      ttyd_port=$(pai_lite_config_get_nested "mayor" "ttyd_port" 2>/dev/null)
      ttyd_port="${ttyd_port:-$MAYOR_DEFAULT_PORT}"
      pai_lite_info "Starting ttyd on port $ttyd_port..."
      # Start ttyd in background, connecting to the Mayor tmux session
      # -W enables writable mode (readonly by default)
      # Use disown to detach from shell so launchd/systemd doesn't kill it
      local ttyd_log="$HOME/Library/Logs/pai-lite-ttyd.log"
      [[ -d "$HOME/Library/Logs" ]] || ttyd_log="/tmp/pai-lite-ttyd.log"
      nohup ttyd -W -p "$ttyd_port" tmux attach -t "$MAYOR_SESSION_NAME" \
        >>"$ttyd_log" 2>&1 &
      disown
      echo "Web access available at: $(pai_lite_get_url "$ttyd_port")"
    else
      pai_lite_warn "ttyd not installed; skipping web access (use --no-ttyd to suppress this warning)"
    fi
  fi

  return 0
}

#------------------------------------------------------------------------------
# Mayor stop: Gracefully stop the Mayor session
#------------------------------------------------------------------------------

mayor_stop() {
  if ! command -v tmux >/dev/null 2>&1; then
    pai_lite_die "mayor stop: tmux is not available"
  fi

  if ! mayor_is_running; then
    pai_lite_warn "Mayor session '$MAYOR_SESSION_NAME' is not running"
    return 0
  fi

  # Update status before stopping
  mayor_signal "stopped" "session stopped by user"

  # Kill any ttyd processes attached to this session
  local ttyd_pids
  ttyd_pids=$(pgrep -f "ttyd.*$MAYOR_SESSION_NAME" 2>/dev/null || true)
  if [[ -n "$ttyd_pids" ]]; then
    pai_lite_info "Stopping ttyd process(es)..."
    echo "$ttyd_pids" | xargs kill 2>/dev/null || true
  fi

  pai_lite_info "Stopping Mayor tmux session '$MAYOR_SESSION_NAME'..."
  tmux kill-session -t "$MAYOR_SESSION_NAME"

  # Update state file
  local state_file
  state_file="$(mayor_state_file)"
  if [[ -f "$state_file" ]]; then
    # Append stopped timestamp
    echo "stopped=$(date -u +"%Y-%m-%dT%H:%M:%SZ")" >> "$state_file"
  fi

  echo "Mayor session stopped."
  return 0
}

#------------------------------------------------------------------------------
# Mayor status: Show Mayor session status
#------------------------------------------------------------------------------

mayor_status() {
  local state_dir state_file status_file

  state_dir="$(mayor_state_dir)"
  state_file="$(mayor_state_file)"
  status_file="$(mayor_status_file)"

  echo "=== Mayor Status ==="
  echo ""

  # Check if session is running
  if mayor_is_running; then
    echo "Session: $MAYOR_SESSION_NAME (running)"
  else
    echo "Session: $MAYOR_SESSION_NAME (not running)"
    if [[ -f "$state_file" ]] && grep -q '^stopped=' "$state_file" 2>/dev/null; then
      local stopped
      stopped=$(grep '^stopped=' "$state_file" | tail -n1 | cut -d= -f2-)
      echo "Last stopped: $stopped"
    fi
    echo ""
    echo "Start with: pai-lite mayor start"
    return 0
  fi

  echo ""

  # Show state file info
  if [[ -f "$state_file" ]]; then
    if grep -q '^started=' "$state_file" 2>/dev/null; then
      echo "Started: $(grep '^started=' "$state_file" | cut -d= -f2-)"
    fi
    if grep -q '^working_dir=' "$state_file" 2>/dev/null; then
      echo "Working directory: $(grep '^working_dir=' "$state_file" | cut -d= -f2-)"
    fi
  fi

  # Show status
  if [[ -f "$status_file" ]]; then
    local status_line status_text status_epoch status_msg
    status_line=$(cat "$status_file")
    status_text=$(echo "$status_line" | cut -d'|' -f1)
    status_epoch=$(echo "$status_line" | cut -d'|' -f2)
    status_msg=$(echo "$status_line" | cut -d'|' -f3-)

    echo ""
    echo "Status: $status_text"
    if [[ -n "$status_msg" ]]; then
      echo "Message: $status_msg"
    fi
    if [[ -n "$status_epoch" ]]; then
      local now diff mins
      now=$(date +%s)
      diff=$((now - status_epoch))
      mins=$((diff / 60))
      if [[ $mins -lt 60 ]]; then
        echo "Last activity: ${mins}m ago"
      else
        local hours=$((mins / 60))
        echo "Last activity: ${hours}h ago"
      fi
    fi
  fi

  # Show queue status
  echo ""
  local queue_file
  queue_file="$(pai_lite_queue_file)"
  if [[ -f "$queue_file" ]] && [[ -s "$queue_file" ]]; then
    local pending_count
    pending_count=$(wc -l < "$queue_file" | tr -d ' ')
    echo "Pending requests: $pending_count"
  else
    echo "Pending requests: 0"
  fi

  # Show memory status
  echo ""
  local memory_dir="$state_dir/memory"
  if [[ -d "$memory_dir" ]]; then
    echo "Memory:"
    if [[ -f "$memory_dir/corrections.md" ]]; then
      local corrections_count
      corrections_count=$(grep -c '^-' "$memory_dir/corrections.md" 2>/dev/null || echo "0")
      echo "  - Corrections: $corrections_count entries"
    fi
    if [[ -f "$memory_dir/tools.md" ]]; then
      echo "  - Tools: present"
    fi
    if [[ -f "$memory_dir/workflows.md" ]]; then
      echo "  - Workflows: present"
    fi
    local projects_count
    projects_count=$(find "$memory_dir/projects" -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$projects_count" -gt 0 ]]; then
      echo "  - Projects: $projects_count"
    fi
  fi

  # Show context file if present
  if [[ -f "$state_dir/context.md" ]]; then
    echo ""
    echo "Context file: present"
  fi

  return 0
}

#------------------------------------------------------------------------------
# Mayor attach: Attach to the Mayor tmux session
#------------------------------------------------------------------------------

mayor_attach() {
  if ! command -v tmux >/dev/null 2>&1; then
    pai_lite_die "mayor attach: tmux is not available"
  fi

  if ! mayor_is_running; then
    pai_lite_die "Mayor session '$MAYOR_SESSION_NAME' is not running. Start with: pai-lite mayor start"
  fi

  exec tmux attach -t "$MAYOR_SESSION_NAME"
}

#------------------------------------------------------------------------------
# Mayor logs: Show recent Mayor activity from tmux pane
#------------------------------------------------------------------------------

mayor_logs() {
  local lines="${1:-100}"

  if ! command -v tmux >/dev/null 2>&1; then
    pai_lite_die "mayor logs: tmux is not available"
  fi

  if ! mayor_is_running; then
    pai_lite_warn "Mayor session '$MAYOR_SESSION_NAME' is not running"

    # Show results from completed requests if available
    local results_dir
    results_dir="$(pai_lite_results_dir)"
    if [[ -d "$results_dir" ]]; then
      echo "Recent results:"
      find "$results_dir" -name "*.json" -type f -mtime -1 | \
        xargs -I {} sh -c 'echo "---"; cat "{}"' 2>/dev/null | head -n 50
    fi
    return 0
  fi

  echo "=== Mayor Session Logs (last $lines lines) ==="
  echo ""
  tmux capture-pane -t "$MAYOR_SESSION_NAME" -p -S "-$lines"
}

#------------------------------------------------------------------------------
# Mayor signal: Update Mayor status
#------------------------------------------------------------------------------

mayor_signal() {
  local status="$1"
  local message="${2:-}"

  local status_file state_dir
  state_dir="$(mayor_state_dir)"
  status_file="$(mayor_status_file)"

  # Ensure state directory exists
  mkdir -p "$state_dir"

  # Write status in format: status|epoch|message
  local epoch
  epoch=$(date +%s)
  echo "${status}|${epoch}|${message}" > "$status_file"
}

#------------------------------------------------------------------------------
# Mayor send: Send a command to the Mayor (for automation)
#------------------------------------------------------------------------------

mayor_send() {
  local command="$1"

  if ! mayor_is_running; then
    pai_lite_die "Mayor session is not running. Start with: pai-lite mayor start"
  fi

  tmux send-keys -t "$MAYOR_SESSION_NAME" "$command" C-m
  pai_lite_info "Sent command to Mayor: $command"
}

#------------------------------------------------------------------------------
# Mayor doctor: Health check for Mayor setup
#------------------------------------------------------------------------------

mayor_doctor() {
  local all_ok=true

  echo "=== Mayor Health Check ==="
  echo ""

  # Check tmux
  if command -v tmux >/dev/null 2>&1; then
    echo "tmux: $(tmux -V)"
  else
    echo "tmux: NOT FOUND (required)"
    all_ok=false
  fi

  # Check claude CLI
  if command -v claude >/dev/null 2>&1; then
    echo "claude: found at $(command -v claude)"
  else
    echo "claude: NOT FOUND"
    echo "  Install: npm install -g @anthropic-ai/claude-code"
    all_ok=false
  fi

  # Check jq (for queue processing)
  if command -v jq >/dev/null 2>&1; then
    echo "jq: found"
  else
    echo "jq: NOT FOUND (required for queue processing)"
    all_ok=false
  fi

  # Check ttyd (for web access)
  if command -v ttyd >/dev/null 2>&1; then
    echo "ttyd: found at $(command -v ttyd)"
  else
    echo "ttyd: NOT FOUND (optional, for web access)"
    echo "  Install: brew install ttyd (macOS) or apt install ttyd (Linux)"
  fi

  echo ""

  # Check session status
  if mayor_is_running; then
    echo "Mayor session: running"
  else
    echo "Mayor session: not running"
  fi

  # Check state directory
  local state_dir
  state_dir="$(mayor_state_dir)"
  if [[ -d "$state_dir" ]]; then
    echo "State directory: $state_dir"
  else
    echo "State directory: $state_dir (not created yet)"
  fi

  # Check queue file
  local queue_file
  queue_file="$(pai_lite_queue_file)"
  if [[ -f "$queue_file" ]]; then
    local pending
    pending=$(wc -l < "$queue_file" | tr -d ' ')
    echo "Queue: $queue_file ($pending pending)"
  else
    echo "Queue: not initialized"
  fi

  # Check stop hook
  echo ""
  echo "Stop hook locations to check:"
  echo "  - ~/.claude/hooks/pai-lite-on-stop.sh"
  echo "  - ~/.config/claude-code/hooks/pai-lite-on-stop.sh"

  if [[ -f "$HOME/.claude/hooks/pai-lite-on-stop.sh" ]]; then
    echo "  Found: ~/.claude/hooks/pai-lite-on-stop.sh"
  elif [[ -f "$HOME/.config/claude-code/hooks/pai-lite-on-stop.sh" ]]; then
    echo "  Found: ~/.config/claude-code/hooks/pai-lite-on-stop.sh"
  else
    echo "  Not found - install with: pai-lite init --hooks"
    all_ok=false
  fi

  echo ""

  if $all_ok; then
    echo "All checks passed"
    return 0
  else
    echo "Some checks failed"
    return 1
  fi
}

#------------------------------------------------------------------------------
# Mayor briefing: Request a briefing and wait for result
#------------------------------------------------------------------------------

mayor_briefing() {
  local wait="${1:-true}"
  local timeout="${2:-300}"

  # Queue the briefing request
  local request_id
  request_id=$(pai_lite_queue_request "briefing")
  echo "Queued briefing request: $request_id"

  if [[ "$wait" != "true" ]]; then
    echo "Mayor will process when ready"
    return 0
  fi

  # Check if Mayor is running
  if ! mayor_is_running; then
    pai_lite_warn "Mayor session is not running. Start with: pai-lite mayor start"
    pai_lite_warn "Or process manually: the request is queued"
    return 1
  fi

  echo "Waiting for Mayor to process (timeout: ${timeout}s)..."

  # Wait for result
  local result
  if result=$(pai_lite_wait_for_result "$request_id" "$timeout"); then
    echo ""
    echo "=== Briefing Result ==="
    echo "$result" | jq -r '.output // "No output"' 2>/dev/null || echo "$result"

    # Send notification
    if command -v notify_pai >/dev/null 2>&1; then
      local summary
      summary=$(echo "$result" | jq -r '.output // ""' 2>/dev/null | head -n 5)
      notify_pai "Briefing ready" 3 "pai-lite briefing"
    fi

    return 0
  else
    pai_lite_warn "Timeout waiting for briefing result"
    return 1
  fi
}
