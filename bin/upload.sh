#!/usr/bin/env bash
# Re-exec under bash when started as `sh script.sh`. dash (Debian's sh) has no
# [[ ]], no BASH_SOURCE, no ${var//pat/rep} and no arrays, so it dies on the
# first line of the real work instead of doing something useful.
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
# upload.sh - ship each finished capture to the processing backend.
#
# The endpoint is NOT in this file. Set UPLOAD_URL in config/wardrive.conf.
# With no URL configured the step reports that and exits 0, so a checkout with
# no backend configured still runs the rest of the pipeline cleanly.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

load_site_conf
check_deps curl

if [[ -z "$UPLOAD_URL" ]]; then
    warn "UPLOAD_URL is not set in $SITE_CONF - nothing to upload."
    exit 0
fi

require_secrets

upload_one() {   # upload_one <url> <file> -> prints the last HTTP status
    local url="$1" file="$2" max=5 delay=2 code=000 i
    for (( i = 1; i <= max; i++ )); do
        code=$(curl -sS --max-time "$CURL_MAX_TIME" -o /dev/null -w '%{http_code}' \
                    -F "file=@$file" -b "key=$API_KEY" "$url") || code=000
        [[ "$code" == "200" ]] && { printf '%s' "$code"; return 0; }
        if (( i < max )); then
            warn "Attempt $i/$max returned HTTP $code; retrying in ${delay}s"
            sleep "$delay"
            delay=$(( delay * 2 ))
        fi
    done
    printf '%s' "$code"
    return 1
}

shopt -s nullglob
files=("$CAPTURES_DIR"/*/capture.pcapng)

if (( ${#files[@]} == 0 )); then
    log "No capture.pcapng files to upload."
    exit 0
fi

ok=0
failed=0

for f in "${files[@]}"; do
    session=$(basename "$(dirname "$f")")
    log "Uploading $session ..."

    if is_dry; then
        log "[dry-run] would POST $session to the configured endpoint"
        ok=$(( ok + 1 ))
        continue
    fi

    # `if code=$(...)` rather than `code=$(...)`: under set -e the plain
    # assignment aborted the script the moment the uploader returned non-zero,
    # which made the failure branch below unreachable and hid every error.
    if code=$(upload_one "$UPLOAD_URL" "$f"); then
        log "OK (HTTP $code)"
        ok=$(( ok + 1 ))
        if is_dry; then
            log "[dry-run] would remove $(dirname "$f")"
        elif [[ "$DELETE_AFTER_UPLOAD" == "1" ]]; then
            rm -rf "$(dirname "$f")"
            log "Removed $(dirname "$f")"
        fi
    else
        err "Upload failed for $session (last HTTP ${code:-000}); capture kept on disk"
        failed=$(( failed + 1 ))
    fi
done

if (( failed > 0 )); then
    err "$failed of $(( ok + failed )) capture(s) not uploaded."
    exit 1
fi

log "Upload complete: $ok capture(s)."
