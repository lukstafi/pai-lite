#!/usr/bin/env bash
set -euo pipefail

# pai-lite/lib/network.sh - Network configuration and URL helpers
# Supports localhost mode and Tailscale mode for multi-machine deployments

#------------------------------------------------------------------------------
# Network mode and hostname detection
#------------------------------------------------------------------------------

# Get network mode: localhost | tailscale
pai_lite_network_mode() {
  local mode
  mode="$(pai_lite_config_get_nested "network" "mode" 2>/dev/null || echo "")"
  [[ -n "$mode" ]] && echo "$mode" || echo "localhost"
}

# Get explicit hostname from config (may be empty)
pai_lite_network_hostname_config() {
  pai_lite_config_get_nested "network" "hostname" 2>/dev/null || echo ""
}

# Get hostname from tailscale status (auto-detect)
# Returns the MagicDNS hostname if tailscale is running
pai_lite_network_hostname_tailscale() {
  if ! command -v tailscale >/dev/null 2>&1; then
    return 1
  fi

  # Use tailscale status --json to get hostname
  local ts_status hostname
  if ts_status=$(tailscale status --json 2>/dev/null); then
    # Extract Self.DNSName (ends with trailing dot, remove it)
    hostname=$(echo "$ts_status" | jq -r '.Self.DNSName // empty' 2>/dev/null)
    if [[ -n "$hostname" ]]; then
      echo "${hostname%.}"
      return 0
    fi

    # Fallback: try Self.HostName + tailnet name
    hostname=$(echo "$ts_status" | jq -r '.Self.HostName // empty' 2>/dev/null)
    if [[ -n "$hostname" ]]; then
      echo "$hostname"
      return 0
    fi
  fi

  return 1
}

# Get the effective hostname for URL generation
# Resolution order:
# 1. If mode=localhost, return "localhost"
# 2. If mode=tailscale:
#    a. Try tailscale status --json auto-detect
#    b. Fall back to config hostname
#    c. Fail if neither available
pai_lite_network_hostname() {
  local mode
  mode="$(pai_lite_network_mode)"

  if [[ "$mode" == "localhost" ]]; then
    echo "localhost"
    return 0
  fi

  if [[ "$mode" == "tailscale" ]]; then
    # Try auto-detect first
    local ts_hostname
    if ts_hostname="$(pai_lite_network_hostname_tailscale 2>/dev/null)" && [[ -n "$ts_hostname" ]]; then
      echo "$ts_hostname"
      return 0
    fi

    # Fall back to config
    local config_hostname
    config_hostname="$(pai_lite_network_hostname_config)"
    if [[ -n "$config_hostname" ]]; then
      echo "$config_hostname"
      return 0
    fi

    # Neither available - fail
    pai_lite_warn "tailscale mode enabled but cannot determine hostname"
    pai_lite_warn "  - tailscale status failed or not available"
    pai_lite_warn "  - network.hostname not set in config"
    return 1
  fi

  # Unknown mode, default to localhost
  echo "localhost"
}

#------------------------------------------------------------------------------
# URL generation helper
#------------------------------------------------------------------------------

# Generate a URL with the correct hostname
# Usage: pai_lite_get_url <port> [protocol]
# Example: pai_lite_get_url 7679 -> "http://mac-mini.ts.net:7679"
pai_lite_get_url() {
  local port="$1"
  local protocol="${2:-http}"
  local hostname

  if ! hostname="$(pai_lite_network_hostname)"; then
    # Fallback to localhost if hostname detection fails
    hostname="localhost"
  fi

  echo "${protocol}://${hostname}:${port}"
}

#------------------------------------------------------------------------------
# Node management for federation
#------------------------------------------------------------------------------

# Get list of node names (in seniority order)
pai_lite_network_nodes() {
  local config
  config="$(pai_lite_config_path)"
  [[ -f "$config" ]] || return 0

  awk '
    /^[[:space:]]*network:/ { in_network=1; next }
    in_network && /^[[:space:]]*nodes:/ { in_nodes=1; next }
    in_network && in_nodes && /^[[:space:]]*-[[:space:]]*name:/ {
      sub(/^[^:]+:[[:space:]]*/, "")
      gsub(/[[:space:]]+$/, "")
      gsub(/^["'"'"']|["'"'"']$/, "")
      print
    }
    in_network && in_nodes && /^[[:space:]]{2}[^[:space:]-]/ && !/^[[:space:]]*-/ { in_nodes=0 }
    in_network && /^[^[:space:]]/ { in_network=0 }
  ' "$config"
}

# Get tailscale hostname for a node by name
pai_lite_network_node_hostname() {
  local node_name="$1"
  local config
  config="$(pai_lite_config_path)"
  [[ -f "$config" ]] || return 1

  awk -v name="$node_name" '
    BEGIN { current_name = "" }
    /^[[:space:]]*network:/ { in_network=1; next }
    in_network && /^[[:space:]]*nodes:/ { in_nodes=1; next }
    in_network && in_nodes && /^[[:space:]]*-[[:space:]]*name:/ {
      sub(/^[^:]+:[[:space:]]*/, "")
      gsub(/[[:space:]]+$/, "")
      gsub(/^["'"'"']|["'"'"']$/, "")
      current_name = $0
    }
    in_network && in_nodes && current_name == name && /^[[:space:]]*tailscale_hostname:/ {
      sub(/^[^:]+:[[:space:]]*/, "")
      gsub(/[[:space:]]+$/, "")
      gsub(/^["'"'"']|["'"'"']$/, "")
      print
      exit
    }
    in_network && in_nodes && /^[[:space:]]{2}[^[:space:]-]/ && !/^[[:space:]]*-/ { in_nodes=0 }
    in_network && /^[^[:space:]]/ { in_network=0 }
  ' "$config"
}

# Get seniority rank of a node (1 = highest, higher numbers = lower seniority)
pai_lite_network_node_seniority() {
  local node_name="$1"
  local rank=0
  local found=0

  while IFS= read -r name; do
    ((rank++)) || true
    if [[ "$name" == "$node_name" ]]; then
      found=1
      break
    fi
  done < <(pai_lite_network_nodes)

  if [[ $found -eq 1 ]]; then
    echo "$rank"
  else
    echo "999"  # Unknown node gets lowest seniority
  fi
}

# Get current machine's node name (by matching tailscale hostname)
pai_lite_network_current_node() {
  local current_hostname
  current_hostname="$(pai_lite_network_hostname_tailscale 2>/dev/null || echo "")"
  [[ -z "$current_hostname" ]] && return 1

  local config
  config="$(pai_lite_config_path)"
  [[ -f "$config" ]] || return 1

  # Search for matching node
  while IFS= read -r node_name; do
    local node_hostname
    node_hostname="$(pai_lite_network_node_hostname "$node_name")"
    # Compare without trailing dots
    local normalized_current="${current_hostname%.}"
    local normalized_node="${node_hostname%.}"
    if [[ "$normalized_node" == "$normalized_current" ]]; then
      echo "$node_name"
      return 0
    fi
  done < <(pai_lite_network_nodes)

  return 1
}

#------------------------------------------------------------------------------
# Network status display
#------------------------------------------------------------------------------

# Show network configuration status
pai_lite_network_status() {
  echo "=== Network Status ==="
  echo ""

  local mode
  mode="$(pai_lite_network_mode)"
  echo "Mode: $mode"

  if [[ "$mode" == "tailscale" ]]; then
    # Check tailscale availability
    if command -v tailscale >/dev/null 2>&1; then
      echo "Tailscale CLI: available"
      local ts_hostname
      if ts_hostname="$(pai_lite_network_hostname_tailscale 2>/dev/null)"; then
        echo "Tailscale hostname: $ts_hostname"
      else
        echo "Tailscale hostname: (not connected or unavailable)"
      fi
    else
      echo "Tailscale CLI: not installed"
    fi

    local config_hostname
    config_hostname="$(pai_lite_network_hostname_config)"
    if [[ -n "$config_hostname" ]]; then
      echo "Config hostname: $config_hostname"
    fi
  fi

  local effective_hostname
  if effective_hostname="$(pai_lite_network_hostname 2>/dev/null)"; then
    echo ""
    echo "Effective hostname: $effective_hostname"
    echo "Example URL: $(pai_lite_get_url 7679)"
  fi

  # Show configured nodes
  local node_count=0
  echo ""
  echo "Configured nodes (by seniority):"
  while IFS= read -r node_name; do
    [[ -z "$node_name" ]] && continue
    ((node_count++)) || true
    local node_hostname
    node_hostname="$(pai_lite_network_node_hostname "$node_name" || echo "(not set)")"
    echo "  $node_count. $node_name -> $node_hostname"
  done < <(pai_lite_network_nodes)

  if [[ $node_count -eq 0 ]]; then
    echo "  (no nodes configured)"
  fi

  # Show current node identification
  local current_node
  if current_node="$(pai_lite_network_current_node 2>/dev/null)"; then
    echo ""
    echo "This machine: $current_node (seniority: $(pai_lite_network_node_seniority "$current_node"))"
  fi
}
