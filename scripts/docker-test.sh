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
# container with the repository mounted read-only at /work. The image is never
# modified, so a second run starts from the same pristine filesystem — the
# sandbox is disposable by construction.
#
# Environment:
#   RUNS   Number of times to run main.sh inside the container (default 1).
#          RUNS=2 tests idempotency on an already-configured machine, not a
#          clean install.
#   KEEP   Set to 1 to keep the container after the run (drops --rm).
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
  RUNS        How many times to run main.sh inside the container (default 1).
              RUNS=2 tests idempotency on an already-configured machine.
  KEEP        Set to 1 to keep the container after the run.

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

# run_release release runs — build the image, then run it `runs` times in one
# container. --rm makes the container disposable; the -v mount is read-only so
# the working tree cannot be touched.
run_release() {
    local release="$1" runs="$2"
    local image="$IMAGE_PREFIX:$release"
    local -a run_flags=( --rm )

    section "Testing on ubuntu:$release"

    [[ "${KEEP:-0}" == "1" ]] && run_flags=()

    run "Building $image" docker build \
        --build-arg "UBUNTU_VERSION=$release" \
        -t "$image" "$__repo_root"

    run "Running main.sh on ubuntu:$release" docker run \
        ${run_flags[@]+"${run_flags[@]}"} \
        -e "RUNS=$runs" \
        -v "$__repo_root:/work:ro" \
        "$image" \
        bash -c 'for (( i = 1; i <= RUNS; i++ )); do
                     echo "=== run $i/$RUNS ==="
                     bash ./main.sh || exit $?
                 done'

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

    banner 'CONTAINER TEST'

    for arg in "${releases[@]}"; do
        run_release "$arg" "$runs"
    done
}

main "$@"
