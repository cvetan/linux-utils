#!/usr/bin/env bash
# =============================================================================
# lib.sh — UI & logging utilities (pure bash, zero dependencies)
# =============================================================================

# ── Guard against double sourcing ─────────────────────────────────────────────
[[ -n "${_LIB_SH_LOADED:-}" ]] && return
readonly _LIB_SH_LOADED=1

# ── Strict mode ───────────────────────────────────────────────────────────────
set -euo pipefail
IFS=$'\n\t'

# ── Bash version check ────────────────────────────────────────────────────────
if (( BASH_VERSINFO[0] < 4 )); then
  echo "ERROR: bash 4.0+ required (you have $BASH_VERSION)" >&2
  exit 1
fi

# ── OS check ──────────────────────────────────────────────────────────────────
if [[ "$(uname -s)" != "Linux" ]]; then
  echo "ERROR: this script is Linux only" >&2
  exit 1
fi

# ── Log file ──────────────────────────────────────────────────────────────────
LOG_FILE="/tmp/setup-$(date +%Y%m%d-%H%M%S).log"

# ── Trap ──────────────────────────────────────────────────────────────────────
trap 'echo "ERROR: unexpected failure on line $LINENO in $BASH_SOURCE" >&2' ERR

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'

# ── Banner (pure bash, no dependencies) ───────────────────────────────────────
banner() {
  local text="${1:-}"
  local color="${2:-$CYAN}"   # second arg is optional, defaults to CYAN
  local max_width=60
  local min_padding=4

  local max_text=$(( max_width - (min_padding * 2) ))
  if (( ${#text} > max_text )); then
    text="${text:0:$(( max_text - 3 ))}..."
  fi

  local width=$(( ${#text} + (min_padding * 2) ))
  (( width > max_width )) && width=$max_width
  (( width < 30 )) && width=30

  local pad=$(( (width - ${#text}) / 2 ))

  local line
  printf -v line '%*s' "$width" ''
  line="${line// /═}"

  echo ""
  echo -e "${color}${BOLD}  ╔${line}╗"
  printf "  ║%*s%s%*s║\n" \
    "$pad" "" "$text" "$(( width - pad - ${#text} ))" ""
  echo -e "  ╚${line}╝${NC}"
  echo ""
}


# ── Section ───────────────────────────────────────────────────────────────────
section() {
  echo -e "\n${CYAN}${BOLD}▶  $*${NC}"
  echo -e "${CYAN}$(printf '%.0s─' {1..50})${NC}"
}

# ── Logging ───────────────────────────────────────────────────────────────────
info()    { echo -e "${GREEN}  ✓  ${NC}$*"; }
warn()    { echo -e "${YELLOW}  !  ${NC}$*"; }
error()   { echo -e "${RED}  ✗  ${NC}$*" >&2; }
success() { echo -e "${GREEN}  ✓  ${BOLD}$*${NC}"; }
step()    { echo -e "${BLUE}  ›  ${NC}$*"; }

# ── Spinner ───────────────────────────────────────────────────────────────────
_SPINNER_PID=""
_SPINNER_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')

spinner_start() {
  local msg="${1:-}"
  (
    local i=0
    while true; do
      printf "\r  ${CYAN}%s${NC}  %s " \
        "${_SPINNER_FRAMES[$((i % ${#_SPINNER_FRAMES[@]}))]}" "$msg"
      sleep 0.1
      (( i++ )) || true
    done
  ) &
  _SPINNER_PID=$!
  disown "${_SPINNER_PID:-}" 2>/dev/null || true
}

spinner_stop() {
  local label="${1:-}"
  if [[ -n "${_SPINNER_PID:-}" ]]; then
    kill "$_SPINNER_PID" 2>/dev/null || true
    wait "$_SPINNER_PID" 2>/dev/null || true
    _SPINNER_PID=""
  fi
  printf "\r\033[2K" || true
  if [[ -n "$label" ]]; then
    info "$label"
  fi
}

# ── run: silent execution with spinner ───────────────────────────────────────
# Usage: run "Label" cmd arg1 arg2 ...
run() {
  local label="$1"; shift
  local exit_code=0

  spinner_start "$label"
  "$@" >> "$LOG_FILE" 2>&1 || exit_code=$?
  spinner_stop

  if [[ $exit_code -ne 0 ]]; then
    error "FAILED: $label (exit $exit_code)"
    echo -e "${YELLOW}  Last output (full log: $LOG_FILE):${NC}"
    tail -20 "$LOG_FILE" | sed 's/^/    /'
    exit $exit_code
  fi

  info "$label"
}

# ── Misc helpers ──────────────────────────────────────────────────────────────
command_exists() { command -v "$1" &>/dev/null; }

append_if_missing() {
  local file="${1:?file required}"
  local marker="${2:?marker required}"
  local content="${3:?content required}"
  grep -qF "$marker" "$file" 2>/dev/null || echo -e "$content" >> "$file"
}