#!/usr/bin/env sh
# OpenVPN --route-up hook, only used when EXIT_NODE=true.
#
# Sends exit node traffic into the tunnel and points the container's DNS at
# the DNS servers the VPN pushes, so DNS queries of exit node clients don't
# leak outside the VPN. OpenVPN provides $dev, $route_vpn_gateway and
# $foreign_option_N, entrypoint.sh provides the rest via --setenv.

set -eu

# Exit node traffic is looked up in this table (see entrypoint.sh). This route
# wins over the fallback "unreachable" route while the tunnel exists.
# $route_vpn_gateway is intentionally unquoted so it can expand to nothing.
# shellcheck disable=SC2086
ip route replace default ${route_vpn_gateway:+via $route_vpn_gateway} dev "$dev" table "$EXIT_NODE_TABLE"
echo "Exit node traffic now goes through $dev"

# Pushed options arrive as foreign_option_1, foreign_option_2, ...
# e.g. "dhcp-option DNS 10.8.0.1"
dns=""
i=1
while eval "opt=\${foreign_option_$i:-}" && [ -n "$opt" ]; do
  # shellcheck disable=SC2086
  set -- $opt
  if [ "$1" = "dhcp-option" ] && [ "${2:-}" = "DNS" ] &&
    echo "${3:-}" | grep -qE '^[0-9]+(\.[0-9]+){3}$'; then
    dns="$dns $3"
  fi
  i=$((i + 1))
done

vpn_dns=""
for ns in $dns; do
  # A route for an OpenVPN server would replace its route to the regular
  # gateway and send the tunnel into itself.
  case " $OVPN_SERVER_IPS " in
    *" $ns "*)
      echo "WARNING: ignoring pushed DNS server $ns, it is also an OpenVPN server" >&2
      continue
      ;;
  esac
  # tailscaled answers the DNS queries of exit node clients itself, and its
  # own traffic uses the main table, so the DNS servers need a route there.
  # shellcheck disable=SC2086
  ip route replace "$ns/32" ${route_vpn_gateway:+via $route_vpn_gateway} dev "$dev"
  vpn_dns="$vpn_dns $ns"
done

if [ -z "$vpn_dns" ]; then
  echo "WARNING: the VPN pushed no usable IPv4 DNS servers, DNS queries of exit node clients will not go through the VPN" >&2
  exit 0
fi

# Docker bind-mounts /etc/resolv.conf, so write it in place instead of replacing it.
# shellcheck disable=SC2086
printf 'nameserver %s\n' $vpn_dns > /etc/resolv.conf
echo "DNS servers now:$vpn_dns"
