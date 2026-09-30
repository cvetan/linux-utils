#!/usr/bin/env bash
# =============================================================================
# setup/base_packages.sh — apt repositories and the base package set
# =============================================================================
# A step of main.sh, not a standalone program: it draws with lib/ui.sh and runs
# commands with run_or_die, which main.sh defines.

# ── Guard against double sourcing ─────────────────────────────────────────────
[[ -n "${_BASE_PACKAGES_SH_LOADED:-}" ]] && return
readonly _BASE_PACKAGES_SH_LOADED=1

_setup_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_setup_dir/../lib/ui.sh"

add_custom_repositories() {
    sudo apt update
    sudo apt install software-properties-common -y
    sudo add-apt-repository ppa:libreoffice/ppa -y
    sudo add-apt-repository ppa:solaar-unifying/stable -y
    sudo add-apt-repository ppa:ubuntuhandbook1/mpv -y
    sudo add-apt-repository ppa:spvkgn/deadbeef -y
    sudo add-apt-repository ppa:xuzhen666/gnome-mpv -y
    sudo add-apt-repository ppa:danielrichter2007/grub-customizer -y
    sudo add-apt-repository ppa:ubuntuhandbook1/gdm-settings  -y
}

install_base_packages() {
    sudo apt update
    sudo apt upgrade -y
    sudo apt install -y \
        build-essential \
        curl wget zip unzip \
        xclip xsel \
        gnupg ca-certificates lsb-release \
        ubuntu-restricted-extras \
        htop btop fastfetch \
        synaptic apt-xapian-index \
        git zsh powerline fonts-powerline tmux \
        dconf-editor gdm-settings libglib2.0-dev-bin \
        gnome-shell-extension-manager gnome-tweaks \
        solaar deluge \
        mpv celluloid \
        libreoffice libreoffice-style-sifr \
        grub-customizer \
        pipx
}

base_packages_setup() {
    section 'System update and base packages installation'

    run_or_die 'Adding custom repositories' add_custom_repositories
    run_or_die 'Installing base packages' install_base_packages
}
