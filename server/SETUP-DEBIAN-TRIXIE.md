# Setup Notes: vps-grapevine on Debian 13 (Trixie) with Podman

This is a remix of the original Ubuntu setup (see SETUP-NOTES.md) for Debian
Trixie on IONOS Cloud Panel. The key differences:

- **Podman instead of Docker** — daemonless, rootless by default, Quadlet for systemd
- **apps user** — unprivileged service user for rootless containers + vibe daemon
- **nftables port redirect** — kernel NAT forwards 80/443 to high loopback ports,
  so Traefik runs rootless without CAP_NET_BIND_SERVICE
- **No Docker daemon** — no `dockerd`, no `/var/run/docker.sock` attack surface

## Host inventory — IPs and roles

There is exactly one IONOS.de VPS. These are the only IPs in this project:

| Host | IP | Provider | OS | Role |
|---|---|---|---|---|
| vps0 | 31.70.75.165 | IONOS.de | Debian 13 Trixie | Production VPS (IdP, Traefik, vibe agent) |
| vps1 | 72.61.145.134 | Hostinger | Ubuntu 24.04 | Test box (stable, KVM2, larger) |
| vps2 | 72.61.16.48 | Hostinger | Ubuntu 24.04 | Burner/expiring (KVM1, smaller) |
| Managed Nextcloud | 217.160.0.81 | IONOS.de | Managed hosting | Nextcloud Enterprise (NOT a VPS — no SSH, no Docker, no admin access) |

### Managed Nextcloud (217.160.0.81)

This project uses IONOS managed Nextcloud for WebDAV storage. We do NOT manage
that host. We do NOT SSH into it. We cannot admin that box. It is a managed
hosting product, not a VPS. The `stenographer.cloud` apex domain and
`nextcloud.stenographer.cloud` point at 217.160.0.81 for the Nextcloud
instance. All VPS subdomains (idp, traefik, vps1, whoami, etc.) point at
31.70.75.165.

### DNS records for IdP

Both `idp` subdomains point at vps0 (31.70.75.165):

| Record | Type | Value | TTL |
|---|---|---|---|
| idp.stenographer.cloud | A | 31.70.75.165 | 300 (5 min) |
| idp.gitbackup.cloud | A | 31.70.75.165 | 300 (5 min) |

These were initially created pointing at 217.160.0.81 (the managed Nextcloud
IP) by mistake. They have been corrected to 31.70.75.165 (the actual VPS).

## Phase 0: Base system

```bash
apt update && apt full-upgrade -y
apt install -y curl git unzip age gpg build-essential nftables
```

## Phase 1: Create the apps user

Rootless Podman needs a dedicated unprivileged user with subuid/subgid ranges.

```bash
# create a service user with a home directory and login
adduser --gecos "" apps

# confirm it got subuid/subgid ranges (apt install podman sets these up)
grep apps /etc/subuid /etc/subgid
```

Everything below assumes that `apps` user.

## Phase 2: Install Podman

Debian 13 ships Podman 5.4.x from main repos — no third-party sources needed.

```bash
apt install -y podman podman-compose podman-docker

# enable the Docker-compatible socket (system, rootful Podman)
# Traefik's Docker provider talks to this socket
systemctl enable --now podman.socket
# socket lives at /run/podman/podman.sock

# enable the apps user's own rootless podman socket
# Traefik (running as apps) mounts this into its container
systemctl --machine=apps@.host --user enable --now podman.socket
# rootless socket lives at /run/user/1000/podman/podman.sock

# enable lingering so rootless services survive logout
loginctl enable-linger apps
```

### Why Podman not Docker

Docker's security problem is the long-running root daemon (`dockerd`). Any
process that can talk to the Docker socket effectively has root on the host.
Mount that socket into a container and a container escape = full host
compromise.

Podman is daemonless — each `podman run` is a short-lived process. Rootless
by default via user namespaces + subuid/subgid ranges. A container escape
lands in a heavily-mapped unprivileged UID, not root.

CLI-compatible: `podman` accepts the same commands as `docker`. Existing
compose files work via `podman-compose`. Quadlet generates systemd units
from `.container` files.

## Phase 3: Directory layout

Two kinds of files: config you write (Quadlet units, Traefik config) and
persistent data the containers write (DBs, certs, uploaded files).

```
/home/apps/
├── config/                          # your hand-written config (version-control this)
│   ├── containers/systemd/          # Quadlet .container/.network/.volume files
│   │   ├── traefik.container
│   │   ├── whoami.container
│   │   ├── traefik-network.network
│   │   └── ...
│   └── traefik/
│       ├── traefik.yml              # static Traefik config
│       └── dynamic/                 # dynamic file-provider config (if you use it)
│
├── data/                            # persistent container data (DON'T version-control)
│   ├── traefik/
│   │   └── acme.json                # Let's Encrypt certs — chmod 600
│   └── <appname>/                   # per-app volumes
│
└── compose/                         # optional: podman-compose files if you prefer compose
```

### Where Quadlet looks, by default

Quadlet searches these paths (run as the `apps` user):
- `~/.config/containers/systemd/*.container` (rootless, per-user)
- `/etc/containers/systemd/` (system-wide, rootful — only if you run something rootful)

```bash
# as the apps user:
mkdir -p ~/.config/containers/systemd
mkdir -p ~/config/traefik/dynamic
mkdir -p ~/data/traefik
```

When you drop a `.container` file there and run `systemctl --user daemon-reload`,
Podman auto-generates the systemd unit. You then manage it with
`systemctl --user start traefik`, `systemctl --user status traefik`, etc.

## Phase 4: nftables — SSH + port redirect for rootless Traefik

Instead of running Traefik as root to bind 80/443, we use kernel NAT to
DNAT incoming 80/443 to 127.0.0.1:8080/8443 where rootless Traefik
listens. This is the "OS NAT" approach — no rootful container, no
CAP_NET_BIND_SERVICE hack.

### Prerequisites: sysctl settings

DNAT to 127.0.0.1 requires three sysctl settings that are NOT default:

```bash
# Enable IP forwarding (needed for NAT to work)
sysctl -w net.ipv4.ip_forward=1

# Allow routing to 127.0.0.1 (loopback) from external interfaces
# Without this, the kernel drops packets DNAT'd to 127.0.0.1
sysctl -w net.ipv4.conf.all.route_localnet=1
sysctl -w net.ipv4.conf.ens6.route_localnet=1

# Persist across reboots
cat > /etc/sysctl.d/99-route-localnet.conf << 'EOF'
net.ipv4.conf.ens6.route_localnet=1
net.ipv4.ip_forward = 1
EOF
```

**Note:** `route_localnet=1` must be set on `all` AND on the specific
interface (e.g. `ens6`). Check your interface name with `ip addr` —
IONOS VPS uses `ens6`.

### The nftables ruleset

1. Input: allow loopback, ICMP, established/related, TCP 22 (SSH only)
2. Input: allow TCP 80/443 (so the packets arrive)
3. Input: allow TCP 8080/8443 (DNAT targets — packets rewritten to
   127.0.0.1:8080/8443 arrive on the input chain for local delivery)
4. NAT prerouting: DNAT 80 → 127.0.0.1:8080, 443 → 127.0.0.1:8443
5. NAT postrouting: masquerade on lo so reply traffic has correct source
6. Forward: policy accept (DNAT'd packets may traverse forward chain)
7. Traefik listens on 127.0.0.1:8080 and 127.0.0.1:8443 as the apps user

See `server/nftables/nftables-debian.conf` for the full ruleset.

### Why DNAT to 127.0.0.1 and not `redirect to`?

`redirect to :8080` changes the destination port but keeps the destination
IP as the external IP. Traefik (via rootlessport) only listens on
127.0.0.1:8080, so the connection is refused. `dnat to 127.0.0.1:8080`
rewrites both the IP and port, delivering the packet to the loopback
address where Traefik is actually listening.

### Why not run Traefik as root?

- Rootful containers are the Docker security problem we're avoiding
- `CAP_NET_BIND_SERVICE` is a capability escalation that can be exploited
- Kernel NAT is the cleanest split: the OS does the port translation, Traefik
  stays unprivileged, no capabilities needed

### Why not just open 80/443 in the firewall and let Traefik bind directly?

Rootless Podman can't bind ports below 1024 — those need root. The nftables
redirect is the bridge: the kernel rewrites the destination port before the
packet reaches userspace, so Traefik only ever sees 8080/8443.

## Phase 5: Install uv and Mistral Vibe CLI

```bash
# as root — install uv
curl -LsSf https://astral.sh/uv/install.sh | sh
source /root/.local/bin/env

# install mistral-vibe via uv tool
uv tool install mistral-vibe

# verify
vibe --version
```

The vibe binary lands at `/root/.local/bin/vibe`.

## Phase 6: Vibe configuration

```bash
# config directory
mkdir -p /root/.vibe

# write config with the Mistral API key
cat > /root/.vibe/config.toml << 'EOF'
[providers.mistral]
api_key = "<MISTRAL_API_KEY from .env>"
EOF

# create the agent profile
mkdir -p /root/.vibe/agents
cat > /root/.vibe/agents/box-manager.toml << 'EOF'
model = "mistral-medium-3.5"
EOF
```

## Phase 7: Install vibe-bridge + mailbox

```bash
mkdir -p /opt/vps-grapevine/mail
cp vibe-bridge /opt/vps-grapevine/
chmod +x /opt/vps-grapevine/vibe-bridge
```

The vibe-bridge script is adapted for Debian Trixie:
- VIBE path: `/root/.local/bin/vibe`
- WORKDIR: `/root`
- AGENT: `box-manager`
- MAIL: `/opt/vps-grapevine/mail` (env override: `VPS_GRAPEVINE_MAIL`)
- PIDFILE: `/run/vibed.pid`
- LOCKFILE: `/run/vibed.lock`
- SOCKFILE: `/run/vibed.sock`
- LOGFILE: `/var/log/vibe-bridge.log`
- SESSIONFILE: `/etc/vibe-bridge/session_id`

## Phase 8: systemd vibed.service

```ini
[Unit]
Description=Vibe Bridge Daemon (vps-grapevine)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/env -S uv run --script /opt/vps-grapevine/vibe-bridge serve
Restart=on-failure
RestartSec=5
Environment=VPS_GRAPEVINE_MAIL=/opt/vps-grapevine/mail
Environment=TERM=dumb
# Security: lock down the daemon
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/opt/vps-grapevine /var/log /run /etc/vibe-bridge /root/.vibe
ProtectHome=read-only
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

Install:
```bash
cp vibed.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable vibed
```

## Phase 9: First run + start daemon

```bash
# first run to initialize the session (must succeed before daemon starts)
vibe -p READY --yolo --agent box-manager --trust

# start the daemon
systemctl start vibed
systemctl status vibed
```

## Phase 10: AGENTS.md on the box

Append the box policy from `server/AGENTS.md.template` to `/root/AGENTS.md`.
The template is adapted for Debian Trixie:
- References Podman/Quadlet instead of Docker
- References nftables port redirect instead of Docker DNAT
- References the apps user for container workloads
- Vibe daemon runs as root (SSH-only, no network exposure)
- App containers run as the apps user (rootless Podman)

## Summary: what runs as what

| Component | User | Why |
|---|---|---|
| SSH daemon (sshd) | root | port 22, always |
| vibed.service (vibe-bridge) | root | owns the mailbox, runs vibe -p |
| vibe agent | root | programmatic mode, no TUI |
| Podman socket | root | Docker-compatible API for Traefik |
| Traefik (future) | apps | rootless, listens on 127.0.0.1:8080/8443 |
| App containers (future) | apps | rootless Podman + Quadlet |
| nftables | root | kernel NAT 80→8080, 443→8443 |

## Verified deltas on Debian 13 (Trixie)

1. Vibe install: `uv tool install mistral-vibe` (npm returns 404 on Debian)
2. Podman 5.4.x from apt, no third-party repos
3. nftables `dnat to 127.0.0.1:8080` in nat prerouting (NOT `redirect to` —
   redirect keeps the external IP as destination, but Traefik only listens on
   127.0.0.1, so the connection is refused)
4. Python 3.13 ships with Trixie; uv scripts work fine
5. `loginctl enable-linger apps` required for rootless services to survive logout
6. No Docker daemon — podman.socket provides the Docker-compatible API
7. Rootless Traefik needs the apps user's own podman socket at
   `/run/user/1000/podman/podman.sock`, not the system socket at
   `/run/podman/podman.sock`. Enable it with
   `systemctl --machine=apps@.host --user enable --now podman.socket`.
8. The Traefik static config must reference the in-container socket path
   `unix:///var/run/docker.sock`, not the host path — the Quadlet volume
   mount maps the host socket to the container path.
9. DNAT to 127.0.0.1 requires `net.ipv4.ip_forward=1` AND
   `net.ipv4.conf.all.route_localnet=1` AND
   `net.ipv4.conf.<iface>.route_localnet=1`. Without ip_forward, NAT
   silently drops packets. Without route_localnet, the kernel refuses to
   route to 127.0.0.1 from an external interface.
10. The input chain must allow TCP 8080 and 8443 — DNAT'd packets to
    127.0.0.1 arrive on the input chain (local delivery), not the forward
    chain.
11. The vibe-bridge `in_flight` set must be module-level, not local to
    `serve()` — the `worker()` thread references it and gets a NameError
    if it's a local variable.

## Security incident: dashboard exposed with admin/admin

During initial setup, the Traefik dashboard was exposed on
`traefik.vps1.stenographer.cloud` with basic auth credentials `admin/admin`.
This is a trivially guessable password on a public-facing admin panel —
unacceptable for any internet-facing host.

**What happened:** The Quadlet unit included dashboard router labels and a
basic auth middleware with a hardcoded `admin:{SHA}...` hash. The DNS A
record for `traefik.vps1.stenographer.cloud` was added, which would have
allowed Let's Encrypt to provision a TLS cert and make the dashboard
reachable from the internet.

**What was done to fix it:**
- Removed all dashboard router labels from the Traefik Quadlet unit
- Set `api.dashboard: false` and `api.insecure: false` in the static config
- Restarted Traefik — no dashboard or API endpoint is exposed
- The `traefik.vps1.stenographer.cloud` DNS record returns a 404 (no
  matching route in Traefik)

**Lesson:** Never expose admin dashboards to the internet with default or
trivially guessable credentials. If a dashboard is needed, use SSH port
forwarding:
```bash
ssh -L 8080:127.0.0.1:8080 root@vps1.stenographer.cloud
# then visit http://localhost:8080/dashboard/ locally
```
