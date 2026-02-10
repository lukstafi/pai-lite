#!/usr/bin/env bash
set -euo pipefail

# pai-lite/lib/sessions.sh - Pervasive session discovery
#
# Scans shared session stores (Codex, Claude Code) and tmux to discover
# all active agent sessions, regardless of how they were started.
# Classifies sessions into slots by longest-prefix cwd matching.
# Outputs a sessions report for Mayor consumption.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$script_dir/common.sh"
# shellcheck source=lib/slots.sh
source "$script_dir/slots.sh"

#------------------------------------------------------------------------------
# Configuration
#------------------------------------------------------------------------------

# Seconds of inactivity before a session is considered stale (default: 24h)
SESSIONS_STALE_THRESHOLD="${SESSIONS_STALE_THRESHOLD:-86400}"

# Codex home directory
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"

# Claude Code projects directory
CLAUDE_PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"

# Check for jq availability — used for JSONL parsing
_SESSIONS_HAS_JQ=false
if command -v jq >/dev/null 2>&1; then
  _SESSIONS_HAS_JQ=true
fi

#------------------------------------------------------------------------------
# Session record format (tab-separated fields, one per line):
#   agent_type \t cwd \t session_id \t source \t mtime_epoch \t extra_json
#
# agent_type: codex | claude-code | tmux | ttyd
# source: cli | vscode | appServer | app | unknown
# extra_json: {"key":"value",...} with agent-specific metadata
#------------------------------------------------------------------------------

# Accumulator for discovered sessions (newline-separated records)
_SESSIONS_RAW=""

sessions_add_record() {
  local agent_type="$1" cwd="$2" session_id="$3" source_kind="$4" mtime_epoch="$5"
  local extra_json="${6:-}"
  [[ -n "$extra_json" ]] || extra_json='{}'
  # Normalize: strip trailing slash from cwd
  cwd="${cwd%/}"
  local record
  record=$(printf '%s\t%s\t%s\t%s\t%s\t%s' \
    "$agent_type" "$cwd" "$session_id" "$source_kind" "$mtime_epoch" "$extra_json")
  if [[ -z "$_SESSIONS_RAW" ]]; then
    _SESSIONS_RAW="$record"
  else
    _SESSIONS_RAW+=$'\n'"$record"
  fi
}

#------------------------------------------------------------------------------
# Codex session discovery
# Layout: $CODEX_HOME/sessions/YYYY/MM/DD/rollout-<timestamp>-<uuid>.jsonl
# First line: {"type":"session_meta","payload":{"id":...,"cwd":...,"source":...}}
#------------------------------------------------------------------------------

sessions_discover_codex() {
  local sessions_dir="$CODEX_HOME/sessions"
  [[ -d "$sessions_dir" ]] || return 0
  [[ "$_SESSIONS_HAS_JQ" == true ]] || return 0

  local now
  now=$(date +%s)

  # Find JSONL files modified within the stale threshold
  while IFS= read -r -d '' jsonl_file; do
    local mtime_epoch
    # macOS stat vs GNU stat
    if stat -f '%m' /dev/null >/dev/null 2>&1; then
      mtime_epoch=$(stat -f '%m' "$jsonl_file")
    else
      mtime_epoch=$(stat -c '%Y' "$jsonl_file")
    fi

    # Skip stale sessions
    local age=$(( now - mtime_epoch ))
    if (( age > SESSIONS_STALE_THRESHOLD )); then
      continue
    fi

    # Read first line to try session_meta parsing
    local first_line
    first_line=$(head -n 1 "$jsonl_file" 2>/dev/null) || continue
    [[ -n "$first_line" ]] || continue

    local session_id="" cwd="" source_kind=""

    # Try session_meta first (standard Codex format)
    local parsed
    parsed=$(printf '%s' "$first_line" | jq -r '
      if .type == "session_meta" then
        [.payload.id // "", .payload.cwd // "", .payload.source // "unknown"] | @tsv
      else
        empty
      end
    ' 2>/dev/null) || true

    if [[ -n "$parsed" ]]; then
      session_id=$(printf '%s' "$parsed" | cut -f1)
      cwd=$(printf '%s' "$parsed" | cut -f2)
      source_kind=$(printf '%s' "$parsed" | cut -f3)
    fi

    # Fallback: scan first 20 lines for any entry with cwd
    if [[ -z "$cwd" ]]; then
      local fallback
      fallback=$(head -n 20 "$jsonl_file" | jq -r -s '
        [.[] | select(.cwd != null or .payload.cwd != null)] | first |
        [(.id // .payload.id // ""), (.cwd // .payload.cwd // ""), (.source // .payload.source // "unknown")] | @tsv
      ' 2>/dev/null) || true
      if [[ -n "$fallback" ]]; then
        session_id=$(printf '%s' "$fallback" | cut -f1)
        cwd=$(printf '%s' "$fallback" | cut -f2)
        source_kind=$(printf '%s' "$fallback" | cut -f3)
      fi
    fi

    [[ -n "$cwd" ]] || continue

    # Use filename-based ID as fallback
    if [[ -z "$session_id" ]]; then
      session_id=$(basename "$jsonl_file" .jsonl)
    fi

    # Build extra metadata
    local extra
    extra=$(printf '%s' "$first_line" | jq -c --arg file "$jsonl_file" '{
      cli_version: (.payload.cli_version // null),
      model_provider: (.payload.model_provider // null),
      file: $file
    }' 2>/dev/null) || extra="{}"

    sessions_add_record "codex" "$cwd" "$session_id" "${source_kind:-unknown}" "$mtime_epoch" "$extra"
  done < <(find "$sessions_dir" -name '*.jsonl' -type f -print0 2>/dev/null)
}

#------------------------------------------------------------------------------
# Claude Code session discovery
# Layout: $CLAUDE_PROJECTS_DIR/<encoded-path>/sessions-index.json
#   has entries[] with: sessionId, projectPath, created, modified, gitBranch, summary
# Fallback: scan <encoded-path>/*.jsonl, read first entry with parentUuid:null for cwd
#------------------------------------------------------------------------------

sessions_discover_claude_code() {
  [[ -d "$CLAUDE_PROJECTS_DIR" ]] || return 0
  [[ "$_SESSIONS_HAS_JQ" == true ]] || return 0

  local now
  now=$(date +%s)

  # Iterate over project directories
  for project_dir in "$CLAUDE_PROJECTS_DIR"/*/; do
    [[ -d "$project_dir" ]] || continue
    local index_file="$project_dir/sessions-index.json"

    if [[ -f "$index_file" ]]; then
      # Use sessions-index.json (rich metadata)
      _sessions_claude_from_index "$index_file" "$project_dir" "$now"
    else
      # Fallback: scan JSONL files directly
      _sessions_claude_from_jsonl "$project_dir" "$now"
    fi
  done
}

_sessions_claude_from_index() {
  local index_file="$1" project_dir="$2" now="$3"

  # Extract originalPath from index
  local original_path
  original_path=$(jq -r '.originalPath // empty' "$index_file" 2>/dev/null)

  # Use process substitution to avoid subshell (pipe | while runs in subshell,
  # losing _SESSIONS_RAW modifications)
  local entries
  entries=$(jq -c '.entries[]?' "$index_file" 2>/dev/null) || return 0
  [[ -n "$entries" ]] || return 0

  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue

    local session_id modified_ms modified_epoch cwd

    session_id=$(printf '%s' "$entry" | jq -r '.sessionId // empty')
    [[ -n "$session_id" ]] || continue

    # modified is in milliseconds epoch
    modified_ms=$(printf '%s' "$entry" | jq -r '.fileMtime // .modified // empty')
    if [[ -n "$modified_ms" ]]; then
      # Convert ms to seconds if it looks like ms (>1e12)
      if (( ${modified_ms%%.*} > 1000000000000 )); then
        modified_epoch=$(( ${modified_ms%%.*} / 1000 ))
      else
        modified_epoch="${modified_ms%%.*}"
      fi
    else
      modified_epoch="$now"
    fi

    # Skip stale sessions
    local age=$(( now - modified_epoch ))
    if (( age > SESSIONS_STALE_THRESHOLD )); then
      continue
    fi

    cwd=$(printf '%s' "$entry" | jq -r '.projectPath // empty')
    [[ -n "$cwd" ]] || cwd="$original_path"
    [[ -n "$cwd" ]] || continue

    local extra
    extra=$(printf '%s' "$entry" | jq -c '{
      git_branch: (.gitBranch // null),
      summary: (.summary // null),
      message_count: (.messageCount // null),
      is_sidechain: (.isSidechain // false)
    }' 2>/dev/null) || extra="{}"

    sessions_add_record "claude-code" "$cwd" "$session_id" "unknown" "$modified_epoch" "$extra"
  done <<< "$entries"
}

_sessions_claude_from_jsonl() {
  local project_dir="$1" now="$2"

  while IFS= read -r -d '' jsonl_file; do
    local mtime_epoch
    if stat -f '%m' /dev/null >/dev/null 2>&1; then
      mtime_epoch=$(stat -f '%m' "$jsonl_file")
    else
      mtime_epoch=$(stat -c '%Y' "$jsonl_file")
    fi

    local age=$(( now - mtime_epoch ))
    if (( age > SESSIONS_STALE_THRESHOLD )); then
      continue
    fi

    # Find the first entry with cwd (typically the root entry with parentUuid:null)
    local parsed
    parsed=$(head -n 20 "$jsonl_file" | jq -r -s '
      [.[] | select(.cwd != null)] | first |
      [(.sessionId // ""), (.cwd // "")] | @tsv
    ' 2>/dev/null) || continue
    [[ -n "$parsed" ]] || continue

    local session_id cwd
    session_id=$(printf '%s' "$parsed" | cut -f1)
    cwd=$(printf '%s' "$parsed" | cut -f2)
    [[ -n "$cwd" ]] || continue
    [[ -n "$session_id" ]] || session_id=$(basename "$jsonl_file" .jsonl)

    sessions_add_record "claude-code" "$cwd" "$session_id" "unknown" "$mtime_epoch" "{}"
  done < <(find "$project_dir" -maxdepth 1 -name '*.jsonl' -type f -print0 2>/dev/null)
}

#------------------------------------------------------------------------------
# tmux session discovery
# Detects running tmux sessions and extracts their working directories
#------------------------------------------------------------------------------

sessions_discover_tmux() {
  command -v tmux >/dev/null 2>&1 || return 0

  local tmux_output
  tmux_output=$(tmux ls 2>/dev/null) || return 0
  [[ -n "$tmux_output" ]] || return 0

  local mtime_epoch
  mtime_epoch=$(date +%s)

  while IFS=: read -r session_name _rest; do
    [[ -n "$session_name" ]] || continue

    local cwd
    cwd=$(tmux display-message -t "$session_name" -p '#{pane_current_path}' 2>/dev/null) || continue
    [[ -n "$cwd" ]] || continue

    local extra
    extra=$(printf '{"tmux_session":"%s"}' "$session_name")

    sessions_add_record "tmux" "$cwd" "tmux:$session_name" "cli" "$mtime_epoch" "$extra"
  done <<< "$tmux_output"
}

#------------------------------------------------------------------------------
# ttyd discovery
# Finds running ttyd processes, extracts port and linked tmux session
#------------------------------------------------------------------------------

sessions_discover_ttyd() {
  local lines=""

  # Try pgrep first, then fall back to ps
  lines=$(pgrep -a ttyd 2>/dev/null) || \
    lines=$(ps -ax -o pid=,command= 2>/dev/null | grep ttyd | grep -v grep) || \
    return 0

  [[ -n "$lines" ]] || return 0

  local now
  now=$(date +%s)

  while IFS= read -r line; do
    [[ "$line" == *ttyd* ]] || continue
    local pid cmd port tmux_session cwd

    pid=$(printf '%s' "$line" | awk '{print $1}')
    cmd=$(printf '%s' "$line" | cut -d' ' -f2-)

    # Extract port from -p <port> or --port <port>
    port=""
    if [[ "$cmd" =~ -p[[:space:]]+([0-9]+) ]]; then
      port="${BASH_REMATCH[1]}"
    elif [[ "$cmd" =~ --port[[:space:]]+([0-9]+) ]]; then
      port="${BASH_REMATCH[1]}"
    fi

    # Extract tmux session name from "tmux attach -t <name>"
    tmux_session=""
    if [[ "$cmd" =~ tmux[[:space:]]+attach[^[:space:]]*[[:space:]]+-t[[:space:]]+([^[:space:]]+) ]]; then
      tmux_session="${BASH_REMATCH[1]}"
    fi

    # Try to resolve cwd from linked tmux session
    cwd=""
    if [[ -n "$tmux_session" ]]; then
      cwd=$(tmux display-message -t "$tmux_session" -p '#{pane_current_path}' 2>/dev/null) || true
    fi

    local extra
    if [[ "$_SESSIONS_HAS_JQ" == true ]]; then
      extra=$(jq -nc --arg pid "$pid" --arg port "$port" --arg tmux "$tmux_session" --arg cmd "$cmd" \
        '{pid: $pid, port: $port, tmux_session: $tmux, command: $cmd}' 2>/dev/null) || extra="{}"
    else
      extra=$(printf '{"pid":"%s","port":"%s","tmux_session":"%s"}' "$pid" "$port" "$tmux_session")
    fi

    sessions_add_record "ttyd" "${cwd:-unknown}" "ttyd:$pid" "web" "$now" "$extra"
  done <<< "$lines"
}

#------------------------------------------------------------------------------
# Deduplication by cwd
# When multiple sources report the same cwd, keep the richer source.
# Priority: codex/claude-code > tmux/ttyd (agent store has more metadata)
#------------------------------------------------------------------------------

_sessions_source_priority() {
  case "$1" in
    codex)       echo 2 ;;
    claude-code) echo 2 ;;
    tmux)        echo 1 ;;
    ttyd)        echo 1 ;;
    *)           echo 0 ;;
  esac
}

sessions_deduplicate() {
  # Input: $_SESSIONS_RAW (newline-separated records)
  # Output: deduplicated records, stored back in $_SESSIONS_RAW
  [[ -n "$_SESSIONS_RAW" ]] || return 0

  # Use jq to deduplicate by cwd, keeping highest priority
  local deduped
  deduped=$(printf '%s\n' "$_SESSIONS_RAW" | awk -F'\t' '
    {
      cwd = $2
      agent = $1
      # Priority: codex=2, claude-code=2, tmux=1, ttyd=1
      if (agent == "codex" || agent == "claude-code") prio = 2
      else if (agent == "tmux" || agent == "ttyd") prio = 1
      else prio = 0

      if (!(cwd in best_prio) || prio > best_prio[cwd]) {
        best_prio[cwd] = prio
        best_line[cwd] = $0
      }
    }
    END {
      for (cwd in best_line) print best_line[cwd]
    }
  ')

  _SESSIONS_RAW="$deduped"
}

#------------------------------------------------------------------------------
# Slot classification: longest-prefix cwd matching
#
# A session belongs to the slot whose assigned path (no trailing /)
# is the longest prefix of the session's cwd.
#------------------------------------------------------------------------------

# Extract working directories from slot blocks in slots.md.
# Returns tab-separated: slot_number \t path
# Prefers the explicit **Path:** field (if set), then falls back to
# Git section "Working directory:" / "worktree:" lines, then Session field.
_sessions_extract_slot_paths() {
  local file
  file="$(slots_file_path)"
  [[ -f "$file" ]] || return 0

  slots_load_blocks "$file"
  local count
  count="$(slots_count)"

  for (( i=1; i<=count; i++ )); do
    local block="${PAI_LITE_SLOTS[$i]:-}"
    [[ -n "$block" ]] || continue

    local mode
    mode=$(slot_get_mode "$block" 2>/dev/null)
    mode=$(printf "%s" "$mode" | awk '{$1=$1; print}')
    [[ -n "$mode" && "$mode" != "null" ]] || continue

    local found_path=false

    # Prefer explicit **Path:** field
    local slot_path
    slot_path=$(slot_get_path "$block" 2>/dev/null)
    slot_path=$(printf "%s" "$slot_path" | awk '{$1=$1; print}')
    if [[ -n "$slot_path" && "$slot_path" != "null" ]]; then
      printf '%s\t%s\n' "$i" "$slot_path"
      found_path=true
    fi

    # Fallback: extract paths from Git section
    if [[ "$found_path" == false ]]; then
      local git_paths
      git_paths=$(printf '%s' "$block" | awk -v slot="$i" '
        /^\*\*Git:\*\*/ { in_git=1; next }
        /^\*\*[A-Z]/ { in_git=0 }
        in_git && /Working directory:/ {
          path = $0
          sub(/.*Working directory:[[:space:]]*/, "", path)
          sub(/[[:space:]]*\(worktree\)/, "", path)
          sub(/[[:space:]]*$/, "", path)
          if (path != "") print slot "\t" path
        }
        in_git && /worktree:/ {
          path = $0
          sub(/.*worktree:[[:space:]]*/, "", path)
          sub(/[[:space:]]*$/, "", path)
          if (path != "") print slot "\t" path
        }
      ')
      if [[ -n "$git_paths" ]]; then
        printf '%s\n' "$git_paths"
        found_path=true
      fi
    fi

    # Last resort: try Session field as a path or directory name
    if [[ "$found_path" == false ]]; then
      local session
      session=$(slot_get_session "$block")
      session=$(printf "%s" "$session" | awk '{$1=$1; print}')
      if [[ -n "$session" && "$session" != "null" ]]; then
        if [[ "$session" == /* && -d "$session" ]]; then
          printf '%s\t%s\n' "$i" "$session"
        elif [[ -d "$HOME/$session" ]]; then
          printf '%s\t%s\n' "$i" "$HOME/$session"
        fi
      fi
    fi
  done
}

# Classify sessions against slot paths.
# Sets two variables:
#   _SESSIONS_CLASSIFIED - records with slot assignment appended (tab field 7)
#   _SESSIONS_UNCLASSIFIED - records that didn't match any slot
sessions_classify() {
  _SESSIONS_CLASSIFIED=""
  _SESSIONS_UNCLASSIFIED=""

  [[ -n "$_SESSIONS_RAW" ]] || return 0

  # Get slot paths
  local slot_paths
  slot_paths=$(_sessions_extract_slot_paths)

  if [[ -z "$slot_paths" ]]; then
    # No slot paths at all — everything is unclassified
    _SESSIONS_UNCLASSIFIED="$_SESSIONS_RAW"
    return 0
  fi

  # For each session, find the slot with the longest matching prefix
  while IFS= read -r record; do
    [[ -n "$record" ]] || continue
    local session_cwd
    session_cwd=$(printf '%s' "$record" | cut -f2)

    local best_slot="" best_len=0

    while IFS=$'\t' read -r slot_num slot_path; do
      [[ -n "$slot_path" ]] || continue
      # Strip trailing slash from slot_path for prefix matching
      slot_path="${slot_path%/}"

      # Check if slot_path is a prefix of session_cwd
      # Must match exactly at directory boundary: cwd starts with path/ or equals path
      if [[ "$session_cwd" == "$slot_path" || "$session_cwd" == "$slot_path/"* ]]; then
        local path_len=${#slot_path}
        if (( path_len > best_len )); then
          best_len=$path_len
          best_slot="$slot_num"
        fi
      fi
    done <<< "$slot_paths"

    if [[ -n "$best_slot" ]]; then
      local classified_record="${record}"$'\t'"${best_slot}"
      if [[ -z "$_SESSIONS_CLASSIFIED" ]]; then
        _SESSIONS_CLASSIFIED="$classified_record"
      else
        _SESSIONS_CLASSIFIED+=$'\n'"$classified_record"
      fi
    else
      if [[ -z "$_SESSIONS_UNCLASSIFIED" ]]; then
        _SESSIONS_UNCLASSIFIED="$record"
      else
        _SESSIONS_UNCLASSIFIED+=$'\n'"$record"
      fi
    fi
  done <<< "$_SESSIONS_RAW"
}

#------------------------------------------------------------------------------
# Check for stale sessions
#------------------------------------------------------------------------------

sessions_is_stale() {
  local mtime_epoch="$1"
  local now
  now=$(date +%s)
  local age=$(( now - mtime_epoch ))
  (( age > SESSIONS_STALE_THRESHOLD ))
}

#------------------------------------------------------------------------------
# Report generation — writes sessions report to harness directory
#------------------------------------------------------------------------------

sessions_report_path() {
  echo "$(pai_lite_state_harness_dir)/sessions.md"
}

sessions_generate_report() {
  local report_file
  report_file="$(sessions_report_path)"
  local now
  now=$(date +%s)
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  {
    echo "# Discovered Sessions"
    echo ""
    echo "Generated: $timestamp"
    echo ""

    # Classified sessions
    if [[ -n "${_SESSIONS_CLASSIFIED:-}" ]]; then
      echo "## Classified Sessions"
      echo ""
      while IFS= read -r record; do
        [[ -n "$record" ]] || continue
        _sessions_format_record "$record" "$now" "classified"
      done <<< "$_SESSIONS_CLASSIFIED"
    fi

    # Unclassified sessions
    if [[ -n "${_SESSIONS_UNCLASSIFIED:-}" ]]; then
      echo "## Unclassified Sessions"
      echo ""
      echo "*These sessions could not be matched to any slot. Mayor action needed.*"
      echo ""
      while IFS= read -r record; do
        [[ -n "$record" ]] || continue
        _sessions_format_record "$record" "$now" "unclassified"
      done <<< "$_SESSIONS_UNCLASSIFIED"
    fi

    # Summary
    local total_classified=0 total_unclassified=0
    if [[ -n "${_SESSIONS_CLASSIFIED:-}" ]]; then
      total_classified=$(printf '%s\n' "$_SESSIONS_CLASSIFIED" | wc -l | tr -d ' ')
    fi
    if [[ -n "${_SESSIONS_UNCLASSIFIED:-}" ]]; then
      total_unclassified=$(printf '%s\n' "$_SESSIONS_UNCLASSIFIED" | wc -l | tr -d ' ')
    fi

    echo ""
    echo "---"
    echo ""
    echo "**Summary:** $total_classified classified, $total_unclassified unclassified"

  } > "$report_file"

  pai_lite_info "sessions report written to $report_file"
  echo "$report_file"
}

_sessions_format_record() {
  local record="$1" now="$2" classification="$3"

  local agent_type cwd session_id source_kind mtime_epoch extra_json slot_num
  agent_type=$(printf '%s' "$record" | cut -f1)
  cwd=$(printf '%s' "$record" | cut -f2)
  session_id=$(printf '%s' "$record" | cut -f3)
  source_kind=$(printf '%s' "$record" | cut -f4)
  mtime_epoch=$(printf '%s' "$record" | cut -f5)
  extra_json=$(printf '%s' "$record" | cut -f6)

  if [[ "$classification" == "classified" ]]; then
    slot_num=$(printf '%s' "$record" | cut -f7)
  fi

  # Calculate age
  local age_secs=$(( now - mtime_epoch ))
  local age_display
  if (( age_secs < 60 )); then
    age_display="${age_secs}s ago"
  elif (( age_secs < 3600 )); then
    age_display="$(( age_secs / 60 ))m ago"
  elif (( age_secs < 86400 )); then
    age_display="$(( age_secs / 3600 ))h ago"
  else
    age_display="$(( age_secs / 86400 ))d ago"
  fi

  local stale_marker=""
  if (( age_secs > SESSIONS_STALE_THRESHOLD )); then
    stale_marker=" (STALE)"
  fi

  echo "### $agent_type — $cwd"
  if [[ "$classification" == "classified" ]]; then
    echo "- **Slot:** $slot_num"
  fi
  echo "- **Session ID:** $session_id"
  echo "- **Source:** $source_kind"
  echo "- **Last activity:** $age_display$stale_marker"

  # Extract useful fields from extra_json
  if [[ -n "$extra_json" && "$extra_json" != "{}" ]]; then
    local tmux_session git_branch summary
    tmux_session=$(printf '%s' "$extra_json" | jq -r '.tmux_session // empty' 2>/dev/null) || true
    git_branch=$(printf '%s' "$extra_json" | jq -r '.git_branch // empty' 2>/dev/null) || true
    summary=$(printf '%s' "$extra_json" | jq -r '.summary // empty' 2>/dev/null) || true

    [[ -z "$tmux_session" ]] || echo "- **tmux session:** $tmux_session"
    [[ -z "$git_branch" ]] || echo "- **Git branch:** $git_branch"
    [[ -z "$summary" ]] || echo "- **Summary:** $summary"
  fi
  echo ""
}

#------------------------------------------------------------------------------
# Main discovery pipeline
#------------------------------------------------------------------------------

# Run full discovery: scan all sources, deduplicate, classify, generate report.
# Returns the path to the generated report file.
sessions_discover_and_report() {
  # Reset state
  _SESSIONS_RAW=""
  _SESSIONS_CLASSIFIED=""
  _SESSIONS_UNCLASSIFIED=""

  # Layer 1: Raw discovery from all sources
  sessions_discover_codex
  sessions_discover_claude_code
  sessions_discover_tmux
  sessions_discover_ttyd

  # Deduplicate by cwd
  sessions_deduplicate

  # Classify against slots
  sessions_classify

  # Generate report
  sessions_generate_report
}

# Quick summary for CLI output (not the full report)
sessions_summary() {
  local total=0 codex_count=0 claude_count=0 tmux_count=0 ttyd_count=0
  if [[ -n "$_SESSIONS_RAW" ]]; then
    total=$(printf '%s\n' "$_SESSIONS_RAW" | wc -l | tr -d ' ')
    codex_count=$(printf '%s\n' "$_SESSIONS_RAW" | grep -c '^codex' || true)
    claude_count=$(printf '%s\n' "$_SESSIONS_RAW" | grep -c '^claude-code' || true)
    tmux_count=$(printf '%s\n' "$_SESSIONS_RAW" | grep -c '^tmux' || true)
    ttyd_count=$(printf '%s\n' "$_SESSIONS_RAW" | grep -c '^ttyd' || true)
  fi

  local classified=0 unclassified=0
  if [[ -n "${_SESSIONS_CLASSIFIED:-}" ]]; then
    classified=$(printf '%s\n' "$_SESSIONS_CLASSIFIED" | wc -l | tr -d ' ')
  fi
  if [[ -n "${_SESSIONS_UNCLASSIFIED:-}" ]]; then
    unclassified=$(printf '%s\n' "$_SESSIONS_UNCLASSIFIED" | wc -l | tr -d ' ')
  fi

  echo "Sessions: $total total ($codex_count codex, $claude_count claude-code, $tmux_count tmux, $ttyd_count ttyd)"
  echo "Classified: $classified | Unclassified: $unclassified"
}
