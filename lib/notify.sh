#!/usr/bin/env bash
set -euo pipefail

# Notification system for ludics
# Three-tier ntfy.sh integration: pai (strategic), agents (operational), public (broadcasts)

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$script_dir/common.sh"

# Get notification config
notify_get_provider() {
  ludics_config_get "provider" 2>/dev/null || echo "ntfy"
}

notify_get_topic() {
  local tier="$1"
  local config
  config="$(ludics_config_path)"
  [[ -f "$config" ]] || ludics_die "config not found: $config"

  awk -v tier="$tier" '
    /^[[:space:]]*notifications:/ { in_notif=1; next }
    in_notif && /^[[:space:]]*topics:/ { in_topics=1; next }
    in_notif && in_topics && $0 ~ "^[[:space:]]*" tier ":" {
      sub(/^[^:]+:[[:space:]]*/, "", $0)
      gsub(/[[:space:]]+$/, "", $0)
      print $0
      exit
    }
    in_notif && /^[^[:space:]]/ { in_notif=0 }
    in_topics && /^[[:space:]]{4}[^[:space:]]/ && $0 !~ /^[[:space:]]*(pai|agents|public):/ { in_topics=0 }
  ' "$config"
}

notify_get_priority() {
  local event="$1"
  local config
  config="$(ludics_config_path)"
  [[ -f "$config" ]] || return

  awk -v event="$event" '
    /^[[:space:]]*notifications:/ { in_notif=1; next }
    in_notif && /^[[:space:]]*priorities:/ { in_prio=1; next }
    in_notif && in_prio && $0 ~ "^[[:space:]]*" event ":" {
      sub(/^[^:]+:[[:space:]]*/, "", $0)
      gsub(/[[:space:]]+$/, "", $0)
      print $0
      exit
    }
    in_notif && /^[^[:space:]]/ { in_notif=0 }
    in_prio && /^[[:space:]]{4}[^[:space:]]/ && $0 !~ /^[[:space:]]*(briefing|health_check|deadline|stall|critical):/ { in_prio=0 }
  ' "$config"
}

# Journal directory for local logging
notify_journal_dir() {
  echo "$(ludics_state_harness_dir)/journal"
}

# Log notification locally (for dashboard history)
notify_log() {
  local tier="$1"
  local message="$2"
  local priority="${3:-3}"
  local title="${4:-}"

  local journal_dir
  journal_dir="$(notify_journal_dir)"
  mkdir -p "$journal_dir"

  local log_file="$journal_dir/notifications.jsonl"
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Append JSON line
  printf '{"timestamp":"%s","tier":"%s","priority":%s,"title":"%s","message":"%s"}\n' \
    "$timestamp" "$tier" "$priority" "${title//\"/\\\"}" "${message//\"/\\\"}" >> "$log_file"
}

# Core send function via ntfy.sh
# Usage: notify_send <topic> <message> [priority] [title] [tags]
notify_send() {
  local topic="$1"
  local message="$2"
  local priority="${3:-3}"
  local title="${4:-}"
  local tags="${5:-}"

  [[ -n "$topic" ]] || ludics_die "notify_send: topic required"
  [[ -n "$message" ]] || ludics_die "notify_send: message required"

  # Build curl args
  local curl_args=()
  curl_args+=(-s -o /dev/null -w "%{http_code}")
  curl_args+=(-d "$message")

  if [[ -n "$title" ]]; then
    curl_args+=(-H "Title: $title")
  fi

  if [[ -n "$priority" ]]; then
    curl_args+=(-H "Priority: $priority")
  fi

  if [[ -n "$tags" ]]; then
    curl_args+=(-H "Tags: $tags")
  fi

  local url="https://ntfy.sh/$topic"

  # Try to send; log locally regardless
  local http_code
  http_code=$(curl "${curl_args[@]}" "$url" 2>/dev/null) || http_code="000"

  if [[ "$http_code" != "200" ]]; then
    ludics_warn "ntfy.sh notification failed (HTTP $http_code), logged locally"
  fi

  return 0
}

# Private strategic notifications (Mag)
# Usage: notify_pai <message> [priority] [title]
notify_pai() {
  local message="$1"
  local priority="${2:-3}"
  local title="${3:-ludics}"

  local topic
  topic="$(notify_get_topic "pai")"

  if [[ -z "$topic" ]]; then
    ludics_warn "pai topic not configured, logging locally only"
    notify_log "pai" "$message" "$priority" "$title"
    return 0
  fi

  notify_log "pai" "$message" "$priority" "$title"
  notify_send "$topic" "$message" "$priority" "$title" "robot_face"
}

# Private operational notifications (workers/agents)
# Usage: notify_agents <message> [priority] [title]
notify_agents() {
  local message="$1"
  local priority="${2:-3}"
  local title="${3:-agent update}"

  local topic
  topic="$(notify_get_topic "agents")"

  if [[ -z "$topic" ]]; then
    ludics_warn "agents topic not configured, logging locally only"
    notify_log "agents" "$message" "$priority" "$title"
    return 0
  fi

  notify_log "agents" "$message" "$priority" "$title"
  notify_send "$topic" "$message" "$priority" "$title" "gear"
}

# Public read-only broadcasts
# Usage: notify_public <message> [priority] [title]
notify_public() {
  local message="$1"
  local priority="${2:-3}"
  local title="${3:-announcement}"

  local topic
  topic="$(notify_get_topic "public")"

  if [[ -z "$topic" ]]; then
    ludics_warn "public topic not configured, logging locally only"
    notify_log "public" "$message" "$priority" "$title"
    return 0
  fi

  notify_log "public" "$message" "$priority" "$title"
  notify_send "$topic" "$message" "$priority" "$title" "mega,tada"
}

# Slot-specific agent notification
# Usage: notify_slot <slot_num> <message> [priority]
notify_slot() {
  local slot_num="$1"
  local message="$2"
  local priority="${3:-3}"

  notify_agents "Slot $slot_num: $message" "$priority" "Slot $slot_num"
}

# Show recent notifications from journal
notify_recent() {
  local count="${1:-10}"
  local journal_dir
  journal_dir="$(notify_journal_dir)"
  local log_file="$journal_dir/notifications.jsonl"

  if [[ ! -f "$log_file" ]]; then
    echo "No notifications yet"
    return
  fi

  tail -n "$count" "$log_file" | jq -r '
    "\(.timestamp) [\(.tier)] \(.title): \(.message)"
  ' 2>/dev/null || tail -n "$count" "$log_file"
}
