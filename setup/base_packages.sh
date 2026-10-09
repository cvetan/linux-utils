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
# Each entry is `owner/name[|package[|when]]`. Only two of these supply a package
# that is not in the Ubuntu archive (`gdm-settings` and `grub-customizer`); the
# rest are kept because they carry newer builds of packages that are. The optional
# package after the first pipe is requested ONLY when that PPA was successfully
# added, so a skipped repository can never turn into a package that is missing
# from every configured source and aborts the run. The optional field after the
# second pipe lists the desktops the PPA serves — space-separated ids from
# detect_desktop_environment (lib/preflight.sh); empty means every desktop, and a
# run on any other desktop never probes or adds it. Keep the gnome-mpv list in
# step with _GTK_DESKTOPS below when changing either.
#
# A PPA that publishes no suite for the running Ubuntu is SKIPPED, never fatal.
# `apt update` exits 100 on any configured repository it cannot fetch, so one
# dead PPA would otherwise abort the whole run at step 1 — which is exactly what
# happened with `ubuntuhandbook1/mpv` on Ubuntu 26.04 (resolute).
_CUSTOM_REPOSITORIES=(
    'libreoffice/ppa||'
    'solaar-unifying/stable||'
    'ubuntuhandbook1/mpv||'
    'spvkgn/deadbeef||'
    'xuzhen666/gnome-mpv||gnome cinnamon xfce mate budgie unity'
    'danielrichter2007/grub-customizer|grub-customizer|'
    'ubuntuhandbook1/gdm-settings|gdm-settings|gnome'
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

# Best-effort, desktop-neutral: media, CLI and release-specific extras for ANY
# desktop — or none at all. Anything the running release does not carry
# (fastfetch before 24.04, a package renamed after 26.04) is warned about and
# skipped, never fatal — a missing screensaver is not a reason to abandon the
# whole machine. Desktop-specific extras live in _DE_PACKAGES below, so a
# machine with no detected desktop still gets all of this and nothing more.
_OPTIONAL_PACKAGES=(
    ubuntu-restricted-extras
    bat fd-find xsel
    btop fastfetch
    synaptic apt-xapian-index
    powerline fonts-powerline
    libglib2.0-dev-bin
    solaar deluge
    mpv
    libreoffice libreoffice-style-sifr
    pipx
)

# ── Desktop-specific extras ───────────────────────────────────────────────────
# Keyed by the ids detect_desktop_environment (lib/preflight.sh) prints. Only
# what the desktop itself actually uses belongs here: GNOME's tuning tools on
# GNOME, dconf-editor on the dconf-based desktops (Cinnamon, MATE, Budgie and
# Unity read their settings from dconf; Xfce's xfconf and KDE's KConfig do
# not), Xfce's extras on Xfce. A desktop with no entry — kde, lxqt, unknown —
# gets the desktop-neutral set only, which is the point: guessing GNOME on a
# machine that runs something else installs tools nothing will ever open.
declare -A _DE_PACKAGES=(
    [gnome]='gnome-shell-extension-manager gnome-tweaks dconf-editor'
    [cinnamon]='dconf-editor'
    [mate]='dconf-editor'
    [budgie]='dconf-editor'
    [unity]='dconf-editor'
    [xfce]='xfce4-goodies'
)

# GTK desktops only: celluloid is a GTK frontend for mpv, and the
# xuzhen666/gnome-mpv PPA above is what builds it — both follow the same
# desktop list, so keep _GTK_DESKTOPS and that PPA's `when` field identical.
# `mpv` itself stays in the neutral set: it is a player a terminal (or any
# other frontend) can drive anywhere.
_GTK_PACKAGES=( celluloid )
_GTK_DESKTOPS=' gnome cinnamon xfce mate budgie unity '

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
    local entry ppa pkg when
    for entry in "${_CUSTOM_REPOSITORIES[@]}"; do
        IFS='|' read -r ppa pkg when <<< "$entry"
        if [[ "$ppa" == "$1" ]]; then
            printf '%s' "$pkg"
            return 0
        fi
    done
    return 1
}

# gdm_is_active — is GDM the display manager this machine actually boots?
# /etc/X11/default-display-manager names the active manager's binary
# (`/usr/sbin/gdm3`, `gdm` on releases that renamed it), and it is rewritten
# when another manager takes over. Checked in addition to the PPA's `gnome` DE
# gate: a GNOME session can run under LightDM, and a leftover gdm3 package does
# not make gdm-settings worth installing on a machine whose greeter is
# lightdm or sddm.
gdm_is_active() {
    local dm=''
    [[ -r /etc/X11/default-display-manager ]] || return 1
    dm="$(</etc/X11/default-display-manager)"
    [[ "$dm" == *gdm* ]]
}

# ── apt helpers ───────────────────────────────────────────────────────────────

# _supports_no_update — does the installed add-apt-repository know
# `-n` / `--no-update`? That flag holds back the `apt update` each invocation
# runs by default, and a run adds two components plus seven PPAs: without it
# the machine pays for nine index refreshes before a single package is
# installed. Releases whose add-apt-repository predates the flag keep the
# original behaviour instead of failing on an unknown option.
_supports_no_update() {
    add-apt-repository --help 2>&1 | grep -q -- '--no-update'
}

# curl, gnupg and add-apt-repository are not guaranteed on a minimal Ubuntu
# image (nor in this repo's Dockerfile), yet the PPA probe below needs curl and
# adding a PPA needs add-apt-repository. Install them FIRST: otherwise every PPA
# is skipped, and the install then fails on the packages that exist only there.
install_repo_prerequisites() {
    _sudo apt update
    _sudo apt install -y ca-certificates curl gnupg software-properties-common

    # Minimal and cloud images enable only `main`; the CLI set (bat, fd-find,
    # ...) and ubuntu-restricted-extras live in universe/multiverse. Enabling
    # both is idempotent, and a no-op on a full desktop image. `-n` defers each
    # call's implicit `apt update` to the explicit one at the end, so two
    # components cost one refresh instead of three.
    local -a no_update=()
    if _supports_no_update; then
        no_update=( -n )
    fi
    _sudo add-apt-repository -y ${no_update[@]+"${no_update[@]}"} universe
    _sudo add-apt-repository -y ${no_update[@]+"${no_update[@]}"} multiverse
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

# ~/.local/bin on PATH for every login shell, zsh's own line in .zshrc
# (setup/zsh.sh) aside. This lives in step 1 rather than in the zsh step
# because step 1 runs whether or not that step is selected: a run that skips
# zsh would otherwise leave Composer (php), the npm global prefix (node) and
# the bat symlink above in a directory nothing puts on PATH. Stock Ubuntu's
# .profile already carries the same block, so its `.local/bin` marker makes
# this a no-op there; a trimmed-down .profile does not have it.
extend_profile_path() {
    append_if_missing "$HOME/.profile" '.local/bin' \
        '\nexport PATH="$HOME/.local/bin:$PATH"'
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
    local -a no_update=()
    if _supports_no_update; then
        no_update=( -n )
    fi

    for ppa in "$@"; do
        # `-n` defers each call's implicit `apt update`: seven PPAs cost one
        # index refresh (the explicit one below) instead of eight. The add
        # itself — keyring, source entry — and the failure policy are exactly
        # as before.
        run "Adding $ppa" _sudo add-apt-repository -y \
            ${no_update[@]+"${no_update[@]}"} "ppa:$ppa" \
            || warn "Could not add $ppa — continuing without it (see $LOG_FILE)"
    done

    # One refresh covers every PPA above. Non-fatal on purpose: a PPA added
    # moments ago may still be propagating, and update_and_upgrade runs its
    # own `apt update` regardless.
    _sudo apt update || warn 'apt update reported errors — see the log for details'
}

# ── base_packages_setup ───────────────────────────────────────────────────────
base_packages_setup() {
    local codename ppa pkg when entry de
    local -a available=() candidates=() install=() missing=() de_extra=()

    section 'System update and base packages installation'

    # Which desktop this machine runs decides which of the repositories and
    # packages below apply (detect_desktop_environment lives in lib/preflight.sh,
    # which main.sh sources before this module). Announced before anything is
    # touched, so the package set chosen further down is never a surprise —
    # including the deliberate absence of any desktop extras on `unknown`.
    de="$(detect_desktop_environment)"
    case "$de" in
        unknown) step 'Desktop environment not detected — installing desktop-neutral packages only' ;;
        *)       step "Desktop environment: $de" ;;
    esac

    # The probe below needs curl and a PPA needs add-apt-repository; neither is
    # guaranteed on a fresh image. Bootstrap them before deciding anything.
    run_or_die 'Installing repository prerequisites' install_repo_prerequisites

    codename="$(os_codename)"
    if [[ -z "$codename" ]]; then
        warn 'Could not read the Ubuntu codename — skipping every third-party repository'
    else
        for entry in "${_CUSTOM_REPOSITORIES[@]}"; do
            IFS='|' read -r ppa pkg when <<< "$entry"

            # Desktop-gated repositories are not probed at all on a desktop
            # they do not serve — information, not a warning: nothing is wrong
            # with a Mint box that never fetches a GNOME-only PPA.
            if [[ -n "$when" && " $when " != *" $de "* ]]; then
                step "Skipping $ppa — not used by the '$de' desktop (applies to: $when)"
                continue
            fi
            if [[ "$pkg" == 'gdm-settings' ]] && ! gdm_is_active; then
                step 'Skipping gdm-settings — GDM is not the active display manager'
                continue
            fi

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

    # The desktop-specific extras: the set for the detected desktop (nothing
    # for kde, lxqt and unknown — see _DE_PACKAGES), plus the GTK-only player
    # where a GTK stack is present. Everything then still goes through the
    # apt-cache probe below, so a desktop set naming a package this release
    # does not carry warns and is skipped like any other optional one.
    if [[ -n "${_DE_PACKAGES[$de]:-}" ]]; then
        IFS=' ' read -r -a de_extra <<< "${_DE_PACKAGES[$de]}"
        candidates+=( ${de_extra[@]+"${de_extra[@]}"} )
    fi
    if [[ "$_GTK_DESKTOPS" == *" $de "* ]]; then
        candidates+=( "${_GTK_PACKAGES[@]}" )
    fi

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
    extend_profile_path
}
