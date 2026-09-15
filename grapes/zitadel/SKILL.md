# SKILL.md: Zitadel v4.17.3 with OpenResty Email Rate-Limiting Sidecar

## Image

```
ghcr.io/simbo1905/vps-grapevine/openresty-sidecar:1.0
```

## What this deploys

- Zitadel v4.17.3 (api + login + postgres) — stock images from ghcr.io/zitadel/
- OpenResty sidecar — custom image with email-based rate limiting
- One Zitadel instance, multi-tenant via Organizations

## Architecture

```
Traefik (TLS, LE, Host routing)
  ├── /ui/v2/login  →  zitadel-login:3000  (direct, no throttle)
  ├── /             →  zitadel-login:3000  (direct, no throttle)
  ├── /api          →  openresty-sidecar:8080  →  zitadel-api:8080  (rate limited)
  └── /*            →  openresty-sidecar:8080  →  zitadel-api:8080  (rate limited)
```

The OpenResty sidecar throttles POST requests containing `loginName`/`email`
to 1 request per 3 seconds per email address. Non-POST requests pass through
unthrottled. gRPC endpoints pass through unthrottled.

## Prerequisites

- Docker (or Podman with docker-compose) on the host
- Traefik running with Docker provider, `traefik` network exists
- DNS A record for the Zitadel domain pointing at the host
- Let's Encrypt HTTP challenge configured in Traefik

## Install

```bash
# 1. Pull the sidecar image
docker pull ghcr.io/simbo1905/vps-grapevine/openresty-sidecar:1.0

# 2. Create the deploy directory
mkdir -p /opt/zitadel && cd /opt/zitadel

# 3. Copy docker-compose.yml and .env.example from this package
#    (or from the vps-grapevine repo at grapes/zitadel/)

# 4. Create .env from .env.example, filling in secrets:
cp .env.example .env
# Edit .env:
#   - ZITADEL_DOMAIN: your FQDN (e.g. idp.stenographer.cloud)
#   - POSTGRES_ADMIN_PASSWORD: openssl rand -base64 32
#   - ZITADEL_DATABASE_POSTGRES_DSN: update password to match
#   - ZITADEL_MASTERKEY: openssl rand -hex 16
chmod 600 .env

# 5. Deploy
docker compose up -d

# 6. Wait for health
docker compose ps
# zitadel-postgres: healthy
# zitadel-api: healthy
# zitadel-login: healthy
# openresty-sidecar: up

# 7. Verify
curl -s https://idp.stenographer.cloud/.well-known/openid-configuration | head -5
# Should return JSON with issuer
```

## Multi-tenant setup (Organizations)

After Zitadel is running, create Organizations for each domain:

```bash
# Get a system token (from the bootstrap PAT)
PAT=$(cat /opt/zitadel/bootstrap/login-client.pat 2>/dev/null || \
  docker exec zitadel-api cat /zitadel/bootstrap/login-client.pat)

# Create Organization for stenographer.cloud
curl -X POST https://idp.stenographer.cloud/management/v1/orgs \
  -H "Authorization: Bearer $PAT" \
  -H "Content-Type: application/json" \
  -d '{"name":"stenographer.cloud"}'

# Create Organization for gitbackup.cloud
curl -X POST https://idp.stenographer.cloud/management/v1/orgs \
  -H "Authorization: Bearer $PAT" \
  -H "Content-Type: application/json" \
  -d '{"name":"gitbackup.cloud"}'
```

## Signup with any email

In Zitadel console (or via API), disable "User Loginname must contain orgdomain"
in the instance settings. This allows users to sign up with any email provider
(Gmail, Outlook, etc.) without being forced to use the org domain.

## Rate limiting verification

```bash
# Rapid login attempts should get 429 after the first one
for i in $(seq 1 5); do
  curl -s -o /dev/null -w "%{http_code}\n" \
    -X POST https://idp.stenographer.cloud/ui/v2/login/login \
    -H "Content-Type: application/json" \
    -d '{"loginName":"test@example.com","password":"wrong"}'
done
# Expected: 200, 429, 429, 429, 429
```

## Upgrade

```bash
# Pull new sidecar image
docker pull ghcr.io/simbo1905/vps-grapevine/openresty-sidecar:1.0

# Pull new Zitadel version (update ZITADEL_VERSION in .env first)
docker compose pull
docker compose up -d
```

## Tested on

- vps2 (72.61.16.48, Hostinger Ubuntu 24.04, Docker) — Zitadel v4.17.3 + Traefik
- vps0 (31.70.75.165, IONOS Debian Trixie, Podman) — pending deployment

## Memory note

Zitadel uses ~1.5GB RSS. On a 1.8GB RAM host, add a 2GB swap file before
deploying:
```bash
fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
```
