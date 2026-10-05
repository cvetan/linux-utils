#!/usr/bin/env bash
# =============================================================================
# setup/xbox.sh — keep the Xbox Wireless Adapter paired to Windows (dual boot)
# =============================================================================
# A step of main.sh, not a standalone program: it draws with lib/ui.sh and calls
# run_or_die, which main.sh defines. `confirm` comes from lib/preflight.sh, which
# main.sh sources before the step modules (setup/nvidia.sh relies on the same).
#
# The problem this fixes: on a Windows + Linux dual boot, Linux claims the Xbox
# Wireless Adapter for Windows on every boot, which makes Windows ask to re-pair
# the controller the next time it starts. The fix (from Ask Ubuntu q/1278244) is
# a udev rule that de-authorizes the dongle the moment it appears, so Linux never
# touches it and the Windows pairing survives.
#
# Detection is dynamic, not a hardcoded product list. Every revision of the
# dongle so far is a Microsoft (USB vendor 045e) device that presents as a
# MediaTek wireless adapter, so it carries an "Xbox ... wireless/adapter/dongle"
# product string and binds to the mt76x2u driver. Either signal identifies it,
# and the rule is generated from the idProduct(s) actually found — a new
# revision needs no code change. XBOX_DONGLE_IDS overrides detection (needed if
# the dongle is not attached, or if its driver is bound by something else).
#
# The trade-off is deliberate and the prompt says so: the adapter then does NOT
# work on Linux. It is a no-op on a machine without the dongle, and INSTALL_XBOX
# overrides the prompt (1 installs, 0 skips) exactly like INSTALL_NVIDIA.
#
# The rule is written to /etc/udev/rules.d/99-xbox-wireless-adapter.rules and
# applied with `udevadm control --reload-rules` + `udevadm trigger`. No initramfs
# rebuild. Runs before the NVIDIA step so a reboot-requiring step stays last.

# ── Guard against double sourcing ─────────────────────────────────────────────
[[ -n "${_XBOX_SH_LOADED:-}" ]] && return
readonly _XBOX_SH_LOADED=1

_setup_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_setup_dir/../lib/ui.sh"
source "$_setup_dir/../lib/log.sh"
source "$_setup_dir/../lib/utils.sh"

# INSTALL_XBOX: unset asks before installing; 1 installs, 0 skips, both without a
# prompt. Honors the usual SETUP_ASSUME_YES / no-TTY policy through `confirm`.
INSTALL_XBOX="${INSTALL_XBOX:-}"

# XBOX_DONGLE_IDS: optional override, a space/comma-separated list of USB
# product IDs (the vendor is always 045e). Empty — the default — detects the
# attached dongle at run time. Set it for an unattended run, or to install the
# rule when the dongle is not plugged in.
XBOX_DONGLE_IDS="${XBOX_DONGLE_IDS:-}"

_XBOX_RULE_FILE='/etc/udev/rules.d/99-xbox-wireless-adapter.rules'

# Overridable only so the detection can be exercised against a fixture tree.
_XBOX_USB_ROOT="${_XBOX_USB_ROOT:-/sys/bus/usb/devices}"

# ── Detection ─────────────────────────────────────────────────────────────────

# _xbox_product_is_dongle string — true when a USB product string names the Xbox
# wireless adapter. Lowercased by the caller. "Xbox Wireless Adapter for Windows"
# and "XBOX ACC" (the two known revisions) both match. Controllers — "Xbox One S
# Controller", "Xbox Wireless Controller", … — are excluded by the `controller`
# guard rather than by the keyword list, so a controller is never de-authorized.
_xbox_product_is_dongle() {
    local s="${1,,}"
    [[ "$s" == *xbox* ]] || return 1
    [[ "$s" == *controller* ]] && return 1
    [[ "$s" == *adapter* || "$s" == *dongle* || "$s" == *acc* || "$s" == *wireless* ]]
}

# _xbox_detect_ids — print the idProduct of every attached Xbox wireless adapter,
# one per line. Two dependency-free signals, either sufficient:
#   1. a Microsoft USB device whose product string names the adapter, and
#   2. a Microsoft USB device whose interface is bound to the MediaTek USB WiFi
#      driver (mt76x2u) — the dongle is physically a MediaTek radio, while Xbox
#      controllers bind xpad/xone and are excluded by the vendor+driver pair.
# Microsoft (vendor 045e) is required in both passes, so an unrelated MediaTek
# WiFi stick is not mistaken for the dongle.
_xbox_detect_ids() {
    local dev iface name vendor product prodstr driver

    {
        for dev in "$_XBOX_USB_ROOT"/*; do
            [[ -r "$dev/idVendor" && -r "$dev/idProduct" ]] || continue
            read -r vendor  < "$dev/idVendor"  || continue
            read -r product < "$dev/idProduct" || continue
            [[ "$vendor" == '045e' ]] || continue

            prodstr=''
            [[ -r "$dev/product" ]] && read -r prodstr < "$dev/product" 2>/dev/null || true
            if _xbox_product_is_dongle "$prodstr"; then
                printf '%s\n' "$product"
            fi
        done

        for iface in "$_XBOX_USB_ROOT"/*:*; do
            [[ -e "$iface/driver" ]] || continue
            driver="$(basename "$(readlink -f "$iface/driver")")"
            [[ "$driver" == mt76* ]] || continue

            name="${iface##*/}"; name="${name%%:*}"
            dev="$_XBOX_USB_ROOT/$name"
            [[ -r "$dev/idVendor" && -r "$dev/idProduct" ]] || continue
            read -r vendor  < "$dev/idVendor"  || continue
            read -r product < "$dev/idProduct" || continue
            [[ "$vendor" == '045e' ]] || continue
            printf '%s\n' "$product"
        done
    } | awk '!seen[$0]++'
}

# ── The rule ──────────────────────────────────────────────────────────────────

# _xbox_rule_line id — one udev rule. ATTRS (not ATTR) matches the device or any
# parent, which is reliable for USB; the `[ -f … ]` guard keeps the RUN from
# erroring when the attribute is absent. `$devpath` is udev's own substitution
# and is intentionally left unexpanded by this shell (it sits in single quotes).
_xbox_rule_line() {
    local id="$1"
    printf 'ACTION=="add", ATTRS{idVendor}=="045e", ATTRS{idProduct}=="%s", RUN="/bin/sh -c '\''[ -f /sys$devpath/authorized ] && echo 0 >/sys$devpath/authorized || true'\''"\n' "$id"
}

# _xbox_rule_content id … — the whole file, on stdout. One rule per product ID:
# udev matching is fnmatch, not a regex, so there is no `|` alternation.
_xbox_rule_content() {
    local id

    printf '%s\n' \
        '# Installed by linux-utils — de-authorize the Xbox Wireless Adapter for' \
        '# Windows (vendor 045e) under Linux, so a Windows dual boot keeps its' \
        '# controller pairing and does not ask to pair again.' \
        '# To undo: remove this file and run:' \
        '#   sudo udevadm control --reload-rules && sudo udevadm trigger'
    for id in "$@"; do
        _xbox_rule_line "$id"
    done
}

_xbox_install_rule() {
    _xbox_rule_content "$@" | _sudo tee "$_XBOX_RULE_FILE" > /dev/null
}

# _xbox_rule_current id … — true when the installed file already matches what we
# would write, so a re-run stays quiet.
_xbox_rule_current() {
    [[ -r "$_XBOX_RULE_FILE" ]] || return 1
    diff -q <(_xbox_rule_content "$@") "$_XBOX_RULE_FILE" > /dev/null 2>&1
}

# ── xbox_setup ────────────────────────────────────────────────────────────────
xbox_setup() {
    local forced=0
    local -a ids=() configured=()

    section 'Xbox Wireless Adapter (dual-boot fix)'

    case "${INSTALL_XBOX}" in
        0|no|false)
            info 'Xbox step disabled (INSTALL_XBOX=0).'
            return 0
            ;;
        1|yes|true)
            forced=1
            ;;
    esac

    if [[ -n "$XBOX_DONGLE_IDS" ]]; then
        IFS=' ,' read -r -a configured <<< "$XBOX_DONGLE_IDS"
        ids=( "${configured[@]}" )
    else
        mapfile -t ids < <(_xbox_detect_ids)
    fi

    if (( ${#ids[@]} == 0 )); then
        if (( forced )); then
            warn 'No Xbox Wireless Adapter detected and XBOX_DONGLE_IDS is not set — nothing to install.'
        else
            info 'No Xbox Wireless Adapter detected. Skipping.'
        fi
        return 0
    fi

    if (( ! forced )); then
        if [[ -n "$XBOX_DONGLE_IDS" ]]; then
            info "Using the configured dongle ID(s): ${ids[*]}"
        else
            info "Xbox Wireless Adapter detected: ${ids[*]}"
        fi
        if ! confirm 'Disable the Xbox Wireless Adapter under Linux? It will not work here, but Windows keeps its pairing.'; then
            warn 'Skipping Xbox udev rule.'
            return 0
        fi
    fi

    if _xbox_rule_current "${ids[@]}"; then
        info 'Xbox udev rule already installed. Skipping.'
    else
        run_or_die 'Installing Xbox Wireless Adapter udev rule' _xbox_install_rule "${ids[@]}"
    fi

    run_or_die 'Reloading udev rules' _sudo udevadm control --reload-rules
    run_or_die 'Triggering udev' _sudo udevadm trigger

    success 'Xbox udev rule active.'
    info 'The adapter is left alone by Linux; pair the controller once more in Windows if needed.'
}
