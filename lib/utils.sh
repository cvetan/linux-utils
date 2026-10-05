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
    else
        sudo "$@"
    fi
}

# append_if_missing file marker content — the idempotency primitive for editing
# dotfiles: append content only when the marker is not already in the file.
append_if_missing() {
    local file="${1:?file required}"
    local marker="${2:?marker required}"
    local content="${3:?content required}"
    grep -qF "$marker" "$file" 2>/dev/null || echo -e "$content" >> "$file"
}
