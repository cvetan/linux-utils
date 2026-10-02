#!/usr/bin/env bash
# =============================================================================
# lib/ui.sh — presentation primitives (pure bash, zero dependencies)
# =============================================================================
# This library only draws and prompts. It does NOT:
#   * change the caller's shell options (main.sh owns `set -euo pipefail`, IFS)
#   * install traps
#   * create log files or redirect output (see lib/log.sh)
#   * call `exit` — every function here returns a status instead
#   * read the environment (see lib/preflight.sh for detection)

# ── Guard against double sourcing ─────────────────────────────────────────────
[[ -n "${_UI_SH_LOADED:-}" ]] && return
readonly _UI_SH_LOADED=1

# ── Layout ────────────────────────────────────────────────────────────────────
# Shared width so banners and section rules line up.
UI_WIDTH=60

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
# banner "TEXT" [color] — boxed, centered title. The optional second argument
# colors both the frame and the title text.
banner() {
    local text="${1:-}"
    local color="${2:-$CYAN}"
    local max_width=$UI_WIDTH
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

    printf '\n  %s%s╔%s╗%s\n' "$color" "$BOLD" "$line" "$NC"
    printf '  %s%s║%*s%s%*s║%s\n' \
        "$color" "$BOLD" "$pad" '' "$text" "$(( width - pad - ${#text} ))" '' "$NC"
    printf '  %s%s╚%s╝%s\n\n' "$color" "$BOLD" "$line" "$NC"
}

# ── Section ───────────────────────────────────────────────────────────────────
section() {
    local rule
    printf -v rule "%${UI_WIDTH}s" ''
    rule="${rule// /─}"

    printf '\n%s%s▶  %s%s\n' "$CYAN" "$BOLD" "$*" "$NC"
    printf '%s%s%s\n' "$CYAN" "$rule" "$NC"
}

# ── Logging to the terminal ───────────────────────────────────────────────────
info()    { printf '  %s✓%s  %s\n' "$GREEN" "$NC" "$*"; }
warn()    { printf '  %s!%s  %s\n' "$YELLOW" "$NC" "$*" >&2; }
error()   { printf '  %s✗%s  %s\n' "$RED" "$NC" "$*" >&2; }
success() { printf '  %s✓%s  %s%s%s\n' "$GREEN" "$NC" "$BOLD" "$*" "$NC"; }
step()    { printf '  %s›%s  %s\n' "$BLUE" "$NC" "$*"; }

# ── Spinner ───────────────────────────────────────────────────────────────────
_SPINNER_PID=''
_SPINNER_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')

# No TTY, no spinner. The frames are written without a newline and only make
# sense when a terminal re-renders the line; piped into a file or a pager stdout
# is block-buffered, so the frames flush *after* the following output and land
# interleaved with it — stray `⠋ Adding base packages` fragments in the middle of
# the next section. spinner_start is a no-op there and spinner_stop a no-op too.
spinner_supported() { [[ -t 1 ]]; }

spinner_start() {
    local msg="${1:-}"

    spinner_supported || return 0

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
        _SPINNER_PID=''
        # Only erase the line if we actually drew one.
        printf '\r\033[2K' || true
    fi

    [[ -n "$label" ]] && info "$label"
    return 0
}

# ── Inline markdown ───────────────────────────────────────────────────────────
# md_inline "text" — terminal rendering of `code` (bold cyan) and **bold**.
md_inline() {
    local text="${1:-}" bold='' code=''
    local bold_re='^([^*]*)\*\*([^*]+)\*\*(.*)$'
    local code_re='^([^`]*)`([^`]*)`(.*)$'

    # Two passes, bold first: neither pass can consume the other's markers.
    while [[ "$text" =~ $bold_re ]]; do
        bold+="${BASH_REMATCH[1]}${BOLD}${BASH_REMATCH[2]}${NC}"
        text="${BASH_REMATCH[3]}"
    done
    bold+="$text"

    while [[ "$bold" =~ $code_re ]]; do
        code+="${BASH_REMATCH[1]}${BOLD}${CYAN}${BASH_REMATCH[2]}${NC}"
        bold="${BASH_REMATCH[3]}"
    done

    printf '%s\n' "${code}${bold}"
}

# ── bullet "marker" "text" — one list line, with inline markdown rendered ─────
bullet() {
    local marker="${1:-•}" text="${2:-}"
    printf "  ${CYAN}%s${NC}  %s\n" "$marker" "$(md_inline "$text")"
}

# ── prompt_yes_no "question" ──────────────────────────────────────────────────
# Ask a [Y/n] question and return 0 for yes, 1 for no. Deliberately policy-free:
# it does not know about SETUP_ASSUME_YES, TTYs or CI — see confirm in
# lib/preflight.sh for the wrapper that does.
prompt_yes_no() {
    local prompt="${1:-Continue?}" reply=''

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
