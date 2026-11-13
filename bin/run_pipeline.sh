#!/usr/bin/env bash
# Re-exec under bash when started as `sh script.sh`. dash (Debian's sh) has no
# [[ ]], no BASH_SOURCE, no ${var//pat/rep} and no arrays, so it dies on the
# first line of the real work instead of doing something useful.
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
# run_pipeline.sh - single entry point, run at boot.
#
#   eth0 up   -> at home      : skip capture, run the post-capture steps
#   eth0 down -> mobile       : capture until SIGTERM, then run the post steps
#
# There is one entry point on purpose. Running capture.sh directly from a second
# systemd unit as well means two processes fighting over the same interface,
# monitor mode applied twice, and a capture nobody collects.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

mkdir -p "$LOGS_DIR" "$STATE_DIR" "$CAPTURES_DIR"

# One run at a time. A boot-time start that overlaps a manual run is a
# guaranteed interface conflict, so the second one leaves quietly.
exec 9>"$STATE_DIR/pipeline.lock"
if ! flock -n 9; then
    warn "Another pipeline run holds $STATE_DIR/pipeline.lock; exiting."
    exit 0
fi

log "=== pipeline start $(date -Is) ==="

IFACE="${1:-wlan0}"

run_post() {
    local step
    for step in extract_macs upload sync_results; do
        if [[ -x "$BIN_DIR/$step.sh" ]]; then
            log "-> $step"
            "$BIN_DIR/$step.sh" || warn "$step.sh exited with $?"
        else
            warn "$step.sh missing or not executable; skipped"
        fi
    done
}

if at_home "$IFACE"; then
    log "AT HOME (uplink present): capture skipped."
    run_post
    log "=== pipeline complete (home) ==="
    exit 0
fi

log "MOBILE (no uplink): capturing until SIGTERM."

"$BIN_DIR/capture.sh" "$IFACE" &
cap_pid=$!

stopped=0
trap 'stopped=1; kill -TERM "$cap_pid" 2>/dev/null' INT TERM

rc=0
wait "$cap_pid" || rc=$?

if (( stopped )); then
    log "Capture stopped by operator."
fi

# Post-capture steps run whenever a capture finished - whether it was
# interrupted or exited on its own. Previously a clean exit skipped them and
# left the capture sitting on the card until the next boot.
run_post

if (( rc != 0 && ! stopped )); then
    err "capture.sh exited with $rc"
    exit "$rc"
fi

log "=== pipeline complete (mobile) ==="
exit 0
