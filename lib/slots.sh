#!/usr/bin/env bash
set -euo pipefail

# Slot management for pai-lite

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$script_dir/common.sh"

declare -gA PAI_LITE_SLOTS

slots_file_path() {
  pai_lite_ensure_state_repo
  pai_lite_ensure_state_dir
  echo "$(pai_lite_state_harness_dir)/slots.md"
}

slots_empty_block() {
  local slot="$1"
  cat <<BLOCK
## Slot $slot

**Process:** (empty)
**Task:** null
**Mode:** null
**Session:** null
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
    count="$(pai_lite_config_slots_count)"
    [[ -n "$count" ]] || count=6
    PAI_LITE_SLOTS=()
    slots_write_file "$count"
  fi
}

slots_load_blocks() {
  local file line slot=0 block=""
  file="$1"
  declare -gA PAI_LITE_SLOTS
  PAI_LITE_SLOTS=()

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^##[[:space:]]+Slot[[:space:]]+([0-9]+) ]]; then
      if [[ $slot -ne 0 ]]; then
        PAI_LITE_SLOTS["$slot"]="$block"
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
    PAI_LITE_SLOTS["$slot"]="$block"
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
      if [[ -n "${PAI_LITE_SLOTS[$i]:-}" ]]; then
        printf "%s" "${PAI_LITE_SLOTS[$i]}"
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
  count="$(pai_lite_config_slots_count)"
  [[ -n "$count" ]] || count=6
  echo "$count"
}

slot_validate_range() {
  local slot="$1"
  local count="$2"
  [[ "$slot" =~ ^[0-9]+$ ]] || pai_lite_die "slot must be a number: $slot"
  if (( slot < 1 || slot > count )); then
    pai_lite_die "slot out of range: $slot (1-$count)"
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
  printf "%s" "$block" | awk -F"\\*\\*${field}:\\*\\*" -v field="$field" '
    $0 ~ "\\*\\*" field ":\\*\\*" {
      sub(/^[[:space:]]*/, "", $2)
      print $2
      exit
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
  tasks_dir="$(pai_lite_state_harness_dir)/tasks"
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

task_update_for_slot_assign() {
  local task_id="$1"
  local slot="$2"
  local adapter="$3"
  local started="$4"

  if ! task_file_exists "$task_id"; then
    pai_lite_warn "task file not found: $task_id (skipping task update)"
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
    pai_lite_warn "task file not found: $task_id (skipping task update)"
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

  local file count started block task_id process
  file="$(slots_file_path)"
  slots_ensure_file
  slots_load_blocks "$file"
  count="$(slots_count)"
  slot_validate_range "$slot" "$count"

  started="$(date -u +"%Y-%m-%dT%H:%MZ")"

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
**Started:** $started

**Terminals:**

**Runtime:**
- Assigned via pai-lite

**Git:**
BLOCK
)

  PAI_LITE_SLOTS["$slot"]="$block"$'\n'
  slots_write_file "$count"

  # Update task file if we have a valid task ID
  if [[ "$task_id" != "null" ]]; then
    task_update_for_slot_assign "$task_id" "$slot" "$adapter" "$started"
  fi

  # Journal entry
  pai_lite_journal_append "slot" "Slot $slot assigned: $process (task=$task_id, adapter=$adapter)"

  # Auto-commit state change
  pai_lite_state_commit "slot $slot: assign $task_or_desc"
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
  block="${PAI_LITE_SLOTS[$slot]:-}"
  if [[ -n "$block" ]]; then
    task_id=$(slot_get_task "$block")
  else
    task_id="null"
  fi

  PAI_LITE_SLOTS["$slot"]="$(slots_empty_block "$slot")"$'\n'
  slots_write_file "$count"

  # Update task file if we had a valid task
  if [[ -n "$task_id" && "$task_id" != "null" ]]; then
    task_update_for_slot_clear "$task_id" "$final_status"
    pai_lite_journal_append "slot" "Slot $slot cleared: task=$task_id status=$final_status"
  else
    pai_lite_journal_append "slot" "Slot $slot cleared"
  fi

  # Auto-commit state change
  pai_lite_state_commit "slot $slot: cleared (status=$final_status)"
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

  if [[ -z "${PAI_LITE_SLOTS[$slot]:-}" ]]; then
    pai_lite_die "slot $slot not found"
  fi

  PAI_LITE_SLOTS["$slot"]="$(slot_add_note_block "${PAI_LITE_SLOTS[$slot]}" "$note")"
  slots_write_file "$count"
}

#------------------------------------------------------------------------------
# Slot start/stop via adapters
#------------------------------------------------------------------------------

slot_adapter_action() {
  local action="$1" slot="$2"
  local file block mode root adapter_file fn

  file="$(slots_file_path)"
  slot_validate_range "$slot" "$(slots_count)"
  slots_ensure_file
  slots_load_blocks "$file"
  block="${PAI_LITE_SLOTS[$slot]:-}"
  [[ -n "$block" ]] || pai_lite_die "slot $slot not found"

  mode=$(slot_get_mode "$block")
  mode=$(printf "%s" "$mode" | awk '{$1=$1; print}')
  [[ -n "$mode" && "$mode" != "null" ]] || pai_lite_die "slot $slot has no Mode"

  root="$(pai_lite_root)"
  adapter_file="$root/adapters/$mode.sh"
  [[ -f "$adapter_file" ]] || pai_lite_die "adapter not found: $mode"
  # shellcheck source=/dev/null
  source "$adapter_file"

  fn="adapter_${mode//-/_}_${action}"
  if ! declare -F "$fn" >/dev/null 2>&1; then
    pai_lite_die "adapter missing function: $fn"
  fi

  # Extract slot metadata for adapter calls
  local session task_id process project_dir
  session=$(slot_get_session "$block")
  session=$(printf "%s" "$session" | awk '{$1=$1; print}')
  [[ "$session" == "null" ]] && session=""

  task_id=$(slot_get_task "$block")
  task_id=$(printf "%s" "$task_id" | awk '{$1=$1; print}')
  [[ "$task_id" == "null" ]] && task_id=""

  process=$(slot_get_process "$block")
  process=$(printf "%s" "$process" | awk '{$1=$1; print}')
  [[ "$process" == "(empty)" ]] && process=""

  # Try to find project directory from session name or current directory
  project_dir=""
  if [[ -n "$session" ]]; then
    if [[ -d "$HOME/$session" ]]; then
      project_dir="$HOME/$session"
    elif [[ -d "$HOME/repos/$session" ]]; then
      project_dir="$HOME/repos/$session"
    fi
  fi
  [[ -n "$project_dir" ]] || project_dir="$PWD"

  # Call adapter with appropriate arguments based on adapter type
  # Adapter signatures:
  # - agent-duo, agent-solo: project_dir, task_id, session_name
  # - claude-code, codex: session_name, project_dir, task_id
  # - claude-ai, chatgpt-com: url, label, task_id
  # - manual: slot_num
  PAI_LITE_STATE_DIR="$(pai_lite_state_harness_dir)" \
    PAI_LITE_STATE_REPO="$(pai_lite_state_repo_dir)" \
    PAI_LITE_SLOT="$slot" \
    PAI_LITE_TASK="$task_id" \
    PAI_LITE_SESSION="$session" \
    PAI_LITE_PROCESS="$process"
  export PAI_LITE_STATE_DIR PAI_LITE_STATE_REPO PAI_LITE_SLOT PAI_LITE_TASK PAI_LITE_SESSION PAI_LITE_PROCESS

  case "$mode" in
    agent-duo|agent-solo)
      "$fn" "$project_dir" "$task_id" "$session"
      ;;
    claude-code|codex)
      # session_name defaults to slot number if empty
      [[ -n "$session" ]] || session="$slot"
      "$fn" "$session" "$project_dir" "$task_id"
      ;;
    claude-ai|chatgpt-com)
      # session is used as URL, process as label
      "$fn" "$session" "$process" "$task_id"
      ;;
    manual)
      "$fn" "$slot"
      ;;
    *)
      # Default: pass slot and harness dir for backwards compatibility
      "$fn" "$slot" "$(pai_lite_state_harness_dir)"
      ;;
  esac

  # Journal entry for start/stop
  if [[ "$action" == "start" ]]; then
    pai_lite_journal_append "slot" "Slot $slot started (adapter=$mode)"
  elif [[ "$action" == "stop" ]]; then
    pai_lite_journal_append "slot" "Slot $slot stopped (adapter=$mode)"
  fi
}

slot_start() {
  slot_adapter_action "start" "$1"
}

slot_stop() {
  slot_adapter_action "stop" "$1"
}

#------------------------------------------------------------------------------
# Slots refresh - read adapter state and update Runtime/Terminals blocks
#------------------------------------------------------------------------------

slots_refresh() {
  local file count i block mode root adapter_file fn updated_block
  file="$(slots_file_path)"
  slots_ensure_file
  slots_load_blocks "$file"
  count="$(slots_count)"

  local any_updated=0

  for ((i=1; i<=count; i++)); do
    block="${PAI_LITE_SLOTS[$i]:-}"
    [[ -n "$block" ]] || continue

    mode=$(slot_get_mode "$block")
    mode=$(printf "%s" "$mode" | awk '{$1=$1; print}')
    [[ -n "$mode" && "$mode" != "null" ]] || continue

    root="$(pai_lite_root)"
    adapter_file="$root/adapters/$mode.sh"
    [[ -f "$adapter_file" ]] || continue

    # shellcheck source=/dev/null
    source "$adapter_file"

    fn="adapter_${mode//-/_}_read_state"
    if ! declare -F "$fn" >/dev/null 2>&1; then
      continue
    fi

    # Get the session info from slot
    local session
    session=$(slot_get_session "$block")
    session=$(printf "%s" "$session" | awk '{$1=$1; print}')

    # Determine the right argument to pass based on adapter type
    # Different adapters expect different first arguments:
    # - agent-duo, agent-solo: project_dir (path with .peer-sync/)
    # - claude-code, codex: session_name (tmux session, can be empty for auto-detect)
    # - manual: slot_num
    # - claude-ai, chatgpt-com: url or identifier
    local adapter_arg=""
    case "$mode" in
      agent-duo|agent-solo)
        # Look for project directory
        if [[ -n "$session" && "$session" != "null" ]]; then
          if [[ -d "$HOME/$session" && -d "$HOME/$session/.peer-sync" ]]; then
            adapter_arg="$HOME/$session"
          elif [[ -d "$HOME/repos/$session" && -d "$HOME/repos/$session/.peer-sync" ]]; then
            adapter_arg="$HOME/repos/$session"
          fi
        fi
        # Fallback to current directory if it has .peer-sync
        if [[ -z "$adapter_arg" && -d "$PWD/.peer-sync" ]]; then
          adapter_arg="$PWD"
        fi
        [[ -n "$adapter_arg" ]] || continue  # Skip if no valid project dir
        ;;
      claude-code|codex)
        # Pass session name; empty string triggers auto-detect
        adapter_arg="$session"
        [[ "$adapter_arg" == "null" ]] && adapter_arg=""
        ;;
      manual)
        # Manual adapter expects slot number
        adapter_arg="$i"
        ;;
      claude-ai|chatgpt-com)
        # Pass session as identifier/URL
        adapter_arg="$session"
        [[ "$adapter_arg" == "null" ]] && adapter_arg=""
        ;;
      *)
        # Default: try session name, empty if null
        adapter_arg="$session"
        [[ "$adapter_arg" == "null" ]] && adapter_arg=""
        ;;
    esac

    # Call the adapter's read_state function and capture output
    local adapter_output
    adapter_output=$("$fn" "$adapter_arg" 2>/dev/null) || continue
    [[ -n "$adapter_output" ]] || continue

    # Update the slot block with adapter information
    updated_block=$(slot_merge_adapter_state "$block" "$adapter_output")
    PAI_LITE_SLOTS[$i]="$updated_block"
    any_updated=1
    pai_lite_info "refreshed slot $i ($mode)"
  done

  if [[ $any_updated -eq 1 ]]; then
    slots_write_file "$count"
    pai_lite_state_commit "slots refresh"
  fi
}

# Merge adapter state output into slot block
slot_merge_adapter_state() {
  local block="$1"
  local adapter_output="$2"

  # Extract sections from adapter output
  # Terminals, Runtime, Git are the canonical sections
  # Status, Warnings, Notes, Agents get merged into Runtime
  local terminals_section="" runtime_section="" git_section=""
  local has_terminals=0 has_runtime=0 has_git=0
  local current_section=""

  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      "**Terminals:"*|"**Terminals**"*)
        current_section="terminals"
        has_terminals=1
        continue
        ;;
      "**Runtime:"*|"**Runtime**"*)
        current_section="runtime"
        has_runtime=1
        continue
        ;;
      "**Git:"*|"**Git**"*)
        current_section="git"
        has_git=1
        continue
        ;;
      "**Mode:"*|"**Session:"*|"**Feature:"*)
        # Skip these - we preserve the slot's original values
        current_section=""
        continue
        ;;
      "**"*":**"*)
        # Any other **SectionName:** header (Status, Agents, Warnings, Notes,
        # Roles, Conversations, Stats, etc.) gets mapped into runtime
        current_section="runtime"
        has_runtime=1
        runtime_section+="$line"$'\n'
        continue
        ;;
    esac

    # Accumulate content based on current section
    case "$current_section" in
      terminals)
        terminals_section+="$line"$'\n'
        ;;
      runtime)
        runtime_section+="$line"$'\n'
        ;;
      git)
        git_section+="$line"$'\n'
        ;;
    esac
  done <<< "$adapter_output"

  # Now rebuild the block, preserving Process/Task/Mode/Session/Started
  # Only replace Terminals/Runtime/Git if the adapter actually provided that section
  local output="" in_section="" skip_until_next=0

  while IFS= read -r line || [[ -n "$line" ]]; do
    # Track section transitions
    case "$line" in
      "**Terminals:"*)
        output+="**Terminals:**"$'\n'
        if [[ $has_terminals -eq 1 ]]; then
          # Adapter provided this section - use adapter data
          if [[ -n "$terminals_section" ]]; then
            output+="$terminals_section"
          fi
          skip_until_next=1
        else
          # Adapter didn't provide this section - preserve existing content
          skip_until_next=0
        fi
        in_section="terminals"
        continue
        ;;
      "**Runtime:"*)
        output+="**Runtime:**"$'\n'
        if [[ $has_runtime -eq 1 ]]; then
          # Adapter provided this section - use adapter data
          if [[ -n "$runtime_section" ]]; then
            output+="$runtime_section"
          fi
          skip_until_next=1
        else
          # Adapter didn't provide this section - preserve existing content
          skip_until_next=0
        fi
        in_section="runtime"
        continue
        ;;
      "**Git:"*)
        output+="**Git:**"$'\n'
        if [[ $has_git -eq 1 ]]; then
          # Adapter provided this section - use adapter data
          if [[ -n "$git_section" ]]; then
            output+="$git_section"
          fi
          skip_until_next=1
        else
          # Adapter didn't provide this section - preserve existing content
          skip_until_next=0
        fi
        in_section="git"
        continue
        ;;
    esac

    # Check if we've hit a new section header
    if [[ "$line" =~ ^\*\* ]]; then
      skip_until_next=0
      in_section=""
    fi

    if [[ $skip_until_next -eq 0 ]]; then
      output+="$line"$'\n'
    fi
  done <<< "$block"

  printf "%s" "$output"
}
