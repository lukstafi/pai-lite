#!/usr/bin/env bash
set -euo pipefail

adapter_claude_code_read_state() {
  local session_name="${1:-}"
  if ! command -v tmux >/dev/null 2>&1; then
    return 1
  fi

  if [[ -z "$session_name" ]]; then
    session_name=$(tmux ls 2>/dev/null | head -n 1 | cut -d: -f1)
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
}

adapter_claude_code_start() {
  echo "claude-code start: open your tmux session manually." >&2
  return 1
}

adapter_claude_code_stop() {
  echo "claude-code stop: end the tmux session manually." >&2
  return 1
}
