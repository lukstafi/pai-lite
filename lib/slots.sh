#!/usr/bin/env bash
# pai-lite/lib/slots.sh - Slot management
# Reads and writes slots.md in the state repository

# Requires: STATE_DIR to be set by the main script

#------------------------------------------------------------------------------
# Slot file operations
#------------------------------------------------------------------------------

slots_file() {
    echo "$STATE_DIR/slots.md"
}

ensure_slots_file() {
    local file
    file="$(slots_file)"
    if [[ ! -f "$file" ]]; then
        die "slots file not found: $file"
    fi
}

#------------------------------------------------------------------------------
# Parsing slots.md
#------------------------------------------------------------------------------

# Parse a single slot section and output key=value pairs
# Usage: parse_slot_section "## Slot N" < slots.md
parse_slot_section() {
    local slot_header="$1"
    local in_section=false
    local in_runtime=false
    local in_terminals=false
    local in_git=false

    while IFS= read -r line; do
        if [[ "$line" == "$slot_header" ]]; then
            in_section=true
            continue
        fi

        if $in_section; then
            # End at next slot or end of file
            if [[ "$line" =~ ^##\ Slot ]]; then
                break
            fi

            # Parse fields
            if [[ "$line" =~ ^\*\*Process:\*\*[[:space:]]*(.*) ]]; then
                echo "process=${BASH_REMATCH[1]}"
                in_runtime=false; in_terminals=false; in_git=false
            elif [[ "$line" =~ ^\*\*Mode:\*\*[[:space:]]*(.*) ]]; then
                echo "mode=${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^\*\*Session:\*\*[[:space:]]*(.*) ]]; then
                echo "session=${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^\*\*Started:\*\*[[:space:]]*(.*) ]]; then
                echo "started=${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^\*\*Runtime:\*\* ]]; then
                in_runtime=true; in_terminals=false; in_git=false
            elif [[ "$line" =~ ^\*\*Terminals:\*\* ]]; then
                in_terminals=true; in_runtime=false; in_git=false
            elif [[ "$line" =~ ^\*\*Git:\*\* ]]; then
                in_git=true; in_runtime=false; in_terminals=false
            elif [[ "$line" =~ ^-[[:space:]]+(.*) ]]; then
                local item="${BASH_REMATCH[1]}"
                if $in_runtime; then
                    echo "runtime_item=$item"
                elif $in_terminals; then
                    echo "terminal_item=$item"
                elif $in_git; then
                    echo "git_item=$item"
                fi
            fi
        fi
    done
}

# Get a specific field from a slot
# Usage: slot_get_field <slot_num> <field>
slot_get_field() {
    local slot_num="$1"
    local field="$2"
    local file
    file="$(slots_file)"

    parse_slot_section "## Slot $slot_num" < "$file" | grep "^${field}=" | cut -d= -f2-
}

# Check if a slot is empty
slot_is_empty() {
    local slot_num="$1"
    local process
    process="$(slot_get_field "$slot_num" "process")"
    [[ -z "$process" || "$process" == "(empty)" ]]
}

#------------------------------------------------------------------------------
# Display functions
#------------------------------------------------------------------------------

slots_list() {
    ensure_slots_file
    local file
    file="$(slots_file)"

    echo -e "${BOLD}Slots${NC}"
    echo ""

    local slot_num
    for slot_num in 1 2 3 4 5 6; do
        local process mode
        process="$(slot_get_field "$slot_num" "process")"
        mode="$(slot_get_field "$slot_num" "mode")"

        if [[ -z "$process" || "$process" == "(empty)" ]]; then
            echo -e "  ${BOLD}[$slot_num]${NC} ${YELLOW}empty${NC}"
        else
            local mode_str=""
            [[ -n "$mode" ]] && mode_str=" (${BLUE}$mode${NC})"
            echo -e "  ${BOLD}[$slot_num]${NC} ${GREEN}$process${NC}$mode_str"
        fi
    done
}

slots_summary() {
    ensure_slots_file

    local active=0
    local empty=0
    local slot_num

    for slot_num in 1 2 3 4 5 6; do
        if slot_is_empty "$slot_num"; then
            ((empty++))
        else
            ((active++))
        fi
    done

    echo -e "${BOLD}Slots:${NC} $active active, $empty available"

    # List active slots
    for slot_num in 1 2 3 4 5 6; do
        if ! slot_is_empty "$slot_num"; then
            local process mode
            process="$(slot_get_field "$slot_num" "process")"
            mode="$(slot_get_field "$slot_num" "mode")"
            echo -e "  [$slot_num] $process${mode:+ ($mode)}"
        fi
    done
}

slots_list_active() {
    ensure_slots_file

    local found=false
    local slot_num

    for slot_num in 1 2 3 4 5 6; do
        if ! slot_is_empty "$slot_num"; then
            found=true
            local process mode started
            process="$(slot_get_field "$slot_num" "process")"
            mode="$(slot_get_field "$slot_num" "mode")"
            started="$(slot_get_field "$slot_num" "started")"

            echo -e "  ${BOLD}Slot $slot_num:${NC} $process"
            [[ -n "$mode" ]] && echo "    Mode: $mode"
            [[ -n "$started" ]] && echo "    Started: $started"

            # Show runtime notes if any
            local runtime_items
            runtime_items="$(slot_get_field "$slot_num" "runtime_item" | head -2)"
            if [[ -n "$runtime_items" ]]; then
                echo "    Status:"
                echo "$runtime_items" | while read -r item; do
                    echo "      - $item"
                done
            fi
            echo ""
        fi
    done

    $found || echo "  No active slots"
}

slot_show() {
    local slot_num="$1"
    ensure_slots_file

    local file
    file="$(slots_file)"

    echo -e "${BOLD}Slot $slot_num${NC}"
    echo ""

    local process mode session started
    process="$(slot_get_field "$slot_num" "process")"
    mode="$(slot_get_field "$slot_num" "mode")"
    session="$(slot_get_field "$slot_num" "session")"
    started="$(slot_get_field "$slot_num" "started")"

    if [[ -z "$process" || "$process" == "(empty)" ]]; then
        echo -e "  Status: ${YELLOW}empty${NC}"
        return 0
    fi

    echo -e "  ${BOLD}Process:${NC} $process"
    [[ -n "$mode" ]] && echo -e "  ${BOLD}Mode:${NC} $mode"
    [[ -n "$session" ]] && echo -e "  ${BOLD}Session:${NC} $session"
    [[ -n "$started" ]] && echo -e "  ${BOLD}Started:${NC} $started"

    # Terminals
    local terminals
    terminals="$(parse_slot_section "## Slot $slot_num" < "$file" | grep "^terminal_item=" | cut -d= -f2-)"
    if [[ -n "$terminals" ]]; then
        echo -e "  ${BOLD}Terminals:${NC}"
        echo "$terminals" | while read -r item; do
            echo "    - $item"
        done
    fi

    # Runtime
    local runtime
    runtime="$(parse_slot_section "## Slot $slot_num" < "$file" | grep "^runtime_item=" | cut -d= -f2-)"
    if [[ -n "$runtime" ]]; then
        echo -e "  ${BOLD}Runtime:${NC}"
        echo "$runtime" | while read -r item; do
            echo "    - $item"
        done
    fi

    # Git
    local git_info
    git_info="$(parse_slot_section "## Slot $slot_num" < "$file" | grep "^git_item=" | cut -d= -f2-)"
    if [[ -n "$git_info" ]]; then
        echo -e "  ${BOLD}Git:${NC}"
        echo "$git_info" | while read -r item; do
            echo "    - $item"
        done
    fi

    # If adapter is available, show live status
    if [[ -n "$mode" ]]; then
        if source_adapter "$mode" 2>/dev/null; then
            # Convert hyphens to underscores for valid Bash function names
            local mode_fn="${mode//-/_}"
            if declare -f "adapter_${mode_fn}_status" &>/dev/null; then
                echo ""
                echo -e "  ${BOLD}Live Status:${NC}"
                "adapter_${mode_fn}_status" "$slot_num" 2>/dev/null || echo "    (adapter error)"
            fi
        fi
    fi
}

slots_suggest() {
    ensure_slots_file

    local empty_slots=()
    local slot_num

    for slot_num in 1 2 3 4 5 6; do
        if slot_is_empty "$slot_num"; then
            empty_slots+=("$slot_num")
        fi
    done

    if [[ ${#empty_slots[@]} -eq 0 ]]; then
        echo "  - All slots in use. Consider clearing completed work."
    elif [[ ${#empty_slots[@]} -eq 6 ]]; then
        echo "  - All slots empty. Run 'pai-lite tasks list' to see available tasks."
    else
        echo "  - ${#empty_slots[@]} slots available (${empty_slots[*]})"
        echo "  - Assign tasks with 'pai-lite slot <n> assign <task-id>'"
    fi
}

#------------------------------------------------------------------------------
# Modification functions
#------------------------------------------------------------------------------

# Generate a slot section markdown
generate_slot_section() {
    local slot_num="$1"
    local process="${2:-(empty)}"
    local mode="$3"
    local session="$4"
    local started="$5"
    shift 5
    local terminals=("${@:1:$#/3}")
    local runtime=("${@:$((1+$#/3)):$#/3}")
    local git_info=("${@:$((1+2*$#/3))}")

    echo "## Slot $slot_num"
    echo ""
    echo "**Process:** $process"

    if [[ "$process" != "(empty)" && -n "$mode" ]]; then
        echo "**Mode:** $mode"
        [[ -n "$session" ]] && echo "**Session:** $session"
        [[ -n "$started" ]] && echo "**Started:** $started"

        if [[ ${#terminals[@]} -gt 0 && -n "${terminals[0]}" ]]; then
            echo ""
            echo "**Terminals:**"
            for t in "${terminals[@]}"; do
                [[ -n "$t" ]] && echo "- $t"
            done
        fi

        if [[ ${#runtime[@]} -gt 0 && -n "${runtime[0]}" ]]; then
            echo ""
            echo "**Runtime:**"
            for r in "${runtime[@]}"; do
                [[ -n "$r" ]] && echo "- $r"
            done
        fi

        if [[ ${#git_info[@]} -gt 0 && -n "${git_info[0]}" ]]; then
            echo ""
            echo "**Git:**"
            for g in "${git_info[@]}"; do
                [[ -n "$g" ]] && echo "- $g"
            done
        fi
    fi
}

# Update a slot in the slots.md file
# This rewrites the entire file with the updated slot
update_slot_in_file() {
    local slot_num="$1"
    local new_section="$2"
    local file
    file="$(slots_file)"

    local temp_file
    temp_file="$(mktemp)"

    local in_target_slot=false
    local wrote_new_section=false

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "## Slot $slot_num" ]]; then
            in_target_slot=true
            echo "$new_section" >> "$temp_file"
            wrote_new_section=true
            continue
        fi

        if $in_target_slot; then
            if [[ "$line" =~ ^##\ Slot ]] || [[ "$line" == "---" && "$wrote_new_section" == "true" ]]; then
                in_target_slot=false
                echo "" >> "$temp_file"
                echo "---" >> "$temp_file"
                echo "" >> "$temp_file"
                # If this is another slot header, write it
                if [[ "$line" =~ ^##\ Slot ]]; then
                    echo "$line" >> "$temp_file"
                fi
            fi
            # Skip lines while in target slot (they're replaced)
            continue
        fi

        echo "$line" >> "$temp_file"
    done < "$file"

    mv "$temp_file" "$file"
}

slot_assign() {
    local slot_num="$1"
    local task_id="$2"

    ensure_slots_file

    if ! slot_is_empty "$slot_num"; then
        warn "slot $slot_num is not empty"
        read -rp "Clear and assign? [y/N] " confirm
        [[ "$confirm" =~ ^[Yy] ]] || { info "aborted"; return 1; }
    fi

    # Look up task details
    local task_name="$task_id"
    if declare -f task_get_title &>/dev/null; then
        task_name="$(task_get_title "$task_id")" || task_name="$task_id"
    fi

    local started
    started="$(date -u '+%Y-%m-%dT%H:%MZ')"

    local new_section
    new_section="$(generate_slot_section "$slot_num" "$task_name" "" "" "$started")"

    update_slot_in_file "$slot_num" "$new_section"

    success "assigned '$task_name' to slot $slot_num"
}

slot_clear() {
    local slot_num="$1"
    ensure_slots_file

    if slot_is_empty "$slot_num"; then
        info "slot $slot_num is already empty"
        return 0
    fi

    local process
    process="$(slot_get_field "$slot_num" "process")"

    # Check if there's an active session to stop
    local mode
    mode="$(slot_get_field "$slot_num" "mode")"
    if [[ -n "$mode" ]]; then
        if source_adapter "$mode" 2>/dev/null; then
            # Convert hyphens to underscores for valid Bash function names
            local mode_fn="${mode//-/_}"
            if declare -f "adapter_${mode_fn}_stop" &>/dev/null; then
                info "stopping $mode session..."
                "adapter_${mode_fn}_stop" "$slot_num" 2>/dev/null || warn "failed to stop session"
            fi
        fi
    fi

    local new_section
    new_section="$(generate_slot_section "$slot_num" "(empty)")"

    update_slot_in_file "$slot_num" "$new_section"

    success "cleared slot $slot_num (was: $process)"
}

slot_start() {
    local slot_num="$1"
    local mode="${2:-}"

    ensure_slots_file

    if slot_is_empty "$slot_num"; then
        die "slot $slot_num is empty - assign a task first"
    fi

    local current_mode
    current_mode="$(slot_get_field "$slot_num" "mode")"

    # Use specified mode or existing mode
    mode="${mode:-$current_mode}"
    [[ -z "$mode" ]] && die "no mode specified and slot has no mode set"

    # Load and invoke adapter
    if ! source_adapter "$mode"; then
        die "adapter not found: $mode"
    fi

    # Convert hyphens to underscores for valid Bash function names
    local mode_fn="${mode//-/_}"
    if ! declare -f "adapter_${mode_fn}_start" &>/dev/null; then
        die "adapter $mode does not support start"
    fi

    info "starting $mode session for slot $slot_num..."
    "adapter_${mode_fn}_start" "$slot_num"
}

slot_stop() {
    local slot_num="$1"
    ensure_slots_file

    if slot_is_empty "$slot_num"; then
        die "slot $slot_num is empty"
    fi

    local mode
    mode="$(slot_get_field "$slot_num" "mode")"
    [[ -z "$mode" ]] && die "slot $slot_num has no mode - nothing to stop"

    if ! source_adapter "$mode"; then
        die "adapter not found: $mode"
    fi

    # Convert hyphens to underscores for valid Bash function names
    local mode_fn="${mode//-/_}"
    if ! declare -f "adapter_${mode_fn}_stop" &>/dev/null; then
        die "adapter $mode does not support stop"
    fi

    info "stopping $mode session for slot $slot_num..."
    "adapter_${mode_fn}_stop" "$slot_num"
}

slot_note() {
    local slot_num="$1"
    shift
    local text="$*"

    ensure_slots_file

    if slot_is_empty "$slot_num"; then
        die "slot $slot_num is empty"
    fi

    local file
    file="$(slots_file)"

    # Get current slot data
    local process mode session started
    process="$(slot_get_field "$slot_num" "process")"
    mode="$(slot_get_field "$slot_num" "mode")"
    session="$(slot_get_field "$slot_num" "session")"
    started="$(slot_get_field "$slot_num" "started")"

    # Get existing runtime items and add new one
    local runtime_items
    runtime_items="$(parse_slot_section "## Slot $slot_num" < "$file" | grep "^runtime_item=" | cut -d= -f2-)"

    # Get terminals and git
    local terminal_items git_items
    terminal_items="$(parse_slot_section "## Slot $slot_num" < "$file" | grep "^terminal_item=" | cut -d= -f2-)"
    git_items="$(parse_slot_section "## Slot $slot_num" < "$file" | grep "^git_item=" | cut -d= -f2-)"

    # Build new section
    local new_section="## Slot $slot_num

**Process:** $process"

    [[ -n "$mode" ]] && new_section+="
**Mode:** $mode"
    [[ -n "$session" ]] && new_section+="
**Session:** $session"
    [[ -n "$started" ]] && new_section+="
**Started:** $started"

    if [[ -n "$terminal_items" ]]; then
        new_section+="

**Terminals:**"
        while IFS= read -r item; do
            new_section+="
- $item"
        done <<< "$terminal_items"
    fi

    # Add runtime with new note
    new_section+="

**Runtime:**"
    if [[ -n "$runtime_items" ]]; then
        while IFS= read -r item; do
            new_section+="
- $item"
        done <<< "$runtime_items"
    fi
    new_section+="
- $text"

    if [[ -n "$git_items" ]]; then
        new_section+="

**Git:**"
        while IFS= read -r item; do
            new_section+="
- $item"
        done <<< "$git_items"
    fi

    update_slot_in_file "$slot_num" "$new_section"

    success "added note to slot $slot_num"
}
