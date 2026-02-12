#!/usr/bin/env bash
set -euo pipefail

# Trigger setup for ludics
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
  config="$(ludics_config_path)"
  [[ -f "$config" ]] || ludics_die "config not found: $config"

  local result
  result=$(yq eval ".triggers.${trigger}.${key}" "$config" 2>/dev/null)
  if [[ "$result" != "null" && -n "$result" ]]; then echo "$result"; fi
}

# Get watch rules from config (list format)
# Each rule has paths and an action.
# Output: one line per rule, format: action|path1,path2,...
# Config format:
#   triggers:
#     watch:
#       - paths:
#           - ~/repos/project/README.md
#         action: tasks sync
trigger_get_watch_rules() {
  local config
  config="$(ludics_config_path)"
  [[ -f "$config" ]] || return 1

  local count
  count=$(yq eval '.triggers.watch | length' "$config" 2>/dev/null)
  [[ -n "$count" && "$count" -gt 0 ]] 2>/dev/null || return 0

  local i
  for ((i = 0; i < count; i++)); do
    local action paths_csv
    action=$(yq eval ".triggers.watch[$i].action" "$config" 2>/dev/null)
    [[ "$action" != "null" && -n "$action" ]] || continue
    paths_csv=$(yq eval ".triggers.watch[$i].paths | join(\",\")" "$config" 2>/dev/null)
    [[ "$paths_csv" != "null" && -n "$paths_csv" ]] || continue
    echo "${action}|${paths_csv}"
  done
}

# Sanitize an action string for use in plist/service names
sanitize_action() {
  local action="$1"
  echo "$action" | tr ' ' '-' | tr -cd 'a-zA-Z0-9_-'
}

command_from_action() {
  local action="$1"
  if [[ -z "$action" ]]; then
    echo "mag briefing"
  else
    echo "$action"
  fi
}

#------------------------------------------------------------------------------
# Plist/service names
#------------------------------------------------------------------------------

PLIST_STARTUP="com.ludics.startup"
PLIST_SYNC="com.ludics.sync"
PLIST_MORNING="com.ludics.morning"
PLIST_HEALTH="com.ludics.health"
PLIST_WATCH_PREFIX="com.ludics.watch"
PLIST_FEDERATION="com.ludics.federation"
PLIST_MAG="com.ludics.mag"
PLIST_DASHBOARD="com.ludics.dashboard"

#------------------------------------------------------------------------------
# macOS launchd triggers
#------------------------------------------------------------------------------

# Helper to write PATH environment so launchd finds Homebrew's Bash 4+
_plist_write_env() {
  local plist="$1"
  cat >> "$plist" <<PLIST
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:$HOME/.local/bin</string>
  </dict>
PLIST
}

# Helper to write program arguments to plist
_plist_write_args() {
  local plist="$1"
  local bin_path="$2"
  shift 2

  {
    echo "  <key>ProgramArguments</key>"
    echo "  <array>"
    echo "    <string>$bin_path</string>"
    for arg in "$@"; do
      echo "    <string>$arg</string>"
    done
    echo "  </array>"
  } >> "$plist"
}

# Helper to write log paths to plist
_plist_write_logs() {
  local plist="$1"
  local name="$2"

  cat >> "$plist" <<PLIST
  <key>StandardOutPath</key>
  <string>$HOME/Library/Logs/ludics-${name}.log</string>
  <key>StandardErrorPath</key>
  <string>$HOME/Library/Logs/ludics-${name}.err</string>
PLIST
}

triggers_install_macos() {
  local bin_path
  bin_path="$(ludics_root)/bin/ludics"
  mkdir -p "$HOME/Library/LaunchAgents"

  local startup_enabled sync_enabled morning_enabled health_enabled federation_enabled
  startup_enabled="$(trigger_get startup enabled)"
  sync_enabled="$(trigger_get sync enabled)"
  morning_enabled="$(trigger_get morning enabled)"
  health_enabled="$(trigger_get health enabled)"
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
    _plist_write_env "$plist"
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
    _plist_write_env "$plist"
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
    _plist_write_env "$plist"
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
    _plist_write_env "$plist"
    # shellcheck disable=SC2086
    _plist_write_args "$plist" "$bin_path" $action
    _plist_write_logs "$plist" "health"
    echo "</dict>" >> "$plist"
    echo "</plist>" >> "$plist"

    launchctl unload "$plist" >/dev/null 2>&1 || true
    launchctl load "$plist" >/dev/null 2>&1 || true
    echo "Installed launchd trigger: health (every $((interval / 3600))h)"
  fi

  # Watch triggers (WatchPaths) — one plist per rule
  while IFS='|' read -r rule_action rule_paths_csv; do
    [[ -n "$rule_action" ]] || continue
    local sanitized_action
    sanitized_action="$(sanitize_action "$rule_action")"
    local label="${PLIST_WATCH_PREFIX}-${sanitized_action}"
    local plist="$HOME/Library/LaunchAgents/${label}.plist"

    # Split comma-separated paths
    local paths=()
    IFS=',' read -ra path_array <<< "$rule_paths_csv"
    for p in "${path_array[@]}"; do
      [[ -n "$p" ]] && paths+=("$p")
    done

    if [[ ${#paths[@]} -gt 0 ]]; then
      cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${label}</string>
  <key>WatchPaths</key>
  <array>
PLIST
      for path in "${paths[@]}"; do
        local expanded_path="${path/#\~/$HOME}"
        echo "    <string>$expanded_path</string>" >> "$plist"
      done
      echo "  </array>" >> "$plist"
      _plist_write_env "$plist"

      local action_cmd
      action_cmd="$(command_from_action "$rule_action")"
      # shellcheck disable=SC2086
      _plist_write_args "$plist" "$bin_path" $action_cmd
      _plist_write_logs "$plist" "watch-${sanitized_action}"
      echo "</dict>" >> "$plist"
      echo "</plist>" >> "$plist"

      launchctl unload "$plist" >/dev/null 2>&1 || true
      launchctl load "$plist" >/dev/null 2>&1 || true
      echo "Installed launchd trigger: watch-${sanitized_action} (${#paths[@]} paths)"
    fi
  done < <(trigger_get_watch_rules)

  # Federation trigger (StartInterval - for multi-machine Mag coordination)
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
    _plist_write_env "$plist"
    # shellcheck disable=SC2086
    _plist_write_args "$plist" "$bin_path" $action
    _plist_write_logs "$plist" "federation"
    echo "</dict>" >> "$plist"
    echo "</plist>" >> "$plist"

    launchctl unload "$plist" >/dev/null 2>&1 || true
    launchctl load "$plist" >/dev/null 2>&1 || true
    echo "Installed launchd trigger: federation (every $((interval / 60))m)"
  fi

  # Mag keepalive trigger (RunAtLoad + StartInterval)
  local mag_enabled
  mag_enabled="$(ludics_config_mag_get enabled 2>/dev/null || echo "")"
  if [[ "$mag_enabled" == "true" ]]; then
    local plist mag_interval
    mag_interval=900  # 15 minutes
    plist="$HOME/Library/LaunchAgents/${PLIST_MAG}.plist"
    cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${PLIST_MAG}</string>
  <key>RunAtLoad</key>
  <true/>
  <key>StartInterval</key>
  <integer>$mag_interval</integer>
PLIST
    _plist_write_env "$plist"
    _plist_write_args "$plist" "$bin_path" "mag" "start"
    _plist_write_logs "$plist" "mag"
    echo "</dict>" >> "$plist"
    echo "</plist>" >> "$plist"

    launchctl unload "$plist" >/dev/null 2>&1 || true
    launchctl load "$plist" >/dev/null 2>&1 || true
    echo "Installed launchd trigger: mag (keepalive every 15m)"
  fi

  # Dashboard server trigger (KeepAlive)
  local dashboard_enabled
  dashboard_enabled="$(trigger_get dashboard enabled)"
  if [[ "$dashboard_enabled" == "true" ]]; then
    local dash_port plist
    dash_port="$(trigger_get dashboard port)"
    if [[ -z "$dash_port" ]]; then
      dash_port=$(ludics_config_get_nested "dashboard" "port" 2>/dev/null || echo "")
    fi
    if [[ -z "$dash_port" ]]; then
      dash_port=7678
    fi
    plist="$HOME/Library/LaunchAgents/${PLIST_DASHBOARD}.plist"
    cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${PLIST_DASHBOARD}</string>
  <key>KeepAlive</key>
  <true/>
  <key>RunAtLoad</key>
  <true/>
PLIST
    _plist_write_env "$plist"
    _plist_write_args "$plist" "$bin_path" "dashboard" "serve" "$dash_port"
    _plist_write_logs "$plist" "dashboard"
    echo "</dict>" >> "$plist"
    echo "</plist>" >> "$plist"

    launchctl unload "$plist" >/dev/null 2>&1 || true
    launchctl load "$plist" >/dev/null 2>&1 || true
    echo "Installed launchd trigger: dashboard (port $dash_port, KeepAlive)"
  fi
}

#------------------------------------------------------------------------------
# Linux systemd triggers
#------------------------------------------------------------------------------

triggers_install_linux() {
  local bin_path
  bin_path="$(ludics_root)/bin/ludics"
  mkdir -p "$HOME/.config/systemd/user"

  local startup_enabled sync_enabled morning_enabled health_enabled federation_enabled
  startup_enabled="$(trigger_get startup enabled)"
  sync_enabled="$(trigger_get sync enabled)"
  morning_enabled="$(trigger_get morning enabled)"
  health_enabled="$(trigger_get health enabled)"
  federation_enabled="$(trigger_get federation enabled)"

  # Startup trigger
  if [[ "$startup_enabled" == "true" ]]; then
    local action service_file
    action="$(command_from_action "$(trigger_get startup action)")"
    service_file="$HOME/.config/systemd/user/ludics-startup.service"
    cat > "$service_file" <<SERVICE
[Unit]
Description=ludics startup trigger

[Service]
Type=oneshot
ExecStart=$bin_path $action

[Install]
WantedBy=default.target
SERVICE
    systemctl --user daemon-reload
    systemctl --user enable --now ludics-startup.service
    echo "Installed systemd trigger: startup"
  fi

  # Sync trigger (periodic timer)
  if [[ "$sync_enabled" == "true" ]]; then
    local action interval service_file timer_file
    action="$(command_from_action "$(trigger_get sync action)")"
    interval="$(trigger_get sync interval)"
    [[ -n "$interval" ]] || interval=3600
    service_file="$HOME/.config/systemd/user/ludics-sync.service"
    timer_file="$HOME/.config/systemd/user/ludics-sync.timer"
    cat > "$service_file" <<SERVICE
[Unit]
Description=ludics sync trigger

[Service]
Type=oneshot
ExecStart=$bin_path $action
SERVICE
    cat > "$timer_file" <<TIMER
[Unit]
Description=ludics sync timer

[Timer]
OnUnitActiveSec=${interval}s
Unit=ludics-sync.service

[Install]
WantedBy=timers.target
TIMER
    systemctl --user daemon-reload
    systemctl --user enable --now ludics-sync.timer
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
    service_file="$HOME/.config/systemd/user/ludics-morning.service"
    timer_file="$HOME/.config/systemd/user/ludics-morning.timer"
    cat > "$service_file" <<SERVICE
[Unit]
Description=ludics morning briefing

[Service]
Type=oneshot
ExecStart=$bin_path $action
SERVICE
    cat > "$timer_file" <<TIMER
[Unit]
Description=ludics morning briefing timer

[Timer]
OnCalendar=*-*-* ${hour}:$(printf '%02d' "$minute"):00
Persistent=true

[Install]
WantedBy=timers.target
TIMER
    systemctl --user daemon-reload
    systemctl --user enable --now ludics-morning.timer
    echo "Installed systemd trigger: morning (daily at ${hour}:$(printf '%02d' "$minute"))"
  fi

  # Health check trigger (periodic timer)
  if [[ "$health_enabled" == "true" ]]; then
    local action interval service_file timer_file
    action="$(command_from_action "$(trigger_get health action)")"
    interval="$(trigger_get health interval)"
    [[ -n "$interval" ]] || interval=14400
    service_file="$HOME/.config/systemd/user/ludics-health.service"
    timer_file="$HOME/.config/systemd/user/ludics-health.timer"
    cat > "$service_file" <<SERVICE
[Unit]
Description=ludics health check

[Service]
Type=oneshot
ExecStart=$bin_path $action
SERVICE
    cat > "$timer_file" <<TIMER
[Unit]
Description=ludics health check timer

[Timer]
OnUnitActiveSec=${interval}s
Unit=ludics-health.service

[Install]
WantedBy=timers.target
TIMER
    systemctl --user daemon-reload
    systemctl --user enable --now ludics-health.timer
    echo "Installed systemd trigger: health (every $((interval / 3600))h)"
  fi

  # Watch triggers (path units) — one service+path per rule
  while IFS='|' read -r rule_action rule_paths_csv; do
    [[ -n "$rule_action" ]] || continue
    local sanitized_action
    sanitized_action="$(sanitize_action "$rule_action")"
    local unit_name="ludics-watch-${sanitized_action}"
    local service_file="$HOME/.config/systemd/user/${unit_name}.service"
    local path_file="$HOME/.config/systemd/user/${unit_name}.path"

    # Split comma-separated paths
    local paths=()
    IFS=',' read -ra path_array <<< "$rule_paths_csv"
    for p in "${path_array[@]}"; do
      [[ -n "$p" ]] && paths+=("$p")
    done

    if [[ ${#paths[@]} -gt 0 ]]; then
      local action_cmd
      action_cmd="$(command_from_action "$rule_action")"

      cat > "$service_file" <<SERVICE
[Unit]
Description=ludics watch trigger (${rule_action})

[Service]
Type=oneshot
ExecStart=$bin_path $action_cmd
SERVICE

      cat > "$path_file" <<PATH
[Unit]
Description=ludics watch for file changes (${rule_action})

[Path]
PATH
      for path in "${paths[@]}"; do
        local expanded_path="${path/#\~/$HOME}"
        echo "PathModified=$expanded_path" >> "$path_file"
      done
      cat >> "$path_file" <<PATH
Unit=${unit_name}.service

[Install]
WantedBy=default.target
PATH
      systemctl --user daemon-reload
      systemctl --user enable --now "${unit_name}.path"
      echo "Installed systemd trigger: watch-${sanitized_action} (${#paths[@]} paths)"
    fi
  done < <(trigger_get_watch_rules)

  # Federation trigger (periodic timer - for multi-machine Mag coordination)
  if [[ "$federation_enabled" == "true" ]]; then
    local action interval service_file timer_file
    action="$(command_from_action "$(trigger_get federation action)")"
    interval="$(trigger_get federation interval)"
    [[ -n "$interval" ]] || interval=300  # 5 minutes default
    service_file="$HOME/.config/systemd/user/ludics-federation.service"
    timer_file="$HOME/.config/systemd/user/ludics-federation.timer"
    cat > "$service_file" <<SERVICE
[Unit]
Description=ludics federation heartbeat

[Service]
Type=oneshot
ExecStart=$bin_path $action
SERVICE
    cat > "$timer_file" <<TIMER
[Unit]
Description=ludics federation timer

[Timer]
OnUnitActiveSec=${interval}s
Unit=ludics-federation.service

[Install]
WantedBy=timers.target
TIMER
    systemctl --user daemon-reload
    systemctl --user enable --now ludics-federation.timer
    echo "Installed systemd trigger: federation (every $((interval / 60))m)"
  fi

  # Mag keepalive trigger (boot + periodic timer)
  local mag_enabled
  mag_enabled="$(ludics_config_mag_get enabled 2>/dev/null || echo "")"
  if [[ "$mag_enabled" == "true" ]]; then
    local mag_interval service_file timer_file
    mag_interval=900  # 15 minutes
    service_file="$HOME/.config/systemd/user/ludics-mag.service"
    timer_file="$HOME/.config/systemd/user/ludics-mag.timer"
    cat > "$service_file" <<SERVICE
[Unit]
Description=ludics Mag keepalive

[Service]
Type=oneshot
ExecStart=$bin_path mag start
SERVICE
    cat > "$timer_file" <<TIMER
[Unit]
Description=ludics Mag keepalive timer

[Timer]
OnBootSec=60
OnUnitActiveSec=${mag_interval}s
Unit=ludics-mag.service

[Install]
WantedBy=timers.target
TIMER
    systemctl --user daemon-reload
    systemctl --user enable --now ludics-mag.timer
    echo "Installed systemd trigger: mag (keepalive every 15m)"
  fi

  # Dashboard server trigger (long-running service)
  local dashboard_enabled
  dashboard_enabled="$(trigger_get dashboard enabled)"
  if [[ "$dashboard_enabled" == "true" ]]; then
    local dash_port service_file
    dash_port="$(trigger_get dashboard port)"
    if [[ -z "$dash_port" ]]; then
      dash_port=$(ludics_config_get_nested "dashboard" "port" 2>/dev/null || echo "")
    fi
    if [[ -z "$dash_port" ]]; then
      dash_port=7678
    fi
    service_file="$HOME/.config/systemd/user/ludics-dashboard.service"
    cat > "$service_file" <<SERVICE
[Unit]
Description=ludics dashboard server

[Service]
Type=simple
ExecStart=$bin_path dashboard serve $dash_port
Restart=on-failure

[Install]
WantedBy=default.target
SERVICE
    systemctl --user daemon-reload
    systemctl --user enable --now ludics-dashboard.service
    echo "Installed systemd trigger: dashboard (port $dash_port)"
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
        ludics_die "systemctl not found; cannot install Linux triggers"
      fi
      triggers_install_linux
      ;;
    *)
      ludics_die "unsupported OS for triggers: $uname_out"
      ;;
  esac
}

triggers_uninstall_macos() {
  local agents_dir="$HOME/Library/LaunchAgents"
  local plists=("$PLIST_STARTUP" "$PLIST_SYNC" "$PLIST_MORNING" "$PLIST_HEALTH" "$PLIST_FEDERATION" "$PLIST_MAG" "$PLIST_DASHBOARD")

  for label in "${plists[@]}"; do
    local plist="$agents_dir/${label}.plist"
    if [[ -f "$plist" ]]; then
      launchctl unload "$plist" >/dev/null 2>&1 || true
      rm -f "$plist"
      echo "Uninstalled launchd trigger: ${label#com.ludics.}"
    fi
  done

  # Uninstall all watch-* plists (one per rule)
  for plist in "$agents_dir/${PLIST_WATCH_PREFIX}"-*.plist; do
    [[ -f "$plist" ]] || continue
    local label
    label="$(basename "$plist" .plist)"
    launchctl unload "$plist" >/dev/null 2>&1 || true
    rm -f "$plist"
    echo "Uninstalled launchd trigger: ${label#com.ludics.}"
  done

  echo "All ludics launchd triggers uninstalled"
}

triggers_uninstall_linux() {
  local services=("startup" "sync" "morning" "health" "federation" "mag" "dashboard")

  for name in "${services[@]}"; do
    local service_file="$HOME/.config/systemd/user/ludics-${name}.service"
    local timer_file="$HOME/.config/systemd/user/ludics-${name}.timer"
    local path_file="$HOME/.config/systemd/user/ludics-${name}.path"

    if [[ -f "$timer_file" ]]; then
      systemctl --user disable --now "ludics-${name}.timer" 2>/dev/null || true
      rm -f "$timer_file"
    fi

    if [[ -f "$path_file" ]]; then
      systemctl --user disable --now "ludics-${name}.path" 2>/dev/null || true
      rm -f "$path_file"
    fi

    if [[ -f "$service_file" ]]; then
      systemctl --user disable --now "ludics-${name}.service" 2>/dev/null || true
      rm -f "$service_file"
      echo "Uninstalled systemd trigger: $name"
    fi
  done

  # Uninstall all watch-* units (one per rule)
  local systemd_dir="$HOME/.config/systemd/user"
  for service_file in "$systemd_dir"/ludics-watch-*.service; do
    [[ -f "$service_file" ]] || continue
    local unit_name
    unit_name="$(basename "$service_file" .service)"
    local path_file="$systemd_dir/${unit_name}.path"

    if [[ -f "$path_file" ]]; then
      systemctl --user disable --now "${unit_name}.path" 2>/dev/null || true
      rm -f "$path_file"
    fi
    systemctl --user disable --now "${unit_name}.service" 2>/dev/null || true
    rm -f "$service_file"
    echo "Uninstalled systemd trigger: ${unit_name#ludics-}"
  done

  systemctl --user daemon-reload
  echo "All ludics systemd triggers uninstalled"
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
        ludics_warn "systemctl not found; nothing to uninstall"
        return 0
      fi
      triggers_uninstall_linux
      ;;
    *)
      ludics_die "unsupported OS for triggers: $uname_out"
      ;;
  esac
}

_status_macos_plist() {
  local label="$1" agents_dir="$2"
  local plist="$agents_dir/${label}.plist"
  local name="${label#com.ludics.}"

  [[ -f "$plist" ]] || return 1

  local status
  if launchctl list "$label" >/dev/null 2>&1; then
    status="loaded"
    local pid
    pid=$(launchctl list "$label" 2>/dev/null | awk 'NR==2 {print $1}')
    if [[ -n "$pid" && "$pid" != "-" ]]; then
      status="running (PID: $pid)"
    fi
  else
    status="not loaded"
  fi
  printf "  %-20s %s\n" "$name:" "$status"

  local log="$HOME/Library/Logs/ludics-${name}.log"
  if [[ -f "$log" ]]; then
    local last_line
    last_line=$(tail -n 1 "$log" 2>/dev/null)
    if [[ -n "$last_line" ]]; then
      printf "                       last output: %s\n" "${last_line:0:60}"
    fi
  fi
  return 0
}

triggers_status_macos() {
  local agents_dir="$HOME/Library/LaunchAgents"
  local plists=("$PLIST_STARTUP" "$PLIST_SYNC" "$PLIST_MORNING" "$PLIST_HEALTH" "$PLIST_FEDERATION" "$PLIST_MAG" "$PLIST_DASHBOARD")
  local found_any=false

  echo "ludics launchd triggers:"
  echo ""

  for label in "${plists[@]}"; do
    if _status_macos_plist "$label" "$agents_dir"; then
      found_any=true
    fi
  done

  # Discover watch-* plists
  for plist in "$agents_dir/${PLIST_WATCH_PREFIX}"-*.plist; do
    [[ -f "$plist" ]] || continue
    local label
    label="$(basename "$plist" .plist)"
    if _status_macos_plist "$label" "$agents_dir"; then
      found_any=true
    fi
  done

  if ! $found_any; then
    echo "  No ludics triggers installed"
  fi

  echo ""
  echo "Log files: $HOME/Library/Logs/ludics-*.log"
}

_status_linux_unit() {
  local name="$1"
  local service_file="$HOME/.config/systemd/user/ludics-${name}.service"
  local timer_file="$HOME/.config/systemd/user/ludics-${name}.timer"
  local path_file="$HOME/.config/systemd/user/ludics-${name}.path"

  [[ -f "$service_file" ]] || return 1

  local status

  if [[ -f "$timer_file" ]]; then
    status=$(systemctl --user is-active "ludics-${name}.timer" 2>/dev/null || echo "inactive")
    local next=""
    if next=$(systemctl --user list-timers "ludics-${name}.timer" --no-legend 2>/dev/null); then
      next=$(echo "$next" | awk '{print $1, $2}')
    fi
    if [[ -n "$next" ]]; then
      printf "  %-20s %s (next: %s)\n" "$name:" "$status" "$next"
    else
      printf "  %-20s %s\n" "$name:" "$status"
    fi
  elif [[ -f "$path_file" ]]; then
    status=$(systemctl --user is-active "ludics-${name}.path" 2>/dev/null || echo "inactive")
    printf "  %-20s %s (watching paths)\n" "$name:" "$status"
  else
    status=$(systemctl --user is-active "ludics-${name}.service" 2>/dev/null || echo "inactive")
    printf "  %-20s %s\n" "$name:" "$status"
  fi
  return 0
}

triggers_status_linux() {
  local services=("startup" "sync" "morning" "health" "federation" "mag" "dashboard")
  local found_any=false

  echo "ludics systemd triggers:"
  echo ""

  for name in "${services[@]}"; do
    if _status_linux_unit "$name"; then
      found_any=true
    fi
  done

  # Discover watch-* units
  local systemd_dir="$HOME/.config/systemd/user"
  for service_file in "$systemd_dir"/ludics-watch-*.service; do
    [[ -f "$service_file" ]] || continue
    local unit_name
    unit_name="$(basename "$service_file" .service)"
    local name="${unit_name#ludics-}"
    if _status_linux_unit "$name"; then
      found_any=true
    fi
  done

  if ! $found_any; then
    echo "  No ludics triggers installed"
  fi

  echo ""
  echo "View logs: journalctl --user -u 'ludics-*'"
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
        ludics_warn "systemctl not found"
        return 0
      fi
      triggers_status_linux
      ;;
    *)
      ludics_die "unsupported OS for triggers: $uname_out"
      ;;
  esac
}
