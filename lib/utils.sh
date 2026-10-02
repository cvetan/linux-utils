#!/usr/bin/env bash
# =============================================================================
# lib/utils.sh — small generic helpers with no UI or environment dependency
# =============================================================================

# ── Guard against double sourcing ─────────────────────────────────────────────
[[ -n "${_UTILS_SH_LOADED:-}" ]] && return
readonly _UTILS_SH_LOADED=1

# command_exists "cmd" — `command -v` with a quiet failure mode.
command_exists() { command -v "$1" &>/dev/null; }

# append_if_missing file marker content — the idempotency primitive for editing
# dotfiles: append content only when the marker is not already in the file.
append_if_missing() {
    local file="${1:?file required}"
    local marker="${2:?marker required}"
    local content="${3:?content required}"
    grep -qF "$marker" "$file" 2>/dev/null || echo -e "$content" >> "$file"
}
