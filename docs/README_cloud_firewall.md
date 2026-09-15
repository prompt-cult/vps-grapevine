# Cloud Firewall Policies

Most cloud VPS providers sit all servers behind an external hardware firewall
at the infrastructure layer. This is separate from the host's own firewall
(nftables/iptables) and operates before traffic ever reaches the VM.

## Two layers of firewall

1. **Cloud firewall** (infrastructure layer) — controlled via the cloud
   provider's web panel. Filters incoming traffic before it reaches the VM.
   If this blocks a port, no host-level configuration can unblock it.

2. **Host firewall** (nftables) — controlled on the VM itself.
   Filters traffic that has already passed the cloud firewall.

Both layers must allow a port for traffic to reach a service. If either
layer blocks it, the service is unreachable.

## Typical default ports

When a VPS is provisioned with a control panel (e.g. Plesk), the cloud
firewall policy typically opens these ports by default:

| Port | Protocol | Service |
|---|---|---|
| 22 | TCP | SSH |
| 80 | TCP | HTTP |
| 443 | TCP | HTTPS |
| 8443 | TCP | Plesk control panel (HTTPS) |
| 8447 | TCP | Plesc auto-update / agent |
| 20, 21 | TCP | FTP |
| 25 | TCP | SMTP (often blocked by provider, requires support call) |
| 465, 587 | TCP | SMTPS / SMTP submission |
| 110, 995 | TCP | POP3 / POP3S |
| 143, 993 | TCP | IMAP / IMAPS |
| 53 | TCP/UDP | DNS |
| 3306 | TCP | MySQL (often not exposed) |
| 5432 | TCP | PostgreSQL (often not exposed) |

## Locking down: drop control panel ports

If you are not using the control panel (e.g. you removed Plesk or never
installed it), the Plesk ports (8443, 8447) should be closed. Leaving them
open exposes unused services to the internet.

Create a new cloud firewall policy with only the ports you need. For a
typical Traefik-based setup:

| Port | Protocol | Purpose |
|---|---|---|
| 22 | TCP | SSH |
| 80 | TCP | HTTP (Let's Encrypt HTTP-01 challenge + redirect to HTTPS) |
| 443 | TCP | HTTPS (Traefik TLS) |

That is the correct minimal set. Drop 8443, 8447, FTP, mail ports, and
database ports unless you have a specific reason to keep them open.

## Why keep port 80 open

Port 80 is needed for two things even when all traffic is HTTPS:

1. **Let's Encrypt HTTP-01 challenges.** Traefik's default ACME challenge
   type connects to `http://yourdomain/.well-known/acme-challenge/...` on
   port 80 to validate domain ownership. If port 80 is blocked, cert
   issuance and renewals fail. Renewals happen every ~60 days.

2. **HTTP to HTTPS redirects.** Visitors typing `yourdomain.com` or
   clicking an `http://` link land on port 80 first. Traefik issues a
   permanent redirect to HTTPS. No content is served insecurely.

Closing port 80 is only viable if you switch to TLS-ALPN-01 or DNS challenge
for ACME, and you accept that plain HTTP requests time out instead of
redirecting. For most setups, keep port 80 open.

## Loss of access checklist

If a service or SSH is unreachable, check in this order:

1. **Is the VM running?** Check the cloud panel — is the server status
   green/running? If not, start or restart it from the cloud panel.

2. **Does the cloud firewall allow the port?** Check the cloud firewall
   policy assigned to this server. Are the needed ports (22, 80, 443)
   listed and active? If the policy was removed or changed, traffic is
   blocked at the infrastructure layer.

3. **Does the host firewall allow the port?** SSH in (if possible) and
   check nftables. If SSH is also blocked, use the web console
   (see `docs/README_sev0_access_loss.md`).

4. **Is the service listening?** Check with `ss -tlnp | grep <port>` on
   the host. If nothing is listening, the service is down.

5. **Is Docker/Podman port mapping correct?** Check `docker ps` or
   `podman ps` for the port mapping. A mismatch between the container's
   listening port and the published port will cause connection refused.

## Testing cloud firewall changes

When changing the cloud firewall policy:

1. Before the change, verify the port you are about to close is currently
   reachable (curl from outside).
2. Apply the new policy.
3. Verify the closed port is now unreachable (curl should fail).
4. Verify the open ports still work (SSH, HTTP, HTTPS).
5. If something breaks, revert to the previous policy immediately.
