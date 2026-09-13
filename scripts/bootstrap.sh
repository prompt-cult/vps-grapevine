#!/usr/bin/env bash
# vps-grapevine server-side bootstrap (run ON the fresh box, as root).
#
# Usage:
#   bash bootstrap.sh '<presigned-env-bundle-url>' [tag]
#
# $1: presigned (mc share download --expire 1h) URL of the encrypted env
#     bundle (env/bundle.tar.gz.age or .gpg). See server/BOOTSTRAP.md.
# $2: optional repo tag (default v0.2.0), or VPS_GRAPEVINE_TAG env var.
#
# Idempotent; never reboots the box. Decrypts the env bundle only in a
# temporary file which is wiped (shred) before this script exits.

set -euo pipefail

ENV_BUNDLE_URL="${1:?usage: bash bootstrap.sh '<presigned-env-bundle-url>' [tag]}"
TAG="${2:-${VPS_GRAPEVINE_TAG:-v0.2.0}}"
ROOT=/opt/vps-grapevine
GITHUB_ZIP="https://github.com/simbo1905/vps-grapevine/archive/refs/tags/${TAG}.zip"
BUCKET_ZIP="${VPS_GRAPEVINE_BUCKET_ZIP_URL:-}"

TMP=$(mktemp -d /tmp/vps-grapevine-bootstrap.XXXXXX)
trap 'find "$TMP" -type f -exec shred -u {} + 2>/dev/null || rm -f "$TMP"/*; rmdir "$TMP" 2>/dev/null || true' EXIT

echo "bootstrap.sh: repo kit -> ${ROOT} (tag ${TAG})"

# --- 0. packages needed below (idempotent; unzip+age are NOT in the base image)
apt-get update -qq && apt-get install -y -qq curl git unzip age gpg >/dev/null

# --- 1. fetch + unpack the repo zip (GitHub first, bucket fallback) ----------
if [ -n "$BUCKET_ZIP_URL" ]; then
  curl -fsSL -o "$TMP/repo.zip" "$BUCKET_ZIP_URL" \
    || curl -fsSL -o "$TMP/repo.zip" "$GITHUB_ZIP"
else
  curl -fsSL -o "$TMP/repo.zip" "$GITHUB_ZIP"
fi
mkdir -p "$TMP/unpack"
unzip -q "$TMP/repo.zip" -d "$TMP/unpack"
SRC=$(find "$TMP/unpack" -maxdepth 1 -mindepth 1 -type d | head -1)

mkdir -p "$ROOT" "$ROOT/mail/inbox" "$ROOT/mail/outbox" "$ROOT/drop-in"
install -m 755 "$SRC/server/vibe-bridge" "$ROOT/vibe-bridge"
install -m 644 "$SRC/server/BRIDGE-PROTOCOL.md" "$ROOT/BRIDGE-PROTOCOL.md"
install -m 644 "$SRC/server/AGENTS.md.template" "$ROOT/AGENTS.md.template"

# --- 2. env bundle: fetch, decrypt, install .env (mode 600) -----------------
echo "bootstrap.sh: fetching encrypted env bundle"
curl -fsSL -o "$TMP/bundle.enc" "$ENV_BUNDLE_URL"
chmod 600 "$TMP/bundle.enc"
if [ -f /root/age-identity.txt ]; then
  age --decrypt -i /root/age-identity.txt -o "$TMP/env.tar.gz" "$TMP/bundle.enc"
else
  echo "bootstrap.sh: no /root/age-identity.txt — using gpg symmetric (passphrase prompt)"
  gpg --decrypt --output "$TMP/env.tar.gz" "$TMP/bundle.enc"
fi
tar xzf "$TMP/env.tar.gz" -C "$TMP"
ENVFILE=$(find "$TMP" -maxdepth 2 -name '.env' -type f | head -1)
[ -n "$ENVFILE" ] || { echo "bootstrap.sh: no .env inside the bundle" >&2; exit 1; }
install -m 600 "$ENVFILE" "$ROOT/.env"
echo "bootstrap.sh: .env installed at ${ROOT}/.env (mode 600; temporaries wiped)"

# --- 3. agent kit (mirrors `scripts/grapevine bootstrap` server-side steps) --
[ -x /root/.local/bin/vibe ] || bash -lc 'npm i -g mistral-vibe' >/dev/null 2>&1 || true
touch /var/log/vps-grapevine.log
mkdir -p /root/.vibe/agents
cat > /root/.vibe/agents/box-manager.toml <<'TOMLEOF'
description = "Box agent managed by the vps-grapevine daemon"
TOMLEOF
grep -q '# Box policy for the box-manager' /root/AGENTS.md 2>/dev/null \
  || cat "$ROOT/AGENTS.md.template" >> /root/AGENTS.md

# --- 4. systemd unit ---------------------------------------------------------
cat > /etc/systemd/system/vibed.service <<'UNIT'
[Unit]
Description=vps-grapevine: box-manager vibe agent daemon (headless)
Documentation=file:///opt/vps-grapevine/vibe-bridge
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=/opt/vps-grapevine/vibe-bridge serve
ExecStop=/opt/vps-grapevine/vibe-bridge stop
Restart=on-failure
RestartSec=5
Environment=PATH=/snap/bin:/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable vibed >/dev/null 2>&1 || true

# --- 5. first run + start ----------------------------------------------------
if ! ls /root/.vibe/logs/session/.session_index.json >/dev/null 2>&1; then
  /root/.local/bin/vibe -p READY --yolo --agent box-manager --trust >/dev/null 2>&1 || true
fi
systemctl restart vibed
sleep 2
systemctl is-active vibed

echo "bootstrap.sh done: ${ROOT} + vibed.service (run 'vibe --setup' once for the agent key)"
