#!/bin/bash
# pai-lite Mayor Stop Hook
# Installed by: pai-lite init --hooks
#
# This hook fires when Claude Code finishes a turn. It reads the Stop event
# JSON from stdin, checks stop_hook_active to prevent loops, pops the next
# queued request, and outputs a JSON decision to continue Claude with the
# skill command.

# Read Stop event input from stdin
input=$(cat)

# Prevent infinite loops: if Claude is already continuing from a stop hook,
# don't pop another request.
stop_hook_active=$(echo "$input" | jq -r '.stop_hook_active // false' 2>/dev/null)
if [[ "$stop_hook_active" == "true" ]]; then
  exit 0
fi

# Find pai-lite binary and run queue-pop
if command -v pai-lite >/dev/null 2>&1; then
  exec pai-lite mayor queue-pop
fi

# Fallback: check common install locations
for bin in "$HOME/.local/bin/pai-lite" "$HOME/.local/pai-lite/bin/pai-lite"; do
  if [[ -x "$bin" ]]; then
    exec "$bin" mayor queue-pop
  fi
done

# pai-lite not found - exit silently
exit 0
