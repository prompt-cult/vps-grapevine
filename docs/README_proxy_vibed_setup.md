# Proxy Router + vibed Setup (MDD)

This is the Markdown-Driven Development desired-state doc. A box reads
this, compares against its current state, and self-migrates. Estate
specifics (IPs, keys, host labels) are in the git-veil canary file, not
here.

## 1. Proxy router (codex-proxy-router)

### Install binaries

```bash
# Download the release tarball for the box arch from the codex repo
# https://github.com/prompt-cult/codex/releases
# Verify sha256 against the release notes before installing
curl -L -o /tmp/codex-proxies-linux-x64.tar.gz <release-url>
sha256sum /tmp/codex-proxies-linux-x64.tar.gz   # must match published digest
tar -xzf /tmp/codex-proxies-linux-x64.tar.gz
install -m755 codex-proxy-router codex-mistral-proxy codex-opencode-proxy /usr/local/bin/
```

### Configure OpenCode proxy for Go endpoint

```bash
mkdir -p ~/.codex
cat > ~/.codex/proxy-opencode-zen.jsonc << 'EOF'
{
  // Route to the Go (open) endpoint for free models like glm-5.3-flash
  "upstream_base_url": "https://opencode.ai/zen/go/v1"
}
EOF
```

### Create the env file

```bash
# /root/.secrets/proxy-router.env (mode 600)
# Contains MISTRAL_API_KEY and OPENCODE_API_KEY
# The router sanitizes child env to an allow-list; keys never touch the harness
mkdir -p /root/.secrets
cat > /root/.secrets/proxy-router.env << EOF
MISTRAL_API_KEY=<mistral-key>
OPENCODE_API_KEY=<opencode-key>
EOF
chmod 600 /root/.secrets/proxy-router.env
```

### Create systemd service

```ini
# /etc/systemd/system/codex-proxy-router.service
[Unit]
Description=codex-proxy-router: loopback routing proxy for Mistral + OpenCode
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/codex-proxy-router --port 9090 --http-shutdown
Restart=on-failure
RestartSec=5
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
EnvironmentFile=/root/.secrets/proxy-router.env
RuntimeDirectory=codex-proxy

[Install]
WantedBy=multi-user.target
```

```bash
systemctl daemon-reload
systemctl enable --now codex-proxy-router
```

### Verify

```bash
curl -s http://127.0.0.1:9090/health | python3 -m json.tool
# Expect: status ok, two backends (opencode.ai, mistral.ai)

# Mistral chat
curl -s -X POST http://127.0.0.1:9090/mistral.ai/v1/responses \
  -H "Content-Type: application/json" \
  -d '{"model":"mistral-small-latest","input":[{"role":"user","content":[{"type":"input_text","text":"Reply with exactly: pong"}]}]}'

# OpenCode chat
curl -s -X POST http://127.0.0.1:9090/opencode.ai/v1/responses \
  -H "Content-Type: application/json" \
  -d '{"model":"glm-5.3-flash","input":[{"role":"user","content":[{"type":"input_text","text":"Reply with exactly: pong"}]}]}'
```

## 2. Vibe config (keyless harness)

The harness carries NO API key. All requests go through the proxy router.

```toml
# ~/.vibe/config.toml

active_model = "glm-5.3-flash"

[[providers]]
name = "oc-go"
api_base = "http://127.0.0.1:9090/opencode.ai/v1"
api_key_env_var = ""
api_style = "openai-responses"
backend = "generic"

[[providers]]
name = "mistral-proxy"
api_base = "http://127.0.0.1:9090/mistral.ai/v1"
api_key_env_var = ""
api_style = "openai-responses"
backend = "generic"

# Default: fast and cheap via OpenCode Go
[[models]]
name = "glm-5.3-flash"
provider = "oc-go"
thinking = "off"
auto_compact_threshold = 900000

compaction_model = { name = "glm-5.2", provider = "oc-go", alias = "compact-glm52", thinking = "off" }

# Thinker: large model via Mistral proxy
[[models]]
name = "mistral-large-latest"
provider = "mistral-proxy"
thinking = "off"
auto_compact_threshold = 900000

# Scout: small model for harness tests
[[models]]
name = "mistral-small-latest"
provider = "mistral-proxy"
thinking = "off"
auto_compact_threshold = 900000
```

### Verify

```bash
# Keyless: both API key env vars unset, vibe talks through the proxy
env -u MISTRAL_API_KEY -u OPENCODE_API_KEY vibe -p "Reply with exactly: pong keyless"
# Check for fallback warnings (must be empty)
grep -r "falling back" ~/.vibe/logs/session/unified/*/journal/ 2>/dev/null
```

## 3. total-recall MCP

```bash
# Download from https://github.com/prompt-cult/total-recall/releases
# Verify sha256, install
install -m755 total-recall-linux-x86_64 /usr/local/bin/total-recall

# Wire into vibe as MCP server
vibe mcp add total-recall --transport stdio \
  --command /usr/local/bin/total-recall --arg=mcp --arg=--harness --arg=vibe
```

### Verify

```bash
total-recall --harness vibe list
env -u MISTRAL_API_KEY -u OPENCODE_API_KEY vibe --auto-approve -p \
  "Use the total-recall MCP to list recent vibe sessions. Reply with the count."
```

## 4. vibed (Rust persistent ACP harness)

### Install binaries

```bash
# From the vps-grapevine release (same date tag as the skill)
# Verify sha256 against release notes
install -m755 vibed vibed-cli /usr/local/bin/
```

### Install service

```ini
# /etc/systemd/system/vibed.service
[Unit]
Description=vibed
[Service]
ExecStart=/usr/local/bin/vibed
Restart=always
RestartSec=5
Environment=TERM=dumb
Environment=VIBED_STATE=/var/lib/vibed/session_id
Environment=VIBED_SOCK=/run/vibed/vibed.sock
Environment=VIBED_LOCK=/run/vibed/vibed.lock
RuntimeDirectory=vibed
[Install]
WantedBy=multi-user.target
```

### Mint and pin the session (FIRST-RUN only)

```bash
# Mint a session (resume flags fail on a box with zero saved sessions)
echo 'remember this box' | vibe -p

# Find the newest session id by STORE MTIME (not alphabetical)
ls -lt ~/.vibe/logs/session/unified/ | head -3

# Pin it
install -d /var/lib/vibed
echo -n '<session-id>' > /var/lib/vibed/session_id
```

### Install the vibe shim

The shim intercepts `--resume <pinned-id>` and forwards to `vibed-cli`
over the socket. It refuses if vibed is down — never falls back to a
direct resume. See `server/VIBED-ACP.md` (git commit 3f23be6) for the
full shim law and acceptance suite.

```bash
# Install the shim where PATH finds it before the real vibe
# The real vibe is at /root/.local/share/uv/tools/mistral-vibe/bin/vibe
# Put the shim at /root/.local/bin/vibe (or wherever PATH finds it first)
install -m755 vibe-shim /root/.local/bin/vibe
```

### Cutover

```bash
# Stop the old Python vibed (if running)
systemctl stop vibed  # old service
systemctl disable vibed

# Install and start the new rust vibed
systemctl daemon-reload
systemctl enable --now vibed

# Verify
journalctl -u vibed -n 20   # expect: session/load ok / session ready
vibed-cli status             # {"ok":true,"up":true,"session":"..."}
```

### Acceptance (run on every release before cutover)

All against a THROWAWAY session id, never the pinned one:

1. **Pin refusal.** Garbage id in state -> daemon exits 3, stderr has
   `PIN_LOST`, `session_id.*.bak` exists, state file unchanged.
2. **Lock-free status.** Long push in flight -> `vibed-cli status` replies
   in <1s with `busy:true`.
3. **Child kill regression.** `kill -9` the vibe-acp child -> status
   reports `up:false, restarts:1` -> respawn -> `session/load` restores
   the SAME id -> push -> `end_turn`.
4. **Cross-process recall.** Mint session with `vibe -p`, load via vibed,
   ask what the earlier instruction was -> reply must quote it exactly.
5. **Flock.** Start a second vibed -> exits 1 immediately; first untouched.

## 5. Self-migration (MDD)

A box that receives "check new desired state and self-migrate":

1. `git pull` the vps-grapevine repo.
2. Read this doc and the SKILL.md laws.
3. Read the git-veil canary for estate specifics (host inventory, keys).
4. Diff current state against desired state.
5. Apply missing pieces (proxy, vibe config, total-recall, vibed, shim).
6. Run the acceptance suite.
7. Report what changed and what remains.
