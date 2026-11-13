#!/usr/bin/env bash
# extract_macs.sh - turn captures into access-point records.
#
# Default mode is incremental: only captures newer than the last successful pass
# are parsed, so a box that has been driving for a week does not re-hash its
# whole archive on every boot.
#
#   extract_macs.sh                 process new captures under captures/
#   extract_macs.sh file.pcapng     process one capture
#   extract_macs.sh file.22000      process one already-converted hash file
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

check_deps tr sed
mkdir -p "$DATA_DIR" "$STATE_DIR"

INPUT="${1:-}"
pcap_files=()
hash_files=()

if [[ -n "$INPUT" ]]; then
    [[ -f "$INPUT" ]] || die "No such file: $INPUT"
    case "$INPUT" in
        *.22000) hash_files=("$INPUT") ;;
        *.pcapng) pcap_files=("$INPUT") ;;
        *) die "Expected a .pcapng or .22000 file, got: $INPUT" ;;
    esac
    log "Single-file mode: $INPUT"
else
    STAMP="$STATE_DIR/last_extract"
    # -mmin +1 skips a capture that is still being written: parsing a live file
    # yields half a session and the watermark would then hide it from later runs.
    mapfile -t pcap_files < <(
        if [[ -f "$STAMP" ]]; then
            find "$CAPTURES_DIR" -type f -name '*.pcapng' -mmin +1 -newer "$STAMP" 2>/dev/null
        else
            find "$CAPTURES_DIR" -type f -name '*.pcapng' -mmin +1 2>/dev/null
        fi || true
    )
fi

if (( ${#pcap_files[@]} == 0 && ${#hash_files[@]} == 0 )); then
    warn "No unprocessed captures."
    exit 0
fi

WORK=$(mktemp -d -t wardrive_extract_XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# Convert every capture to the hash format first, then parse in one pass.
sources=()
if (( ${#pcap_files[@]} > 0 )); then
    check_deps hcxpcapngtool
fi
for pcap in "${pcap_files[@]}"; do
    name=$(basename "$(dirname "$pcap")")
    out="$WORK/${name}-$(basename "${pcap%.pcapng}").22000"
    if ! hcxpcapngtool -o "$out" "$pcap" >/dev/null 2>&1; then
        warn "Could not parse $pcap"
        continue
    fi
    [[ -s "$out" ]] || { log "$name: no hashes"; continue; }
    sources+=("$out")
done
sources+=("${hash_files[@]}")

if (( ${#sources[@]} == 0 )); then
    warn "Nothing to extract."
    exit 0
fi

declare -A aps
load_entries aps
log "Loaded ${#aps[@]} known access points"

new_aps=0
total_hashes=0

for hashes in "${sources[@]}"; do
    label=$(basename "$hashes")
    added=0
    while IFS='*' read -r prefix _type _mic ap_mac _client hex_essid _rest || [[ -n "${prefix:-}" ]]; do
        [[ "${prefix:-}" == "WPA" ]] || continue
        [[ -n "${ap_mac:-}" && -n "${hex_essid:-}" ]] || continue

        mac=$(normalize_mac "$ap_mac")
        [[ "$mac" =~ ^[0-9a-f]{12}$ ]] || continue

        if [[ -z "${aps[$mac]+x}" ]]; then
            essid=$(sanitize_essid "$(hex_to_string "$hex_essid")")
            aps["$mac"]="${essid}${SEP}"
            added=$(( added + 1 ))
            new_aps=$(( new_aps + 1 ))
        fi
    done < "$hashes"

    count=$(wc -l < "$hashes")
    total_hashes=$(( total_hashes + count ))
    log "$label: $count hashes, $added new APs"
done

if (( new_aps > 0 )); then
    write_entries aps
    log "mac.txt updated: +$new_aps access points (now ${#aps[@]})."
else
    log "No new access points."
fi

if [[ -n "${STAMP:-}" && ${#pcap_files[@]} -gt 0 ]]; then
    # Advance the watermark to the newest capture actually parsed.
    newest=$(ls -1t "${pcap_files[@]}" 2>/dev/null | head -1 || true)
    [[ -z "${newest:-}" ]] || touch -r "$newest" "$STAMP"
fi

log "Extract complete: $total_hashes hashes across ${#sources[@]} file(s)."
