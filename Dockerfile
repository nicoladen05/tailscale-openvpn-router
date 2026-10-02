FROM alpine:latest

RUN apk add --no-cache tailscale openvpn iptables ip6tables iproute2

COPY cidr.awk /usr/local/lib/cidr.awk
COPY route-up.sh /usr/local/lib/route-up.sh

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh /usr/local/lib/route-up.sh
ENTRYPOINT [ "/entrypoint.sh" ]
