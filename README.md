# vps-grapevine

Talk to an autonomous coding agent that lives on a VPS, over plain SSH —
no extra ports, no TUI scraping, no concurrency. The agent is a Mistral Vibe
harness (any model you configure it with) run headless by a systemd daemon
that owns a mailbox; your local CLI posts JSONL messages with attachments
into its inbox and polls its outbox for replies.

The name: messages vine out from your machine to boxes you rent, and each box
grows its own grape (agent) on the vine. One client, many vines.

```
your mac ──ssh:22──▶ VPS ──▶ vibed.service (flock-guarded daemon)
                              └─▶ vibe -p (serialized, stateful sessions)
                                    └─▶ /opt/vps-grapevine/mail/ (inbox/outbox)
```

## What is in this repo

| Path | Side | Purpose |
|---|---|---|
| `SKILL.md` | client | the installable skill: how to bootstrap a fresh VPS and exchange messages |
| `scripts/grapevine` | client | the CLI: `send_message` / `check_messages` / `status` / `stop`, over plain ssh |
| `server/vibe-bridge` | server | the daemon + mailbox script (uv PEP 723, stdlib only) |
| `server/BRIDGE-PROTOCOL.md` | server | the wire protocol spec |
| `server/AGENTS.md.template` | server | the box policy the agent runs under (you fill in your own conventions) |

This repo is a **template repository**: take a copy (do not fork), point
`SRV_HOST` at your box, and bootstrap.

## Design rules

- **SSH only.** Everything rides port 22. The daemon exposes nothing to the
  network; its unix socket is root-only.
- **One agent per box.** A flock + pidfile is the split-brain guard. The
  agent refuses to run twice, and refuses `vibe -p` from anything but the
  daemon.
- **Async mailbox, never blocking.** `send_message` returns a uuid +
  timestamp instantly; the agent works in the background; you poll
  `check_messages --after <ts>` for replies. Replies are files you scp down.
- **Stateful.** The daemon pins the agent's session id; every dispatch
  resumes it, so the agent accumulates box knowledge across messages.
- **Cloud-agnostic.** Anything specific to a hosting provider lives in files
  named after *that provider's DNS suffix* (e.g. `hstgr-cloud.sh`), never the
  marketing brand. The generic scripts never mention a provider.
- **Honest failure.** No hidden fallbacks, no fake results; if the daemon or
  the agent is down, the client says so.

## Releases

The `SKILL.md` is version-stamped and attached to every GitHub release.
To cut a release: `make tag` — it tags `YYYY.MM.DD-<short-sha>` (or
`YYYY.MM.DD-dirty` if the tree is not clean) and pushes; CI appends the
version footer to `SKILL.md` and attaches it to the release.

## Quick start

See `SKILL.md`.
