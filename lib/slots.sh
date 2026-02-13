#!/usr/bin/env bash
set -euo pipefail

# Slot management for ludics

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$script_dir/common.sh"

declare -gA LUDICS_SLOTS

slots_file_path() {
  ludics_ensure_state_repo
  ludics_ensure_state_dir
  echo "$(ludics_state_harness_dir)/slots.md"
}

slots_empty_block() {
  local slot="$1"
  cat <<BLOCK
## Slot $slot

**Process:** (empty)
**Task:** null
**Mode:** null
**Session:** null
**Path:** null
**Started:** null

**Terminals:**

**Runtime:**

**Git:**
BLOCK
}

slots_ensure_file() {
  local file count
  file="$(slots_file_path)"
  if [[ ! -f "$file" ]]; then
    count="$(ludics_config_slots_count)"
    [[ -n "$count" ]] || count=6
    LUDICS_SLOTS=()
    slots_write_file "$count"
  fi
}

slots_load_blocks() {
  local file line slot=0 block=""
  file="$1"
  declare -gA LUDICS_SLOTS
  LUDICS_SLOTS=()

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^##[[:space:]]+Slot[[:space:]]+([0-9]+) ]]; then
      if [[ $slot -ne 0 ]]; then
        LUDICS_SLOTS["$slot"]="$block"
      fi
      slot="${BASH_REMATCH[1]}"
      block="$line"$'\n'
      continue
    fi
    if [[ "$line" == "---" ]]; then
      continue
    fi
    if [[ "$line" == "# Slots" ]]; then
      continue
    fi
    block+="$line"$'\n'
  done < "$file"

  if [[ $slot -ne 0 ]]; then
    LUDICS_SLOTS["$slot"]="$block"
  fi
}

slots_write_file() {
  local count="$1"
  local file i
  file="$(slots_file_path)"

  {
    echo "# Slots"
    echo ""
    for ((i=1; i<=count; i++)); do
      if [[ -n "${LUDICS_SLOTS[$i]:-}" ]]; then
        printf "%s" "${LUDICS_SLOTS[$i]}"
      else
        slots_empty_block "$i"
      fi
      if [[ "$i" -lt "$count" ]]; then
        echo ""
        echo "---"
        echo ""
      fi
    done
  } > "$file"
}

slots_count() {
  local count
  count="$(ludics_config_slots_count)"
  [[ -n "$count" ]] || count=6
  echo "$count"
}

slot_validate_range() {
  local slot="$1"
  local count="$2"
  [[ "$slot" =~ ^[0-9]+$ ]] || ludics_die "slot must be a number: $slot"
  if (( slot < 1 || slot > count )); then
    ludics_die "slot out of range: $slot (1-$count)"
  fi
}

slots_list() {
  local file
  file="$(slots_file_path)"
  slots_ensure_file
  awk '
    /^## Slot / { slot=$3 }
    /^\*\*Process:\*\*/ {
      process=$0
      sub(/^\*\*Process:\*\*[[:space:]]*/, "", process)
      printf "Slot %s: %s\n", slot, process
    }
  ' "$file"
}

slot_show() {
  local slot="$1" file
  file="$(slots_file_path)"
  slot_validate_range "$slot" "$(slots_count)"
  slots_ensure_file
  awk -v target="$slot" '
    /^## Slot / {
      current=$3
      if (current == target) { in_block=1 } else if (in_block) { exit }
    }
    in_block { print }
  ' "$file"
}

#------------------------------------------------------------------------------
# Parse slot block to extract field values
#------------------------------------------------------------------------------

slot_get_field() {
  local block="$1"
  local field="$2"
  printf "%s" "$block" | awk -v marker="**${field}:**" '
    {
      i = index($0, marker)
      if (i > 0) {
        val = substr($0, i + length(marker))
        gsub(/^[[:space:]]+/, "", val)
        print val
        exit
      }
    }
  '
}

slot_get_task() {
  local block="$1"
  slot_get_field "$block" "Task"
}

slot_get_mode() {
  local block="$1"
  slot_get_field "$block" "Mode"
}

slot_get_session() {
  local block="$1"
  slot_get_field "$block" "Session"
}

slot_get_path() {
  local block="$1"
  slot_get_field "$block" "Path"
}

slot_get_process() {
  local block="$1"
  slot_get_field "$block" "Process"
}

#------------------------------------------------------------------------------
# Task file update helpers
#------------------------------------------------------------------------------

task_file_path() {
  local task_id="$1"
  local tasks_dir
  tasks_dir="$(ludics_state_harness_dir)/tasks"
  echo "$tasks_dir/${task_id}.md"
}

task_file_exists() {
  local task_id="$1"
  local file
  file="$(task_file_path "$task_id")"
  [[ -f "$file" ]]
}

task_update_frontmatter() {
  local task_id="$1"
  local field="$2"
  local value="$3"
  local file
  file="$(task_file_path "$task_id")"

  [[ -f "$file" ]] || return 1

  local tmp="${file}.tmp"

  awk -v field="$field" -v value="$value" '
    BEGIN { in_frontmatter=0; done=0 }
    /^---$/ && !in_frontmatter { in_frontmatter=1; print; next }
    /^---$/ && in_frontmatter { in_frontmatter=0; print; next }
    in_frontmatter && !done && $0 ~ "^" field ":" {
      print field ": " value
      done=1
      next
    }
    { print }
  ' "$file" > "$tmp" && mv "$tmp" "$file"
}

# Add a new field to task frontmatter (inserts before closing ---)
# Use this for fields that don't exist in the template (e.g. merged_into)
task_add_frontmatter() {
  local task_id="$1" field="$2" value="$3"
  local file
  file="$(task_file_path "$task_id")"
  [[ -f "$file" ]] || return 1

  # If field already exists, update it instead
  if grep -q "^${field}:" "$file"; then
    task_update_frontmatter "$task_id" "$field" "$value"
    return
  fi

  local tmp="${file}.tmp"
  awk -v field="$field" -v value="$value" '
    BEGIN { count=0 }
    /^---$/ { count++ }
    count == 2 && /^---$/ { print field ": " value }
    { print }
  ' "$file" > "$tmp" && mv "$tmp" "$file"
}

task_update_for_slot_assign() {
  local task_id="$1"
  local slot="$2"
  local adapter="$3"
  local started="$4"

  if ! task_file_exists "$task_id"; then
    ludics_warn "task file not found: $task_id (skipping task update)"
    return 0
  fi

  task_update_frontmatter "$task_id" "status" "in-progress"
  task_update_frontmatter "$task_id" "slot" "$slot"
  task_update_frontmatter "$task_id" "adapter" "$adapter"
  task_update_frontmatter "$task_id" "started" "$started"
}

task_update_for_slot_clear() {
  local task_id="$1"
  local final_status="${2:-ready}"  # ready, done, or abandoned

  if ! task_file_exists "$task_id"; then
    ludics_warn "task file not found: $task_id (skipping task update)"
    return 0
  fi

  task_update_frontmatter "$task_id" "status" "$final_status"
  task_update_frontmatter "$task_id" "slot" "null"

  if [[ "$final_status" == "done" ]]; then
    local completed
    completed="$(date -u +"%Y-%m-%dT%H:%MZ")"
    task_update_frontmatter "$task_id" "completed" "$completed"
  fi
}

#------------------------------------------------------------------------------
# Slot assign
#------------------------------------------------------------------------------

slot_assign() {
  local slot="$1"
  local task_or_desc="$2"
  local adapter="${3:-manual}"
  local session="${4:-}"
  local path="${5:-}"

  local file count started block task_id process
  file="$(slots_file_path)"
  slots_ensure_file
  slots_load_blocks "$file"
  count="$(slots_count)"
  slot_validate_range "$slot" "$count"

  started="$(date -u +"%Y-%m-%dT%H:%MZ")"

  # Normalize path: strip trailing slash
  if [[ -n "$path" && "$path" != "/" ]]; then
    path="${path%/}"
  fi

  # Determine if this is a task ID or a process description
  if [[ "$task_or_desc" =~ ^task-[0-9]+ ]] || [[ "$task_or_desc" =~ ^gh- ]] || [[ "$task_or_desc" =~ ^readme- ]]; then
    task_id="$task_or_desc"
    # Try to get title from task file for Process field
    local task_file
    task_file="$(task_file_path "$task_id")"
    if [[ -f "$task_file" ]]; then
      process=$(awk '/^title:/ { sub(/^title:[[:space:]]*"?/, ""); sub(/"?$/, ""); print; exit }' "$task_file")
    else
      process="$task_id"
    fi
  else
    task_id="null"
    process="$task_or_desc"
  fi

  # Session handling: use slot number for tmux-based adapters, null for directory-based
  # If session was explicitly provided, use it; otherwise set based on adapter type
  if [[ -z "$session" ]]; then
    case "$adapter" in
      claude-code|codex|manual)
        # These adapters use tmux sessions named by slot number
        # slot_start passes slot number to adapter, which creates session with that name
        session="$slot"
        ;;
      agent-duo|agent-solo)
        # These use project directories, session is informational only
        session="null"
        ;;
      *)
        # Default: use slot number
        session="$slot"
        ;;
    esac
  fi

  block=$(cat <<BLOCK
## Slot $slot

**Process:** $process
**Task:** $task_id
**Mode:** $adapter
**Session:** $session
**Path:** ${path:-null}
**Started:** $started

**Terminals:**

**Runtime:**
- Assigned via ludics

**Git:**
BLOCK
)

  LUDICS_SLOTS["$slot"]="$block"$'\n'
  slots_write_file "$count"

  # Update task file if we have a valid task ID
  if [[ "$task_id" != "null" ]]; then
    task_update_for_slot_assign "$task_id" "$slot" "$adapter" "$started"
  fi

  # Journal entry
  ludics_journal_append "slot" "Slot $slot assigned: $process (task=$task_id, adapter=$adapter)"

  # Auto-commit state change
  ludics_state_commit "slot $slot: assign $task_or_desc"
}

#------------------------------------------------------------------------------
# Slot clear
#------------------------------------------------------------------------------

slot_clear() {
  local slot="$1"
  local final_status="${2:-ready}"  # ready, done, or abandoned

  local file count block task_id
  file="$(slots_file_path)"
  slots_ensure_file
  slots_load_blocks "$file"
  count="$(slots_count)"
  slot_validate_range "$slot" "$count"

  # Get current task before clearing
  block="${LUDICS_SLOTS[$slot]:-}"
  if [[ -n "$block" ]]; then
    task_id=$(slot_get_task "$block")
  else
    task_id="null"
  fi

  LUDICS_SLOTS["$slot"]="$(slots_empty_block "$slot")"$'\n'
  slots_write_file "$count"

  # Update task file if we had a valid task
  if [[ -n "$task_id" && "$task_id" != "null" ]]; then
    task_update_for_slot_clear "$task_id" "$final_status"
    ludics_journal_append "slot" "Slot $slot cleared: task=$task_id status=$final_status"
  else
    ludics_journal_append "slot" "Slot $slot cleared"
  fi

  # Auto-commit state change
  ludics_state_commit "slot $slot: cleared (status=$final_status)"
}

slot_add_note_block() {
  local block="$1" note="$2"
  local output="" line inserted=0 in_runtime=0

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "**Runtime:**" ]]; then
      in_runtime=1
      output+="$line"$'\n'
      continue
    fi
    if [[ $in_runtime -eq 1 && "$line" == "**Git:**" ]]; then
      output+="- $note"$'\n'
      output+="$line"$'\n'
      inserted=1
      in_runtime=0
      continue
    fi
    output+="$line"$'\n'
  done <<< "$block"

  if [[ $in_runtime -eq 1 && $inserted -eq 0 ]]; then
    output+="- $note"$'\n'
    inserted=1
  fi

  if [[ $inserted -eq 0 ]]; then
    output+=$'\n'"**Runtime:**"$'\n'"- $note"$'\n'
  fi

  printf "%s" "$output"
}

slot_note() {
  local slot="$1" note="$2"
  local file count
  file="$(slots_file_path)"
  slots_ensure_file
  slots_load_blocks "$file"
  count="$(slots_count)"
  slot_validate_range "$slot" "$count"

  if [[ -z "${LUDICS_SLOTS[$slot]:-}" ]]; then
    ludics_die "slot $slot not found"
  fi

  LUDICS_SLOTS["$slot"]="$(slot_add_note_block "${LUDICS_SLOTS[$slot]}" "$note")"
  slots_write_file "$count"
}

#------------------------------------------------------------------------------
# Slot start/stop via adapters — now handled by TypeScript entrypoint
#------------------------------------------------------------------------------

slot_adapter_action() {
  ludics_die "slot adapter actions are now handled by the TypeScript entrypoint. Use: ludics slot $2 $1"
}

slot_start() {
  ludics_die "slot start is now handled by the TypeScript entrypoint. Use: ludics slot $1 start"
}

slot_stop() {
  ludics_die "slot stop is now handled by the TypeScript entrypoint. Use: ludics slot $1 stop"
}

#------------------------------------------------------------------------------
# Slots refresh — delegates to TypeScript entrypoint
#------------------------------------------------------------------------------

slots_refresh() {
  local root
  root="$(ludics_root)"
  if [[ -f "$root/src/index.ts" ]] && command -v bun >/dev/null 2>&1; then
    bun run "$root/src/index.ts" slots refresh "$@"
  else
    ludics_warn "slots refresh: shell adapters removed; install bun and use the TypeScript entrypoint"
  fi
}

