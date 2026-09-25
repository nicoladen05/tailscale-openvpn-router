#!/usr/bin/env sh

set -euo pipefail

TAILSCALED_SOCKET="/var/run/tailscale/tailscaled.sock"
CIDR_AWK="/usr/local/lib/cidr.awk"

# Configuration
TS_AUTH_KEY="${TS_AUTH_KEY:?TS_AUTH_KEY must be set}"
TS_HOSTNAME="${TS_HOSTNAME:-openvpn-router}"
TS_EXTRA_ARGS="${TS_EXTRA_ARGS:-}"
# Comma-separated list of IPv4 CIDRs to route through the VPN and advertise on the tailnet.
VPN_ROUTES="${VPN_ROUTES:?VPN_ROUTES must be set, e.g. VPN_ROUTES=10.0.0.0/8,192.168.1.10/32}"
# Addresses of the OpenVPN servers. Auto-detected from the "remote" lines of the config if unset.
OVPN_SERVER_IPS="${OVPN_SERVER_IPS:-}"
OVPN_USER="${OVPN_USER:-}"
OVPN_PASS="${OVPN_PASS:-}"

# Pick the OpenVPN config. Defaults to the only *.ovpn file in /config.
if [ -z "${OVPN_CONFIG:-}" ]; then
  set -- /config/*.ovpn
  if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
    echo "Expected exactly one *.ovpn file in /config, set OVPN_CONFIG to choose one" >&2
    exit 1
  fi
  OVPN_CONFIG="$1"
fi

# Strip any scripts for updating DNS, since that isn't needed
grep -vE '^\s*(up|down)\s' "$OVPN_CONFIG" > /run/client.ovpn

# Resolve the OpenVPN servers so their traffic keeps using the regular
# gateway, even when they live inside one of the VPN_ROUTES.
if [ -z "$OVPN_SERVER_IPS" ]; then
  for host in $(awk '$1 == "remote" { print $2 }' /run/client.ovpn); do
    ips=$(getent hosts "$host" | awk '$1 ~ /^[0-9.]+$/ { print $1 }') || true
    if [ -z "$ips" ]; then
      echo "Could not resolve OpenVPN server $host, set OVPN_SERVER_IPS manually" >&2
      exit 1
    fi
    OVPN_SERVER_IPS="$OVPN_SERVER_IPS $ips"
  done
fi
OVPN_SERVER_IPS=$(echo "$OVPN_SERVER_IPS" | tr ', ' '\n\n' | awk 'NF && !seen[$1]++' | tr '\n' ' ')
echo "OpenVPN server addresses: ${OVPN_SERVER_IPS:-none}"

# If we advertised a route containing an OpenVPN server, every client that
# accepts routes (including a host running this container) would send the
# encrypted OpenVPN packets back into Tailscale, creating a routing loop.
# So we advertise VPN_ROUTES minus the server addresses.
ADVERTISE_ROUTES=$(awk -f "$CIDR_AWK" -v mode=exclude -v routes="$VPN_ROUTES" -v exclude="$OVPN_SERVER_IPS")
echo "Advertising routes: ${ADVERTISE_ROUTES}"

# Start tailscale
tailscaled --socket ${TAILSCALED_SOCKET} &

# Wait for the daemon to start and create the socket file
elapsed=0
while [ ! -S "$TAILSCALED_SOCKET" ]; do
  if [ "$elapsed" -ge 60 ]; then # Time out after 60 seconds
    echo "tailscaled socket did not appear after 60 seconds" >&2
    exit 1
  fi

  sleep 1
  elapsed=$((elapsed + 1))
done

# TS_EXTRA_ARGS is intentionally unquoted so it can hold multiple flags
# shellcheck disable=SC2086
tailscale --socket ${TAILSCALED_SOCKET} up \
  --auth-key="${TS_AUTH_KEY}" \
  --hostname="${TS_HOSTNAME}" \
  --advertise-routes="${ADVERTISE_ROUTES}" \
  $TS_EXTRA_ARGS

# Build the openvpn arguments
set -- \
  --config /run/client.ovpn \
  --pull-filter ignore "redirect-gateway"

if [ -n "$OVPN_USER" ]; then
  umask 077
  printf '%s\n%s\n' "$OVPN_USER" "$OVPN_PASS" > /run/ovpn-creds.txt
  set -- "$@" --auth-user-pass /run/ovpn-creds.txt
fi

for ip in $OVPN_SERVER_IPS; do
  set -- "$@" --route "$ip" 255.255.255.255 net_gateway
done

while read -r network netmask; do
  set -- "$@" --route "$network" "$netmask"
done <<EOF
$(awk -f "$CIDR_AWK" -v mode=netmask -v routes="$VPN_ROUTES")
EOF

openvpn "$@"
