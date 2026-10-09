#!/usr/bin/env bash
# =============================================================================
# scripts/docker-test.sh — run the setup against a clean Ubuntu, in a throwaway
# container built from the repo's Dockerfile
# =============================================================================
# Usage:
#   scripts/docker-test.sh [release ...]
#
# With no release arguments it tests the default (26.04). Each release is built
# once into linux-utils-test:<release> and run in a fresh `docker run --rm`
# container from a frozen snapshot of the repository mounted read-only at /work.
# The image is never modified, so a second run starts from the same pristine
# filesystem — the sandbox is disposable by construction.
#
# The snapshot matters: a live bind-mount can be rewritten under the container's
# feet by an editor and make bash execute a half-read line. Each invocation
# copies the working tree once, up front, and every release runs from that copy.
#
# The image build is retried up to three times: with the Dockerfile's
# `# syntax=` directive gone, the only registry left in the build is the ubuntu
# base pull — but Docker Desktop prunes unreferenced base images, and a
# transient auth.docker.io failure (504s seen in the wild) used to fail every
# run before it started. The container run streams main.sh's output live
# instead of hiding it behind `run`'s spinner: a full run is many minutes and
# several GB, and silence behind a frozen spinner reads like a hang.
#
# Environment:
#   RUNS   Number of times to run main.sh inside the container (default 1).
#          RUNS=2 tests idempotency on an already-configured machine, not a
#          clean install.
#   KEEP   Set to 1 to keep the container after the run (drops --rm).
#   SETUP_DESKTOP
#          Forwarded to the container when set (e.g. `cinnamon`, `unknown`),
#          to exercise a desktop other than the image default (`gnome`);
#          unset keeps that default.
#
# This only orchestrates Docker; it runs no part of the setup on the host.

set -euo pipefail
IFS=$'\n\t'

__repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$__repo_root/lib/log.sh"

readonly DEFAULT_RELEASES=(26.04)
readonly IMAGE_PREFIX='linux-utils-test'

usage() {
    cat <<'EOF'
Usage: scripts/docker-test.sh [release ...]

  release     Ubuntu release to test (22.04, 24.04, 26.04, ...).
              Defaults to 26.04.

Environment:
  RUNS              How many times to run main.sh inside the container (default 1).
                    RUNS=2 tests idempotency on an already-configured machine.
  KEEP              Set to 1 to keep the container after the run.
  SETUP_DESKTOP     Forwarded into the container when set (e.g. cinnamon, unknown)
                    to test a desktop other than the image default (gnome).

Notes:
  The image build retries up to 3 times on transient registry failures, and
  the container run streams main.sh's output live. A full run takes many
  minutes and downloads several GB.

Options:
  -h, --help  Show this message.
EOF
}

require_docker() {
    command -v docker >/dev/null 2>&1 || {
        error 'docker not found — this test needs a working Docker daemon'
        return 1
    }
    docker info >/dev/null 2>&1 || {
        error 'docker is present but the daemon is not reachable'
        return 1
    }
}

# ── Repository snapshot ───────────────────────────────────────────────────────
# A run mounts a frozen copy of the working tree, not the live one. A live
# bind-mount is read-only to the container, but the host can still rewrite it
# mid-run — and bash executing a script edited under it reads garbage (a
# half-written comment line becomes a command). The snapshot removes that race.
__snapshot_dir=''

_cleanup_snapshot() {
    if [[ -n "$__snapshot_dir" && -d "$__snapshot_dir" ]]; then
        rm -rf "$__snapshot_dir"
    fi
}
trap _cleanup_snapshot EXIT

# snapshot_repo — copy the working tree to a fresh temp directory and print it.
snapshot_repo() {
    local dir
    dir="$(mktemp -d "${TMPDIR:-/tmp}/linux-utils-test.XXXXXX")" || return 1
    tar -C "$__repo_root" \
        --exclude=.git --exclude=build --exclude=dist --exclude='*.log' \
        -cf - . | tar -C "$dir" -xf - \
        || { rm -rf "$dir"; return 1; }
    printf '%s' "$dir"
}

# build_image image release — docker build, retried. With the Dockerfile's
# `# syntax=` directive gone the only registry left in the build is the ubuntu
# base pull (which Docker Desktop periodically prunes), so a transient
# auth.docker.io failure must not take down the whole test on the first
# attempt. Every attempt goes through `run`, so its failure tail lands in the
# log; the wait between attempts is announced with `warn`, and the last
# attempt's exit status is what returns.
build_image() {
    local image="$1" release="$2" attempt rc=1
    local -a backoff=( 5 15 )

    for attempt in 1 2 3; do
        if run "Building $image (attempt $attempt/3)" docker build \
            --build-arg "UBUNTU_VERSION=$release" \
            -t "$image" "$__repo_root"; then
            return 0
        else
            rc=$?
        fi
        if (( attempt < 3 )); then
            warn "Build attempt $attempt/3 failed (exit $rc) — retrying in ${backoff[attempt-1]}s"
            sleep "${backoff[attempt-1]}"
        fi
    done

    error "Could not build $image after 3 attempts (exit $rc)"
    return "$rc"
}

# run_release release runs — build the image, then run it `runs` times in one
# container. --rm makes the container disposable; the snapshot is mounted
# read-only, so neither the working tree nor the snapshot can be touched.
run_release() {
    local release="$1" runs="$2"
    local image="$IMAGE_PREFIX:$release"
    local -a run_flags=( --rm )
    local -a env_flags=( -e "RUNS=$runs" )
    local rc=0

    section "Testing on ubuntu:$release"

    [[ "${KEEP:-0}" == "1" ]] && run_flags=()

    # Forwarded only when set: unset keeps the image default (gnome), which is
    # what covers the desktop package set; an explicit value exercises another
    # path — a real desktop id, or `unknown` for the desktop-neutral set.
    if [[ -n "${SETUP_DESKTOP:-}" ]]; then
        env_flags+=( -e "SETUP_DESKTOP=$SETUP_DESKTOP" )
    fi

    build_image "$image" "$release"

    # Live output instead of `run`'s spinner: this step IS the test — many
    # minutes inside the container — and `run` would swallow every step label
    # behind one frozen spinner, which reads like a hang. `tee` keeps the log
    # copy; with no TTY on the container's stdout, main.sh's own spinner stays
    # off and its step lines stream cleanly. Under pipefail the pipeline's
    # status is docker run's own (tee always succeeds), and `|| rc=$?` catches
    # it without set -e firing.
    step "Running main.sh on ubuntu:$release — live output follows"
    docker run \
        ${run_flags[@]+"${run_flags[@]}"} \
        ${env_flags[@]+"${env_flags[@]}"} \
        -v "$__snapshot_dir:/work:ro" \
        "$image" \
        bash -c 'for (( i = 1; i <= RUNS; i++ )); do
                     echo "=== run $i/$RUNS ==="
                     bash ./main.sh || exit $?
                 done' \
        2>&1 | tee -a "$LOG_FILE" || rc=$?

    if (( rc != 0 )); then
        error "FAILED: Running main.sh on ubuntu:$release (exit $rc)"
        warn "Full log: $LOG_FILE"
        return "$rc"
    fi

    success "ubuntu:$release passed"
}

main() {
    local -a releases=()
    local arg runs

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
                releases+=( "$1" )
                shift
                ;;
        esac
    done

    (( ${#releases[@]} )) || releases=( "${DEFAULT_RELEASES[@]}" )

    runs="${RUNS:-1}"
    [[ "$runs" =~ ^[1-9][0-9]*$ ]] || {
        error "RUNS must be a positive integer, got: $runs"
        return 2
    }

    require_docker || return 1

    __snapshot_dir="$(snapshot_repo)" || {
        error 'could not snapshot the repository'
        return 1
    }

    banner 'CONTAINER TEST'

    for arg in "${releases[@]}"; do
        run_release "$arg" "$runs"
    done
}

main "$@"
