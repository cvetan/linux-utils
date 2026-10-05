#!/usr/bin/env bash
# =============================================================================
# setup/nvidia.sh — the latest proprietary NVIDIA driver, when a GPU is present
# =============================================================================
# A step of main.sh, not a standalone program: it draws with lib/ui.sh and calls
# run_or_die, which main.sh defines. `confirm` comes from lib/preflight.sh, which
# main.sh sources before the step modules (setup/ssh.sh relies on the same).
#
# The step is a no-op on a machine without an NVIDIA display controller: it
# detects the card first and reports the skip, so the same run works on every
# box. With a GPU it asks (INSTALL_NVIDIA overrides) and installs through
# `ubuntu-drivers`, whose logic is the same as the "Additional Drivers" GUI and
# which, on Secure Boot systems, picks the signed, prebuilt module.
#
# "Proprietary" here means the plain `nvidia-driver-<branch>` package: the
# `-open` (NVIDIA open kernel modules) and `-server` branches are deliberately
# not chosen. The newest branch can drop support for very old cards, so
# NVIDIA_DRIVER pins an earlier one, and `NVIDIA_DRIVER=recommended` defers to
# whatever Ubuntu recommends (which may be an `-open` branch).
#
# It is the last step in main.sh on purpose: the driver only takes effect after
# a reboot, so the run ends with the machine ready to restart.

# ── Guard against double sourcing ─────────────────────────────────────────────
[[ -n "${_NVIDIA_SH_LOADED:-}" ]] && return
readonly _NVIDIA_SH_LOADED=1

_setup_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_setup_dir/../lib/ui.sh"
source "$_setup_dir/../lib/log.sh"
source "$_setup_dir/../lib/utils.sh"

# INSTALL_NVIDIA: unset asks before installing; 1 installs, 0 skips, both without
# a prompt. Honors the usual SETUP_ASSUME_YES / no-TTY policy through `confirm`.
INSTALL_NVIDIA="${INSTALL_NVIDIA:-}"

# NVIDIA_DRIVER: a branch number to pin (e.g. 580 → `nvidia:580`), or
# `recommended` to let ubuntu-drivers choose (possibly an -open branch). Empty
# auto-detects the newest plain/proprietary branch the hardware supports.
NVIDIA_DRIVER="${NVIDIA_DRIVER:-}"

# ── Detection ─────────────────────────────────────────────────────────────────

# _nvidia_gpu_present — true when a PCI device from NVIDIA (vendor 0x10de) is a
# display controller (class 0x03xx). The class check matters: NVIDIA also makes
# audio, USB-C and network controllers, and their presence alone must not drag a
# driver install onto a machine that only has onboard Intel/AMD graphics.
#
# sysfs first, so this is dependency-free — it also runs cleanly before pciutils
# would ever be installed. lspci is a fallback for the rare box without sysfs.
_nvidia_gpu_present() {
    local dev vendor class lspci_out

    for dev in /sys/bus/pci/devices/*; do
        [[ -r "$dev/vendor" && -r "$dev/class" ]] || continue
        read -r vendor < "$dev/vendor" || continue
        read -r class  < "$dev/class"  || continue
        if [[ "$vendor" == '0x10de' && "$class" == 0x03* ]]; then
            return 0
        fi
    done

    # `lspci | grep -q` would let pipefail turn a SIGPIPE on lspci into a false
    # negative, so capture the output first and match against it.
    if command_exists lspci; then
        lspci_out="$(lspci -n 2>/dev/null || true)"
        grep -qE '03[0-9a-f]{2}: 10de:' <<< "$lspci_out" && return 0
    fi
    return 1
}

# _nvidia_driver_loaded — the kernel module is live, so there is nothing to do.
_nvidia_driver_loaded() {
    [[ -r /proc/driver/nvidia/version ]]
}

# _nvidia_driver_installed — a driver package is on the system but the module is
# not loaded yet: the install is done and only a reboot is missing. `-open` and
# `-server` packages count too, so a machine set up by hand is not reinstalled.
_nvidia_driver_installed() {
    local status=''
    status="$(dpkg-query -W -f='${Status}\n' 'nvidia-driver-*' 2>/dev/null || true)"
    grep -q 'install ok installed' <<< "$status"
}

# _nvidia_latest_proprietary — the highest `nvidia-driver-<N>` branch
# ubuntu-drivers lists for this hardware, excluding `-open` and `-server`. The
# trailing-whitespace anchor in the pattern is what does the excluding: the
# suffix on those variants is a `-`, not whitespace. Prints nothing (returns 1)
# when ubuntu-drivers is absent or lists no plain branch.
_nvidia_latest_proprietary() {
    command_exists ubuntu-drivers || return 1
    ubuntu-drivers devices 2>/dev/null \
        | grep -oE 'nvidia-driver-[0-9]+[[:space:]]' \
        | grep -oE '[0-9]+' \
        | sort -n \
        | tail -n1
}

# ── Install ───────────────────────────────────────────────────────────────────

# The driver packages live in `restricted`; `ubuntu-drivers-common` provides the
# `ubuntu-drivers` tool. add-apt-repository is already present from step 1's
# software-properties-common.
install_nvidia_repo_prereqs() {
    _sudo add-apt-repository -y restricted
    _sudo apt update
    _sudo apt install -y ubuntu-drivers-common
}

# install_nvidia_driver [branch] — with no branch, let ubuntu-drivers pick; with
# one, pin it (`nvidia:580`), which is the documented way to choose a version.
install_nvidia_driver() {
    local branch="${1:-}"
    if [[ -n "$branch" ]]; then
        _sudo ubuntu-drivers install "nvidia:${branch}"
    else
        _sudo ubuntu-drivers install
    fi
}

# ── nvidia_setup ──────────────────────────────────────────────────────────────
nvidia_setup() {
    local branch=''

    section 'NVIDIA drivers'

    if ! _nvidia_gpu_present; then
        info 'No NVIDIA GPU detected. Skipping.'
        return 0
    fi

    if _nvidia_driver_loaded; then
        info 'NVIDIA driver already loaded. Skipping.'
        return 0
    fi

    if _nvidia_driver_installed; then
        info 'NVIDIA driver installed but not loaded — reboot to activate it.'
        return 0
    fi

    case "${INSTALL_NVIDIA:-}" in
        0|no|false)
            info 'NVIDIA GPU detected — skipping driver install (INSTALL_NVIDIA=0).'
            return 0
            ;;
        1|yes|true)
            : # proceed without asking
            ;;
        *)
            if ! confirm 'NVIDIA GPU detected — install the latest proprietary driver now?'; then
                warn 'Skipping NVIDIA driver install.'
                return 0
            fi
            ;;
    esac

    # ubuntu-drivers is needed to read the candidate list, so install the tool
    # before resolving the branch.
    run_or_die 'Installing NVIDIA repository prerequisites' install_nvidia_repo_prereqs

    if [[ "$NVIDIA_DRIVER" == 'recommended' ]]; then
        branch=''
        info 'Using the driver Ubuntu recommends'
    elif [[ -n "$NVIDIA_DRIVER" ]]; then
        branch="$NVIDIA_DRIVER"
        info "Installing the pinned driver: nvidia-driver-$branch"
    else
        branch="$(_nvidia_latest_proprietary || true)"
        if [[ -n "$branch" ]]; then
            info "Installing the latest proprietary driver: nvidia-driver-$branch"
        else
            warn 'No proprietary branch detected — using the driver Ubuntu recommends'
        fi
    fi

    run_or_die 'Installing the NVIDIA driver' install_nvidia_driver "$branch"

    success 'NVIDIA driver installed.'
    info 'Reboot to load the driver, then verify with nvidia-smi.'
}
