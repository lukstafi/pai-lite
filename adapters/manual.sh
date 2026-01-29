#!/usr/bin/env bash
# pai-lite/adapters/manual.sh - Manual (human-only) mode
# For tracking work done without AI agents

#------------------------------------------------------------------------------
# Adapter interface for pai-lite
#------------------------------------------------------------------------------

adapter_manual_status() {
    local slot_num="$1"

    echo "    Mode: Manual (no agent)"
    echo "    This slot tracks human-only work."
    echo ""

    # Show runtime notes if any
    local runtime
    runtime="$(slot_get_field "$slot_num" "runtime_item" 2>/dev/null)"
    if [[ -n "$runtime" ]]; then
        echo "    Notes:"
        echo "$runtime" | while read -r item; do
            echo "      - $item"
        done
    fi
}

adapter_manual_start() {
    local slot_num="$1"

    info "Manual mode - no agent to start"
    echo ""
    echo "This slot is for tracking work you do yourself."
    echo "Use 'pai-lite slot $slot_num note \"...\"' to track progress."
}

adapter_manual_stop() {
    local slot_num="$1"

    info "Manual mode - nothing to stop"
    echo "Use 'pai-lite slot $slot_num clear' to clear this slot when done."
}
