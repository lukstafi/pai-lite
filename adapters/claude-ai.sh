#!/usr/bin/env bash
set -euo pipefail

# ludics/adapters/claude-ai.sh - Claude.ai web interface integration
# Tracks browser-based conversations via bookmarks/URLs with metadata

#------------------------------------------------------------------------------
# Helper: Get bookmarks file location
#------------------------------------------------------------------------------

adapter_claude_ai_bookmarks_file() {
  if [[ -n "${LUDICS_STATE_DIR:-}" ]]; then
    echo "$LUDICS_STATE_DIR/claude-ai.urls"
  else
    echo "$HOME/.config/ludics/claude-ai.urls"
  fi
}

#------------------------------------------------------------------------------
# Helper: Get state directory for metadata
#------------------------------------------------------------------------------

adapter_claude_ai_state_dir() {
  if [[ -n "${LUDICS_STATE_DIR:-}" ]]; then
    echo "$LUDICS_STATE_DIR/claude-ai"
  else
    echo "$HOME/.config/ludics/claude-ai"
  fi
}

#------------------------------------------------------------------------------
# Helper: Get conversation metadata file
#------------------------------------------------------------------------------

adapter_claude_ai_metadata_file() {
  local conv_id="$1"
  local state_dir
  state_dir="$(adapter_claude_ai_state_dir)"
  echo "$state_dir/${conv_id}.meta"
}

#------------------------------------------------------------------------------
# Adapter interface for ludics
#------------------------------------------------------------------------------

adapter_claude_ai_read_state() {
  local bookmarks state_dir
  bookmarks="$(adapter_claude_ai_bookmarks_file)"
  state_dir="$(adapter_claude_ai_state_dir)"

  [[ -f "$bookmarks" ]] || return 1

  echo "**Mode:** claude-ai"
  echo ""
  echo "**Conversations:**"

  local has_urls=false
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^# ]] && continue

    has_urls=true

    # Parse line format: URL [label] or just URL
    if [[ "$line" =~ ^([^[:space:]]+)[[:space:]]+(.+)$ ]]; then
      local url="${BASH_REMATCH[1]}"
      local label="${BASH_REMATCH[2]}"
      echo "- [$label]($url)"

      # Extract conversation ID from URL if possible
      if [[ "$url" =~ claude\.ai/chat/([a-zA-Z0-9-]+) ]]; then
        local conv_id="${BASH_REMATCH[1]}"
        local meta_file
        meta_file="$(adapter_claude_ai_metadata_file "$conv_id")"

        if [[ -f "$meta_file" ]]; then
          # Display metadata if available
          if grep -q '^model=' "$meta_file" 2>/dev/null; then
            local model
            model=$(grep '^model=' "$meta_file" | cut -d= -f2-)
            echo "  Model: $model"
          fi
          if grep -q '^task=' "$meta_file" 2>/dev/null; then
            local task
            task=$(grep '^task=' "$meta_file" | cut -d= -f2-)
            echo "  Task: $task"
          fi
          if grep -q '^updated=' "$meta_file" 2>/dev/null; then
            local updated
            updated=$(grep '^updated=' "$meta_file" | cut -d= -f2-)
            echo "  Updated: $updated"
          fi
        fi
      fi
    else
      # Just a URL without label
      echo "- $line"
    fi
  done < "$bookmarks"

  if [[ "$has_urls" == "false" ]]; then
    return 1
  fi

  # Display summary statistics
  if [[ -d "$state_dir" ]]; then
    local meta_count
    meta_count=$(find "$state_dir" -name "*.meta" -type f 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$meta_count" -gt 0 ]]; then
      echo ""
      echo "**Stats:**"
      echo "- Tracked conversations: $meta_count"
    fi
  fi

  return 0
}

adapter_claude_ai_start() {
  local url="${1:-}"
  local label="${2:-Claude.ai conversation}"
  local task_id="${3:-}"

  local bookmarks state_dir
  bookmarks="$(adapter_claude_ai_bookmarks_file)"
  state_dir="$(adapter_claude_ai_state_dir)"

  # Ensure directories exist
  mkdir -p "$(dirname "$bookmarks")"
  mkdir -p "$state_dir"

  if [[ -z "$url" ]]; then
    echo "claude-ai start: Opening new Claude.ai conversation..." >&2
    echo "Please provide the conversation URL to track it:" >&2
    echo "  ludics adapter claude-ai add <url> [label]" >&2
    echo "" >&2
    echo "Or manually add to: $bookmarks" >&2
    return 1
  fi

  # Validate URL format
  if [[ ! "$url" =~ ^https?://claude\.ai ]]; then
    echo "Warning: URL doesn't look like a Claude.ai conversation: $url" >&2
  fi

  # Add to bookmarks file
  echo "$url $label" >> "$bookmarks"
  echo "Added Claude.ai conversation: $label" >&2
  echo "  URL: $url" >&2

  # Extract conversation ID and create metadata if possible
  if [[ "$url" =~ claude\.ai/chat/([a-zA-Z0-9-]+) ]]; then
    local conv_id="${BASH_REMATCH[1]}"
    local meta_file
    meta_file="$(adapter_claude_ai_metadata_file "$conv_id")"

    cat > "$meta_file" <<EOF
conversation_id=$conv_id
url=$url
label=$label
started=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
updated=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
model=claude-sonnet
EOF

    if [[ -n "$task_id" ]]; then
      echo "task=$task_id" >> "$meta_file"
    fi

    echo "Created metadata: $meta_file" >&2
  fi

  echo ""
  echo "Open in browser: $url"
  return 0
}

adapter_claude_ai_stop() {
  local identifier="${1:-}"

  local bookmarks state_dir
  bookmarks="$(adapter_claude_ai_bookmarks_file)"
  state_dir="$(adapter_claude_ai_state_dir)"

  if [[ -z "$identifier" ]]; then
    echo "claude-ai stop: no conversation identifier provided." >&2
    echo "Usage: ludics adapter claude-ai stop <url|label|conversation_id>" >&2
    return 1
  fi

  if [[ ! -f "$bookmarks" ]]; then
    echo "claude-ai stop: no bookmarks file found at $bookmarks" >&2
    return 1
  fi

  # Remove from bookmarks
  local temp_file
  temp_file=$(mktemp)
  local removed=false

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -z "$line" ]] || [[ "$line" =~ ^# ]]; then
      echo "$line" >> "$temp_file"
      continue
    fi

    # Check if line matches identifier (URL or label)
    if [[ "$line" =~ $identifier ]]; then
      removed=true
      echo "Removed: $line" >&2

      # Try to remove metadata file
      if [[ "$line" =~ claude\.ai/chat/([a-zA-Z0-9-]+) ]]; then
        local conv_id="${BASH_REMATCH[1]}"
        local meta_file
        meta_file="$(adapter_claude_ai_metadata_file "$conv_id")"
        if [[ -f "$meta_file" ]]; then
          rm -f "$meta_file"
          echo "Removed metadata: $meta_file" >&2
        fi
      fi
    else
      echo "$line" >> "$temp_file"
    fi
  done < "$bookmarks"

  mv "$temp_file" "$bookmarks"

  if [[ "$removed" == "true" ]]; then
    echo "Claude.ai conversation removed from tracking."
    return 0
  else
    echo "claude-ai stop: conversation not found matching '$identifier'" >&2
    return 1
  fi
}

#------------------------------------------------------------------------------
# Additional helpers for Claude.ai operations
#------------------------------------------------------------------------------

adapter_claude_ai_add() {
  adapter_claude_ai_start "$@"
}

adapter_claude_ai_remove() {
  adapter_claude_ai_stop "$@"
}

adapter_claude_ai_list() {
  local bookmarks
  bookmarks="$(adapter_claude_ai_bookmarks_file)"

  if [[ ! -f "$bookmarks" ]]; then
    echo "No Claude.ai conversations tracked yet."
    echo "Track a conversation with: ludics adapter claude-ai add <url> [label]"
    return 0
  fi

  echo "Tracked Claude.ai conversations:"
  echo ""

  local count=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^# ]] && continue

    count=$((count + 1))

    if [[ "$line" =~ ^([^[:space:]]+)[[:space:]]+(.+)$ ]]; then
      local url="${BASH_REMATCH[1]}"
      local label="${BASH_REMATCH[2]}"
      echo "$count. $label"
      echo "   $url"

      # Show metadata if available
      if [[ "$url" =~ claude\.ai/chat/([a-zA-Z0-9-]+) ]]; then
        local conv_id="${BASH_REMATCH[1]}"
        local meta_file
        meta_file="$(adapter_claude_ai_metadata_file "$conv_id")"

        if [[ -f "$meta_file" ]]; then
          if grep -q '^model=' "$meta_file" 2>/dev/null; then
            echo "   Model: $(grep '^model=' "$meta_file" | cut -d= -f2-)"
          fi
          if grep -q '^task=' "$meta_file" 2>/dev/null; then
            echo "   Task: $(grep '^task=' "$meta_file" | cut -d= -f2-)"
          fi
          if grep -q '^updated=' "$meta_file" 2>/dev/null; then
            echo "   Updated: $(grep '^updated=' "$meta_file" | cut -d= -f2-)"
          fi
        fi
      fi
    else
      echo "$count. $line"
    fi
    echo ""
  done < "$bookmarks"

  if [[ $count -eq 0 ]]; then
    echo "No conversations found in bookmarks file."
  fi
}

adapter_claude_ai_update() {
  local identifier="$1"
  local key="$2"
  local value="$3"

  if [[ -z "$identifier" || -z "$key" || -z "$value" ]]; then
    echo "Usage: update <conversation_id|url> <key> <value>" >&2
    return 1
  fi

  local conv_id=""

  # Extract conversation ID from URL if needed
  if [[ "$identifier" =~ claude\.ai/chat/([a-zA-Z0-9-]+) ]]; then
    conv_id="${BASH_REMATCH[1]}"
  else
    conv_id="$identifier"
  fi

  local meta_file
  meta_file="$(adapter_claude_ai_metadata_file "$conv_id")"

  if [[ ! -f "$meta_file" ]]; then
    echo "No metadata found for conversation '$identifier'" >&2
    return 1
  fi

  # Update timestamp
  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Update or append key=value
  if grep -q "^${key}=" "$meta_file"; then
    # Update existing key (macOS compatible)
    if [[ "$(uname)" == "Darwin" ]]; then
      sed -i '' "s|^${key}=.*|${key}=${value}|" "$meta_file"
      sed -i '' "s|^updated=.*|updated=${now}|" "$meta_file"
    else
      sed -i "s|^${key}=.*|${key}=${value}|" "$meta_file"
      sed -i "s|^updated=.*|updated=${now}|" "$meta_file"
    fi
  else
    # Append new key
    echo "${key}=${value}" >> "$meta_file"
    if grep -q "^updated=" "$meta_file"; then
      if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' "s|^updated=.*|updated=${now}|" "$meta_file"
      else
        sed -i "s|^updated=.*|updated=${now}|" "$meta_file"
      fi
    else
      echo "updated=${now}" >> "$meta_file"
    fi
  fi

  echo "Updated $key for conversation $conv_id"
}
