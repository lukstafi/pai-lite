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

adapter_agent_solo_read_state() {
    local project_dir="$1"
    local sync_dir="$project_dir/.peer-sync"

    [[ -d "$sync_dir" ]] || return 1

    echo "**Mode:** agent-solo"

    local session phase round
    [[ -f "$sync_dir/session" ]] && session="$(cat "$sync_dir/session")" && echo "**Session:** $session"
    [[ -f "$sync_dir/phase" ]] && phase="$(cat "$sync_dir/phase")"
    [[ -f "$sync_dir/round" ]] && round="$(cat "$sync_dir/round")"

    # Solo mode has coder and reviewer roles
    if [[ -f "$sync_dir/coder.status" ]] || [[ -f "$sync_dir/reviewer.status" ]]; then
        echo ""
        echo "**Roles:**"
        [[ -f "$sync_dir/coder.status" ]] && echo "- Coder: $(cat "$sync_dir/coder.status")"
        [[ -f "$sync_dir/reviewer.status" ]] && echo "- Reviewer: $(cat "$sync_dir/reviewer.status")"
    fi

    if [[ -n "$phase" || -n "$round" ]]; then
        echo ""
        echo "**Runtime:**"
        [[ -n "$phase" ]] && echo "- Phase: $phase"
        [[ -n "$round" ]] && echo "- Round: $round"
    fi
}

adapter_agent_solo_start() {
    echo "agent-solo start: use the agent-duo CLI with --mode solo to launch sessions." >&2
    return 1
}

adapter_agent_solo_stop() {
    echo "agent-solo stop: use the agent-duo CLI to stop sessions." >&2
    return 1
}
