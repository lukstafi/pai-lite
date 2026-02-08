#!/usr/bin/env bash
set -euo pipefail

# pai-lite/adapters/manual.sh - Manual/human work tracking
# Track human work without an AI agent (just notes and status)

#------------------------------------------------------------------------------
# Helper: Get state directory for manual tracking
#------------------------------------------------------------------------------

adapter_manual_state_dir() {
  if [[ -n "${PAI_LITE_STATE_DIR:-}" ]]; then
    echo "$PAI_LITE_STATE_DIR/manual"
  else
    echo "$HOME/.config/pai-lite/manual"
  fi
}

#------------------------------------------------------------------------------
# Helper: Get slot tracking file
#------------------------------------------------------------------------------

adapter_manual_slot_file() {
  local slot_num="$1"
  local state_dir
  state_dir="$(adapter_manual_state_dir)"
  echo "$state_dir/slot-${slot_num}.md"
}

#------------------------------------------------------------------------------
# Helper: Get status file
#------------------------------------------------------------------------------

adapter_manual_status_file() {
  local slot_num="$1"
  local state_dir
  state_dir="$(adapter_manual_state_dir)"
  echo "$state_dir/slot-${slot_num}.status"
}

#------------------------------------------------------------------------------
# Adapter interface: read_state
# Shows the current manual work state for a slot
#------------------------------------------------------------------------------

adapter_manual_read_state() {
  local slot_num="$1"
  local state_dir
  state_dir="$(adapter_manual_state_dir)"

  local slot_file status_file
  slot_file="$(adapter_manual_slot_file "$slot_num")"
  status_file="$(adapter_manual_status_file "$slot_num")"

  echo "**Mode:** manual (human work)"
  echo ""

  # Check for status
  if [[ -f "$status_file" ]]; then
    local status started task
    status=$(grep '^status=' "$status_file" 2>/dev/null | cut -d= -f2- || echo "active")
    started=$(grep '^started=' "$status_file" 2>/dev/null | cut -d= -f2- || echo "unknown")
    task=$(grep '^task=' "$status_file" 2>/dev/null | cut -d= -f2- || echo "")

    echo "**Status:** $status"
    echo "**Started:** $started"
    if [[ -n "$task" ]]; then
      echo "**Task:** $task"
    fi
  else
    echo "**Status:** not initialized"
    echo ""
    echo "Use 'pai-lite slot $slot_num start' to begin tracking manual work."
    return 1
  fi

  # Show notes if file exists
  if [[ -f "$slot_file" ]]; then
    echo ""
    echo "**Notes:**"
    cat "$slot_file"
  fi

  return 0
}

#------------------------------------------------------------------------------
# Adapter interface: start
# Initialize manual work tracking for a slot
#------------------------------------------------------------------------------

adapter_manual_start() {
  local slot_num="$1"
  local state_dir
  state_dir="$(adapter_manual_state_dir)"
  mkdir -p "$state_dir"

  local slot_file status_file
  slot_file="$(adapter_manual_slot_file "$slot_num")"
  status_file="$(adapter_manual_status_file "$slot_num")"

  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Create status file
  {
    echo "status=active"
    echo "started=$timestamp"
    echo "task="
  } > "$status_file"

  # Create empty notes file
  {
    echo "# Manual Work Notes - Slot $slot_num"
    echo ""
    echo "Started: $timestamp"
    echo ""
    echo "## Progress"
    echo ""
  } > "$slot_file"

  echo "Manual tracking initialized for slot $slot_num"
  echo "Add notes with: pai-lite slot $slot_num note \"your note\""
  return 0
}

#------------------------------------------------------------------------------
# Adapter interface: stop
# Complete/archive manual work tracking
#------------------------------------------------------------------------------

adapter_manual_stop() {
  local slot_num="$1"
  local state_dir
  state_dir="$(adapter_manual_state_dir)"

  local slot_file status_file
  slot_file="$(adapter_manual_slot_file "$slot_num")"
  status_file="$(adapter_manual_status_file "$slot_num")"

  if [[ ! -f "$status_file" ]]; then
    echo "No manual tracking found for slot $slot_num"
    return 1
  fi

  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Update status
  if [[ "$(uname)" == "Darwin" ]]; then
    sed -i '' "s/^status=.*/status=completed/" "$status_file"
  else
    sed -i "s/^status=.*/status=completed/" "$status_file"
  fi
  echo "completed=$timestamp" >> "$status_file"

  # Archive notes file
  if [[ -f "$slot_file" ]]; then
    local archive_dir="$state_dir/archive"
    mkdir -p "$archive_dir"
    local archive_name
    archive_name="slot-${slot_num}-$(date +%Y%m%d-%H%M%S).md"
    mv "$slot_file" "$archive_dir/$archive_name"
    echo "Notes archived to: $archive_dir/$archive_name"
  fi

  # Clean up status file
  rm -f "$status_file"

  echo "Manual tracking completed for slot $slot_num"
  return 0
}

#------------------------------------------------------------------------------
# Helper: Add a note to manual tracking
#------------------------------------------------------------------------------

adapter_manual_note() {
  local slot_num="$1"
  local note="$2"

  local slot_file status_file
  slot_file="$(adapter_manual_slot_file "$slot_num")"
  status_file="$(adapter_manual_status_file "$slot_num")"

  if [[ ! -f "$status_file" ]]; then
    echo "No manual tracking found for slot $slot_num"
    echo "Start with: pai-lite slot $slot_num start"
    return 1
  fi

  local timestamp
  timestamp=$(date +"%Y-%m-%d %H:%M")

  # Append note to file
  echo "- [$timestamp] $note" >> "$slot_file"

  echo "Note added to slot $slot_num"
  return 0
}

#------------------------------------------------------------------------------
# Helper: Update task description
#------------------------------------------------------------------------------

adapter_manual_set_task() {
  local slot_num="$1"
  local task="$2"

  local status_file
  status_file="$(adapter_manual_status_file "$slot_num")"

  if [[ ! -f "$status_file" ]]; then
    echo "No manual tracking found for slot $slot_num"
    return 1
  fi

  # Update task in status file
  if grep -q '^task=' "$status_file" 2>/dev/null; then
    if [[ "$(uname)" == "Darwin" ]]; then
      sed -i '' "s/^task=.*/task=$task/" "$status_file"
    else
      sed -i "s/^task=.*/task=$task/" "$status_file"
    fi
  else
    echo "task=$task" >> "$status_file"
  fi

  echo "Task set for slot $slot_num: $task"
  return 0
}

#------------------------------------------------------------------------------
# Helper: List all manual tracking entries (active and archived)
#------------------------------------------------------------------------------

adapter_manual_list() {
  local state_dir
  state_dir="$(adapter_manual_state_dir)"

  echo "=== Active Manual Work ==="
  local has_active=false
  for status_file in "$state_dir"/slot-*.status; do
    [[ -f "$status_file" ]] || continue
    has_active=true
    local slot_num
    slot_num=$(basename "$status_file" | sed 's/slot-//' | sed 's/.status//')
    local status started task
    status=$(grep '^status=' "$status_file" 2>/dev/null | cut -d= -f2- || echo "unknown")
    started=$(grep '^started=' "$status_file" 2>/dev/null | cut -d= -f2- || echo "unknown")
    task=$(grep '^task=' "$status_file" 2>/dev/null | cut -d= -f2- || echo "(none)")
    echo "Slot $slot_num: $status (started: $started)"
    [[ -n "$task" && "$task" != "(none)" ]] && echo "  Task: $task"
  done
  if [[ "$has_active" == "false" ]]; then
    echo "(none)"
  fi

  echo ""
  echo "=== Archived Work ==="
  local archive_dir="$state_dir/archive"
  if [[ -d "$archive_dir" ]]; then
    # shellcheck disable=SC2012 # ls -t for mtime sort; find has no native sort
    ls -1t "$archive_dir"/*.md 2>/dev/null | head -10 | while read -r f; do
      basename "$f"
    done
  else
    echo "(none)"
  fi
}

#------------------------------------------------------------------------------
# Helper: Get status string for external polling
#------------------------------------------------------------------------------

adapter_manual_get_status() {
  local slot_num="$1"
  local status_file
  status_file="$(adapter_manual_status_file "$slot_num")"

  if [[ ! -f "$status_file" ]]; then
    echo "inactive"
    return 1
  fi

  grep '^status=' "$status_file" 2>/dev/null | cut -d= -f2- || echo "unknown"
}
