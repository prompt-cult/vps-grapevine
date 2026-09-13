# Grape: forgejo — Zitadel SSO + Forgejo + oauth2-proxy behind Traefik

One grape = Forgejo (git server) gated by oauth2-proxy, authenticated
against Zitadel OIDC, all routed by a running Traefik. Restructured verbatim
from the agent-verified RUNBOOK (passed end-to-end on a real box: id2
discovery 200 with LE cert, git unauth 302 to the IdP, both-user logins).
Landed at v0.2.1.

## Vocabulary

- **IdP** — Zitadel at `SSO.DOMAIN` (already deployed, Phase 1 here covers it
  for a fresh box; skip to Phase 2 if Zitadel is already running)
- **app** — Forgejo at `APP.DOMAIN`, proxied by oauth2-proxy
- **proxy** — oauth2-proxy; the ONLY service Traefik routes `APP.DOMAIN` to

## Prerequisites

- Fresh Ubuntu 24.04 server with:
  - Docker Engine 24+ and Docker Compose plugin installed
  - Traefik running with:
    - `web` entrypoint on :80 (redirects to :443)
    - `websecure` entrypoint on :443
    - `letsencrypt` ACME HTTP challenge resolver configured
    - Docker provider enabled (`providers.docker=true`, `providers.docker.exposedbydefault=false`)
    - A `traefik` Docker network (external)
  - DNS A records for `SSO.DOMAIN` and `APP.DOMAIN` pointing to `SERVER_IP`
  - Ports 22, 80, 443 open in the firewall

## Placeholders

Replace these throughout before executing (secrets come from the grape's own
`.env`, mode 600 — never from this file):

| Placeholder | Meaning | Example |
|---|---|---|
| `SSO.DOMAIN` | Zitadel public domain | id.example.com |
| `APP.DOMAIN` | Forgejo public domain | git.example.com |
| `SERVER_IP` | Server public IPv4 | 203.0.113.10 |
| `REGISTRY` | Container registry prefix (if mirrored) | ghcr.io |
| `ACME_EMAIL` | Let's Encrypt notification email | ops@example.com |
| `ZITADEL_VERSION` | Zitadel version tag | v4.17.3 |
| `FORGEJO_VERSION` | Forgejo version tag | 16.0.4 |
| `OAUTH2_PROXY_VERSION` | oauth2-proxy version | v7.8.1 |

Verified parameter values (do not drift): zitadel `v4.16+` compose shape,
`postgres:17-alpine`, forgejo `FORGEJO_VERSION`, oauth2-proxy
`OAUTH2_PROXY_VERSION` (v7.8.1 pinned for the scope/arg gotchas below).

## Files in this grape

```
grapes/forgejo/
  grape-forgejo.md     this skill
  zitadel-compose.yml  Zitadel stack (postgres + api + login) -> /root/docker-compose.yml
  zitadel.env.example  Zitadel env template -> /root/.env
  docker-compose.yml   Forgejo + oauth2-proxy stack -> /opt/forgejo/docker-compose.yml
  .env.example         OIDC client + cookie secrets -> /opt/forgejo/.env
```

Resulting on-box layout:

```
/root/
  .env                    # Zitadel secrets (mode 600)
  docker-compose.yml      # Zitadel stack
  SSO-credentials         # All credentials (mode 600)

/opt/forgejo/
  .env                    # OIDC client + cookie secrets (mode 600)
  docker-compose.yml      # Forgejo + oauth2-proxy stack
  data/                   # Forgejo data volume
```

## Install

### Phase 1: Deploy Zitadel (skip if already running)

#### 1.1 Create the Zitadel compose directory and .env

```bash
# All Zitadel files live in /root (per box policy)
cd /root

# Generate secrets (32 chars each)
ZITADEL_MASTERKEY=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 32)
POSTGRES_ADMIN_PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 32)

cat > /root/.env <<EOF
ZITADEL_DOMAIN=SSO.DOMAIN
ZITADEL_EXTERNALPORT=443
ZITADEL_EXTERNALSECURE=true
ZITADEL_PUBLIC_SCHEME=https
ZITADEL_MASTERKEY=${ZITADEL_MASTERKEY}
LOGIN_CLIENT_PAT_EXPIRATION=2099-01-01T00:00:00Z
ZITADEL_VERSION=ZITADEL_VERSION
POSTGRES_IMAGE=postgres:17-alpine
POSTGRES_DB=zitadel
POSTGRES_ADMIN_USER=postgres
POSTGRES_ADMIN_PASSWORD=${POSTGRES_ADMIN_PASSWORD}
ZITADEL_DATABASE_POSTGRES_DSN=postgresql://postgres:${POSTGRES_ADMIN_PASSWORD}@zitadel-postgres:5432/zitadel?sslmode=disable
ZITADEL_ACCESS_LOG_STDOUT_ENABLED=true
ZITADEL_CACHES_CONNECTORS_REDIS_ENABLED=false
ZITADEL_INSTRUMENTATION_TRACE_EXPORTER_TYPE=none
ZITADEL_INSTRUMENTATION_SERVICENAME=zitadel-api
ZITADEL_INSTRUMENTATION_TRACE_EXPORTER_ENDPOINT=
ZITADEL_INSTRUMENTATION_TRACE_EXPORTER_INSECURE=true
EOF

chmod 600 /root/.env
```

#### 1.2 Create /root/docker-compose.yml

Copy `zitadel-compose.yml` from this grape to `/root/docker-compose.yml`
(verbatim — verified Traefik label priorities, h2c scheme, strip-prefix
middlewares, healthchecks).

#### 1.3 Start Zitadel

```bash
cd /root
docker compose --env-file .env pull
docker compose --env-file .env up -d --wait
```

Wait for all three containers (zitadel-postgres, zitadel-api, zitadel-login) to be healthy.

#### 1.4 Set the admin password

The default admin is `zitadel-admin@zitadel.SSO.DOMAIN` with password `Password1!`.

```bash
# Get the bootstrap PAT (machine user with IAM_LOGIN_CLIENT role)
PAT=$(docker run --rm -v zitadel_zitadel-bootstrap:/bootstrap:ro alpine cat /bootstrap/login-client.pat)

# Get the admin user ID
ADMIN_USER=$(docker run --rm --network zitadel curlimages/curl -s -X POST \
  -H "Authorization: Bearer $PAT" \
  -H "Host: SSO.DOMAIN" \
  -H "Content-Type: application/json" \
  "http://zitadel-api:8080/management/v1/users/_search" \
  -d '{}' | python3 -c "import sys,json; d=json.load(sys.stdin); [print(u['id']) for u in d['result'] if 'admin' in u.get('userName','')]")

# Generate a strong admin password
ADMIN_PASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)aA1!

# Set the admin password via v1 management API
docker run --rm --network zitadel curlimages/curl -s -X POST \
  -H "Authorization: Bearer $PAT" \
  -H "Host: SSO.DOMAIN" \
  -H "Content-Type: application/json" \
  "http://zitadel-api:8080/management/v1/users/$ADMIN_USER/password" \
  -d "{\"password\":\"$ADMIN_PASSWORD\"}"
```

#### 1.5 Record credentials

```bash
cat > /root/SSO-credentials <<EOF
# Zitadel SSO Credentials - SSO.DOMAIN
# MODE 600 - never commit to any repo

[Zitadel Admin]
URL: https://SSO.DOMAIN
Username: zitadel-admin@zitadel.SSO.DOMAIN
Password: <ADMIN_PASSWORD>
EOF

chmod 600 /root/SSO-credentials
```

### Phase 2: Create human users

Use the v2 API (the v1 API does not properly set passwords in Zitadel v4.x).

```bash
PAT=$(docker run --rm -v zitadel_zitadel-bootstrap:/bootstrap:ro alpine cat /bootstrap/login-client.pat)

# Create admin session for management operations
ADMIN_PASSWORD="<from SSO-credentials>"
ADMIN_SESSION=$(docker run --rm --network zitadel curlimages/curl -s -X POST \
  -H "Authorization: Bearer $PAT" \
  -H "Host: SSO.DOMAIN" \
  -H "Content-Type: application/json" \
  "http://zitadel-api:8080/v2/sessions" \
  -d "{\"checks\":{\"user\":{\"loginName\":\"zitadel-admin@zitadel.SSO.DOMAIN\"},\"password\":{\"password\":\"$ADMIN_PASSWORD\"}}}")
ADMIN_TOKEN=$(echo "$ADMIN_SESSION" | python3 -c "import sys,json; print(json.load(sys.stdin)['sessionToken'])")

# User 1: must change password at first login
USER1_PASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)aA1!
docker run --rm --network zitadel curlimages/curl -s -X POST \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Host: SSO.DOMAIN" \
  -H "Content-Type: application/json" \
  "http://zitadel-api:8080/v2/users/human" \
  -d "{\"username\":\"user1@example.com\",\"profile\":{\"givenName\":\"First\",\"familyName\":\"User\"},\"email\":{\"email\":\"user1@example.com\",\"isVerified\":true},\"password\":{\"password\":\"$USER1_PASSWORD\",\"passwordChangeRequired\":true}}"

# User 2: fixed password
USER2_PASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)aA1!
docker run --rm --network zitadel curlimages/curl -s -X POST \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Host: SSO.DOMAIN" \
  -H "Content-Type: application/json" \
  "http://zitadel-api:8080/v2/users/human" \
  -d "{\"username\":\"user2@example.com\",\"profile\":{\"givenName\":\"Second\",\"familyName\":\"User\"},\"email\":{\"email\":\"user2@example.com\",\"isVerified\":true},\"password\":{\"password\":\"$USER2_PASSWORD\",\"passwordChangeRequired\":false}}"
```

Append user credentials to /root/SSO-credentials (mode 600).

### Phase 3: Create OIDC application for oauth2-proxy

```bash
# Create a project
PROJECT_RESPONSE=$(docker run --rm --network zitadel curlimages/curl -s -X POST \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Host: SSO.DOMAIN" \
  -H "Content-Type: application/json" \
  "http://zitadel-api:8080/management/v1/projects" \
  -d '{"name":"forgejo","projectRoleAssertion":false,"projectRoleKeysForToken":false,"hasProjectCheck":false,"privateLabelingSetting":"PRIVATE_LABELING_SETTING_UNSPECIFIED"}')
PROJECT_ID=$(echo "$PROJECT_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

# Create an OIDC application
APP_RESPONSE=$(docker run --rm --network zitadel curlimages/curl -s -X POST \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Host: SSO.DOMAIN" \
  -H "Content-Type: application/json" \
  "http://zitadel-api:8080/management/v1/projects/$PROJECT_ID/apps/oidc" \
  -d '{
    "name": "oauth2-proxy",
    "redirectUris": ["https://APP.DOMAIN/oauth2/callback"],
    "responseTypes": ["OIDC_RESPONSE_TYPE_CODE"],
    "grantTypes": ["OIDC_GRANT_TYPE_AUTHORIZATION_CODE", "OIDC_GRANT_TYPE_REFRESH_TOKEN"],
    "appType": "OIDC_APP_TYPE_WEB",
    "authMethodType": "OIDC_AUTH_METHOD_TYPE_BASIC",
    "postLogoutRedirectUris": ["https://APP.DOMAIN/"],
    "version": "OIDC_VERSION_1_0",
    "devMode": false,
    "accessTokenType": "OIDC_TOKEN_TYPE_BEARER"
  }')
OIDC_CLIENT_ID=$(echo "$APP_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['clientId'])")
OIDC_CLIENT_SECRET=$(echo "$APP_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['clientSecret'])")
```

### Phase 4: Deploy Forgejo + oauth2-proxy

#### 4.1 Create /opt/forgejo/.env

```bash
mkdir -p /opt/forgejo
cp <grape>/.env.example /opt/forgejo/.env   # then fill in the real values below

COOKIE_SECRET=$(docker run --rm python:3-alpine python3 -c "import secrets; print(secrets.token_urlsafe(32))")

# Fill /opt/forgejo/.env with:
#   OIDC_CLIENT_ID=${OIDC_CLIENT_ID}
#   OIDC_CLIENT_SECRET=${OIDC_CLIENT_SECRET}
#   OIDC_ISSUER=https://SSO.DOMAIN
#   COOKIE_SECRET=${COOKIE_SECRET}
# and the forgejo DB password (same value in two keys — see .env.example)

chmod 600 /opt/forgejo/.env
```

#### 4.2 Create /opt/forgejo/docker-compose.yml

Copy `docker-compose.yml` from this grape to `/opt/forgejo/docker-compose.yml`
(verbatim — verified oauth2-proxy args and Traefik routing to 4180 only).

#### 4.3 Key oauth2-proxy gotchas (from flagship experience)

1. `--scope=openid profile email` MUST be a SINGLE command-line arg (v7.8.1 ignores env scope)
2. `--upstream=http://forgejo:3000/` MUST be a command-line arg too
3. Forgejo itself is NOT exposed to Traefik — only oauth2-proxy is. This ensures "no app page without login"
4. All traffic to APP.DOMAIN hits oauth2-proxy first, which redirects to Zitadel if not authenticated

#### 4.4 Start Forgejo

```bash
cd /opt/forgejo
docker compose --env-file .env pull
docker compose --env-file .env up -d
```

### Phase 6: DNS-dependent steps

The following only work once DNS A records for SSO.DOMAIN and APP.DOMAIN point to SERVER_IP:

1. Let's Encrypt certificate provisioning (Traefik ACME HTTP challenge)
2. External browser access to the Zitadel admin console and Forgejo
3. oauth2-proxy OIDC discovery without `--ssl-insecure-skip-verify`

Until DNS resolves, oauth2-proxy needs `--ssl-insecure-skip-verify=true` and `extra_hosts` mapping `SSO.DOMAIN` to the Traefik gateway IP (typically 172.16.0.1 on the traefik Docker network). Once DNS resolves, remove both.

## Verify

### Check containers are healthy

```bash
docker ps --format "table {{.Names}}\t{{.Status}}"
# All containers should be Up (healthy)
```

### Check HTTPS redirects

```bash
# APP.DOMAIN should redirect to Zitadel login (302)
curl -sk -o /dev/null -w "%{http_code} %{redirect_url}" https://APP.DOMAIN/
# Expected: 302 https://SSO.DOMAIN/oauth/v2/authorize?...
```

### Browser login test (both users)

For each user, perform a real browser login:

1. Open `https://APP.DOMAIN/` in a browser
2. You should be redirected to `https://SSO.DOMAIN/ui/v2/login/login`
3. Enter the user's credentials
4. You should be redirected back to `https://APP.DOMAIN/` with a Forgejo session
5. Verify you can see the Forgejo dashboard (HTTP 200)

### API-based end-to-end test (if no browser available)

```bash
PAT=$(docker run --rm -v zitadel_zitadel-bootstrap:/bootstrap:ro alpine cat /bootstrap/login-client.pat)
USER_PASSWORD="<from SSO-credentials>"
COOKIE_JAR=/tmp/cookies.txt

# Step 1: Access app -> redirect to Zitadel
REDIRECT=$(curl -sk -c $COOKIE_JAR -o /dev/null -w "%{redirect_url}" https://APP.DOMAIN/)

# Step 2: Follow to Zitadel authorize
STEP2=$(curl -sk -c $COOKIE_JAR -b $COOKIE_JAR --resolve SSO.DOMAIN:443:<TRAEFIK_GATEWAY_IP> -o /dev/null -w "%{redirect_url}" "$REDIRECT")
AUTH_REQUEST_ID=$(echo "$STEP2" | grep -oP 'authRequest=\K[^&]+')

# Step 3: Create user session
SESSION=$(docker run --rm --network zitadel curlimages/curl -s -X POST \
  -H "Authorization: Bearer $PAT" \
  -H "Host: SSO.DOMAIN" \
  -H "Content-Type: application/json" \
  "http://zitadel-api:8080/v2/sessions" \
  -d "{\"checks\":{\"user\":{\"loginName\":\"user@example.com\"},\"password\":{\"password\":\"$USER_PASSWORD\"}}}")
SESSION_ID=$(echo "$SESSION" | python3 -c "import sys,json; print(json.load(sys.stdin)['sessionId'])")
SESSION_TOKEN=$(echo "$SESSION" | python3 -c "import sys,json; print(json.load(sys.stdin)['sessionToken'])")

# Step 4: Finalize OIDC auth request
FINALIZE=$(docker run --rm --network zitadel curlimages/curl -s -X POST \
  -H "Authorization: Bearer $PAT" \
  -H "Host: SSO.DOMAIN" \
  -H "Content-Type: application/json" \
  "http://zitadel-api:8080/v2/oidc/auth_requests/$AUTH_REQUEST_ID" \
  -d "{\"session\":{\"sessionId\":\"$SESSION_ID\",\"sessionToken\":\"$SESSION_TOKEN\"}}")
CALLBACK_URL=$(echo "$FINALIZE" | python3 -c "import sys,json; print(json.load(sys.stdin)['callbackUrl'])")

# Step 5: Follow callback (sets session cookie)
curl -sk -c $COOKIE_JAR -b $COOKIE_JAR -o /dev/null -w "%{http_code}" "$CALLBACK_URL"
# Expected: 302

# Step 6: Access app with session
curl -sk -b $COOKIE_JAR -o /dev/null -w "%{http_code}" https://APP.DOMAIN/
# Expected: 200
```

## Rollback

```bash
cd /opt/forgejo && docker compose down -v && rm -rf /opt/forgejo
cd /root && docker compose down -v && rm -f /root/.env /root/docker-compose.yml /root/SSO-credentials
# Traefik is untouched (external network); no other grapes are touched.
# Zitadel masterkey cannot be changed after initialization without losing
# encrypted data — down -v drops the volumes, so a re-install starts clean.
```

## Security notes

- `.env` and `SSO-credentials` files are mode 600, never committed to any repo
- Zitadel masterkey cannot be changed after initialization without losing encrypted data
- Forgejo is not directly exposed to Traefik — all access goes through oauth2-proxy
- Registration is disabled in Forgejo; all authentication is via Zitadel OIDC
- The Zitadel `login-client` machine user PAT is used for API automation; it has `IAM_LOGIN_CLIENT` role only
- Admin operations require an admin session token (created via the v2 sessions API with admin credentials)
