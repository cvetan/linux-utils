#!/usr/bin/env bash
# =============================================================================
# setup/ssh.sh — adopt the SSH keys in ~/.ssh and manage their host config
# =============================================================================
# A step of main.sh, not a standalone program: it draws with lib/ui.sh and calls
# run_or_die, which main.sh defines.
#
# The default path is to *adopt* what is already in ~/.ssh: copy your keys there
# however you like — from MEGA, a USB stick, scp — and this step tightens their
# permissions and, for any key not mapped yet, asks which host it belongs to and
# writes the mapping. Nothing is fetched from the network and no key is ever
# overwritten, because the module never writes key material at all.
#
# Setting SSH_KEYS_BUNDLE instead installs keys from an offline bundle (a
# directory, .tar / .tar.gz or .zip) and, if the bundle carries a config.d/,
# uses that as the host config instead of prompting. That is the reproducible,
# non-interactive path; the adopt path is the interactive, no-bundle one.
#
# ssh_preflight runs at the front of main.sh, before anything is installed:
# it reports whether a bundle is set or keys are present, asks whether to use
# them, and records the plan in _SSH_MODE. ssh_setup later executes that plan.
#
# Key material must never pass through `run`, which appends a command's output to
# the run log — so keys are only ever chmod'ed or copied with `install`, and only
# fingerprints are ever printed.

# ── Guard against double sourcing ─────────────────────────────────────────────
[[ -n "${_SSH_SH_LOADED:-}" ]] && return
readonly _SSH_SH_LOADED=1

_setup_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_setup_dir/../lib/ui.sh"
source "$_setup_dir/../lib/utils.sh"

# Optional offline bundle. When set, its keys are installed and its config.d/ is
# used verbatim; when empty, the keys already in ~/.ssh are adopted instead.
SSH_KEYS_BUNDLE="${SSH_KEYS_BUNDLE:-}"

# SSH_KEYS_VERIFY=1 runs a non-fatal `ssh -T` against every concrete host in the
# generated config, to prove the keys are wired up.
SSH_KEYS_VERIFY="${SSH_KEYS_VERIFY:-0}"

# Destination. Overridable for testing; defaults to the usual place.
SSH_DIR="${SSH_DIR:-$HOME/.ssh}"

# The file our host blocks are written to, and the `Include` line that pulls it
# into the user's own ~/.ssh/config.
_SSH_MANAGED_CONF='linux-utils.conf'
_SSH_INCLUDE_MARKER='# Managed by linux-utils (ssh host config)'

# Filled in by prepare_bundle while a bundle is in use.
_ssh_bundle_root=''
_ssh_work=''

# The plan ssh_preflight resolved, executed later by ssh_setup: adopt | bundle |
# skip. Empty until ssh_preflight runs (or when ssh_setup is called standalone).
_SSH_MODE=''

# ── Bundle helpers (optional SSH_KEYS_BUNDLE path) ────────────────────────────

# bundle_root_in dir — the directory the bundle's contents live under. An archive
# with a single top-level directory is unwrapped; anything else is used as-is.
bundle_root_in() {
    local dir="${1:?dir required}"
    local -a entries=()
    local entry

    while IFS= read -r -d '' entry; do
        entries+=( "$entry" )
    done < <(find "$dir" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)

    if (( ${#entries[@]} == 1 )) && [[ -d "${entries[0]}" ]]; then
        printf '%s' "${entries[0]}"
    else
        printf '%s' "$dir"
    fi
}

# prepare_bundle path — set _ssh_bundle_root (and _ssh_work for an archive).
# Returns 1, having warned, when the path is not a recognised bundle. An archive
# is extracted into a private temp directory, removed later by cleanup_bundle.
prepare_bundle() {
    local bundle="${1:?bundle required}"
    local work

    _ssh_bundle_root=''
    _ssh_work=''

    if [[ -d "$bundle" ]]; then
        _ssh_bundle_root="$bundle"
        return 0
    fi

    work="$(mktemp -d "${TMPDIR:-/tmp}/linux-utils-ssh.XXXXXX")" || return 1
    chmod 700 "$work"
    _ssh_work="$work"

    case "$bundle" in
        *.tar.gz|*.tgz) run 'Extracting SSH bundle' tar -xzf "$bundle" -C "$work" || return 1 ;;
        *.tar)          run 'Extracting SSH bundle' tar -xf  "$bundle" -C "$work" || return 1 ;;
        *.zip)          run 'Extracting SSH bundle' unzip -q "$bundle" -d "$work" || return 1 ;;
        *)
            warn "Unrecognised SSH bundle format: $bundle"
            return 1
            ;;
    esac

    _ssh_bundle_root="$(bundle_root_in "$work")"
    return 0
}

# Remove the extracted copy, if any. Always succeeds.
cleanup_bundle() {
    if [[ -n "$_ssh_work" && -d "$_ssh_work" ]]; then
        rm -rf "$_ssh_work"
    fi
    _ssh_work=''
    _ssh_bundle_root=''
    return 0
}

# ── Key helpers ───────────────────────────────────────────────────────────────

# _key_fingerprint file — the SHA256 fingerprint, or nothing when ssh-keygen is
# unavailable or the file is not a key. Only a fingerprint is ever printed; the
# key bytes themselves stay out of every stream.
_key_fingerprint() {
    local file="${1:?file required}"
    command_exists ssh-keygen || return 1
    ssh-keygen -lf "$file" 2>/dev/null | awk 'NR == 1 { print $2 }'
}

# _same_key a b — true when the two files are the same key. Fingerprints catch a
# re-export with different formatting; a byte comparison is the fallback.
_same_key() {
    local a="${1:?}" b="${2:?}"
    local fa fb

    fa="$(_key_fingerprint "$a" || true)"
    fb="$(_key_fingerprint "$b" || true)"
    if [[ -n "$fa" && -n "$fb" ]]; then
        [[ "$fa" == "$fb" ]]
        return
    fi
    cmp -s "$a" "$b"
}

# _is_private_key file — a private key that is not one of ~/.ssh's other files.
# Deliberately dependency-free: this runs in the up-front check, before step 1 has
# installed openssh-client, so it looks for a PEM/OpenSSH private-key header or a
# matching .pub sibling rather than calling ssh-keygen. An encrypted key still
# carries its header, so it is recognised without a passphrase.
_is_private_key() {
    local file="${1:?file required}"
    local base

    base="$(basename "$file")"
    case "$base" in
        *.pub|known_hosts*|authorized_keys*|*.old|config|config.*|environment|rc)
            return 1
            ;;
    esac
    [[ -f "$file" ]] || return 1

    if grep -qE -- '-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----' "$file" 2>/dev/null; then
        return 0
    fi
    [[ -f "${file}.pub" ]]
}

# discover_keys dir — the private keys sitting directly in dir, sorted.
discover_keys() {
    local dir="${1:?dir required}"
    local file

    while IFS= read -r -d '' file; do
        if _is_private_key "$file"; then
            printf '%s\n' "$file"
        fi
    done < <(find "$dir" -maxdepth 1 -type f -print0 2>/dev/null | LC_ALL=C sort -z)
}

# _key_is_mapped keyfile — true when the key's basename is already referenced by
# an IdentityFile line, in the managed config or the user's own ~/.ssh/config.
_key_is_mapped() {
    local keyfile="${1:?file required}"
    local base
    local -a files=()

    base="$(basename "$keyfile")"
    [[ -f "$SSH_DIR/$_SSH_MANAGED_CONF" ]] && files+=( "$SSH_DIR/$_SSH_MANAGED_CONF" )
    [[ -f "$SSH_DIR/config" ]] && files+=( "$SSH_DIR/config" )
    (( ${#files[@]} )) || return 1

    grep -hE '^[[:space:]]*IdentityFile[[:space:]]' "${files[@]}" 2>/dev/null \
        | grep -qF -- "$base"
}

# ── Keys ──────────────────────────────────────────────────────────────────────

# Lock down anything already in ~/.ssh that looks like a private key. Only the
# conventional `id_*` names are touched, so nothing surprising is re-moded.
harden_private_keys() {
    local file

    [[ -d "$SSH_DIR" ]] || return 0
    chmod 700 "$SSH_DIR" 2>/dev/null || true

    while IFS= read -r -d '' file; do
        chmod 600 "$file" 2>/dev/null || true
    done < <(find "$SSH_DIR" -maxdepth 1 -type f -name 'id_*' ! -name '*.pub' -print0 2>/dev/null)
}

# install_keys root — copy every file in the bundle into ~/.ssh. Private keys get
# 600, public keys 644. A destination that already exists is never overwritten.
install_keys() {
    local root="${1:?root required}"
    local keys_dir file name dest mode installed=0 kept=0

    if [[ -d "$root/keys" ]]; then
        keys_dir="$root/keys"
    else
        keys_dir="$root"
    fi

    while IFS= read -r -d '' file; do
        name="$(basename "$file")"
        dest="$SSH_DIR/$name"

        case "$name" in
            *.pub) mode=644 ;;
            *)     mode=600 ;;
        esac

        if [[ -e "$dest" ]]; then
            if _same_key "$file" "$dest"; then
                info "SSH key unchanged: $name"
            else
                warn "SSH key already exists and differs — keeping the existing $name"
            fi
            kept=$(( kept + 1 ))
            continue
        fi

        run_or_die "Installing SSH key $name" install -m "$mode" "$file" "$dest"
        installed=$(( installed + 1 ))
    done < <(find "$keys_dir" -maxdepth 1 -type f -print0 2>/dev/null)

    if (( installed == 0 && kept == 0 )); then
        warn "No key files found in the SSH bundle ($keys_dir)"
    fi
}

# ── Host config ───────────────────────────────────────────────────────────────

# ensure_ssh_include — make ~/.ssh/config pull in the managed file. Prepended,
# because ssh_config is first-match-wins and the bundle's Host blocks should take
# precedence over a catch-all the user may have. Added at most once.
ensure_ssh_include() {
    local config="$SSH_DIR/config"
    local marker="$_SSH_INCLUDE_MARKER"
    local tmp

    if [[ ! -f "$config" ]]; then
        : > "$config"
    fi
    chmod 600 "$config" 2>/dev/null || true

    if grep -qF "Include $_SSH_MANAGED_CONF" "$config" 2>/dev/null; then
        return 0
    fi

    tmp="$(mktemp "$config.XXXXXX")" || return 1
    chmod 600 "$tmp" 2>/dev/null || true
    {
        printf '%s\n' "$marker"
        printf '%s\n' "Include $_SSH_MANAGED_CONF"
        printf '\n'
        cat "$config"
    } > "$tmp"
    mv "$tmp" "$config"
    chmod 600 "$config" 2>/dev/null || true
    info "Added 'Include $_SSH_MANAGED_CONF' to ~/.ssh/config"
}

# install_host_config root — bundle path only: concatenate config.d/*.conf into
# the managed file. The managed file is rewritten on every run, so an edited or
# removed block propagates instead of lingering; the user's own ~/.ssh/config is
# untouched. A bundle without config.d/ leaves the managed file alone.
install_host_config() {
    local root="${1:?root required}"
    local config_d="$root/config.d"
    local managed="$SSH_DIR/$_SSH_MANAGED_CONF"
    local file
    local -a confs=()

    [[ -d "$config_d" ]] || return 0

    while IFS= read -r -d '' file; do
        confs+=( "$file" )
    done < <(find "$config_d" -maxdepth 1 -type f -name '*.conf' -print0 2>/dev/null | LC_ALL=C sort -z)

    if (( ${#confs[@]} == 0 )); then
        warn "No host config blocks (*.conf) found in $config_d"
        return 0
    fi

    : > "$managed"
    chmod 600 "$managed" 2>/dev/null || true
    for file in "${confs[@]}"; do
        printf '# ---- %s ----\n' "$(basename "$file")" >> "$managed"
        cat "$file" >> "$managed"
        printf '\n' >> "$managed"
    done

    info "SSH host config written to $managed (${#confs[@]} block(s))"
}

# prompt_host_block keyfile — ask for a Host block for one key and append it to
# the managed config. Returns 1 when the user skipped or there is no terminal.
prompt_host_block() {
    local keyfile="${1:?file required}"
    local base alias host user

    base="$(basename "$keyfile")"

    alias="$(ask "Host alias for $base (blank to skip)" || true)"
    [[ -n "$alias" ]] || return 1

    host="$(ask "HostName for $alias (blank = $alias)" "$alias" || true)"
    user="$(ask "User for $alias (blank for none)" || true)"

    {
        printf '\n# ---- %s (linux-utils) ----\n' "$base"
        printf 'Host %s\n' "$alias"
        if [[ "$host" != "$alias" ]]; then
            printf '    HostName %s\n' "$host"
        fi
        if [[ -n "$user" ]]; then
            printf '    User %s\n' "$user"
        fi
        printf '    IdentityFile ~/.ssh/%s\n' "$base"
        printf '    IdentitiesOnly yes\n'
    } >> "$SSH_DIR/$_SSH_MANAGED_CONF"
    return 0
}

# map_unmapped_keys — adopt path: for every discovered key with no mapping yet,
# ask for one. Keys already referenced by an IdentityFile line — whether written
# here earlier or by hand — are left alone, which keeps a re-run quiet. Without a
# terminal `ask` yields nothing and the key is skipped rather than guessed at.
map_unmapped_keys() {
    local keyfile mapped=0 skipped=0
    local -a keys=()

    # Collect first, then iterate: a `while read … done < <(discover_keys …)`
    # loop redirects fd 0 to the process substitution, so `ask`'s `[[ -t 0 ]]`
    # reports "no terminal" and silently skips every prompt.
    mapfile -t keys < <(discover_keys "$SSH_DIR")

    for keyfile in ${keys[@]+"${keys[@]}"}; do
        [[ -n "$keyfile" ]] || continue
        if _key_is_mapped "$keyfile"; then
            info "Host mapping already present for $(basename "$keyfile")"
            continue
        fi
        if prompt_host_block "$keyfile"; then
            mapped=$(( mapped + 1 ))
        else
            skipped=$(( skipped + 1 ))
        fi
    done

    if (( mapped > 0 )); then
        info "Mapped $mapped key(s) in $SSH_DIR/$_SSH_MANAGED_CONF"
    fi
    if (( skipped > 0 )); then
        warn "$skipped key(s) left unmapped — re-run to map them, or edit $SSH_DIR/$_SSH_MANAGED_CONF"
    fi
}

# finalize_managed_config — pull the managed file into ~/.ssh/config once there
# is something in it, and keep it private. A no-op when there is nothing managed.
finalize_managed_config() {
    local managed="$SSH_DIR/$_SSH_MANAGED_CONF"

    [[ -s "$managed" ]] || return 0
    chmod 600 "$managed" 2>/dev/null || true
    ensure_ssh_include
}

# ── Verification ──────────────────────────────────────────────────────────────

# verify_hosts — with SSH_KEYS_VERIFY=1, connect to each concrete Host alias. The
# output is captured rather than run through `run`, so the provider's banner
# stays out of the log, and the exit status is not treated as a verdict: GitHub,
# for one, exits 1 after a successful authentication.
verify_hosts() {
    local managed="$SSH_DIR/$_SSH_MANAGED_CONF"
    local host out
    local -a hosts=()

    [[ "$SSH_KEYS_VERIFY" == '1' ]] || return 0

    if ! command_exists ssh; then
        warn 'ssh is not installed — skipping verification'
        return 0
    fi
    if [[ ! -f "$managed" ]]; then
        warn 'No managed SSH config to verify against'
        return 0
    fi

    mapfile -t hosts < <(
        awk 'tolower($1) == "host" {
                 for (i = 2; i <= NF; i++)
                     if ($i !~ /[*?!]/) print $i
             }' "$managed" | LC_ALL=C sort -u
    )

    if (( ${#hosts[@]} == 0 )); then
        warn 'No concrete hosts in the managed config to verify'
        return 0
    fi

    for host in "${hosts[@]}"; do
        out="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
                   -o ConnectTimeout=10 -T "$host" 2>&1 || true)"
        # `step`, not `info`: this is the provider's message, not our verdict.
        step "$host — $(printf '%s' "$out" | head -n1)"
    done
}

# ── Adopt path ────────────────────────────────────────────────────────────────

# adopt_existing_keys — use the keys already in ~/.ssh: tighten their permissions
# and prompt for a host mapping for any that do not have one.
adopt_existing_keys() {
    local -a keys=()
    local keyfile fingerprint

    while IFS= read -r keyfile; do
        [[ -n "$keyfile" ]] && keys+=( "$keyfile" )
    done < <(discover_keys "$SSH_DIR")

    if (( ${#keys[@]} == 0 )); then
        warn "No SSH private keys found in $SSH_DIR — copy your keys there, then re-run"
        return 0
    fi

    for keyfile in "${keys[@]}"; do
        chmod 600 "$keyfile" 2>/dev/null || true
        fingerprint="$(_key_fingerprint "$keyfile" || true)"
        if [[ -n "$fingerprint" ]]; then
            info "Found SSH key $(basename "$keyfile") — $fingerprint"
        else
            info "Found SSH key $(basename "$keyfile")"
        fi
    done

    map_unmapped_keys
}

# ── Up-front check ────────────────────────────────────────────────────────────

# ssh_preflight — run before anything is installed, so the SSH decision is made
# up front. It resolves one of three outcomes into _SSH_MODE: use the bundle, use
# the keys in ~/.ssh, or skip. Either way it reports what it found and, when there
# is a source, asks whether to use it. It never touches the filesystem, and it
# uses the dependency-free _is_private_key, so it works before step 1 has
# installed openssh-client.
ssh_preflight() {
    local -a keys=()
    local keyfile names

    section 'SSH keys'

    # Bundle first, matching ssh_setup's precedence.
    if [[ -n "$SSH_KEYS_BUNDLE" ]]; then
        if [[ ! -e "$SSH_KEYS_BUNDLE" ]]; then
            warn "SSH_KEYS_BUNDLE is set but not found: $SSH_KEYS_BUNDLE"
            step 'SSH setup will be skipped for now'
            _SSH_MODE=skip
            return 0
        fi
        step "SSH_KEYS_BUNDLE is set: $SSH_KEYS_BUNDLE"
        if confirm 'Install SSH keys from this bundle now?'; then
            _SSH_MODE=bundle
        else
            _SSH_MODE=skip
            warn 'SSH setup will be skipped for now'
        fi
        return 0
    fi

    while IFS= read -r keyfile; do
        [[ -n "$keyfile" ]] && keys+=( "$keyfile" )
    done < <(discover_keys "$SSH_DIR")

    if (( ${#keys[@]} == 0 )); then
        warn "No SSH keys in $SSH_DIR and SSH_KEYS_BUNDLE is not set"
        step 'SSH setup will be skipped for now'
        _SSH_MODE=skip
        return 0
    fi

    success "Found ${#keys[@]} SSH key(s) in $SSH_DIR"
    names=''
    for keyfile in "${keys[@]}"; do
        names+="${names:+, }$(basename "$keyfile")"
    done
    step "$names"

    if confirm 'Set up SSH keys from ~/.ssh now?'; then
        _SSH_MODE=adopt
    else
        _SSH_MODE=skip
        warn 'SSH setup will be skipped for now'
    fi
    return 0
}

# ── ssh_setup ─────────────────────────────────────────────────────────────────
ssh_setup() {
    local mode
    section 'SSH keys setup'

    # Normally ssh_preflight resolved the plan before anything ran; called on its
    # own (a test, or a direct invocation) decide now with the same logic. The
    # plan is consumed so a later call re-resolves it instead of acting stale.
    mode="$_SSH_MODE"
    if [[ -z "$mode" ]]; then
        ssh_preflight
        mode="$_SSH_MODE"
    fi
    _SSH_MODE=''

    if [[ "$mode" == 'skip' ]]; then
        info 'SSH setup skipped for now.'
        return 0
    fi

    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR" 2>/dev/null || true

    if [[ "$mode" == 'bundle' ]]; then
        if ! prepare_bundle "$SSH_KEYS_BUNDLE"; then
            cleanup_bundle
            return 0
        fi
        info "Installing SSH keys from bundle: $SSH_KEYS_BUNDLE"
        install_keys "$_ssh_bundle_root"
        install_host_config "$_ssh_bundle_root"
        cleanup_bundle
    else
        adopt_existing_keys
    fi

    harden_private_keys
    finalize_managed_config
    verify_hosts
    info 'SSH keys ready.'
    return 0
}
