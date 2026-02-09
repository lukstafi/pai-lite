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
  state_repo=$(yq eval '.state_repo' "$pointer_config" 2>/dev/null)
  [[ "$state_repo" == "null" ]] && state_repo=""
  state_path=$(yq eval '.state_path' "$pointer_config" 2>/dev/null)
  [[ "$state_path" == "null" ]] && state_path=""

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
  local result
  result=$(yq eval ".${key}" "$config" 2>/dev/null)
  if [[ "$result" != "null" && -n "$result" ]]; then echo "$result"; fi
}

pai_lite_config_slots_count() {
  local config
  config="$(pai_lite_config_path)"
  [[ -f "$config" ]] || pai_lite_die "config not found: $config"
  local result
  result=$(yq eval '.slots.count' "$config" 2>/dev/null)
  if [[ "$result" != "null" && -n "$result" ]]; then echo "$result"; fi
}

# Get nested config value (e.g., "mayor.ttyd_port")
# Usage: pai_lite_config_get_nested "section" "key"
pai_lite_config_get_nested() {
  local section="$1"
  local key="$2"
  local config
  config="$(pai_lite_config_path)"
  [[ -f "$config" ]] || return 1
  local result
  result=$(yq eval ".${section}.${key}" "$config" 2>/dev/null)
  if [[ "$result" != "null" && -n "$result" ]]; then echo "$result"; fi
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

  local result
  result=$(yq eval ".mayor.${key}" "$config" 2>/dev/null)
  if [[ "$result" != "null" && -n "$result" ]]; then echo "$result"; fi
}

# Get a nested value from mayor config (e.g., autonomy_level.analyze_issues)
# Usage: pai_lite_config_mayor_nested_get <section> <key>
# Example: pai_lite_config_mayor_nested_get "autonomy_level" "analyze_issues"
pai_lite_config_mayor_nested_get() {
  local section="$1" key="$2"
  local config
  config="$(pai_lite_config_path)"
  [[ -f "$config" ]] || return 1

  local result
  result=$(yq eval ".mayor.${section}.${key}" "$config" 2>/dev/null)
  if [[ "$result" != "null" && -n "$result" ]]; then echo "$result"; fi
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

  local result
  result=$(yq eval ".notifications.${key}" "$config" 2>/dev/null)
  if [[ "$result" != "null" && -n "$result" ]]; then echo "$result"; fi
}

# Get a notification topic
# Usage: pai_lite_config_notifications_topic <tier>
# Example: pai_lite_config_notifications_topic "pai" -> lukstafi-pai
pai_lite_config_notifications_topic() {
  local tier="$1"
  local config
  config="$(pai_lite_config_path)"
  [[ -f "$config" ]] || return 1

  local result
  result=$(yq eval ".notifications.topics.${tier}" "$config" 2>/dev/null)
  if [[ "$result" != "null" && -n "$result" ]]; then echo "$result"; fi
}

# Get a notification priority
# Usage: pai_lite_config_notifications_priority <event>
# Example: pai_lite_config_notifications_priority "briefing" -> 3
pai_lite_config_notifications_priority() {
  local event="$1"
  local config
  config="$(pai_lite_config_path)"
  [[ -f "$config" ]] || return 1

  local result
  result=$(yq eval ".notifications.priorities.${event}" "$config" 2>/dev/null)
  if [[ "$result" != "null" && -n "$result" ]]; then echo "$result"; fi
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
  result=$(yq eval ".notifications.public_filter.auto_publish[] | select(. == \"${event}\")" "$config" 2>/dev/null)
  [[ "$result" == "$event" ]]
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
  if [[ -n "$path" ]]; then echo "$path"; else echo "harness"; fi
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
  echo "$(pai_lite_state_harness_dir)/mayor/queue.jsonl"
}

pai_lite_results_dir() {
  echo "$(pai_lite_state_harness_dir)/mayor/results"
}

# Queue a request for the Mayor
# Usage: pai_lite_queue_request <action> [extra_json_fields]
pai_lite_queue_request() {
  local action="$1"
  local extra="${2:-}"

  local queue_file
  queue_file="$(pai_lite_queue_file)"

  # Ensure mayor directory exists
  local mayor_dir
  mayor_dir="$(dirname "$queue_file")"
  mkdir -p "$mayor_dir"

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
# Mayor Inbox Functions
# Async message channel: humans drop messages, Mayor consumes them.
# inbox.md is free-form text (no required structure).
# past-messages.md is the structured archive with date-stamped sections.
#------------------------------------------------------------------------------

pai_lite_inbox_file() {
  echo "$(pai_lite_state_harness_dir)/mayor/inbox.md"
}

pai_lite_past_messages_file() {
  echo "$(pai_lite_state_harness_dir)/mayor/past-messages.md"
}

# Write a message to the inbox (free-form text, appended as-is)
# Usage: pai_lite_inbox_append <message>
pai_lite_inbox_append() {
  local message="$1"
  local inbox_file
  inbox_file="$(pai_lite_inbox_file)"

  # Ensure mayor directory exists
  mkdir -p "$(dirname "$inbox_file")"

  # Append message followed by a blank line for readability
  printf '%s\n\n' "$message" >> "$inbox_file"
}

# Check if inbox has content (non-empty, non-whitespace)
# Returns 0 if there are messages, 1 if empty
pai_lite_inbox_has_messages() {
  local inbox_file
  inbox_file="$(pai_lite_inbox_file)"

  [[ -f "$inbox_file" ]] || return 1

  # Check for any non-whitespace content
  if grep -q '[^[:space:]]' "$inbox_file" 2>/dev/null; then
    return 0
  fi
  return 1
}

# Consume inbox: pull remote, print messages, archive to past-messages.md,
# clear inbox. Output goes to stdout for Mayor to see.
# Usage: pai_lite_inbox_consume
pai_lite_inbox_consume() {
  local inbox_file past_file
  inbox_file="$(pai_lite_inbox_file)"
  past_file="$(pai_lite_past_messages_file)"

  # Pull latest from remote to pick up messages sent from other machines
  if ! pai_lite_state_pull 2>/dev/null; then
    # Check for merge conflicts
    local repo_dir
    repo_dir="$(pai_lite_state_repo_dir)"
    if git -C "$repo_dir" diff --name-only --diff-filter=U 2>/dev/null | grep -q .; then
      echo "ERROR: Merge conflicts detected in state repo."
      echo "Please resolve conflicts in $repo_dir and run 'pai-lite mayor inbox' again."
      return 1
    fi
    pai_lite_warn "pull failed but no conflicts detected; continuing with local state"
  fi

  # Ensure directory exists
  mkdir -p "$(dirname "$inbox_file")"
  if [[ ! -f "$past_file" ]]; then
    echo "# Past Messages" > "$past_file"
  fi

  # Check for messages
  if ! pai_lite_inbox_has_messages; then
    echo "No pending messages."
    return 0
  fi

  # Print current inbox for Mayor to see
  echo "=== Pending Messages ==="
  cat "$inbox_file"
  echo ""

  # Compute the line number where this message will start in past-messages
  local past_lines
  past_lines=$(wc -l < "$past_file" | tr -d ' ')
  # The new content starts after current lines + 1 (blank line) + 1 (header)
  local start_line=$((past_lines + 3))

  # Archive: append inbox contents to past-messages with timestamp header
  local archive_timestamp
  archive_timestamp="$(date +"%Y-%m-%d %H:%M")"
  {
    echo ""
    echo "## Message consumed $archive_timestamp"
    echo ""
    cat "$inbox_file"
  } >> "$past_file"

  # Clear inbox
  : > "$inbox_file"

  echo "The current message starts at past-messages.md line $start_line."
  echo "To revisit past messages, read mayor/past-messages.md."
}

#------------------------------------------------------------------------------
# State Repository Pull Functions
#------------------------------------------------------------------------------

# Pull latest changes from the state repo remote
# Usage: pai_lite_state_pull
pai_lite_state_pull() {
  local repo_dir
  repo_dir="$(pai_lite_state_repo_dir)"

  if [[ ! -d "$repo_dir/.git" ]]; then
    pai_lite_warn "state repo not initialized: $repo_dir"
    return 1
  fi

  # Stash any local changes first
  local has_changes=0
  if ! git -C "$repo_dir" diff --quiet HEAD 2>/dev/null; then
    has_changes=1
    git -C "$repo_dir" stash push -m "pai-lite auto-stash before pull" >/dev/null 2>&1 || true
  fi

  # Pull from remote
  if git -C "$repo_dir" pull --rebase >/dev/null 2>&1; then
    pai_lite_info "pulled latest from remote"
  else
    pai_lite_warn "pull failed (may need manual intervention)"
    # Restore stashed changes on failure
    if [[ $has_changes -eq 1 ]]; then
      git -C "$repo_dir" stash pop >/dev/null 2>&1 || true
    fi
    return 1
  fi

  # Restore stashed changes
  if [[ $has_changes -eq 1 ]]; then
    if git -C "$repo_dir" stash pop >/dev/null 2>&1; then
      pai_lite_info "restored local changes"
    else
      pai_lite_warn "conflict restoring local changes (check git stash)"
    fi
  fi

  return 0
}

# Full state sync: pull, then push any local changes
# Usage: pai_lite_state_full_sync
pai_lite_state_full_sync() {
  pai_lite_state_pull || true
  pai_lite_state_commit "sync"
  pai_lite_state_push
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

  if git -C "$harness_dir" push >/dev/null 2>&1; then
    pai_lite_info "pushed to remote"
  else
    pai_lite_warn "push failed (will retry later)"
  fi
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

#------------------------------------------------------------------------------
# Journal Functions
# Append events to journal/YYYY-MM-DD.md for audit trail
#------------------------------------------------------------------------------

pai_lite_journal_dir() {
  echo "$(pai_lite_state_harness_dir)/journal"
}

pai_lite_journal_file() {
  local date_str
  date_str="$(date +%Y-%m-%d)"
  echo "$(pai_lite_journal_dir)/${date_str}.md"
}

# Append an entry to today's journal
# Usage: pai_lite_journal_append <category> <message>
# Categories: slot, task, flow, mayor, system
pai_lite_journal_append() {
  local category="$1"
  local message="$2"

  local journal_dir journal_file timestamp
  journal_dir="$(pai_lite_journal_dir)"
  journal_file="$(pai_lite_journal_file)"
  timestamp="$(date +"%H:%M:%S")"

  # Ensure journal directory exists
  mkdir -p "$journal_dir"

  # Create journal file with header if it doesn't exist
  if [[ ! -f "$journal_file" ]]; then
    {
      echo "# Journal $(date +%Y-%m-%d)"
      echo ""
    } > "$journal_file"
  fi

  # Append the entry
  printf "- **%s** [%s] %s\n" "$timestamp" "$category" "$message" >> "$journal_file"
}

# Read recent journal entries
# Usage: pai_lite_journal_recent [count] [category]
pai_lite_journal_recent() {
  local count="${1:-20}"
  local category="${2:-}"

  local journal_file
  journal_file="$(pai_lite_journal_file)"

  if [[ ! -f "$journal_file" ]]; then
    echo "No journal entries for today"
    return
  fi

  if [[ -n "$category" ]]; then
    grep "\\[$category\\]" "$journal_file" | tail -n "$count"
  else
    grep "^- \\*\\*" "$journal_file" | tail -n "$count"
  fi
}

# List journal files
# Usage: pai_lite_journal_list [days]
pai_lite_journal_list() {
  local days="${1:-7}"
  local journal_dir
  journal_dir="$(pai_lite_journal_dir)"

  if [[ ! -d "$journal_dir" ]]; then
    echo "No journal directory"
    return
  fi

  find "$journal_dir" -name "*.md" -type f -mtime -"$days" | sort -r
}

#------------------------------------------------------------------------------
# Source network helpers if available
#------------------------------------------------------------------------------

_pai_lite_network_sh="$(dirname "${BASH_SOURCE[0]}")/network.sh"
if [[ -f "$_pai_lite_network_sh" ]]; then
  # shellcheck source=lib/network.sh
  source "$_pai_lite_network_sh"
fi
unset _pai_lite_network_sh
