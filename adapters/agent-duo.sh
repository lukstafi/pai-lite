#!/usr/bin/env bash
set -euo pipefail

adapter_agent_duo_read_state() {
  local project_dir="$1"
  local sync_dir="$project_dir/.peer-sync"
  local state_file ports_file

  [[ -d "$sync_dir" ]] || return 1
  state_file="$sync_dir/state.json"
  ports_file="$sync_dir/ports.json"

  local phase="" round="" session=""
  if [[ -f "$state_file" ]] && command -v python3 >/dev/null 2>&1; then
    read -r phase round session <<<"$(python3 - "$state_file" <<'PY'
import json,sys
path = sys.argv[1]
try:
    data = json.load(open(path))
except Exception:
    data = {}
print(data.get("phase",""), data.get("round",""), data.get("session",""))
PY
)"
  elif [[ -f "$state_file" ]]; then
    phase=$(grep -E '"phase"' "$state_file" | head -n 1 | sed -E 's/.*"phase"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')
    round=$(grep -E '"round"' "$state_file" | head -n 1 | sed -E 's/.*"round"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/')
  fi

  echo "**Mode:** agent-duo"
  [[ -n "$session" ]] && echo "**Session:** $session"

  if [[ -f "$ports_file" ]]; then
    echo ""
    echo "**Terminals:**"
    if command -v python3 >/dev/null 2>&1; then
      python3 - "$ports_file" <<'PY'
import json,sys
ports = json.load(open(sys.argv[1]))
for key,label in [("orchestrator","Orchestrator"),("claude","Claude"),("codex","Codex")]:
    if key in ports:
        print(f"- {label}: http://localhost:{ports[key]}")
PY
    else
      if grep -q '"orchestrator"' "$ports_file"; then
        echo "- Orchestrator: http://localhost:$(grep -E '"orchestrator"' "$ports_file" | sed -E 's/.*: *([0-9]+).*/\1/' )"
      fi
      if grep -q '"claude"' "$ports_file"; then
        echo "- Claude: http://localhost:$(grep -E '"claude"' "$ports_file" | sed -E 's/.*: *([0-9]+).*/\1/' )"
      fi
      if grep -q '"codex"' "$ports_file"; then
        echo "- Codex: http://localhost:$(grep -E '"codex"' "$ports_file" | sed -E 's/.*: *([0-9]+).*/\1/' )"
      fi
    fi
  fi

  if [[ -n "$phase" || -n "$round" ]]; then
    echo ""
    echo "**Runtime:**"
    [[ -n "$phase" ]] && echo "- Phase: $phase"
    [[ -n "$round" ]] && echo "- Round: $round"
  fi
}

adapter_agent_duo_start() {
  echo "agent-duo start: use the agent-duo CLI to launch sessions." >&2
  return 1
}

adapter_agent_duo_stop() {
  echo "agent-duo stop: use the agent-duo CLI to stop sessions." >&2
  return 1
}
