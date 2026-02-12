#!/usr/bin/env bash
set -euo pipefail

# Dashboard data generation for ludics
# Produces JSON files for the web dashboard from Markdown state

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$script_dir/common.sh"
# shellcheck source=lib/flow.sh
source "$script_dir/flow.sh"

# Get dashboard data directory
dashboard_data_dir() {
  echo "$(ludics_state_harness_dir)/dashboard/data"
}

# Ensure dashboard data directory exists
dashboard_ensure_data_dir() {
  local data_dir
  data_dir="$(dashboard_data_dir)"
  mkdir -p "$data_dir"
}

# Check required tools
dashboard_require_tools() {
  ludics_require_cmd jq
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
  slots_file="$(ludics_state_harness_dir)/slots.md"

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
  journal_dir="$(ludics_state_harness_dir)/journal"
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
# Generate mag.json
# Schema:
# {
#   "status": "running" | "idle" | "unknown",
#   "lastActivity": "2026-02-01T08:00:00Z",
#   "pendingRequests": 2,
#   "terminal": "http://localhost:7680"
# }
#------------------------------------------------------------------------------
dashboard_generate_mag() {
  dashboard_require_tools

  local harness_dir queue_file
  harness_dir="$(ludics_state_harness_dir)"
  queue_file="$harness_dir/mag/queue.jsonl"

  # Count pending requests
  local pending=0
  if [[ -f "$queue_file" && -s "$queue_file" ]]; then
    pending=$(wc -l < "$queue_file" | tr -d ' ')
  fi

  # Check for Mag session status (look for tmux session or state file)
  local status="unknown"
  local last_activity=""
  local terminal=""

  # Get Mag session name from config (default: ludics-mag)
  local mag_session
  mag_session=$(dashboard_get_mag_session)
  [[ -z "$mag_session" ]] && mag_session="ludics-mag"

  # Check if Mag tmux session exists
  if command -v tmux >/dev/null 2>&1; then
    if tmux has-session -t "$mag_session" 2>/dev/null; then
      status="running"
    fi
  fi

  # Get Mag ttyd port from config (default: 7679)
  local mag_port
  mag_port=$(dashboard_get_mag_ttyd_port)
  [[ -z "$mag_port" ]] && mag_port="7679"
  terminal="$(ludics_get_url "$mag_port")"

  # Check for Mag state file (from claude-code adapter pattern)
  local mag_state="$HOME/.config/ludics/mag.state"
  if [[ -f "$mag_state" ]]; then
    local state_status
    state_status=$(awk -F= '/^status=/ { print $2 }' "$mag_state" 2>/dev/null || echo "")
    [[ -n "$state_status" ]] && status="$state_status"

    local state_activity
    state_activity=$(awk -F= '/^last_activity=/ { print $2 }' "$mag_state" 2>/dev/null || echo "")
    [[ -n "$state_activity" ]] && last_activity="$state_activity"
  fi

  # Check results directory for latest activity
  local results_dir="$harness_dir/mag/results"
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

# Get Mag session name from config
dashboard_get_mag_session() {
  local config
  config="$(ludics_config_path)"
  [[ -f "$config" ]] || return

  awk '
    /^[[:space:]]*mag:/ { in_mag=1; next }
    in_mag && /^[[:space:]]*session:/ {
      sub(/^[^:]+:[[:space:]]*/, "", $0)
      gsub(/[[:space:]]+$/, "", $0)
      print $0
      exit
    }
    in_mag && /^[^[:space:]]/ { in_mag=0 }
  ' "$config"
}

# Get a dashboard config value
# Usage: dashboard_get_config <key>
dashboard_get_config() {
  local key="$1"
  local config
  config="$(ludics_config_path)"
  if [[ -f "$config" ]]; then
    local result
    result=$(yq eval ".dashboard.${key}" "$config" 2>/dev/null)
    if [[ "$result" != "null" && -n "$result" ]]; then
      echo "$result"
    fi
  fi
}

# Get Mag ttyd port from config
dashboard_get_mag_ttyd_port() {
  local config
  config="$(ludics_config_path)"
  [[ -f "$config" ]] || return

  awk '
    /^[[:space:]]*mag:/ { in_mag=1; next }
    in_mag && /^[[:space:]]*ttyd_port:/ {
      sub(/^[^:]+:[[:space:]]*/, "", $0)
      gsub(/[[:space:]]+$/, "", $0)
      print $0
      exit
    }
    in_mag && /^[^[:space:]]/ { in_mag=0 }
  ' "$config"
}

#------------------------------------------------------------------------------
# Generate briefing.json
# Reads briefing.md from the harness directory and converts to JSON
# Schema:
# {
#   "date": "2026-02-09",
#   "content": "# Briefing - 2026-02-09\n...",
#   "exists": true
# }
#------------------------------------------------------------------------------
dashboard_generate_briefing() {
  dashboard_require_tools

  local harness_dir briefing_file
  harness_dir="$(ludics_state_harness_dir)"
  briefing_file="$harness_dir/briefing.md"

  if [[ ! -f "$briefing_file" ]]; then
    jq -n '{ date: null, html: "", exists: false }'
    return
  fi

  local date_line=""
  local first_line
  first_line=$(head -n 1 "$briefing_file")
  if [[ "$first_line" =~ ^#[[:space:]]+Briefing[[:space:]]+-[[:space:]]+([0-9]{4}-[0-9]{2}-[0-9]{2}) ]]; then
    date_line="${BASH_REMATCH[1]}"
  fi

  local content
  content=$(cat "$briefing_file")

  # Convert markdown to simple HTML using jq for JSON escaping
  # We pass raw markdown; the browser will render it via JS
  jq -n \
    --arg date "$date_line" \
    --arg content "$content" \
    '{
      date: (if $date == "" then null else $date end),
      content: $content,
      exists: true
    }'
}

#------------------------------------------------------------------------------
# Generate all dashboard data files
#------------------------------------------------------------------------------
dashboard_generate() {
  dashboard_ensure_data_dir
  local data_dir
  data_dir="$(dashboard_data_dir)"

  ludics_info "generating dashboard data..."

  dashboard_generate_slots > "$data_dir/slots.json"
  ludics_info "  slots.json"

  dashboard_generate_ready > "$data_dir/ready.json"
  ludics_info "  ready.json"

  dashboard_generate_notifications > "$data_dir/notifications.json"
  ludics_info "  notifications.json"

  dashboard_generate_mag > "$data_dir/mag.json"
  ludics_info "  mag.json"

  dashboard_generate_briefing > "$data_dir/briefing.json"
  ludics_info "  briefing.json"

  ludics_info "dashboard data generated in $data_dir"
}

#------------------------------------------------------------------------------
# Serve dashboard via Python HTTP server
#------------------------------------------------------------------------------
dashboard_serve() {
  local port="${1:-7678}"
  local dashboard_dir
  dashboard_dir="$(ludics_state_harness_dir)/dashboard"

  if [[ ! -d "$dashboard_dir" ]]; then
    ludics_die "dashboard not installed. Run: ludics dashboard install"
  fi

  local server_script
  server_script="$(ludics_root)/lib/dashboard_server.py"

  if [[ ! -f "$server_script" ]]; then
    ludics_die "dashboard server script not found: $server_script"
  fi

  local bin_path
  bin_path="$(ludics_root)/bin/ludics"

  # Read TTL from config (default: 5 seconds)
  local ttl
  ttl="$(dashboard_get_config "ttl")"
  if [[ -z "$ttl" ]]; then
    ttl=5
  fi

  # Generate initial data so first page load is fast
  dashboard_generate

  ludics_info "serving dashboard at $(ludics_get_url "$port")"
  ludics_info "data regenerates lazily (TTL: ${ttl}s)"
  ludics_info "press Ctrl+C to stop"

  python3 "$server_script" "$port" "$dashboard_dir" "$bin_path" "$ttl"
}

#------------------------------------------------------------------------------
# Install dashboard templates to state repo
#------------------------------------------------------------------------------
dashboard_install() {
  local root_dir template_dir dashboard_dir
  root_dir="$(ludics_root)"
  template_dir="$root_dir/templates/dashboard"
  dashboard_dir="$(ludics_state_harness_dir)/dashboard"

  if [[ ! -d "$template_dir" ]]; then
    ludics_die "dashboard templates not found: $template_dir"
  fi

  ludics_info "installing dashboard to $dashboard_dir"

  mkdir -p "$dashboard_dir"
  cp -r "$template_dir"/* "$dashboard_dir/"

  # Create data directory
  mkdir -p "$dashboard_dir/data"

  ludics_info "dashboard installed"
  ludics_info "  run: ludics dashboard generate"
  ludics_info "  then: ludics dashboard serve"
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
      ludics_die "unknown dashboard command: $cmd (use: generate, serve, install)"
      ;;
  esac
}
