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
    local project_dir="${1:-.}"
    local sync_dir="$project_dir/.peer-sync"

    [[ -d "$sync_dir" ]] || return 1

    local phase="" round="" session="" feature="" mode=""

    # Read from individual files (primary format)
    [[ -f "$sync_dir/phase" ]] && phase=$(cat "$sync_dir/phase" 2>/dev/null | tr -d '\n')
    [[ -f "$sync_dir/round" ]] && round=$(cat "$sync_dir/round" 2>/dev/null | tr -d '\n')
    [[ -f "$sync_dir/session" ]] && session=$(cat "$sync_dir/session" 2>/dev/null | tr -d '\n')
    [[ -f "$sync_dir/feature" ]] && feature=$(cat "$sync_dir/feature" 2>/dev/null | tr -d '\n')
    [[ -f "$sync_dir/mode" ]] && mode=$(cat "$sync_dir/mode" 2>/dev/null | tr -d '\n')

    # Fallback to JSON state file if individual files don't exist
    if [[ -z "$phase" && -z "$session" ]]; then
        local state_file="$sync_dir/state.json"
        if [[ -f "$state_file" ]] && command -v python3 >/dev/null 2>&1; then
            read -r phase round session feature mode <<<"$(python3 - "$state_file" <<'PY'
import json,sys
try:
    data = json.load(open(sys.argv[1]))
    print(
        data.get("phase",""),
        data.get("round",""),
        data.get("session",""),
        data.get("feature",""),
        data.get("mode","")
    )
except Exception:
    print("", "", "", "", "")
PY
)"
        fi
    fi

    echo "**Mode:** agent-solo"
    [[ -n "$session" ]] && echo "**Session:** $session"
    [[ -n "$feature" ]] && echo "**Feature:** $feature"

    # Display agent status with pipe-delimited format parsing
    if [[ -f "$sync_dir/coder.status" ]] || [[ -f "$sync_dir/reviewer.status" ]]; then
        echo ""
        echo "**Roles:**"
        if [[ -f "$sync_dir/coder.status" ]]; then
            local coder_status_line coder_agent_status coder_agent_timestamp coder_agent_message
            coder_status_line=$(cat "$sync_dir/coder.status" 2>/dev/null)
            IFS='|' read -r coder_agent_status coder_agent_timestamp coder_agent_message <<< "$coder_status_line"
            if [[ -n "$coder_agent_status" ]]; then
                if [[ -n "$coder_agent_message" ]]; then
                    echo "- Coder: $coder_agent_status - $coder_agent_message"
                else
                    echo "- Coder: $coder_agent_status"
                fi
            fi
        fi
        if [[ -f "$sync_dir/reviewer.status" ]]; then
            local reviewer_status_line reviewer_agent_status reviewer_agent_timestamp reviewer_agent_message
            reviewer_status_line=$(cat "$sync_dir/reviewer.status" 2>/dev/null)
            IFS='|' read -r reviewer_agent_status reviewer_agent_timestamp reviewer_agent_message <<< "$reviewer_status_line"
            if [[ -n "$reviewer_agent_status" ]]; then
                if [[ -n "$reviewer_agent_message" ]]; then
                    echo "- Reviewer: $reviewer_agent_status - $reviewer_agent_message"
                else
                    echo "- Reviewer: $reviewer_agent_status"
                fi
            fi
        fi
    fi

    # Parse ports file (shell variable format)
    local ports_file="$sync_dir/ports"
    if [[ -f "$ports_file" ]]; then
        echo ""
        echo "**Terminals:**"
        while IFS='=' read -r key value; do
            case "$key" in
                ORCHESTRATOR_PORT)
                    echo "- Orchestrator: http://localhost:$value"
                    ;;
                CODER_PORT)
                    echo "- Coder: http://localhost:$value"
                    ;;
                REVIEWER_PORT)
                    echo "- Reviewer: http://localhost:$value"
                    ;;
            esac
        done < "$ports_file"
    else
        # Fallback to JSON ports file
        local ports_json="$sync_dir/ports.json"
        if [[ -f "$ports_json" ]] && command -v python3 >/dev/null 2>&1; then
            python3 - "$ports_json" <<'PY'
import json,sys
try:
    ports = json.load(open(sys.argv[1]))
    for key,label in [("orchestrator","Orchestrator"),("coder","Coder"),("reviewer","Reviewer")]:
        if key in ports:
            print(f"- {label}: http://localhost:{ports[key]}")
except Exception:
    pass
PY
        fi
    fi

    if [[ -n "$phase" || -n "$round" ]]; then
        echo ""
        echo "**Runtime:**"
        [[ -n "$phase" ]] && echo "- Phase: $phase"
        [[ -n "$round" ]] && echo "- Round: $round"
    fi

    # Display worktree information if available
    local worktrees_file="$sync_dir/worktrees.json"
    if [[ -f "$worktrees_file" ]]; then
        if command -v python3 >/dev/null 2>&1; then
            local worktrees_info
            worktrees_info=$(python3 - "$worktrees_file" <<'PY'
import json,sys
try:
    data = json.load(open(sys.argv[1]))
    if "coder" in data or "reviewer" in data:
        print("yes")
        if "coder" in data:
            print(f"coder:{data['coder']}")
        if "reviewer" in data:
            print(f"reviewer:{data['reviewer']}")
except Exception:
    pass
PY
)
            if [[ -n "$worktrees_info" ]]; then
                echo ""
                echo "**Git:**"
                echo "$worktrees_info" | while IFS=: read -r role path; do
                    [[ "$role" == "yes" ]] && continue
                    echo "- $role worktree: $path"
                done
            fi
        fi
    fi

    # Check for error state
    if [[ -f "$sync_dir/error.log" ]]; then
        local error_count
        error_count=$(wc -l < "$sync_dir/error.log" 2>/dev/null | tr -d ' ')
        if [[ -n "$error_count" && "$error_count" -gt 0 ]]; then
            echo ""
            echo "**Warnings:**"
            echo "- Error log has $error_count entries"
        fi
    fi
}

adapter_agent_solo_start() {
    local project_dir="${1:-.}"
    local task_id="${2:-}"
    local session_name="${3:-}"

    echo "agent-solo start: Use the agent-duo CLI with --mode solo to launch sessions." >&2
    echo "" >&2

    if [[ -n "$task_id" && -n "$session_name" ]]; then
        echo "Suggested command:" >&2
        echo "  cd $project_dir && agent-duo start --mode solo --session $session_name --task $task_id" >&2
    elif [[ -n "$task_id" ]]; then
        echo "Suggested command:" >&2
        echo "  cd $project_dir && agent-duo start --mode solo --task $task_id" >&2
    else
        echo "Usage:" >&2
        echo "  cd $project_dir && agent-duo start --mode solo [--session <name>] [--task <task-id>]" >&2
    fi

    echo "" >&2
    echo "After starting, pai-lite will automatically detect the session via .peer-sync/" >&2
    return 1
}

adapter_agent_solo_stop() {
    local project_dir="${1:-.}"
    local sync_dir="$project_dir/.peer-sync"

    echo "agent-solo stop: Use the agent-duo CLI to stop sessions." >&2
    echo "" >&2

    # Try to provide helpful context
    if [[ -d "$sync_dir" ]]; then
        local session_name=""
        if [[ -f "$sync_dir/state.json" ]] && command -v python3 >/dev/null 2>&1; then
            session_name=$(python3 - "$sync_dir/state.json" <<'PY'
import json,sys
try:
    data = json.load(open(sys.argv[1]))
    print(data.get("session",""))
except Exception:
    pass
PY
)
        elif [[ -f "$sync_dir/session" ]]; then
            session_name=$(cat "$sync_dir/session")
        fi

        if [[ -n "$session_name" ]]; then
            echo "Active session detected: $session_name" >&2
            echo "Suggested command:" >&2
            echo "  cd $project_dir && agent-duo stop --session $session_name" >&2
        else
            echo "Suggested command:" >&2
            echo "  cd $project_dir && agent-duo stop" >&2
        fi
    else
        echo "No active agent-solo session detected in $project_dir" >&2
        echo "Usage:" >&2
        echo "  cd <project-dir> && agent-duo stop [--session <name>]" >&2
    fi

    return 1
}

#------------------------------------------------------------------------------
# Additional helper functions
#------------------------------------------------------------------------------

adapter_agent_solo_watch_phase() {
    local project_dir="${1:-.}"
    local sync_dir="$project_dir/.peer-sync"

    if [[ ! -d "$sync_dir" ]] || { [[ ! -f "$sync_dir/phase" ]] && [[ ! -f "$sync_dir/state.json" ]]; }; then
        echo "No agent-solo session found in $project_dir" >&2
        return 1
    fi

    echo "Watching agent-solo phase changes in $project_dir..."
    echo "Press Ctrl+C to stop."
    echo ""

    local prev_phase="" prev_round="" prev_coder_status="" prev_reviewer_status=""

    while true; do
        if [[ ! -d "$sync_dir" ]]; then
            echo "Session ended (.peer-sync removed)"
            break
        fi

        local phase="" round="" coder_status="" reviewer_status=""

        # Try individual files first
        if [[ -f "$sync_dir/phase" ]]; then
            phase=$(cat "$sync_dir/phase" 2>/dev/null | tr -d '\n')
        fi
        if [[ -f "$sync_dir/round" ]]; then
            round=$(cat "$sync_dir/round" 2>/dev/null | tr -d '\n')
        fi

        # Get agent statuses
        if [[ -f "$sync_dir/coder.status" ]]; then
            local coder_watch_line coder_watch_status coder_watch_timestamp coder_watch_message
            coder_watch_line=$(cat "$sync_dir/coder.status" 2>/dev/null)
            IFS='|' read -r coder_watch_status coder_watch_timestamp coder_watch_message <<< "$coder_watch_line"
            coder_status="$coder_watch_status"
        fi
        if [[ -f "$sync_dir/reviewer.status" ]]; then
            local reviewer_watch_line reviewer_watch_status reviewer_watch_timestamp reviewer_watch_message
            reviewer_watch_line=$(cat "$sync_dir/reviewer.status" 2>/dev/null)
            IFS='|' read -r reviewer_watch_status reviewer_watch_timestamp reviewer_watch_message <<< "$reviewer_watch_line"
            reviewer_status="$reviewer_watch_status"
        fi

        # Fallback to JSON
        if [[ -z "$phase" && -f "$sync_dir/state.json" ]] && command -v python3 >/dev/null 2>&1; then
            read -r phase round <<<"$(python3 - "$sync_dir/state.json" <<'PY'
import json,sys
try:
    data = json.load(open(sys.argv[1]))
    print(data.get("phase",""), data.get("round",""))
except Exception:
    print("", "")
PY
)"
        fi

        if [[ -z "$phase" && -z "$round" ]]; then
            echo "Session ended (no state files)"
            break
        fi

        if [[ "$phase" != "$prev_phase" || "$round" != "$prev_round" || "$coder_status" != "$prev_coder_status" || "$reviewer_status" != "$prev_reviewer_status" ]]; then
            local timestamp
            timestamp=$(date "+%Y-%m-%d %H:%M:%S")
            echo "[$timestamp] Phase: $phase, Round: $round | Coder: ${coder_status:-N/A}, Reviewer: ${reviewer_status:-N/A}"
            prev_phase="$phase"
            prev_round="$round"
            prev_coder_status="$coder_status"
            prev_reviewer_status="$reviewer_status"
        fi

        sleep 5
    done
}

adapter_agent_solo_get_status() {
    local project_dir="${1:-.}"
    local sync_dir="$project_dir/.peer-sync"

    if [[ ! -d "$sync_dir" ]]; then
        echo "inactive"
        return 1
    fi

    local phase="" round=""

    # Try individual files first
    [[ -f "$sync_dir/phase" ]] && phase=$(cat "$sync_dir/phase" 2>/dev/null | tr -d '\n')
    [[ -f "$sync_dir/round" ]] && round=$(cat "$sync_dir/round" 2>/dev/null | tr -d '\n')

    # Fallback to JSON
    if [[ -z "$phase" && -f "$sync_dir/state.json" ]] && command -v python3 >/dev/null 2>&1; then
        read -r phase round <<<"$(python3 - "$sync_dir/state.json" <<'PY'
import json,sys
try:
    data = json.load(open(sys.argv[1]))
    print(data.get("phase",""), data.get("round",""))
except Exception:
    print("", "")
PY
)"
    fi

    if [[ -n "$phase" && -n "$round" ]]; then
        echo "$phase (round $round)"
    elif [[ -n "$phase" ]]; then
        echo "$phase"
    else
        echo "active"
    fi
}
