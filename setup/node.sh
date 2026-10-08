#!/usr/bin/env bash
# =============================================================================
# setup/node.sh — Node.js + npm from the Ubuntu archive
# =============================================================================
# A step of main.sh, not a standalone program: it draws with lib/ui.sh and runs
# commands with run_or_die, which main.sh defines.
#
# Node comes from the distribution's own archive, NOT a third-party PPA or nvm,
# so the version follows the Ubuntu release (12 on 22.04, 18 on 24.04, 22 on
# 26.04). Debian/Ubuntu build nodejs --without-npm, so npm is a separate
# package; it is also what ships npx. This is local tooling only — projects run
# their own Node from their Docker setup.

# ── Guard against double sourcing ─────────────────────────────────────────────
[[ -n "${_NODE_SH_LOADED:-}" ]] && return
readonly _NODE_SH_LOADED=1

_setup_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_setup_dir/../lib/ui.sh"
source "$_setup_dir/../lib/utils.sh"

# npm installs global packages under this prefix; ~/.local needs no sudo and
# its bin dir is on PATH via step 1's ~/.profile line (and the zsh step's
# .zshrc line). The Composer analogue.
NPM_PREFIX="${NPM_PREFIX:-$HOME/.local}"

# The archive Node is EOL below this major (12 on 22.04, 18 on 24.04). The
# warning is deliberate: local Node is a utility, projects pin their own version
# in Docker.
_NODE_SUPPORTED_MAJOR=20

# ── Package sets ──────────────────────────────────────────────────────────────
# Core: npm (which also provides npx) cannot run without nodejs. A release that
# carries neither stops the run rather than leaving a half-working Node.
_NODE_CORE_PACKAGES=(
    nodejs
    npm
)

# Extras: empty by default. Add best-effort archive packages here (for example
# node-typescript, or node-corepack on 26.04+) and the resolver below installs
# whatever the release carries.
_NODE_EXTRA_PACKAGES=()

# Global npm packages to install alongside npm. Empty by default — add entries
# here (e.g. 'npm-check-updates') and re-run.
_NPM_GLOBAL_PACKAGES=()

_NODE_RESOLVED=()

# ── Package resolution ────────────────────────────────────────────────────────

resolve_node_packages() {
    local pkg
    local -a install=() missing=()

    for pkg in "${_NODE_CORE_PACKAGES[@]}"; do
        if apt-cache show "$pkg" >/dev/null 2>&1; then
            install+=( "$pkg" )
        else
            error "required Node package not available: $pkg"
            return 1
        fi
    done

    for pkg in ${_NODE_EXTRA_PACKAGES[@]+"${_NODE_EXTRA_PACKAGES[@]}"}; do
        if apt-cache show "$pkg" >/dev/null 2>&1; then
            install+=( "$pkg" )
        else
            missing+=( "$pkg" )
        fi
    done

    if (( ${#missing[@]} )); then
        warn "Node packages not carried by this release, skipping: ${missing[*]}"
    fi

    _NODE_RESOLVED=( "${install[@]}" )
    return 0
}

install_node_packages() {
    _sudo apt install -y "$@"
}

# ── npm configuration ─────────────────────────────────────────────────────────
# Put global packages in the user's home so `npm install -g` needs no sudo and
# its bins land in ~/.local/bin, which step 1 puts on PATH via ~/.profile.
configure_npm_prefix() {
    run_or_die 'Configuring npm global prefix' npm config set prefix "$NPM_PREFIX"
}

install_npm_globals() {
    local pkg
    for pkg in ${_NPM_GLOBAL_PACKAGES[@]+"${_NPM_GLOBAL_PACKAGES[@]}"}; do
        run_or_die "Installing global npm package $pkg" \
            npm install -g --no-fund --no-audit "$pkg"
    done
}

# ── Version reporting ─────────────────────────────────────────────────────────
node_major() {
    node --version 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/'
}

warn_if_eol() {
    local major
    major="$(node_major)"
    [[ -n "$major" ]] || return 0
    if (( major < _NODE_SUPPORTED_MAJOR )); then
        warn "Node $major from this Ubuntu release is end-of-life — use the project's Docker image for modern Node."
    fi
}

# ── node_setup ────────────────────────────────────────────────────────────────
node_setup() {
    section 'Node.js + npm'

    if command_exists node && command_exists npm; then
        info "Node already installed ($(node --version 2>/dev/null || printf 'version unavailable'), npm $(npm --version 2>/dev/null || printf 'version unavailable')). Skipping."
    else
        resolve_node_packages || return 1
        run_or_die 'Installing Node packages' install_node_packages \
            ${_NODE_RESOLVED[@]+"${_NODE_RESOLVED[@]}"}
        info "Node installed ($(node --version 2>/dev/null || printf 'version unavailable'), npm $(npm --version 2>/dev/null || printf 'version unavailable'))."
    fi

    configure_npm_prefix
    install_npm_globals
    warn_if_eol
}
