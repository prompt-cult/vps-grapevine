# DNS Management — Segregation of Duties

## Core Principle

DNS management is protected by 2FA that is NOT on any vps-grapevine host.
The user's laptop agent opens the DNS provider in the user's browser for the
user to 2FA in, and the user watches while the laptop agent makes additive,
safe changes to DNS records.

This is a **core segregation of duties**: if one VPS is compromised, it does
not have the ability to hijack the user's domain. No VPS host has DNS provider
credentials. No VPS host can change DNS records. Only the user's laptop,
with the user present to 2FA, can make DNS changes.

## How It Works

```
VPS agent needs DNS change
        |
        v
VPS agent posts DNS request to outbox
        |
        v
Laptop agent reads outbox, opens DNS provider in browser
        |
        v
User 2FAs in at the keyboard
        |
        v
Laptop agent makes additive DNS change with user watching
        |
        v
Laptop agent confirms change in reply to VPS agent
```

## Rules

1. **No VPS host stores DNS provider credentials.** Not in .env, not in
   memory, not anywhere. DNS credentials live only on the user's laptop
   behind 2FA.

2. **All DNS changes are additive.** Add new records; do not delete or
   modify existing records unless explicitly required. If a record must
   change, add the new record first, verify it resolves, then remove the
   old one — never delete blindly.

3. **The user must be at the keyboard to 2FA.** The laptop agent opens the
   DNS provider page in the user's browser. The user authenticates with 2FA.
   The laptop agent then makes the change with the user watching.

4. **VPS agents request DNS changes via the outbox.** When a VPS agent needs
   a DNS change, it posts a request to its outbox in the format:
   ```
   DNS ACTION NEEDED: <add|edit|delete> <record-type> <hostname> -> <value> (TTL <seconds>)
   ```
   The laptop agent reads the outbox and executes the change.

5. **Documentation is uploaded to all VPS servers.** The laptop agent should
   have a document with the DNS provider's navigation steps (how to log in,
   how to reach the DNS records page, how to add/edit records). This
   documentation should be tested and verified. A copy should be uploaded to
   all VPS servers so they know the process and can include the correct
   details in their outbox requests.

6. **The DNS provider is never named in public repos.** The vps-grapevine
   repo is public. Documentation in this repo must not name the DNS provider,
   leak account details, or expose the user's domains. Provider-specific
   navigation instructions live only on the user's laptop and on the VPS
   hosts (in private docs, not in the public repo).

## What VPS Agents Should Do

1. Read this document (`docs/README_dns.md`) on first boot.
2. Store a copy in `/root/docs/` or equivalent.
3. When a DNS change is needed, post the request to the outbox with the
   exact record details (hostname, type, value, TTL).
4. Wait for the laptop agent to confirm the change in the outbox reply.
5. Never attempt to access the DNS provider directly.

## What the Laptop Agent Should Do

1. Read this document to understand the segregation of duties.
2. Maintain a private document with the DNS provider's navigation steps
   (login URL, how to reach DNS records, how to add/edit).
3. When a DNS request appears in a VPS outbox, open the DNS provider in
   the user's browser, let the user 2FA, make the change, and confirm.
4. Upload the navigation documentation to all VPS hosts so they can
   include accurate details in future requests.
5. All changes must be additive and verified (dig/nslookup after change).
