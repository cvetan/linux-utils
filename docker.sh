#!/bin/bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/ui.sh"

remove_old_docker() {
    local pkg
    for pkg in docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc; do
        sudo apt-get remove -y "$pkg"
    done
}

add_docker_repo() {
    sudo apt-get update
    sudo apt-get install -y ca-certificates curl
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc

    sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

    sudo apt-get update
}

install_docker_packages() {
    sudo apt install -y docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
}

docker_setup() {
    section 'Docker Engine installation'
    
    if command_exists docker; then
        info "Docker already installed ($(docker --version)). Skipping."
    else
        run 'Removing old Docker packages' remove_old_docker
        run 'Adding Docker repository'     add_docker_repo
        run 'Installing Docker packages'   install_docker_packages
        run 'Adding user to docker group'  sudo usermod -aG docker "$USER"
        info 'Docker engine installed. Log out and back in for group changes to apply.'
    fi
}