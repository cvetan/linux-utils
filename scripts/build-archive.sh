#!/usr/bin/env bash
# =============================================================================
# scripts/build-archive.sh — package the repo into a makeself self-extracting
# archive, the artifact every release ships
# =============================================================================
# Usage:
#   scripts/build-archive.sh [version] [output-dir]
#     version      embedded in the archive label and used in its filename
#                  (default: `git describe --tags --always --dirty`)
#     output-dir   where the .run is written (default: dist/)
#
# Options:
#   -h, --help    this message
#
# Environment:
#   MAKESELF      path to the makeself binary, when it is not in PATH. CI
#                 installs the distribution package (`sudo apt install makeself`,
#                 which installs /usr/bin/makeself); this override exists so the
#                 same script can build an archive from a makeself you unpacked
#                 by hand.
#
# This is the whole of what .github/workflows/release.yml and build.yml do, so a
# release can be built and checked on a laptop before a tag goes out.
#
# Two deliberate decisions:
#
#   * The payload is an explicit allowlist, not the working tree. main.sh
#     resolves its own root from BASH_SOURCE and lib/preflight.sh reads
#     README.md from one level above lib/, so the archive has to carry exactly
#     that layout — and README.md is not decoration, a missing one is a silently
#     degraded preflight at run time. setup/dev-setup.sh (v1) stays out: it is
#     superseded, and its config block is a wall of placeholder values.
#
#   * The build never runs the setup. The archive is extracted with --noexec
#     and inspected, because a release job has no business installing apt
#     packages on a runner.
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

__repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$__repo_root/lib/ui.sh"

# ── Constants ─────────────────────────────────────────────────────────────────
# The directory name inside the archive. makeself derives its default extraction
# target from it, so it shows up in `--info` and in the message a user sees.
readonly ARCHIVE_DIR_NAME='linux-utils'

# What must be in the extracted archive, and what must not be. Checked after the
# build, because the whole point of the check is the archive rather than the
# repo it was made from.
readonly REQUIRED_FILES=(
    main.sh
    README.md
    lib/log.sh
    lib/preflight.sh
    lib/ui.sh
    lib/utils.sh
    setup/base_packages.sh
    setup/docker.sh
    setup/sdkman.sh
    setup/vscode.sh
    setup/zsh.sh
)
readonly EXCLUDED_FILES=(
    setup/dev-setup.sh
)

# ── Helpers ───────────────────────────────────────────────────────────────────

usage() {
    cat <<'EOF'
Usage: scripts/build-archive.sh [version] [output-dir]

  version     Label embedded in the archive and used in its filename.
              Defaults to `git describe --tags --always --dirty`.
  output-dir  Where the .run is written. Defaults to dist/.

Options:
  -h, --help  Show this message.
EOF
}

# _makeself — the binary, whatever this machine happens to call it. Debian and
# Ubuntu install it as /usr/bin/makeself with the header path patched in; a
# makeself unpacked from an official release is a makeself.sh beside its header.
_makeself() {
    printf '%s\n' "${MAKESELF:-$(command -v makeself || command -v makeself.sh || true)}"
}

_require_makeself() {
    local binary
    binary="$(_makeself)"

    [[ -n "$binary" ]] || {
        error 'makeself not found — install it (sudo apt install makeself) or set $MAKESELF'
        return 1
    }
    [[ -x "$binary" ]] || {
        error "makeself at $binary is not executable"
        return 1
    }

    printf '%s\n' "$binary"
}

# stage_payload [dir] — copy the allowlist into a clean directory, preserving the
# executable bit on main.sh. makeself runs the startup script as a command
# (`./main.sh`), so losing that bit would produce an archive that extracts fine
# and then fails to run.
stage_payload() {
    local dir="$1" file

    rm -rf "$dir"
    mkdir -p "$dir"

    for file in "${REQUIRED_FILES[@]}"; do
        if [[ ! -e "$__repo_root/$file" ]]; then
            error "missing from the repository: $file"
            return 1
        fi
    done

    cp -p "$__repo_root/main.sh" "$__repo_root/README.md" "$dir/"
    cp -r "$__repo_root/lib" "$__repo_root/setup" "$dir/"

    for file in "${EXCLUDED_FILES[@]}"; do
        rm -f "$dir/$file"
    done

    chmod +x "$dir/main.sh"
}

# build_archive payload archive label — the makeself invocation, verbatim.
#
#   --sha256     an embedded checksum, so `--check` can verify the payload
#   --nox11      baked in: makeself otherwise opens an xterm when stdout is not
#                a terminal but DISPLAY is set — an IDE or a file manager
#   --tar-extra  root:root in the tar, so the extracted tree is owned by whoever
#                runs it rather than by whoever built it
#
# gzip is deliberate: it is the one compressor every Ubuntu and Debian box has,
# and the payload is text, so the archive lands around 40 KB either way.
build_archive() {
    local payload="$1" archive="$2" label="$3" makeself
    makeself="$(_require_makeself)" || return 1

    section "Building $(basename "$archive")"

    "$makeself" \
        --gzip \
        --complevel 9 \
        --sha256 \
        --nox11 \
        --tar-extra '--owner=0 --group=0 --numeric-owner' \
        "$payload" "$archive" "$label" ./main.sh
}

# verify_archive archive [extract-dir] — every way this artifact can be subtly
# wrong, checked before it is published.
verify_archive() {
    local archive="$1" extract="${2:-}" file output

    if [[ -z "$extract" ]]; then
        extract="$(dirname "$archive")/../build/verify"
    fi

    section 'Archive metadata'
    "$archive" --info

    section 'Integrity'
    "$archive" --check

    section 'Contents'
    "$archive" --list

    # --noexec extracts without touching the machine; --quiet keeps the listing
    # out of the log twice. makeself has no runtime --nooverwrite flag, so the
    # directory is removed here instead.
    section 'Extracted payload'
    rm -rf "$extract"
    "$archive" --noexec --quiet --target "$extract"

    for file in "${REQUIRED_FILES[@]}"; do
        if [[ ! -e "$extract/$file" ]]; then
            error "not in the archive: $file"
            return 1
        fi
    done

    for file in "${EXCLUDED_FILES[@]}"; do
        if [[ -e "$extract/$file" ]]; then
            error "should not be in the archive: $file"
            return 1
        fi
    done

    # `./main.sh` is executed by the stub, not sourced, so the bit has to survive
    # packaging.
    if [[ ! -x "$extract/main.sh" ]]; then
        error 'main.sh lost its executable bit in the archive'
        return 1
    fi

    info "payload complete (${#REQUIRED_FILES[@]} files)"

    section 'Shell syntax'
    while IFS= read -r -d '' file; do
        bash -n "$file" || {
            error "syntax error in $file"
            return 1
        }
        info "${file#"$extract"/}"
    done < <(find "$extract" -type f -name '*.sh' -print0 | LC_ALL=C sort -z)

    # The one failure a makeself archive actually has: the preflight reads the
    # wording of its requirements out of the bundled README, so a payload
    # without it degrades silently. Reading it back from inside the extracted
    # tree exercises the whole chain — main.sh's layout, lib/preflight.sh
    # finding README.md one level up, and its sourcing of lib/ui.sh.
    section 'Reading the bundled README'
    output="$(cd "$extract" && SETUP_ASSUME_YES=1 bash -c 'source lib/preflight.sh; show_requirements')" || {
        printf '%s\n' "$output"
        error 'could not read the requirements out of the bundled README'
        return 1
    }
    printf '%s\n' "$output"

    success 'archive verified'
}

# write_checksum archive — a .sha256 next to the artifact, so a download can be
# checked before it is run. Written from inside the directory so the file names
# the artifact relatively and `sha256sum -c` works where it is downloaded.
write_checksum() {
    local archive="$1" dir base
    dir="$(dirname "$archive")"
    base="$(basename "$archive")"

    ( cd "$dir" && sha256sum "$base" > "$base.sha256" )
}

# ── Entry ─────────────────────────────────────────────────────────────────────

main() {
    local version='' out_dir='' build_dir payload archive label

    while (( $# > 0 )); do
        case "$1" in
            -h|--help)
                usage
                return 0
                ;;
            -*)
                error "unknown option: $1"
                usage >&2
                return 2
                ;;
            *)
                if [[ -z "$version" ]]; then
                    version="$1"
                elif [[ -z "$out_dir" ]]; then
                    out_dir="$1"
                else
                    error "unexpected argument: $1"
                    usage >&2
                    return 2
                fi
                shift
                ;;
        esac
    done

    _require_makeself >/dev/null   # fail before anything is written

    if [[ -z "$version" ]]; then
        version="$(git -C "$__repo_root" describe --tags --always --dirty 2>/dev/null || printf 'dev')"
    fi

    # A git tag may hold characters a filename cannot — release/v2.0.0 is a legal
    # tag — and this string ends up in a path. The tag itself is untouched; only
    # the filename and the label are flattened.
    version="${version//[^A-Za-z0-9._-]/-}"

    build_dir="$__repo_root/build"
    payload="$build_dir/$ARCHIVE_DIR_NAME"
    out_dir="${out_dir:-$__repo_root/dist}"
    archive="$out_dir/$ARCHIVE_DIR_NAME-$version.run"
    label="$ARCHIVE_DIR_NAME $version — Ubuntu/Debian dev machine setup"

    banner "PACKAGING $ARCHIVE_DIR_NAME $version"

    stage_payload "$payload" || return 1

    mkdir -p "$out_dir"
    build_archive "$payload" "$archive" "$label" || return 1

    verify_archive "$archive" "$build_dir/verify" || return 1

    write_checksum "$archive"

    section 'Result'
    info "$(du -h "$archive" | cut -f1)  $archive"
    cat "$archive.sha256"
}

main "$@"
