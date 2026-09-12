# Fresh VPS Bootstrap — Server Setup Notes
# Branch: agent/server-setup on simbo1905/vps-grapevine

These notes document what a fresh Ubuntu 24.04 VPS needs beyond the
vps-grapevine repo scripts to reach the state of srv1081918.

## Phase 1: Base system

```bash
apt-get update && apt-get install -y build-essential age git curl
# Rust (for git-veil and mercury-compaction Rust CLI)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source ~/.cargo/env
# uv (for Python scripts)
curl -LsSf https://astral.sh/uv/install.sh | sh
```

## Phase 2: Mistral Vibe

```bash
# Install vibe CLI (follow official docs for current method)
# Set up config at ~/.vibe/config.toml with:
#   - Pinned model (zai-glm-5-2)
#   - MISTRAL_API_KEY in ~/.vibe/.env
#   - INCEPTION_API_KEY in ~/.vibe/.env (for mercury compaction)
```

## Phase 3: git-veil (key encryption)

```bash
# Build git-veil v0.4.0
git clone https://github.com/prompt-cult/git-veil.git /opt/git-veil
cd /opt/git-veil && cargo build --release
cp target/release/git-veil /usr/local/bin/

# Generate keys (age identity + Ed25519 signing key)
# age-keygen -o ~/.git-veil/age-identity.txt
# git-veil uses these to encrypt secrets in git repos

# When a production workload lands:
# 1. Create a separate user account
# 2. git-veil encrypts the agent keys
# 3. Lock the door when leaving
```

## Phase 4: Native PostgreSQL (for non-Zitadel apps)

```bash
apt-get install -y postgresql
# Configure listen_addresses in /etc/postgresql/16/main/postgresql.conf:
#   listen_addresses = 'localhost,172.17.0.1,<other-docker-gateways>'
# Do NOT listen on the public NIC
# Configure pg_hba.conf:
#   host <db> <user> 172.16.0.0/12 scram-sha-256  (Docker bridge subnets)
# Create roles and databases per app
```

## Phase 5: Zitadel stack (Docker Compose)

```bash
# /root/docker-compose.yml with:
#   - traefik:v3.7 (Let's Encrypt HTTP challenge, Docker provider)
#   - ghcr.io/zitadel/zitadel:v4.16.0 (start-from-init)
#   - ghcr.io/zitadel/zitadel-login:v4.16.0
#   - postgres:17-alpine
# Key env vars:
#   ZITADEL_MASTERKEY, ZITADEL_EXTERNALDOMAIN, ZITADEL_EXTERNALPORT=443
#   ZITADEL_EXTERNALSECURE=true, ZITADEL_TLS_ENABLED=false
#   ZITADEL_FIRSTINSTANCE_LOGINCLIENTPATPATH=/zitadel/bootstrap/login-client.pat
# Traefik labels for routing id.<domain> -> zitadel-api:8080
```

## Phase 6: Forgejo

```bash
# Native PostgreSQL role + database for forgejo
# Docker compose with:
#   - codeberg.org/forgejo/forgejo:<stable-version>
#   - Connected to native PG via docker0 gateway (172.17.0.1:5432)
#   - Traefik labels for git.<domain> -> forgejo:3000
#   - INSTALL_LOCK=true, DISABLE_REGISTRATION=true
#   - ENABLE_AUTO_REGISTRATION=true (for OIDC)
# OIDC auth source via CLI:
#   docker exec --user git forgejo forgejo admin auth add-oauth \
#     --name Zitadel --provider openidConnect \
#     --key <client_id> --secret <client_secret> \
#     --auto-discover-url https://id.<domain>/.well-known/openid-configuration \
#     --scopes openid --scopes profile --scopes email
```

## Phase 7: oauth2-proxy pattern (for gated static sites)

```yaml
# docker-compose.yml per site:
services:
  <site>-nginx:
    image: <static-site-image>
    networks: [<site>]
  <site>-proxy:
    image: quay.io/oauth2-proxy/oauth2-proxy:v7.8.1
    command: >
      --upstream=http://<site>-nginx:80
      --http-address=0.0.0.0:4180
      --email-domain=<domain>
      --provider=oidc
      --oidc-issuer-url=https://id.<domain>
      --redirect-url=https://<site>.<domain>/oauth2/callback
      "--scope=openid profile email"
      --skip-provider-button
      --code-challenge-method=S256
      --cookie-secure --cookie-httponly
      --set-xauthrequest --pass-authorization-header
      --authenticated-emails-file=/etc/oauth2-proxy/allowed-emails
      --whitelist-domain=.<domain>
    volumes:
      - ./allowed-emails:/etc/oauth2-proxy/allowed-emails:ro
    networks: [<site>, zitadel]  # zitadel network for Traefik discovery
    labels:
      - traefik.enable=true
      - traefik.docker.network=zitadel
      # ... router labels for <site>.<domain>
```

Key learnings:
- `--scope` is a single string, not repeatable. Use `"--scope=openid profile email"`.
- `OAUTH2_PROXY_SCOPE` env var overrides `--scope` flags. Remove it from env files.
- `--skip-provider-button` auto-redirects to OIDC provider (no sign-in page).
- `--authenticated-emails-file` for per-email filtering (env var doesn't exist).
- oauth2-proxy must be on the `zitadel` Docker network for Traefik to discover it.

## Phase 8: Mercury compaction (long-term memory)

```bash
git clone https://github.com/simbo1905/inception-mercury-compaction.git /opt/mercury-compaction
# Patch mercury.py: remove reasoning_effort="low", set temperature=0.5, max_tokens=8000
# Create summarize_session.py wrapper (handles 260K token context truncation)
# Memory folder: ~/.vibe/memory/ with INDEX.md
```

## Phase 9: Backup job

```bash
# /opt/backups/create-backup.py
# REPOS: list of git repos to bundle
# SENSITIVE_FILES: list of files to age-encrypt
# extras: non-secret config files to copy
# Run via cron, download via rsync from the User's mac
```

## Phase 10: Bridge daemon (vibed.service)

```bash
# /opt/vibe-bridge/vibe-bridge-v2 serve
# Mailbox at /opt/vibe-bridge/mail/ (inbox.jsonl, outbox.jsonl)
# systemd unit with flock/pidfile split-brain guard
```

## Cloud-specific config

Per the template: cloud-specific config lives in files named after the
provider DNS suffix (e.g. `hstgr-cloud.sh`), imported by generic scripts.
For Hostinger:
- DNS via IONOS panel (A records)
- VPS panel for rebuilds (2FA + browser automation)
- Weekly backups on test VPS, manual on production
