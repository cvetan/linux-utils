#!/usr/bin/env bash
# =============================================================================
# setup/firefox.sh — Firefox as a deb instead of Ubuntu's snap
# =============================================================================
# A step of main.sh, not a standalone program: it draws with lib/ui.sh and calls
# run_or_die, which main.sh defines. `confirm` comes from lib/preflight.sh, which
# main.sh sources before the step modules (setup/xbox.sh relies on the same).
#
# Ubuntu ships Firefox as a snap. This step is for the machine that wants the
# Mozilla team's apt build instead: it removes the snap, purges the snap-
# transitional deb, adds ppa:mozillateam/ppa, pins that archive above the Ubuntu
# archive and installs `firefox` from it.
#
# It is gated hard, because it is destructive and pointless on most machines:
# it runs only when `snap list firefox` finds the snap AND no real deb build is
# installed. Ubuntu's `1:1snap…` transition package does NOT count as a deb —
# it is what pulls the snap in, so counting it would make this step never run on
# a stock desktop. The step still asks before touching anything; INSTALL_FIREFOX
# overrides the prompt (1 installs, 0 skips) exactly like INSTALL_XBOX.
#
# The PPA is probed before it is added: apt update exits non-zero on a
# repository it cannot fetch, so a PPA with no suite for the running release
# must be skipped with a warning rather than abort the run — the same policy as
# the PPAs in setup/base_packages.sh.

# ── Guard against double sourcing ─────────────────────────────────────────────
[[ -n "${_FIREFOX_SH_LOADED:-}" ]] && return
readonly _FIREFOX_SH_LOADED=1

_setup_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_setup_dir/../lib/ui.sh"
source "$_setup_dir/../lib/log.sh"
source "$_setup_dir/../lib/utils.sh"

# INSTALL_FIREFOX: unset asks before installing; 1 installs, 0 skips, both without
# a prompt. Honors the usual SETUP_ASSUME_YES / no-TTY policy through `confirm`.
INSTALL_FIREFOX="${INSTALL_FIREFOX:-}"

# The Launchpad PPA and the two files that make its build stick. The pin raises
# the PPA above the Ubuntu archive (whose default priority is 500), so a
# `firefox` install resolves to the deb rather than the snap transition package.
_FIREFOX_PPA='mozillateam/ppa'
_FIREFOX_PREF_FILE='/etc/apt/preferences.d/mozilla-firefox'
_FIREFOX_APT_CONF='/etc/apt/apt.conf.d/51unattended-upgrades-firefox'

# ── Detection ─────────────────────────────────────────────────────────────────

# _firefox_codename — the Ubuntu suite name, e.g. `noble`. UBUNTU_CODENAME first:
# /etc/os-release sets it on derivatives too (Linux Mint, Pop!_OS, Zorin), where
# VERSION_CODENAME is the derivative's own codename and would match nothing on
# Launchpad. Empty when /etc/os-release is unreadable.
_firefox_codename() {
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

# _firefox_snap_installed — true when snapd is present and carries Firefox. The
# daemon may be absent or unreachable (containers, some servers), in which case
# snap fails and there is nothing to replace.
_firefox_snap_installed() {
    command_exists snap || return 1
    snap list firefox >/dev/null 2>&1
}

# _firefox_deb_installed — true when the installed `firefox` package is a real
# apt build rather than Ubuntu's snap transition package. The transition carries
# an epoch'd `1:1snap…` version; the Mozilla build does not.
_firefox_deb_installed() {
    local status='' version=''

    status="$(dpkg-query -W -f='${Status}' firefox 2>/dev/null || true)"
    [[ "$status" == *'install ok installed'* ]] || return 1

    version="$(dpkg-query -W -f='${Version}' firefox 2>/dev/null || true)"
    [[ "$version" == 1:1snap* ]] && return 1
    return 0
}

# _firefox_ppa_suite_available — does the PPA publish a suite for the running
# release? A HEAD request against its Release file is enough; the index is never
# downloaded.
_firefox_ppa_suite_available() {
    local codename
    codename="$(_firefox_codename)"
    [[ -n "$codename" ]] || return 1
    command_exists curl || return 1
    curl -fsI --max-time 15 \
        "https://ppa.launchpadcontent.net/${_FIREFOX_PPA}/ubuntu/dists/${codename}/Release" \
        >/dev/null 2>&1
}

# ── Install ───────────────────────────────────────────────────────────────────

remove_firefox_snap() {
    _sudo snap remove firefox
}

# Purge both the snap transition package and, on a re-run that got this far, any
# half-installed deb. apt exits 0 when the package is absent.
purge_firefox_deb() {
    _sudo apt purge -y firefox
}

add_firefox_ppa() {
    _sudo add-apt-repository -y "ppa:${_FIREFOX_PPA}"
}

# Pin the PPA above the Ubuntu archive so `apt install firefox` cannot fall back
# to the snap transition package. `o=LP-PPA-mozillateam` is Launchpad's origin
# for the PPA; it is derived from the PPA owner rather than hardcoded twice.
pin_firefox_ppa() {
    local owner="${_FIREFOX_PPA%%/*}"
    _sudo tee "$_FIREFOX_PREF_FILE" >/dev/null <<EOF
Package: *
Pin: release o=LP-PPA-${owner}
Pin-Priority: 1001
EOF
}

# Register the pinned PPA with unattended-upgrades, so security updates to the
# deb keep flowing without manual approval. The suite is resolved at run time.
allow_firefox_unattended_upgrades() {
    local codename owner
    codename="$(_firefox_codename)"
    owner="${_FIREFOX_PPA%%/*}"
    _sudo tee "$_FIREFOX_APT_CONF" >/dev/null <<EOF
Unattended-Upgrade::Allowed-Origins:: "LP-PPA-${owner}:${codename}";
EOF
}

update_firefox_index() {
    _sudo apt update
}

install_firefox_deb() {
    _sudo apt install -y firefox
}

# ── firefox_setup ─────────────────────────────────────────────────────────────
firefox_setup() {
    section 'Firefox (Mozilla APT build)'

    if ! _firefox_snap_installed; then
        info 'No Firefox snap detected. Skipping.'
        return 0
    fi

    if _firefox_deb_installed; then
        info 'Firefox is already installed as a deb. Skipping.'
        return 0
    fi

    case "${INSTALL_FIREFOX}" in
        0|no|false)
            info 'Firefox snap detected — skipping the deb install (INSTALL_FIREFOX=0).'
            return 0
            ;;
        1|yes|true)
            : # proceed without asking
            ;;
        *)
            if ! confirm 'Firefox is installed as a snap — replace it with the Mozilla APT (deb) build?'; then
                warn 'Skipping the Firefox deb install.'
                return 0
            fi
            ;;
    esac

    if ! _firefox_ppa_suite_available; then
        warn "Skipping the Firefox deb install — the ${_FIREFOX_PPA} PPA has no suite for '$(_firefox_codename)'"
        return 0
    fi

    run_or_die 'Removing the Firefox snap' remove_firefox_snap
    run_or_die 'Purging the Firefox snap-transition package' purge_firefox_deb
    run_or_die 'Adding the Mozilla team PPA' add_firefox_ppa
    run_or_die 'Pinning the Mozilla team PPA' pin_firefox_ppa
    run_or_die 'Allowing Firefox unattended upgrades' allow_firefox_unattended_upgrades
    run_or_die 'Updating the package index' update_firefox_index
    run_or_die 'Installing Firefox (deb)' install_firefox_deb

    success 'Firefox installed as a deb package.'
}
