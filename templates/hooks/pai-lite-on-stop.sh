#!/bin/bash
# pai-lite Mayor Stop Hook
# Install to: ~/.claude/hooks/pai-lite-on-stop.sh
#
# This hook fires when Claude Code finishes a turn and returns to the prompt.
# It reads queued requests from pai-lite and outputs the appropriate skill command.
#
# Setup:
# 1. Run: pai-lite init --hooks
#    Or manually copy to ~/.claude/hooks/pai-lite-on-stop.sh
# 2. Make executable: chmod +x ~/.claude/hooks/pai-lite-on-stop.sh
# 3. Configure Claude Code to use hooks from ~/.claude/hooks/
#
# The hook's stdout becomes the next user prompt for Claude Code.

#------------------------------------------------------------------------------
# State Path Detection
#------------------------------------------------------------------------------

# Priority order for finding state path:
# 1. PAI_LITE_STATE_PATH environment variable (explicit override)
# 2. Derive from pointer config (~/.config/pai-lite/config.yaml)
# 3. Fall back to common default

detect_state_path() {
  # 1. Check environment variable first
  if [[ -n "${PAI_LITE_STATE_PATH:-}" ]]; then
    echo "$PAI_LITE_STATE_PATH"
    return 0
  fi

  # 2. Try to read from pointer config
  local pointer_config="$HOME/.config/pai-lite/config.yaml"
  if [[ -f "$pointer_config" ]]; then
    local state_repo state_path repo_name

    # Parse state_repo (e.g., "lukstafi/self-improve")
    state_repo=$(awk '/^state_repo:/ { sub(/^[^:]+:[[:space:]]*/, ""); print; exit }' "$pointer_config")

    # Parse state_path (default: "harness")
    state_path=$(awk '/^state_path:/ { sub(/^[^:]+:[[:space:]]*/, ""); print; exit }' "$pointer_config")
    [[ -z "$state_path" ]] && state_path="harness"

    if [[ -n "$state_repo" ]]; then
      # Extract repo name from slug (e.g., "self-improve" from "lukstafi/self-improve")
      repo_name="${state_repo##*/}"
      local derived_path="$HOME/$repo_name/$state_path"

      if [[ -d "$derived_path" ]]; then
        echo "$derived_path"
        return 0
      fi
    fi
  fi

  # 3. Fall back to common default
  local default_path="$HOME/self-improve/harness"
  if [[ -d "$default_path" ]]; then
    echo "$default_path"
    return 0
  fi

  # Unable to detect - return empty
  return 1
}

#------------------------------------------------------------------------------
# Main Hook Logic
#------------------------------------------------------------------------------

# Detect state path
STATE_PATH=$(detect_state_path)
if [[ -z "$STATE_PATH" ]]; then
  # No state path found - exit silently
  exit 0
fi

QUEUE="$STATE_PATH/tasks/queue.jsonl"
RESULTS="$STATE_PATH/tasks/results"

# Exit silently if no queue file or empty
[[ -f "$QUEUE" ]] || exit 0
[[ -s "$QUEUE" ]] || exit 0

# Check if jq is available (required for parsing)
if ! command -v jq >/dev/null 2>&1; then
  echo "pai-lite-on-stop: jq not found, cannot process queue" >&2
  exit 0
fi

# Read first request from queue (but don't remove yet)
request=$(head -n 1 "$QUEUE")

# Parse the action and request ID - validate before dequeuing
action=$(echo "$request" | jq -r '.action' 2>/dev/null)
request_id=$(echo "$request" | jq -r '.id' 2>/dev/null)

# Exit without dequeuing if parsing failed or no valid action
if [[ -z "$action" || "$action" == "null" ]]; then
  echo "pai-lite-on-stop: invalid request in queue (no action), leaving in queue" >&2
  exit 0
fi

# Now that we have a valid action, remove from queue atomically
tmp="${QUEUE}.tmp"
tail -n +2 "$QUEUE" > "$tmp" && mv "$tmp" "$QUEUE"

# Ensure results directory exists
mkdir -p "$RESULTS"

# Export request info for skills to use
export PAI_LITE_REQUEST_ID="$request_id"
export PAI_LITE_STATE_PATH="$STATE_PATH"
export PAI_LITE_RESULTS_DIR="$RESULTS"

# Map action to skill command
# The output here becomes Claude Code's next input
case "$action" in
    briefing)
        echo "/briefing"
        ;;
    suggest)
        echo "/suggest"
        ;;
    analyze-issue)
        issue=$(echo "$request" | jq -r '.issue' 2>/dev/null)
        echo "/analyze-issue $issue"
        ;;
    elaborate)
        task=$(echo "$request" | jq -r '.task' 2>/dev/null)
        echo "/elaborate $task"
        ;;
    health-check)
        echo "/health-check"
        ;;
    learn)
        echo "/learn"
        ;;
    sync-learnings)
        echo "/sync-learnings"
        ;;
    techdebt)
        echo "/techdebt"
        ;;
    context-sync)
        echo "/context-sync"
        ;;
    *)
        # Unknown action - log to stderr and skip
        echo "pai-lite-on-stop: unknown queue action: $action" >&2
        exit 0
        ;;
esac

# The Mayor skill is responsible for writing results to:
#   $RESULTS/${request_id}.json
#
# Result format:
# {
#   "id": "req-1706789012-12345",
#   "status": "completed",
#   "timestamp": "2026-02-01T12:30:00Z",
#   "output": "..."
# }
#
# Skills can use pai_lite_write_result helper if sourcing common.sh,
# or write the JSON directly.
