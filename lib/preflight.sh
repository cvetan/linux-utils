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
    # Debian also reports apt-get, but the base package set and Docker repo in
    # setup/ are Ubuntu-specific, so accepting it here would let preflight pass
    # and step 1 fail. Derivatives carry ID_LIKE=ubuntu.
    local distro id_like
    distro="$(_os_release ID)"; id_like="$(_os_release ID_LIKE)"
    distro="${distro,,} ${id_like,,}"
    if [[ "$distro" == *ubuntu* ]]; then
        command_exists apt-get
    else
        return 1
    fi
}
_req_detail_apt() {
    local pretty
    pretty="$(_os_release PRETTY_NAME)"
    [[ -n "$pretty" ]] || pretty='unknown distribution'
    printf '%s, apt-get: %s' "$pretty" "$(command -v apt-get 2>/dev/null || printf 'not found')"
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
# file, stopping at the next heading. Returns 1 if the file is unreadable.
readme_section() {
    local heading="${1:?heading required}"
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
    local prompt="${1:?prompt required}" default="${2:-1}"; shift 2
    local -a items=( "$@" )
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
    local prompt="${1:?prompt required}" default="${2:-}"

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
