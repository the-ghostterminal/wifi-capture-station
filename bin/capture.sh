#!/usr/bin/env bash
# Re-exec under bash when started as `sh script.sh`. dash (Debian's sh) has no
# [[ ]], no BASH_SOURCE, no ${var//pat/rep} and no arrays, so it dies on the
# first line of the real work instead of doing something useful.
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
# capture.sh - put the radio in monitor mode and hand it to hcxdumptool.
#
# Everything that can abort cheaply runs before the interface is touched:
# mode decision, dependency check, power check. A capture that dies halfway
# leaves a truncated pcapng and a radio stuck in monitor mode.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

INTERFACE="${1:-wlan0}"
SESSION_DIR="$CAPTURES_DIR/session_$(date +%Y%m%d_%H%M%S)"
DUMP_PID=

log "=== wardrive session start ==="

# Dependency and mode checks first: "at home" must exit 0 even on a box where
# hcxdumptool is not installed, so nothing else is required until we know a
# capture is really going to run.
check_deps ip

if at_home "$INTERFACE"; then
    log "Uplink present -> at home. Skipping capture."
    exit 0
fi

ip link show "$INTERFACE" >/dev/null 2>&1 ||
    die "Wireless adapter $INTERFACE not present. Aborting."

check_deps hcxdumptool iw
log "Preflight OK: no uplink, $INTERFACE present."

# ---------------------------------------------------------------------------
# Power. A brownout during capture corrupts the pcapng and can take the card
# with it, so an undervoltage flag is a hard stop. vcgencmd is authoritative on
# a Pi; the hwmon loop stays as a fallback for other boards.
# ---------------------------------------------------------------------------
check_power() {
    local t mv vfile v
    if command -v vcgencmd >/dev/null 2>&1; then
        t=$(vcgencmd get_throttled 2>/dev/null | sed -n 's/.*throttled=0x//p')
        if [[ -n "$t" ]] && (( 16#$t & 1 )); then
            err "Under-voltage right now (throttled=0x$t). Aborting capture."
            return 1
        fi
        log "Power OK (throttled=0x${t:-0})"
        return 0
    fi
    for vfile in /sys/class/hwmon/hwmon*/in0_input; do
        [[ -r "$vfile" ]] || continue
        v=$(<"$vfile") || continue
        mv=$(( v / 1000 ))
        if (( mv < 4650 )); then
            err "Under-voltage detected (${mv}mV < 4650mV). Aborting capture."
            return 1
        fi
        log "Power OK: ${mv}mV"
        return 0
    done
    warn "No voltage sensor found; skipping power check."
    return 0
}

setup_monitor() {
    log "Setting monitor mode on $INTERFACE..."
    ip link set "$INTERFACE" down
    iw dev "$INTERFACE" set type monitor
    ip link set "$INTERFACE" up
    local mode
    mode=$(iw dev "$INTERFACE" info | awk '/type/{print $2}')
    [[ "$mode" == "monitor" ]] || die "Failed to set monitor mode (got: ${mode:-none})"
    log "Monitor mode engaged."
}

# Runs on exit, SIGINT and SIGTERM. The dump process is killed first: bash
# defers a trap until the foreground command returns, so with hcxdumptool in the
# foreground a SIGTERM did nothing until the capture ended by itself.
cleanup() {
    local rc=$?
    trap - EXIT INT TERM
    if [[ -n "$DUMP_PID" ]] && kill -0 "$DUMP_PID" 2>/dev/null; then
        log "Stopping capture (pid $DUMP_PID)..."
        kill -TERM "$DUMP_PID" 2>/dev/null || true
        wait "$DUMP_PID" 2>/dev/null || true
    fi
    log "Cleaning up..."
    sync
    ip link set "$INTERFACE" down 2>/dev/null || true
    iw dev "$INTERFACE" set type managed 2>/dev/null || true
    ip link set "$INTERFACE" up 2>/dev/null || true
    log "Interface restored."
    exit "$rc"
}
trap cleanup EXIT INT TERM

check_power || exit 1
setup_monitor

bpf_args=()
if [[ -s "$BPF_FILE" ]]; then
    bpf_args+=("--bpf=$BPF_FILE")
    log "BPF exclusion filter loaded."
else
    warn "No BPF exclusion filter; capturing everything."
fi

mkdir -p "$SESSION_DIR"
printf 'started=%s\ninterface=%s\n' "$(date -Is)" "$INTERFACE" > "$SESSION_DIR/meta.txt"
log "Session: $SESSION_DIR"

hcxdumptool -i "$INTERFACE" "${bpf_args[@]}" -w "$SESSION_DIR/capture.pcapng" &
DUMP_PID=$!
log "Capture running (pid $DUMP_PID)."

rc=0
wait "$DUMP_PID" || rc=$?
DUMP_PID=
log "Capture exited with $rc."
exit "$rc"
