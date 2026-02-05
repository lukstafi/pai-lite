#!/usr/bin/env bash
set -euo pipefail

# pai-lite/lib/federation.sh - Mayor federation with seniority-based leader election
# Enables multiple machines to coordinate Mayor responsibilities via heartbeats
# and automatic leader election based on a configured seniority order.

#------------------------------------------------------------------------------
# Constants
#------------------------------------------------------------------------------

HEARTBEAT_INTERVAL="${PAI_LITE_HEARTBEAT_INTERVAL:-300}"  # 5 minutes default
HEARTBEAT_TIMEOUT="${PAI_LITE_HEARTBEAT_TIMEOUT:-900}"    # 15 minutes = stale

#------------------------------------------------------------------------------
# Directory helpers
#------------------------------------------------------------------------------

federation_dir() {
  echo "$(pai_lite_state_harness_dir)/federation"
}

federation_heartbeats_dir() {
  echo "$(federation_dir)/heartbeats"
}

federation_leader_file() {
  echo "$(federation_dir)/leader.json"
}

#------------------------------------------------------------------------------
# Heartbeat functions
#------------------------------------------------------------------------------

# Publish heartbeat for current node
# Usage: federation_heartbeat_publish
federation_heartbeat_publish() {
  local node_name
  node_name="$(pai_lite_network_current_node 2>/dev/null || echo "")"

  if [[ -z "$node_name" ]]; then
    # If we can't determine node name, try to use tailscale hostname directly
    local ts_hostname
    ts_hostname="$(pai_lite_network_hostname_tailscale 2>/dev/null || echo "")"
    if [[ -z "$ts_hostname" ]]; then
      pai_lite_warn "federation: cannot determine current node name"
      pai_lite_warn "  - ensure tailscale is running and this machine is in network.nodes config"
      return 1
    fi
    # Use hostname as node name if not in config
    node_name="$ts_hostname"
  fi

  local heartbeats_dir heartbeat_file
  heartbeats_dir="$(federation_heartbeats_dir)"
  mkdir -p "$heartbeats_dir"
  heartbeat_file="$heartbeats_dir/${node_name}.json"

  # Check if Mayor is running locally
  local mayor_running="false"
  if command -v tmux >/dev/null 2>&1; then
    local mayor_session
    mayor_session="${PAI_LITE_MAYOR_SESSION:-pai-mayor}"
    if tmux has-session -t "$mayor_session" 2>/dev/null; then
      mayor_running="true"
    fi
  fi

  # Write heartbeat
  local timestamp epoch
  timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  epoch="$(date +%s)"

  if command -v jq >/dev/null 2>&1; then
    jq -n \
      --arg node "$node_name" \
      --arg timestamp "$timestamp" \
      --argjson epoch "$epoch" \
      --argjson mayor_running "$mayor_running" \
      '{
        node: $node,
        timestamp: $timestamp,
        epoch: $epoch,
        mayor_running: $mayor_running
      }' > "$heartbeat_file"
  else
    # Fallback without jq
    cat > "$heartbeat_file" <<EOF
{"node":"$node_name","timestamp":"$timestamp","epoch":$epoch,"mayor_running":$mayor_running}
EOF
  fi

  pai_lite_info "federation: published heartbeat for $node_name"
  return 0
}

# Check if a node's heartbeat is fresh (not stale)
# Usage: federation_heartbeat_is_fresh <node_name>
federation_heartbeat_is_fresh() {
  local node_name="$1"
  local heartbeat_file
  heartbeat_file="$(federation_heartbeats_dir)/${node_name}.json"

  [[ -f "$heartbeat_file" ]] || return 1

  local heartbeat_epoch now_epoch age
  if command -v jq >/dev/null 2>&1; then
    heartbeat_epoch=$(jq -r '.epoch // 0' "$heartbeat_file" 2>/dev/null)
  else
    # Fallback: extract epoch with grep/sed
    heartbeat_epoch=$(grep -o '"epoch":[0-9]*' "$heartbeat_file" 2>/dev/null | grep -o '[0-9]*' || echo "0")
  fi
  now_epoch=$(date +%s)
  age=$((now_epoch - heartbeat_epoch))

  [[ $age -lt $HEARTBEAT_TIMEOUT ]]
}

# Check if a node has Mayor running
# Usage: federation_node_has_mayor <node_name>
federation_node_has_mayor() {
  local node_name="$1"
  local heartbeat_file
  heartbeat_file="$(federation_heartbeats_dir)/${node_name}.json"

  [[ -f "$heartbeat_file" ]] || return 1

  local mayor_running
  if command -v jq >/dev/null 2>&1; then
    mayor_running=$(jq -r '.mayor_running // false' "$heartbeat_file" 2>/dev/null)
  else
    # Fallback
    if grep -q '"mayor_running":true' "$heartbeat_file" 2>/dev/null; then
      mayor_running="true"
    else
      mayor_running="false"
    fi
  fi
  [[ "$mayor_running" == "true" ]]
}

# Get list of online nodes (fresh heartbeats)
federation_online_nodes() {
  local heartbeats_dir
  heartbeats_dir="$(federation_heartbeats_dir)"

  [[ -d "$heartbeats_dir" ]] || return 0

  for heartbeat_file in "$heartbeats_dir"/*.json; do
    [[ -f "$heartbeat_file" ]] || continue
    local node_name
    node_name="$(basename "$heartbeat_file" .json)"
    if federation_heartbeat_is_fresh "$node_name"; then
      echo "$node_name"
    fi
  done
}

#------------------------------------------------------------------------------
# Leader election (seniority-based)
#------------------------------------------------------------------------------

# Determine who should be leader based on seniority and online status
# Returns: node name of rightful leader
federation_compute_leader() {
  # Get all configured nodes in seniority order
  local nodes=()
  while IFS= read -r node; do
    [[ -n "$node" ]] && nodes+=("$node")
  done < <(pai_lite_network_nodes)

  # If no nodes configured, no federation
  if [[ ${#nodes[@]} -eq 0 ]]; then
    return 1
  fi

  # Return first online node (highest seniority that's online)
  for node in "${nodes[@]}"; do
    if federation_heartbeat_is_fresh "$node"; then
      echo "$node"
      return 0
    fi
  done

  # No online nodes
  return 1
}

# Get current leader from state file
federation_current_leader() {
  local leader_file
  leader_file="$(federation_leader_file)"

  [[ -f "$leader_file" ]] || return 1

  if command -v jq >/dev/null 2>&1; then
    jq -r '.node // empty' "$leader_file" 2>/dev/null
  else
    grep -o '"node":"[^"]*"' "$leader_file" 2>/dev/null | sed 's/.*"\([^"]*\)"$/\1/'
  fi
}

# Get current term from state file
federation_current_term() {
  local leader_file
  leader_file="$(federation_leader_file)"

  [[ -f "$leader_file" ]] || { echo "0"; return; }

  if command -v jq >/dev/null 2>&1; then
    jq -r '.term // 0' "$leader_file" 2>/dev/null
  else
    grep -o '"term":[0-9]*' "$leader_file" 2>/dev/null | grep -o '[0-9]*' || echo "0"
  fi
}

# Update leader file if election result changed
# Usage: federation_update_leader <new_leader>
federation_update_leader() {
  local new_leader="$1"
  local leader_file leader_dir
  leader_file="$(federation_leader_file)"
  leader_dir="$(dirname "$leader_file")"
  mkdir -p "$leader_dir"

  local current_leader term
  current_leader="$(federation_current_leader 2>/dev/null || echo "")"

  if [[ "$current_leader" != "$new_leader" ]]; then
    # Leader changed - increment term
    term=$(federation_current_term)
    term=$((term + 1))

    local timestamp
    timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

    if command -v jq >/dev/null 2>&1; then
      jq -n \
        --arg node "$new_leader" \
        --arg elected "$timestamp" \
        --argjson term "$term" \
        '{
          node: $node,
          elected: $elected,
          term: $term
        }' > "$leader_file"
    else
      cat > "$leader_file" <<EOF
{"node":"$new_leader","elected":"$timestamp","term":$term}
EOF
    fi

    pai_lite_info "federation: new leader elected: $new_leader (term $term)"

    # Journal the leadership change
    pai_lite_journal_append "federation" "leader changed to $new_leader (term $term)" 2>/dev/null || true

    return 0
  fi

  return 1  # No change
}

# Run leader election and update state
federation_elect() {
  local new_leader
  if new_leader="$(federation_compute_leader)"; then
    federation_update_leader "$new_leader" || true
    echo "$new_leader"
  else
    pai_lite_warn "federation: no online nodes available for leader election"
    return 1
  fi
}

# Check if current node is the leader
federation_is_leader() {
  local current_node current_leader
  current_node="$(pai_lite_network_current_node 2>/dev/null || echo "")"
  [[ -z "$current_node" ]] && return 1

  current_leader="$(federation_current_leader 2>/dev/null || echo "")"
  [[ "$current_node" == "$current_leader" ]]
}

# Check if current node should start/stop Mayor based on leadership
# Returns 0 if should run Mayor, 1 if should not
federation_should_run_mayor() {
  # If federation not configured (no nodes), always allow Mayor
  local node_count
  node_count=$(pai_lite_network_nodes | wc -l | tr -d ' ')
  [[ "$node_count" -eq 0 ]] && return 0

  federation_is_leader
}

#------------------------------------------------------------------------------
# Federation tick (heartbeat + election, called periodically)
#------------------------------------------------------------------------------

federation_tick() {
  pai_lite_info "federation: running tick..."

  # Sync state from remote first
  pai_lite_state_pull 2>/dev/null || true

  # Publish our heartbeat
  federation_heartbeat_publish || true

  # Run election
  local leader
  if leader=$(federation_elect 2>/dev/null); then
    pai_lite_info "federation: current leader is $leader"
  fi

  # Commit and push changes
  pai_lite_state_commit "federation heartbeat" 2>/dev/null || true
  pai_lite_state_push 2>/dev/null || true

  pai_lite_info "federation: tick complete"
}

#------------------------------------------------------------------------------
# Status display
#------------------------------------------------------------------------------

federation_status() {
  echo "=== Federation Status ==="
  echo ""

  # Current node
  local current_node
  current_node="$(pai_lite_network_current_node 2>/dev/null || echo "unknown")"
  echo "Current node: $current_node"

  # Current leader
  local current_leader
  current_leader="$(federation_current_leader 2>/dev/null || echo "none")"
  local current_term
  current_term="$(federation_current_term 2>/dev/null || echo "0")"
  echo "Current leader: $current_leader (term $current_term)"

  # Am I the leader?
  if federation_is_leader 2>/dev/null; then
    echo "Leadership: THIS NODE IS LEADER"
  else
    echo "Leadership: follower"
  fi

  echo ""
  echo "Configured nodes (by seniority):"
  local rank=0
  while IFS= read -r node; do
    [[ -z "$node" ]] && continue
    ((rank++)) || true
    local status="offline"
    local heartbeat_age=""

    local heartbeat_file
    heartbeat_file="$(federation_heartbeats_dir)/${node}.json"
    if [[ -f "$heartbeat_file" ]]; then
      local heartbeat_epoch now_epoch age
      if command -v jq >/dev/null 2>&1; then
        heartbeat_epoch=$(jq -r '.epoch // 0' "$heartbeat_file" 2>/dev/null)
      else
        heartbeat_epoch=$(grep -o '"epoch":[0-9]*' "$heartbeat_file" 2>/dev/null | grep -o '[0-9]*' || echo "0")
      fi
      now_epoch=$(date +%s)
      age=$((now_epoch - heartbeat_epoch))

      if federation_heartbeat_is_fresh "$node"; then
        status="online"
        if federation_node_has_mayor "$node"; then
          status="online (mayor running)"
        fi
        local mins=$((age / 60))
        heartbeat_age=" [${mins}m ago]"
      else
        local mins=$((age / 60))
        status="stale [${mins}m ago]"
      fi
    fi

    local leader_marker=""
    [[ "$node" == "$current_leader" ]] && leader_marker=" *LEADER*"

    echo "  $rank. $node - $status$heartbeat_age$leader_marker"
  done < <(pai_lite_network_nodes)

  if [[ $rank -eq 0 ]]; then
    echo "  (no nodes configured in network.nodes)"
    echo ""
    echo "Federation is disabled - Mayor will run on any machine."
  fi

  # Show should-run-mayor status
  echo ""
  if federation_should_run_mayor 2>/dev/null; then
    echo "Mayor permission: ALLOWED (this node should run Mayor)"
  else
    echo "Mayor permission: BLOCKED (defer to leader)"
  fi
}
