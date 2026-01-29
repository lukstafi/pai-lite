#!/usr/bin/env bash
# pai-lite/lib/triggers.sh - System trigger setup
# Supports macOS (launchd) and Linux (systemd)

# Requires: CONFIG_FILE, SCRIPT_DIR to be set by the main script

#------------------------------------------------------------------------------
# Platform detection
#------------------------------------------------------------------------------

detect_platform() {
    case "$(uname -s)" in
        Darwin)
            echo "macos"
            ;;
        Linux)
            if command -v systemctl &>/dev/null; then
                echo "linux-systemd"
            else
                echo "linux-other"
            fi
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

readonly PLATFORM="$(detect_platform)"

#------------------------------------------------------------------------------
# Paths
#------------------------------------------------------------------------------

# macOS LaunchAgents directory
launchd_dir() {
    echo "$HOME/Library/LaunchAgents"
}

# Linux systemd user directory
systemd_dir() {
    echo "$HOME/.config/systemd/user"
}

# pai-lite binary path
pai_lite_bin() {
    echo "$SCRIPT_DIR/pai-lite"
}

#------------------------------------------------------------------------------
# macOS launchd implementation
#------------------------------------------------------------------------------

launchd_plist_startup() {
    local action="$1"
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.pai-lite.startup</string>
    <key>ProgramArguments</key>
    <array>
        <string>$(pai_lite_bin)</string>
        <string>$action</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$HOME/.pai-lite/logs/startup.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/.pai-lite/logs/startup.err</string>
</dict>
</plist>
EOF
}

launchd_plist_sync() {
    local action="$1"
    local interval="$2"
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.pai-lite.sync</string>
    <key>ProgramArguments</key>
    <array>
        <string>$(pai_lite_bin)</string>
        <string>${action%% *}</string>
        <string>${action#* }</string>
    </array>
    <key>StartInterval</key>
    <integer>$interval</integer>
    <key>StandardOutPath</key>
    <string>$HOME/.pai-lite/logs/sync.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/.pai-lite/logs/sync.err</string>
</dict>
</plist>
EOF
}

install_launchd_triggers() {
    local agents_dir
    agents_dir="$(launchd_dir)"
    mkdir -p "$agents_dir"
    mkdir -p "$HOME/.pai-lite/logs"

    # Read trigger settings from config
    local startup_enabled=false
    local startup_action="briefing"
    local sync_enabled=false
    local sync_interval=3600
    local sync_action="tasks sync"

    local in_triggers=false
    local in_startup=false
    local in_sync=false

    while IFS= read -r line; do
        if [[ "$line" =~ ^triggers: ]]; then
            in_triggers=true
            continue
        fi

        if $in_triggers; then
            # Exit triggers section at non-indented line
            if [[ "$line" =~ ^[a-z] && ! "$line" =~ ^[[:space:]] ]]; then
                in_triggers=false
                continue
            fi

            if [[ "$line" =~ ^[[:space:]]*startup: ]]; then
                in_startup=true
                in_sync=false
                continue
            elif [[ "$line" =~ ^[[:space:]]*sync: ]]; then
                in_sync=true
                in_startup=false
                continue
            fi

            if $in_startup; then
                if [[ "$line" =~ enabled:[[:space:]]*(true|yes) ]]; then
                    startup_enabled=true
                elif [[ "$line" =~ action:[[:space:]]*(.+) ]]; then
                    startup_action="${BASH_REMATCH[1]}"
                fi
            fi

            if $in_sync; then
                if [[ "$line" =~ enabled:[[:space:]]*(true|yes) ]]; then
                    sync_enabled=true
                elif [[ "$line" =~ interval:[[:space:]]*([0-9]+) ]]; then
                    sync_interval="${BASH_REMATCH[1]}"
                elif [[ "$line" =~ action:[[:space:]]*(.+) ]]; then
                    sync_action="${BASH_REMATCH[1]}"
                fi
            fi
        fi
    done < "$CONFIG_FILE"

    local installed=0

    # Install startup trigger
    if $startup_enabled; then
        local plist_file="$agents_dir/com.pai-lite.startup.plist"
        launchd_plist_startup "$startup_action" > "$plist_file"

        # Unload if already loaded, then load
        launchctl unload "$plist_file" 2>/dev/null || true
        launchctl load "$plist_file"

        info "installed startup trigger: $plist_file"
        ((installed++))
    fi

    # Install sync trigger
    if $sync_enabled; then
        local plist_file="$agents_dir/com.pai-lite.sync.plist"
        launchd_plist_sync "$sync_action" "$sync_interval" > "$plist_file"

        launchctl unload "$plist_file" 2>/dev/null || true
        launchctl load "$plist_file"

        info "installed sync trigger: $plist_file (every ${sync_interval}s)"
        ((installed++))
    fi

    if [[ $installed -eq 0 ]]; then
        warn "no triggers enabled in config"
        echo "Enable triggers in your config.yaml:"
        echo "  triggers:"
        echo "    startup:"
        echo "      enabled: true"
    else
        success "installed $installed trigger(s)"
    fi
}

uninstall_launchd_triggers() {
    local agents_dir
    agents_dir="$(launchd_dir)"

    local removed=0

    for plist in com.pai-lite.startup.plist com.pai-lite.sync.plist; do
        local plist_file="$agents_dir/$plist"
        if [[ -f "$plist_file" ]]; then
            launchctl unload "$plist_file" 2>/dev/null || true
            rm "$plist_file"
            info "removed: $plist_file"
            ((removed++))
        fi
    done

    if [[ $removed -eq 0 ]]; then
        info "no triggers installed"
    else
        success "removed $removed trigger(s)"
    fi
}

status_launchd_triggers() {
    echo -e "${BOLD}Trigger Status (macOS launchd)${NC}"
    echo ""

    local agents_dir
    agents_dir="$(launchd_dir)"

    for trigger in startup sync; do
        local plist_file="$agents_dir/com.pai-lite.${trigger}.plist"
        local label="com.pai-lite.${trigger}"

        echo -n "  $trigger: "
        if [[ -f "$plist_file" ]]; then
            if launchctl list "$label" &>/dev/null; then
                echo -e "${GREEN}active${NC}"
            else
                echo -e "${YELLOW}installed but not loaded${NC}"
            fi
        else
            echo -e "${YELLOW}not installed${NC}"
        fi
    done

    # Show recent logs if available
    echo ""
    echo -e "${BOLD}Recent Logs:${NC}"
    for log in startup sync; do
        local logfile="$HOME/.pai-lite/logs/${log}.log"
        if [[ -f "$logfile" ]]; then
            echo "  $log: $(tail -1 "$logfile" 2>/dev/null || echo "(empty)")"
        fi
    done
}

#------------------------------------------------------------------------------
# Linux systemd implementation
#------------------------------------------------------------------------------

systemd_service_startup() {
    local action="$1"
    cat <<EOF
[Unit]
Description=pai-lite startup briefing
After=network.target

[Service]
Type=oneshot
ExecStart=$(pai_lite_bin) $action

[Install]
WantedBy=default.target
EOF
}

systemd_service_sync() {
    local action="$1"
    cat <<EOF
[Unit]
Description=pai-lite task sync

[Service]
Type=oneshot
ExecStart=$(pai_lite_bin) $action
EOF
}

systemd_timer_sync() {
    local interval="$1"
    # Convert seconds to systemd OnUnitActiveSec format
    cat <<EOF
[Unit]
Description=pai-lite task sync timer

[Timer]
OnBootSec=60
OnUnitActiveSec=${interval}s
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

install_systemd_triggers() {
    local user_dir
    user_dir="$(systemd_dir)"
    mkdir -p "$user_dir"
    mkdir -p "$HOME/.pai-lite/logs"

    # Read trigger settings from config (same parsing as launchd)
    local startup_enabled=false
    local startup_action="briefing"
    local sync_enabled=false
    local sync_interval=3600
    local sync_action="tasks sync"

    local in_triggers=false
    local in_startup=false
    local in_sync=false

    while IFS= read -r line; do
        if [[ "$line" =~ ^triggers: ]]; then
            in_triggers=true
            continue
        fi

        if $in_triggers; then
            if [[ "$line" =~ ^[a-z] && ! "$line" =~ ^[[:space:]] ]]; then
                in_triggers=false
                continue
            fi

            if [[ "$line" =~ ^[[:space:]]*startup: ]]; then
                in_startup=true
                in_sync=false
                continue
            elif [[ "$line" =~ ^[[:space:]]*sync: ]]; then
                in_sync=true
                in_startup=false
                continue
            fi

            if $in_startup; then
                if [[ "$line" =~ enabled:[[:space:]]*(true|yes) ]]; then
                    startup_enabled=true
                elif [[ "$line" =~ action:[[:space:]]*(.+) ]]; then
                    startup_action="${BASH_REMATCH[1]}"
                fi
            fi

            if $in_sync; then
                if [[ "$line" =~ enabled:[[:space:]]*(true|yes) ]]; then
                    sync_enabled=true
                elif [[ "$line" =~ interval:[[:space:]]*([0-9]+) ]]; then
                    sync_interval="${BASH_REMATCH[1]}"
                elif [[ "$line" =~ action:[[:space:]]*(.+) ]]; then
                    sync_action="${BASH_REMATCH[1]}"
                fi
            fi
        fi
    done < "$CONFIG_FILE"

    local installed=0

    # Install startup service
    if $startup_enabled; then
        local service_file="$user_dir/pai-lite-startup.service"
        systemd_service_startup "$startup_action" > "$service_file"

        systemctl --user daemon-reload
        systemctl --user enable pai-lite-startup.service

        info "installed startup service: $service_file"
        ((installed++))
    fi

    # Install sync service and timer
    if $sync_enabled; then
        local service_file="$user_dir/pai-lite-sync.service"
        local timer_file="$user_dir/pai-lite-sync.timer"

        systemd_service_sync "$sync_action" > "$service_file"
        systemd_timer_sync "$sync_interval" > "$timer_file"

        systemctl --user daemon-reload
        systemctl --user enable pai-lite-sync.timer
        systemctl --user start pai-lite-sync.timer

        info "installed sync timer: $timer_file (every ${sync_interval}s)"
        ((installed++))
    fi

    if [[ $installed -eq 0 ]]; then
        warn "no triggers enabled in config"
    else
        success "installed $installed trigger(s)"
    fi
}

uninstall_systemd_triggers() {
    local user_dir
    user_dir="$(systemd_dir)"

    local removed=0

    # Stop and disable startup service
    if systemctl --user is-enabled pai-lite-startup.service &>/dev/null; then
        systemctl --user disable pai-lite-startup.service
        rm -f "$user_dir/pai-lite-startup.service"
        info "removed startup service"
        ((removed++))
    fi

    # Stop and disable sync timer
    if systemctl --user is-enabled pai-lite-sync.timer &>/dev/null; then
        systemctl --user stop pai-lite-sync.timer
        systemctl --user disable pai-lite-sync.timer
        rm -f "$user_dir/pai-lite-sync.timer"
        rm -f "$user_dir/pai-lite-sync.service"
        info "removed sync timer and service"
        ((removed++))
    fi

    systemctl --user daemon-reload

    if [[ $removed -eq 0 ]]; then
        info "no triggers installed"
    else
        success "removed $removed trigger(s)"
    fi
}

status_systemd_triggers() {
    echo -e "${BOLD}Trigger Status (Linux systemd)${NC}"
    echo ""

    echo -n "  startup: "
    if systemctl --user is-enabled pai-lite-startup.service &>/dev/null; then
        echo -e "${GREEN}enabled${NC}"
    else
        echo -e "${YELLOW}not installed${NC}"
    fi

    echo -n "  sync: "
    if systemctl --user is-active pai-lite-sync.timer &>/dev/null; then
        echo -e "${GREEN}active${NC}"
        # Show next trigger time
        local next
        next="$(systemctl --user show pai-lite-sync.timer --property=NextElapseUSecRealtime 2>/dev/null | cut -d= -f2)"
        [[ -n "$next" ]] && echo "    next: $next"
    elif systemctl --user is-enabled pai-lite-sync.timer &>/dev/null; then
        echo -e "${YELLOW}enabled but not running${NC}"
    else
        echo -e "${YELLOW}not installed${NC}"
    fi

    # Show recent journal entries
    echo ""
    echo -e "${BOLD}Recent Logs:${NC}"
    journalctl --user -u 'pai-lite-*' --no-pager -n 5 2>/dev/null || echo "  (no logs available)"
}

#------------------------------------------------------------------------------
# Platform-agnostic interface
#------------------------------------------------------------------------------

triggers_install() {
    case "$PLATFORM" in
        macos)
            install_launchd_triggers
            ;;
        linux-systemd)
            install_systemd_triggers
            ;;
        *)
            die "unsupported platform for triggers: $PLATFORM"
            ;;
    esac
}

triggers_uninstall() {
    case "$PLATFORM" in
        macos)
            uninstall_launchd_triggers
            ;;
        linux-systemd)
            uninstall_systemd_triggers
            ;;
        *)
            die "unsupported platform for triggers: $PLATFORM"
            ;;
    esac
}

triggers_status() {
    case "$PLATFORM" in
        macos)
            status_launchd_triggers
            ;;
        linux-systemd)
            status_systemd_triggers
            ;;
        *)
            echo "Platform: $PLATFORM"
            echo "Triggers not supported on this platform."
            ;;
    esac
}
