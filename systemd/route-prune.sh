#!/bin/bash
# Remove default routes that sit on a link with no carrier.
#
# eth0 is allow-hotplug/dhcp. When the cable is pulled the DHCP client does not
# always take its default route with it, so the kernel keeps a route via a dead
# link at metric 100. That route wins over the working wlan1 route (metric 200)
# and every outbound connection dies with "Could not connect", while the box
# still answers on the LAN. Nothing recovers until the route is deleted.
set -u

changed=0
while read -r dev; do
    [[ -n "$dev" ]] || continue
    carrier=$(cat "/sys/class/net/$dev/carrier" 2>/dev/null || echo 0)
    if [[ "$carrier" != "1" ]]; then
        if ip route del default dev "$dev" 2>/dev/null; then
            logger -t route-prune "removed default route on $dev (no carrier)"
            echo "removed default route on $dev (no carrier)"
            changed=1
        fi
    fi
done < <(ip -o route show default 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") print $(i + 1)}' | sort -u)

(( changed )) || exit 0
