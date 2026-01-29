#!/usr/bin/env bash
# pai-lite/adapters/claude-ai.sh - Claude.ai browser integration
# Manages URL bookmarks for browser-based Claude conversations

# This adapter is simpler than others - it just tracks URLs
# since we can't programmatically control the browser.

#------------------------------------------------------------------------------
# URL storage
#------------------------------------------------------------------------------

# Store URLs in the slot's runtime notes
# Format: "Claude.ai: https://claude.ai/chat/xxx"

#------------------------------------------------------------------------------
# Adapter interface for pai-lite
#------------------------------------------------------------------------------

adapter_claude_ai_status() {
    local slot_num="$1"

    # Look for Claude.ai URL in terminals or runtime
    local url
    url="$(slot_get_field "$slot_num" "terminal_item" | grep -i "claude.ai" | head -1)"

    if [[ -z "$url" ]]; then
        url="$(slot_get_field "$slot_num" "runtime_item" | grep -i "claude.ai" | head -1)"
    fi

    if [[ -n "$url" ]]; then
        echo "    Mode: Browser conversation"
        echo "    URL: $url"
        echo ""
        echo "    (Open URL in browser to continue conversation)"
    else
        echo "    No Claude.ai URL configured"
        echo "    Use 'pai-lite slot $slot_num note \"Claude.ai: <url>\"' to add"
    fi
}

adapter_claude_ai_start() {
    local slot_num="$1"

    # Look for existing URL
    local url
    url="$(slot_get_field "$slot_num" "terminal_item" | grep -oE "https://claude.ai/[^ ]*" | head -1)"

    if [[ -z "$url" ]]; then
        url="$(slot_get_field "$slot_num" "runtime_item" | grep -oE "https://claude.ai/[^ ]*" | head -1)"
    fi

    if [[ -n "$url" ]]; then
        info "opening Claude.ai conversation..."
        open_url "$url"
    else
        # Start a new conversation
        info "opening Claude.ai..."
        open_url "https://claude.ai/new"

        echo ""
        echo "After starting your conversation, save the URL with:"
        echo "  pai-lite slot $slot_num note \"Claude.ai: <paste-url-here>\""
    fi
}

adapter_claude_ai_stop() {
    local slot_num="$1"

    # Nothing to stop for browser sessions
    info "browser sessions cannot be stopped programmatically"
    echo "Close the browser tab manually."
}

#------------------------------------------------------------------------------
# URL opening (cross-platform)
#------------------------------------------------------------------------------

open_url() {
    local url="$1"

    case "$(uname -s)" in
        Darwin)
            open "$url"
            ;;
        Linux)
            if command -v xdg-open &>/dev/null; then
                xdg-open "$url"
            elif command -v gnome-open &>/dev/null; then
                gnome-open "$url"
            else
                echo "Please open manually: $url"
            fi
            ;;
        *)
            echo "Please open manually: $url"
            ;;
    esac
}

#------------------------------------------------------------------------------
# Helper: Extract conversation ID from URL
#------------------------------------------------------------------------------

parse_claude_ai_url() {
    local url="$1"

    if [[ "$url" =~ claude.ai/chat/([a-f0-9-]+) ]]; then
        echo "${BASH_REMATCH[1]}"
    fi
}

#------------------------------------------------------------------------------
# Quick reference: How to use this adapter
#------------------------------------------------------------------------------

adapter_claude_ai_help() {
    cat <<EOF
${BOLD}Claude.ai Adapter${NC}

This adapter tracks browser-based Claude conversations.

${BOLD}Usage:${NC}

1. Assign a task to a slot with claude-ai mode:
   pai-lite slot 2 assign "research#42"

2. Add the Claude.ai URL after starting a conversation:
   pai-lite slot 2 note "Claude.ai: https://claude.ai/chat/abc123"

3. Later, open the conversation:
   pai-lite slot 2 start

${BOLD}Tips:${NC}
- Keep the URL in your slot notes for easy access
- The URL format is: https://claude.ai/chat/<conversation-id>
- New conversations start at: https://claude.ai/new

EOF
}
