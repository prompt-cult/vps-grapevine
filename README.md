# vps-grapevine

Run opencode on a rented VPS and drive it from your mac over a plain SSH
tunnel — the service binds loopback only, so nothing new faces the
internet.

```
your mac ──ssh:22──▶ VPS ──▶ opencode-serve.service (127.0.0.1:4096)
        ◀── forwarded 4096 ──┘   opencode attach http://127.0.0.1:4096
```

## Official install path

1. **Install opencode from the release page** of the opencode site.
   Never pipe the installer into a shell
   (`curl -fsSL https://opencode.ai/install | bash` is too dangerous).
2. **Auth on the CLI (v2):**

       opencode auth login opencode

   The v1 command `opencode console login` did not work — use the v2
   command above. Then run `/models` and select a model.

## Box setup (after installing opencode)

The unit lives at `server/opencode-serve.service.ubuntu`. Install it on
the box (root):

    install -m 644 opencode-serve.service.ubuntu /etc/systemd/system/opencode-serve.service
    systemctl daemon-reload
    systemctl enable --now opencode-serve.service

It binds `127.0.0.1:4096` only — nothing on the public interface; the
cloud firewall keeps 22/80/443 and nothing else opens. Auth is direct
(v2 auth above); no proxy legs, no daemon, no ACP.

## Attach from the mac

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
