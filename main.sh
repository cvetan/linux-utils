#!/usr/bin/env bash
# =============================================================================
# main.sh — v2 entrypoint
# =============================================================================
# Everything process-wide is set up here, not in lib/: shell options, the IFS,
# the ERR trap, $LOG_FILE and run_or_die. The libraries under lib/ never call
# `exit` and never touch the caller's shell options, so this file is the only
# place that decides what ends the program.

set -eEuo pipefail
IFS=$'\n\t'

__repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$__repo_root/lib/ui.sh"
source "$__repo_root/lib/log.sh"
source "$__repo_root/lib/utils.sh"
source "$__repo_root/lib/preflight.sh"
source "$__repo_root/setup/base_packages.sh"
source "$__repo_root/setup/docker.sh"
source "$__repo_root/setup/zsh.sh"

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

# =============================================================================
# 1. SYSTEM UPDATE & BASE PACKAGES
# =============================================================================
base_packages_setup

# =============================================================================
# 2. DOCKER ENGINE
# =============================================================================
docker_setup

# =============================================================================
# 3. ZSH + OH-MY-ZSH
# =============================================================================
zsh_setup

# VS Code is not one of the eight steps. setup/vscode.sh is a complete module,
# so uncomment to run it here — or call vscode_setup from your own shell after
# sourcing this repo's libraries.
# vscode_setup


# =============================================================================
# 4. NVM + NODE.JS
# =============================================================================


# =============================================================================
# 5. PHP + COMPOSER + LARAVEL
# =============================================================================


# =============================================================================
# 6. SDKMAN + JAVA
# =============================================================================


# =============================================================================
# 7. GIT CONFIGURATION
# =============================================================================


# =============================================================================
# 8. SSH KEYS
# =============================================================================
