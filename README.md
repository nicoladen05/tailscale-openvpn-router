# tailscale-openvpn-router

A container that connects to an OpenVPN network and shares it with your tailnet as a
Tailscale subnet router. Devices on the tailnet can then reach the networks behind the
VPN without running an OpenVPN client themselves.

## How it works

```
your devices ──Tailscale──▶ this container ──OpenVPN──▶ VPN network
```

The container joins your tailnet and connects to the OpenVPN. It then acts as a
gateway between the two:

1. **Tailscale:** the container tells your tailnet "send traffic for `VPN_ROUTES` to me".
2. **OpenVPN:** the container sends that traffic on through the VPN tunnel.

There is one catch. The VPN server itself can be inside one of the `VPN_ROUTES`
networks. If so, devices on the tailnet (including the machine that runs this container)
would send the VPN connection itself through Tailscale, back to the container, in a
loop. To prevent this, the container leaves the VPN server addresses out of what it
tells the tailnet. You don't have to do anything for this; it happens automatically.

Only IPv4 routes are supported for now.

## Setup

A prebuilt image is published to the GitHub Container Registry as
`ghcr.io/nicoladen05/tailscale-openvpn-router`. `latest` follows the `main` branch;
each commit is also tagged with its full commit hash, for pinning a specific version.

1. Create a directory for the router and save this as `compose.yml` in it:

   ```yaml
   services:
     tailscale-openvpn-router:
       image: ghcr.io/nicoladen05/tailscale-openvpn-router:latest
       container_name: tailscale-openvpn-router
       restart: unless-stopped
       env_file: .env
       cap_add:
         - NET_ADMIN
         - NET_RAW
       devices:
         - /dev/net/tun:/dev/net/tun
       sysctls:
         net.ipv4.ip_forward: 1
         net.ipv6.conf.all.forwarding: 1
       volumes:
         - ./state:/var/lib/tailscale
         - ./config:/config:ro
   ```

2. Put your OpenVPN client config in `config/` (e.g. `config/client.ovpn`).
3. Create a `.env` file next to `compose.yml` and fill it in. See
   [`.env.example`](.env.example) and [Configuration](#configuration).
4. Start the container:

   ```sh
   docker compose up -d
   ```

5. In the Tailscale admin console, approve the advertised subnet routes for the new node.
6. On clients, accept the routes (e.g. `tailscale set --accept-routes` on Linux).

The Tailscale node state is stored in `./state`, so the node keeps its identity across restarts.

To update to the latest image, run `docker compose pull && docker compose up -d`.

### Building the image yourself

To build from source instead, clone this repository and replace the `image:` line in
`compose.yml` with `build: .`, then start it with `docker compose up -d --build`.

## Configuration

| Variable          | Required | Description                                                                                  |
| ----------------- | -------- | -------------------------------------------------------------------------------------------- |
| `TS_AUTH_KEY`     | yes      | Tailscale auth key.                                                                          |
| `VPN_ROUTES`      | yes      | Comma-separated IPv4 CIDRs to route through the VPN and advertise, e.g. `10.0.0.0/8,192.168.1.10/32`. |
| `TS_HOSTNAME`     | no       | Node name on the tailnet. Default: `openvpn-router`.                                         |
| `TS_EXTRA_ARGS`   | no       | Extra flags for `tailscale up`, e.g. `--accept-dns=false`.                                   |
| `OVPN_USER`       | no       | OpenVPN username. Only used when set.                                                        |
| `OVPN_PASS`       | no       | OpenVPN password.                                                                            |
| `OVPN_CONFIG`     | no       | Path of the OpenVPN config. Default: the only `*.ovpn` file in `/config`.                    |
| `OVPN_SERVER_IPS` | no       | OpenVPN server addresses, e.g. `10.0.0.1,10.0.0.2`. Default: resolved from the `remote` lines of the config.           |

`up`/`down` scripts in the OpenVPN config and pushed `redirect-gateway`
options are ignored, so only the traffic for `VPN_ROUTES` goes through the VPN.

## Troubleshooting

The container logs the detected server addresses and the advertised routes at startup:

```sh
docker compose logs -f
```

If a server hostname cannot be resolved at startup, the container exits. Set
`OVPN_SERVER_IPS` to fixed addresses to avoid the DNS lookup.

## Future features

- **IPv6 support:** route and advertise IPv6 networks in `VPN_ROUTES`, not only IPv4.
- **Exit node support:** let the container act as a Tailscale exit node, so devices can
  send all of internet traffic through the VPN.
