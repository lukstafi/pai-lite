#!/usr/bin/env bash
# pai-lite/adapters/agent-solo.sh - agent-solo (coder + reviewer) integration
# Uses the same .peer-sync/ structure as agent-duo but with solo workflow

# This adapter reuses most of agent-duo's functionality since they share
# the same .peer-sync state format.

#------------------------------------------------------------------------------
# Source agent-duo adapter for shared functionality
#------------------------------------------------------------------------------

# Get adapter directory
_ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source agent-duo if available (for shared functions)
if [[ -f "$_ADAPTER_DIR/agent-duo.sh" ]]; then
    # shellcheck source=agent-duo.sh
    source "$_ADAPTER_DIR/agent-duo.sh"
fi

#------------------------------------------------------------------------------
# Adapter interface for pai-lite
#------------------------------------------------------------------------------

adapter_agent-solo_status() {
    local slot_num="$1"

    # Get project directory from slot
    local project_dir
    project_dir="$(slot_get_field "$slot_num" "git_item" | grep "Base:" | sed 's/Base:[[:space:]]*//')"

    if [[ -z "$project_dir" ]]; then
        echo "    No project directory found"
        return 1
    fi

    project_dir="${project_dir/#\~/$HOME}"

    local sync_dir
    if ! sync_dir="$(find_peer_sync "$project_dir")"; then
        echo "    No .peer-sync directory found"
        return 1
    fi

    local session phase round mode
    session="$(read_sync_file "$sync_dir" "session")"
    phase="$(read_sync_file "$sync_dir" "phase")"
    round="$(read_sync_file "$sync_dir" "round")"
    mode="$(read_sync_file "$sync_dir" "mode")"

    echo "    Session: ${session:-unknown}"
    echo "    Mode: ${mode:-solo}"
    echo "    Phase: ${phase:-unknown}"
    [[ -n "$round" ]] && echo "    Round: $round"

    # Solo mode has coder and reviewer roles
    for role in coder reviewer; do
        local status
        status="$(read_sync_file "$sync_dir" "${role}.status")"
        [[ -n "$status" ]] && echo "    $role: $status"
    done

    # Show terminal URLs
    local ports
    ports="$(read_sync_file "$sync_dir" "ports")"
    if [[ -n "$ports" ]]; then
        echo "    Terminals:"
        local orch_port coder_port
        orch_port="$(parse_ports "$ports" "orchestrator")"
        coder_port="$(parse_ports "$ports" "coder")"

        [[ -n "$orch_port" ]] && echo "      Orchestrator: http://localhost:$orch_port"
        [[ -n "$coder_port" ]] && echo "      Coder: http://localhost:$coder_port"
    fi
}

adapter_agent-solo_start() {
    local slot_num="$1"

    local session
    session="$(slot_get_field "$slot_num" "session")"
    local process
    process="$(slot_get_field "$slot_num" "process")"

    if [[ -z "$session" ]]; then
        echo "Starting new agent-solo session..."

        local session_name
        session_name="$(echo "$process" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-')"

        if ! command -v agent-duo &>/dev/null; then
            die "agent-duo command not found. Install from https://github.com/lukstafi/agent-duo"
        fi

        local project_dir
        project_dir="$(slot_get_field "$slot_num" "git_item" | grep "Base:" | sed 's/Base:[[:space:]]*//')"
        project_dir="${project_dir/#\~/$HOME}"

        if [[ -z "$project_dir" || ! -d "$project_dir" ]]; then
            die "no valid project directory for slot $slot_num"
        fi

        info "starting agent-solo in $project_dir..."
        info "session: $session_name"

        # Start agent-duo in solo mode
        (cd "$project_dir" && agent-duo start "$session_name" --mode solo) || die "failed to start agent-solo"

        success "agent-solo session started"
    else
        echo "Resuming agent-solo session: $session"

        local project_dir
        project_dir="$(slot_get_field "$slot_num" "git_item" | grep "Base:" | sed 's/Base:[[:space:]]*//')"
        project_dir="${project_dir/#\~/$HOME}"

        if [[ -d "$project_dir" ]]; then
            (cd "$project_dir" && agent-duo resume "$session" 2>/dev/null) || \
                warn "could not resume session (may already be running)"
        fi
    fi
}

adapter_agent-solo_stop() {
    local slot_num="$1"

    # Same as agent-duo
    adapter_agent-duo_stop "$slot_num"
}
