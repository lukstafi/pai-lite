#!/usr/bin/env bash
set -euo pipefail

# Trigger setup for pai-lite
# Supports: startup, sync, morning (briefing), health, watch (WatchPaths)

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$script_dir/common.sh"

#------------------------------------------------------------------------------
# Config parsing helpers
#------------------------------------------------------------------------------

trigger_get() {
  local trigger="$1" key="$2"
  local config
  config="$(pai_lite_config_path)"
  [[ -f "$config" ]] || pai_lite_die "config not found: $config"

  awk -v trigger="$trigger" -v key="$key" '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    /^[[:space:]]*triggers:/ { in_triggers=1; next }
    in_triggers && $0 ~ /^[[:space:]]{2}[a-zA-Z0-9_-]+:/ {
      current=$0
      sub(/^[[:space:]]*/, "", current)
      sub(/:.*/, "", current)
    }
    in_triggers && current==trigger && $0 ~ "^[[:space:]]*" key ":" {
      value=$0
      sub(/^[^:]+:[[:space:]]*/, "", value)
      print trim(value)
      exit
    }
    in_triggers && $0 !~ /^[[:space:]]/ { in_triggers=0 }
  ' "$config"
}

# Get watch paths array from config
trigger_get_watch_paths() {
  local config
  config="$(pai_lite_config_path)"
  [[ -f "$config" ]] || return 1

  awk '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    /^[[:space:]]*triggers:/ { in_triggers=1; next }
    in_triggers && /^[[:space:]]*watch:/ { in_watch=1; next }
    in_triggers && in_watch && /^[[:space:]]*paths:/ { in_paths=1; next }
    in_triggers && in_watch && in_paths && /^[[:space:]]*-[[:space:]]*/ {
      path=$0
      sub(/^[[:space:]]*-[[:space:]]*/, "", path)
      print trim(path)
    }
    in_triggers && in_watch && in_paths && /^[[:space:]]{4}[^[:space:]-]/ { in_paths=0 }
    in_triggers && in_watch && /^[[:space:]]{2}[^[:space:]]/ && $0 !~ /paths:/ { in_watch=0 }
    in_triggers && /^[^[:space:]]/ { in_triggers=0 }
  ' "$config"
}

command_from_action() {
  local action="$1"
  if [[ -z "$action" ]]; then
    echo "briefing"
  else
    echo "$action"
  fi
}

#------------------------------------------------------------------------------
# Plist/service names
#------------------------------------------------------------------------------

PLIST_STARTUP="com.pai-lite.startup"
PLIST_SYNC="com.pai-lite.sync"
PLIST_MORNING="com.pai-lite.morning"
PLIST_HEALTH="com.pai-lite.health"
PLIST_WATCH="com.pai-lite.watch"
PLIST_FEDERATION="com.pai-lite.federation"

#------------------------------------------------------------------------------
# macOS launchd triggers
#------------------------------------------------------------------------------

# Helper to write program arguments to plist
_plist_write_args() {
  local plist="$1"
  local bin_path="$2"
  shift 2

  echo "  <key>ProgramArguments</key>" >> "$plist"
  echo "  <array>" >> "$plist"
  echo "    <string>$bin_path</string>" >> "$plist"
  for arg in "$@"; do
    echo "    <string>$arg</string>" >> "$plist"
  done
  echo "  </array>" >> "$plist"
}

# Helper to write log paths to plist
_plist_write_logs() {
  local plist="$1"
  local name="$2"

  cat >> "$plist" <<PLIST
  <key>StandardOutPath</key>
  <string>$HOME/Library/Logs/pai-lite-${name}.log</string>
  <key>StandardErrorPath</key>
  <string>$HOME/Library/Logs/pai-lite-${name}.err</string>
PLIST
}

triggers_install_macos() {
  local bin_path
  bin_path="$(pai_lite_root)/bin/pai-lite"
  mkdir -p "$HOME/Library/LaunchAgents"

  local startup_enabled sync_enabled morning_enabled health_enabled watch_enabled federation_enabled
  startup_enabled="$(trigger_get startup enabled)"
  sync_enabled="$(trigger_get sync enabled)"
  morning_enabled="$(trigger_get morning enabled)"
  health_enabled="$(trigger_get health enabled)"
  watch_enabled="$(trigger_get watch enabled)"
  federation_enabled="$(trigger_get federation enabled)"

  # Startup trigger (RunAtLoad)
  if [[ "$startup_enabled" == "true" ]]; then
    local action plist
    action="$(command_from_action "$(trigger_get startup action)")"
    plist="$HOME/Library/LaunchAgents/${PLIST_STARTUP}.plist"
    cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${PLIST_STARTUP}</string>
  <key>RunAtLoad</key>
  <true/>
PLIST
    # shellcheck disable=SC2086
    _plist_write_args "$plist" "$bin_path" $action
    _plist_write_logs "$plist" "startup"
    echo "</dict>" >> "$plist"
    echo "</plist>" >> "$plist"

    launchctl unload "$plist" >/dev/null 2>&1 || true
    launchctl load "$plist" >/dev/null 2>&1 || true
    echo "Installed launchd trigger: startup"
  fi

  # Sync trigger (StartInterval)
  if [[ "$sync_enabled" == "true" ]]; then
    local action interval plist
    action="$(command_from_action "$(trigger_get sync action)")"
    interval="$(trigger_get sync interval)"
    [[ -n "$interval" ]] || interval=3600
    plist="$HOME/Library/LaunchAgents/${PLIST_SYNC}.plist"
    cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${PLIST_SYNC}</string>
  <key>StartInterval</key>
  <integer>$interval</integer>
PLIST
    # shellcheck disable=SC2086
    _plist_write_args "$plist" "$bin_path" $action
    _plist_write_logs "$plist" "sync"
    echo "</dict>" >> "$plist"
    echo "</plist>" >> "$plist"

    launchctl unload "$plist" >/dev/null 2>&1 || true
    launchctl load "$plist" >/dev/null 2>&1 || true
    echo "Installed launchd trigger: sync"
  fi

  # Morning briefing trigger (StartCalendarInterval)
  if [[ "$morning_enabled" == "true" ]]; then
    local action hour minute plist
    action="$(command_from_action "$(trigger_get morning action)")"
    hour="$(trigger_get morning hour)"
    minute="$(trigger_get morning minute)"
    [[ -n "$hour" ]] || hour=8
    [[ -n "$minute" ]] || minute=0
    plist="$HOME/Library/LaunchAgents/${PLIST_MORNING}.plist"
    cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${PLIST_MORNING}</string>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>$hour</integer>
    <key>Minute</key>
    <integer>$minute</integer>
  </dict>
PLIST
    # shellcheck disable=SC2086
    _plist_write_args "$plist" "$bin_path" $action
    _plist_write_logs "$plist" "morning"
    echo "</dict>" >> "$plist"
    echo "</plist>" >> "$plist"

    launchctl unload "$plist" >/dev/null 2>&1 || true
    launchctl load "$plist" >/dev/null 2>&1 || true
    echo "Installed launchd trigger: morning (daily at ${hour}:$(printf '%02d' "$minute"))"
  fi

  # Health check trigger (StartInterval)
  if [[ "$health_enabled" == "true" ]]; then
    local action interval plist
    action="$(command_from_action "$(trigger_get health action)")"
    interval="$(trigger_get health interval)"
    [[ -n "$interval" ]] || interval=14400  # 4 hours default
    plist="$HOME/Library/LaunchAgents/${PLIST_HEALTH}.plist"
    cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${PLIST_HEALTH}</string>
  <key>StartInterval</key>
  <integer>$interval</integer>
PLIST
    # shellcheck disable=SC2086
    _plist_write_args "$plist" "$bin_path" $action
    _plist_write_logs "$plist" "health"
    echo "</dict>" >> "$plist"
    echo "</plist>" >> "$plist"

    launchctl unload "$plist" >/dev/null 2>&1 || true
    launchctl load "$plist" >/dev/null 2>&1 || true
    echo "Installed launchd trigger: health (every $((interval / 3600))h)"
  fi

  # Watch trigger (WatchPaths)
  if [[ "$watch_enabled" == "true" ]]; then
    local action plist
    action="$(command_from_action "$(trigger_get watch action)")"
    plist="$HOME/Library/LaunchAgents/${PLIST_WATCH}.plist"

    # Get watch paths
    local paths=()
    while IFS= read -r path; do
      [[ -n "$path" ]] && paths+=("$path")
    done < <(trigger_get_watch_paths)

    if [[ ${#paths[@]} -gt 0 ]]; then
      cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${PLIST_WATCH}</string>
  <key>WatchPaths</key>
  <array>
PLIST
      for path in "${paths[@]}"; do
        # Expand ~ to HOME
        local expanded_path="${path/#\~/$HOME}"
        echo "    <string>$expanded_path</string>" >> "$plist"
      done
      echo "  </array>" >> "$plist"

      # shellcheck disable=SC2086
      _plist_write_args "$plist" "$bin_path" $action
      _plist_write_logs "$plist" "watch"
      echo "</dict>" >> "$plist"
      echo "</plist>" >> "$plist"

      launchctl unload "$plist" >/dev/null 2>&1 || true
      launchctl load "$plist" >/dev/null 2>&1 || true
      echo "Installed launchd trigger: watch (${#paths[@]} paths)"
    else
      pai_lite_warn "watch trigger enabled but no paths configured"
    fi
  fi

  # Federation trigger (StartInterval - for multi-machine Mayor coordination)
  if [[ "$federation_enabled" == "true" ]]; then
    local action interval plist
    action="$(command_from_action "$(trigger_get federation action)")"
    interval="$(trigger_get federation interval)"
    [[ -n "$interval" ]] || interval=300  # 5 minutes default
    plist="$HOME/Library/LaunchAgents/${PLIST_FEDERATION}.plist"
    cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${PLIST_FEDERATION}</string>
  <key>StartInterval</key>
  <integer>$interval</integer>
PLIST
    # shellcheck disable=SC2086
    _plist_write_args "$plist" "$bin_path" $action
    _plist_write_logs "$plist" "federation"
    echo "</dict>" >> "$plist"
    echo "</plist>" >> "$plist"

    launchctl unload "$plist" >/dev/null 2>&1 || true
    launchctl load "$plist" >/dev/null 2>&1 || true
    echo "Installed launchd trigger: federation (every $((interval / 60))m)"
  fi
}

#------------------------------------------------------------------------------
# Linux systemd triggers
#------------------------------------------------------------------------------

triggers_install_linux() {
  local bin_path
  bin_path="$(pai_lite_root)/bin/pai-lite"
  mkdir -p "$HOME/.config/systemd/user"

  local startup_enabled sync_enabled morning_enabled health_enabled watch_enabled federation_enabled
  startup_enabled="$(trigger_get startup enabled)"
  sync_enabled="$(trigger_get sync enabled)"
  morning_enabled="$(trigger_get morning enabled)"
  health_enabled="$(trigger_get health enabled)"
  watch_enabled="$(trigger_get watch enabled)"
  federation_enabled="$(trigger_get federation enabled)"

  # Startup trigger
  if [[ "$startup_enabled" == "true" ]]; then
    local action service_file
    action="$(command_from_action "$(trigger_get startup action)")"
    service_file="$HOME/.config/systemd/user/pai-lite-startup.service"
    cat > "$service_file" <<SERVICE
[Unit]
Description=pai-lite startup trigger

[Service]
Type=oneshot
ExecStart=$bin_path $action

[Install]
WantedBy=default.target
SERVICE
    systemctl --user daemon-reload
    systemctl --user enable --now pai-lite-startup.service
    echo "Installed systemd trigger: startup"
  fi

  # Sync trigger (periodic timer)
  if [[ "$sync_enabled" == "true" ]]; then
    local action interval service_file timer_file
    action="$(command_from_action "$(trigger_get sync action)")"
    interval="$(trigger_get sync interval)"
    [[ -n "$interval" ]] || interval=3600
    service_file="$HOME/.config/systemd/user/pai-lite-sync.service"
    timer_file="$HOME/.config/systemd/user/pai-lite-sync.timer"
    cat > "$service_file" <<SERVICE
[Unit]
Description=pai-lite sync trigger

[Service]
Type=oneshot
ExecStart=$bin_path $action
SERVICE
    cat > "$timer_file" <<TIMER
[Unit]
Description=pai-lite sync timer

[Timer]
OnUnitActiveSec=${interval}s
Unit=pai-lite-sync.service

[Install]
WantedBy=timers.target
TIMER
    systemctl --user daemon-reload
    systemctl --user enable --now pai-lite-sync.timer
    echo "Installed systemd trigger: sync"
  fi

  # Morning briefing trigger (calendar timer)
  if [[ "$morning_enabled" == "true" ]]; then
    local action hour minute service_file timer_file
    action="$(command_from_action "$(trigger_get morning action)")"
    hour="$(trigger_get morning hour)"
    minute="$(trigger_get morning minute)"
    [[ -n "$hour" ]] || hour=8
    [[ -n "$minute" ]] || minute=0
    service_file="$HOME/.config/systemd/user/pai-lite-morning.service"
    timer_file="$HOME/.config/systemd/user/pai-lite-morning.timer"
    cat > "$service_file" <<SERVICE
[Unit]
Description=pai-lite morning briefing

[Service]
Type=oneshot
ExecStart=$bin_path $action
SERVICE
    cat > "$timer_file" <<TIMER
[Unit]
Description=pai-lite morning briefing timer

[Timer]
OnCalendar=*-*-* ${hour}:$(printf '%02d' "$minute"):00
Persistent=true

[Install]
WantedBy=timers.target
TIMER
    systemctl --user daemon-reload
    systemctl --user enable --now pai-lite-morning.timer
    echo "Installed systemd trigger: morning (daily at ${hour}:$(printf '%02d' "$minute"))"
  fi

  # Health check trigger (periodic timer)
  if [[ "$health_enabled" == "true" ]]; then
    local action interval service_file timer_file
    action="$(command_from_action "$(trigger_get health action)")"
    interval="$(trigger_get health interval)"
    [[ -n "$interval" ]] || interval=14400
    service_file="$HOME/.config/systemd/user/pai-lite-health.service"
    timer_file="$HOME/.config/systemd/user/pai-lite-health.timer"
    cat > "$service_file" <<SERVICE
[Unit]
Description=pai-lite health check

[Service]
Type=oneshot
ExecStart=$bin_path $action
SERVICE
    cat > "$timer_file" <<TIMER
[Unit]
Description=pai-lite health check timer

[Timer]
OnUnitActiveSec=${interval}s
Unit=pai-lite-health.service

[Install]
WantedBy=timers.target
TIMER
    systemctl --user daemon-reload
    systemctl --user enable --now pai-lite-health.timer
    echo "Installed systemd trigger: health (every $((interval / 3600))h)"
  fi

  # Watch trigger (path unit)
  if [[ "$watch_enabled" == "true" ]]; then
    local action
    action="$(command_from_action "$(trigger_get watch action)")"

    # Get watch paths
    local paths=()
    while IFS= read -r path; do
      [[ -n "$path" ]] && paths+=("$path")
    done < <(trigger_get_watch_paths)

    if [[ ${#paths[@]} -gt 0 ]]; then
      local service_file path_file
      service_file="$HOME/.config/systemd/user/pai-lite-watch.service"
      path_file="$HOME/.config/systemd/user/pai-lite-watch.path"

      cat > "$service_file" <<SERVICE
[Unit]
Description=pai-lite watch trigger

[Service]
Type=oneshot
ExecStart=$bin_path $action
SERVICE

      cat > "$path_file" <<PATH
[Unit]
Description=pai-lite watch for file changes

[Path]
PATH
      for path in "${paths[@]}"; do
        # Expand ~ to HOME
        local expanded_path="${path/#\~/$HOME}"
        echo "PathModified=$expanded_path" >> "$path_file"
      done
      cat >> "$path_file" <<PATH
Unit=pai-lite-watch.service

[Install]
WantedBy=default.target
PATH
      systemctl --user daemon-reload
      systemctl --user enable --now pai-lite-watch.path
      echo "Installed systemd trigger: watch (${#paths[@]} paths)"
    else
      pai_lite_warn "watch trigger enabled but no paths configured"
    fi
  fi

  # Federation trigger (periodic timer - for multi-machine Mayor coordination)
  if [[ "$federation_enabled" == "true" ]]; then
    local action interval service_file timer_file
    action="$(command_from_action "$(trigger_get federation action)")"
    interval="$(trigger_get federation interval)"
    [[ -n "$interval" ]] || interval=300  # 5 minutes default
    service_file="$HOME/.config/systemd/user/pai-lite-federation.service"
    timer_file="$HOME/.config/systemd/user/pai-lite-federation.timer"
    cat > "$service_file" <<SERVICE
[Unit]
Description=pai-lite federation heartbeat

[Service]
Type=oneshot
ExecStart=$bin_path $action
SERVICE
    cat > "$timer_file" <<TIMER
[Unit]
Description=pai-lite federation timer

[Timer]
OnUnitActiveSec=${interval}s
Unit=pai-lite-federation.service

[Install]
WantedBy=timers.target
TIMER
    systemctl --user daemon-reload
    systemctl --user enable --now pai-lite-federation.timer
    echo "Installed systemd trigger: federation (every $((interval / 60))m)"
  fi
}

#------------------------------------------------------------------------------
# Install/Uninstall/Status
#------------------------------------------------------------------------------

triggers_install() {
  local uname_out
  uname_out="$(uname -s)"
  case "$uname_out" in
    Darwin)
      triggers_install_macos
      ;;
    Linux)
      if ! command -v systemctl >/dev/null 2>&1; then
        pai_lite_die "systemctl not found; cannot install Linux triggers"
      fi
      triggers_install_linux
      ;;
    *)
      pai_lite_die "unsupported OS for triggers: $uname_out"
      ;;
  esac
}

triggers_uninstall_macos() {
  local agents_dir="$HOME/Library/LaunchAgents"
  local plists=("$PLIST_STARTUP" "$PLIST_SYNC" "$PLIST_MORNING" "$PLIST_HEALTH" "$PLIST_WATCH" "$PLIST_FEDERATION")

  for label in "${plists[@]}"; do
    local plist="$agents_dir/${label}.plist"
    if [[ -f "$plist" ]]; then
      launchctl unload "$plist" >/dev/null 2>&1 || true
      rm -f "$plist"
      echo "Uninstalled launchd trigger: ${label#com.pai-lite.}"
    fi
  done

  echo "All pai-lite launchd triggers uninstalled"
}

triggers_uninstall_linux() {
  local services=("startup" "sync" "morning" "health" "watch" "federation")

  for name in "${services[@]}"; do
    local service_file="$HOME/.config/systemd/user/pai-lite-${name}.service"
    local timer_file="$HOME/.config/systemd/user/pai-lite-${name}.timer"
    local path_file="$HOME/.config/systemd/user/pai-lite-${name}.path"

    if [[ -f "$timer_file" ]]; then
      systemctl --user disable --now "pai-lite-${name}.timer" 2>/dev/null || true
      rm -f "$timer_file"
    fi

    if [[ -f "$path_file" ]]; then
      systemctl --user disable --now "pai-lite-${name}.path" 2>/dev/null || true
      rm -f "$path_file"
    fi

    if [[ -f "$service_file" ]]; then
      systemctl --user disable --now "pai-lite-${name}.service" 2>/dev/null || true
      rm -f "$service_file"
      echo "Uninstalled systemd trigger: $name"
    fi
  done

  systemctl --user daemon-reload
  echo "All pai-lite systemd triggers uninstalled"
}

triggers_uninstall() {
  local uname_out
  uname_out="$(uname -s)"
  case "$uname_out" in
    Darwin)
      triggers_uninstall_macos
      ;;
    Linux)
      if ! command -v systemctl >/dev/null 2>&1; then
        pai_lite_warn "systemctl not found; nothing to uninstall"
        return 0
      fi
      triggers_uninstall_linux
      ;;
    *)
      pai_lite_die "unsupported OS for triggers: $uname_out"
      ;;
  esac
}

triggers_status_macos() {
  local agents_dir="$HOME/Library/LaunchAgents"
  local plists=("$PLIST_STARTUP" "$PLIST_SYNC" "$PLIST_MORNING" "$PLIST_HEALTH" "$PLIST_WATCH" "$PLIST_FEDERATION")
  local found_any=false

  echo "pai-lite launchd triggers:"
  echo ""

  for label in "${plists[@]}"; do
    local plist="$agents_dir/${label}.plist"
    local name="${label#com.pai-lite.}"

    if [[ -f "$plist" ]]; then
      found_any=true
      local status
      if launchctl list "$label" >/dev/null 2>&1; then
        status="loaded"
        # Check if running
        local pid
        pid=$(launchctl list "$label" 2>/dev/null | awk 'NR==2 {print $1}')
        if [[ -n "$pid" && "$pid" != "-" ]]; then
          status="running (PID: $pid)"
        fi
      else
        status="not loaded"
      fi
      printf "  %-10s %s\n" "$name:" "$status"

      # Show last run from log
      local log="$HOME/Library/Logs/pai-lite-${name}.log"
      if [[ -f "$log" ]]; then
        local last_line
        last_line=$(tail -n 1 "$log" 2>/dev/null)
        if [[ -n "$last_line" ]]; then
          printf "             last output: %s\n" "${last_line:0:60}"
        fi
      fi
    fi
  done

  if ! $found_any; then
    echo "  No pai-lite triggers installed"
  fi

  echo ""
  echo "Log files: $HOME/Library/Logs/pai-lite-*.log"
}

triggers_status_linux() {
  local services=("startup" "sync" "morning" "health" "watch" "federation")
  local found_any=false

  echo "pai-lite systemd triggers:"
  echo ""

  for name in "${services[@]}"; do
    local service_file="$HOME/.config/systemd/user/pai-lite-${name}.service"
    local timer_file="$HOME/.config/systemd/user/pai-lite-${name}.timer"
    local path_file="$HOME/.config/systemd/user/pai-lite-${name}.path"

    if [[ -f "$service_file" ]]; then
      found_any=true
      local status unit_type

      if [[ -f "$timer_file" ]]; then
        unit_type="timer"
        status=$(systemctl --user is-active "pai-lite-${name}.timer" 2>/dev/null || echo "inactive")
        # Get next trigger time (may fail if no user bus)
        local next=""
        if next=$(systemctl --user list-timers "pai-lite-${name}.timer" --no-legend 2>/dev/null); then
          next=$(echo "$next" | awk '{print $1, $2}')
        fi
        if [[ -n "$next" ]]; then
          printf "  %-10s %s (next: %s)\n" "$name:" "$status" "$next"
        else
          printf "  %-10s %s\n" "$name:" "$status"
        fi
      elif [[ -f "$path_file" ]]; then
        unit_type="path"
        status=$(systemctl --user is-active "pai-lite-${name}.path" 2>/dev/null || echo "inactive")
        printf "  %-10s %s (watching paths)\n" "$name:" "$status"
      else
        unit_type="service"
        status=$(systemctl --user is-active "pai-lite-${name}.service" 2>/dev/null || echo "inactive")
        printf "  %-10s %s\n" "$name:" "$status"
      fi
    fi
  done

  if ! $found_any; then
    echo "  No pai-lite triggers installed"
  fi

  echo ""
  echo "View logs: journalctl --user -u 'pai-lite-*'"
}

triggers_status() {
  local uname_out
  uname_out="$(uname -s)"
  case "$uname_out" in
    Darwin)
      triggers_status_macos
      ;;
    Linux)
      if ! command -v systemctl >/dev/null 2>&1; then
        pai_lite_warn "systemctl not found"
        return 0
      fi
      triggers_status_linux
      ;;
    *)
      pai_lite_die "unsupported OS for triggers: $uname_out"
      ;;
  esac
}
