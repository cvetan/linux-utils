#!/usr/bin/env bash
# =============================================================================
# setup/sdkman.sh — SDKMAN! and the Eclipse Temurin JDK
# =============================================================================
# A step of main.sh, not a standalone program: it draws with lib/ui.sh and runs
# commands with run_or_die, which main.sh defines.

# ── Guard against double sourcing ─────────────────────────────────────────────
[[ -n "${_SDKMAN_SH_LOADED:-}" ]] && return
readonly _SDKMAN_SH_LOADED=1

_setup_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_setup_dir/../lib/ui.sh"
source "$_setup_dir/../lib/utils.sh"

# SDKMAN installs into $SDKMAN_DIR, $HOME/.sdkman unless the caller exported
# another path. Resolved once and exported so the installer and every sdk_run
# subshell below agree on it.
SDKMAN_DIR="${SDKMAN_DIR:-$HOME/.sdkman}"
export SDKMAN_DIR

# Pin a build by exporting JAVA_VERSION before the run (e.g. 21.0.12+1.1-tem);
# leave it unset to be offered the Temurin builds SDKMAN currently publishes.
JAVA_VERSION="${JAVA_VERSION:-}"

# The default choice in the menu: list_temurin_versions sorts newest first, so
# index 1 is the latest Temurin. A non-interactive run takes this without asking.
_TEMURIN_DEFAULT=1

# ── SDKMAN! ───────────────────────────────────────────────────────────────────
# `sdk` is a shell function, not a binary, so it only exists after sdkman-init.sh
# has been sourced. Every call goes through here: the init runs in a subshell,
# which keeps SDKMAN's globals out of the module's shell and means this step
# needs no `source` line in .zshrc in order to run.
sdk_run() {
    bash -c '
        source "$SDKMAN_DIR/bin/sdkman-init.sh"
        "$@"
    ' bash "$@"
}

install_sdkman() {
    # pipefail is set by main.sh for THIS shell, not for the `bash -c` launched
    # by `run`: without it a failed curl is masked by bash's own status and an
    # empty script "succeeds".
    bash -c '
        set -o pipefail
        curl -fsSL https://get.sdkman.io | bash
    '
}

# set_sdkman_config key value — write one setting into SDKMAN's config file.
# sdkman_auto_answer=true is what keeps `sdk install` from stopping at
# "Do you want java … to be set as default? (Y/n)" with no TTY to answer it.
set_sdkman_config() {
    local config="$SDKMAN_DIR/etc/config"
    local key="${1:?key required}" value="${2:?value required}"

    [[ -f "$config" ]] || return 0
    if grep -qE "^[#[:space:]]*${key}=" "$config"; then
        sed -i -E "s|^[#[:space:]]*${key}=.*|${key}=${value}|" "$config"
    else
        printf '%s=%s\n' "$key" "$value" >> "$config"
    fi
}

# ── Temurin JDK ───────────────────────────────────────────────────────────────
# list_temurin_versions — the Temurin identifiers SDKMAN offers, newest first.
# `sdk list java` renders the same table whether or not it goes through a pager
# (stdout is a pipe here, so it does not), and the Identifier column is the last
# `|` field. Captured, never passed through `run`, so the table stays out of the
# log. An empty result leaves the caller to fall back to `sdk install java`.
list_temurin_versions() {
    sdk_run sdk list java 2>/dev/null \
        | awk -F'|' '
            NF >= 4 {
                v = $4
                gsub(/^[ \t]+|[ \t]+$/, "", v)
                if (v ~ /-tem$/) print v
            }
        ' \
        | sort -ruV
}

# resolve_java_version — precedence: an explicit JAVA_VERSION, else the menu
# (or the default without a TTY). Prints the chosen identifier, or nothing to
# mean "let SDKMAN pick its latest stable".
resolve_java_version() {
    local -a versions=()

    [[ -n "$JAVA_VERSION" ]] && { printf '%s\n' "$JAVA_VERSION"; return 0; }

    mapfile -t versions < <(list_temurin_versions)
    if (( ${#versions[@]} == 0 )); then
        warn 'Could not list Temurin builds — using the latest stable' >&2
        return 0
    fi

    # A cancelled prompt (Ctrl-D) is not fatal: fall back to the latest stable.
    choose 'Select the Temurin JDK to install' "$_TEMURIN_DEFAULT" "${versions[@]}" \
        || { warn 'No selection made — using the latest stable' >&2; return 0; }
}

install_java() {
    if [[ -n "$JAVA_VERSION" ]]; then
        run_or_die "Installing Temurin JDK $JAVA_VERSION" \
            sdk_run sdk install java "$JAVA_VERSION"
    else
        run_or_die 'Installing the latest Temurin JDK' sdk_run sdk install java
    fi
}

# ── .zshrc ────────────────────────────────────────────────────────────────────
extend_zshrc() {
    local block
    # The SDKMAN installer already appends its own block to .zshrc; the SDKMAN_DIR
    # marker makes this a no-op once that happened, and the safety net for a
    # machine where it did not. zsh.sh wrote the base .zshrc in step 3, so this
    # lands after its "User configuration" block.
    block="\n# SDKMAN\nexport SDKMAN_DIR=\"$SDKMAN_DIR\"\n[[ -s \"\$SDKMAN_DIR/bin/sdkman-init.sh\" ]] && source \"\$SDKMAN_DIR/bin/sdkman-init.sh\""
    append_if_missing "$HOME/.zshrc" 'SDKMAN_DIR' "$block"
}

# ── sdkman_setup ──────────────────────────────────────────────────────────────
sdkman_setup() {
    section 'SDKMAN + Java'

    if [[ -d "$SDKMAN_DIR" ]]; then
        info "SDKMAN already installed ($SDKMAN_DIR). Skipping install."
    else
        run_or_die 'Installing SDKMAN' install_sdkman
    fi

    set_sdkman_config sdkman_auto_answer true

    local java_home="$SDKMAN_DIR/candidates/java/current" version
    if [[ -x "$java_home/bin/java" ]]; then
        version="$("$java_home/bin/java" -version 2>&1 | head -n1 || printf 'version unavailable')"
        info "Java already installed via SDKMAN ($version). Skipping."
    else
        JAVA_VERSION="$(resolve_java_version)"
        install_java
        info 'Temurin JDK installed and set as the SDKMAN default.'
    fi

    extend_zshrc
}

sdkman_setup