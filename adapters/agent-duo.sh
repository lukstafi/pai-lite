#!/usr/bin/env bash
# pai-lite/adapters/agent-duo.sh - agent-duo integration
# Reads state from .peer-sync/ directory

#------------------------------------------------------------------------------
# State reading from .peer-sync/
#------------------------------------------------------------------------------

# Find .peer-sync directory for a project
find_peer_sync() {
    local project_dir="$1"

    # Check common locations
    for dir in "$project_dir/.peer-sync" "$project_dir/../.peer-sync"; do
        if [[ -d "$dir" ]]; then
            echo "$(cd "$dir" && pwd)"
            return 0
        fi
    done
    return 1
}

# Read a simple value file from .peer-sync
read_sync_file() {
    local sync_dir="$1"
    local filename="$2"
    local file="$sync_dir/$filename"

    [[ -f "$file" ]] && cat "$file"
}

# Get agent-duo session state
adapter_agent-duo_read_state() {
    local project_dir="$1"

    local sync_dir
    sync_dir="$(find_peer_sync "$project_dir")" || return 1

    local session phase round mode
    session="$(read_sync_file "$sync_dir" "session")"
    phase="$(read_sync_file "$sync_dir" "phase")"
    round="$(read_sync_file "$sync_dir" "round")"
    mode="$(read_sync_file "$sync_dir" "mode")"

    echo "session=$session"
    echo "phase=$phase"
    echo "round=$round"
    echo "mode=$mode"

    # Read ports if available
    local ports_file="$sync_dir/ports"
    if [[ -f "$ports_file" ]]; then
        echo "ports=$(cat "$ports_file")"
    fi

    # Read agent statuses
    for agent in claude codex gemini; do
        local status_file="$sync_dir/${agent}.status"
        if [[ -f "$status_file" ]]; then
            echo "${agent}_status=$(cat "$status_file")"
        fi
    done
}

# Parse ports file format: "orchestrator:7680 claude:7681 codex:7682"
parse_ports() {
    local ports_str="$1"
    local role="$2"

    echo "$ports_str" | tr ' ' '\n' | grep "^${role}:" | cut -d: -f2
}

#------------------------------------------------------------------------------
# Adapter interface for pai-lite
#------------------------------------------------------------------------------

adapter_agent-duo_status() {
    local slot_num="$1"

    # Get project directory from slot
    local project_dir
    project_dir="$(slot_get_field "$slot_num" "git_item" | grep "Base:" | sed 's/Base:[[:space:]]*//')"

    if [[ -z "$project_dir" ]]; then
        echo "    No project directory found"
        return 1
    fi

    # Expand ~ if present
    project_dir="${project_dir/#\~/$HOME}"

    local sync_dir
    if ! sync_dir="$(find_peer_sync "$project_dir")"; then
        echo "    No .peer-sync directory found"
        return 1
    fi

    local session phase round
    session="$(read_sync_file "$sync_dir" "session")"
    phase="$(read_sync_file "$sync_dir" "phase")"
    round="$(read_sync_file "$sync_dir" "round")"

    echo "    Session: ${session:-unknown}"
    echo "    Phase: ${phase:-unknown}"
    [[ -n "$round" ]] && echo "    Round: $round"

    # Show agent statuses
    for agent in claude codex; do
        local status
        status="$(read_sync_file "$sync_dir" "${agent}.status")"
        [[ -n "$status" ]] && echo "    $agent: $status"
    done

    # Show terminal URLs if ports are available
    local ports
    ports="$(read_sync_file "$sync_dir" "ports")"
    if [[ -n "$ports" ]]; then
        echo "    Terminals:"
        local orch_port claude_port codex_port
        orch_port="$(parse_ports "$ports" "orchestrator")"
        claude_port="$(parse_ports "$ports" "claude")"
        codex_port="$(parse_ports "$ports" "codex")"

        [[ -n "$orch_port" ]] && echo "      Orchestrator: http://localhost:$orch_port"
        [[ -n "$claude_port" ]] && echo "      Claude: http://localhost:$claude_port"
        [[ -n "$codex_port" ]] && echo "      Codex: http://localhost:$codex_port"
    fi
}

adapter_agent-duo_start() {
    local slot_num="$1"

    # Get session info from slot
    local session
    session="$(slot_get_field "$slot_num" "session")"
    local process
    process="$(slot_get_field "$slot_num" "process")"

    if [[ -z "$session" ]]; then
        # Need to create a new session
        echo "Starting new agent-duo session..."

        # Derive session name from process
        local session_name
        session_name="$(echo "$process" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-')"

        if ! command -v agent-duo &>/dev/null; then
            die "agent-duo command not found. Install from https://github.com/lukstafi/agent-duo"
        fi

        # Get project directory
        local project_dir
        project_dir="$(slot_get_field "$slot_num" "git_item" | grep "Base:" | sed 's/Base:[[:space:]]*//')"
        project_dir="${project_dir/#\~/$HOME}"

        if [[ -z "$project_dir" || ! -d "$project_dir" ]]; then
            die "no valid project directory for slot $slot_num"
        fi

        info "starting agent-duo in $project_dir..."
        info "session: $session_name"

        # Start agent-duo (this will open terminals)
        (cd "$project_dir" && agent-duo start "$session_name") || die "failed to start agent-duo"

        success "agent-duo session started"
    else
        # Resume existing session
        echo "Resuming agent-duo session: $session"

        local project_dir
        project_dir="$(slot_get_field "$slot_num" "git_item" | grep "Base:" | sed 's/Base:[[:space:]]*//')"
        project_dir="${project_dir/#\~/$HOME}"

        if [[ -d "$project_dir" ]]; then
            (cd "$project_dir" && agent-duo resume "$session" 2>/dev/null) || \
                warn "could not resume session (may already be running)"
        fi
    fi
}

adapter_agent-duo_stop() {
    local slot_num="$1"

    local session
    session="$(slot_get_field "$slot_num" "session")"

    if [[ -z "$session" ]]; then
        warn "no session to stop"
        return 0
    fi

    local project_dir
    project_dir="$(slot_get_field "$slot_num" "git_item" | grep "Base:" | sed 's/Base:[[:space:]]*//')"
    project_dir="${project_dir/#\~/$HOME}"

    if command -v agent-duo &>/dev/null && [[ -d "$project_dir" ]]; then
        info "stopping agent-duo session: $session"
        (cd "$project_dir" && agent-duo stop 2>/dev/null) || true
    fi

    success "stopped agent-duo session"
}

#------------------------------------------------------------------------------
# Utility: Update slot from .peer-sync state
#------------------------------------------------------------------------------

# Sync slot state from agent-duo's .peer-sync directory
adapter_agent-duo_sync_slot() {
    local slot_num="$1"
    local project_dir="$2"

    local sync_dir
    sync_dir="$(find_peer_sync "$project_dir")" || return 1

    local session phase round ports
    session="$(read_sync_file "$sync_dir" "session")"
    phase="$(read_sync_file "$sync_dir" "phase")"
    round="$(read_sync_file "$sync_dir" "round")"
    ports="$(read_sync_file "$sync_dir" "ports")"

    # Build runtime items
    local runtime_items=()
    [[ -n "$phase" ]] && runtime_items+=("Phase: $phase")
    [[ -n "$round" ]] && runtime_items+=("Round: $round")

    # Build terminal items
    local terminal_items=()
    if [[ -n "$ports" ]]; then
        local orch_port
        orch_port="$(parse_ports "$ports" "orchestrator")"
        [[ -n "$orch_port" ]] && terminal_items+=("Orchestrator: http://localhost:$orch_port")

        local claude_port
        claude_port="$(parse_ports "$ports" "claude")"
        [[ -n "$claude_port" ]] && terminal_items+=("Claude: http://localhost:$claude_port")

        local codex_port
        codex_port="$(parse_ports "$ports" "codex")"
        [[ -n "$codex_port" ]] && terminal_items+=("Codex: http://localhost:$codex_port")
    fi

    echo "session=$session"
    echo "runtime_count=${#runtime_items[@]}"
    for i in "${!runtime_items[@]}"; do
        echo "runtime_$i=${runtime_items[$i]}"
    done
    echo "terminal_count=${#terminal_items[@]}"
    for i in "${!terminal_items[@]}"; do
        echo "terminal_$i=${terminal_items[$i]}"
    done
}
