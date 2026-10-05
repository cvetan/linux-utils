#!/usr/bin/env bash
# =============================================================================
# main.sh — entrypoint
# =============================================================================
# Everything process-wide is set up here, not in lib/: shell options, the IFS,
# the ERR trap, $LOG_FILE and run_or_die. The libraries under lib/ never call
# `exit` and never touch the caller's shell options, so this file is the only
# place that decides what ends the program.

set -eEuo pipefail
IFS=$'\n\t'

# Non-interactive apt, process-wide (that is why it lives in the entrypoint).
# Without DEBIAN_FRONTEND the ubuntu-restricted-extras / ttf-mscorefonts EULA
# blocks the install, and on 22.04+ needrestart stops to ask about services.
# UCF_FORCE_CONFFOLD keeps a package upgrade from prompting about changed config
# files. All of these are fatal to an unattended run.
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export APT_LISTCHANGES_FRONTEND=none
export UCF_FORCE_CONFFOLD=1

__repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$__repo_root/lib/ui.sh"
source "$__repo_root/lib/log.sh"
# The log captures raw command output, which may include secrets; keep it
# private from the moment it exists.
: >> "$LOG_FILE"
chmod 600 "$LOG_FILE" 2>/dev/null || true
source "$__repo_root/lib/utils.sh"
source "$__repo_root/lib/preflight.sh"
source "$__repo_root/setup/base_packages.sh"
source "$__repo_root/setup/docker.sh"
source "$__repo_root/setup/zsh.sh"
source "$__repo_root/setup/vscode.sh"
source "$__repo_root/setup/php.sh"
source "$__repo_root/setup/sdkman.sh"
source "$__repo_root/setup/git.sh"

# ── ERR trap ──────────────────────────────────────────────────────────────────
# A trap is a process-wide setting, so it belongs to the entrypoint. `set -E`
# above makes it fire for failures inside functions too — which is where all the
# real work happens. The handler reports the file and line that actually failed
# and exits with the command's own status.
_on_error() {
    local rc=$? line="${BASH_LINENO[0]}"

    # Inside a subshell — `$(...)`, `( ... )` — the failure belongs to that
    # subshell, not to us. Reporting from here would be a lie: `exit` only ends
    # the subshell, and the enclosing command's own status then decides what
    # happens. `info "$(docker --version)"` is the shape this exists for: the
    # version lookup fails, this handler fires inside the substitution, prints a
    # bogus trace, and `info` goes on to report success with an empty version.
    # Call sites that genuinely discard a failure must say so themselves with a
    # `||` fallback, which this guard makes visible instead of silent.
    (( BASH_SUBSHELL == 0 )) || return "$rc"

    (( line > 0 )) || line="$LINENO"
    # ${RED:-} not $RED: under `set -u` an unset colour would kill the one
    # handler whose job is to report that something else went wrong.
    printf '  %s✗%s  unexpected failure at %s:%s (exit %s)\n' \
        "${RED:-}" "${NC:-}" "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}" "$line" "$rc" >&2
    exit "$rc"
}
trap _on_error ERR

# run_or_die "Label" cmd … — run(), except a failure ends the program. Libraries
# return a status; the program decides that a failed step is fatal.
run_or_die() {
    run "$@" || exit $?
}

banner 'DEVELOPMENT MACHINE SETUP'

# Show README requirements, verify them on this machine, ask for confirmation.
preflight || exit $?

# Cache sudo credentials once so every later step does not prompt again. Skipped
# as root (nothing to cache) and without a TTY, where prompting would hang — an
# unattended run must instead be root or have passwordless sudo.
if (( EUID != 0 )) && [[ -t 0 ]] && command_exists sudo; then
    sudo -v || true
fi

# =============================================================================
# 1. SYSTEM UPDATE & BASE PACKAGES
# =============================================================================
base_packages_setup

# =============================================================================
# 2. ZSH + OH-MY-ZSH
# =============================================================================
# Before Docker and the language installers: SDKMAN and friends write their
# init into the user's shell config, and that config has to exist first.
zsh_setup

# =============================================================================
# 3. DOCKER ENGINE
# =============================================================================
docker_setup


# =============================================================================
# 4. VSCODE SETUP
# =============================================================================
vscode_setup


# =============================================================================
# 5. NVM + NODE.JS
# =============================================================================


# =============================================================================
# 6. PHP + COMPOSER
# =============================================================================
php_setup


# =============================================================================
# 7. SDKMAN + JAVA
# =============================================================================
sdkman_setup


# =============================================================================
# 8. GIT CONFIGURATION
# =============================================================================
git_setup


# =============================================================================
# 9. SSH KEYS
# =============================================================================
