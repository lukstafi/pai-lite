#!/usr/bin/env bash
# pai-lite/adapters/claude-code.sh - Claude Code (CLI) integration
# Tracks tmux sessions running Claude Code

#------------------------------------------------------------------------------
# tmux session detection
#------------------------------------------------------------------------------

# Check if tmux is available
has_tmux() {
    command -v tmux &>/dev/null
}

# List all tmux sessions
list_tmux_sessions() {
    has_tmux || return 1
    tmux list-sessions -F "#{session_name}" 2>/dev/null
}

# Check if a tmux session exists
tmux_session_exists() {
    local session_name="$1"
    has_tmux || return 1
    tmux has-session -t "$session_name" 2>/dev/null
}

# Get the current working directory of a tmux session
tmux_session_cwd() {
    local session_name="$1"
    has_tmux || return 1

    # Get the pane's current path
    tmux display-message -t "$session_name" -p "#{pane_current_path}" 2>/dev/null
}

# Check if Claude Code is running in a tmux session
# (looks for 'claude' process or characteristic patterns)
is_claude_code_session() {
    local session_name="$1"
    has_tmux || return 1

    # Capture pane content and look for Claude Code indicators
    local pane_content
    pane_content="$(tmux capture-pane -t "$session_name" -p 2>/dev/null)"

    # Look for Claude Code patterns
    if echo "$pane_content" | grep -qE '(claude>|Claude Code|anthropic|/compact|/help)'; then
        return 0
    fi

    # Check if claude process is running in the session's pane
    local pane_pid
    pane_pid="$(tmux display-message -t "$session_name" -p "#{pane_pid}" 2>/dev/null)"
    if [[ -n "$pane_pid" ]]; then
        # Check child processes for 'claude'
        if pgrep -P "$pane_pid" -f "claude" &>/dev/null; then
            return 0
        fi
    fi

    return 1
}

# Find Claude Code sessions
find_claude_code_sessions() {
    has_tmux || return 1

    list_tmux_sessions | while read -r session; do
        if is_claude_code_session "$session"; then
            echo "$session"
        fi
    done
}

#------------------------------------------------------------------------------
# Adapter interface for pai-lite
#------------------------------------------------------------------------------

adapter_claude_code_status() {
    local slot_num="$1"

    # Get session name from slot
    local session
    session="$(slot_get_field "$slot_num" "session")"

    if [[ -z "$session" ]]; then
        # Try to find by checking terminals field
        local terminal_info
        terminal_info="$(slot_get_field "$slot_num" "terminal_item" | grep -i "tmux\|claude")"
        if [[ "$terminal_info" =~ session[[:space:]]+[\`\']?([a-zA-Z0-9_-]+) ]]; then
            session="${BASH_REMATCH[1]}"
        fi
    fi

    if [[ -z "$session" ]]; then
        echo "    No tmux session configured"
        return 1
    fi

    if ! has_tmux; then
        echo "    tmux not available"
        return 1
    fi

    if tmux_session_exists "$session"; then
        echo "    Session: $session"
        echo "    Status: ${GREEN}running${NC}"

        local cwd
        cwd="$(tmux_session_cwd "$session")"
        [[ -n "$cwd" ]] && echo "    Directory: $cwd"

        # Check if Claude Code is active
        if is_claude_code_session "$session"; then
            echo "    Claude Code: ${GREEN}active${NC}"
        else
            echo "    Claude Code: ${YELLOW}not detected${NC}"
        fi
    else
        echo "    Session: $session"
        echo "    Status: ${YELLOW}not running${NC}"
    fi
}

adapter_claude_code_start() {
    local slot_num="$1"

    if ! has_tmux; then
        die "tmux is required for claude-code adapter"
    fi

    if ! command -v claude &>/dev/null; then
        die "claude command not found. Install Claude Code first."
    fi

    # Get or create session name
    local session
    session="$(slot_get_field "$slot_num" "session")"

    if [[ -z "$session" ]]; then
        # Generate session name from process
        local process
        process="$(slot_get_field "$slot_num" "process")"
        session="$(echo "$process" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-')"
        session="${session:-slot$slot_num}"
    fi

    # Get working directory
    local work_dir
    work_dir="$(slot_get_field "$slot_num" "git_item" | grep -E "^(Base|Branch):" | head -1 | sed 's/.*:[[:space:]]*//')"
    work_dir="${work_dir/#\~/$HOME}"

    if [[ -z "$work_dir" || ! -d "$work_dir" ]]; then
        work_dir="$HOME"
    fi

    if tmux_session_exists "$session"; then
        info "attaching to existing session: $session"
        tmux attach-session -t "$session"
    else
        info "creating new tmux session: $session"
        info "starting Claude Code in $work_dir"

        # Create session and start Claude Code
        tmux new-session -d -s "$session" -c "$work_dir"
        tmux send-keys -t "$session" "claude" Enter

        # Attach to the session
        tmux attach-session -t "$session"
    fi
}

adapter_claude_code_stop() {
    local slot_num="$1"

    if ! has_tmux; then
        return 0
    fi

    local session
    session="$(slot_get_field "$slot_num" "session")"

    if [[ -z "$session" ]]; then
        warn "no session to stop"
        return 0
    fi

    if tmux_session_exists "$session"; then
        info "killing tmux session: $session"

        # Send quit command to Claude Code first
        tmux send-keys -t "$session" "/exit" Enter 2>/dev/null || true
        sleep 1

        # Kill the session
        tmux kill-session -t "$session" 2>/dev/null || true

        success "stopped session: $session"
    else
        info "session not running: $session"
    fi
}

#------------------------------------------------------------------------------
# Discovery: Find and report Claude Code sessions
#------------------------------------------------------------------------------

adapter_claude_code_discover() {
    echo -e "${BOLD}Claude Code Sessions${NC}"
    echo ""

    if ! has_tmux; then
        echo "  tmux not available"
        return 0
    fi

    local found=false
    while read -r session; do
        [[ -z "$session" ]] && continue
        found=true

        local cwd
        cwd="$(tmux_session_cwd "$session")"

        echo -e "  ${GREEN}$session${NC}"
        [[ -n "$cwd" ]] && echo "    directory: $cwd"

        # Try to detect what project
        if [[ -n "$cwd" && -d "$cwd/.git" ]]; then
            local branch
            branch="$(git -C "$cwd" branch --show-current 2>/dev/null)"
            [[ -n "$branch" ]] && echo "    branch: $branch"
        fi
        echo ""
    done < <(find_claude_code_sessions)

    $found || echo "  No Claude Code sessions found"
}

#------------------------------------------------------------------------------
# Quick attach helper
#------------------------------------------------------------------------------

# Attach to a Claude Code session by name or slot
adapter_claude_code_attach() {
    local target="$1"

    if ! has_tmux; then
        die "tmux not available"
    fi

    # If target is a number, treat as slot number
    if [[ "$target" =~ ^[1-6]$ ]]; then
        local session
        session="$(slot_get_field "$target" "session")"
        [[ -z "$session" ]] && die "no session for slot $target"
        target="$session"
    fi

    if tmux_session_exists "$target"; then
        tmux attach-session -t "$target"
    else
        die "session not found: $target"
    fi
}
