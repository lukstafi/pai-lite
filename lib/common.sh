#!/usr/bin/env bash
set -euo pipefail

pai_lite_die() {
  echo "pai-lite: $*" >&2
  exit 1
}

pai_lite_warn() {
  echo "pai-lite: $*" >&2
}

pai_lite_info() {
  echo "pai-lite: $*" >&2
}

pai_lite_root() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  cd "$script_dir/.." && pwd
}

# Get the pointer config path (minimal config in ~/.config/pai-lite/)
pai_lite_pointer_config_path() {
  if [[ -n "${PAI_LITE_CONFIG:-}" ]]; then
    echo "$PAI_LITE_CONFIG"
  else
    echo "$HOME/.config/pai-lite/config.yaml"
  fi
}

# Get the full config path (in the harness directory)
# Falls back to pointer config if harness config doesn't exist
pai_lite_config_path() {
  local pointer_config harness_config
  pointer_config="$(pai_lite_pointer_config_path)"

  # If pointer config doesn't exist, return it anyway (error will be caught later)
  [[ -f "$pointer_config" ]] || { echo "$pointer_config"; return; }

  # Read state_repo and state_path from pointer config
  local state_repo state_path repo_name
  state_repo=$(awk '/^state_repo:/ { sub(/^[^:]+:[[:space:]]*/, ""); print; exit }' "$pointer_config")
  state_path=$(awk '/^state_path:/ { sub(/^[^:]+:[[:space:]]*/, ""); print; exit }' "$pointer_config")

  # Default state_path to "harness" if not specified
  [[ -n "$state_path" ]] || state_path="harness"

  # Compute harness config path
  if [[ -n "$state_repo" ]]; then
    repo_name="${state_repo##*/}"
    harness_config="$HOME/$repo_name/$state_path/config.yaml"

    # Return harness config if it exists, otherwise fall back to pointer
    if [[ -f "$harness_config" ]]; then
      echo "$harness_config"
    else
      echo "$pointer_config"
    fi
  else
    echo "$pointer_config"
  fi
}

pai_lite_require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || pai_lite_die "missing required command: $cmd"
}

pai_lite_config_get() {
  local key="$1"
  local config
  config="$(pai_lite_config_path)"
  [[ -f "$config" ]] || pai_lite_die "config not found: $config"
  awk -v key="$key" -F: '
    $0 ~ "^[[:space:]]*" key ":" {
      sub(/^[^:]+:[[:space:]]*/, "", $0)
      sub(/[[:space:]]+$/, "", $0)
      print $0
      exit
    }
  ' "$config"
}

pai_lite_config_slots_count() {
  local config
  config="$(pai_lite_config_path)"
  [[ -f "$config" ]] || pai_lite_die "config not found: $config"
  awk '
    $0 ~ /^[[:space:]]*slots:/ { in_slots=1; next }
    in_slots && $0 ~ /^[[:space:]]*count:/ {
      sub(/^[^:]+:[[:space:]]*/, "", $0)
      sub(/[[:space:]]+$/, "", $0)
      print $0
      exit
    }
    in_slots && $0 !~ /^[[:space:]]/ { in_slots=0 }
  ' "$config"
}

#------------------------------------------------------------------------------
# Config Parsing: Mayor Section
#------------------------------------------------------------------------------

# Get a value from the mayor config section
# Usage: pai_lite_config_mayor_get <key>
# Example: pai_lite_config_mayor_get "enabled" -> true/false
pai_lite_config_mayor_get() {
  local key="$1"
  local config
  config="$(pai_lite_config_path)"
  [[ -f "$config" ]] || return 1

  awk -v key="$key" '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    /^[[:space:]]*mayor:/ { in_mayor=1; next }
    in_mayor && $0 ~ "^[[:space:]]*" key ":" {
      value=$0
      sub(/^[^:]+:[[:space:]]*/, "", value)
      print trim(value)
      exit
    }
    in_mayor && /^[^[:space:]]/ { in_mayor=0 }
  ' "$config"
}

# Get a nested value from mayor config (e.g., autonomy_level.analyze_issues)
# Usage: pai_lite_config_mayor_nested_get <section> <key>
# Example: pai_lite_config_mayor_nested_get "autonomy_level" "analyze_issues"
pai_lite_config_mayor_nested_get() {
  local section="$1" key="$2"
  local config
  config="$(pai_lite_config_path)"
  [[ -f "$config" ]] || return 1

  awk -v section="$section" -v key="$key" '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    /^[[:space:]]*mayor:/ { in_mayor=1; next }
    in_mayor && $0 ~ "^[[:space:]]{2}" section ":" { in_section=1; next }
    in_mayor && in_section && $0 ~ "^[[:space:]]{4}" key ":" {
      value=$0
      sub(/^[^:]+:[[:space:]]*/, "", value)
      print trim(value)
      exit
    }
    in_mayor && in_section && /^[[:space:]]{2}[^[:space:]]/ { in_section=0 }
    in_mayor && /^[^[:space:]]/ { in_mayor=0; in_section=0 }
  ' "$config"
}

# Get mayor schedule config
# Usage: pai_lite_config_mayor_schedule <event>
# Example: pai_lite_config_mayor_schedule "briefing" -> "08:00"
pai_lite_config_mayor_schedule() {
  pai_lite_config_mayor_nested_get "schedule" "$1"
}

# Get mayor autonomy level
# Usage: pai_lite_config_mayor_autonomy <action>
# Example: pai_lite_config_mayor_autonomy "analyze_issues" -> "auto"
pai_lite_config_mayor_autonomy() {
  pai_lite_config_mayor_nested_get "autonomy_level" "$1"
}

#------------------------------------------------------------------------------
# Config Parsing: Notifications Section
#------------------------------------------------------------------------------

# Get a value from the notifications config section
# Usage: pai_lite_config_notifications_get <key>
# Example: pai_lite_config_notifications_get "provider" -> ntfy
pai_lite_config_notifications_get() {
  local key="$1"
  local config
  config="$(pai_lite_config_path)"
  [[ -f "$config" ]] || return 1

  awk -v key="$key" '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    /^[[:space:]]*notifications:/ { in_notif=1; next }
    in_notif && $0 ~ "^[[:space:]]*" key ":" && $0 !~ /^[[:space:]]{4}/ {
      value=$0
      sub(/^[^:]+:[[:space:]]*/, "", value)
      print trim(value)
      exit
    }
    in_notif && /^[^[:space:]]/ { in_notif=0 }
  ' "$config"
}

# Get a notification topic
# Usage: pai_lite_config_notifications_topic <tier>
# Example: pai_lite_config_notifications_topic "pai" -> lukstafi-pai
pai_lite_config_notifications_topic() {
  local tier="$1"
  local config
  config="$(pai_lite_config_path)"
  [[ -f "$config" ]] || return 1

  awk -v tier="$tier" '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    /^[[:space:]]*notifications:/ { in_notif=1; next }
    in_notif && /^[[:space:]]*topics:/ { in_topics=1; next }
    in_notif && in_topics && $0 ~ "^[[:space:]]*" tier ":" {
      value=$0
      sub(/^[^:]+:[[:space:]]*/, "", value)
      print trim(value)
      exit
    }
    in_notif && /^[^[:space:]]/ { in_notif=0 }
    in_topics && /^[[:space:]]{2}[^[:space:]]/ && $0 !~ /^[[:space:]]*(pai|agents|public):/ { in_topics=0 }
  ' "$config"
}

# Get a notification priority
# Usage: pai_lite_config_notifications_priority <event>
# Example: pai_lite_config_notifications_priority "briefing" -> 3
pai_lite_config_notifications_priority() {
  local event="$1"
  local config
  config="$(pai_lite_config_path)"
  [[ -f "$config" ]] || return 1

  awk -v event="$event" '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    /^[[:space:]]*notifications:/ { in_notif=1; next }
    in_notif && /^[[:space:]]*priorities:/ { in_prio=1; next }
    in_notif && in_prio && $0 ~ "^[[:space:]]*" event ":" {
      value=$0
      sub(/^[^:]+:[[:space:]]*/, "", value)
      print trim(value)
      exit
    }
    in_notif && /^[^[:space:]]/ { in_notif=0 }
    in_prio && /^[[:space:]]{2}[^[:space:]]/ && $0 !~ /^[[:space:]]*(briefing|health_check|deadline|stall|critical):/ { in_prio=0 }
  ' "$config"
}

# Check if an event type should be auto-published
# Usage: pai_lite_config_notifications_auto_publish <event>
# Returns 0 if should auto-publish, 1 otherwise
pai_lite_config_notifications_auto_publish() {
  local event="$1"
  local config
  config="$(pai_lite_config_path)"
  [[ -f "$config" ]] || return 1

  local result
  result=$(awk -v event="$event" '
    /^[[:space:]]*notifications:/ { in_notif=1; next }
    in_notif && /^[[:space:]]*public_filter:/ { in_filter=1; next }
    in_notif && in_filter && /^[[:space:]]*auto_publish:/ { in_auto=1; next }
    in_notif && in_filter && in_auto && /^[[:space:]]*-[[:space:]]*/ {
      item=$0
      sub(/^[[:space:]]*-[[:space:]]*/, "", item)
      gsub(/[[:space:]]+$/, "", item)
      if (item == event) { print "yes"; exit }
    }
    in_notif && in_filter && in_auto && /^[[:space:]]{4}[^[:space:]-]/ { in_auto=0 }
    in_notif && in_filter && /^[[:space:]]{2}[^[:space:]]/ { in_filter=0 }
    in_notif && /^[^[:space:]]/ { in_notif=0 }
  ' "$config")

  [[ "$result" == "yes" ]]
}

pai_lite_state_repo_slug() {
  pai_lite_config_get "state_repo"
}

pai_lite_state_repo_dir() {
  local slug repo_name
  slug="$(pai_lite_state_repo_slug)"
  repo_name="${slug##*/}"
  echo "$HOME/$repo_name"
}

pai_lite_state_path() {
  local path
  path="$(pai_lite_config_get "state_path")"
  [[ -n "$path" ]] || echo "harness"
  [[ -n "$path" ]] && echo "$path"
}

pai_lite_state_harness_dir() {
  local repo_dir path
  repo_dir="$(pai_lite_state_repo_dir)"
  path="$(pai_lite_state_path)"
  echo "$repo_dir/$path"
}

pai_lite_ensure_state_repo() {
  local repo_dir slug
  repo_dir="$(pai_lite_state_repo_dir)"
  slug="$(pai_lite_state_repo_slug)"

  if [[ ! -d "$repo_dir/.git" ]]; then
    pai_lite_require_cmd gh
    pai_lite_info "cloning state repo $slug into $repo_dir"
    gh repo clone "$slug" "$repo_dir" >/dev/null
  fi
}

pai_lite_ensure_state_dir() {
  local harness_dir
  harness_dir="$(pai_lite_state_harness_dir)"
  [[ -d "$harness_dir" ]] || mkdir -p "$harness_dir"
}

#------------------------------------------------------------------------------
# Mayor Queue Functions
# Queue-based communication with Claude Code Mayor session
#------------------------------------------------------------------------------

pai_lite_queue_file() {
  echo "$(pai_lite_state_harness_dir)/tasks/queue.jsonl"
}

pai_lite_results_dir() {
  echo "$(pai_lite_state_harness_dir)/tasks/results"
}

# Queue a request for the Mayor
# Usage: pai_lite_queue_request <action> [extra_json_fields]
pai_lite_queue_request() {
  local action="$1"
  local extra="${2:-}"

  local queue_file
  queue_file="$(pai_lite_queue_file)"

  # Ensure tasks directory exists
  local tasks_dir
  tasks_dir="$(dirname "$queue_file")"
  mkdir -p "$tasks_dir"

  local timestamp request_id
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  request_id="req-$(date +%s)-$$"

  # Build JSON request
  local request
  if [[ -n "$extra" ]]; then
    request=$(printf '{"id":"%s","action":"%s","timestamp":"%s",%s}' \
      "$request_id" "$action" "$timestamp" "$extra")
  else
    request=$(printf '{"id":"%s","action":"%s","timestamp":"%s"}' \
      "$request_id" "$action" "$timestamp")
  fi

  # Append to queue
  echo "$request" >> "$queue_file"

  echo "$request_id"
}

# Wait for a result file from the Mayor
# Usage: pai_lite_wait_for_result <request_id> [timeout_seconds]
pai_lite_wait_for_result() {
  local request_id="$1"
  local timeout="${2:-300}"

  local results_dir result_file
  results_dir="$(pai_lite_results_dir)"
  result_file="$results_dir/${request_id}.json"

  local elapsed=0
  local interval=2

  while [[ $elapsed -lt $timeout ]]; do
    if [[ -f "$result_file" ]]; then
      cat "$result_file"
      return 0
    fi
    sleep $interval
    elapsed=$((elapsed + interval))
  done

  pai_lite_warn "timeout waiting for result: $request_id"
  return 1
}

# Read and remove the first request from the queue (for stop hook)
# Usage: pai_lite_queue_pop
pai_lite_queue_pop() {
  local queue_file
  queue_file="$(pai_lite_queue_file)"

  [[ -f "$queue_file" ]] || return 1
  [[ -s "$queue_file" ]] || return 1

  # Read first line
  local request
  request=$(head -n 1 "$queue_file")

  # Remove it from queue (atomic via temp file)
  local tmp="${queue_file}.tmp"
  tail -n +2 "$queue_file" > "$tmp" && mv "$tmp" "$queue_file"

  echo "$request"
}

# Check if queue has pending requests
# Usage: pai_lite_queue_pending
pai_lite_queue_pending() {
  local queue_file
  queue_file="$(pai_lite_queue_file)"

  [[ -f "$queue_file" ]] && [[ -s "$queue_file" ]]
}

#------------------------------------------------------------------------------
# State Repository Commit Functions
#------------------------------------------------------------------------------

# Commit changes to the state repo
# Usage: pai_lite_state_commit <message>
pai_lite_state_commit() {
  local message="$1"
  local harness_dir
  harness_dir="$(pai_lite_state_harness_dir)"

  # Check if there are changes to commit
  if ! git -C "$harness_dir" diff --quiet HEAD 2>/dev/null; then
    git -C "$harness_dir" add -A
    git -C "$harness_dir" commit -m "$message" >/dev/null
    pai_lite_info "committed: $message"
  elif ! git -C "$harness_dir" diff --cached --quiet 2>/dev/null; then
    git -C "$harness_dir" commit -m "$message" >/dev/null
    pai_lite_info "committed: $message"
  fi
}

# Push state repo to remote
# Usage: pai_lite_state_push
pai_lite_state_push() {
  local harness_dir
  harness_dir="$(pai_lite_state_harness_dir)"

  git -C "$harness_dir" push >/dev/null 2>&1 && \
    pai_lite_info "pushed to remote" || \
    pai_lite_warn "push failed (will retry later)"
}

# Commit and push state repo
# Usage: pai_lite_state_sync <message>
pai_lite_state_sync() {
  local message="$1"
  pai_lite_state_commit "$message"
  pai_lite_state_push
}

#------------------------------------------------------------------------------
# Mayor Result Functions
#------------------------------------------------------------------------------

# Write a result file (for Mayor to call after processing)
# Usage: pai_lite_write_result <request_id> <status> [output_file]
pai_lite_write_result() {
  local request_id="$1"
  local status="$2"
  local output_file="${3:-}"

  local results_dir result_file
  results_dir="$(pai_lite_results_dir)"
  mkdir -p "$results_dir"
  result_file="$results_dir/${request_id}.json"

  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  if [[ -n "$output_file" && -f "$output_file" ]]; then
    # Include file contents in result
    local content
    content=$(cat "$output_file" | jq -Rs '.')
    printf '{"id":"%s","status":"%s","timestamp":"%s","output":%s}\n' \
      "$request_id" "$status" "$timestamp" "$content" > "$result_file"
  else
    printf '{"id":"%s","status":"%s","timestamp":"%s"}\n' \
      "$request_id" "$status" "$timestamp" > "$result_file"
  fi
}
