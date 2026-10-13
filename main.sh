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
# blocks the install — step 1 pre-seeds that EULA, and installs the package only
# where a graphical environment is detected — and on 22.04+ needrestart stops
# to ask about services.
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
source "$__repo_root/setup/node.sh"
source "$__repo_root/setup/php.sh"
source "$__repo_root/setup/sdkman.sh"
source "$__repo_root/setup/git.sh"
source "$__repo_root/setup/ssh.sh"
source "$__repo_root/setup/firefox.sh"
source "$__repo_root/setup/xbox.sh"
source "$__repo_root/setup/nvidia.sh"

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
    spinner_cleanup
    exit "$rc"
}
trap _on_error ERR

# A disowned spinner outlives the shell: on any exit (normal, error, or signal)
# stop it so it does not keep redrawing over the user's prompt.
trap spinner_cleanup EXIT

# run_or_die "Label" cmd … — run(), except a failure ends the program. Libraries
# return a status; the program decides that a failed step is fatal.
run_or_die() {
    run "$@" || exit $?
}

# ── Step registry ─────────────────────────────────────────────────────────────
# `id|label`, in run order. `id` names the `${id}_setup` function called below;
# the label is what the "Steps to run" checklist shows. Step 1 (base_packages) is
# the bootstrap — it installs curl/git/software-properties-common the later steps
# depend on — so it is always selected and cannot be toggled off. The two GUI
# steps (vscode, firefox) sit at the end on purpose, right before the reboot-last
# NVIDIA step: on a machine with no graphical environment (WSL, a server) all
# three are deselected and skipped entirely, so nothing that only a desktop
# needs gets in the way of the CLI tooling — and a machine with a GUI but no
# NVIDIA GPU never sees the NVIDIA step ticked either.
_STEP_SPECS=(
    'base_packages|System update & base packages'
    'zsh|Zsh + Oh-My-Zsh'
    'docker|Docker Engine'
    'node|Node.js + npm'
    'php|PHP + Composer'
    'sdkman|SDKMAN + Java'
    'git|Git configuration'
    'ssh|SSH keys'
    'xbox|Xbox Wireless Adapter (dongle-gated)'
    'vscode|Visual Studio Code'
    'firefox|Firefox (snap-gated)'
    'nvidia|NVIDIA drivers (GUI + GPU-gated)'
)
readonly _STEP_REQUIRED='base_packages'

# id → label, filled once from the registry; _SELECTED[id]=1 for every step the
# user chose, which run_step consults.
declare -A _STEP_LABELS=() _SELECTED=()
for _spec in "${_STEP_SPECS[@]}"; do
    _STEP_LABELS["${_spec%%|*}"]="${_spec#*|}"
done
unset _spec

# run_step id — run a step only when it was selected, so a deselected step is
# skipped cleanly instead of silently dropped. The skip line matches how the
# hardware-gated steps (firefox/xbox/nvidia) already announce their own skips.
run_step() {
    local id="${1:?step id required}"
    if [[ -n "${_SELECTED[$id]:-}" ]]; then
        "${id}_setup"
    else
        step "Skipping: ${_STEP_LABELS[$id]:-${id}}"
    fi
}

banner 'DEVELOPMENT MACHINE SETUP'

# Show README requirements, verify them on this machine, ask for confirmation.
preflight || exit $?

# No graphical environment (WSL, a server, a container) means the GUI steps have
# nothing to run on and nothing to draw with, and the NVIDIA step has no display
# to drive — Windows owns the GPU under WSL, and a headless box never needs a
# Linux graphics driver. Adding the ids to SKIP_STEPS is what deselects them in
# the checklist below and drops them in an unattended run. SETUP_GUI=1 still
# installs the GUI steps (their own gates read the same switch); the NVIDIA
# step's gates are absolute — it needs a GUI *and* a detected NVIDIA GPU, and
# under WSL it always skips.
_deselect_steps() {
    local skip="${SKIP_STEPS:-}" id
    skip="${skip//,/ }"
    skip="${skip//$'\n'/ }"
    skip="${skip//$'\t'/ }"
    for id in "$@"; do
        [[ " $skip " == *" $id "* ]] || skip="${skip:+$skip }$id"
    done
    SKIP_STEPS="$skip"
}

if ! gui_available; then
    step 'No graphical environment — Visual Studio Code, Firefox and the NVIDIA driver step are deselected (SETUP_GUI=1 restores the GUI steps)'
    _deselect_steps vscode firefox nvidia
elif ! _nvidia_gpu_present; then
    # The GPU half of the NVIDIA gate, checked here so the checklist reflects it
    # — setup/nvidia.sh gates the same condition again inside the step.
    step 'No NVIDIA GPU detected — the NVIDIA driver step is deselected'
    _deselect_steps nvidia
fi

# Decide which steps to run, up front, while the user is still at the terminal.
# The checklist defaults to everything selected; step 1 is locked on, and an
# unattended run (or SKIP_STEPS) carries the choice without a prompt. select_steps
# returns 1 only on an interactive abort (q), which ends the run the same way a
# declined preflight does.
_selected_ids="$(select_steps 'Steps to run' "$_STEP_REQUIRED" ${_STEP_SPECS[@]+"${_STEP_SPECS[@]}"})" \
    || { warn 'Aborted by user'; exit 130; }
while IFS= read -r _id; do
    [[ -n "$_id" ]] && _SELECTED["$_id"]=1
done <<< "$_selected_ids"
unset _selected_ids _id

# Decide the SSH plan up front — bundle, ~/.ssh keys, or skip — while the user is
# still at the terminal. ssh_setup carries out whatever is chosen here. Skipped
# entirely when the SSH step itself was deselected.
if [[ -n "${_SELECTED[ssh]:-}" ]]; then
    ssh_preflight
fi

# Cache sudo credentials once so every later step does not prompt again. Skipped
# as root (nothing to cache) and without a TTY, where prompting would hang — an
# unattended run must instead be root or have passwordless sudo.
if (( EUID != 0 )) && [[ -t 0 ]] && command_exists sudo; then
    sudo -v || true
fi

# =============================================================================
# 1. SYSTEM UPDATE & BASE PACKAGES
# =============================================================================
run_step base_packages

# =============================================================================
# 2. ZSH + OH-MY-ZSH
# =============================================================================
# Before Docker and the language installers: SDKMAN and friends write their
# init into the user's shell config, and that config has to exist first.
run_step zsh

# =============================================================================
# 3. DOCKER ENGINE
# =============================================================================
run_step docker


# =============================================================================
# 4. NODE.JS + NPM
# =============================================================================
run_step node


# =============================================================================
# 5. PHP + COMPOSER
# =============================================================================
run_step php


# =============================================================================
# 6. SDKMAN + JAVA
# =============================================================================
run_step sdkman


# =============================================================================
# 7. GIT CONFIGURATION
# =============================================================================
# Runs before the GUI steps on purpose: on a fresh machine `code` is not
# installed yet when the editor is configured, and setup/vscode.sh re-applies
# core.editor once it is.
run_step git


# =============================================================================
# 8. SSH KEYS
# =============================================================================
# Executes the plan ssh_preflight chose at the top of the run: adopt the keys in
# ~/.ssh (permissions + host mapping prompts), install an offline bundle, or skip.
# No network, and no key is ever overwritten. ssh_preflight itself only ran
# because this step is selected.
run_step ssh


# =============================================================================
# 9. XBOX WIRELESS ADAPTER (only when the adapter is attached)
# =============================================================================
# A dual-boot fix, not a driver: when the Microsoft dongle is found it writes a
# udev rule that de-authorizes it, so Linux leaves it alone and Windows keeps the
# controller pairing. Skipped entirely when no dongle is attached, so every other
# machine is unaffected. Runs before the GUI steps and the NVIDIA step on purpose:
# those are the steps a machine without a display skips, and the one that wants
# a reboot stays last.
run_step xbox


# =============================================================================
# 10. VSCODE SETUP (only with a graphical environment)
# =============================================================================
# GUI steps last: on WSL or a server they are deselected before the run starts
# (see the SKIP_STEPS block above) and gated again inside the step, so the CLI
# tooling above is all such a machine ever gets to.
run_step vscode


# =============================================================================
# 11. FIREFOX (only with a GUI, and only when installed as a snap with no deb)
# =============================================================================
# Ubuntu ships Firefox as a snap. This step is for a machine that wants the
# Mozilla team's apt build instead: only when `snap list firefox` finds the snap
# and dpkg reports no real deb does it ask, then swap them, pin the PPA and
# install the deb. Skipped entirely everywhere else, so every other machine is
# unaffected — including one with no graphical environment, where the step is
# deselected up front and gated again here.
run_step firefox


# =============================================================================
# 12. NVIDIA DRIVERS (only with a GUI and an NVIDIA GPU present)
# =============================================================================
# Last on purpose: the driver only takes effect after a reboot, so the run ends
# with the machine ready to restart. Deselected up front when this machine has
# no graphical environment or no NVIDIA GPU (see the gates above) — and gated
# again inside — on WSL, where Windows owns the driver and the PCI bus inside
# the distro only mirrors the hardware — so every other machine is unaffected.
run_step nvidia
