#!/usr/bin/env bash
set -euo pipefail

# ludics/lib/mag.sh - Mag session management
# The Mag is a persistent Claude Code instance running in a dedicated tmux session

#------------------------------------------------------------------------------
# Constants
#------------------------------------------------------------------------------

MAG_SESSION_NAME="${LUDICS_MAG_SESSION:-ludics-mag}"
MAG_DEFAULT_PORT="${LUDICS_MAG_PORT:-7679}"

#------------------------------------------------------------------------------
# Helper: Send a skill command (slash command) to a tmux session
# The sleep is needed because the console would still input a newline
# instead of processing the prompt without it.
#------------------------------------------------------------------------------

trigger_skill() {
  local session="$1"
  local skill_cmd="$2"

  tmux send-keys -t "$session" -l "$skill_cmd"
  sleep 0.5
  tmux send-keys -t "$session" Enter
}

#------------------------------------------------------------------------------
# Helper: Get Mag state directory
#------------------------------------------------------------------------------

mag_state_dir() {
  local harness_dir
  harness_dir="$(ludics_state_harness_dir)"
  echo "$harness_dir/mag"
}

#------------------------------------------------------------------------------
# Helper: Get Mag state file
#------------------------------------------------------------------------------

mag_state_file() {
  echo "$(mag_state_dir)/session.state"
}

#------------------------------------------------------------------------------
# Helper: Get Mag status file
#------------------------------------------------------------------------------

mag_status_file() {
  echo "$(mag_state_dir)/session.status"
}

#------------------------------------------------------------------------------
# Helper: Check if Mag session is running
#------------------------------------------------------------------------------

mag_is_running() {
  if ! command -v tmux >/dev/null 2>&1; then
    return 1
  fi
  tmux has-session -t "$MAG_SESSION_NAME" 2>/dev/null
}

#------------------------------------------------------------------------------
# Helper: Ensure ttyd is running for Mag session
# Spawns ttyd under the tmux server's process tree so launchd can't kill it.
#------------------------------------------------------------------------------

mag_ensure_ttyd() {
  if ! command -v ttyd >/dev/null 2>&1; then
    ludics_warn "ttyd not installed; skipping web access (use --no-ttyd to suppress this warning)"
    return 0
  fi

  # Check if ttyd is already running for this session
  if pgrep -f "ttyd.*$MAG_SESSION_NAME" >/dev/null 2>&1; then
    return 0
  fi

  local ttyd_port
  ttyd_port=$(ludics_config_get_nested "mag" "ttyd_port" 2>/dev/null)
  ttyd_port="${ttyd_port:-$MAG_DEFAULT_PORT}"

  local ttyd_log="$HOME/Library/Logs/ludics-ttyd.log"
  [[ -d "$HOME/Library/Logs" ]] || ttyd_log="/tmp/ludics-ttyd.log"

  local ttyd_bin
  ttyd_bin="$(command -v ttyd)"

  ludics_info "Starting ttyd on port $ttyd_port..."

  # Spawn ttyd via tmux run-shell so it lives under the tmux server's process
  # tree, not the caller's.  This prevents launchd/systemd from killing it
  # when the one-shot job exits.
  tmux run-shell -b -t "$MAG_SESSION_NAME" \
    "$ttyd_bin -W -p $ttyd_port tmux attach -t $MAG_SESSION_NAME >>$ttyd_log 2>&1"

  echo "Web access available at: $(ludics_get_url "$ttyd_port")"
}

#------------------------------------------------------------------------------
# Mag start: Create/restart Mag tmux session
#------------------------------------------------------------------------------

mag_start() {
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
    ludics_die "mag start: tmux is required but not installed"
  fi

  # Check federation - only leader should start Mag
  if [[ "$skip_federation" != "true" ]]; then
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -f "$script_dir/federation.sh" ]]; then
      # shellcheck source=lib/federation.sh
      source "$script_dir/federation.sh"
      if ! federation_should_run_mag 2>/dev/null; then
        ludics_warn "Mag blocked: not the federation leader"
        echo "Current leader: $(federation_current_leader 2>/dev/null || echo 'unknown')"
        echo "Run 'ludics federation status' for details"
        echo ""
        echo "To override, use: ludics mag start --skip-federation"
        return 0
      fi
    fi
  fi

  # Check if session already exists
  if mag_is_running; then
    # Keepalive path: session exists, ensure ttyd is alive
    if [[ "$use_ttyd" == "true" ]]; then
      mag_ensure_ttyd
    fi
    # Queue is drained by the Stop hook when Mag finishes a turn.
    # If Mag is idle and items were queued after its last turn, nudge it
    # so the Stop hook fires and picks them up.
    local queue_file
    queue_file="$(ludics_queue_file)"
    if [[ -s "$queue_file" ]]; then
      trigger_skill "$MAG_SESSION_NAME" "Continue. (ludics automatic message, current time: $(date '+%Y-%m-%d %H:%M %Z'))"
    fi
    return 0
  fi

  # Ensure state directory exists
  state_dir="$(mag_state_dir)"
  mkdir -p "$state_dir"
  mkdir -p "$state_dir/memory"
  mkdir -p "$state_dir/memory/projects"

  # Get working directory (harness dir by default)
  working_dir="$(ludics_state_harness_dir)"

  # Create state file
  state_file="$(mag_state_file)"
  cat > "$state_file" <<EOF
session=$MAG_SESSION_NAME
started=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
working_dir=$working_dir
status=starting
EOF

  # Create tmux session
  ludics_info "Creating Mag tmux session '$MAG_SESSION_NAME' in $working_dir"
  tmux new-session -d -s "$MAG_SESSION_NAME" -c "$working_dir"

  # Update status
  mag_signal "running" "session started"

  # Start Claude Code CLI if available (with -c to continue previous session, fallback to new)
  if command -v claude >/dev/null 2>&1; then
    tmux send-keys -t "$MAG_SESSION_NAME" "claude -c --dangerously-skip-permissions || claude --dangerously-skip-permissions"
    tmux send-keys -t "$MAG_SESSION_NAME" C-m
    ludics_info "Started Claude Code in Mag session"
  else
    ludics_warn "claude CLI not found; session started without Claude Code"
  fi

  echo "Mag session started. Attach with: tmux attach -t $MAG_SESSION_NAME"

  # Start ttyd by default unless --no-ttyd was passed
  if [[ "$use_ttyd" == "true" ]]; then
    mag_ensure_ttyd
  fi

  # Drain any queued requests (e.g. briefing queued at startup before Mag was up)
  local skill_cmd
  skill_cmd="$(mag_queue_pop_skill)"
  if [[ -n "$skill_cmd" ]]; then
    # Give Claude Code a moment to initialize before sending the command
    sleep 5
    ludics_info "Mag fresh start, sending queued request: $skill_cmd"
    trigger_skill "$MAG_SESSION_NAME" "$skill_cmd"
  fi

  return 0
}

#------------------------------------------------------------------------------
# Mag stop: Gracefully stop Mag session
#------------------------------------------------------------------------------

mag_stop() {
  if ! command -v tmux >/dev/null 2>&1; then
    ludics_die "mag stop: tmux is not available"
  fi

  if ! mag_is_running; then
    ludics_warn "Mag session '$MAG_SESSION_NAME' is not running"
    return 0
  fi

  # Update status before stopping
  mag_signal "stopped" "session stopped by user"

  # Kill any ttyd processes attached to this session
  local ttyd_pids
  ttyd_pids=$(pgrep -f "ttyd.*$MAG_SESSION_NAME" 2>/dev/null || true)
  if [[ -n "$ttyd_pids" ]]; then
    ludics_info "Stopping ttyd process(es)..."
    echo "$ttyd_pids" | xargs kill 2>/dev/null || true
  fi

  ludics_info "Stopping Mag tmux session '$MAG_SESSION_NAME'..."
  tmux kill-session -t "$MAG_SESSION_NAME"

  # Update state file
  local state_file
  state_file="$(mag_state_file)"
  if [[ -f "$state_file" ]]; then
    # Append stopped timestamp
    echo "stopped=$(date -u +"%Y-%m-%dT%H:%M:%SZ")" >> "$state_file"
  fi

  echo "Mag session stopped."
  return 0
}

#------------------------------------------------------------------------------
# Mag status: Show Mag session status
#------------------------------------------------------------------------------

mag_status() {
  local state_dir state_file status_file

  state_dir="$(mag_state_dir)"
  state_file="$(mag_state_file)"
  status_file="$(mag_status_file)"

  echo "=== Mag Status ==="
  echo ""

  # Check if session is running
  if mag_is_running; then
    echo "Session: $MAG_SESSION_NAME (running)"
  else
    echo "Session: $MAG_SESSION_NAME (not running)"
    if [[ -f "$state_file" ]] && grep -q '^stopped=' "$state_file" 2>/dev/null; then
      local stopped
      stopped=$(grep '^stopped=' "$state_file" | tail -n1 | cut -d= -f2-)
      echo "Last stopped: $stopped"
    fi
    echo ""
    echo "Start with: ludics mag start"
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
  queue_file="$(ludics_queue_file)"
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
# Mag attach: Attach to Mag tmux session
#------------------------------------------------------------------------------

mag_attach() {
  if ! command -v tmux >/dev/null 2>&1; then
    ludics_die "mag attach: tmux is not available"
  fi

  if ! mag_is_running; then
    ludics_die "Mag session '$MAG_SESSION_NAME' is not running. Start with: ludics mag start"
  fi

  exec tmux attach -t "$MAG_SESSION_NAME"
}

#------------------------------------------------------------------------------
# Mag logs: Show recent Mag activity from tmux pane
#------------------------------------------------------------------------------

mag_logs() {
  local lines="${1:-100}"

  if ! command -v tmux >/dev/null 2>&1; then
    ludics_die "mag logs: tmux is not available"
  fi

  if ! mag_is_running; then
    ludics_warn "Mag session '$MAG_SESSION_NAME' is not running"

    # Show results from completed requests if available
    local results_dir
    results_dir="$(ludics_results_dir)"
    if [[ -d "$results_dir" ]]; then
      echo "Recent results:"
      find "$results_dir" -name "*.json" -type f -mtime -1 -exec sh -c 'echo "---"; cat "$1"' _ {} \; 2>/dev/null | head -n 50
    fi
    return 0
  fi

  echo "=== Mag Session Logs (last $lines lines) ==="
  echo ""
  tmux capture-pane -t "$MAG_SESSION_NAME" -p -S "-$lines"
}

#------------------------------------------------------------------------------
# Mag signal: Update Mag status
#------------------------------------------------------------------------------

mag_signal() {
  local status="$1"
  local message="${2:-}"

  local status_file state_dir
  state_dir="$(mag_state_dir)"
  status_file="$(mag_status_file)"

  # Ensure state directory exists
  mkdir -p "$state_dir"

  # Write status in format: status|epoch|message
  local epoch
  epoch=$(date +%s)
  echo "${status}|${epoch}|${message}" > "$status_file"
}

#------------------------------------------------------------------------------
# Mag queue-pop-skill: Pop next request from queue and output skill command
# Outputs the plain skill command to stdout; nothing if queue is empty.
# Used by the keepalive path and mag start to send commands via tmux.
#------------------------------------------------------------------------------

mag_queue_pop_skill() {
  local queue_file
  queue_file="$(ludics_queue_file)"

  # Exit silently if no queue or empty
  [[ -f "$queue_file" ]] || return 0
  [[ -s "$queue_file" ]] || return 0

  # Read first request
  local request action request_id
  request=$(head -n 1 "$queue_file")
  action=$(echo "$request" | jq -r '.action' 2>/dev/null)
  request_id=$(echo "$request" | jq -r '.id' 2>/dev/null)

  # Bail if parsing failed
  if [[ -z "$action" || "$action" == "null" ]]; then
    echo "mag queue-pop: invalid request in queue (no action), leaving in queue" >&2
    return 0
  fi

  # Remove from queue atomically
  local tmp="${queue_file}.tmp"
  tail -n +2 "$queue_file" > "$tmp" && mv "$tmp" "$queue_file"

  # Export request info for skills to use
  export LUDICS_REQUEST_ID="$request_id"
  LUDICS_STATE_PATH="$(ludics_state_harness_dir)"
  export LUDICS_STATE_PATH
  LUDICS_RESULTS_DIR="$(ludics_results_dir)"
  export LUDICS_RESULTS_DIR
  mkdir -p "$LUDICS_RESULTS_DIR"

  # Map action to skill command
  local skill_command=""
  case "$action" in
    briefing)
      briefing_precompute_context
      skill_command="/ludics-briefing"
      ;;
    suggest)        skill_command="/ludics-suggest" ;;
    analyze-issue)
      local issue
      issue=$(echo "$request" | jq -r '.issue' 2>/dev/null)
      skill_command="/ludics-analyze-issue $issue" ;;
    elaborate)
      local task
      task=$(echo "$request" | jq -r '.task' 2>/dev/null)
      skill_command="/ludics-elaborate $task" ;;
    health-check)   skill_command="/ludics-health-check" ;;
    learn)          skill_command="/ludics-learn" ;;
    sync-learnings) skill_command="/ludics-sync-learnings" ;;
    techdebt)       skill_command="/ludics-techdebt" ;;
    message)        skill_command="/ludics-read-inbox" ;;
    *)
      echo "mag queue-pop: unknown queue action: $action" >&2
      return 0
      ;;
  esac

  echo "$skill_command"
}

#------------------------------------------------------------------------------
# Mag queue-pop: Pop next request and output Stop hook JSON
# Used by the Claude Code Stop hook (ludics-on-stop).
# Returns JSON with decision:"block" and the skill command as reason,
# which tells Claude Code to continue with that command as its instruction.
#------------------------------------------------------------------------------

mag_queue_pop() {
  local cwd="${1:-}"

  # Only process queue for Mag session (cwd must be inside the harness dir)
  if [[ -n "$cwd" ]]; then
    local harness_dir
    harness_dir="$(ludics_state_harness_dir)"
    if [[ "$cwd" != "$harness_dir"* ]]; then
      return 0
    fi
  fi

  local skill_command
  skill_command="$(mag_queue_pop_skill)"

  if [[ -n "$skill_command" ]]; then
    jq -n --arg reason "$skill_command" '{"decision": "block", "reason": $reason}'
  fi
}

#------------------------------------------------------------------------------
# Mag send: Send a command to Mag (for automation)
#------------------------------------------------------------------------------

mag_send() {
  local command="$1"

  if ! mag_is_running; then
    ludics_die "Mag session is not running. Start with: ludics mag start"
  fi

  trigger_skill "$MAG_SESSION_NAME" "$command"
  ludics_info "Sent command to Mag: $command"
}

#------------------------------------------------------------------------------
# Mag doctor: Health check for Mag setup
#------------------------------------------------------------------------------

mag_doctor() {
  local all_ok=true

  echo "=== Mag Health Check ==="
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
  if mag_is_running; then
    echo "Mag session: running"
  else
    echo "Mag session: not running"
  fi

  # Check state directory
  local state_dir
  state_dir="$(mag_state_dir)"
  if [[ -d "$state_dir" ]]; then
    echo "State directory: $state_dir"
  else
    echo "State directory: $state_dir (not created yet)"
  fi

  # Check queue file
  local queue_file
  queue_file="$(ludics_queue_file)"
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
  echo "  - ~/.claude/hooks/ludics-on-stop.sh"
  echo "  - ~/.config/claude-code/hooks/ludics-on-stop.sh"

  if [[ -f "$HOME/.claude/hooks/ludics-on-stop.sh" ]]; then
    echo "  Found: ~/.claude/hooks/ludics-on-stop.sh"
  elif [[ -f "$HOME/.config/claude-code/hooks/ludics-on-stop.sh" ]]; then
    echo "  Found: ~/.config/claude-code/hooks/ludics-on-stop.sh"
  else
    echo "  Not found - install with: ludics init --hooks"
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
# Mag briefing: Request a briefing and wait for result
#------------------------------------------------------------------------------

mag_briefing() {
  local wait="${1:-true}"
  local timeout="${2:-300}"

  # Queue the briefing request
  local request_id
  request_id=$(ludics_queue_request "briefing")
  echo "Queued briefing request: $request_id"

  if [[ "$wait" != "true" ]]; then
    echo "Mag will process when ready"
    return 0
  fi

  # Check if Mag is running
  if ! mag_is_running; then
    ludics_warn "Mag session is not running. Start with: ludics mag start"
    ludics_warn "Or process manually: the request is queued"
    return 1
  fi

  echo "Waiting for Mag to process (timeout: ${timeout}s)..."

  # Wait for result
  local result
  if result=$(ludics_wait_for_result "$request_id" "$timeout"); then
    echo ""
    echo "=== Briefing Result ==="
    echo "$result" | jq -r '.output // "No output"' 2>/dev/null || echo "$result"

    # Send notification
    if command -v notify_pai >/dev/null 2>&1; then
      notify_pai "Briefing ready" 3 "ludics briefing"
    fi

    return 0
  else
    ludics_warn "Timeout waiting for briefing result"
    return 1
  fi
}

#------------------------------------------------------------------------------
# Pre-compute briefing context: gather all data into briefing-context.md
# so the /ludics-briefing skill can focus on strategic reasoning.
#------------------------------------------------------------------------------

briefing_precompute_context() {
  local harness_dir
  harness_dir="$(ludics_state_harness_dir)"
  local context_file="$harness_dir/mag/briefing-context.md"
  local timestamp
  timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  mkdir -p "$harness_dir/mag"

  # 1. Slots refresh (also triggers session discovery via sessions_discover_and_report)
  ludics_info "briefing pre-compute: refreshing slots and sessions..."
  slots_refresh 2>/dev/null || true

  # 2. Capture slots list
  local slots_output
  slots_output="$(slots_list 2>/dev/null)" || slots_output="(unavailable)"

  # 3. Read sessions report (written by slots_refresh -> sessions_discover_and_report)
  local sessions_content
  local sessions_file="$harness_dir/sessions.md"
  if [[ -f "$sessions_file" ]]; then
    sessions_content="$(cat "$sessions_file")"
  else
    sessions_content="(no sessions report available)"
  fi

  # 4. Flow computations
  local flow_ready_output flow_critical_output
  flow_ready_output="$(flow_ready 2>/dev/null)" || flow_ready_output="(unavailable)"
  flow_critical_output="$(flow_critical 2>/dev/null)" || flow_critical_output="(unavailable)"

  # 5. Tasks needing elaboration
  local needs_elab_output
  needs_elab_output="$(tasks_needs_elaboration 2>/dev/null)" || needs_elab_output=""
  if [[ -z "$needs_elab_output" ]]; then
    needs_elab_output="None"
  fi

  # 6. Inbox (consume: pull remote, print, archive, clear)
  local inbox_output
  inbox_output="$(ludics_inbox_consume 2>/dev/null)" || inbox_output=""
  if [[ -z "$inbox_output" ]]; then
    inbox_output="No pending messages."
  fi

  # 7. Recent journal
  local journal_output
  journal_output="$(ludics_journal_recent 20 2>/dev/null)" || journal_output="(no journal entries)"

  # 8. Same-day check: compare existing briefing date with today
  local sameday_status="new" existing_date="none"
  local briefing_file="$harness_dir/briefing.md"
  if [[ -f "$briefing_file" ]]; then
    local first_heading
    first_heading="$(head -n 5 "$briefing_file" | grep -oE '^# Briefing - [0-9]{4}-[0-9]{2}-[0-9]{2}' || true)"
    if [[ -n "$first_heading" ]]; then
      existing_date="${first_heading##*- }"
      local today
      today="$(date +%Y-%m-%d)"
      if [[ "$existing_date" == "$today" ]]; then
        sameday_status="amend"
      fi
    fi
  fi

  # 9. Write context file atomically
  cat > "${context_file}.tmp" <<CONTEXT_EOF
# Briefing Context

Generated: $timestamp

## Same-Day Status

Status: $sameday_status
Existing briefing date: $existing_date

## Inbox Messages

$inbox_output

## Slots State

$slots_output

## Sessions Report

$sessions_content

## Flow: Ready Queue

$flow_ready_output

## Flow: Critical Items

$flow_critical_output

## Tasks Needing Elaboration

$needs_elab_output

## Recent Journal

$journal_output
CONTEXT_EOF
  mv "${context_file}.tmp" "$context_file"

  ludics_info "briefing context written to $context_file"
}
