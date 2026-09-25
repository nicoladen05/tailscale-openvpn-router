FROM alpine:latest

RUN apk add --no-cache tailscale openvpn iptables ip6tables

COPY cidr.awk /usr/local/lib/cidr.awk

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT [ "/entrypoint.sh" ]
