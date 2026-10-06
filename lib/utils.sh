#!/usr/bin/env bash
# =============================================================================
# lib/utils.sh — small generic helpers with no UI or environment dependency
# =============================================================================

# ── Guard against double sourcing ─────────────────────────────────────────────
[[ -n "${_UTILS_SH_LOADED:-}" ]] && return
readonly _UTILS_SH_LOADED=1

# command_exists "cmd" — `command -v` with a quiet failure mode.
command_exists() { command -v "$1" &>/dev/null; }

# _sudo cmd ... — run a command with sudo, except when already root.
#
# Keeps the modules working on a minimal image that ships no sudo binary at all
# (preflight explicitly treats root as meeting the sudo requirement). A truly
# unattended run still needs to be root or have passwordless sudo — see the
# README's "Unattended runs" section.
_sudo() {
    if (( EUID == 0 )); then
        "$@"
        return
    fi

    # Unless the sudo credential is still cached, sudo prompts for a password on
    # the terminal. If a spinner is running, its \r redraw erases the prompt
    # before it can be read, so pause it around the authentication, then put it
    # back. `sudo -n true` is silent when the credential is cached, so the common
    # case never touches the spinner.
    local paused=0
    if declare -F spinner_pause >/dev/null 2>&1 && [[ -n "${_SPINNER_PID:-}" ]]; then
        spinner_pause
        paused=1
    fi

    if ! sudo -n true 2>/dev/null; then
        if ! sudo -v; then
            if (( paused )); then spinner_resume; fi
            return 1
        fi
    fi

    if (( paused )); then spinner_resume; fi
    sudo "$@"
}

# append_if_missing file marker content — the idempotency primitive for editing
# dotfiles: append content only when the marker is not already in the file.
append_if_missing() {
    local file="${1:?file required}"
    local marker="${2:?marker required}"
    local content="${3:?content required}"
    grep -qF "$marker" "$file" 2>/dev/null || echo -e "$content" >> "$file"
}
