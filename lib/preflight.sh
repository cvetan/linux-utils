#!/usr/bin/env bash
# =============================================================================
# lib/preflight.sh — machine detection, requirement checks, confirmation
# =============================================================================
# Everything that inspects the machine or decides whether to go ahead lives
# here, not in lib/ui.sh. Nothing here calls `exit`: `preflight` returns a
# status and the entrypoint turns it into an exit code.
#
# The `## Requirements` section of README.md is the single source of truth for
# the wording of each requirement. The list is parsed from it at run time, then
# each bullet is matched against a registered check below. A bullet with no
# check, or a check with no bullet, is reported rather than silently ignored.

# ── Guard against double sourcing ─────────────────────────────────────────────
[[ -n "${_PREFLIGHT_SH_LOADED:-}" ]] && return
readonly _PREFLIGHT_SH_LOADED=1

_preflight_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_preflight_lib_dir/ui.sh"
source "$_preflight_lib_dir/utils.sh"

# ── Registered requirement checks ─────────────────────────────────────────────
# key|predicate|detail
#   `key` must appear as a whole word in the normalised README bullet. The bullet
#   supplies the label that gets printed, so the README stays authoritative for
#   wording and this table only carries the machine-specific logic.
_REQ_CHECKS=(
    'linux|_req_check_linux|_req_detail_linux'
    'bash|_req_check_bash|_req_detail_bash'
    'ubuntu|_req_check_apt|_req_detail_apt'
    'sudo|_req_check_sudo|_req_detail_sudo'
)

# ── Environment detection ─────────────────────────────────────────────────────

# Print one value from /etc/os-release. Empty on any failure.
_os_release() {
    local key="${1:-}" value=''
    if [[ -r /etc/os-release ]]; then
        value="$( set +u; . /etc/os-release 2>/dev/null >/dev/null || true; printf '%s' "${!key:-}" )" || value=''
    fi
    printf '%s' "$value"
}

_req_check_linux() { [[ "$(uname -s)" == "Linux" ]]; }
_req_detail_linux() { printf 'kernel %s' "$(uname -sr)"; }

_req_check_bash() { (( BASH_VERSINFO[0] >= 4 )); }
_req_detail_bash() { printf 'bash %s' "$BASH_VERSION"; }

_req_check_apt() {
    # Ubuntu-like only (Ubuntu itself, Linux Mint, Pop!_OS, Zorin, ...). Vanilla
    # Debian also reports apt, but the base package set and Docker repo in
    # setup/ are Ubuntu-specific, so accepting it here would let preflight pass
    # and step 1 fail. Derivatives carry ID_LIKE=ubuntu.
    local distro id_like
    distro="$(_os_release ID)"; id_like="$(_os_release ID_LIKE)"
    distro="${distro,,} ${id_like,,}"
    if [[ "$distro" == *ubuntu* ]]; then
        command_exists apt
    else
        return 1
    fi
}
_req_detail_apt() {
    local pretty
    pretty="$(_os_release PRETTY_NAME)"
    [[ -n "$pretty" ]] || pretty='unknown distribution'
    printf '%s, apt: %s' "$pretty" "$(command -v apt 2>/dev/null || printf 'not found')"
}

_req_check_sudo() { (( EUID == 0 )) || command_exists sudo; }
_req_detail_sudo() {
    if (( EUID == 0 )); then
        printf 'running as root — sudo not needed'
    else
        printf 'sudo: %s' "$(command -v sudo 2>/dev/null || printf 'not found')"
    fi
}

# ── README lookup ─────────────────────────────────────────────────────────────

# Default README path: one level up from lib/. Override with PREFLIGHT_README
# (UI_README is still honoured).
_preflight_default_readme() {
    local root
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)" || root="$PWD"
    printf '%s\n' "${PREFLIGHT_README:-${UI_README:-${root}/README.md}}"
}

# Trim leading/trailing whitespace.
_trim() {
    local s="${1:-}"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# readme_section "Heading" [file] — print the body of `## Heading` in a markdown
# file, stopping at the next heading. Returns 1 if the file is unreadable and
# 2 when no heading was given.
readme_section() {
    if (( $# < 1 )) || [[ -z "${1:-}" ]]; then
        error 'readme_section: heading required'
        return 2
    fi
    local heading="$1"
    local file="${2:-$(_preflight_default_readme)}"
    local line='' heading_text='' inside=0

    [[ -r "$file" ]] || return 1

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^#{1,6}[[:space:]]+(.+)$ ]]; then
            heading_text="$(_trim "${BASH_REMATCH[1]}")"
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

# Normalise a requirement bullet to the text a check key is matched against:
# drop markdown, drop a trailing parenthetical, cut at an em/en dash, lowercase.
_req_norm() {
    local s="${1:-}"
    s="${s//\`/}"
    s="${s//\*\*/}"
    s="${s%%(*}"
    s="${s%%—*}"
    s="${s%%–*}"
    s="${s,,}"
    s="$(_trim "$s")"
    s="${s%%[.,;:!?]*}"
    _trim "$s"
}

# One requirement bullet per line, verbatim. The single place both the renderer
# and the checks read the list from.
_req_bullets() {
    local file="${1:-$(_preflight_default_readme)}"
    local body='' line=''
    local bullet_re='^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]+(.+)$'

    body="$(readme_section 'Requirements' "$file")" || return 1
    [[ -n "$body" ]] || return 1

    while IFS= read -r line; do
        if [[ "$line" =~ $bullet_re ]]; then
            printf '%s\n' "${BASH_REMATCH[2]}"
        fi
    done <<< "$body"
}

# ── show_requirements [file] ──────────────────────────────────────────────────
# Render the README `## Requirements` bullets as a numbered checklist.
# Warns (and returns 1) if there is nothing to show.
show_requirements() {
    local file="${1:-$(_preflight_default_readme)}"
    local text='' index=0
    local -a bullets=()

    mapfile -t bullets < <(_req_bullets "$file")

    section 'Requirements'

    if (( ${#bullets[@]} == 0 )); then
        warn "no '## Requirements' bullets found in ${file}"
        return 1
    fi

    for text in "${bullets[@]}"; do
        index=$(( index + 1 ))
        bullet "${index}." "$text"
    done
}

# ── check_requirements [file] ─────────────────────────────────────────────────
# Verify the machine against every README requirement, printing the observed
# value next to the verdict. Returns 1 if any check failed. Requirements with no
# registered check are reported as unverified rather than passing silently.
check_requirements() {
    local file="${1:-$(_preflight_default_readme)}"
    local failed=0 unverified=0 row=-1 i
    local text label key row_key predicate detail_fn
    local -a bullets=() used=()

    mapfile -t bullets < <(_req_bullets "$file")

    for (( i = 0; i < ${#_REQ_CHECKS[@]}; i++ )); do
        used[i]=0
    done

    for text in ${bullets[@]+"${bullets[@]}"}; do
        label="$(md_inline "$text")"
        key="$(_req_norm "$text")"
        row=-1

        for i in "${!_REQ_CHECKS[@]}"; do
            (( used[i] )) && continue
            row_key="${_REQ_CHECKS[$i]%%|*}"
            if [[ "$key" =~ (^|[[:space:]])${row_key}([[:space:]]|$) ]]; then
                row=$i
                break
            fi
        done

        if (( row < 0 )); then
            step "${label} — no automated check, unverified"
            unverified=$(( unverified + 1 ))
            continue
        fi

        used[row]=1
        IFS='|' read -r row_key predicate detail_fn <<< "${_REQ_CHECKS[row]}"

        if "$predicate"; then
            success "${label} — $("$detail_fn")"
        else
            error "${label} — $("$detail_fn")"
            failed=1
        fi
    done

    if (( ${#bullets[@]} == 0 )); then
        warn "no '## Requirements' bullets found in ${file}"
    else
        for i in "${!_REQ_CHECKS[@]}"; do
            if (( ! used[i] )); then
                key="${_REQ_CHECKS[$i]%%|*}"
                warn "check '${key}' has no matching requirement in ${file}"
            fi
        done
    fi

    if (( unverified )); then
        step "${unverified} requirement(s) could not be verified automatically"
    fi

    return "$failed"
}

# ── confirm "prompt" ──────────────────────────────────────────────────────────
# Policy wrapper around prompt_yes_no: auto-approves when SETUP_ASSUME_YES=1
# or when there is no terminal (CI, pipes).
#
# The check is on stdin only, like choose and ask: prompt_yes_no draws on stderr
# and reads stdin, so redirecting stdout (e.g. `main.sh | tee log`) must not be
# mistaken for an unattended run and skip the confirmation.
confirm() {
    local prompt="${1:-Continue?}"

    if [[ "${SETUP_ASSUME_YES:-0}" == "1" ]]; then
        step "$prompt — auto-approved (SETUP_ASSUME_YES=1)"
        return 0
    fi
    [[ -t 0 ]] || return 0

    prompt_yes_no "$prompt"
}

# ── choose "prompt" default item ... ──────────────────────────────────────────
# A selection with the same non-interactive policy as confirm: with
# SETUP_ASSUME_YES=1, or no terminal, it takes `default` (1-based) without
# reading. The chosen item is printed to stdout; the note goes to stderr so a
# caller's $(choose ...) never captures it. Returns 1 only when there is nothing
# to choose from.
#
# The check is on stdin only: a caller captures the selection with
# `$(choose ...)` (or via a function it captures), which redirects stdout to a
# pipe, so `-t 1` would be false by construction and the menu would never show.
# The menu and the note are drawn on stderr, which is the terminal that matters.
choose() {
    if (( $# < 1 )); then
        error 'choose: prompt required'
        return 2
    fi
    local prompt="$1" default="${2:-1}"
    local -a items=( "${@:3}" )
    (( ${#items[@]} > 0 )) || { error 'choose: no items to choose from'; return 1; }
    (( default >= 1 && default <= ${#items[@]} )) || default=1

    if [[ "${SETUP_ASSUME_YES:-0}" == "1" || ! -t 0 ]]; then
        step "$prompt — ${items[default-1]} (auto-selected)" >&2
        printf '%s\n' "${items[default-1]}"
        return 0
    fi
    prompt_choice "$prompt" "$default" "${items[@]}"
}

# ── ask "prompt" [default] ────────────────────────────────────────────────────
# Free text with the same non-interactive policy as confirm/choose: with
# SETUP_ASSUME_YES=1, or no terminal, it takes `default` without reading. The
# value is printed to stdout. Returns 1 when there is nothing to answer with
# (no terminal and no default), so a caller that needs a value can react.
#
# The check is on stdin only: a caller captures the value with `$(ask ...)`,
# which redirects stdout to a pipe, so `-t 1` is false by construction. The
# prompt and any note are drawn on stderr, which is the terminal that matters.
ask() {
    if (( $# < 1 )); then
        error 'ask: prompt required'
        return 2
    fi
    local prompt="$1" default="${2:-}"

    if [[ "${SETUP_ASSUME_YES:-0}" == "1" || ! -t 0 ]]; then
        if [[ -z "$default" ]]; then
            step "$prompt — no terminal, skipping" >&2
            return 1
        fi
        step "$prompt — $default (auto-filled)" >&2
        printf '%s\n' "$default"
        return 0
    fi
    prompt_input "$prompt" "$default"
}

# ── _interactive_ok ───────────────────────────────────────────────────────────
# Can an arrow-key list actually be shown and read? The keys arrive on stdin
# and the menu is drawn on stderr (a caller captures stdout), so both must be
# terminals — `main.sh 2>log` would otherwise wait for keys nobody can see —
# TERM must render the ANSI the picker draws with, and the window must be at
# least 6x15: an item row needs 14 columns and the shortest possible frame
# needs 5 lines (those limits must match the geometry floor in ui.sh's
# _prompt_picker, which draws at 80x24 when the size is unreadable). The
# select_* wrappers fall back to their non-interactive path when this fails.
_interactive_ok() {
    [[ -t 0 && -t 2 && ${TERM:-dumb} != dumb ]] || return 1

    # Size unreadable: assume usable — only a size we could read and know to
    # be too small rules the menu out.
    local sz=''
    sz="$(stty size 2>/dev/null)" || sz=''
    [[ -n "$sz" ]] || return 0
    [[ "$sz" =~ ^([0-9]+)[[:space:]]+([0-9]+)$ ]] || return 0
    (( BASH_REMATCH[1] >= 6 && BASH_REMATCH[2] >= 15 ))
}

# _select_fallback_note "prompt" — explain why a selection just answered
# itself. Three cases: SETUP_ASSUME_YES was asked for (no prompts, no note);
# no terminal at all (documented behaviour, nothing to explain); a terminal
# that cannot show the menu — stderr redirected, a TERM that cannot draw it, or
# a window too small for it.
_select_fallback_note() {
    local prompt="${1:-}" reason=''
    [[ "${SETUP_ASSUME_YES:-0}" != "1" ]] || return 0
    [[ -t 0 ]] || return 0
    if _interactive_ok; then return 0; fi

    if [[ ! -t 2 ]]; then
        reason='stderr is not a terminal, the menu would be invisible'
    elif [[ ${TERM:-dumb} == dumb ]]; then
        reason="TERM=${TERM:-unset} cannot draw the menu"
    else
        local sz=''
        sz="$(stty size 2>/dev/null)" || sz=''
        if [[ "$sz" =~ ^([0-9]+)[[:space:]]+([0-9]+)$ ]]; then
            reason="the window is ${BASH_REMATCH[2]}x${BASH_REMATCH[1]}, too small for the checklist"
        else
            reason='the window cannot show the checklist'
        fi
    fi
    step "$prompt — $reason; selecting non-interactively" >&2
}

# ── select_one "prompt" "default_id" "id|label" ... ──────────────────────────
# A single-selection with the same non-interactive policy as confirm/choose/ask:
# with SETUP_ASSUME_YES=1, or no usable terminal, it resolves `default_id`
# without reading — falling back to the first item when the id is absent from
# the list, the clamp prompt_choice applies to its 1-based index. Interactively
# it hands the terminal to prompt_select_one, whose cursor starts on that same
# resolved id. The chosen id is printed to stdout, so a caller captures it with
# $(...). Returns 1 on an interactive abort (q / Ctrl-D), 2 when there is
# nothing to choose from or the arguments are unusable, so a caller can write
# `id="$(select_one …)" || return`.
#
# The terminal check is on stdin and stderr, exactly like select_steps: the
# caller captures the value with $(...), which redirects stdout to a pipe, so
# `-t 1` would be false by construction and the menu would never show. The menu
# and any note are drawn on stderr, the terminal that matters.
select_one() {
    if (( $# < 1 )); then
        error 'select_one: prompt required'
        return 2
    fi
    local prompt="$1" default="${2:-}"
    local -a specs=( "${@:3}" )
    local spec resolved='' resolved_label=''

    (( ${#specs[@]} > 0 )) || { error 'select_one: no items to choose from'; return 2; }

    # One pass: take `default` when a spec carries its id, otherwise remember
    # the first spec as the fallback — so an unknown default still resolves to a
    # real item instead of printing an id the menu never showed.
    for spec in "${specs[@]}"; do
        if [[ -n "$default" && "${spec%%|*}" == "$default" ]]; then
            resolved="$default"
            resolved_label="${spec#*|}"
            break
        fi
        if [[ -z "$resolved" ]]; then
            resolved="${spec%%|*}"
            resolved_label="${spec#*|}"
        fi
    done

    _select_fallback_note "$prompt"

    if [[ "${SETUP_ASSUME_YES:-0}" == "1" ]] || ! _interactive_ok; then
        step "$prompt — $resolved_label (auto-selected)" >&2
        printf '%s\n' "$resolved"
        return 0
    fi

    prompt_select_one "$prompt" "$resolved" "${specs[@]}"
}

# ── select_steps "prompt" "required_id" "id|label" ... ────────────────────────
# A multi-select with the same non-interactive policy as confirm/choose/ask:
# with SETUP_ASSUME_YES=1 or no usable terminal it selects every step (minus
# SKIP_STEPS, a space-, tab- or comma-separated list of step ids) without
# reading. Interactively it hands the terminal to prompt_multiselect,
# pre-deselecting any SKIP_STEPS ids so the blocklist also seeds the
# checklist. The selected ids are printed to stdout, one per line, so a caller
# captures them with $(...). Returns 1 on an interactive abort (q / Ctrl-D) and
# 2 when there is nothing to select from or the arguments are unusable.
#
# The terminal check is on stdin and stderr, not stdout: the caller captures
# the selection with $(...), which redirects stdout to a pipe, so `-t 1` would
# be false by construction and the checklist would never show. The menu is
# drawn on stderr, the terminal that matters, exactly like choose/ask.
select_steps() {
    if (( $# < 1 )); then
        error 'select_steps: prompt required'
        return 2
    fi
    local prompt="$1" required="${2:-}"
    local -a specs=( "${@:3}" )
    local raw="${SKIP_STEPS:-}" spec known
    local -a skip_ids=()
    local skip_pat=' '

    (( ${#specs[@]} > 0 )) || { error 'select_steps: no steps to select from'; return 2; }

    if [[ -n "$raw" ]]; then
        # Commas are separators too, and any whitespace splits. Newlines and
        # tabs are turned into spaces first: `read` stops at the first newline
        # and `<<<` supplies one of its own, so splitting on it directly would
        # silently drop every id after the first line-break.
        raw="${raw//,/ }"
        raw="${raw//$'\n'/ }"
        raw="${raw//$'\t'/ }"
        IFS=' ' read -r -a skip_ids <<< "$raw" || true
        local s
        for s in "${skip_ids[@]}"; do
            [[ -n "$s" ]] || continue
            skip_pat+="$s "
            known=0
            for spec in "${specs[@]}"; do
                [[ "${spec%%|*}" == "$s" ]] && { known=1; break; }
            done
            (( known )) || warn "SKIP_STEPS: unknown step '$s' — ignored"
        done
    fi

    _select_fallback_note "$prompt"

    if [[ "${SETUP_ASSUME_YES:-0}" == "1" ]] || ! _interactive_ok; then
        _select_steps_unattended "$prompt" "$required" "$skip_pat" "${specs[@]}"
    else
        prompt_multiselect "$prompt" "$required" "$skip_pat" "${specs[@]}"
    fi
}

# _select_steps_unattended — the no-terminal path of select_steps: every step id
# except the SKIP_STEPS blocklist, with `required` forced in regardless. Ids go
# to stdout; a note about what was skipped goes to stderr.
_select_steps_unattended() {
    if (( $# < 3 )); then
        error '_select_steps_unattended: prompt, required and skip pattern required'
        return 2
    fi
    local prompt="$1" required="$2" skip_pat="$3"
    local -a specs=( "${@:4}" ) out=()
    local spec id
    for spec in "${specs[@]}"; do
        id="${spec%%|*}"
        if [[ "$id" == "$required" ]] || [[ "$skip_pat" != *" $id "* ]]; then
            out+=( "$id" )
        fi
    done
    if [[ -n "${SKIP_STEPS:-}" ]]; then
        step "$prompt — SKIP_STEPS: ${SKIP_STEPS}" >&2
    fi
    # A blank line would reach the caller as an empty "id" (and an empty
    # selection when everything, including the pattern, is skipped).
    if (( ${#out[@]} )); then
        printf '%s\n' "${out[@]}"
    fi
    return 0
}

# ── preflight [file] ──────────────────────────────────────────────────────────
# show_requirements → check_requirements → confirm. Returns 1 if a check failed,
# 130 if the user declined. Reports failed checks as warnings instead when
# SOFT_PREFLIGHT=1. The caller decides whether to exit.
preflight() {
    local file="${1:-$(_preflight_default_readme)}"

    show_requirements "$file" || true   # show_requirements already warned

    section 'Environment check'

    if ! check_requirements "$file"; then
        if [[ "${SOFT_PREFLIGHT:-0}" == "1" ]]; then
            warn 'requirements not met — continuing anyway (SOFT_PREFLIGHT=1)'
        else
            error 'requirements not met — fix the items above, or re-run with SOFT_PREFLIGHT=1 to continue anyway'
            return 1
        fi
    else
        success 'All requirements satisfied'
    fi

    if ! confirm 'Run the setup now?'; then
        warn 'Aborted by user'
        return 130
    fi
}
