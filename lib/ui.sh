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
#            Enter accepts, `q` or Ctrl-D aborts. Prints every selected id to
#            stdout, one per line.
#   single — `anchor` is the id the cursor starts on (item 1 when it is absent
#            or unknown); `off_ids` is ignored. Arrow keys (or j/k) move, Enter
#            commits the highlighted item, `q` or Ctrl-D aborts. Prints the one
#            chosen id to stdout.
#
# Returns 0 with the value on stdout; 1 on an empty list or on an abort
# (`q`/Ctrl-D — a single-select that never committed prints nothing at all);
# 2 when the arguments are unusable (wrong arity, empty prompt, unknown mode).
# Ctrl-D is ordinary data to `read -n`, which runs non-canonical, so it needs
# its own abort arm; genuine EOF — the tty hanging up mid-read — leaves the
# loop, keeping whatever `multi` has toggled and failing a `single` that never
# committed.
#
# Deliberately policy-free: it always reads the terminal, so the TTY/CI handling
# lives in the wrappers — select_steps/select_one in lib/preflight.sh. Those
# check stdin (where the keys come from: a caller captures the value with
# $(...), which only redirects stdout) and stderr (where this draws).
#
# Every draw goes to stderr, never stdout: a bare printf here would be swallowed
# by the caller's $(...) capture and leave the terminal blank while this loop
# waits for a keypress nobody can see. `_multiselect_readkey` is the single
# exception — its key is the captured value, so stdout is its channel.
# The body of the picker, entered only through _prompt_picker below — which
# owns the cleanup of the _picker_render function this defines.
_prompt_picker_body() {
    if (( $# < 4 )); then
        error '_prompt_picker: mode, prompt, anchor and off_ids required'
        return 2
    fi
    local mode="$1" prompt="$2" anchor="$3" off="$4"
    shift 4
    case "$mode" in
        multi|single) ;;
        *) error "_prompt_picker: unknown mode '$mode'"; return 2 ;;
    esac
    if [[ -z "$prompt" ]]; then
        error '_prompt_picker: prompt required'
        return 2
    fi
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

    # ── Terminal geometry ─────────────────────────────────────────────────────
    # Two failure modes are guarded here. (1) Width: a line wider than the
    # terminal wraps, and a wrapped line makes the cursor-up redraw count rows
    # that are not there, so every drawn line is clipped to the width. (2)
    # Height: when the frame is taller than the viewport the cursor-up cannot
    # reach back past the first row, so the list is redrawn from home (clear
    # screen) with the items windowed around the cursor instead.
    #
    # An unusable terminal size keeps the historical 80x24 assumption: below 6
    # rows or 15 columns no checklist can be drawn at all (the item prefix
    # alone is 14 columns). Those two numbers must match the floor in
    # _interactive_ok, lib/preflight.sh — which sends a window that small down
    # the non-interactive path instead of letting it draw here.
    local _ms_rows=24 _ms_cols=80 _ms_geom=''
    if _ms_geom="$(stty size 2>/dev/null)" \
        && [[ "$_ms_geom" =~ ^([0-9]+)[[:space:]]+([0-9]+)$ ]] \
        && (( BASH_REMATCH[1] >= 6 && BASH_REMATCH[2] >= 15 )); then
        _ms_rows="${BASH_REMATCH[1]}"
        _ms_cols="${BASH_REMATCH[2]}"
    fi

    # Visible width each kind of line may use — ANSI colour is not counted, it
    # never occupies a column. One column is deliberately left empty: a terminal
    # that wraps immediately rather than deferring the wrap would otherwise put
    # the cursor on the next row before the line's own newline arrives, adding a
    # row the redraw does not know about. Every budget is clamped at 0, because
    # a negative substring length means "everything but the last n" — the
    # opposite of a clip. The item row's fixed part is 14 columns (cursor/mark,
    # box, number) plus the "(required)" tag when a column is left for it.
    local _ms_max=$(( _ms_cols > 0 ? _ms_cols - 1 : 0 ))
    local _ms_w_prompt=0 _ms_w_rule=0 _ms_w_label=0 _ms_w_label_tag=0
    local _ms_w_note=0 _ms_w_help=0 _ms_show_reqtag=0
    if (( _ms_max >= 5 )); then _ms_w_prompt=$(( _ms_max - 5 )); fi
    _ms_w_rule=$_ms_max
    if (( _ms_max >= 14 )); then _ms_w_label=$(( _ms_max - 14 )); fi
    if (( _ms_max >= 27 )); then
        _ms_w_label_tag=$(( _ms_max - 27 ))
        _ms_show_reqtag=1
    fi
    if (( _ms_max >= 5 )); then _ms_w_note=$(( _ms_max - 5 )); fi
    if (( _ms_max >= 2 )); then _ms_w_help=$(( _ms_max - 2 )); fi

    local _ms_lines=$(( total + 5 ))
    local _ms_first=1
    local _ms_note=''
    local _ms_inplace=1
    (( _ms_rows >= total + 5 )) || _ms_inplace=0
    local _ms_prompt="${prompt:0:_ms_w_prompt}"
    local rule help
    printf -v rule "%${UI_WIDTH}s" ''
    rule="${rule// /─}"
    rule="${rule:0:_ms_w_rule}"
    if [[ "$mode" == 'single' ]]; then
        help='↑/↓ move · Enter select · q quit'
    else
        help='↑/↓ move · space toggle · a all · n none · Enter continue · q quit'
    fi
    help="${help:0:_ms_w_help}"

    # _picker_render redraws the whole list. It is defined inside the body so
    # it reads that function's locals (dynamic scope): mode, prompt, rule,
    # help, total, ids, labels, on, cursor, anchor, the _ms_* geometry and
    # clip values, and _ms_note. Every printf here carries >&2; see the header
    # comment. _prompt_picker unsets the function again once the body returns.
    #
    # In-place mode emits exactly _ms_lines lines — blank, prompt, rule, one
    # row per item, note-or-blank, help — and walks back up that many rows to
    # redraw over itself. _ms_inplace=0 (frame taller than the viewport, where
    # cursor-up cannot reach past row 1) goes home and clears instead, showing
    # only the window of items around the cursor so the highlighted row is
    # always on screen. The trailing \033[J drops any stale tail a
    # reposition may have left below the frame.
    _picker_render() {
        local i box mark reqtag label budget
        local lo=0 hi=$(( total - 1 )) avail from

        if (( _ms_inplace )); then
            if (( ! _ms_first )); then
                printf '\033[%dA\r' "$_ms_lines" >&2
            fi
            _ms_first=0
            printf '\033[2K\n' >&2
        else
            printf '\033[H\033[2J' >&2
            # Rows for items: prompt, rule, note-or-blank and help take four,
            # and the final \n needs its own row or the frame scrolls by one.
            avail=$(( _ms_rows - 5 ))
            if (( avail < 1 )); then avail=1; fi
            if (( avail < total )); then
                from=$(( cursor - 1 - avail / 2 ))
                if (( from < 0 )); then from=0; fi
                if (( from + avail > total )); then from=$(( total - avail )); fi
                if (( from < 0 )); then from=0; fi
                lo=$from
                hi=$(( from + avail - 1 ))
                if (( hi > total - 1 )); then hi=$(( total - 1 )); fi
            fi
        fi

        printf '\033[2K  %s▶%s  %s%s%s\n' "$CYAN" "$NC" "$BOLD" "$_ms_prompt" "$NC" >&2
        printf '\033[2K%s%s%s\n' "$CYAN" "$rule" "$NC" >&2
        for (( i = lo; i <= hi; i++ )); do
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
            label="${labels[i]}"
            if [[ "$mode" != 'single' && "${ids[i]}" == "$anchor" && "$_ms_show_reqtag" == 1 ]]; then
                reqtag="  ${YELLOW}(required)${NC}"
                budget=$_ms_w_label_tag
            else
                reqtag=''
                budget=$_ms_w_label
            fi
            label="${label:0:budget}"
            printf '\033[2K%s%s  %2d. %s%s\n' \
                "$mark" "$box" "$(( i + 1 ))" "$label" "$reqtag" >&2
        done
        if [[ -n "$_ms_note" ]]; then
            printf '\033[2K  %s!%s  %s\n' "$YELLOW" "$NC" "${_ms_note:0:_ms_w_note}" >&2
        else
            printf '\033[2K\n' >&2
        fi
        printf '\033[2K  %s%s%s\n' "$CYAN" "$help" "$NC" >&2
        printf '\033[J' >&2
    }

    _picker_render
    local key
    while :; do
        _ms_note=''
        # Ctrl-D arrives as ordinary data here (read -n runs non-canonical, so
        # 0x04 is never an EOF), which is why the abort arm below lists it
        # explicitly. Real EOF — the tty gone while we read — leaves the loop:
        # multi keeps whatever is toggled, single has committed nothing and
        # must fail with an empty stdout.
        key="$(_multiselect_readkey)" || break
        case "$key" in
            ''|$'\r')
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
            'q'|$'\x04')
                printf '\n' >&2
                return 1 ;;
        esac
        _picker_render
    done

    if [[ "$mode" == 'single' ]]; then
        return 1    # real EOF without Enter: no id was chosen
    fi

    local out=''
    for (( i = 0; i < total; i++ )); do
        [[ "${on[${ids[i]}]}" == 1 ]] || continue
        out+="${ids[i]}"$'\n'
    done
    printf '%s' "$out"
    return 0
}

# _prompt_picker — the entry point the wrappers call: run the body, then drop
# the _picker_render function it defined. Bash has no closures, so without this
# a caller that invokes a prompt directly (instead of through $(...)) would
# inherit a function reading locals that no longer exist. The `|| rc=$?` keeps
# set -e and the ERR trap from seeing the body's own non-zero statuses — they
# are the picker's answer, not a failure.
_prompt_picker() {
    local rc=0
    _prompt_picker_body "$@" || rc=$?
    unset -f _picker_render 2>/dev/null || true
    return "$rc"
}

# ── prompt_multiselect ─────────────────────────────────────────────────────────
# prompt_multiselect "prompt" "required_id" "off_ids" "id|label" ... — an
# interactive checklist. Arrow keys (or j/k) move a cursor, space toggles the
# highlighted item, `a` selects all, `n` deselects all except the required id,
# Enter accepts, `q` or Ctrl-D aborts (returns 1). The checklist is drawn on
# stderr and redrawn in place — from the top of the screen with the items
# windowed around the cursor when the terminal is too short for the whole
# frame, clipped to the terminal width either way — so a caller captures the
# chosen ids on stdout, one per line, with $(...).
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
    if (( $# < 1 )); then
        error 'prompt_select_one: prompt required'
        return 2
    fi
    local prompt="$1" default="${2:-}"
    _prompt_picker single "$prompt" "$default" '' "${@:3}"
}
