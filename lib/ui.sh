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
_SPINNER_LABEL=''
_SPINNER_DEPTH=0
_SPINNER_PAUSED=0
_SPINNER_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')

# No TTY, no spinner. The frames are written without a newline and only make
# sense when a terminal re-renders the line; piped into a file or a pager stdout
# is block-buffered, so the frames flush *after* the following output and land
# interleaved with it — stray `⠋ Adding base packages` fragments in the middle of
# the next section. spinner_start is a no-op there and spinner_stop a no-op too.
spinner_supported() { [[ -t 1 ]]; }

# _spinner_spawn "msg" — launch the redraw loop and record its pid.
_spinner_spawn() {
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

# spinner_start "msg" — begin (or nest into) a spinner. Only the outermost call
# owns a process. A nested `run` — add_custom_repositories is itself invoked
# through `run` while it calls `run` per PPA — would otherwise overwrite
# _SPINNER_PID and orphan the outer loop, which then redraws forever over every
# later prompt (including sudo's).
spinner_start() {
    local msg="${1:-}"

    _SPINNER_DEPTH=$(( _SPINNER_DEPTH + 1 ))
    (( _SPINNER_DEPTH == 1 )) || return 0

    _SPINNER_LABEL="$msg"
    spinner_supported || return 0
    _spinner_spawn "$msg"
}

spinner_stop() {
    local label="${1:-}"

    if (( _SPINNER_DEPTH > 0 )); then
        _SPINNER_DEPTH=$(( _SPINNER_DEPTH - 1 ))
    fi
    (( _SPINNER_DEPTH == 0 )) || return 0

    if [[ -n "${_SPINNER_PID:-}" ]]; then
        kill "$_SPINNER_PID" 2>/dev/null || true
        wait "$_SPINNER_PID" 2>/dev/null || true
        _SPINNER_PID=''
        # Only erase the line if we actually drew one.
        printf '\r\033[2K' || true
    fi
    _SPINNER_LABEL=''
    _SPINNER_PAUSED=0

    [[ -n "$label" ]] && info "$label"
    return 0
}

# spinner_pause / spinner_resume — hide the spinner around an interactive prompt
# (sudo asking for a password) and restore it afterwards. The depth counter is
# left alone, so the enclosing run's spinner_stop still balances its start.
spinner_pause() {
    _SPINNER_PAUSED=0
    [[ -n "${_SPINNER_PID:-}" ]] || return 0

    kill "$_SPINNER_PID" 2>/dev/null || true
    wait "$_SPINNER_PID" 2>/dev/null || true
    _SPINNER_PID=''
    _SPINNER_PAUSED=1
    printf '\r\033[2K' || true
}

spinner_resume() {
    (( _SPINNER_PAUSED )) || return 0
    _SPINNER_PAUSED=0
    [[ -n "${_SPINNER_LABEL:-}" ]] || return 0
    [[ -z "${_SPINNER_PID:-}" ]] || return 0
    spinner_supported || return 0
    _spinner_spawn "$_SPINNER_LABEL"
}

# Kill any running spinner and reset all state. Safe to call at any time —
# main.sh wires it to EXIT (and the ERR handler) so an aborted run never leaves
# a disowned spinner redrawing over the shell prompt, or a stale depth/paused
# counter for a later stage to trip over. No erase: on exit we must not blank the
# error line that triggered the cleanup.
spinner_cleanup() {
    if [[ -n "${_SPINNER_PID:-}" ]]; then
        kill "$_SPINNER_PID" 2>/dev/null || true
        wait "$_SPINNER_PID" 2>/dev/null || true
        _SPINNER_PID=''
    fi
    _SPINNER_DEPTH=0
    _SPINNER_PAUSED=0
    _SPINNER_LABEL=''
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
        # Question on its own line, [Y/n] on the next: a long prompt (Xbox,
        # Firefox, NVIDIA) wraps past the terminal width, which pushes the
        # marker off-screen where the following spinner can overwrite it.
        printf '  %s›%s  %s%s%s\n' "$CYAN" "$NC" "$BOLD" "$prompt" "$NC" >&2
        read -r -p "  ${CYAN}[Y/n]${NC} " reply || return 1
        case "${reply,,}" in
            ''|y|yes) return 0 ;;
            n|no)     return 1 ;;
            *)        warn 'please answer y or n' ;;
        esac
    done
}

# ── prompt_choice "question" default item ... ────────────────────────────────
# Numbered menu drawn on stderr, the chosen item printed on stdout, so a caller
# can capture it with $(...) and still see the menu. `default` is a 1-based index
# used when the user presses Enter. Deliberately policy-free like prompt_yes_no:
# it always reads the terminal — see `choose` in lib/preflight.sh for the TTY/CI
# handling. Returns 1 on EOF.
prompt_choice() {
    local prompt="${1:-Select?}" default="${2:-1}" reply='' item i=0
    shift 2
    local -a items=( "$@" )
    (( ${#items[@]} > 0 )) || return 1
    (( default >= 1 && default <= ${#items[@]} )) || default=1

    {
        printf '  %s›%s  %s%s%s\n' "$CYAN" "$NC" "$BOLD" "$prompt" "$NC"
        for item in "${items[@]}"; do
            i=$(( i + 1 ))
            if (( i == default )); then
                printf '  %s%2d)%s %s %s(default)%s\n' \
                    "$CYAN" "$i" "$NC" "$item" "$YELLOW" "$NC"
            else
                printf '  %s%2d)%s %s\n' "$CYAN" "$i" "$NC" "$item"
            fi
        done
    } >&2

    while true; do
        read -r -p "  ${CYAN}›${NC}  ${BOLD}${prompt}${NC} [${default}] " reply || return 1
        reply="${reply:-$default}"
        if [[ "$reply" =~ ^[0-9]+$ ]] && (( reply >= 1 && reply <= ${#items[@]} )); then
            printf '%s\n' "${items[reply-1]}"
            return 0
        fi
        warn "enter a number between 1 and ${#items[@]}"
    done
}

# ── prompt_input "question" [default] ────────────────────────────────────────
# Free-text prompt. The prompt is drawn on stderr and the entered value printed
# on stdout, so a caller captures it with $(...) and still sees the prompt. A
# bare Enter accepts `default`; with no default the value is required.
# Deliberately policy-free like the other prompts: it always reads the terminal
# — see `ask` in lib/preflight.sh for the TTY/CI handling. Returns 1 on EOF.
prompt_input() {
    local prompt="${1:-}" default="${2:-}" reply=''

    while true; do
        if [[ -n "$default" ]]; then
            read -r -p "  ${CYAN}›${NC}  ${BOLD}${prompt}${NC} ${YELLOW}[${default}]${NC} " reply || return 1
            reply="${reply:-$default}"
        else
            read -r -p "  ${CYAN}›${NC}  ${BOLD}${prompt}${NC} " reply || return 1
        fi
        if [[ -n "$reply" ]]; then
            printf '%s\n' "$reply"
            return 0
        fi
        warn 'a value is required'
    done
}

# ── _multiselect_readkey ──────────────────────────────────────────────────────
# Read one keypress without Enter, returning the key on stdout. Arrow keys are
# escape sequences, so a leading ESC is followed by two short-timeout reads; a
# lone ESC returns just `\e`. Returns 1 on EOF. No terminal changes leak out:
# each `read` restores its own mode, and the caller owns any longer-lived state.
#
# The key deliberately goes to *stdout* even though the checklist draws on
# stderr: the caller captures it with `key="$(...)"`, so stdout is the value
# channel here. Redirecting this one would hand the caller an empty key and
# freeze the loop.
_multiselect_readkey() {
    local key='' k2='' k3=''
    IFS= read -rsn1 key || return 1
    if [[ "$key" == $'\e' ]]; then
        IFS= read -rsn1 -t 0.1 k2 || k2=''
        IFS= read -rsn1 -t 0.1 k3 || k3=''
        key="${key}${k2}${k3}"
    fi
    printf '%s' "$key"
}

# ── _prompt_picker ────────────────────────────────────────────────────────────
# _prompt_picker "mode" "prompt" "anchor" "off_ids" "id|label" ... — the shared
# core behind prompt_multiselect (mode `multi`) and prompt_select_one (mode
# `single`): one interactive list, drawn on stderr and redrawn in place with
# ANSI cursor movement, so a caller captures the value from stdout with $(...)
# and still sees the menu.
#
#   multi  — `anchor` is a required id that cannot be toggled off and is shown
#            `(required)`; `off_ids` is a space-padded, space-separated list of
#            ids that start unchecked (e.g. ` vscode php `). Arrow keys (or
#            j/k) move, space toggles, `a` all, `n` none but the required id,
#            Enter accepts, `q` aborts. Prints every selected id to stdout, one
#            per line.
#   single — `anchor` is the id the cursor starts on (item 1 when it is absent
#            or unknown); `off_ids` is ignored. Arrow keys (or j/k) move, Enter
#            commits the highlighted item, `q` aborts. Prints the one chosen id
#            to stdout.
#
# Returns 0 with the value on stdout; 1 on an empty list, on `q`, or on EOF
# (Ctrl-D — a single-select that never committed prints nothing at all).
#
# Deliberately policy-free: it always reads the terminal, so the TTY/CI handling
# lives in the wrappers — select_steps/select_one in lib/preflight.sh. The
# check is on stdin there, because a caller captures the value with $(...),
# which only redirects stdout.
#
# Every draw goes to stderr, never stdout: a bare printf here would be swallowed
# by the caller's $(...) capture and leave the terminal blank while this loop
# waits for a keypress nobody can see. `_multiselect_readkey` is the single
# exception — its key is the captured value, so stdout is its channel.
_prompt_picker() {
    local mode="${1:?mode required}" prompt="${2:?prompt required}"
    local anchor="${3:-}" off="${4:-}"
    (( $# >= 4 )) || return 1
    shift 4
    local -a specs=( "$@" )
    local total=${#specs[@]}
    (( total > 0 )) || return 1

    local -a ids=() labels=()
    local -A on=()
    local spec id label i
    for spec in "${specs[@]}"; do
        id="${spec%%|*}"; label="${spec#*|}"
        ids+=( "$id" ); labels+=( "$label" )
        if [[ "$mode" == 'single' ]]; then
            # No toggling state in single mode: the cursor is the selection.
            on["$id"]=0
        elif [[ "$id" == "$anchor" ]] || [[ "$off" != *" $id "* ]]; then
            on["$id"]=1
        else
            on["$id"]=0
        fi
    done

    # Single mode starts on the caller's default, clamped to the first item.
    local cursor=1
    if [[ "$mode" == 'single' ]]; then
        for i in "${!ids[@]}"; do
            if [[ "${ids[i]}" == "$anchor" ]]; then
                cursor=$(( i + 1 ))
                break
            fi
        done
    fi

    local _ms_lines=$(( total + 5 ))
    local _ms_first=1
    local _ms_note=''
    local rule help
    printf -v rule "%${UI_WIDTH}s" ''
    rule="${rule// /─}"
    if [[ "$mode" == 'single' ]]; then
        help='↑/↓ move · Enter select · q quit'
    else
        help='↑/↓ move · space toggle · a all · n none · Enter continue · q quit'
    fi

    # _picker_render redraws the whole list in place. It is defined inside
    # _prompt_picker so it reads the caller's locals (dynamic scope): mode,
    # prompt, rule, help, total, ids, labels, on, cursor, anchor, _ms_lines,
    # _ms_first and _ms_note. _ms_lines is the exact number of lines it emits —
    # blank, prompt, rule, one row per item, note-or-blank, help — which is what
    # makes the cursor-up redraw stay in place in both modes.
    # Every printf here carries >&2; see the header comment.
    _picker_render() {
        local i box mark reqtag

        if (( ! _ms_first )); then
            printf '\033[%dA\r' "$_ms_lines" >&2
        fi
        _ms_first=0

        printf '\033[2K\n' >&2
        printf '\033[2K  %s▶%s  %s%s%s\n' "$CYAN" "$NC" "$BOLD" "$prompt" "$NC" >&2
        printf '\033[2K%s%s%s\n' "$CYAN" "$rule" "$NC" >&2
        for (( i = 0; i < total; i++ )); do
            if (( i + 1 == cursor )); then
                mark="  ${CYAN}▶${NC}  "
            else
                mark='     '
            fi
            if [[ "$mode" == 'single' ]]; then
                # Radio, not checkbox: only the highlighted row can be picked.
                if (( i + 1 == cursor )); then
                    box="${GREEN}[•]${NC}"
                else
                    box='[ ]'
                fi
            elif [[ "${on[${ids[i]}]}" == 1 ]]; then
                box="${GREEN}[x]${NC}"
            else
                box='[ ]'
            fi
            if [[ "$mode" != 'single' && "${ids[i]}" == "$anchor" ]]; then
                reqtag="  ${YELLOW}(required)${NC}"
            else
                reqtag=''
            fi
            printf '\033[2K%s%s  %2d. %s%s\n' \
                "$mark" "$box" "$(( i + 1 ))" "${labels[i]}" "$reqtag" >&2
        done
        if [[ -n "$_ms_note" ]]; then
            printf '\033[2K  %s!%s  %s\n' "$YELLOW" "$NC" "$_ms_note" >&2
        else
            printf '\033[2K\n' >&2
        fi
        printf '\033[2K  %s%s%s\n' "$CYAN" "$help" "$NC" >&2
    }

    _picker_render
    local key
    while :; do
        _ms_note=''
        # EOF (Ctrl-D) leaves the loop: multi keeps whatever is toggled, single
        # has committed nothing and must fail with an empty stdout.
        key="$(_multiselect_readkey)" || break
        case "$key" in
            '')
                if [[ "$mode" == 'single' ]]; then
                    printf '%s\n' "${ids[cursor-1]}"
                    return 0
                fi
                break ;;
            $'\e[A'|'k') cursor=$(( cursor > 1 ? cursor - 1 : total )) ;;
            $'\e[B'|'j') cursor=$(( cursor < total ? cursor + 1 : 1 )) ;;
            ' ')
                if [[ "$mode" == 'single' ]]; then
                    continue    # nothing to toggle — Enter is the commitment
                fi
                if [[ "${ids[cursor-1]}" == "$anchor" ]]; then
                    _ms_note="step $cursor is required — cannot be deselected"
                elif [[ "${on[${ids[cursor-1]}]}" == 1 ]]; then
                    on["${ids[cursor-1]}"]=0
                else
                    on["${ids[cursor-1]}"]=1
                fi
                ;;
            'a')
                if [[ "$mode" == 'single' ]]; then continue; fi
                for (( i = 0; i < total; i++ )); do on["${ids[i]}"]=1; done ;;
            'n')
                if [[ "$mode" == 'single' ]]; then continue; fi
                for (( i = 0; i < total; i++ )); do
                     [[ "${ids[i]}" == "$anchor" ]] || on["${ids[i]}"]=0
                 done ;;
            'q')
                printf '\n' >&2
                return 1 ;;
        esac
        _picker_render
    done

    if [[ "$mode" == 'single' ]]; then
        return 1    # EOF without Enter: no id was chosen
    fi

    local out=''
    for (( i = 0; i < total; i++ )); do
        [[ "${on[${ids[i]}]}" == 1 ]] || continue
        out+="${ids[i]}"$'\n'
    done
    printf '%s' "$out"
    return 0
}

# ── prompt_multiselect ─────────────────────────────────────────────────────────
# prompt_multiselect "prompt" "required_id" "off_ids" "id|label" ... — an
# interactive checklist. Arrow keys (or j/k) move a cursor, space toggles the
# highlighted item, `a` selects all, `n` deselects all except the required id,
# Enter accepts, `q` aborts (returns 1). The checklist is drawn on stderr and
# redrawn in place with ANSI cursor movement; the chosen ids are printed to
# stdout, one per line, so a caller captures them with $(...).
#
# `required_id` (may be empty) is an id that cannot be toggled off and is shown
# `(required)`. `off_ids` is a space-padded, space-separated list of ids that
# start unchecked — e.g. ` vscode php `. Like prompt_yes_no/prompt_choice this is
# policy-free: it always reads the terminal — see select_steps in lib/preflight.sh
# for the TTY/CI handling.
prompt_multiselect() {
    _prompt_picker multi "$@"
}

# ── prompt_select_one ──────────────────────────────────────────────────────────
# prompt_select_one "prompt" "default_id" "id|label" ... — an interactive
# single-choice list: the cursor starts on `default_id` (item 1 when the id is
# absent or unknown), arrow keys (or j/k) move it, Enter commits the highlighted
# item, `q` aborts (returns 1, as does Ctrl-D). Drawn on stderr, redrawn in
# place; the one chosen id is printed to stdout, so a caller captures it with
# $(...). The `off_ids` slot of the shared core is deliberately empty here —
# there is nothing to pre-deselect in a radio list.
#
# Policy-free, exactly like prompt_yes_no/prompt_choice/prompt_multiselect: it
# always reads the terminal — see select_one in lib/preflight.sh for the
# TTY/CI handling.
prompt_select_one() {
    local prompt="${1:?prompt required}" default="${2:-}"; shift 2
    _prompt_picker single "$prompt" "$default" '' "$@"
}
