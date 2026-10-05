#!/usr/bin/env bash
# =============================================================================
# setup/zsh.sh — zsh, Oh-My-Zsh, powerlevel10k and the base .zshrc
# =============================================================================
# A step of main.sh, not a standalone program: it draws with lib/ui.sh and runs
# commands with run_or_die, which main.sh defines.

# ── Guard against double sourcing ─────────────────────────────────────────────
[[ -n "${_ZSH_SH_LOADED:-}" ]] && return
readonly _ZSH_SH_LOADED=1

_setup_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_setup_dir/../lib/ui.sh"
source "$_setup_dir/../lib/utils.sh"

# Oh-My-Zsh installs to $ZSH when it is exported, $HOME/.oh-my-zsh otherwise.
# Resolved once here and used for the guard, the clone destinations and the
# generated .zshrc, so all four can never disagree about which directory they
# mean.
_OMZ_DIR="${ZSH:-$HOME/.oh-my-zsh}"

# Marker for the block we own in .zshrc. Later steps (nvm, SDKMAN, ...) append to
# the same file, so it is deliberately NOT overwritten on re-runs.
ZSHRC_MARKER='# Managed by linux-utils (base config)'

# ── Oh-My-Zsh ────────────────────────────────────────────────────────────────
install_oh_my_zsh() {
    if [[ -d "$_OMZ_DIR" ]]; then
        info "Oh-My-Zsh already installed ($_OMZ_DIR). Skipping."
        return 0
    fi

    # ZSH is passed explicitly rather than inherited: an exported ZSH pointing
    # somewhere else would make the installer refuse to run.
    run_or_die 'Installing Oh-My-Zsh' env \
        "ZSH=$_OMZ_DIR" RUNZSH=no CHSH=no KEEP_ZSHRC=yes \
        bash -c 'curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh | sh -s -- --unattended'
}

# ── Theme + plugins ──────────────────────────────────────────────────────────
clone_zsh_extra() {
    local name="${1:?name required}" url="${2:?url required}" dest="${3:?dest required}"

    if [[ -d "$dest/.git" ]]; then
        info "$name already present. Skipping."
        return 0
    fi

    mkdir -p "$(dirname "$dest")"
    run_or_die "Cloning $name" git clone --depth=1 "$url" "$dest"
}

install_zsh_extras() {
    local custom="$_OMZ_DIR/custom"

    clone_zsh_extra 'zsh-completions' \
        'https://github.com/zsh-users/zsh-completions' \
        "$custom/plugins/zsh-completions"
    clone_zsh_extra 'zsh-autosuggestions' \
        'https://github.com/zsh-users/zsh-autosuggestions' \
        "$custom/plugins/zsh-autosuggestions"
    clone_zsh_extra 'powerlevel10k' \
        'https://github.com/romkatv/powerlevel10k.git' \
        "$custom/themes/powerlevel10k"
}

# ── Base .zshrc ──────────────────────────────────────────────────────────────
write_zshrc() {
    local zshrc="$HOME/.zshrc" backup escaped

    if grep -qF "$ZSHRC_MARKER" "$zshrc" 2>/dev/null; then
        info '.zshrc base config already applied. Skipping.'
        return 0
    fi

    if [[ -f "$zshrc" ]]; then
        backup="$zshrc.bak.$(date +%Y%m%d-%H%M%S)"
        cp "$zshrc" "$backup"
        warn "Existing .zshrc backed up to $backup"
    fi

    # The here-doc is quoted so nothing expands now; $HOME and the $ZSH
    # references below are written literally and resolved by zsh at startup.
    # Only the install path goes through a sentinel, because $_OMZ_DIR can be a
    # non-default directory when $ZSH was exported before this ran.
    cat > "$zshrc" <<'ZSHRC_EOF'
# Managed by linux-utils (base config)

# Path to your oh-my-zsh installation.
export ZSH="__OMZ_DIR__"

# Powerlevel10k settings (must be set before oh-my-zsh is sourced)
POWERLEVEL9K_MODE="powerline"
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

    # Substitute the sentinel. Escape the sed delimiter and `&` (which means
    # "the whole match" in a replacement) so a path containing them survives.
    escaped="${_OMZ_DIR//\\/\\\\}"
    escaped="${escaped//|/\\|}"
    escaped="${escaped//&/\\&}"
    sed -i "s|__OMZ_DIR__|${escaped}|" "$zshrc"

    info 'Base .zshrc written (theme, plugins, prompt, aliases).'
}

# ── Default shell ────────────────────────────────────────────────────────────
set_zsh_default() {
    local zsh_bin current_shell user
    zsh_bin="$(command -v zsh 2>/dev/null || printf '')"
    user="$(id -un)"

    if [[ -z "$zsh_bin" ]]; then
        warn 'zsh is not on PATH — skipping the default-shell change'
        warn "install it, then run: chsh -s $(command -v zsh 2>/dev/null || echo /bin/zsh) $user"
        return 0
    fi

    # getent rather than $USER: $USER is unset under `env -i`, which is fatal
    # with `set -u`. An empty field here just means we cannot tell.
    current_shell="$(getent passwd "$user" 2>/dev/null | cut -d: -f7 || printf '')"

    if [[ "$current_shell" == "$zsh_bin" ]]; then
        info "zsh is already the default shell. Skipping."
        return 0
    fi

    if _sudo chsh -s "$zsh_bin" "$user"; then
        info 'Default shell set to zsh. Takes effect on next login.'
    else
        warn "Could not change default shell. Run manually: chsh -s $zsh_bin $user"
    fi
}

# ── .zshrc additions ─────────────────────────────────────────────────────────
# The shared append_if_missing from lib/utils.sh, not a local override: a local
# two-argument version hardcoded to $zshrc silently redirects every other
# module's three-argument calls into .zshrc.
extend_zshrc() {
    local zshrc="$HOME/.zshrc"

    # PATH first, so the `bat` symlink link_cli_aliases drops in ~/.local/bin is
    # visible to the alias guard below when the shell starts.
    append_if_missing "$zshrc" '.local/bin' \
        '\nexport PATH="$HOME/.local/bin:$PATH"'

    # Guarded: bat/fd-find are best-effort, so a machine without them must not
    # end up with `cat` or `fd` pointing at a missing binary.
    append_if_missing "$zshrc" '# bat alias' \
        '\n# bat alias\ncommand -v bat >/dev/null && alias cat="bat --paging=never"'

    append_if_missing "$zshrc" '# fd alias' \
        '\n# fd alias (fd-find)\ncommand -v fdfind >/dev/null && alias fd="fdfind"'
}

# ── zsh_setup ────────────────────────────────────────────────────────────────
zsh_setup() {
    section 'Zsh + Oh-My-Zsh'

    install_oh_my_zsh
    install_zsh_extras
    write_zshrc
    set_zsh_default
    extend_zshrc
}