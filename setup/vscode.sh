#!/usr/bin/env bash
# =============================================================================
# setup/vscode.sh — Visual Studio Code from Microsoft's apt repository
# =============================================================================
# A step of main.sh, not a standalone program: it draws with lib/ui.sh and runs
# commands with run_or_die, which main.sh defines. `gui_available` comes from
# lib/preflight.sh, which main.sh sources before the step modules.
#
# Called from main.sh as step 10 — near the end, with the other GUI step — and
# skipped entirely on a machine with no graphical environment; remove that call
# to leave it out.

# ── Guard against double sourcing ─────────────────────────────────────────────
[[ -n "${_VSCODE_SH_LOADED:-}" ]] && return
readonly _VSCODE_SH_LOADED=1

_setup_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_setup_dir/../lib/ui.sh"
source "$_setup_dir/../lib/log.sh"
source "$_setup_dir/../lib/utils.sh"

# Microsoft's repository publishes one distro-independent suite, so there is no
# codename to resolve here — unlike Docker's repository in setup/docker.sh.
_VSCODE_KEYRING='/etc/apt/keyrings/packages.microsoft.gpg'
_VSCODE_LIST='/etc/apt/sources.list.d/vscode.list'
_VSCODE_URL='https://packages.microsoft.com/repos/code'

add_vscode_repo() {
    local key_tmp

    _sudo apt update
    _sudo apt install -y wget gpg apt-transport-https

    # The dearmored key goes to a temporary file, not the current directory: the
    # repo is meant to be runnable from anywhere, and dropping a .gpg into
    # $PWD would litter whatever directory the user happened to be in. `pipefail`
    # (set by main.sh) is what makes a failed download fatal — `gpg --dearmor`
    # exits non-zero on empty input, but without pipefail the wget failure would
    # be masked by gpg's status and install an empty keyring.
    key_tmp="$(mktemp)" || return 1
    if ! curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
        | gpg --dearmor --yes -o "$key_tmp"; then
        rm -f "$key_tmp"
        return 1
    fi

    _sudo install -D -o root -g root -m 0644 "$key_tmp" "$_VSCODE_KEYRING"
    rm -f "$key_tmp"

    _sudo tee "$_VSCODE_LIST" >/dev/null <<EOF
deb [arch=amd64,arm64,armhf signed-by=$_VSCODE_KEYRING] $_VSCODE_URL stable main
EOF

    _sudo apt update
}

install_vscode() {
    _sudo apt install -y code
}

vscode_setup() {
    section 'Visual Studio Code'

    # GUI-only: on WSL, a server or a container there is no display to open a
    # window on, so the step is skipped the same way main.sh deselects it up
    # front. SETUP_GUI=1 is the override for a machine that knows better (WSLg,
    # a remote X session).
    if ! gui_available; then
        info 'No graphical environment — skipping Visual Studio Code (SETUP_GUI=1 to install it).'
        return 0
    fi

    if command_exists code; then
        local version
        version="$(code --version 2>/dev/null | head -n1 || printf '')"
        [[ -n "$version" ]] || version='version unavailable'
        info "Visual Studio Code already installed ($version). Skipping."
    else
        run_or_die 'Adding the VS Code repository' add_vscode_repo
        run_or_die 'Installing Visual Studio Code'  install_vscode
        info "VS Code installed. Launch it with 'code'."

        # The git step runs BEFORE this one, so configure_git_editor could not
        # find `code` when it looked and left core.editor unchanged. Re-apply it
        # now — but only where a git identity is already configured, so this
        # never conjures a ~/.gitconfig onto a machine that never asked for one.
        if declare -F configure_git_editor >/dev/null 2>&1 \
            && command_exists git \
            && git config --global --get user.email >/dev/null 2>&1; then
            configure_git_editor
        fi
    fi
}