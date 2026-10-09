#!/usr/bin/env bash
# =============================================================================
# scripts/docker-test.sh — run the setup against a clean Ubuntu, in a throwaway
# container built from the repo's Dockerfile
# =============================================================================
# Usage:
#   scripts/docker-test.sh [release ...]
#
# With no release arguments it tests the default (26.04). Each release is built
# once into linux-utils-test:<release> and run in a named, disposable container
# (linux-utils-test-<release>) from a frozen snapshot of the repository mounted
# read-only at /work. The image is never modified, and the EXIT trap removes
# the container and the snapshot, so a second run starts from the same pristine
# filesystem.
#
# The snapshot matters: a live bind-mount can be rewritten under the container's
# feet by an editor and make bash execute a half-read line. Each invocation
# copies the working tree once, up front, and every release runs from that copy.
#
# Everything is bounded by timeouts, so a wedged registry, a stalled download
# or a dead Docker Desktop becomes a reported failure instead of a hang that
# never ends:
#   * `docker info` must answer within 30s (require_docker).
#   * Each build attempt is capped by BUILD_TIMEOUT (default 900s); a stalled
#     attempt is killed and the retry loop takes over.
#   * The container run is capped by RUN_TIMEOUT (default 3600s, 0 disables).
#     `timeout` signals the docker CLIENT, not the container, so the EXIT
#     trap's `docker rm -f` is what actually stops it — no orphan is left to
#     wedge the VM.
#
# The image build is retried up to three times: with the Dockerfile's
# `# syntax=` directive gone, the only registry left in the build is the ubuntu
# base pull — but Docker Desktop prunes unreferenced base images, and a
# transient auth.docker.io failure (504s seen in the wild) used to fail every
# run before it started. The container run streams main.sh's output live
# instead of hiding it behind `run`'s spinner: a full run is many minutes and
# several GB, and silence behind a frozen spinner reads like a hang. The
# docker client's own status is taken from PIPESTATUS[0] — a failing `tee`
# (disk full) is reported separately, never as a test failure — and translated
# into a plain-language verdict: timeout, OOM-kill, or "the daemon died
# mid-run" (the Docker Desktop / WSL crash case).
#
# Environment:
#   RUNS            Number of times to run main.sh inside the container
#                   (default 1). RUNS=2 tests idempotency on an
#                   already-configured machine, not a clean install.
#   KEEP            Set to 1 to keep the container after the run (the EXIT
#                   trap then leaves it in place for inspection).
#   SETUP_DESKTOP   Forwarded to the container when set (e.g. `cinnamon`,
#                   `unknown`), to exercise a desktop other than the image
#                   default (`gnome`); unset keeps that default.
#   INSTALL_NVIDIA / INSTALL_XBOX
#                   Forwarded to the container, default 0. A container inherits
#                   the host's PCI/USB sysfs, so on a machine with an NVIDIA
#                   GPU or an Xbox dongle the sandbox would otherwise
#                   auto-confirm (SETUP_ASSUME_YES=1) and install real host
#                   hardware support inside a throwaway container. Set to 1 to
#                   deliberately exercise those paths.
#   BUILD_TIMEOUT   Seconds per build attempt (default 900, 0 disables).
#   RUN_TIMEOUT     Seconds for the container run (default 3600, 0 disables).
#   MIN_FREE_GB     Refuse to start when the Docker VM has less free disk than
#                   this (default 15, 0 disables the probe).
#   TEST_MEMORY     Optional `docker run --memory` cap (e.g. 8g), so a runaway
#                   workload dies as a clean container OOM instead of taking
#                   the Docker Desktop / WSL VM down with it.
#
# This only orchestrates Docker; it runs no part of the setup on the host.

set -euo pipefail
IFS=$'\n\t'

__repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$__repo_root/lib/log.sh"

readonly DEFAULT_RELEASES=(26.04)
readonly IMAGE_PREFIX='linux-utils-test'

# Bounded by default so a wedged registry or a dead daemon can never hang the
# script; 0 disables a limit. Validated as non-negative integers in main.
BUILD_TIMEOUT="${BUILD_TIMEOUT:-900}"
RUN_TIMEOUT="${RUN_TIMEOUT:-3600}"
MIN_FREE_GB="${MIN_FREE_GB:-15}"

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
  INSTALL_NVIDIA    Forwarded into the container (default 0: a container must
  INSTALL_XBOX      not install host hardware drivers; set 1 to exercise them).
  BUILD_TIMEOUT     Seconds per build attempt (default 900, 0 disables).
  RUN_TIMEOUT       Seconds for the container run (default 3600, 0 disables).
  MIN_FREE_GB       Minimum free disk inside the Docker VM (default 15, 0 disables).
  TEST_MEMORY       docker run --memory cap, e.g. 8g (unset = no cap).

Notes:
  The image build retries up to 3 times on transient registry failures, and the
  container run streams main.sh's output live. A full run takes many minutes
  and downloads several GB. On failure the script reports the container's real
  state (OOM-kill, timeout, or a dead Docker daemon) and cleans up after
  itself; a wedged Docker Desktop can be recovered with `wsl --shutdown`.

Options:
  -h, --help  Show this message.
EOF
}

require_docker() {
    command -v docker >/dev/null 2>&1 || {
        error 'docker not found — this test needs a working Docker daemon'
        return 1
    }

    # Bounded: a wedged Docker Desktop answers a killed socket call by hanging,
    # and an unbounded `docker info` is exactly how this script used to freeze
    # forever with no output at all.
    local rc=0
    timeout 30 docker info >/dev/null 2>&1 || rc=$?
    case "$rc" in
        0)  return 0 ;;
        124)
            error 'docker daemon did not answer within 30s — Docker Desktop looks wedged'
            warn 'Recover with: wsl --shutdown   (then start Docker Desktop and retry)'
            return 1
            ;;
        *)
            error 'docker is present but the daemon is not reachable'
            warn 'Try: wsl --shutdown, then start Docker Desktop and retry'
            return 1
            ;;
    esac
}

# with_timeout seconds cmd ... — run cmd under `timeout` when a limit is set
# (0 means no limit). --kill-after gives a stalled command 10s past the TERM
# before SIGKILL, so nothing outlives the timeout. timeout(1) reports 124 on
# expiry, 137 when the KILL escalation was needed.
with_timeout() {
    local secs="$1"
    shift
    if (( secs > 0 )); then
        timeout --kill-after=10 "$secs" "$@"
    else
        "$@"
    fi
}

# ── Cleanup ──────────────────────────────────────────────────────────────────
# One trap owns every scrap of state a run creates: the repository snapshot and
# the named container. The rm calls are best-effort (`|| true`, stderr
# discarded): under `set -e` a failing EXIT trap REPLACES the run's own exit
# status with its own — a passing test would report as failed with rm's code.
# INT/TERM exit THROUGH the EXIT trap, because bash does not run EXIT traps
# when it is killed by an untrapped fatal signal (a bare Ctrl-C).
__snapshot_dir=''
__container_name=''

_cleanup_all() {
    if [[ -n "$__container_name" && "${KEEP:-0}" != "1" ]]; then
        timeout 30 docker rm -f "$__container_name" >/dev/null 2>&1 || true
    fi
    if [[ -n "$__snapshot_dir" && -d "$__snapshot_dir" ]]; then
        rm -rf "$__snapshot_dir" 2>/dev/null || true
    fi
    return 0
}
trap _cleanup_all EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# snapshot_repo — copy the working tree to a fresh temp directory and print it.
# A run mounts a frozen copy of the working tree, not the live one: a live
# bind-mount is read-only to the container, but the host can still rewrite it
# mid-run — and bash executing a script edited under it reads garbage (a
# half-written comment line becomes a command). The snapshot removes that race.
snapshot_repo() {
    local dir
    dir="$(mktemp -d "${TMPDIR:-/tmp}/linux-utils-test.XXXXXX")" || return 1
    tar -C "$__repo_root" \
        --exclude=.git --exclude=build --exclude=dist --exclude='*.log' \
        -cf - . | tar -C "$dir" -xf - \
        || { rm -rf "$dir"; return 1; }
    printf '%s' "$dir"
}

# check_disk_space image — refuse to start a run the Docker VM cannot hold.
# The probe is the built image itself (`df /` inside the VM), not the host:
# the container's several GB land in the VM's disk, and a VM that fills up
# wedges Docker Desktop and takes WSL with it. MIN_FREE_GB=0 skips the probe;
# an unreadable probe only warns — the run itself gets the final say.
check_disk_space() {
    local image="$1" avail_kb='' avail_gb
    (( MIN_FREE_GB > 0 )) || return 0

    avail_kb="$(with_timeout 60 docker run --rm --entrypoint df "$image" -k / \
        2>/dev/null | awk 'NR == 2 { print $4 }')" || avail_kb=''
    if [[ ! "$avail_kb" =~ ^[0-9]+$ ]]; then
        warn 'Could not probe free disk space inside the Docker VM — continuing'
        return 0
    fi

    avail_gb=$(( avail_kb / 1024 / 1024 ))
    if (( avail_gb < MIN_FREE_GB )); then
        error "Only ${avail_gb}G free inside the Docker VM — a run needs ${MIN_FREE_GB}G"
        warn 'Free space (see `docker system df`, `docker builder prune`) or re-run with MIN_FREE_GB=0'
        return 1
    fi
    step "Docker VM free space: ${avail_gb}G (minimum ${MIN_FREE_GB}G)"
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
        if run "Building $image (attempt $attempt/3)" \
            with_timeout "$BUILD_TIMEOUT" docker build \
            --build-arg "UBUNTU_VERSION=$release" \
            -t "$image" "$__repo_root"; then
            return 0
        else
            rc=$?
        fi
        if (( rc == 124 )); then
            warn "Build attempt $attempt/3 timed out after ${BUILD_TIMEOUT}s"
        fi
        if (( attempt < 3 )); then
            warn "Build attempt $attempt/3 failed (exit $rc) — retrying in ${backoff[attempt-1]}s"
            sleep "${backoff[attempt-1]}"
        fi
    done

    error "Could not build $image after 3 attempts (exit $rc)"
    return "$rc"
}

# report_run_failure name release rc — the verdict for a failed container run,
# taken from the container's own recorded state rather than the docker
# client's exit code. The three cases that used to be indistinguishable
# garbage exits:
#   * the daemon died mid-run (Docker Desktop / WSL crashed): inspecting the
#     container fails and `docker info` no longer answers;
#   * the container was OOM-killed: .State.OOMKilled is true;
#   * a real main.sh failure: .State.ExitCode is main.sh's own status.
report_run_failure() {
    local name="$1" release="$2" rc="$3"
    local state='' status='' oom='' exitcode=''

    # Ctrl-C: an abort, not a failure — say so before anything else.
    if (( rc == 130 )); then
        warn "Interrupted — ubuntu:$release run aborted by user"
        return 0
    fi

    if ! timeout 15 docker info >/dev/null 2>&1; then
        error "FAILED: ubuntu:$release (docker exit $rc) — the Docker daemon died during the run"
        warn 'Docker Desktop / WSL most likely crashed. Recover with: wsl --shutdown,'
        warn 'then start Docker Desktop and re-run.'
        return 0
    fi

    state="$(timeout 15 docker inspect \
        -f '{{.State.Status}} {{.State.OOMKilled}}' "$name" 2>/dev/null)" || state=''
    status="${state%% *}"
    oom="${state##* }"

    if [[ "$oom" == 'true' ]]; then
        error "FAILED: ubuntu:$release — the container was OOM-killed"
        warn 'The Docker VM ran out of memory. Raise its memory limit in Docker Desktop,'
        warn 'or set TEST_MEMORY (e.g. TEST_MEMORY=8g) so the test dies cleanly instead.'
        return 0
    fi

    if [[ -n "$status" ]]; then
        exitcode="$(timeout 15 docker inspect -f '{{.State.ExitCode}}' \
            "$name" 2>/dev/null || printf '?')"
        case "$rc" in
            124) error "FAILED: ubuntu:$release — stopped after RUN_TIMEOUT=${RUN_TIMEOUT}s (main.sh exit $exitcode)" ;;
            *)   error "FAILED: ubuntu:$release (main.sh exit $exitcode, docker exit $rc)" ;;
        esac
        return 0
    fi

    case "$rc" in
        124) error "FAILED: ubuntu:$release — stopped after RUN_TIMEOUT=${RUN_TIMEOUT}s" ;;
        125) error "FAILED: ubuntu:$release — docker could not run the container (exit 125)" ;;
        126) error "FAILED: ubuntu:$release — container command could not be executed (exit 126)" ;;
        127) error "FAILED: ubuntu:$release — container command not found (exit 127)" ;;
        137) error "FAILED: ubuntu:$release — killed (exit 137): out of memory or an external kill" ;;
        143) error "FAILED: ubuntu:$release — terminated (SIGTERM, exit 143)" ;;
        *)   error "FAILED: ubuntu:$release (docker exit $rc)" ;;
    esac
}

# run_release release runs — build the image, probe the VM's disk, then run it
# `runs` times in one named container. The container is deliberately NOT --rm:
# it is removed by the EXIT trap (unless KEEP=1), so a failure can still be
# inspected with `docker inspect` and a timed-out run can be force-stopped —
# a --rm container that outlives its killed client is exactly the orphan that
# wedges the VM.
run_release() {
    local release="$1" runs="$2"
    local image="$IMAGE_PREFIX:$release"
    local -a run_flags=() env_flags=()
    local -a pipe_status=()
    local docker_rc=0 tee_rc=0

    section "Testing on ubuntu:$release"

    __container_name="$IMAGE_PREFIX-$release"
    run_flags=( --name "$__container_name" --init )

    if [[ -n "${TEST_MEMORY:-}" ]]; then
        run_flags+=( --memory "$TEST_MEMORY" )
        step "Memory cap: $TEST_MEMORY"
    fi

    env_flags=( -e "RUNS=$runs" )

    # Hardware-gated steps are pinned off unless explicitly overridden: a
    # container inherits the host's PCI/USB sysfs, so on a machine with an
    # NVIDIA GPU or an Xbox dongle the sandbox would otherwise auto-confirm
    # (SETUP_ASSUME_YES=1) and install real host hardware support — gigabytes
    # and kernel modules — inside a throwaway container.
    env_flags+=( -e "INSTALL_NVIDIA=${INSTALL_NVIDIA:-0}" )
    env_flags+=( -e "INSTALL_XBOX=${INSTALL_XBOX:-0}" )

    # Forwarded only when set: unset keeps the image default (gnome), which is
    # what covers the desktop package set; an explicit value exercises another
    # path — a real desktop id, or `unknown` for the desktop-neutral set.
    if [[ -n "${SETUP_DESKTOP:-}" ]]; then
        env_flags+=( -e "SETUP_DESKTOP=$SETUP_DESKTOP" )
    fi

    # A leftover from a crashed run or a previous KEEP=1 run would collide
    # with --name; it belongs to this script and is disposable by construction.
    if timeout 15 docker inspect "$__container_name" >/dev/null 2>&1; then
        step "Removing leftover container from a previous run: $__container_name"
        with_timeout 30 docker rm -f "$__container_name" >/dev/null 2>&1 || true
    fi

    build_image "$image" "$release"

    check_disk_space "$image" || return 1

    # Live output instead of `run`'s spinner: this step IS the test — many
    # minutes inside the container — and `run` would swallow every step label
    # behind one frozen spinner, which reads like a hang. `tee` keeps the log
    # copy; with no TTY on the container's stdout, main.sh's own spinner stays
    # off and its step lines stream cleanly.
    #
    # The status handling is deliberate: `$?` after a pipefail pipeline is the
    # MERGED status, so a failing `tee` (disk full) used to read as a failed
    # run, and an OOM-killed container was indistinguishable from a daemon
    # error. PIPESTATUS[0] is the docker client's own status, PIPESTATUS[1]
    # is tee's — captured in ONE statement, because any command (even a plain
    # assignment) resets PIPESTATUS.
    step "Running main.sh on ubuntu:$release — live output follows"
    with_timeout "$RUN_TIMEOUT" docker run \
        ${run_flags[@]+"${run_flags[@]}"} \
        ${env_flags[@]+"${env_flags[@]}"} \
        -v "$__snapshot_dir:/work:ro" \
        "$image" \
        bash -c 'for (( i = 1; i <= RUNS; i++ )); do
                     echo "=== run $i/$RUNS ==="
                     bash ./main.sh || exit $?
                 done' \
        2>&1 | tee -a "$LOG_FILE" || pipe_status=( "${PIPESTATUS[@]}" )

    docker_rc="${pipe_status[0]:-0}"
    tee_rc="${pipe_status[1]:-0}"

    if (( tee_rc != 0 )); then
        warn "Could not append to the log file $LOG_FILE (tee exit $tee_rc) — disk full?"
    fi

    if (( docker_rc == 0 )); then
        success "ubuntu:$release passed"
        return 0
    fi

    report_run_failure "$__container_name" "$release" "$docker_rc"
    warn "Full log: $LOG_FILE"
    if [[ "${KEEP:-0}" == "1" ]]; then
        warn "Container kept for inspection: $__container_name (drop with: docker rm -f $__container_name)"
    fi
    return "$docker_rc"
}

main() {
    local -a releases=()
    local arg runs var

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

    for var in BUILD_TIMEOUT RUN_TIMEOUT MIN_FREE_GB; do
        [[ "${!var}" =~ ^[0-9]+$ ]] || {
            error "$var must be a non-negative integer, got: ${!var}"
            return 2
        }
    done

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
