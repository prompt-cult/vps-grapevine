# vps-grapevine

Run opencode on a rented VPS (or anything that is Linux) and drive it from your laptop over an SSH
tunnel—the service binds to loopback only, so nothing new faces the internet, and nftables drop as belt-and-braces.

```
your mac ──ssh:22──▶ VPS ──▶ opencode-serve.service (127.0.0.1:4096)
        ◀── forwarded 4096 ──┘   opencode attach http://127.0.0.1:4096
```

The idea is to use the stock cloud image with the stock cloud firewall and basic backups, plus security updates and nearby affordances like weekly backups. If you want old-school EC2 or bare metal, do you! 

On top of that, we have vines and grapes for setting up Traefik and Docker Compose.  

The idea here is that all the user-facing code is in docker. The underlying box is only visible over port 22. The host has no userland. This means I use old-school big-boys rules to run as root. That relies upon backups. 

## Official install path

1. **Install opencode from the release page** of the opencode site.
   Never pipe the installer into a shell
   (`curl -fsSL https://opencode.ai/install | bash` is too dangerous).
2. **Auth on the CLI (v2):**

       opencode auth login opencode

   The v1 command `opencode console login` did not work — use the v2
   command above. Then run `/models` and select a model.

   You **must** set up quota and keys, ideally a key per host and the like, to ensure it does not eat your wallet. 

## Box setup (after installing opencode)

The unit lives at locations such as `server/opencode-serve.service.ubuntu` which is a service to run 
`opencode serve` to bind websockets to localhost. Install it on
the box (root):

    install -m 644 opencode-serve.service.${distro} /etc/systemd/system/opencode-serve.service
    systemctl daemon-reload
    systemctl enable --now opencode-serve.service

Note that means it starts by default; if you want to turn that off on prod, you can. 

It binds `127.0.0.1:4096` only — nothing on the public interface; configure any 
cloud firewall for openssl letsencrypt on 22/80/443, and nothing else opens. Auth is direct
(v2 auth above); no proxy legs, no daemon, no ACP.

## Attach from your laptop

Terminal 1 (tunnel):

    ssh -N -L 4096:127.0.0.1:4096 root@<box-host>

Terminal 2 (console):

    opencode attach http://127.0.0.1:4096

Sessions persist server-side in the opencode db, so reconnect + attach
resumes. Run `opencode attach --mini` for a minimal interface.

## What is in this repo

| Path | Purpose |
|---|---|
| `server/opencode-serve.service.ubuntu` | the systemd unit (loopback-only headless serve) |
| `server/SETUP-NOTES.md.secret` | private runbook via git-veil (reveal with git-veil) |
| `grapes/` | containers living on the boxes: Forgejo, Traefik, Zitadel, OpenResty sidecar |
| `server/nftables/` | firewall configs for the boxes |
| `docs/` | estate runbooks: DNS segregation, cloud firewall, SEV0 access loss, box policy templates |

## Releases

Tags are immutable, releases are disposable. No release is cut for
config changes.
