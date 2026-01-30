#!/usr/bin/env bash
set -euo pipefail

pai_lite_die() {
  echo "pai-lite: $*" >&2
  exit 1
}

pai_lite_warn() {
  echo "pai-lite: $*" >&2
}

pai_lite_info() {
  echo "pai-lite: $*" >&2
}

pai_lite_root() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  cd "$script_dir/.." && pwd
}

pai_lite_config_path() {
  if [[ -n "${PAI_LITE_CONFIG:-}" ]]; then
    echo "$PAI_LITE_CONFIG"
  else
    echo "$HOME/.config/pai-lite/config.yaml"
  fi
}

pai_lite_require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || pai_lite_die "missing required command: $cmd"
}

pai_lite_config_get() {
  local key="$1"
  local config
  config="$(pai_lite_config_path)"
  [[ -f "$config" ]] || pai_lite_die "config not found: $config"
  awk -v key="$key" -F: '
    $0 ~ "^[[:space:]]*" key ":" {
      sub(/^[^:]+:[[:space:]]*/, "", $0)
      sub(/[[:space:]]+$/, "", $0)
      print $0
      exit
    }
  ' "$config"
}

pai_lite_config_slots_count() {
  local config
  config="$(pai_lite_config_path)"
  [[ -f "$config" ]] || pai_lite_die "config not found: $config"
  awk '
    $0 ~ /^[[:space:]]*slots:/ { in_slots=1; next }
    in_slots && $0 ~ /^[[:space:]]*count:/ {
      sub(/^[^:]+:[[:space:]]*/, "", $0)
      sub(/[[:space:]]+$/, "", $0)
      print $0
      exit
    }
    in_slots && $0 !~ /^[[:space:]]/ { in_slots=0 }
  ' "$config"
}

pai_lite_state_repo_slug() {
  pai_lite_config_get "state_repo"
}

pai_lite_state_repo_dir() {
  local slug repo_name
  slug="$(pai_lite_state_repo_slug)"
  repo_name="${slug##*/}"
  echo "$HOME/$repo_name"
}

pai_lite_state_path() {
  local path
  path="$(pai_lite_config_get "state_path")"
  [[ -n "$path" ]] || echo "harness"
  [[ -n "$path" ]] && echo "$path"
}

pai_lite_state_harness_dir() {
  local repo_dir path
  repo_dir="$(pai_lite_state_repo_dir)"
  path="$(pai_lite_state_path)"
  echo "$repo_dir/$path"
}

pai_lite_ensure_state_repo() {
  local repo_dir slug
  repo_dir="$(pai_lite_state_repo_dir)"
  slug="$(pai_lite_state_repo_slug)"

  if [[ ! -d "$repo_dir/.git" ]]; then
    pai_lite_require_cmd gh
    pai_lite_info "cloning state repo $slug into $repo_dir"
    gh repo clone "$slug" "$repo_dir" >/dev/null
  fi
}

pai_lite_ensure_state_dir() {
  local harness_dir
  harness_dir="$(pai_lite_state_harness_dir)"
  [[ -d "$harness_dir" ]] || mkdir -p "$harness_dir"
}
