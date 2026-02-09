#!/usr/bin/env bash
set -euo pipefail

# Dashboard data generation for pai-lite
# Produces JSON files for the web dashboard from Markdown state

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$script_dir/common.sh"
# shellcheck source=lib/flow.sh
source "$script_dir/flow.sh"

# Get dashboard data directory
dashboard_data_dir() {
  echo "$(pai_lite_state_harness_dir)/dashboard/data"
}

# Ensure dashboard data directory exists
dashboard_ensure_data_dir() {
  local data_dir
  data_dir="$(dashboard_data_dir)"
  mkdir -p "$data_dir"
}

# Check required tools
dashboard_require_tools() {
  pai_lite_require_cmd jq
}

#------------------------------------------------------------------------------
# Generate slots.json
# Schema:
# [
#   {
#     "number": 1,
#     "empty": false,
#     "process": "task-042",
#     "task": "task-042",
#     "mode": "agent-duo",
#     "started": "2026-01-29T14:00Z",
#     "phase": "work",
#     "terminals": { "orchestrator": "http://localhost:7681", ... }
#   },
#   ...
# ]
#------------------------------------------------------------------------------
dashboard_generate_slots() {
  dashboard_require_tools

  local slots_file
  slots_file="$(pai_lite_state_harness_dir)/slots.md"

  if [[ ! -f "$slots_file" ]]; then
    echo "[]"
    return
  fi

  # Parse slots.md into JSON using a state machine
  local slots_json="[]"
  local current_slot=""
  local process="" mode="" started="" phase="" task=""
  local terminals_json="{}"
  local in_slot=0 in_terminals=0

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^##[[:space:]]+Slot[[:space:]]+([0-9]+) ]]; then
      # Emit previous slot if any
      if [[ $in_slot -eq 1 ]]; then
        local empty="true"
        [[ -n "$process" && "$process" != "(empty)" ]] && empty="false"
        local slot_obj
        slot_obj=$(jq -n \
          --arg num "$current_slot" \
          --argjson empty "$empty" \
          --arg process "$process" \
          --arg task "${task:-$process}" \
          --arg mode "$mode" \
          --arg started "$started" \
          --arg phase "$phase" \
          --argjson terminals "$terminals_json" \
          '{
            number: ($num | tonumber),
            empty: $empty,
            process: (if $empty then null else $process end),
            task: (if $empty then null else $task end),
            mode: (if $empty then null else $mode end),
            started: (if $empty then null else $started end),
            phase: (if $empty then null else $phase end),
            terminals: (if $empty then null elif ($terminals | length) == 0 then null else $terminals end)
          }')
        slots_json=$(echo "$slots_json" | jq --argjson obj "$slot_obj" '. + [$obj]')
      fi
      # Start new slot
      current_slot="${BASH_REMATCH[1]}"
      process="" mode="" started="" phase="" task=""
      terminals_json="{}"
      in_slot=1
      in_terminals=0
      continue
    fi

    if [[ $in_slot -eq 1 ]]; then
      # Check for entering/exiting Terminals block
      if [[ "$line" == "**Terminals:**" ]]; then
        in_terminals=1
        continue
      fi
      # Exit terminals block when hitting another section
      if [[ "$line" =~ ^\*\*[A-Za-z]+:\*\*$ && "$line" != "**Terminals:**" ]]; then
        in_terminals=0
      fi

      # Parse terminal entries (format: "- Name: URL" or "- Name: tmux session `name`")
      if [[ $in_terminals -eq 1 && "$line" =~ ^-[[:space:]]+([^:]+):[[:space:]]*(.+)$ ]]; then
        local term_name="${BASH_REMATCH[1]}"
        local term_value="${BASH_REMATCH[2]}"
        # Normalize name to lowercase for JSON key
        term_name=$(echo "$term_name" | tr '[:upper:]' '[:lower:]' | tr ' ' '_')
        terminals_json=$(echo "$terminals_json" | jq --arg k "$term_name" --arg v "$term_value" '. + {($k): $v}')
        continue
      fi

      case "$line" in
        "**Process:"*)
          process="${line#\*\*Process:\*\* }"
          process="${process#\*\*Process:\*\*}"
          process="${process# }"
          in_terminals=0
          ;;
        "**Mode:"*)
          mode="${line#\*\*Mode:\*\* }"
          mode="${mode#\*\*Mode:\*\*}"
          mode="${mode# }"
          in_terminals=0
          ;;
        "**Started:"*)
          started="${line#\*\*Started:\*\* }"
          started="${started#\*\*Started:\*\*}"
          started="${started# }"
          in_terminals=0
          ;;
        "**Task:"*)
          task="${line#\*\*Task:\*\* }"
          task="${task#\*\*Task:\*\*}"
          task="${task# }"
          in_terminals=0
          ;;
        "- Phase:"*)
          phase="${line#- Phase: }"
          phase="${phase#- Phase:}"
          phase="${phase# }"
          ;;
      esac
    fi
  done < "$slots_file"

  # Emit final slot
  if [[ $in_slot -eq 1 ]]; then
    local empty="true"
    [[ -n "$process" && "$process" != "(empty)" ]] && empty="false"
    local slot_obj
    slot_obj=$(jq -n \
      --arg num "$current_slot" \
      --argjson empty "$empty" \
      --arg process "$process" \
      --arg task "${task:-$process}" \
      --arg mode "$mode" \
      --arg started "$started" \
      --arg phase "$phase" \
      --argjson terminals "$terminals_json" \
      '{
        number: ($num | tonumber),
        empty: $empty,
        process: (if $empty then null else $process end),
        task: (if $empty then null else $task end),
        mode: (if $empty then null else $mode end),
        started: (if $empty then null else $started end),
        phase: (if $empty then null else $phase end),
        terminals: (if $empty then null elif ($terminals | length) == 0 then null else $terminals end)
      }')
    slots_json=$(echo "$slots_json" | jq --argjson obj "$slot_obj" '. + [$obj]')
  fi

  echo "$slots_json"
}

#------------------------------------------------------------------------------
# Generate ready.json
# Schema:
# [
#   {
#     "id": "task-042",
#     "title": "Implement feature X",
#     "priority": "A",
#     "project": "ocannl",
#     "context": "einsum"
#   },
#   ...
# ]
#------------------------------------------------------------------------------
dashboard_generate_ready() {
  flow_require_tools
  local tasks_json
  tasks_json="$(flow_collect_tasks)"

  # Filter and format ready tasks (same logic as flow_ready)
  echo "$tasks_json" | jq '
    [.[] | select(
      .status == "ready" and
      ((.dependencies.blocked_by | length) == 0 or .dependencies.blocked_by == null)
    )]
    | map(. + {
        _priority_val: (if .priority == "A" then 1 elif .priority == "B" then 2 elif .priority == "C" then 3 else 9 end)
      })
    | sort_by([._priority_val, .deadline // "9999-99-99"])
    | map({
        id: .id,
        title: .title,
        priority: .priority,
        project: .project,
        context: .context,
        deadline: .deadline
      })
  '
}

#------------------------------------------------------------------------------
# Generate notifications.json
# Schema:
# [
#   {
#     "timestamp": "2026-02-01T08:00:00Z",
#     "tier": "pai",
#     "priority": 3,
#     "title": "Briefing",
#     "message": "Morning briefing complete"
#   },
#   ...
# ]
# Ordered most recent first
#------------------------------------------------------------------------------
dashboard_generate_notifications() {
  dashboard_require_tools

  local journal_dir log_file
  journal_dir="$(pai_lite_state_harness_dir)/journal"
  log_file="$journal_dir/notifications.jsonl"

  if [[ ! -f "$log_file" ]]; then
    echo "[]"
    return
  fi

  # Read JSONL, convert to JSON array, reverse to get most recent first
  # Take last 50 notifications
  tail -n 50 "$log_file" | jq -s 'reverse'
}

#------------------------------------------------------------------------------
# Generate mayor.json
# Schema:
# {
#   "status": "running" | "idle" | "unknown",
#   "lastActivity": "2026-02-01T08:00:00Z",
#   "pendingRequests": 2,
#   "terminal": "http://localhost:7680"
# }
#------------------------------------------------------------------------------
dashboard_generate_mayor() {
  dashboard_require_tools

  local harness_dir queue_file
  harness_dir="$(pai_lite_state_harness_dir)"
  queue_file="$harness_dir/mayor/queue.jsonl"

  # Count pending requests
  local pending=0
  if [[ -f "$queue_file" && -s "$queue_file" ]]; then
    pending=$(wc -l < "$queue_file" | tr -d ' ')
  fi

  # Check for Mayor session status (look for tmux session or state file)
  local status="unknown"
  local last_activity=""
  local terminal=""

  # Get Mayor session name from config (default: pai-mayor)
  local mayor_session
  mayor_session=$(dashboard_get_mayor_session)
  [[ -z "$mayor_session" ]] && mayor_session="pai-mayor"

  # Check if Mayor tmux session exists
  if command -v tmux >/dev/null 2>&1; then
    if tmux has-session -t "$mayor_session" 2>/dev/null; then
      status="running"
    fi
  fi

  # Get Mayor ttyd port from config (default: 7679)
  local mayor_port
  mayor_port=$(dashboard_get_mayor_ttyd_port)
  [[ -z "$mayor_port" ]] && mayor_port="7679"
  terminal="$(pai_lite_get_url "$mayor_port")"

  # Check for Mayor state file (from claude-code adapter pattern)
  local mayor_state="$HOME/.config/pai-lite/mayor.state"
  if [[ -f "$mayor_state" ]]; then
    local state_status
    state_status=$(awk -F= '/^status=/ { print $2 }' "$mayor_state" 2>/dev/null || echo "")
    [[ -n "$state_status" ]] && status="$state_status"

    local state_activity
    state_activity=$(awk -F= '/^last_activity=/ { print $2 }' "$mayor_state" 2>/dev/null || echo "")
    [[ -n "$state_activity" ]] && last_activity="$state_activity"
  fi

  # Check results directory for latest activity
  local results_dir="$harness_dir/mayor/results"
  if [[ -d "$results_dir" ]]; then
    local latest_result
    # shellcheck disable=SC2012 # ls -t for mtime sort; find has no native sort
    latest_result=$(ls -t "$results_dir"/*.json 2>/dev/null | head -n 1 || echo "")
    if [[ -n "$latest_result" && -f "$latest_result" ]]; then
      local result_time
      result_time=$(jq -r '.timestamp // empty' "$latest_result" 2>/dev/null || echo "")
      if [[ -n "$result_time" && -z "$last_activity" ]]; then
        last_activity="$result_time"
      fi
    fi
  fi

  # Build JSON output
  jq -n \
    --arg status "$status" \
    --arg lastActivity "$last_activity" \
    --argjson pendingRequests "$pending" \
    --arg terminal "$terminal" \
    '{
      status: $status,
      lastActivity: (if $lastActivity == "" then null else $lastActivity end),
      pendingRequests: $pendingRequests,
      terminal: (if $terminal == "" then null else $terminal end)
    }'
}

# Get Mayor session name from config
dashboard_get_mayor_session() {
  local config
  config="$(pai_lite_config_path)"
  [[ -f "$config" ]] || return

  awk '
    /^[[:space:]]*mayor:/ { in_mayor=1; next }
    in_mayor && /^[[:space:]]*session:/ {
      sub(/^[^:]+:[[:space:]]*/, "", $0)
      gsub(/[[:space:]]+$/, "", $0)
      print $0
      exit
    }
    in_mayor && /^[^[:space:]]/ { in_mayor=0 }
  ' "$config"
}

# Get a dashboard config value
# Usage: dashboard_get_config <key>
dashboard_get_config() {
  local key="$1"
  local config
  config="$(pai_lite_config_path)"
  if [[ -f "$config" ]]; then
    local result
    result=$(yq eval ".dashboard.${key}" "$config" 2>/dev/null)
    if [[ "$result" != "null" && -n "$result" ]]; then
      echo "$result"
    fi
  fi
}

# Get Mayor ttyd port from config
dashboard_get_mayor_ttyd_port() {
  local config
  config="$(pai_lite_config_path)"
  [[ -f "$config" ]] || return

  awk '
    /^[[:space:]]*mayor:/ { in_mayor=1; next }
    in_mayor && /^[[:space:]]*ttyd_port:/ {
      sub(/^[^:]+:[[:space:]]*/, "", $0)
      gsub(/[[:space:]]+$/, "", $0)
      print $0
      exit
    }
    in_mayor && /^[^[:space:]]/ { in_mayor=0 }
  ' "$config"
}

#------------------------------------------------------------------------------
# Generate all dashboard data files
#------------------------------------------------------------------------------
dashboard_generate() {
  dashboard_ensure_data_dir
  local data_dir
  data_dir="$(dashboard_data_dir)"

  pai_lite_info "generating dashboard data..."

  dashboard_generate_slots > "$data_dir/slots.json"
  pai_lite_info "  slots.json"

  dashboard_generate_ready > "$data_dir/ready.json"
  pai_lite_info "  ready.json"

  dashboard_generate_notifications > "$data_dir/notifications.json"
  pai_lite_info "  notifications.json"

  dashboard_generate_mayor > "$data_dir/mayor.json"
  pai_lite_info "  mayor.json"

  pai_lite_info "dashboard data generated in $data_dir"
}

#------------------------------------------------------------------------------
# Serve dashboard via Python HTTP server
#------------------------------------------------------------------------------
dashboard_serve() {
  local port="${1:-7678}"
  local dashboard_dir
  dashboard_dir="$(pai_lite_state_harness_dir)/dashboard"

  if [[ ! -d "$dashboard_dir" ]]; then
    pai_lite_die "dashboard not installed. Run: pai-lite dashboard install"
  fi

  local server_script
  server_script="$(pai_lite_root)/lib/dashboard_server.py"

  if [[ ! -f "$server_script" ]]; then
    pai_lite_die "dashboard server script not found: $server_script"
  fi

  local bin_path
  bin_path="$(pai_lite_root)/bin/pai-lite"

  # Read TTL from config (default: 5 seconds)
  local ttl
  ttl="$(dashboard_get_config "ttl")"
  if [[ -z "$ttl" ]]; then
    ttl=5
  fi

  # Generate initial data so first page load is fast
  dashboard_generate

  pai_lite_info "serving dashboard at $(pai_lite_get_url "$port")"
  pai_lite_info "data regenerates lazily (TTL: ${ttl}s)"
  pai_lite_info "press Ctrl+C to stop"

  python3 "$server_script" "$port" "$dashboard_dir" "$bin_path" "$ttl"
}

#------------------------------------------------------------------------------
# Install dashboard templates to state repo
#------------------------------------------------------------------------------
dashboard_install() {
  local root_dir template_dir dashboard_dir
  root_dir="$(pai_lite_root)"
  template_dir="$root_dir/templates/dashboard"
  dashboard_dir="$(pai_lite_state_harness_dir)/dashboard"

  if [[ ! -d "$template_dir" ]]; then
    pai_lite_die "dashboard templates not found: $template_dir"
  fi

  pai_lite_info "installing dashboard to $dashboard_dir"

  mkdir -p "$dashboard_dir"
  cp -r "$template_dir"/* "$dashboard_dir/"

  # Create data directory
  mkdir -p "$dashboard_dir/data"

  pai_lite_info "dashboard installed"
  pai_lite_info "  run: pai-lite dashboard generate"
  pai_lite_info "  then: pai-lite dashboard serve"
}

#------------------------------------------------------------------------------
# Main dispatch
#------------------------------------------------------------------------------
dashboard_main() {
  local cmd="${1:-}"
  shift || true

  case "$cmd" in
    generate)
      dashboard_generate
      ;;
    serve)
      local port="${1:-}"
      if [[ -z "$port" ]]; then
        port="$(dashboard_get_config "port")"
      fi
      if [[ -z "$port" ]]; then
        port=7678
      fi
      dashboard_serve "$port"
      ;;
    install)
      dashboard_install
      ;;
    *)
      pai_lite_die "unknown dashboard command: $cmd (use: generate, serve, install)"
      ;;
  esac
}
