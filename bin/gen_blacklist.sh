#!/usr/bin/env bash
# Re-exec under bash when started as `sh script.sh`. dash (Debian's sh) has no
# [[ ]], no BASH_SOURCE, no ${var//pat/rep} and no arrays, so it dies on the
# first line of the real work instead of doing something useful.
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
# gen_blacklist.sh - compile the exclusion list into a BPF filter.
#
# Every excluded address costs three clauses. The compiled filter has a hard
# size limit, so the list is capped: past the cap the filter is emitted for the
# first N entries and a warning says so. Silently producing a filter that the
# kernel rejects would mean capturing nothing at all.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

load_site_conf
check_deps hcxdumptool

mkdir -p "$DATA_DIR"

if [[ ! -f "$BLACKLIST_FILE" ]]; then
    warn "No $BLACKLIST_FILE; leaving $BPF_FILE alone."
    exit 0
fi

mapfile -t macs < <(
    grep -vE '^[[:space:]]*(#|$)' "$BLACKLIST_FILE" \
        | tr -d ':-' \
        | tr '[:upper:]' '[:lower:]' \
        | grep -E '^[0-9a-f]{12}$' || true
)

if (( ${#macs[@]} == 0 )); then
    warn "No valid MACs in $BLACKLIST_FILE; $BPF_FILE unchanged."
    exit 0
fi

if (( ${#macs[@]} > MAX_EXCLUDE_MACS )); then
    warn "${#macs[@]} addresses exceeds MAX_EXCLUDE_MACS=$MAX_EXCLUDE_MACS; using the first $MAX_EXCLUDE_MACS."
    macs=("${macs[@]:0:MAX_EXCLUDE_MACS}")
fi

expr=""
for mac in "${macs[@]}"; do
    clause="not wlan addr1 $mac and not wlan addr2 $mac and not wlan addr3 $mac"
    expr="${expr:+$expr and }$clause"
done

TMP=$(mktemp "$DATA_DIR/.bpf.XXXXXX")
if ! hcxdumptool --bpfc "$expr" > "$TMP"; then
    rm -f "$TMP"
    die "hcxdumptool refused the filter expression."
fi

mv -f "$TMP" "$BPF_FILE"
log "$BPF_FILE written with ${#macs[@]} excluded address(es)."
