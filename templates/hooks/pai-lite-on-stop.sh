#!/bin/bash
# pai-lite Mayor Stop Hook
# Install to: ~/.claude/hooks/pai-lite-on-stop.sh
#
# This hook fires when Claude Code finishes a turn and returns to the prompt.
# It pops the next queued request and outputs the skill command.
#
# Setup:
# 1. Run: pai-lite init --hooks
#    Or manually copy to ~/.claude/hooks/pai-lite-on-stop.sh
# 2. Make executable: chmod +x ~/.claude/hooks/pai-lite-on-stop.sh
# 3. Configure Claude Code to use hooks from ~/.claude/hooks/
#
# The hook's stdout becomes the next user prompt for Claude Code.

# Find pai-lite binary
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
