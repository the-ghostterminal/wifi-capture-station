#!/usr/bin/env bash
# Re-exec under bash when started as `sh script.sh`. dash (Debian's sh) has no
# [[ ]], no BASH_SOURCE, no ${var//pat/rep} and no arrays, so it dies on the
# first line of the real work instead of doing something useful.
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
# sync_results.sh - pull the backend's results file and fold the recovered keys
# back into the access-point store.
#
# The endpoint is NOT in this file. Set RESULTS_URL in config/wardrive.conf.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

load_site_conf
check_deps curl sort

if [[ -z "$RESULTS_URL" ]]; then
    warn "RESULTS_URL is not set in $SITE_CONF - nothing to sync."
    exit 0
fi

require_secrets

mkdir -p "$DATA_DIR" "$STATE_DIR"
# Temp file lives next to the destination on purpose: same filesystem means the
# final mv is a rename. Downloading to /tmp (tmpfs) made it a copy, so a kill
# mid-write truncated the key pool.
RAW=$(mktemp "$DATA_DIR/.results.XXXXXX")
trap 'rm -f "$RAW"' EXIT

if is_dry; then
    log "[dry-run] would download the results file from the configured endpoint"
    exit 0
fi

log "Downloading results file ..."
download_ok=0
for i in 1 2 3 4 5; do
    # -4 first: this host's resolver sometimes answers AAAA only, and the Pi has
    # no IPv6 route, so the connect fails before a byte moves. Plain curl stays
    # as the fallback for a v6-only network.
    if curl -4 -fsS --max-time "$CURL_MAX_TIME" -b "key=$API_KEY" "$RESULTS_URL" -o "$RAW" \
        || curl -fsS --max-time "$CURL_MAX_TIME" -b "key=$API_KEY" "$RESULTS_URL" -o "$RAW"; then
        download_ok=1
        break
    fi
    if (( i < 5 )); then
        warn "Download attempt $i/5 failed; retrying in $(( i * 2 ))s"
        sleep $(( i * 2 ))
    fi
done

if (( download_ok == 0 )); then
    err "Download failed after 5 attempts."
    exit 1
fi

if [[ ! -s "$RAW" ]]; then
    warn "Results file is empty."
    exit 0
fi

# Backend format: bssid:station:essid:key
declare -A r_essid r_key
while IFS=: read -r bssid _station essid key || [[ -n "${bssid:-}" ]]; do
    [[ -n "${bssid:-}" && -n "${key:-}" ]] || continue
    mac=$(normalize_mac "$bssid")
    [[ "$mac" =~ ^[0-9a-f]{12}$ ]] || continue
    r_essid["$mac"]="$essid"
    r_key["$mac"]="$key"
done < "$RAW"

log "Results file holds ${#r_key[@]} recovered keys"

declare -A aps
load_entries aps

updated=0
added=0

for mac in "${!r_key[@]}"; do
    new_key="${r_key[$mac]}"
    new_essid="${r_essid[$mac]:-}"

    if [[ -n "${aps[$mac]+x}" ]]; then
        IFS="$SEP" read -r old_essid old_key <<< "${aps[$mac]}"
        changed=0
        if [[ -z "$old_key" || "$old_key" != "$new_key" ]]; then
            old_key="$new_key"
            changed=1
        fi
        if [[ -n "$new_essid" && "$new_essid" != "$old_essid" ]]; then
            old_essid=$(sanitize_essid "$new_essid")
            changed=1
        fi
        if (( changed )); then
            aps["$mac"]="${old_essid}${SEP}${old_key}"
            updated=$(( updated + 1 ))
        fi
    else
        aps["$mac"]="$(sanitize_essid "${new_essid:-(unknown)}")${SEP}${new_key}"
        added=$(( added + 1 ))
    fi
done

if (( updated == 0 && added == 0 )); then
    log "No changes from the results file."
    exit 0
fi

write_entries aps
log "mac.txt updated: $updated changed, $added added."

# Key pool: every recovered key, deduplicated, written atomically.
POOL=$(mktemp "$DATA_DIR/.keys.XXXXXX")
trap 'rm -f "$RAW" "$POOL"' EXIT
{
    [[ -s "$KEY_POOL" ]] && cat "$KEY_POOL"
    for mac in "${!r_key[@]}"; do printf '%s\n' "${r_key[$mac]}"; done
} | sort -u > "$POOL"
mv -f "$POOL" "$KEY_POOL"
chmod 600 "$KEY_POOL" 2>/dev/null || true

log "Key pool now holds $(wc -l < "$KEY_POOL") unique keys."
log "Sync complete."
