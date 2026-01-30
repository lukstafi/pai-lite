#!/usr/bin/env bash
set -euo pipefail

adapter_claude_ai_bookmarks_file() {
  if [[ -n "${PAI_LITE_STATE_DIR:-}" ]]; then
    echo "$PAI_LITE_STATE_DIR/claude-ai.urls"
  else
    echo "$HOME/.config/pai-lite/claude-ai.urls"
  fi
}

adapter_claude_ai_read_state() {
  local bookmarks
  bookmarks="$(adapter_claude_ai_bookmarks_file)"
  [[ -f "$bookmarks" ]] || return 1

  echo "**Mode:** claude-ai"
  echo ""
  echo "**Terminals:**"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^# ]] && continue
    echo "- $line"
  done < "$bookmarks"
}

adapter_claude_ai_start() {
  echo "claude-ai start: open a bookmark from $(adapter_claude_ai_bookmarks_file)" >&2
  return 1
}

adapter_claude_ai_stop() {
  echo "claude-ai stop: close the browser tab manually." >&2
  return 1
}
