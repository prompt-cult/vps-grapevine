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

# Whoami through Traefik (needs DNS for whoami.vps01.example.com)
curl -sk https://whoami.vps01.example.com/

# Dashboard is NOT exposed to the internet.
# Access it via SSH port forwarding only:
#   ssh -L 8080:127.0.0.1:8080 root@vps01.example.com
# Then visit http://localhost:8080/dashboard/
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

- The Podman socket at `/run/user/1000/podman/podman.sock` must be enabled
  for the apps user (`systemctl --machine=apps@.host --user enable --now podman.socket`).
  Traefik's Docker provider reads container labels from it. The Traefik
  static config references the in-container path `unix:///var/run/docker.sock`;
  the Quadlet volume mount maps the host socket to that path.
- `acme.json` must be mode 600 (`chmod 600 ~/data/traefik/acme.json`).
- **SECURITY: The Traefik dashboard must NEVER be exposed to the internet.**
  An earlier version of this grape exposed the dashboard on
  `traefik.vps01.example.com` with basic auth `admin/admin` — that is
  a trivially guessable credential on a public-facing admin panel. The
  dashboard labels have been removed from the Quadlet unit and `api.dashboard`
  is set to `false` in the static config. If you need the dashboard, use SSH
  port forwarding: `ssh -L 8080:127.0.0.1:8080 root@vps01.example.com`
  then visit `http://localhost:8080/dashboard/`.
- Let's Encrypt HTTP challenge uses the http entryPoint (port 8080 via
  nftables redirect). DNS must resolve for ACME to work.
