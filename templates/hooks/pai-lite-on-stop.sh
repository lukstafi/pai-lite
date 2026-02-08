#!/bin/bash
# pai-lite Mayor Stop Hook
# Installed by: pai-lite init --hooks
#
# This hook fires when Claude Code finishes a turn. It reads the Stop event
# JSON from stdin, pops the next queued request, and outputs a JSON decision
# to continue Claude with the skill command.
#
# Loop prevention: when the queue is empty, mayor_queue_pop outputs nothing
# (exit 0), so Claude stops naturally. No stop_hook_active guard needed.

# Ensure Bash 4+ and tools like jq/yq are available (macOS system bash is v3)
export PATH="/opt/homebrew/bin:$PATH"

# Read Stop event input from stdin
input=$(cat)

# Extract cwd so mayor queue-pop can verify this is the Mayor session
cwd=$(echo "$input" | jq -r '.cwd // ""' 2>/dev/null)

# Find pai-lite binary and run queue-pop
if command -v pai-lite >/dev/null 2>&1; then
  exec pai-lite mayor queue-pop "$cwd"
fi

# Fallback: check common install locations
for bin in "$HOME/.local/bin/pai-lite" "$HOME/.local/pai-lite/bin/pai-lite"; do
  if [[ -x "$bin" ]]; then
    exec "$bin" mayor queue-pop "$cwd"
  fi
done

# pai-lite not found - exit silently
exit 0
