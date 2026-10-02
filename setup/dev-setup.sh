#!/usr/bin/env bash
# =============================================================================
# Dev Machine Setup — Ubuntu / Debian
# Usage:
#   chmod +x setup/dev-setup.sh && ./setup/dev-setup.sh
#
# To bundle your SSH keys:
#   base64 -w0 ~/.ssh/id_ed25519     → paste into PRIVATE_KEY below
#   base64 -w0 ~/.ssh/id_ed25519.pub → paste into PUBLIC_KEY below
# =============================================================================

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${GREEN}  ✓${NC}  $*"; }
warn()    { echo -e "${YELLOW}  !${NC}  $*"; }
section() { echo -e "\n${CYAN}▶ $*${NC}"; }

# ── Log file — all raw output goes here ───────────────────────────────────────
LOG_FILE="/tmp/setup-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1   # tee keeps stdout visible for section/info
# We'll redirect individual noisy commands explicitly (see `run` below)

# ── Spinner ───────────────────────────────────────────────────────────────────
_SPINNER_PID=""

spinner_start() {
    local msg="$1"
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    # Run spinner in a subshell so it doesn't block
    (
        local i=0
        while true; do
            printf "\r  ${CYAN}%s${NC}  %s " "${frames[$((i % ${#frames[@]}))]}" "$msg"
            sleep 0.1
            (( i++ )) || true
        done
    ) &
    _SPINNER_PID=$!
    # Suppress job-control noise
    disown "$_SPINNER_PID" 2>/dev/null || true
}

spinner_stop() {
    local label="${1:-}"
    if [[ -n "$_SPINNER_PID" ]]; then
        kill "$_SPINNER_PID" 2>/dev/null || true
        wait "$_SPINNER_PID" 2>/dev/null || true
        _SPINNER_PID=""
    fi
    printf "\r\033[2K"   # clear the spinner line
    [[ -n "$label" ]] && info "$label"
}

# ── run: execute a command silently with a spinner ────────────────────────────
# Usage: run "Spinner label" cmd arg1 arg2 ...
# Output goes to LOG_FILE; on failure, dumps the last 20 lines of the log.
run() {
    local label="$1"; shift
    spinner_start "$label"
    local exit_code=0
    # Run command, appending only to log (not terminal)
    "$@" >> "$LOG_FILE" 2>&1 || exit_code=$?
    spinner_stop "$label"
    if [[ $exit_code -ne 0 ]]; then
        echo -e "${RED}  ✗  FAILED: $label (exit $exit_code)${NC}"
        echo -e "${YELLOW}  Last output (see full log: $LOG_FILE):${NC}"
        tail -20 "$LOG_FILE" | sed 's/^/    /'
        exit $exit_code
    fi
}

# ── SSH Keys (base64-encoded) ─────────────────────────────────────────────────
# Leave empty to skip SSH key restore.
PRIVATE_KEY=""   # base64 -w0 ~/.ssh/id_ed25519
PUBLIC_KEY=""    # base64 -w0 ~/.ssh/id_ed25519.pub

# ── Git config ────────────────────────────────────────────────────────────────
GIT_NAME="Your Name"
GIT_EMAIL="you@example.com"

# ── Versions ──────────────────────────────────────────────────────────────────
NODE_VERSION="lts/*"      # e.g. "20" or "lts/*"
JAVA_VERSION="21.0.2-tem" # SDKMAN identifier; run `sdk list java` to browse

# =============================================================================
# HELPERS
# =============================================================================

command_exists() { command -v "$1" &>/dev/null; }

require_root_or_sudo() {
    if [[ $EUID -ne 0 ]] && ! sudo -n true 2>/dev/null; then
        warn "This script needs sudo. You may be prompted for your password."
    fi
}

# =============================================================================
# 1. SYSTEM UPDATE & BASE PACKAGES
# =============================================================================

section "System update & base packages"

run "Updating package lists" sudo apt-get update
run "Upgrading installed packages" sudo apt-get upgrade -y

run "Installing base packages" sudo apt-get install -y \
    build-essential \
    curl wget git unzip zip \
    jq ripgrep fzf tmux \
    htop tree bat fd-find \
    zsh \
    gnupg ca-certificates lsb-release \
    software-properties-common apt-transport-https \
    xclip xsel \
    openssh-client

# bat is installed as 'batcat' on Ubuntu — alias it
if command_exists batcat && ! command_exists bat; then
    mkdir -p ~/.local/bin
    ln -sf "$(command -v batcat)" ~/.local/bin/bat
fi

# =============================================================================
# 2. DOCKER ENGINE
# =============================================================================

section "Docker Engine"

if command_exists docker; then
    info "Docker already installed ($(docker --version)). Skipping."
else
    info "Installing Docker Engine..."

    # Remove old packages
    run "Removing old Docker packages" bash -c \
        'for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
            sudo apt-get remove -y "$pkg" 2>/dev/null || true
        done'

    # Add Docker's official GPG key & repo
    run "Adding Docker GPG key & repo" bash -c '
        sudo install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
            | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        sudo chmod a+r /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
            https://download.docker.com/linux/ubuntu \
            $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
            | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        sudo apt-get update
    '

    run "Installing Docker Engine" sudo apt-get install -y \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin

    sudo usermod -aG docker "$USER"
    info "Docker installed. Re-login required to run without sudo."
fi

# =============================================================================
# 3. ZSH + OH-MY-ZSH
# =============================================================================

section "Zsh + Oh-My-Zsh"

# ── Oh-My-Zsh ────────────────────────────────────────────────────────────────
if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
    run "Installing Oh-My-Zsh" env RUNZSH=no CHSH=no KEEP_ZSHRC=yes bash -c \
        'curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh | sh -s -- --unattended'
else
    info "Oh-My-Zsh already installed. Skipping."
fi

# ── Theme + plugins ──────────────────────────────────────────────────────────
ZSH_CUSTOM_DIR="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"

clone_zsh_extra() {
    local name="$1" url="$2" dest="$3"
    if [[ -d "$dest/.git" ]]; then
        info "$name already present. Skipping."
    else
        mkdir -p "$(dirname "$dest")"
        run "Cloning $name" git clone --depth=1 "$url" "$dest"
    fi
}

clone_zsh_extra "zsh-completions"    https://github.com/zsh-users/zsh-completions     "$ZSH_CUSTOM_DIR/plugins/zsh-completions"
clone_zsh_extra "zsh-autosuggestions" https://github.com/zsh-users/zsh-autosuggestions "$ZSH_CUSTOM_DIR/plugins/zsh-autosuggestions"
clone_zsh_extra "powerlevel10k"      https://github.com/romkatv/powerlevel10k.git      "$ZSH_CUSTOM_DIR/themes/powerlevel10k"

# ── Base .zshrc ──────────────────────────────────────────────────────────────
# Written once (guarded by a marker). Later sections append to it (nvm, SDKMAN, ...),
# so it is intentionally NOT overwritten on re-runs.
ZSHRC="$HOME/.zshrc"
ZSHRC_MARKER="# Managed by dev-setup.sh (base config)"

if grep -qF "$ZSHRC_MARKER" "$ZSHRC" 2>/dev/null; then
    info ".zshrc base config already applied. Skipping."
else
    if [[ -f "$ZSHRC" ]]; then
        ZSHRC_BACKUP="$ZSHRC.bak.$(date +%Y%m%d-%H%M%S)"
        cp "$ZSHRC" "$ZSHRC_BACKUP"
        warn "Existing .zshrc backed up to $ZSHRC_BACKUP"
    fi
    cat > "$ZSHRC" <<'ZSHRC_EOF'
# Managed by dev-setup.sh (base config)

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
alias sail='sh $([ -f sail ] && echo sail || echo vendor/bin/sail)'
ZSHRC_EOF
    info "Base .zshrc written (theme, plugins, prompt, aliases)."
fi

# ── Default shell ────────────────────────────────────────────────────────────
ZSH_BIN="$(command -v zsh)"
CURRENT_LOGIN_SHELL="$(getent passwd "$USER" | cut -d: -f7)"

if [[ "$CURRENT_LOGIN_SHELL" != "$ZSH_BIN" ]]; then
    if sudo chsh -s "$ZSH_BIN" "$USER"; then
        info "Default shell set to zsh. Takes effect on next login."
    else
        warn "Could not change default shell. Run manually: chsh -s $ZSH_BIN"
    fi
fi

# ── .zshrc additions ─────────────────────────────────────────────────────────
append_if_missing() {
    local marker="$1"; local content="$2"
    grep -qF "$marker" "$ZSHRC" 2>/dev/null || echo -e "$content" >> "$ZSHRC"
}

append_if_missing "# bat alias" \
    '\n# bat alias\nalias cat="bat --paging=never"'

append_if_missing "# fd alias" \
    '\n# fd alias (fd-find)\nalias fd="fdfind"'

append_if_missing ".local/bin" \
    '\nexport PATH="$HOME/.local/bin:$PATH"'

# =============================================================================
# 4. NVM + NODE.JS
# =============================================================================

section "nvm + Node.js"

export NVM_DIR="$HOME/.nvm"

if [[ ! -d "$NVM_DIR" ]]; then
    run "Installing nvm" bash -c \
        'curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash'
fi

# Load nvm in this shell session
# shellcheck source=/dev/null
[ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"

if ! nvm ls "$NODE_VERSION" &>/dev/null; then
    run "Installing Node $NODE_VERSION" bash -c \
        "source \"$NVM_DIR/nvm.sh\" && nvm install \"$NODE_VERSION\" && nvm alias default \"$NODE_VERSION\""
fi

info "Node: $(node --version)  npm: $(npm --version)"

# Add nvm to .zshrc
append_if_missing "NVM_DIR" \
    '\n# nvm\nexport NVM_DIR="$HOME/.nvm"\n[ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"\n[ -s "$NVM_DIR/bash_completion" ] && source "$NVM_DIR/bash_completion"'

# =============================================================================
# 5. PHP + COMPOSER + LARAVEL
# =============================================================================

section "PHP + Composer + Laravel"

# Add Ondřej's PPA for latest PHP
if ! apt-cache show php8.3 &>/dev/null 2>&1; then
    run "Adding PHP 8.3 PPA" bash -c \
        'sudo add-apt-repository -y ppa:ondrej/php && sudo apt-get update'
fi

run "Installing PHP 8.3 & extensions" sudo apt-get install -y \
    php8.3 php8.3-cli php8.3-fpm \
    php8.3-mbstring php8.3-xml php8.3-curl \
    php8.3-zip php8.3-bcmath php8.3-intl \
    php8.3-mysql php8.3-pgsql php8.3-sqlite3 \
    php8.3-redis php8.3-gd \
    php-pear

info "PHP: $(php --version | head -1)"

# Composer
if ! command_exists composer; then
    run "Installing Composer" bash -c '
        EXPECTED="$(php -r "copy(\"https://composer.github.io/installer.sig\", \"php://stdout\");")"
        php -r "copy(\"https://getcomposer.org/installer\", \"composer-setup.php\");"
        ACTUAL="$(php -r "echo hash_file(\"sha384\", \"composer-setup.php\");")"
        if [[ "$EXPECTED" != "$ACTUAL" ]]; then
            echo "Composer installer checksum mismatch!" >&2
            rm composer-setup.php; exit 1
        fi
        php composer-setup.php --quiet
        rm composer-setup.php
        sudo mv composer.phar /usr/local/bin/composer
    '
fi

# Laravel installer (global)
if ! command_exists laravel; then
    run "Installing Laravel installer" composer global require laravel/installer --quiet
fi

# Add Composer global bin to PATH
append_if_missing "composer/vendor/bin" \
    '\n# Composer global bin\nexport PATH="$HOME/.config/composer/vendor/bin:$PATH"'

info "Laravel installer ready. Create projects with: laravel new myapp"

# =============================================================================
# 6. SDKMAN + JAVA
# =============================================================================

section "SDKMAN + Java"

export SDKMAN_DIR="$HOME/.sdkman"

if [[ ! -d "$SDKMAN_DIR" ]]; then
    run "Installing SDKMAN" bash -c 'curl -s "https://get.sdkman.io" | bash'
fi

# Load SDKMAN in this shell session
# shellcheck source=/dev/null
[[ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]] && source "$SDKMAN_DIR/bin/sdkman-init.sh"

if ! sdk list java 2>/dev/null | grep -q " ${JAVA_VERSION} "; then
    run "Installing Java $JAVA_VERSION" bash -c \
        "source \"$SDKMAN_DIR/bin/sdkman-init.sh\" && sdk install java \"$JAVA_VERSION\" < /dev/null"
fi

sdk default java "$JAVA_VERSION" >> "$LOG_FILE" 2>&1 || true

# Add SDKMAN to .zshrc
append_if_missing "SDKMAN_DIR" \
    '\n# SDKMAN\nexport SDKMAN_DIR="$HOME/.sdkman"\n[[ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]] && source "$SDKMAN_DIR/bin/sdkman-init.sh"'

# =============================================================================
# 7. GIT CONFIGURATION
# =============================================================================

section "Git configuration"

git config --global user.name  "$GIT_NAME"
git config --global user.email "$GIT_EMAIL"
git config --global core.editor "nano"
git config --global init.defaultBranch "main"
git config --global pull.rebase false
git config --global color.ui auto

info "Git configured for $GIT_NAME <$GIT_EMAIL>"

# =============================================================================
# 8. SSH KEYS
# =============================================================================

section "SSH keys"

SSH_DIR="$HOME/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

if [[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]]; then
    info "Restoring SSH keys from embedded base64..."

    echo "$PRIVATE_KEY" | base64 -d > "$SSH_DIR/id_ed25519"
    echo "$PUBLIC_KEY"  | base64 -d > "$SSH_DIR/id_ed25519.pub"

    chmod 600 "$SSH_DIR/id_ed25519"
    chmod 644 "$SSH_DIR/id_ed25519.pub"

    # Start ssh-agent and add key
    eval "$(ssh-agent -s)" > /dev/null
    ssh-add "$SSH_DIR/id_ed25519"

    info "SSH key restored and added to agent."
    info "Public key:"
    cat "$SSH_DIR/id_ed25519.pub"
else
    warn "PRIVATE_KEY / PUBLIC_KEY not set. Generating a new ed25519 key..."
    ssh-keygen -t ed25519 -C "$GIT_EMAIL" -f "$SSH_DIR/id_ed25519" -N ""
    eval "$(ssh-agent -s)" > /dev/null
    ssh-add "$SSH_DIR/id_ed25519"
    info "New SSH key generated. Add this public key to GitHub/GitLab:"
    echo ""
    cat "$SSH_DIR/id_ed25519.pub"
fi

# =============================================================================
# DONE
# =============================================================================

section "Setup complete!"
echo ""
echo -e "  ${GREEN}✓${NC} System packages & CLI tools"
echo -e "  ${CYAN}  Full log: $LOG_FILE${NC}"
echo -e "  ${GREEN}✓${NC} Docker Engine + Compose"
echo -e "  ${GREEN}✓${NC} Zsh + Oh-My-Zsh"
echo -e "  ${GREEN}✓${NC} nvm + Node $(node --version)"
echo -e "  ${GREEN}✓${NC} PHP 8.3 + Composer + Laravel installer"
echo -e "  ${GREEN}✓${NC} SDKMAN + Java $JAVA_VERSION"
echo -e "  ${GREEN}✓${NC} Git configured"
echo -e "  ${GREEN}✓${NC} SSH keys"
echo ""
echo -e "  ${YELLOW}Next steps:${NC}"
echo -e "  1. Run: ${GREEN}exec zsh${NC}  (or re-login) to load all changes"
echo -e "  2. If new SSH key was generated, add the public key to GitHub/GitLab"
echo -e "  3. Docker group: re-login to use docker without sudo"
echo ""