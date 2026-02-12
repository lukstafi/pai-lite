#!/usr/bin/env bash
set -euo pipefail

# Flow engine for ludics
# Provides flow-based views: ready, blocked, critical, impact, context

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$script_dir/common.sh"

# Get the tasks directory (contains individual task-*.md files)
flow_tasks_dir() {
  echo "$(ludics_state_harness_dir)/tasks"
}

# Check required commands
flow_require_tools() {
  ludics_require_cmd yq
  ludics_require_cmd jq
}

# Collect all task frontmatter as JSON array
# Parses YAML frontmatter from task-*.md files
flow_collect_tasks() {
  local tasks_dir
  tasks_dir="$(flow_tasks_dir)"

  if [[ ! -d "$tasks_dir" ]]; then
    echo "[]"
    return
  fi

  local tasks="[]"
  for file in "$tasks_dir"/*.md; do
    [[ -f "$file" ]] || continue
    # Extract YAML frontmatter (between --- markers)
    local frontmatter
    frontmatter=$(awk '/^---$/ { if (++count == 2) exit } count == 1 && !/^---$/' "$file")
    if [[ -n "$frontmatter" ]]; then
      local task_json
      task_json=$(echo "$frontmatter" | yq -o=json '.' 2>/dev/null || echo "{}")
      # Add source file
      task_json=$(echo "$task_json" | jq --arg file "$file" '. + {_file: $file}')
      tasks=$(echo "$tasks" | jq --argjson task "$task_json" '. + [$task]')
    fi
  done

  echo "$tasks"
}

# Check for dependency cycles using tsort
flow_check_cycle() {
  local tasks_json="$1"

  # Build dependency pairs for tsort
  local pairs
  pairs=$(echo "$tasks_json" | jq -r '
    .[] |
    select(.dependencies.blocked_by != null) |
    .id as $id |
    .dependencies.blocked_by[] |
    "\(.) \($id)"
  ' 2>/dev/null)

  if [[ -z "$pairs" ]]; then
    return 0
  fi

  # tsort exits non-zero if cycle detected
  if ! echo "$pairs" | tsort >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

# Priority sort order: A=1, B=2, C=3
priority_value() {
  local p="$1"
  case "$p" in
    A) echo 1 ;;
    B) echo 2 ;;
    C) echo 3 ;;
    *) echo 9 ;;
  esac
}

# Show ready tasks: status=ready AND blocked_by is empty
# Sorted by: priority, then deadline (if present)
flow_ready() {
  flow_require_tools
  local tasks_json
  tasks_json="$(flow_collect_tasks)"

  # Check for cycles first
  if ! flow_check_cycle "$tasks_json"; then
    ludics_warn "dependency cycle detected in tasks"
  fi

  local today
  today=$(date +%Y-%m-%d)

  # Filter ready tasks and sort
  local result
  result=$(echo "$tasks_json" | jq -r --arg today "$today" '
    # Filter: status=ready AND blocked_by is null or empty
    [.[] | select(
      .status == "ready" and
      ((.dependencies.blocked_by | length) == 0 or .dependencies.blocked_by == null)
    )]
    # Add priority sort value
    | map(. + {
        _priority_val: (if .priority == "A" then 1 elif .priority == "B" then 2 elif .priority == "C" then 3 else 9 end),
        _has_deadline: (if .deadline then 1 else 2 end)
      })
    # Sort by priority, then by deadline presence, then by deadline date
    | sort_by([._priority_val, ._has_deadline, .deadline // "9999-99-99"])
    # Format output
    | .[] | "\(.id) (\(.priority // "-")) \(.title)"
  ')

  if [[ -z "$result" ]]; then
    echo "No ready tasks"
  else
    echo "$result"
  fi
}

# Show blocked tasks and what's blocking them
flow_blocked() {
  flow_require_tools
  local tasks_json
  tasks_json="$(flow_collect_tasks)"

  local result
  result=$(echo "$tasks_json" | jq -r '
    # Filter: has non-empty blocked_by
    [.[] | select(
      .dependencies.blocked_by != null and
      (.dependencies.blocked_by | length) > 0
    )]
    | sort_by(.priority // "Z")
    | .[] | "\(.id) blocked by: \(.dependencies.blocked_by | join(", "))"
  ')

  if [[ -z "$result" ]]; then
    echo "No blocked tasks"
  else
    echo "$result"
  fi
}

# Show critical tasks: approaching deadlines, stalled work, high-priority ready
flow_critical() {
  flow_require_tools
  local tasks_json
  tasks_json="$(flow_collect_tasks)"

  local today today_epoch
  today=$(date +%Y-%m-%d)
  today_epoch=$(date +%s)

  echo "=== Approaching Deadlines (within 30 days) ==="
  echo "$tasks_json" | jq -r --arg today "$today" --argjson today_epoch "$today_epoch" '
    [.[] | select(
      .deadline != null and
      .status != "done" and
      .status != "abandoned" and
      .status != "merged"
    )]
    | map(. + {
        _deadline_epoch: (.deadline | strptime("%Y-%m-%d") | mktime),
        _days_left: (((.deadline | strptime("%Y-%m-%d") | mktime) - $today_epoch) / 86400 | floor)
      })
    | [.[] | select(._days_left >= 0 and ._days_left <= 30)]
    | sort_by(._days_left)
    | .[] | "\(.id) - \(._days_left) days - \(.title)"
  ' 2>/dev/null || echo "(none)"

  echo ""
  echo "=== Stalled Work (in-progress > 7 days) ==="
  local stall_threshold=$((7 * 86400))
  echo "$tasks_json" | jq -r --argjson today_epoch "$today_epoch" --argjson threshold "$stall_threshold" '
    [.[] | select(
      .status == "in-progress" and
      .started != null
    )]
    | map(. + {
        _started_epoch: (.started | strptime("%Y-%m-%d") | mktime // 0),
        _days_stalled: (($today_epoch - ((.started | strptime("%Y-%m-%d") | mktime) // $today_epoch)) / 86400 | floor)
      })
    | [.[] | select(._days_stalled > 7)]
    | sort_by(-._days_stalled)
    | .[] | "\(.id) - stalled \(._days_stalled) days - \(.title)"
  ' 2>/dev/null || echo "(none)"

  echo ""
  echo "=== High-Priority Ready (priority A) ==="
  echo "$tasks_json" | jq -r '
    [.[] | select(
      .status == "ready" and
      .priority == "A" and
      ((.dependencies.blocked_by | length) == 0 or .dependencies.blocked_by == null)
    )]
    | .[] | "\(.id) - \(.title)"
  ' 2>/dev/null || echo "(none)"
}

# Show what tasks would unblock if given task completes
flow_impact() {
  local task_id="$1"
  [[ -n "$task_id" ]] || ludics_die "task id required"

  flow_require_tools
  local tasks_json
  tasks_json="$(flow_collect_tasks)"

  # Find tasks that have this task in their blocked_by
  local direct_unblocks
  direct_unblocks=$(echo "$tasks_json" | jq -r --arg id "$task_id" '
    [.[] | select(
      .dependencies.blocked_by != null and
      (.dependencies.blocked_by | index($id) != null)
    )]
  ')

  echo "=== Direct Unblocks (immediately ready if $task_id completes) ==="
  echo "$direct_unblocks" | jq -r '
    [.[] | select((.dependencies.blocked_by | length) == 1)]
    | .[] | "\(.id) - \(.title)"
  ' 2>/dev/null

  if [[ $(echo "$direct_unblocks" | jq 'length') -eq 0 ]]; then
    echo "(none)"
  fi

  echo ""
  echo "=== Partial Unblocks (still has other blockers) ==="
  echo "$direct_unblocks" | jq -r --arg id "$task_id" '
    [.[] | select((.dependencies.blocked_by | length) > 1)]
    | .[] | "\(.id) - still blocked by: \(.dependencies.blocked_by | map(select(. != $id)) | join(", "))"
  ' 2>/dev/null

  local partial_count
  partial_count=$(echo "$direct_unblocks" | jq '[.[] | select((.dependencies.blocked_by | length) > 1)] | length')
  if [[ "$partial_count" -eq 0 ]]; then
    echo "(none)"
  fi
}

# Show context distribution across active slots
flow_context() {
  flow_require_tools

  local slots_file
  slots_file="$(ludics_state_harness_dir)/slots.md"

  if [[ ! -f "$slots_file" ]]; then
    ludics_die "slots file not found: $slots_file"
  fi

  local tasks_json
  tasks_json="$(flow_collect_tasks)"

  echo "=== Context Distribution ==="

  # Extract active tasks from slots (those with Process: not empty)
  # Parse slots.md to find task assignments
  local active_contexts
  active_contexts=$(awk '
    /^## Slot [0-9]/ { slot=$3 }
    /^\*\*Task:\*\*/ {
      task=$0
      sub(/.*Task:\*\*[[:space:]]*/, "", task)
      if (task != "" && task != "(empty)") {
        tasks[slot]=task
      }
    }
    END {
      for (s in tasks) {
        print tasks[s]
      }
    }
  ' "$slots_file")

  if [[ -z "$active_contexts" ]]; then
    echo "No active slots"
    return
  fi

  # For each active task, show its context
  while IFS= read -r task_id; do
    [[ -n "$task_id" ]] || continue
    local context
    context=$(echo "$tasks_json" | jq -r --arg id "$task_id" '
      .[] | select(.id == $id) | .context // "untagged"
    ')
    echo "  $task_id: $context"
  done <<< "$active_contexts"

  echo ""
  echo "=== Context Summary ==="
  # Count contexts in active slots
  echo "$active_contexts" | while read -r task_id; do
    [[ -n "$task_id" ]] || continue
    echo "$tasks_json" | jq -r --arg id "$task_id" '
      .[] | select(.id == $id) | .context // "untagged"
    '
  done | sort | uniq -c | sort -rn | while read -r count ctx; do
    echo "  $ctx: $count slot(s)"
  done
}

# Main dispatch
flow_main() {
  local cmd="${1:-}"
  shift || true

  case "$cmd" in
    ready)
      flow_ready
      ;;
    blocked)
      flow_blocked
      ;;
    critical)
      flow_critical
      ;;
    impact)
      flow_impact "${1:-}"
      ;;
    context)
      flow_context
      ;;
    check-cycle)
      flow_require_tools
      local tasks_json
      tasks_json="$(flow_collect_tasks)"
      if flow_check_cycle "$tasks_json"; then
        echo "No dependency cycles detected"
      else
        echo "Dependency cycle detected!"
        exit 1
      fi
      ;;
    *)
      ludics_die "unknown flow command: $cmd (use: ready, blocked, critical, impact, context, check-cycle)"
      ;;
  esac
}
