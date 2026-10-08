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

    # A still-cached credential needs no prompt: leave any running spinner alone.
    if sudo -n true 2>/dev/null; then
        sudo "$@"
        return
    fi

    # Credential not cached — sudo will prompt for a password. If a spinner is
    # running, its \r redraw erases the prompt before it can be read, so pause it
    # around the authentication, then put it back. `sudo -v` refreshes the
    # credential once so later _sudo calls hit the fast path above.
    local paused=0
    if declare -F spinner_pause >/dev/null 2>&1 && [[ -n "${_SPINNER_PID:-}" ]]; then
        spinner_pause
        paused=1
    fi

    if ! sudo -v; then
        if (( paused )); then spinner_resume; fi
        return 1
    fi

    if (( paused )); then spinner_resume; fi
    sudo "$@"
}

# append_if_missing file marker content — the idempotency primitive for editing
# dotfiles: append content only when the marker is not already in the file.
# Returns 2 when an argument is missing: this library has no UI dependency, so
# the complaint goes straight to stderr instead of through `error`.
append_if_missing() {
    if (( $# < 3 )); then
        printf 'append_if_missing: file, marker and content required\n' >&2
        return 2
    fi
    local file="$1" marker="$2" content="$3"
    grep -qF "$marker" "$file" 2>/dev/null || echo -e "$content" >> "$file"
}
