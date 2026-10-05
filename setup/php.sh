#!/usr/bin/env bash
# =============================================================================
# setup/php.sh — PHP CLI from the Ubuntu archive, and Composer
# =============================================================================
# A step of main.sh, not a standalone program: it draws with lib/ui.sh and runs
# commands with run_or_die, which main.sh defines.
#
# PHP comes from the distribution's own archive, NOT a third-party PPA, so the
# version follows the Ubuntu release (8.1 on 22.04, 8.3 on 24.04, 8.5 on 26.04)
# and the package names stay unversioned. This PHP exists for local tooling —
# Composer, phpunit, global Composer packages — while projects run their own PHP
# from their Docker setup. php-fpm and a web server are deliberately not here.

# ── Guard against double sourcing ─────────────────────────────────────────────
[[ -n "${_PHP_SH_LOADED:-}" ]] && return
readonly _PHP_SH_LOADED=1

_setup_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_setup_dir/../lib/ui.sh"
source "$_setup_dir/../lib/utils.sh"

# Composer installs here rather than /usr/local/bin: a local bin needs no sudo,
# keeps the phar in the user's home, and makes Composer's global config resolve
# to the user instead of root. setup/zsh.sh already puts ~/.local/bin on PATH.
COMPOSER_BIN="${COMPOSER_BIN:-$HOME/.local/bin/composer}"

# ── Package sets ──────────────────────────────────────────────────────────────
# Core: Composer and phpunit cannot run without these. A release that does not
# carry one stops the run rather than leaving a half-working PHP.
_PHP_CORE_PACKAGES=(
    php-cli
    php-mbstring
    php-curl
    php-xml
    php-zip
)

# Extras: useful for local tooling and Laravel-side work, but best-effort. A
# release without one (php-redis lives in universe) warns and skips instead of
# failing the whole run.
_PHP_EXTRA_PACKAGES=(
    php-bcmath
    php-intl
    php-gd
    php-mysql
    php-pgsql
    php-sqlite3
    php-redis
    php-pear
)

# Global Composer packages to install alongside Composer. Empty by default —
# add entries here (e.g. 'phpunit/phpunit') and re-run: the loop below installs
# whatever it is handed.
_COMPOSER_GLOBAL_PACKAGES=(
    # 'phpunit/phpunit'
)

# The packages that actually exist in the configured repositories. Populated by
# resolve_php_packages so the probing happens OUTSIDE `run`, whose redirection
# would hide the warning from the terminal — the same reason
# base_packages_setup probes before calling its install helper.
_PHP_RESOLVED=()

# ── Package resolution ────────────────────────────────────────────────────────

resolve_php_packages() {
    local pkg
    local -a install=() missing=()

    for pkg in "${_PHP_CORE_PACKAGES[@]}"; do
        if apt-cache show "$pkg" >/dev/null 2>&1; then
            install+=( "$pkg" )
        else
            error "required PHP package not available: $pkg"
            return 1
        fi
    done

    for pkg in "${_PHP_EXTRA_PACKAGES[@]}"; do
        if apt-cache show "$pkg" >/dev/null 2>&1; then
            install+=( "$pkg" )
        else
            missing+=( "$pkg" )
        fi
    done

    if (( ${#missing[@]} )); then
        warn "PHP extensions not carried by this release, skipping: ${missing[*]}"
    fi

    _PHP_RESOLVED=( "${install[@]}" )
    return 0
}

install_php_packages() {
    _sudo apt install -y "$@"
}

# ── Composer ──────────────────────────────────────────────────────────────────
# The local-installation flow from getcomposer.org: download the installer,
# verify its SHA-384 against the signature Composer publishes, run it, remove it.
# Done in a mktemp directory so nothing is dropped into the caller's cwd.
install_composer() {
    local install_dir tmp rc=0

    install_dir="$(dirname "$COMPOSER_BIN")"
    tmp="$(mktemp -d)" || return 1
    mkdir -p "$install_dir" || { rm -rf "$tmp"; return 1; }

    # main.sh's errexit is suspended for a function invoked from run's `||`
    # list, so the download and checksum failures are made explicit with a
    # private `set -e` inside this bash -c.
    bash -c '
        set -euo pipefail
        tmp="$1" install_dir="$2"
        cd "$tmp"

        php -r "copy(\"https://getcomposer.org/installer\", \"composer-setup.php\");"
        expected="$(php -r "copy(\"https://composer.github.io/installer.sig\", \"php://stdout\");")"
        actual="$(php -r "echo hash_file(\"sha384\", \"composer-setup.php\");")"

        if [[ "$expected" != "$actual" ]]; then
            echo "Composer installer checksum mismatch (expected $expected, got $actual)" >&2
            exit 1
        fi

        php composer-setup.php --no-interaction \
            --install-dir="$install_dir" --filename=composer
        rm -f composer-setup.php
    ' bash "$tmp" "$install_dir" || rc=$?

    rm -rf "$tmp"
    return "$rc"
}

install_global_packages() {
    local pkg

    for pkg in ${_COMPOSER_GLOBAL_PACKAGES[@]+"${_COMPOSER_GLOBAL_PACKAGES[@]}"}; do
        run_or_die "Installing global Composer package $pkg" \
            "$COMPOSER_BIN" global require --no-interaction --no-ansi "$pkg"
    done
}

# ── .zshrc ────────────────────────────────────────────────────────────────────
extend_zshrc_composer() {
    local zshrc="$HOME/.zshrc"

    # Only the global bin dir: ~/.local/bin itself is added by setup/zsh.sh,
    # which runs earlier. Composer 2 puts its global home in $HOME/.config.
    append_if_missing "$zshrc" 'composer/vendor/bin' \
        '\n# Composer global bin\nexport PATH="$HOME/.config/composer/vendor/bin:$PATH"'
}

# ── php_setup ─────────────────────────────────────────────────────────────────
php_setup() {
    section 'PHP + Composer'

    if command_exists php; then
        local php_version
        php_version="$(php --version 2>/dev/null | head -n1 || printf 'version unavailable')"
        info "PHP already installed ($php_version). Skipping."
    else
        resolve_php_packages || return 1
        run_or_die 'Installing PHP packages' install_php_packages \
            ${_PHP_RESOLVED[@]+"${_PHP_RESOLVED[@]}"}
        info "PHP installed ($(php --version 2>/dev/null | head -n1 || printf 'version unavailable'))."
    fi

    if [[ -x "$COMPOSER_BIN" ]]; then
        local composer_version
        composer_version="$("$COMPOSER_BIN" --version 2>/dev/null || printf 'version unavailable')"
        info "Composer already installed ($composer_version). Skipping."
    else
        run_or_die 'Installing Composer' install_composer
        info "Composer installed to $COMPOSER_BIN."
    fi

    install_global_packages
    extend_zshrc_composer
}
