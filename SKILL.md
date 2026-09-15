---
name: vps-grapevine
description: >-
  Drive an autonomous coding agent that lives on a rented VPS, over plain SSH.
  Use this skill when the user asks to bootstrap an agent on a fresh box, or to
  send work to / read replies from a box that already runs the grapevine.
license: CC0-1.0
version: "1.0.0"
author: simbo1905
tags:
  - vps
  - grapevine
  - ssh
  - agent
  - mailbox
allowed-tools:
  - Bash
metadata:
  homepage: https://github.com/simbo1905/vps-grapevine
  source: https://github.com/simbo1905/vps-grapevine
---

# Skill: vps-grapevine

Drive an autonomous coding agent that lives on a rented VPS, over plain SSH.
Use this skill when the user asks to bootstrap an agent on a fresh box, or to
send work to / read replies from a box that already runs the grapevine.

## Vocabulary

- **client** — this side (your machine): `scripts/grapevine` + ssh
- **server** — the VPS: `vibed.service` daemon + `vibe -p` agent + mailbox
- **the agent** — the Mistral Vibe harness on the box (e.g. profile
  `box-manager`), pinned to one model for the whole box's life
- **the mailbox** — `/opt/vps-grapevine/mail/` (inbox.jsonl, outbox.jsonl,
  `inbox/{uuid}/files/`, `outbox/{uuid}/reply.md`)

## Prerequisites

- SSH root access to the VPS (password or key)
- On the box: Ubuntu 22.04/24.04 LTS, `uv` (snap or standalone), `tmux` is
  NOT required (headless by design), `docker` optional
- The Mistral Vibe CLI installed on the box (`uv tool install mistral-vibe`
  — npm does not carry it), with an API key configured once via `vibe --setup`
- Environment: `SRV_HOST` set (e.g. `root@srv012345.example.hstgr.cloud`)

## Bootstrap (cold VPS)

Run against a fresh box; the script is idempotent — safe to re-run:

    scripts/grapevine bootstrap

What it does on the box: installs nothing beyond what apt needs (curl, git),
creates `/opt/vps-grapevine/`, writes `server/vibe-bridge` there, installs
`vibed.service`, writes `/root/AGENTS.md` from
`server/AGENTS.md.template` (appending, never clobbering), installs the
Mistral Vibe CLI if missing (`uv tool install mistral-vibe`), creates the
agent profile TOML, runs the FIRST-RUN `vibe -p READY` (the daemon's
resume flags fail on a box with zero saved sessions), and starts the
daemon. It never reboots the box.

Then one-time: SSH in and run `vibe --setup` to store the agent API key, then
`vibe-bridge new-id && vibe-bridge post-message <uuid> <your-name> "hello"` —
the first dispatch creates the agent's pinned session.

## Exchanging messages

    scripts/grapevine send_message "text of the task" [--attach file ...]
    # → {"uuid": "...", "ts": "..."} — returns IMMEDIATELY

    scripts/grapevine check_messages [--after "<iso ts>"]
    # → {"now": ..., "inbox": [...], "outbox": [...]}
    #   outbox entries name the reply path to scp down, e.g.
    #   /opt/vps-grapevine/mail/outbox/{uuid}/reply.md

    scripts/grapevine scp-down <remote path> [local dir]
    scripts/grapevine status
    scripts/grapevine stop

Protocol rules (full spec: `server/BRIDGE-PROTOCOL.md`):

1. `send_message` returns immediately. Never block on the agent.
2. Attachments land in `inbox/{uuid}/files/` named server-side; reference
   them by path in your message text.
3. Poll with `check_messages --after <last ts you saw>`. Sleep between polls;
   big tasks take minutes.
4. The inbox/outbox may carry other clients' traffic — filter to your own
   lane (`from` == your client name) and never reply to other agents'
   messages.
5. Replies may be a file or a folder; the outbox `path` tells you which.
6. **Version protocol (mandatory).** Every message you send carries
   `_version` = the version you are running. `scripts/grapevine
   send_message` stamps it automatically from `git describe --tags` of this
   checkout; if you post via `vibe-bridge post-message` directly, pass
   `--version <ver>`. Every reply's `reply.md` MUST end with a line
   `[version] <ver>` — the version the box is running (its deployed
   `/opt/vps-grapevine/VERSION`). Always check it: missing or older than
   the release you are running means the box has not upgraded — tell the
   User. `vibe-bridge status` prints `version: …` for a quick check.
7. **Daemon restarts belong to the coordinator.** Never instruct the agent
   to `systemctl restart vibed` mid-task: the restart kills its own
   dispatch before the outbox line is written, and the daemon re-dispatches
   the same message forever. If a daemon restart is needed, ask the agent
   to write its reply first and note 'restart pending'.

## Rules the client must obey

- **Never raw tail or pipe.** Redirect to a clobber file and read it:
  `<command> 2>&1 | tee .tmp/clobber_me.txt` — recycle the same file; grep it on
  error instead of re-running.
- **Announce edits.** If you push/scp files to the box yourself, tell the
  agent ("FYI I have edited/pushed, please check and ack"). It pushes back
  only for material issues that conflict with other projects on that host.
- **No system surprises.** The agent owns the box day-to-day; system-level
  installs are its call and must be stated. You do not reboot it — it will
  say so if a reboot is needed.
- **Cloud-specific naming.** Anything provider-specific goes in a file named
  after the provider's DNS suffix (`hstgr-cloud.sh`), imported by generic
  scripts, so a box can move providers by regenerating that one file.
- **Agents never touch DNS.** Record creation/edits on the estate domain
  (ionos.de panel) are client-lane only; an agent asks the client in a reply
  and the client does the change. Every record change uses TTL=600s as a hard
  requirement (see server/SETUP-DEBIAN-TRIXIE.md); if a panel offers no 600
  option, ask the client — do not silently pick a different TTL.

## Leaving a box (offboarding)

When a rented box expires: stop the daemon, remove provider-specific files,
and encrypt every agent key/config with the user's chosen secret-encryption
tool (e.g. git-veil) so keys are never left plaintext on a dead box.
