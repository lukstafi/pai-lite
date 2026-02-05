#!/bin/bash
# pai-lite Mayor Stop Hook
# Install to: ~/.claude/hooks/on-stop.sh
#
# This hook fires when Claude Code finishes a turn and returns to the prompt.
# It reads queued requests from pai-lite and outputs the appropriate skill command.
#
# Setup:
# 1. Copy this file to ~/.claude/hooks/on-stop.sh
# 2. Make it executable: chmod +x ~/.claude/hooks/on-stop.sh
# 3. Ensure STATE_PATH points to your harness directory
#
# The hook's stdout becomes the next user prompt for Claude Code.

# Configuration - adjust to match your setup
STATE_PATH="${PAI_LITE_STATE_PATH:-$HOME/self-improve/harness}"
QUEUE="$STATE_PATH/tasks/queue.jsonl"
RESULTS="$STATE_PATH/tasks/results"

# Exit silently if no queue file
[[ -f "$QUEUE" ]] || exit 0
[[ -s "$QUEUE" ]] || exit 0

# Read first request from queue
request=$(head -n 1 "$QUEUE")

# Remove it from queue atomically
tmp="${QUEUE}.tmp"
tail -n +2 "$QUEUE" > "$tmp" && mv "$tmp" "$QUEUE"

# Parse the action
action=$(echo "$request" | jq -r '.action' 2>/dev/null)
request_id=$(echo "$request" | jq -r '.id' 2>/dev/null)

# Ensure results directory exists
mkdir -p "$RESULTS"

# Map action to skill command
# The output here becomes Claude Code's next input
case "$action" in
    briefing)
        echo "/pai-briefing"
        ;;
    suggest)
        echo "/pai-suggest"
        ;;
    analyze-issue)
        issue=$(echo "$request" | jq -r '.issue' 2>/dev/null)
        echo "/pai-analyze-issue $issue"
        ;;
    elaborate)
        task=$(echo "$request" | jq -r '.task' 2>/dev/null)
        echo "/pai-elaborate $task"
        ;;
    health-check)
        echo "/pai-health-check"
        ;;
    *)
        # Unknown action - log and skip
        echo "Unknown queue action: $action" >&2
        exit 0
        ;;
esac

# Note: The Mayor should write results to $RESULTS/${request_id}.json
# when it completes the action. Example:
#
# {
#   "id": "req-1706789012-12345",
#   "status": "completed",
#   "timestamp": "2026-02-01T12:30:00Z",
#   "output": "..."
# }
