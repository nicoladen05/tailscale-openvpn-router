#!/usr/bin/env sh

set -euo pipefail

TAILSCALED_SOCKET="/var/run/tailscale/tailscaled.sock"
CIDR_AWK="/usr/local/lib/cidr.awk"
# Routing table for traffic of exit node clients, see route-up.sh.
EXIT_NODE_TABLE=100

# Configuration
TS_AUTH_KEY="${TS_AUTH_KEY:?TS_AUTH_KEY must be set}"
TS_HOSTNAME="${TS_HOSTNAME:-openvpn-router}"
TS_EXTRA_ARGS="${TS_EXTRA_ARGS:-}"
# Comma-separated list of IPv4 CIDRs to route through the VPN and advertise on the tailnet.
VPN_ROUTES="${VPN_ROUTES:-}"
# Also act as a Tailscale exit node that sends all traffic through the VPN.
EXIT_NODE="${EXIT_NODE:-false}"
# Addresses of the OpenVPN servers. Auto-detected from the "remote" lines of the config if unset.
OVPN_SERVER_IPS="${OVPN_SERVER_IPS:-}"
OVPN_USER="${OVPN_USER:-}"
OVPN_PASS="${OVPN_PASS:-}"

case "$EXIT_NODE" in
  true | false) ;;
  *)
    echo "EXIT_NODE must be true or false" >&2
    exit 1
    ;;
esac
if [ -z "$VPN_ROUTES" ] && [ "$EXIT_NODE" != true ]; then
  echo "VPN_ROUTES must be set (e.g. VPN_ROUTES=10.0.0.0/8,192.168.1.10/32), or EXIT_NODE=true" >&2
  exit 1
fi

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

if [ "$EXIT_NODE" = true ]; then
  # route-up.sh replaces the DNS servers once the tunnel is up. Docker keeps
  # that change across restarts, so start from Docker's original settings.
  [ -f /etc/resolv.conf.docker ] || cp /etc/resolv.conf /etc/resolv.conf.docker
  cat /etc/resolv.conf.docker > /etc/resolv.conf
  # Drop server addresses pinned by a previous run (see below), so they get
  # resolved again.
  grep -v ' # openvpn-remote$' /etc/hosts > /run/hosts || true
  cat /run/hosts > /etc/hosts
fi

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

if [ "$EXIT_NODE" = true ]; then
  # The VPN's DNS servers are only reachable through the tunnel, so OpenVPN
  # could not resolve the server hostnames when it reconnects. Pin them in
  # /etc/hosts while the regular DNS still works.
  for host in $(awk '$1 == "remote" && $2 !~ /^[0-9.]+$/ { print $2 }' /run/client.ovpn); do
    getent hosts "$host" |
      awk -v host="$host" '$1 ~ /^[0-9.]+$/ { print $1, host, "# openvpn-remote" }' >> /etc/hosts || true
  done
fi

# If we advertised a route containing an OpenVPN server, every client that
# accepts routes (including a host running this container) would send the
# encrypted OpenVPN packets back into Tailscale, creating a routing loop.
# So we advertise VPN_ROUTES minus the server addresses.
ADVERTISE_ROUTES=$(awk -f "$CIDR_AWK" -v mode=exclude -v routes="$VPN_ROUTES" -v exclude="$OVPN_SERVER_IPS")
echo "Advertising routes: ${ADVERTISE_ROUTES:-none}"

EXIT_NODE_ARGS=""
if [ "$EXIT_NODE" = true ]; then
  echo "Advertising exit node"
  # tailscaled would otherwise point /etc/resolv.conf at MagicDNS and
  # overwrite the VPN's DNS servers set by route-up.sh.
  EXIT_NODE_ARGS="--advertise-exit-node --accept-dns=false"

  # Traffic of exit node clients arrives on tailscale0 and is looked up in its
  # own table, which route-up.sh points at the tunnel. The container's own
  # traffic (including tailscaled's) keeps using the main table. Priority 5300
  # comes after Tailscale's own rules, which handle traffic to the tailnet.
  ip rule add iif tailscale0 lookup "$EXIT_NODE_TABLE" priority 5300
  # Kill switch: while the tunnel is down, refuse exit node traffic instead of
  # falling through to the main table and the regular gateway.
  ip route add unreachable default metric 4096 table "$EXIT_NODE_TABLE"

  # The VPN is IPv4-only, so always refuse IPv6 exit node traffic. The quick
  # ICMPv6 error lets clients fall back to IPv4 without waiting. If IPv6 is
  # disabled in the container, there is no IPv6 traffic to refuse.
  if ip -6 rule add iif tailscale0 lookup "$EXIT_NODE_TABLE" priority 5300 2>/dev/null; then
    ip -6 route add unreachable default table "$EXIT_NODE_TABLE"
  fi

  # Tailscale's MTU is lower than the tunnel's. Clamp the TCP MSS so large
  # packets don't get dropped on the way.
  iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu ||
    echo "WARNING: could not set up TCP MSS clamping" >&2
fi

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

# EXIT_NODE_ARGS and TS_EXTRA_ARGS are intentionally unquoted so they can hold multiple flags
# shellcheck disable=SC2086
tailscale --socket ${TAILSCALED_SOCKET} up \
  --auth-key="${TS_AUTH_KEY}" \
  --hostname="${TS_HOSTNAME}" \
  --advertise-routes="${ADVERTISE_ROUTES}" \
  $EXIT_NODE_ARGS \
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

if [ "$EXIT_NODE" = true ]; then
  set -- "$@" \
    --script-security 2 \
    --route-up /usr/local/lib/route-up.sh \
    --setenv EXIT_NODE_TABLE "$EXIT_NODE_TABLE" \
    --setenv OVPN_SERVER_IPS "$OVPN_SERVER_IPS"
fi

for ip in $OVPN_SERVER_IPS; do
  set -- "$@" --route "$ip" 255.255.255.255 net_gateway
done

while read -r network netmask; do
  [ -n "$network" ] || continue
  set -- "$@" --route "$network" "$netmask"
done <<EOF
$(awk -f "$CIDR_AWK" -v mode=netmask -v routes="$VPN_ROUTES")
EOF

openvpn "$@"
