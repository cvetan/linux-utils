#!/usr/bin/env bash
# =============================================================================
# setup/docker.sh — Docker Engine from the official apt repository
# =============================================================================
# A step of main.sh, not a standalone program: it draws with lib/ui.sh and runs
# commands with run_or_die, which main.sh defines.

# ── Guard against double sourcing ─────────────────────────────────────────────
[[ -n "${_DOCKER_SH_LOADED:-}" ]] && return
readonly _DOCKER_SH_LOADED=1

_setup_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_setup_dir/../lib/ui.sh"
source "$_setup_dir/../lib/utils.sh"

# Docker's own codename and architecture, resolved once. UBUNTU_CODENAME first:
# /etc/os-release sets it on Ubuntu derivatives too (Linux Mint, Pop!_OS,
# Zorin), where VERSION_CODENAME is the derivative's own codename and would not
# exist in Docker's Ubuntu repository.
_docker_suite() {
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

remove_old_docker() {
    local pkg
    for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
        _sudo apt-get remove -y "$pkg" 2>/dev/null || true
    done
}

add_docker_repo() {
    local suite
    suite="$(_docker_suite)"
    if [[ -z "$suite" ]]; then
        error 'could not determine the Ubuntu codename for the Docker repository'
        return 1
    fi

    _sudo apt-get update
    _sudo apt-get install -y ca-certificates curl
    _sudo install -m 0755 -d /etc/apt/keyrings
    _sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        -o /etc/apt/keyrings/docker.asc
    _sudo chmod a+r /etc/apt/keyrings/docker.asc

    _sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $suite
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

    _sudo apt-get update
}

install_docker_packages() {
    _sudo apt install -y docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
}

docker_setup() {
    section 'Docker Engine installation'

    if command_exists docker; then
        # `command -v` only proves the binary is on PATH, not that it works — a
        # Docker Desktop WSL shim sits on PATH and exits non-zero. Ask it for a
        # version and fall back rather than letting the substitution swallow the
        # failure, which is what a bare $(docker --version) does here.
        local version
        version="$(docker --version 2>/dev/null || printf 'version unavailable')"
        info "Docker already installed ($version). Skipping install."
    else
        run_or_die 'Removing old Docker packages' remove_old_docker
        run_or_die 'Adding Docker repository'     add_docker_repo
        run_or_die 'Installing Docker packages'   install_docker_packages
        info 'Docker engine installed.'
    fi

    # Group membership is fixed whether Docker was just installed or was already
    # present. On a machine that already had Docker the user had never been added
    # to the group, so `docker` kept asking for sudo. id -un, not $USER: $USER is
    # unset under `env -i`, which is fatal with `set -u`.
    if getent group docker >/dev/null 2>&1; then
        if id -nG "$(id -un)" | tr ' ' '\n' | grep -qx docker; then
            info 'User is already in the docker group.'
        else
            run_or_die 'Adding user to docker group' _sudo usermod -aG docker "$(id -un)"
            info 'Docker group membership added. Log out and back in for it to apply.'
        fi
    fi
}
