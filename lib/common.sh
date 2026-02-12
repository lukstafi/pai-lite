#!/usr/bin/env bash
set -euo pipefail

ludics_die() {
  echo "ludics: $*" >&2
  exit 1
}

ludics_warn() {
  echo "ludics: $*" >&2
}

ludics_info() {
  echo "ludics: $*" >&2
}

ludics_root() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  cd "$script_dir/.." && pwd
}

# Get the pointer config path (minimal config in ~/.config/ludics/)
ludics_pointer_config_path() {
  if [[ -n "${LUDICS_CONFIG:-}" ]]; then
    echo "$LUDICS_CONFIG"
  else
    echo "$HOME/.config/ludics/config.yaml"
  fi
}

# Get the full config path (in the harness directory)
# Falls back to pointer config if harness config doesn't exist
ludics_config_path() {
  local pointer_config harness_config
  pointer_config="$(ludics_pointer_config_path)"

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

ludics_require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || ludics_die "missing required command: $cmd"
}

ludics_config_get() {
  local key="$1"
  local config
  config="$(ludics_config_path)"
  [[ -f "$config" ]] || ludics_die "config not found: $config"
  local result
  result=$(yq eval ".${key}" "$config" 2>/dev/null)
  if [[ "$result" != "null" && -n "$result" ]]; then echo "$result"; fi
}

ludics_config_slots_count() {
  local config
  config="$(ludics_config_path)"
  [[ -f "$config" ]] || ludics_die "config not found: $config"
  local result
  result=$(yq eval '.slots.count' "$config" 2>/dev/null)
  if [[ "$result" != "null" && -n "$result" ]]; then echo "$result"; fi
}

# Get nested config value (e.g., "mag.ttyd_port")
# Usage: ludics_config_get_nested "section" "key"
ludics_config_get_nested() {
  local section="$1"
  local key="$2"
  local config
  config="$(ludics_config_path)"
  [[ -f "$config" ]] || return 1
  local result
  result=$(yq eval ".${section}.${key}" "$config" 2>/dev/null)
  if [[ "$result" != "null" && -n "$result" ]]; then echo "$result"; fi
}

#------------------------------------------------------------------------------
# Config Parsing: Mag Section
#------------------------------------------------------------------------------

# Get a value from the mag config section
# Usage: ludics_config_mag_get <key>
# Example: ludics_config_mag_get "enabled" -> true/false
ludics_config_mag_get() {
  local key="$1"
  local config
  config="$(ludics_config_path)"
  [[ -f "$config" ]] || return 1

  local result
  result=$(yq eval ".mag.${key}" "$config" 2>/dev/null)
  if [[ "$result" != "null" && -n "$result" ]]; then echo "$result"; fi
}

# Get a nested value from mag config (e.g., autonomy_level.analyze_issues)
# Usage: ludics_config_mag_nested_get <section> <key>
# Example: ludics_config_mag_nested_get "autonomy_level" "analyze_issues"
ludics_config_mag_nested_get() {
  local section="$1" key="$2"
  local config
  config="$(ludics_config_path)"
  [[ -f "$config" ]] || return 1

  local result
  result=$(yq eval ".mag.${section}.${key}" "$config" 2>/dev/null)
  if [[ "$result" != "null" && -n "$result" ]]; then echo "$result"; fi
}

# Get mag schedule config
# Usage: ludics_config_mag_schedule <event>
# Example: ludics_config_mag_schedule "briefing" -> "08:00"
ludics_config_mag_schedule() {
  ludics_config_mag_nested_get "schedule" "$1"
}

# Get mag autonomy level
# Usage: ludics_config_mag_autonomy <action>
# Example: ludics_config_mag_autonomy "analyze_issues" -> "auto"
ludics_config_mag_autonomy() {
  ludics_config_mag_nested_get "autonomy_level" "$1"
}

#------------------------------------------------------------------------------
# Config Parsing: Notifications Section
#------------------------------------------------------------------------------

# Get a value from the notifications config section
# Usage: ludics_config_notifications_get <key>
# Example: ludics_config_notifications_get "provider" -> ntfy
ludics_config_notifications_get() {
  local key="$1"
  local config
  config="$(ludics_config_path)"
  [[ -f "$config" ]] || return 1

  local result
  result=$(yq eval ".notifications.${key}" "$config" 2>/dev/null)
  if [[ "$result" != "null" && -n "$result" ]]; then echo "$result"; fi
}

# Get a notification topic
# Usage: ludics_config_notifications_topic <tier>
# Example: ludics_config_notifications_topic "pai" -> lukstafi-pai
ludics_config_notifications_topic() {
  local tier="$1"
  local config
  config="$(ludics_config_path)"
  [[ -f "$config" ]] || return 1

  local result
  result=$(yq eval ".notifications.topics.${tier}" "$config" 2>/dev/null)
  if [[ "$result" != "null" && -n "$result" ]]; then echo "$result"; fi
}

# Get a notification priority
# Usage: ludics_config_notifications_priority <event>
# Example: ludics_config_notifications_priority "briefing" -> 3
ludics_config_notifications_priority() {
  local event="$1"
  local config
  config="$(ludics_config_path)"
  [[ -f "$config" ]] || return 1

  local result
  result=$(yq eval ".notifications.priorities.${event}" "$config" 2>/dev/null)
  if [[ "$result" != "null" && -n "$result" ]]; then echo "$result"; fi
}

# Check if an event type should be auto-published
# Usage: ludics_config_notifications_auto_publish <event>
# Returns 0 if should auto-publish, 1 otherwise
ludics_config_notifications_auto_publish() {
  local event="$1"
  local config
  config="$(ludics_config_path)"
  [[ -f "$config" ]] || return 1

  local result
  result=$(yq eval ".notifications.public_filter.auto_publish[] | select(. == \"${event}\")" "$config" 2>/dev/null)
  [[ "$result" == "$event" ]]
}


ludics_state_repo_slug() {
  ludics_config_get "state_repo"
}

ludics_state_repo_dir() {
  local slug repo_name
  slug="$(ludics_state_repo_slug)"
  repo_name="${slug##*/}"
  echo "$HOME/$repo_name"
}

ludics_state_path() {
  local path
  path="$(ludics_config_get "state_path")"
  if [[ -n "$path" ]]; then echo "$path"; else echo "harness"; fi
}

ludics_state_harness_dir() {
  local repo_dir path
  repo_dir="$(ludics_state_repo_dir)"
  path="$(ludics_state_path)"
  echo "$repo_dir/$path"
}

ludics_ensure_state_repo() {
  local repo_dir slug
  repo_dir="$(ludics_state_repo_dir)"
  slug="$(ludics_state_repo_slug)"

  if [[ ! -d "$repo_dir/.git" ]]; then
    ludics_require_cmd gh
    ludics_info "cloning state repo $slug into $repo_dir"
    gh repo clone "$slug" "$repo_dir" >/dev/null
  fi
}

ludics_ensure_state_dir() {
  local harness_dir
  harness_dir="$(ludics_state_harness_dir)"
  [[ -d "$harness_dir" ]] || mkdir -p "$harness_dir"
}

#------------------------------------------------------------------------------
# Mag Queue Functions
# Queue-based communication with Claude Code Mag session
#------------------------------------------------------------------------------

ludics_queue_file() {
  echo "$(ludics_state_harness_dir)/mag/queue.jsonl"
}

ludics_results_dir() {
  echo "$(ludics_state_harness_dir)/mag/results"
}

# Queue a request for the Mag
# Usage: ludics_queue_request <action> [extra_json_fields]
ludics_queue_request() {
  local action="$1"
  local extra="${2:-}"

  local queue_file
  queue_file="$(ludics_queue_file)"

  # Ensure mag directory exists
  local mag_dir
  mag_dir="$(dirname "$queue_file")"
  mkdir -p "$mag_dir"

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

# Wait for a result file from the Mag
# Usage: ludics_wait_for_result <request_id> [timeout_seconds]
ludics_wait_for_result() {
  local request_id="$1"
  local timeout="${2:-300}"

  local results_dir result_file
  results_dir="$(ludics_results_dir)"
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

  ludics_warn "timeout waiting for result: $request_id"
  return 1
}

# Read and remove the first request from the queue (for stop hook)
# Usage: ludics_queue_pop
ludics_queue_pop() {
  local queue_file
  queue_file="$(ludics_queue_file)"

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
# Usage: ludics_queue_pending
ludics_queue_pending() {
  local queue_file
  queue_file="$(ludics_queue_file)"

  [[ -f "$queue_file" ]] && [[ -s "$queue_file" ]]
}

#------------------------------------------------------------------------------
# Mag Inbox Functions
# Async message channel: humans drop messages, Mag consumes them.
# inbox.md is free-form text (no required structure).
# past-messages.md is the structured archive with date-stamped sections.
#------------------------------------------------------------------------------

ludics_inbox_file() {
  echo "$(ludics_state_harness_dir)/mag/inbox.md"
}

ludics_past_messages_file() {
  echo "$(ludics_state_harness_dir)/mag/past-messages.md"
}

# Write a message to the inbox (free-form text, appended as-is)
# Usage: ludics_inbox_append <message>
ludics_inbox_append() {
  local message="$1"
  local inbox_file
  inbox_file="$(ludics_inbox_file)"

  # Ensure mag directory exists
  mkdir -p "$(dirname "$inbox_file")"

  # Append message followed by a blank line for readability
  printf '%s\n\n' "$message" >> "$inbox_file"
}

# Check if inbox has content (non-empty, non-whitespace)
# Returns 0 if there are messages, 1 if empty
ludics_inbox_has_messages() {
  local inbox_file
  inbox_file="$(ludics_inbox_file)"

  [[ -f "$inbox_file" ]] || return 1

  # Check for any non-whitespace content
  if grep -q '[^[:space:]]' "$inbox_file" 2>/dev/null; then
    return 0
  fi
  return 1
}

# Consume inbox: pull remote, print messages, archive to past-messages.md,
# clear inbox. Output goes to stdout for Mag to see.
# Usage: ludics_inbox_consume
ludics_inbox_consume() {
  local inbox_file past_file
  inbox_file="$(ludics_inbox_file)"
  past_file="$(ludics_past_messages_file)"

  # Pull latest from remote to pick up messages sent from other machines
  if ! ludics_state_pull 2>/dev/null; then
    # Check for merge conflicts
    local repo_dir
    repo_dir="$(ludics_state_repo_dir)"
    if git -C "$repo_dir" diff --name-only --diff-filter=U 2>/dev/null | grep -q .; then
      echo "ERROR: Merge conflicts detected in state repo."
      echo "Please resolve conflicts in $repo_dir and run 'ludics mag inbox' again."
      return 1
    fi
    ludics_warn "pull failed but no conflicts detected; continuing with local state"
  fi

  # Ensure directory exists
  mkdir -p "$(dirname "$inbox_file")"
  if [[ ! -f "$past_file" ]]; then
    echo "# Past Messages" > "$past_file"
  fi

  # Check for messages
  if ! ludics_inbox_has_messages; then
    echo "No pending messages."
    return 0
  fi

  # Print current inbox for Mag to see
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
  echo "To revisit past messages, read mag/past-messages.md."
}

#------------------------------------------------------------------------------
# State Repository Pull Functions
#------------------------------------------------------------------------------

# Pull latest changes from the state repo remote
# Usage: ludics_state_pull
ludics_state_pull() {
  local repo_dir
  repo_dir="$(ludics_state_repo_dir)"

  if [[ ! -d "$repo_dir/.git" ]]; then
    ludics_warn "state repo not initialized: $repo_dir"
    return 1
  fi

  # Stash any local changes first
  local has_changes=0
  if ! git -C "$repo_dir" diff --quiet HEAD 2>/dev/null; then
    has_changes=1
    git -C "$repo_dir" stash push -m "ludics auto-stash before pull" >/dev/null 2>&1 || true
  fi

  # Pull from remote
  if git -C "$repo_dir" pull --rebase >/dev/null 2>&1; then
    ludics_info "pulled latest from remote"
  else
    ludics_warn "pull failed (may need manual intervention)"
    # Restore stashed changes on failure
    if [[ $has_changes -eq 1 ]]; then
      git -C "$repo_dir" stash pop >/dev/null 2>&1 || true
    fi
    return 1
  fi

  # Restore stashed changes
  if [[ $has_changes -eq 1 ]]; then
    if git -C "$repo_dir" stash pop >/dev/null 2>&1; then
      ludics_info "restored local changes"
    else
      ludics_warn "conflict restoring local changes (check git stash)"
    fi
  fi

  return 0
}

# Full state sync: pull, then push any local changes
# Usage: ludics_state_full_sync
ludics_state_full_sync() {
  ludics_state_pull || true
  ludics_state_commit "sync"
  ludics_state_push
}

#------------------------------------------------------------------------------
# State Repository Commit Functions
#------------------------------------------------------------------------------

# Commit changes to the state repo
# Usage: ludics_state_commit <message>
ludics_state_commit() {
  local message="$1"
  local harness_dir
  harness_dir="$(ludics_state_harness_dir)"

  # Check if there are changes to commit
  if ! git -C "$harness_dir" diff --quiet HEAD 2>/dev/null; then
    git -C "$harness_dir" add -A
    git -C "$harness_dir" commit -m "$message" >/dev/null
    ludics_info "committed: $message"
  elif ! git -C "$harness_dir" diff --cached --quiet 2>/dev/null; then
    git -C "$harness_dir" commit -m "$message" >/dev/null
    ludics_info "committed: $message"
  fi
}

# Push state repo to remote
# Usage: ludics_state_push
ludics_state_push() {
  local harness_dir
  harness_dir="$(ludics_state_harness_dir)"

  if git -C "$harness_dir" push >/dev/null 2>&1; then
    ludics_info "pushed to remote"
  else
    ludics_warn "push failed (will retry later)"
  fi
}

# Commit and push state repo
# Usage: ludics_state_sync <message>
ludics_state_sync() {
  local message="$1"
  ludics_state_commit "$message"
  ludics_state_push
}

#------------------------------------------------------------------------------
# Mag Result Functions
#------------------------------------------------------------------------------

# Write a result file (for Mag to call after processing)
# Usage: ludics_write_result <request_id> <status> [output_file]
ludics_write_result() {
  local request_id="$1"
  local status="$2"
  local output_file="${3:-}"

  local results_dir result_file
  results_dir="$(ludics_results_dir)"
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

ludics_journal_dir() {
  echo "$(ludics_state_harness_dir)/journal"
}

ludics_journal_file() {
  local date_str
  date_str="$(date +%Y-%m-%d)"
  echo "$(ludics_journal_dir)/${date_str}.md"
}

# Append an entry to today's journal
# Usage: ludics_journal_append <category> <message>
# Categories: slot, task, flow, mag, system
ludics_journal_append() {
  local category="$1"
  local message="$2"

  local journal_dir journal_file timestamp
  journal_dir="$(ludics_journal_dir)"
  journal_file="$(ludics_journal_file)"
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
  printf -- "- **%s** [%s] %s\n" "$timestamp" "$category" "$message" >> "$journal_file"
}

# Read recent journal entries
# Usage: ludics_journal_recent [count] [category]
ludics_journal_recent() {
  local count="${1:-20}"
  local category="${2:-}"

  local journal_file
  journal_file="$(ludics_journal_file)"

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
# Usage: ludics_journal_list [days]
ludics_journal_list() {
  local days="${1:-7}"
  local journal_dir
  journal_dir="$(ludics_journal_dir)"

  if [[ ! -d "$journal_dir" ]]; then
    echo "No journal directory"
    return
  fi

  find "$journal_dir" -name "*.md" -type f -mtime -"$days" | sort -r
}

#------------------------------------------------------------------------------
# Source network helpers if available
#------------------------------------------------------------------------------

_ludics_network_sh="$(dirname "${BASH_SOURCE[0]}")/network.sh"
if [[ -f "$_ludics_network_sh" ]]; then
  # shellcheck source=lib/network.sh
  source "$_ludics_network_sh"
fi
unset _ludics_network_sh
