#!/usr/bin/env bash
# Re-exec under bash when started as `sh script.sh`. dash (Debian's sh) has no
# [[ ]], no BASH_SOURCE, no ${var//pat/rep} and no arrays, so it dies on the
# first line of the real work instead of doing something useful.
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
# common.sh - shared paths, logging and access-point store I/O.
#
# Sourced by every script in this suite. It deliberately does NOT set -e or -u:
# source files must not change the caller's shell options. Callers set their own.
#
# Override the tree location with WARDRIVE_BASE if you install somewhere other
# than the default (the scripts otherwise derive it from their own path).

BASE_DIR="${WARDRIVE_BASE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

BIN_DIR="$BASE_DIR/bin"
DATA_DIR="$BASE_DIR/data"
LOGS_DIR="$BASE_DIR/logs"
CAPTURES_DIR="$BASE_DIR/captures"
CONFIG_DIR="$BASE_DIR/config"
STATE_DIR="$BASE_DIR/.state"

MAC_FILE="$DATA_DIR/mac.txt"          # human-readable store: mac > essid > psk
KEY_POOL="$DATA_DIR/keys.txt"         # every recovered key, deduplicated
BLACKLIST_FILE="$DATA_DIR/blacklist.txt"
BPF_FILE="$DATA_DIR/exclude.bpf"
SECRETS_FILE="$CONFIG_DIR/secrets.conf"
SITE_CONF="$CONFIG_DIR/wardrive.conf"

# Separator for in-memory "<essid><SEP><psk>" records. A unit separator cannot
# appear in an ESSID or a passphrase, so it is safe where '|' is not.
SEP=$'\x1f'

# Colour only when stdout is a terminal, so logs stay readable in files.
if [[ -t 1 ]]; then
    C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[1;33m'
    C_RED=$'\033[0;31m';   C_OFF=$'\033[0m'
else
    C_GREEN=''; C_YELLOW=''; C_RED=''; C_OFF=''
fi

log()  { printf '%s[+]%s %s\n' "$C_GREEN"  "$C_OFF" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_OFF" "$*" >&2; }
err()  { printf '%s[-]%s %s\n' "$C_RED"    "$C_OFF" "$*" >&2; }
die()  { err "$@"; exit 1; }

is_dry() { [[ "${DRY_RUN:-0}" == "1" ]]; }

check_deps() {
    local missing=() cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    (( ${#missing[@]} == 0 )) && return 0
    die "Missing dependencies: ${missing[*]}"
}

normalize_mac() { printf '%s' "$1" | tr -d ':-' | tr '[:upper:]' '[:lower:]'; }

# "At home" means there is an uplink we are not capturing on.
#
# Carrier on eth0 was the original signal, but a box whose uplink is a second
# radio (or USB ethernet) shows eth0 DOWN while it is sitting on the sofa -
# which was read as "mobile" and started a capture indoors. So: eth0 carrier
# first, then any default route that does not belong to the capture radio.
# Home or mobile is decided by the wired uplink alone: eth0 is the "I am home"
# switch. Cable in -> home (no capture, just the post steps). Cable out ->
# mobile (capture, then the post steps when it stops).
#
# Carrier is the signal, not `ip link` state and not the default route. A pulled
# cable still shows a state, and a DHCP default route can outlive the link it was
# handed out on, so either one reads "home" in a car park.
at_home() {
    local uplink="${UPLINK_IFACE:-eth0}"
    [[ -r "/sys/class/net/$uplink/carrier" ]] || return 1
    [[ "$(cat "/sys/class/net/$uplink/carrier" 2>/dev/null)" == "1" ]]
}

# hcxpcapngtool emits the ESSID hex-encoded. Decoded here in pure bash: the
# previous `sed | xargs printf` version handed the ESSID to printf as the format
# string, so any '%' in a network name corrupted or truncated the output. It
# also drops the xxd dependency, which is not installed everywhere this runs.
hex_to_string() {
    local hex out='' i
    hex=$(printf '%s' "$1" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    [[ -z "$hex" ]] && return 0
    (( ${#hex} % 2 )) && hex="${hex%?}"
    for (( i = 0; i < ${#hex}; i += 2 )); do
        out+="\\x${hex:i:2}"
    done
    printf '%b' "$out"
}

# Strip control bytes, then alignment padding and repeated spaces, so a record
# always fits on one line.
sanitize_essid() {
    local s
    s=$(printf '%s' "$1" | tr -d '\000-\037\177')
    s=$(printf '%s' "$s" | sed -e 's/[[:space:]]\{1,\}/ /g' -e 's/^ *//' -e 's/ *$//')
    [[ -z "$s" ]] && s='(hidden)'
    printf '%s' "$s"
}

# load_entries <assoc-array-name> [file]
# The ONE parser for mac.txt. extract_macs and sync_results both use it.
load_entries() {
    local -n _store=$1
    local file="${2:-$MAC_FILE}" line mac rest essid psk
    _store=()
    [[ -s "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        mac="${line:0:12}"
        [[ "$mac" =~ ^[0-9a-f]{12}$ ]] || continue
        rest="${line:12}"
        [[ "$rest" == "  >  "* ]] || continue
        rest="${rest:5}"
        if [[ "$rest" == *"  >  "* ]]; then
            essid="${rest%%  >  *}"
            psk="${rest#*  >  }"
        else
            essid="$rest"; psk=""
        fi
        _store["$mac"]="$(sanitize_essid "$essid")${SEP}${psk}"
    done < "$file"
}

# write_entries <assoc-array-name> [file]
# Sorted, aligned, and written through a temp file in the SAME directory so the
# final mv is an atomic rename. The old code moved from /tmp (tmpfs) to /root,
# which is a copy: a kill mid-write truncated the store.
write_entries() {
    local -n _store=$1
    local file="${2:-$MAC_FILE}"
    local dir; dir=$(dirname "$file")
    local tmp width=8 mac essid psk

    mkdir -p "$dir"
    tmp=$(mktemp "$dir/.mac.XXXXXX") || die "cannot write in $dir"

    for mac in "${!_store[@]}"; do
        IFS="$SEP" read -r essid psk <<< "${_store[$mac]}"
        printf '%s\t%s\t%s\n' "$mac" "$essid" "${psk:-}"
    done | sort -k1,1 > "$tmp"

    while IFS=$'\t' read -r _m essid _p; do
        (( ${#essid} > width )) && width=${#essid}
    done < "$tmp"

    {
        while IFS=$'\t' read -r mac essid psk; do
            if [[ -n "$psk" ]]; then
                printf '%-12s  >  %-*s  >  %s\n' "$mac" "$width" "$essid" "$psk"
            else
                printf '%-12s  >  %-*s\n' "$mac" "$width" "$essid"
            fi
        done < "$tmp"
    } > "$tmp.out"

    mv -f "$tmp.out" "$file"
    chmod 600 "$file" 2>/dev/null || true
    rm -f "$tmp"
}

# Non-secret settings. Safe to commit; the example file ships with the repo.
load_site_conf() {
    if [[ -f "$SITE_CONF" ]]; then
        # shellcheck disable=SC1090
        . "$SITE_CONF"
    fi
    : "${UPLOAD_URL:=}"
    : "${RESULTS_URL:=}"
    : "${MAX_EXCLUDE_MACS:=24}"
    : "${DELETE_AFTER_UPLOAD:=1}"
    : "${CURL_MAX_TIME:=300}"
}

# Secrets. Missing file is fatal; loose permissions are corrected, not ignored.
require_secrets() {
    [[ -f "$SECRETS_FILE" ]] || die "Secrets file missing at $SECRETS_FILE"
    if [[ "$(stat -c %a "$SECRETS_FILE")" != "600" ]]; then
        warn "$SECRETS_FILE is too permissive. Fixing to 600."
        chmod 600 "$SECRETS_FILE"
    fi
    # shellcheck disable=SC1090
    . "$SECRETS_FILE"
    [[ -n "${API_KEY:-}" ]] || die "API_KEY not set in $SECRETS_FILE"
}
