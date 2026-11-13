#!/usr/bin/env bash
# install.sh - lay the suite out and drop the systemd unit.
#
#   sudo ./install.sh                -> /opt/wardrive
#   sudo ./install.sh /srv/wardrive  -> anywhere else
#
# Idempotent: re-running upgrades the scripts and leaves data, config and
# secrets alone.
set -euo pipefail

PREFIX="${1:-/opt/wardrive}"
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

if [[ $EUID -ne 0 ]]; then
    echo "install.sh must run as root (monitor mode and systemd)." >&2
    exit 1
fi

echo "[+] installing to $PREFIX"
install -d -m 755 "$PREFIX"
install -d -m 755 "$PREFIX"/{bin,captures,logs,config,tests}
install -d -m 700 "$PREFIX"/{data,.state}

install -m 755 "$SRC"/bin/*.sh "$PREFIX/bin/"
install -m 644 "$SRC"/bin/common.sh "$PREFIX/bin/common.sh"
install -m 755 "$SRC"/tests/smoke.sh "$PREFIX/tests/smoke.sh"

if [[ ! -f "$PREFIX/config/wardrive.conf" ]]; then
    install -m 644 "$SRC/config/wardrive.conf.example" "$PREFIX/config/wardrive.conf"
    echo "[+] wrote $PREFIX/config/wardrive.conf - set the two endpoints"
fi

if [[ ! -f "$PREFIX/config/secrets.conf" ]]; then
    install -m 600 "$SRC/config/secrets.conf.example" "$PREFIX/config/secrets.conf"
    echo "[+] wrote $PREFIX/config/secrets.conf - set API_KEY"
fi

UNIT=/etc/systemd/system/wardrive-pipeline.service
sed "s#/opt/wardrive#$PREFIX#g" "$SRC/systemd/wardrive-pipeline.service" > "$UNIT"
chmod 644 "$UNIT"

# A default route left behind on a dead link (eth0 unplugged, DHCP did not
# release it) outranks the working wlan1 route and kills all egress.
PRUNE=/usr/local/sbin/route-prune.sh
install -m 755 "$SRC/systemd/route-prune.sh" "$PRUNE"
install -m 644 "$SRC/systemd/route-prune.service" /etc/systemd/system/
install -m 644 "$SRC/systemd/route-prune.timer" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now route-prune.timer
echo "[+] route-prune timer installed"
echo "[+] unit installed: $UNIT"

cat <<EOF

Next:
  1. $PREFIX/config/wardrive.conf   endpoints (empty = step disabled)
  2. $PREFIX/config/secrets.conf    API_KEY, keep mode 600
  3. $PREFIX/bin/gen_blacklist.sh   compile exclusions (optional)
  4. $PREFIX/tests/smoke.sh         offline checks

Enable at boot:
  systemctl enable --now wardrive-pipeline.service
EOF
