#!/usr/bin/env bash
set -euo pipefail

# pai-lite test script — shellcheck + smoke tests
# Usage: ./tests/test.sh

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pai="$root_dir/bin/pai-lite"

pass=0
fail=0
skip=0

green=$'\033[32m'
red=$'\033[31m'
yellow=$'\033[33m'
bold=$'\033[1m'
reset=$'\033[0m'

ok() {
  echo "  ${green}PASS${reset}  $1"
  pass=$((pass + 1))
}

fail() {
  echo "  ${red}FAIL${reset}  $1"
  if [[ -n "${2:-}" ]]; then
    echo "        $2"
  fi
  fail=$((fail + 1))
}

skipped() {
  echo "  ${yellow}SKIP${reset}  $1"
  skip=$((skip + 1))
}

# ── Section: Bash version ────────────────────────────────────────────
echo "${bold}Bash version${reset}"

if [[ "${BASH_VERSINFO[0]}" -ge 4 ]]; then
  ok "Bash ${BASH_VERSION} (>= 4 required for declare -gA)"
else
  fail "Bash ${BASH_VERSION}" "Bash 4+ required; macOS system bash is too old"
fi

# ── Section: shellcheck ──────────────────────────────────────────────
echo
echo "${bold}shellcheck${reset}"

if ! command -v shellcheck &>/dev/null; then
  skipped "shellcheck not installed"
else
  # Collect all shell scripts
  scripts=()
  scripts+=("$root_dir/bin/pai-lite")
  while IFS= read -r f; do scripts+=("$f"); done < <(find "$root_dir/lib" -name '*.sh' | sort)
  while IFS= read -r f; do scripts+=("$f"); done < <(find "$root_dir/adapters" -name '*.sh' | sort)
  while IFS= read -r f; do scripts+=("$f"); done < <(find "$root_dir/templates/hooks" -name '*.sh' 2>/dev/null | sort)

  for script in "${scripts[@]}"; do
    label="${script#"$root_dir/"}"
    if shellcheck -P "$root_dir" -x -S warning "$script" &>/dev/null; then
      ok "$label"
    else
      fail "$label" "$(shellcheck -P "$root_dir" -x -S warning "$script" 2>&1 | head -5)"
    fi
  done
fi

# ── Section: smoke tests ─────────────────────────────────────────────
echo
echo "${bold}Smoke tests${reset}"

# help prints usage and exits 0
if output=$("$pai" help 2>&1) && echo "$output" | grep -q "Usage:"; then
  ok "pai-lite help"
else
  fail "pai-lite help" "expected exit 0 with 'Usage:' in output"
fi

# doctor runs without config and exits 0
if "$pai" doctor &>/dev/null; then
  ok "pai-lite doctor"
else
  fail "pai-lite doctor" "exited non-zero (tool missing?)"
fi

# unknown command should fail
if "$pai" this-does-not-exist &>/dev/null; then
  fail "pai-lite <unknown>" "expected non-zero exit"
else
  ok "pai-lite <unknown> → non-zero exit"
fi

# ── Summary ───────────────────────────────────────────────────────────
echo
total=$((pass + fail + skip))
echo "${bold}Results: $pass passed, $fail failed, $skip skipped${reset} ($total checks)"

if [[ "$fail" -gt 0 ]]; then
  exit 1
fi
