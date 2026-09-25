#!/usr/bin/env sh
# This script runs when the openvpn routes are installed, and
# configures tailscale do advertise those routes on it's network.

set -euo pipefail

routes=""

# IPv4 routes (network + netmask, convert to CIDR)
i=1
while :; do
  eval net=\${route_network_$i:-}
  eval mask=\${route_netmask_$i:-}
  [ -z "$net" ] && break
  prefix=$(ipcalc -p "$net" "$mask" | cut -d= -f2)
  routes="${routes:+$routes,}$net/$prefix"
  i=$((i+1))
done

# IPv6 routes (already in CIDR form)
i=1
while :; do
  eval net6=\${route_ipv6_network_$i:-} 
  [ -z "$net6" ] && break
  routes="${routes:+$routes,}$net6"
  i=$((i+1))
done

[ -n "$routes" ] && tailscale set --advertise-routes="$routes"
exit 0