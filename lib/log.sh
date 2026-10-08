#!/usr/bin/env bash
# =============================================================================
# lib/log.sh — the run log and the command runner built on it
# =============================================================================
# Owns $LOG_FILE and `run`. It never calls `exit`: `run` returns the command's
# exit status and the entrypoint decides whether that ends the program.

# ── Guard against double sourcing ─────────────────────────────────────────────
[[ -n "${_LOG_SH_LOADED:-}" ]] && return
readonly _LOG_SH_LOADED=1

_log_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_log_lib_dir/ui.sh"

# ── Log file ──────────────────────────────────────────────────────────────────
# Every command run through `run` appends its raw output here. Override by
# exporting LOG_FILE before sourcing.
LOG_FILE="${LOG_FILE:-/tmp/setup-$(date +%Y%m%d-%H%M%S).log}"

# ── log_tail [lines] — the end of the log, indented for the terminal ──────────
log_tail() {
    local lines="${1:-20}"
    [[ -r "$LOG_FILE" ]] || return 0
    tail -n "$lines" "$LOG_FILE" | sed 's/^/    /'
}

# ── run: silent execution with a spinner ──────────────────────────────────────
# Usage: run "Label" cmd arg1 arg2 ...
# Output is appended to $LOG_FILE. On failure the tail of the log is printed and
# the command's exit status is returned — nothing is exited from here.
run() {
    if (( $# < 2 )); then
        error 'run: label and command required'
        return 2
    fi
    local label="$1"
    shift
    local exit_code=0

    spinner_start "$label"
    "$@" >> "$LOG_FILE" 2>&1 || exit_code=$?
    spinner_stop

    if (( exit_code != 0 )); then
        error "FAILED: $label (exit $exit_code)"
        warn "Last output (full log: $LOG_FILE)"
        log_tail 20
        return "$exit_code"
    fi

    info "$label"
}
