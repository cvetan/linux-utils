#!/usr/bin/env bash
# =============================================================================
# setup/vscode.sh — Visual Studio Code from Microsoft's apt repository
# =============================================================================
# A step of main.sh, not a standalone program: it draws with lib/ui.sh and runs
# commands with run_or_die, which main.sh defines.
#
# Called from main.sh as step 4; remove that call to leave it out.

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

    if command_exists code; then
        local version
        version="$(code --version 2>/dev/null | head -n1 || printf '')"
        [[ -n "$version" ]] || version='version unavailable'
        info "Visual Studio Code already installed ($version). Skipping."
    else
        run_or_die 'Adding the VS Code repository' add_vscode_repo
        run_or_die 'Installing Visual Studio Code'  install_vscode
        info "VS Code installed. Launch it with 'code'."
    fi
}