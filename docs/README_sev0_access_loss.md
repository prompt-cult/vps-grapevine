# Catastrophic Loss of Access (SEV0)

## Read this first

If you have lost SSH access to a VPS host (port 22 is unreachable), this is a
SEV0 incident. The only recovery path is through the cloud provider's web
console — a VNC/serial console that gives you direct access to the VM's
keyboard and screen, bypassing SSH entirely.

## How to recover

1. The laptop agent logs the user into the cloud provider's web console
   (the user must 2FA at the keyboard).
2. Navigate to the server in the cloud panel and open the web console.
   This typically opens a **new browser tab**.
3. The new tab will likely NOT be connected to any browser automation
   extension. The user must manually connect it (e.g. click the extension
   icon on the new tab).
4. **Pasting commands via browser automation is unlikely to work** because
   web consoles use WebSocket/VNC protocols that do not accept synthetic
   keyboard events reliably. The laptop agent should instead **tell the user
   the exact commands to type** into the web console.
5. The user types the commands manually to restore access.

## Commands to restore SSH access

If nftables dropped port 22, the recovery commands are:

```bash
# Check if nftables is blocking SSH
nft list ruleset | grep -A5 "chain input"

# If port 22 is missing, add it back
nft add rule inet vps_grapevine_filter input "tcp dport 22 accept comment ssh"

# If the filter table was flushed, reload from the saved config
nft -f /etc/nftables.conf

# Verify SSH is listening
ss -tlnp | grep :22

# If sshd is not running, start it
systemctl start sshd
```

## Prevention

- Never flush firewall tables. Always add rules additively.
- Always take a dated backup before any firewall edit.
- Always verify SSH still works after every firewall change.
- If a firewall change breaks SSH, the only recovery is the web console.
- See `docs/README_nftables_safety.md` for the full safety rules.

## Cloud firewall note

Before assuming the host firewall is the problem, check the cloud provider's
firewall policy (external hardware firewall). If the cloud firewall dropped
port 22, no amount of host-level fixing will help. See
`docs/README_cloud_firewall.md` for guidance.
