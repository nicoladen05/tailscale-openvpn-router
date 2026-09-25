FROM alpine:latest

RUN apk add --no-cache tailscale openvpn iptables ip6tables

COPY ovpn-route-up.sh /usr/local/bin/ovpn-route-up.sh
RUN chmod +x /usr/local/bin/ovpn-route-up.sh

COPY cidr.awk /usr/local/lib/cidr.awk

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT [ "/entrypoint.sh" ]
