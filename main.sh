#!/bin/bash

set -euo pipefail

source './lib/ui.sh'

banner 'DEVELOPMENT MACHINE SETUP'

section 'System update and base packages installation'
run 'Updating package list' sudo apt update
run 'Upgrading installed packages' sudo apt upgrade -y
run 'Adding third-party repositories' sudo add-apt-repository ppa:libreoffice/ppa -y \
    sudo add-apt-repository ppa:solaar-unifying/stable -y \
    sudo add-apt-repository ppa:ubuntuhandbook1/mpv -y \
    sudo add-apt-repository ppa:spvkgn/deadbeef -y \
    sudo add-apt-repository ppa:xuzhen666/gnome-mpv -y \
    sudo add-apt-repository ppa:danielrichter2007/grub-customizer -y \
    sudo add-apt-repository ppa:ubuntuhandbook1/gdm-settings  -y \

run 'Installing base packages' sudo apt install -y \
    ubuntu-restricted-extras \
    htop btop fastfetch \
    synaptic apt-xapian-index \
    git zsh powerline fonts-powerline \
    dconf-editor gdm-settings libglib2.0-dev-bin \
    gnome-shell-extension-manager gnome-tweaks \
    solaar deluge \
    mpv celluloid \
    libreoffice libreoffice-style-sifr \
    grub-customizer \
    pipx \

