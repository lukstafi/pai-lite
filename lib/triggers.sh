#!/usr/bin/env bash
set -euo pipefail

# Trigger setup for pai-lite

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$script_dir/common.sh"

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

command_from_action() {
  local action="$1"
  if [[ -z "$action" ]]; then
    echo "briefing"
  else
    echo "$action"
  fi
}

triggers_install_macos() {
  local bin_path
  bin_path="$(pai_lite_root)/bin/pai-lite"
  mkdir -p "$HOME/Library/LaunchAgents"

  local startup_enabled sync_enabled
  startup_enabled="$(trigger_get startup enabled)"
  sync_enabled="$(trigger_get sync enabled)"

  if [[ "$startup_enabled" == "true" ]]; then
    local action plist
    action="$(command_from_action "$(trigger_get startup action)")"
    plist="$HOME/Library/LaunchAgents/com.pai-lite.startup.plist"
    cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.pai-lite.startup</string>
  <key>RunAtLoad</key>
  <true/>
  <key>ProgramArguments</key>
  <array>
    <string>$bin_path</string>
PLIST
    for arg in $action; do
      echo "    <string>$arg</string>" >> "$plist"
    done
    cat >> "$plist" <<PLIST
  </array>
  <key>StandardOutPath</key>
  <string>$HOME/Library/Logs/pai-lite-startup.log</string>
  <key>StandardErrorPath</key>
  <string>$HOME/Library/Logs/pai-lite-startup.err</string>
</dict>
</plist>
PLIST

    launchctl unload "$plist" >/dev/null 2>&1 || true
    launchctl load "$plist" >/dev/null 2>&1 || true
    echo "Installed launchd trigger: startup"
  fi

  if [[ "$sync_enabled" == "true" ]]; then
    local action interval plist
    action="$(command_from_action "$(trigger_get sync action)")"
    interval="$(trigger_get sync interval)"
    [[ -n "$interval" ]] || interval=3600
    plist="$HOME/Library/LaunchAgents/com.pai-lite.sync.plist"
    cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.pai-lite.sync</string>
  <key>StartInterval</key>
  <integer>$interval</integer>
  <key>ProgramArguments</key>
  <array>
    <string>$bin_path</string>
PLIST
    for arg in $action; do
      echo "    <string>$arg</string>" >> "$plist"
    done
    cat >> "$plist" <<PLIST
  </array>
  <key>StandardOutPath</key>
  <string>$HOME/Library/Logs/pai-lite-sync.log</string>
  <key>StandardErrorPath</key>
  <string>$HOME/Library/Logs/pai-lite-sync.err</string>
</dict>
</plist>
PLIST

    launchctl unload "$plist" >/dev/null 2>&1 || true
    launchctl load "$plist" >/dev/null 2>&1 || true
    echo "Installed launchd trigger: sync"
  fi
}

triggers_install_linux() {
  local bin_path
  bin_path="$(pai_lite_root)/bin/pai-lite"
  mkdir -p "$HOME/.config/systemd/user"

  local startup_enabled sync_enabled
  startup_enabled="$(trigger_get startup enabled)"
  sync_enabled="$(trigger_get sync enabled)"

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
SERVICE
    systemctl --user daemon-reload
    systemctl --user enable --now pai-lite-startup.service
    echo "Installed systemd trigger: startup"
  fi

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
OnUnitActiveSec=$interval
Unit=pai-lite-sync.service

[Install]
WantedBy=timers.target
TIMER
    systemctl --user daemon-reload
    systemctl --user enable --now pai-lite-sync.timer
    echo "Installed systemd trigger: sync"
  fi
}

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
