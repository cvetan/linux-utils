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
# Each entry is `owner/name[|package]`. Only two of these supply a package that
# is not in the Ubuntu archive (`gdm-settings` and `grub-customizer`); the rest
# are kept because they carry newer builds of packages that are. The optional
# package after the pipe is requested ONLY when that PPA was successfully added,
# so a skipped repository can never turn into a package that is missing from
# every configured source and aborts the run.
#
# A PPA that publishes no suite for the running Ubuntu is SKIPPED, never fatal.
# `apt update` exits 100 on any configured repository it cannot fetch, so one
# dead PPA would otherwise abort the whole run at step 1 — which is exactly what
# happened with `ubuntuhandbook1/mpv` on Ubuntu 26.04 (resolute).
_CUSTOM_REPOSITORIES=(
    'libreoffice/ppa|'
    'solaar-unifying/stable|'
    'ubuntuhandbook1/mpv|'
    'spvkgn/deadbeef|'
    'xuzhen666/gnome-mpv|'
    'danielrichter2007/grub-customizer|grub-customizer'
    'ubuntuhandbook1/gdm-settings|gdm-settings'
)

# ── Package sets ──────────────────────────────────────────────────────────────

# Core: the run cannot continue without these, and a release that does not carry
# one stops the run rather than leaving a half-configured machine.
_CORE_PACKAGES=(
    build-essential
    curl wget zip unzip
    git zsh
    gnupg ca-certificates lsb-release
    openssh-client
    xclip
    htop tmux
)

# Best-effort: desktop, media and release-specific extras. Anything the running
# release does not carry (fastfetch before 24.04, gdm-settings when its PPA was
# skipped, a package renamed after 26.04) is warned about and skipped, never
# fatal — a missing screensaver is not a reason to abandon the whole machine.
_OPTIONAL_PACKAGES=(
    ubuntu-restricted-extras
    bat fd-find xsel
    btop fastfetch
    synaptic apt-xapian-index
    powerline fonts-powerline
    dconf-editor libglib2.0-dev-bin
    gnome-shell-extension-manager gnome-tweaks
    solaar deluge
    mpv celluloid
    libreoffice libreoffice-style-sifr
    pipx
)

# ── Ubuntu codename ───────────────────────────────────────────────────────────

# The suite name Launchpad publishes under, e.g. `noble`, `resolute`. UBUNTU
# codename first: /etc/os-release sets it on derivatives too (Linux Mint,
# Pop!_OS, Zorin), where VERSION_CODENAME is the derivative's own codename and
# would match nothing on Launchpad. Empty when /etc/os-release is unreadable.
os_codename() {
    local codename=''
    if [[ -r /etc/os-release ]]; then
        codename="$(
            set +u
            . /etc/os-release 2>/dev/null >/dev/null || true
            printf '%s' "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
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
    command_exists curl || return 1
    curl -fsI --max-time 15 \
        "https://ppa.launchpadcontent.net/${ppa}/ubuntu/dists/${codename}/Release" \
        >/dev/null 2>&1
}

# _ppa_package "owner/name" — the archive-only package a PPA supplies, if any.
_ppa_package() {
    local entry
    for entry in "${_CUSTOM_REPOSITORIES[@]}"; do
        if [[ "${entry%%|*}" == "$1" ]]; then
            printf '%s' "${entry#*|}"
            return 0
        fi
    done
    return 1
}

# ── apt helpers ───────────────────────────────────────────────────────────────

# curl, gnupg and add-apt-repository are not guaranteed on a minimal Ubuntu
# image (nor in this repo's Dockerfile), yet the PPA probe below needs curl and
# adding a PPA needs add-apt-repository. Install them FIRST: otherwise every PPA
# is skipped, and the install then fails on the packages that exist only there.
install_repo_prerequisites() {
    _sudo apt update
    _sudo apt install -y ca-certificates curl gnupg software-properties-common

    # Minimal and cloud images enable only `main`; the CLI set (bat, fd-find,
    # ...) and ubuntu-restricted-extras live in universe/multiverse. Enabling
    # both is idempotent, and a no-op on a full desktop image.
    _sudo add-apt-repository -y universe
    _sudo add-apt-repository -y multiverse
    _sudo apt update
}

# Pre-accept the Microsoft core-fonts EULA that ubuntu-restricted-extras pulls
# in. With DEBIAN_FRONTEND=noninteractive but no preseed, ttf-mscorefonts-
# installer still drops into a license prompt that stalls an unattended run.
preseed_debconf() {
    printf 'ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true\n' \
        | _sudo debconf-set-selections
}

update_and_upgrade() {
    _sudo apt update
    _sudo apt upgrade -y
}

install_packages() {
    _sudo apt install -y "$@"
}

# Ubuntu ships bat as `batcat`; the `cat` alias in setup/zsh.sh expects `bat`.
link_cli_aliases() {
    if command_exists batcat && ! command_exists bat; then
        mkdir -p "$HOME/.local/bin"
        ln -sf "$(command -v batcat)" "$HOME/.local/bin/bat"
    fi
}

# ── Repositories ──────────────────────────────────────────────────────────────

# add_custom_repositories ppa [ppa ...] — add the PPAs it is handed.
#
# It is HANDED the list rather than probing for itself because `run` redirects
# this function's stdout and stderr into the log file: a warning printed from
# in here would never reach the terminal, and "which PPA did you skip, and why"
# is exactly the thing a user needs to see. The probe therefore runs in
# base_packages_setup, outside the redirect.
add_custom_repositories() {
    local ppa
    for ppa in "$@"; do
        run "Adding $ppa" _sudo add-apt-repository "ppa:$ppa" -y \
            || warn "Could not add $ppa — continuing without it (see $LOG_FILE)"
    done

    # Non-fatal on purpose: a PPA added moments ago may still be propagating, and
    # update_and_upgrade runs its own `apt update`.
    _sudo apt update || warn 'apt update reported errors — see the log for details'
}

# ── base_packages_setup ───────────────────────────────────────────────────────
base_packages_setup() {
    local codename ppa entry pkg
    local -a available=() candidates=() install=() missing=()

    section 'System update and base packages installation'

    # The probe below needs curl and a PPA needs add-apt-repository; neither is
    # guaranteed on a fresh image. Bootstrap them before deciding anything.
    run_or_die 'Installing repository prerequisites' install_repo_prerequisites

    codename="$(os_codename)"
    if [[ -z "$codename" ]]; then
        warn 'Could not read the Ubuntu codename — skipping every third-party repository'
    else
        for entry in "${_CUSTOM_REPOSITORIES[@]}"; do
            ppa="${entry%%|*}"
            if ppa_suite_available "$ppa"; then
                available+=( "$ppa" )
            else
                warn "Skipping $ppa — no suite published for $codename"
            fi
        done
    fi

    run_or_die 'Adding custom repositories' add_custom_repositories \
        ${available[@]+"${available[@]}"}

    run_or_die 'Updating and upgrading packages' update_and_upgrade
    run_or_die 'Pre-accepting the core fonts EULA' preseed_debconf

    # Resolve the package list against what the configured repositories carry.
    # Core packages abort the run when missing; the extras and the PPA-only
    # packages are best-effort, so a package a given release does not ship warns
    # instead of taking the whole run down with it.
    for pkg in "${_CORE_PACKAGES[@]}"; do
        if apt-cache show "$pkg" >/dev/null 2>&1; then
            install+=( "$pkg" )
        else
            error "required package not available: $pkg"
            return 1
        fi
    done

    candidates=( "${_OPTIONAL_PACKAGES[@]}" )
    for ppa in ${available[@]+"${available[@]}"}; do
        pkg="$(_ppa_package "$ppa" 2>/dev/null || true)"
        if [[ -n "$pkg" ]]; then
            candidates+=( "$pkg" )
        fi
    done

    for pkg in "${candidates[@]}"; do
        if apt-cache show "$pkg" >/dev/null 2>&1; then
            install+=( "$pkg" )
        else
            missing+=( "$pkg" )
        fi
    done

    if (( ${#missing[@]} )); then
        warn "Not carried by the configured repositories, skipping: ${missing[*]}"
    fi

    run_or_die 'Installing base packages' install_packages ${install[@]+"${install[@]}"}

    link_cli_aliases
}
