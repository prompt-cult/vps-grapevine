# Grape: Traefik (Debian Trixie / Podman rootless)

## Overview

Rootless Traefik behind nftables port redirect. The kernel rewrites
incoming 80→8080 and 443→8443; Traefik listens on loopback only. No
rootful container, no CAP_NET_BIND_SERVICE.

## Files

| file | purpose |
|---|---|
| `traefik.yml` | Traefik static config (entryPoints, providers, ACME) |
| `traefik.container` | Quadlet unit — runs Traefik as the apps user |
| `traefik-net.network` | Quadlet network — shared bridge for app containers |
| `whoami.container` | Test container — verifies routing end-to-end |

## Install

```bash
# as the apps user:
cp traefik.yml ~/config/traefik/traefik.yml
cp traefik.container traefik-net.network whoami.container ~/.config/containers/systemd/

# reload systemd + start
systemctl --user daemon-reload
systemctl --user start traefik-net-network
systemctl --user start traefik
systemctl --user start whoami

# verify
systemctl --user status traefik
systemctl --user status whoami
```

## Verify

```bash
# Traefik responds on loopback
curl -sI http://127.0.0.1:8080/

# Whoami through Traefik (needs DNS for whoami.vps1.stenographer.cloud)
curl -sk https://whoami.vps1.stenographer.cloud/

# Dashboard (basic auth: admin / admin)
curl -sk https://traefik.vps1.stenographer.cloud/
```

## Rollback

```bash
systemctl --user stop whoami traefik
systemctl --user disable whoami traefik
rm ~/.config/containers/systemd/{traefik,whoami,traefik-net}.container
rm ~/.config/containers/systemd/{traefik-net}.network
systemctl --user daemon-reload
podman rm -f traefik whoami 2>/dev/null
```

## Notes

- The Podman socket at `/run/podman/podman.sock` must be enabled
  (`systemctl enable --now podman.socket`) — Traefik's Docker provider
  reads container labels from it.
- `acme.json` must be mode 600 (`chmod 600 ~/data/traefik/acme.json`).
- The basic auth password hash is `admin` — change it before production.
- Let's Encrypt HTTP challenge uses the http entryPoint (port 8080 via
  nftables redirect). DNS must resolve for ACME to work.
