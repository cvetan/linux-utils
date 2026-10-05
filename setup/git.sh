#!/usr/bin/env bash
# =============================================================================
# setup/git.sh — global git identity and defaults
# =============================================================================
# A step of main.sh, not a standalone program: it draws with lib/ui.sh and runs
# commands with run_or_die, which main.sh defines.
#
# Everything here is written to the user's global config (~/.gitconfig), so the
# settings apply to every repository. An identity that is already configured is
# reported, not overwritten, which keeps a re-run quiet; explicit
# GIT_USER_NAME / GIT_USER_EMAIL still win. There is no network access here.

# ── Guard against double sourcing ─────────────────────────────────────────────
[[ -n "${_GIT_SH_LOADED:-}" ]] && return
readonly _GIT_SH_LOADED=1

_setup_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_setup_dir/../lib/ui.sh"
source "$_setup_dir/../lib/utils.sh"

# Identity can be supplied non-interactively (CI, unattended runs); an empty
# value means "ask, or fall back to whatever is already configured".
GIT_USER_NAME="${GIT_USER_NAME:-}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-}"

# The initial branch name for new repositories. `main` is the modern default,
# but a machine can override it (e.g. GIT_DEFAULT_BRANCH=master).
GIT_DEFAULT_BRANCH="${GIT_DEFAULT_BRANCH:-main}"

# The editor git opens for commit messages. VS Code is installed by step 4;
# `--wait` keeps git from returning before the editor is closed. Override with
# GIT_CORE_EDITOR, or set it to the empty string to leave the setting untouched.
# Named GIT_CORE_EDITOR, not GIT_EDITOR, because git itself reads GIT_EDITOR
# from the environment.
GIT_CORE_EDITOR="${GIT_CORE_EDITOR-code --wait}"

# key/value pairs applied with `git config --global`. All of these are safe to
# re-apply, so the module is idempotent without any extra checks.
_GIT_OPTIONS=(
    'init.defaultBranch' "$GIT_DEFAULT_BRANCH"
    'push.default'       'current'
    'push.autoSetupRemote' 'true'
    'pull.rebase'        'false'
    'fetch.prune'        'true'
    'rebase.autosquash'  'true'
    'rerere.enabled'     'true'
    'merge.conflictstyle' 'zdiff3'
    'diff.algorithm'     'histogram'
    'color.ui'           'auto'
)

# ── Helpers ───────────────────────────────────────────────────────────────────

# Existing global value, or empty. `git config` exits 1 when the key is unset;
# the `|| true` keeps that from tripping main.sh's `set -e`.
_git_global() {
    git config --global --get "$1" 2>/dev/null || true
}

# ── Identity ──────────────────────────────────────────────────────────────────
# Precedence per field: GIT_USER_NAME / GIT_USER_EMAIL, then the value already in
# the global config, then an interactive prompt. With no terminal and no value
# the field is left unset rather than filled with something bogus.
configure_git_identity() {
    local name="$GIT_USER_NAME" email="$GIT_USER_EMAIL"
    local existing_name existing_email

    existing_name="$(_git_global user.name)"
    existing_email="$(_git_global user.email)"

    if [[ -z "$name" && -n "$existing_name" ]]; then
        info "git user.name already set: $existing_name"
        name="$existing_name"
    fi
    if [[ -z "$email" && -n "$existing_email" ]]; then
        info "git user.email already set: $existing_email"
        email="$existing_email"
    fi

    # `ask` returns 1 (and prints nothing) without a terminal or default, so the
    # `|| true` deliberately leaves the field empty in an unattended run.
    [[ -n "$name" ]] || name="$(ask 'Full name for git commits' || true)"
    [[ -n "$email" ]] || email="$(ask 'Email for git commits' || true)"

    # Only write a field that actually changed: an identity that came from the
    # existing config is reported above and left as it is.
    if [[ -n "$name" && "$name" != "$existing_name" ]]; then
        run_or_die 'Setting git user.name' git config --global user.name "$name"
    fi
    if [[ -n "$email" && "$email" != "$existing_email" ]]; then
        run_or_die 'Setting git user.email' git config --global user.email "$email"
    fi

    if [[ -z "$name" || -z "$email" ]]; then
        warn 'git identity incomplete — set GIT_USER_NAME and GIT_USER_EMAIL, or run interactively'
    fi
}

# ── Options ───────────────────────────────────────────────────────────────────
configure_git_options() {
    local i key value

    for (( i = 0; i < ${#_GIT_OPTIONS[@]}; i += 2 )); do
        key="${_GIT_OPTIONS[i]}"
        value="${_GIT_OPTIONS[i + 1]}"
        run_or_die "Configuring git $key" git config --global "$key" "$value"
    done
}

configure_git_editor() {
    local editor_bin

    [[ -n "$GIT_CORE_EDITOR" ]] || return 0
    editor_bin="${GIT_CORE_EDITOR%% *}"

    if command_exists "$editor_bin"; then
        run_or_die 'Setting git core.editor' git config --global core.editor "$GIT_CORE_EDITOR"
    else
        warn "git editor '$editor_bin' not found — leaving core.editor unchanged"
    fi
}

# ── git_setup ─────────────────────────────────────────────────────────────────
git_setup() {
    section 'Git configuration'

    if ! command_exists git; then
        warn 'git is not installed — skipping git configuration'
        return 0
    fi

    configure_git_identity
    configure_git_options
    configure_git_editor

    info "Git configured (default branch: $GIT_DEFAULT_BRANCH)."
}
