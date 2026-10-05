#!/usr/bin/env bash
# =============================================================================
# setup/firefox.sh — Firefox as a deb instead of Ubuntu's snap
# =============================================================================
# A step of main.sh, not a standalone program: it draws with lib/ui.sh and calls
# run_or_die, which main.sh defines. `confirm` comes from lib/preflight.sh, and
# `os_codename` / `ppa_suite_available` from setup/base_packages.sh, both of which
# main.sh sources before the step modules (setup/xbox.sh relies on the same).
#
# Ubuntu ships Firefox as a snap. This step is for the machine that wants the
# Mozilla team's apt build instead: it removes the snap, purges the snap-
# transitional deb, adds ppa:mozillateam/ppa, pins that archive above the Ubuntu
# archive and installs `firefox` from it.
#
# It is gated hard, because it is destructive and pointless on most machines:
# it runs only when `snap list firefox` finds the snap. With no real deb it does
# the swap; with a real deb already installed it only offers to remove the
# leftover snap. Ubuntu's `1:1snap…` transition package does NOT count as a deb —
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

# ── Install ───────────────────────────────────────────────────────────────────

remove_firefox_snap() {
    _sudo snap remove firefox
}

# Purge the snap-transition `firefox` package. apt exits 0 when it is absent, so
# this is also safe if a previous attempt already removed it.
purge_firefox_deb() {
    _sudo apt purge -y firefox
}

add_firefox_ppa() {
    _sudo add-apt-repository -y "ppa:${_FIREFOX_PPA}"
}

# Pin the PPA above the Ubuntu archive so `apt install firefox` cannot fall back
# to the snap transition package. Scoped to `firefox*` (the build plus its locale
# packages) rather than `*`, so no unrelated package is ever dragged to the PPA.
# `o=LP-PPA-mozillateam` is Launchpad's origin for the PPA; it is derived from
# the PPA owner rather than hardcoded twice.
pin_firefox_ppa() {
    local owner="${_FIREFOX_PPA%%/*}"
    _sudo tee "$_FIREFOX_PREF_FILE" >/dev/null <<EOF
Package: firefox*
Pin: release o=LP-PPA-${owner}
Pin-Priority: 1001
EOF
}

# Register the pinned PPA with unattended-upgrades, so security updates to the
# deb keep flowing without manual approval. The suite is resolved at run time.
allow_firefox_unattended_upgrades() {
    local codename owner
    codename="$(os_codename)"
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
    local forced=0

    section 'Firefox (Mozilla APT build)'

    case "${INSTALL_FIREFOX}" in
        0|no|false)
            info 'Firefox step disabled (INSTALL_FIREFOX=0).'
            return 0
            ;;
        1|yes|true)
            forced=1
            ;;
    esac

    if ! _firefox_snap_installed; then
        info 'No Firefox snap detected. Skipping.'
        return 0
    fi

    if _firefox_deb_installed; then
        # A real deb build is already in place, and the snap is still here (the
        # gate above) — the swap happened once, or the deb was installed by hand.
        # There is nothing to install, so only offer to remove the redundant snap;
        # never run the purge below, which would remove the real deb.
        if (( forced )) || confirm 'Firefox is already installed as a deb — remove the leftover snap?'; then
            run 'Removing the leftover Firefox snap' remove_firefox_snap \
                || warn 'Could not remove the leftover Firefox snap — see the log'
        else
            info 'Keeping the Firefox snap alongside the deb.'
        fi
        return 0
    fi

    if (( ! forced )); then
        if ! confirm 'Firefox is installed as a snap — replace it with the Mozilla APT (deb) build?'; then
            warn 'Skipping the Firefox deb install.'
            return 0
        fi
    fi

    if ! ppa_suite_available "$_FIREFOX_PPA"; then
        warn "Skipping the Firefox deb install — the ${_FIREFOX_PPA} PPA has no suite for '$(os_codename)'"
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
