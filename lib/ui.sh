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
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
BLUE=$'\033[0;34m'
PURPLE=$'\033[0;35m'
NC=$'\033[0m'
BOLD=$'\033[1m'

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

# ── Requirements & preflight ─────────────────────────────────────────────────
# The `## Requirements` section of README.md is the single source of truth for
# what this toolkit needs: the list is rendered from it at run time, then each
# entry is verified against the machine we are actually running on.

# Default README path: one level up from lib/. Override with UI_README=/path.
_ui_default_readme() {
  local root
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)" || root="$PWD"
  printf '%s\n' "${UI_README:-${root}/README.md}"
}

# Trim leading/trailing whitespace.
_ui_trim() {
  local s="${1:-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Print one value from /etc/os-release. Empty on any failure.
_os_release() {
  local key="${1:-}" value=''
  if [[ -r /etc/os-release ]]; then
    value="$( set +u; . /etc/os-release 2>/dev/null >/dev/null || true; printf '%s' "${!key:-}" )" || value=''
  fi
  printf '%s' "$value"
}

# readme_section "Heading" [file] — print the body of `## Heading` in a markdown
# file, stopping at the next heading. Returns 1 if the file is unreadable.
readme_section() {
  local heading="${1:?heading required}"
  local file="${2:-$(_ui_default_readme)}"
  local line='' heading_text='' inside=0

  [[ -r "$file" ]] || return 1

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^#{1,6}[[:space:]]+(.+)$ ]]; then
      heading_text="$(_ui_trim "${BASH_REMATCH[1]}")"
      if (( inside )); then
        break
      fi
      if [[ "${heading_text,,}" == "${heading,,}" ]]; then
        inside=1
      fi
      continue
    fi
    if (( inside )); then
      printf '%s\n' "$line"
    fi
  done < "$file"
}

# Render inline markdown for the terminal: `code` becomes bold+cyan,
# **bold** becomes bold.
md_inline() {
  local text="${1:-}" out=''
  local code_re='^([^`]*)`([^`]*)`(.*)$'
  text="${text//\*\*/}"
  while [[ "$text" =~ $code_re ]]; do
    out+="${BASH_REMATCH[1]}${BOLD}${CYAN}${BASH_REMATCH[2]}${NC}"
    text="${BASH_REMATCH[3]}"
  done
  printf '%s\n' "${out}${text}"
}

# bullet "marker" "text" — one list line, with inline markdown rendered.
bullet() {
  local marker="${1:-•}" text="${2:-}"
  printf "  ${CYAN}%s${NC}  %s\n" "$marker" "$(md_inline "$text")"
}

# show_requirements [file] — render the README `## Requirements` bullets as a
# numbered checklist. Warns (and returns 1) if there is nothing to show.
show_requirements() {
  local file="${1:-$(_ui_default_readme)}"
  local body='' line='' index=0
  local bullet_re='^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]+(.+)$'

  body="$(readme_section 'Requirements' "$file")" || body=''

  section 'Requirements'

  if [[ -z "$(_ui_trim "$body")" ]]; then
    warn "no '## Requirements' section found in ${file}"
    return 1
  fi

  while IFS= read -r line; do
    if [[ "$line" =~ $bullet_re ]]; then
      index=$(( index + 1 ))
      bullet "${index}." "${BASH_REMATCH[2]}"
    fi
  done <<< "$body"
}

# ── Requirement predicates & details (one pair per README bullet) ────────────

_ui_check_linux() { [[ "$(uname -s)" == "Linux" ]]; }
_ui_detail_linux() { printf 'kernel %s' "$(uname -sr)"; }

_ui_check_bash() { (( BASH_VERSINFO[0] >= 4 )); }
_ui_detail_bash() { printf 'bash %s' "$BASH_VERSION"; }

_ui_check_apt() {
  local distro id_like
  distro="$(_os_release ID)"; id_like="$(_os_release ID_LIKE)"
  distro="${distro,,} ${id_like,,}"
  if [[ "$distro" == *debian* || "$distro" == *ubuntu* ]]; then
    command_exists apt-get
  else
    return 1
  fi
}
_ui_detail_apt() {
  local pretty
  pretty="$(_os_release PRETTY_NAME)"
  [[ -n "$pretty" ]] || pretty='unknown distribution'
  printf '%s, apt-get: %s' "$pretty" "$(command -v apt-get 2>/dev/null || printf 'not found')"
}

_ui_check_sudo() { (( EUID == 0 )) || command_exists sudo; }
_ui_detail_sudo() {
  if (( EUID == 0 )); then
    printf 'running as root — sudo not needed'
  else
    printf 'sudo: %s' "$(command -v sudo 2>/dev/null || printf 'not found')"
  fi
}

# check_requirements — verify the machine against the README list, printing the
# observed value next to each verdict. Returns 1 if anything failed.
check_requirements() {
  local failed=0 i label predicate detail_fn
  local -a table=(
    'Linux|_ui_check_linux|_ui_detail_linux'
    'bash 4.0+|_ui_check_bash|_ui_detail_bash'
    'Ubuntu or Debian, apt-based|_ui_check_apt|_ui_detail_apt'
    'sudo available|_ui_check_sudo|_ui_detail_sudo'
  )

  for i in "${!table[@]}"; do
    IFS='|' read -r label predicate detail_fn <<< "${table[$i]}"
    if "$predicate"; then
      success "$label — $("$detail_fn")"
    else
      error "$label — $("$detail_fn")"
      failed=1
    fi
  done

  return "$failed"
}

# confirm "prompt" — TTY-aware y/N gate. Auto-approves when SETUP_ASSUME_YES=1
# or when there is no terminal (CI, pipes).
confirm() {
  local prompt="${1:-Continue?}" reply=''

  if [[ "${SETUP_ASSUME_YES:-0}" == "1" ]]; then
    step "$prompt — auto-approved (SETUP_ASSUME_YES=1)"
    return 0
  fi
  [[ -t 0 && -t 1 ]] || return 0

  while true; do
    read -r -p "  ${CYAN}›${NC}  ${BOLD}${prompt}${NC} ${CYAN}[Y/n]${NC} " \
      reply || return 1
    case "${reply,,}" in
      ''|y|yes) return 0 ;;
      n|no)     return 1 ;;
      *)        warn 'please answer y or n' ;;
    esac
  done
}

# preflight [file] — show the requirements, verify them, then gate on a
# confirmation. Aborts if any check fails, unless SOFT_PREFLIGHT=1.
preflight() {
  local file="${1:-$(_ui_default_readme)}"

  show_requirements "$file" || true   # show_requirements already warned

  section 'Environment check'

  if ! check_requirements; then
    if [[ "${SOFT_PREFLIGHT:-0}" == "1" ]]; then
      warn 'requirements not met — continuing anyway (SOFT_PREFLIGHT=1)'
    else
      error 'requirements not met — aborting'
      error 'fix the items above, or re-run with SOFT_PREFLIGHT=1 to continue anyway'
      exit 1
    fi
  else
    success 'All requirements satisfied'
  fi

  if ! confirm 'Run the setup now?'; then
    warn 'Aborted by user'
    exit 130
  fi
}