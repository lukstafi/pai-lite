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
  local file
  file="$(slots_file_path)"

  {
    echo "# Slots"
    echo ""
    for ((slot=1; slot<=count; slot++)); do
      if [[ -n "${PAI_LITE_SLOTS[$slot]:-}" ]]; then
        printf "%s" "${PAI_LITE_SLOTS[$slot]}"
      else
        slots_empty_block "$slot"
      fi
      if [[ "$slot" -lt "$count" ]]; then
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

slot_assign() {
  local slot="$1" task="$2"
  local file count started block
  file="$(slots_file_path)"
  slots_ensure_file
  slots_load_blocks "$file"
  count="$(slots_count)"
  slot_validate_range "$slot" "$count"

  started="$(date -u +"%Y-%m-%dT%H:%MZ")"
  block=$(cat <<BLOCK
## Slot $slot

**Process:** $task
**Mode:** manual
**Started:** $started

**Runtime:**
- Assigned via pai-lite
BLOCK
)

  PAI_LITE_SLOTS["$slot"]="$block"$'\n'
  slots_write_file "$count"
}

slot_clear() {
  local slot="$1" file count
  file="$(slots_file_path)"
  slots_ensure_file
  slots_load_blocks "$file"
  count="$(slots_count)"
  slot_validate_range "$slot" "$count"

  PAI_LITE_SLOTS["$slot"]="$(slots_empty_block "$slot")"$'\n'
  slots_write_file "$count"
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

slot_adapter_action() {
  local action="$1" slot="$2"
  local file block mode root adapter_file fn

  file="$(slots_file_path)"
  slot_validate_range "$slot" "$(slots_count)"
  slots_ensure_file
  slots_load_blocks "$file"
  block="${PAI_LITE_SLOTS[$slot]:-}"
  [[ -n "$block" ]] || pai_lite_die "slot $slot not found"

  mode=$(printf "%s" "$block" | awk -F'\*\*Mode:\*\*' '/\*\*Mode:\*\*/ { sub(/^[[:space:]]*/, "", $2); print $2; exit }')
  mode=$(printf "%s" "$mode" | awk '{$1=$1; print}')
  [[ -n "$mode" ]] || pai_lite_die "slot $slot has no Mode" 

  root="$(pai_lite_root)"
  adapter_file="$root/adapters/$mode.sh"
  [[ -f "$adapter_file" ]] || pai_lite_die "adapter not found: $mode"
  # shellcheck source=/dev/null
  source "$adapter_file"

  fn="adapter_${mode//-/_}_${action}"
  if ! declare -F "$fn" >/dev/null 2>&1; then
    pai_lite_die "adapter missing function: $fn"
  fi

  PAI_LITE_STATE_DIR="$(pai_lite_state_harness_dir)" \
    PAI_LITE_STATE_REPO="$(pai_lite_state_repo_dir)" \
    "$fn" "$slot" "$(pai_lite_state_harness_dir)"
}

slot_start() {
  slot_adapter_action "start" "$1"
}

slot_stop() {
  slot_adapter_action "stop" "$1"
}
