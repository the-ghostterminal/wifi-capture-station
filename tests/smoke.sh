#!/usr/bin/env bash
# smoke.sh - offline checks for the parts that can be wrong silently:
# the store round-trip, ESSID decoding, the extraction parser and the BPF cap.
#
# Runs against a throwaway tree, never against live data.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d -t wardrive_smoke_XXXXXX)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok()   { printf '  ok   %s\n' "$1"; pass=$(( pass + 1 )); }
bad()  { printf '  FAIL %s\n' "$1"; fail=$(( fail + 1 )); }
expect() { [[ "$2" == "$3" ]] && ok "$1" || bad "$1 (expected [$3], got [$2])"; }

mkdir -p "$TMP"/{bin,data,captures,config,.state}
cp "$REPO/bin/common.sh" "$TMP/bin/"
export WARDRIVE_BASE="$TMP"

. "$REPO/bin/common.sh"

echo "store round-trip"
cat > "$MAC_FILE" <<'FIXTURE'
001122334455  >  HomeNet                        >  correct horse battery
aabbccddeeff  >  Cafe%20Guest                  >  hunter2
112233445566  >  NoKeyNetwork
FIXTURE
declare -A a1
load_entries a1
expect "three records loaded" "${#a1[@]}" "3"
expect "key preserved"        "${a1[001122334455]#*"$SEP"}" "correct horse battery"
expect "missing key is empty" "${a1[112233445566]#*"$SEP"}" ""
write_entries a1
declare -A a2
load_entries a2
expect "round-trip count"     "${#a2[@]}" "3"
expect "round-trip value"     "${a2[aabbccddeeff]#*"$SEP"}" "hunter2"

echo "essid decoding"
expect "hex decodes"          "$(hex_to_string 4d7957694669)" "MyWiFi"
expect "percent survives"     "$(hex_to_string 43414645253230)" "CAFE%20"
expect "empty input is safe"  "$(hex_to_string '')" ""

echo "essid sanitising"
expect "padding trimmed"      "$(sanitize_essid '  Net   With  Spaces   ')" "Net With Spaces"
expect "hidden fallback"      "$(sanitize_essid '   ')" "(hidden)"

echo "hash parsing"
: > "$MAC_FILE"   # fresh store: existing APs are deliberately never overwritten
cat > "$TMP/one.22000" <<'FIXTURE'
WPA*02*1e2d*001122334455*66778899aabb*4d7957694669*00
WPA*02*1e2d*aabbccddeeff*66778899aabb*43414645253230*00
WPA*01*deadbeef*112233445566*000000000000*4e6f4b6579*00
garbage line that must be ignored
FIXTURE
"$REPO/bin/extract_macs.sh" "$TMP/one.22000" >/dev/null 2>&1
declare -A a3
load_entries a3
expect "three APs from hashes" "${#a3[@]}" "3"
expect "percent essid stored"  "${a3[aabbccddeeff]%%"$SEP"*}" "CAFE%20"
expect "duplicate ignored"     "$(grep -c '^001122334455' "$MAC_FILE")" "1"

echo "blacklist cap"
printf 'aa:bb:cc:dd:ee:ff\n11:22:33:44:55:66\n' > "$BLACKLIST_FILE"
if command -v hcxdumptool >/dev/null 2>&1; then
    "$REPO/bin/gen_blacklist.sh" >/dev/null 2>&1 \
        && ok "bpf generated" || bad "bpf generation failed"
else
    printf '  skip (hcxdumptool not installed)\n'
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
