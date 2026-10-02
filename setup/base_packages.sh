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
source "$_setup_dir/../lib/utils.sh"

# ── Third-party repositories ──────────────────────────────────────────────────
# Only two of these actually provide a package that is not in the Ubuntu archive
# (`gdm-settings` and `grub-customizer`); the rest are kept because they carry
# newer builds of packages that are, and dropping them is a separate decision.
#
# A PPA that publishes no suite for the running Ubuntu is SKIPPED, never fatal.
# `apt update` exits 100 on any configured repository it cannot fetch, so one
# dead PPA would otherwise abort the whole run at step 1 — which is exactly what
# happened with `ubuntuhandbook1/mpv` on Ubuntu 26.04 (resolute).
_CUSTOM_REPOSITORIES=(
    'libreoffice/ppa'
    'solaar-unifying/stable'
    'ubuntuhandbook1/mpv'
    'spvkgn/deadbeef'
    'xuzhen666/gnome-mpv'
    'danielrichter2007/grub-customizer'
    'ubuntuhandbook1/gdm-settings'
)

# ── Ubuntu codename ───────────────────────────────────────────────────────────

# The suite name Launchpad publishes under, e.g. `noble`, `resolute`. Empty when
# /etc/os-release is unreadable or carries no codename (Debian, for instance).
os_codename() {
    local codename=''
    if [[ -r /etc/os-release ]]; then
        codename="$(
            set +u
            . /etc/os-release 2>/dev/null >/dev/null || true
            printf '%s' "${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
        )"
    fi
    printf '%s' "$codename"
}

# ── PPA suite probe ───────────────────────────────────────────────────────────

# ppa_suite_available "owner/name" — does this PPA publish a suite for the
# running Ubuntu? A HEAD request against the Release file is enough; we never
# download the index.
ppa_suite_available() {
    local ppa="${1:?ppa required}"
    local codename
    codename="$(os_codename)"
    [[ -n "$codename" ]] || return 1
    curl -fsI --max-time 15 \
        "https://ppa.launchpadcontent.net/${ppa}/ubuntu/dists/${codename}/Release" \
        >/dev/null 2>&1
}

# add_custom_repositories ppa [ppa ...] — add the PPAs it is handed.
#
# It is HANDED the list rather than probing for itself because `run` redirects
# this function's stdout and stderr into the log file: a warning printed from
# in here would never reach the terminal, and "which PPA did you skip, and why"
# is exactly the thing a user needs to see. The probe therefore runs in
# base_packages_setup, outside the redirect.
add_custom_repositories() {
    local ppa

    sudo apt update
    sudo apt install software-properties-common -y

    for ppa in "$@"; do
        run "Adding $ppa" sudo add-apt-repository "ppa:$ppa" -y \
            || warn "Could not add $ppa — continuing without it (see $LOG_FILE)"
    done

    # Non-fatal on purpose: a PPA added moments ago may still be propagating, and
    # install_base_packages runs its own `apt update`, which IS fatal.
    sudo apt update || warn 'apt update reported errors — see the log for details'
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
    local codename ppa
    local -a available=()

    section 'System update and base packages installation'

    codename="$(os_codename)"

    if ! command_exists add-apt-repository; then
        warn 'add-apt-repository is not available — skipping every third-party repository'
        warn 'install software-properties-common, or take gdm-settings and grub-customizer from the archive'
    elif [[ -z "$codename" ]]; then
        warn "Could not read the Ubuntu codename — skipping every third-party repository"
    else
        for ppa in "${_CUSTOM_REPOSITORIES[@]}"; do
            if ppa_suite_available "$ppa"; then
                available+=( "$ppa" )
            else
                warn "Skipping $ppa — no suite published for $codename"
            fi
        done
    fi

    run_or_die 'Adding custom repositories' add_custom_repositories \
        ${available[@]+"${available[@]}"}
    run_or_die 'Installing base packages' install_base_packages
}