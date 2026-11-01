# Manual Install — linux-utils

This is the manual, step-by-step equivalent of `./main.sh`. Every step the
script automates is reproduced here as plain terminal commands: no UI, no
prompts, no `run`/spinner wrappers, no `DEBIAN_FRONTEND` magic. Run each block
in order, and read the `RISKY` / `OPTIONAL` notes before you do.

Steps marked **RISKY** are the ones most likely to destabilise a system — run
them deliberately, one at a time. Steps marked **OPTIONAL** only make sense on
specific hardware (NVIDIA GPU, Xbox dongle, snap-based Firefox) and can be
skipped entirely on everything else.

> **Before you start:** this guide assumes a fresh-ish Ubuntu / Ubuntu
> derivative with `sudo`. Commands that need a value filled in show a
> placeholder (e.g. `noble`, `amd64`, `02e6`, `Your Name`).

---

## Index

| # | Step | Notes |
|---|---|---|
| 1 | System update & base packages | **RISKY** — upgrade + PPAs |
| 2 | Zsh + Oh-My-Zsh | |
| 3 | Docker Engine | |
| 4 | Visual Studio Code | |
| 5 | Node.js + npm | |
| 6 | PHP + Composer | |
| 7 | SDKMAN + Java | |
| 8 | Git configuration | |
| 9 | SSH keys | no install, permissions only |
| 10 | Firefox (deb) | **OPTIONAL / RISKY** — snap-gated |
| 11 | Xbox Wireless Adapter | **OPTIONAL** — dongle-gated |
| 12 | NVIDIA drivers | **OPTIONAL / RISKY** — GPU-gated |

---

## 1. System update & base packages

> **RISKY.** The `sudo apt upgrade -y` line is a full-system upgrade and the
> single most likely thing to leave a system unstable. **Skip it if you've
> already run `sudo apt update && sudo apt upgrade` yourself beforehand** — it's
> done outside this guide, not by the script. The seven PPAs below ship newer
> builds of core packages — add only the ones you actually use.

```bash
# --- Repositories & prerequisites -------------------------------------------
sudo apt update
sudo apt install -y ca-certificates curl gnupg software-properties-common needrestart
sudo add-apt-repository -y universe
sudo add-apt-repository -y multiverse

# --- Third-party PPAs (optional — add only what you need) --------------------
sudo add-apt-repository -y ppa:libreoffice/ppa
sudo add-apt-repository -y ppa:solaar-unifying/stable
sudo add-apt-repository -y ppa:ubuntuhandbook1/mpv
sudo add-apt-repository -y ppa:spvkgn/deadbeef
sudo add-apt-repository -y ppa:xuzhen666/gnome-mpv            # GTK desktops only
sudo add-apt-repository -y ppa:danielrichter2007/grub-customizer
sudo add-apt-repository -y ppa:ubuntuhandbook1/gdm-settings   # GNOME + GDM only

sudo apt update

# --- Full system upgrade (RISKY — SKIP if you already upgraded beforehand) ----
sudo apt upgrade -y

# --- Pre-accept the Microsoft core-fonts EULA --------------------------------
# Needed by ubuntu-restricted-extras so it doesn't stop at a license prompt.
echo 'ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true' \
  | sudo debconf-set-selections

# --- Core packages -----------------------------------------------------------
sudo apt install -y build-essential curl wget zip unzip git zsh gnupg \
  ca-certificates lsb-release openssh-client xclip htop tmux

# --- Optional desktop-neutral packages ---------------------------------------
sudo apt install -y ubuntu-restricted-extras bat fd-find xsel btop fastfetch \
  synaptic apt-xapian-index powerline fonts-powerline libglib2.0-dev-bin \
  solaar deluge mpv libreoffice libreoffice-style-sifr pipx

# --- Desktop-specific extras (pick ONE line) ---------------------------------
sudo apt install -y gnome-shell-extension-manager gnome-tweaks dconf-editor celluloid  # GNOME
sudo apt install -y dconf-editor celluloid                                                # Cinnamon / MATE / Budgie / Unity
sudo apt install -y xfce4-goodies celluloid                                              # Xfce
# KDE / LXQt / unknown desktop: no extras

# --- PPA-only package --------------------------------------------------------
sudo apt install -y grub-customizer          # from danielrichter2007/grub-customizer
sudo apt install -y gdm-settings             # only if GNOME + GDM is active

# --- `bat` symlink + PATH ----------------------------------------------------
# Ubuntu ships bat as `batcat`; the zsh alias below expects `bat`.
mkdir -p ~/.local/bin
ln -sf "$(command -v batcat)" ~/.local/bin/bat
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.profile
```

---

## 2. Zsh + Oh-My-Zsh

> Oh-My-Zsh is installed without changing your shell or touching your
> `.zshrc` (the `KEEP_ZSHRC=yes` flag). You'll set the default shell and write
> the config yourself below.

```bash
# --- Oh-My-Zsh (unattended) ---------------------------------------------------
RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh -c \
  "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" \
  "" --unattended

# --- Theme + plugins ----------------------------------------------------------
git clone --depth=1 https://github.com/zsh-users/zsh-completions \
  ~/.oh-my-zsh/custom/plugins/zsh-completions
git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions \
  ~/.oh-my-zsh/custom/plugins/zsh-autosuggestions
git clone --depth=1 https://github.com/romkatv/powerlevel10k.git \
  ~/.oh-my-zsh/custom/themes/powerlevel10k

# --- Default shell ------------------------------------------------------------
chsh -s "$(command -v zsh)"
```

> **Nerd Font note:** Powerlevel10k is configured for `nerdfont-complete` mode.
> Install a Nerd Font and select it in your terminal, or the prompt icons render
> as boxes.

### `.zshrc`

If you **don't** have a `~/.zshrc` yet, create one with the base config below
(adjust the `ZSH` path if you installed Oh-My-Zsh elsewhere). If you **do**
already have one, append only the `# User configuration` aliases and the PATH
lines you want — the script never overwrites an existing config.

```bash
cat > ~/.zshrc <<'EOF'
# Path to your oh-my-zsh installation.
export ZSH="$HOME/.oh-my-zsh"

# Powerlevel10k settings (must be set before oh-my-zsh is sourced)
POWERLEVEL9K_MODE="nerdfont-complete"
POWERLEVEL9K_DISABLE_CONFIGURATION_WIZARD=true
POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(os_icon dir vcs)
POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS=(status root_indicator)

ZSH_THEME="powerlevel10k/powerlevel10k"

# Add wisely, as too many plugins slow down shell startup.
plugins=(git gitfast zsh-completions zsh-autosuggestions mvn)

source $ZSH/oh-my-zsh.sh

# ---- User configuration ----
export PATH="$HOME/.local/bin:$PATH"

# bat alias
command -v bat >/dev/null && alias cat="bat --paging=never"

# fd alias (fd-find)
command -v fdfind >/dev/null && alias fd="fdfind"

alias sail='sh $([ -f sail ] && echo sail || echo vendor/bin/sail)'
EOF
```

---

## 3. Docker Engine

> Adds you to the `docker` group, which grants root-equivalent access — only do
> this on a machine you fully trust.

```bash
# --- Remove conflicting legacy packages --------------------------------------
sudo apt remove -y docker.io docker-doc docker-compose docker-compose-v2 \
  podman-docker containerd runc

# --- Add Docker's official repository ----------------------------------------
sudo apt update && sudo apt install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release; echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

sudo apt update

# --- Install ----------------------------------------------------------------
sudo apt install -y docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin

# --- Add yourself to the docker group ---------------------------------------
sudo usermod -aG docker "$USER"
```

> `Suites:` is your Ubuntu codename (`noble` on 24.04, `resolute` on 26.04);
> the inline substitution above fills it in for you. Log out and back in for
> the group membership to apply.

---

## 4. Visual Studio Code

```bash
sudo apt update
sudo apt install -y wget gpg apt-transport-https

curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
  | gpg --dearmor --yes -o /tmp/packages.microsoft.gpg
sudo install -D -o root -g root -m 0644 /tmp/packages.microsoft.gpg \
  /etc/apt/keyrings/packages.microsoft.gpg
rm /tmp/packages.microsoft.gpg

sudo tee /etc/apt/sources.list.d/vscode.list >/dev/null <<'EOF'
deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main
EOF

sudo apt update
sudo apt install -y code
```

---

## 5. Node.js + npm

> Installs the distribution's own Node and npm (no PPA, no nvm), so the version
> tracks your Ubuntu release. Global packages install to `~/.local` — no sudo.

```bash
sudo apt install -y nodejs npm

# Global packages go to ~/.local instead of /usr (no sudo for npm install -g)
npm config set prefix "$HOME/.local"
```

---

## 6. PHP + Composer

> Distribution PHP CLI with the common extensions (no PPA, no php-fpm, no web
> server).

```bash
# --- Core extensions ----------------------------------------------------------
sudo apt install -y php-cli php-mbstring php-curl php-xml php-zip

# --- Optional extensions ------------------------------------------------------
sudo apt install -y php-bcmath php-intl php-gd php-mysql php-pgsql \
  php-sqlite3 php-redis php-pear

# --- Composer (verified install to ~/.local/bin) ------------------------------
cd "$(mktemp -d)"
php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
EXPECTED="$(php -r "copy('https://composer.github.io/installer.sig', 'php://stdout');")"
ACTUAL="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"
[ "$EXPECTED" = "$ACTUAL" ] || { echo "CHECKSUM MISMATCH — aborting" >&2; exit 1; }
mkdir -p ~/.local/bin
php composer-setup.php --no-interaction \
  --install-dir="$HOME/.local/bin" --filename=composer
```

> Composer's global bin is `~/.config/composer/vendor/bin`. Add it to your shell
> config to use globally-installed packages:
>
> ```bash
> echo 'export PATH="$HOME/.config/composer/vendor/bin:$PATH"' >> ~/.zshrc
> ```

---

## 7. SDKMAN + Java

```bash
# --- Install SDKMAN -----------------------------------------------------------
curl -fsSL https://get.sdkman.io | bash

# --- Load it in the current shell --------------------------------------------
source "$HOME/.sdkman/bin/sdkman-init.sh"

# --- Auto-answer install prompts ---------------------------------------------
# `sdk install` otherwise stops at "set as default? (Y/n)".
echo 'sdkman_auto_answer=true' >> "$HOME/.sdkman/etc/config"

# --- Install a Temurin JDK ----------------------------------------------------
sdk install java            # latest stable
# ...or pin a version:
sdk install java 21.0.2-tem
```

> The SDKMAN installer normally appends its own init block to `~/.zshrc`. If it
> didn't, add this:
>
> ```bash
> echo 'export SDKMAN_DIR="$HOME/.sdkman"' >> ~/.zshrc
> echo '[[ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]] && source "$SDKMAN_DIR/bin/sdkman-init.sh"' >> ~/.zshrc
> ```

---

## 8. Git configuration

> Set the two identity values yourself; everything else is a safe default.

```bash
git config --global user.name  "Your Name"
git config --global user.email "you@example.com"

git config --global init.defaultBranch main
git config --global push.default current
git config --global push.autoSetupRemote true
git config --global pull.rebase false
git config --global fetch.prune true
git config --global rebase.autosquash true
git config --global rerere.enabled true
git config --global merge.conflictstyle zdiff3
git config --global diff.algorithm histogram
git config --global color.ui auto

# Use VS Code as the commit editor (only if `code` is installed)
git config --global core.editor "code --wait"
```

---

## 9. SSH keys

> No install and no network access. This step just tightens permissions on the
> keys you already have in `~/.ssh`, and (optionally) writes `Host` mappings.

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh

# Lock down private keys and their .pub siblings
chmod 600 ~/.ssh/id_*        # private keys
chmod 644 ~/.ssh/*.pub       # public keys
```

### Host mappings

For each key, add a `Host` block to `~/.ssh/config` (or to a separate file you
`Include` from it):

```
Host github-personal
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_ed25519_personal
    IdentitiesOnly yes
```

If you prefer to keep them separate, create `~/.ssh/linux-utils.conf`, put the
`Host` blocks there, and prepend this line to `~/.ssh/config`:

```
Include linux-utils.conf
```

---

## 10. Firefox as a deb (instead of the snap)

> **OPTIONAL / RISKY.** Only relevant when Firefox is installed as a snap. This
> removes the snap and installs the Mozilla team's apt build. To undo, reinstall
> the snap and remove `/etc/apt/preferences.d/mozilla-firefox`.

```bash
# --- Swap the snap for the deb ------------------------------------------------
sudo snap remove firefox
sudo apt purge -y firefox

# --- Add and pin the Mozilla team PPA ----------------------------------------
sudo add-apt-repository -y ppa:mozillateam/ppa

sudo tee /etc/apt/preferences.d/mozilla-firefox >/dev/null <<'EOF'
Package: firefox*
Pin: release o=LP-PPA-mozillateam
Pin-Priority: 1001
EOF

# --- Optional: let unattended-upgrades update it ------------------------------
sudo tee /etc/apt/apt.conf.d/51unattended-upgrades-firefox >/dev/null <<EOF
Unattended-Upgrade::Allowed-Origins:: "LP-PPA-mozillateam:$(. /etc/os-release; echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")";
EOF

# --- Install the deb ----------------------------------------------------------
sudo apt update
sudo apt install -y firefox
```

---

## 11. Xbox Wireless Adapter udev rule (dual-boot fix)

> **OPTIONAL.** Only when a Microsoft Xbox Wireless Adapter is attached and you
> dual-boot with Windows. This rule makes Linux *leave the dongle alone* so
> Windows keeps the controller pairing — the adapter will **not** work on Linux
> afterwards. Replace `02e6` with your dongle's actual `idProduct` if different.

```bash
sudo tee /etc/udev/rules.d/99-xbox-wireless-adapter.rules >/dev/null <<'EOF'
ACTION=="add", ATTRS{idVendor}=="045e", ATTRS{idProduct}=="02e6", RUN="/bin/sh -c '[ -f /sys$devpath/authorized ] && echo 0 >/sys$devpath/authorized || true'"
EOF

sudo udevadm control --reload-rules
sudo udevadm trigger
```

> Find your dongle's `idProduct` with `lsusb` (vendor is always `045e`). To undo:
> remove the file and re-run the two `udevadm` commands above.

---

## 12. NVIDIA drivers

> **OPTIONAL / RISKY.** Only when an NVIDIA display controller is present. This
> installs the latest proprietary driver through `ubuntu-drivers`. A reboot is
> required afterwards.

```bash
# --- Prerequisites ------------------------------------------------------------
sudo add-apt-repository -y restricted
sudo apt update
sudo apt install -y ubuntu-drivers-common

# --- Install (pick one) -------------------------------------------------------
sudo ubuntu-drivers install            # Ubuntu's recommended driver
sudo ubuntu-drivers install nvidia:580 # pin a specific branch

# --- Resolve any half-configured package state --------------------------------
sudo apt --fix-broken install -y

# --- Reboot to load the driver ------------------------------------------------
sudo reboot
```

> Verify after reboot with `nvidia-smi`. To list candidate drivers first, run
> `ubuntu-drivers devices`.

---

## After the run

A few changes only take effect after a new login:

1. **Shell / SDKMAN:** `exec zsh` (or log out and back in).
2. **Docker group:** log out and back in so `docker` stops asking for `sudo`.
3. **NVIDIA (if installed):** reboot, then check with `nvidia-smi`.
