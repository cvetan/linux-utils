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

# ── ERR trap ──────────────────────────────────────────────────────────────────
# A trap is a process-wide setting, so it belongs to the entrypoint. `set -E`
# above makes it fire for failures inside functions too — which is where all the
# real work happens. The handler reports the file and line that actually failed
# and exits with the command's own status.
_on_error() {
    local rc=$? line="${BASH_LINENO[0]}"
    (( line > 0 )) || line="$LINENO"
    printf '  %s✗%s  unexpected failure at %s:%s (exit %s)\n' \
        "$RED" "$NC" "${BASH_SOURCE[1]:-$BASH_SOURCE}" "$line" "$rc" >&2
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
