---
name: vps-grapevine
description: >-
  Drive an autonomous coding agent on a VPS, over plain SSH. Use this skill
  when the user asks to bootstrap an agent on a fresh box, or to send work
  to / read replies from a box that already runs the grapevine.
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

# vps-grapevine

## Vocabulary

- **client** — this side (your machine): `scripts/grapevine` + ssh
- **server** — the VPS: `vibed.service` daemon + `vibe -p` agent + mailbox
- **the agent** — the Mistral Vibe harness on the box (e.g. profile
  `box-manager`), pinned to one model for the whole box's life
- **the mailbox** — `/opt/vps-grapevine/mail/` (inbox.jsonl, outbox.jsonl,
  `inbox/{uuid}/files/`, `outbox/{uuid}/reply.md`)

## Prerequisites

- SSH root access to the VPS (password or key)
- On the box: a Debian-family OS with `apt`; `uv` (snap or standalone);
  `docker` optional
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
- **DNS is client-lane.** Record creation/edits on the estate domain
  (ionos.de panel) are done by the client — which may drive the panel via
  browser automation under the user's own login (never entering credentials
  itself); an agent asks the client in a reply.
- **TTL law: 60 seconds on every record, no exceptions.** A low TTL means a
  wrong record fails fast and is fixed within a minute; a long TTL lets an
  error sit in caches and blow legs off long after the mistake. If a panel
  offers no 60 option, ask the client — do not silently pick a higher TTL.
- **Cross-check rule.** If any agent edited DNS, the other agents must verify
  the records afterwards: an isolated edit nobody re-checked is presumed
  wrong until confirmed.
- **Touch-then-verify rule.** Whoever touches DNS sleeps 60, then re-reads
  every record they set and checks the services resolve and answer. A change
  is not done until the 60-second re-check passes.

## Secrecy law (git-veil)

- **Nothing confidential enters git unsealed.** No IPs, provider hostnames,
  keys, or estate details in any committed file — only git-veil ciphertext
  (`.secret`) is committed; the plaintext names are gitignored. A violation
  is purged from history (filter-repo) and anything exposed is rotated.
- **Every box runs one age identity**, named `<host-label>@<domain>`
  (e.g. `vps01@example.com` for the box `vps01.example.com`): the identity
  names the box's single root security context. Model profiles
  (thinking/fast/…) are dispatch config, never age identities. A scoped
  identity `consult+tag@<fqdn>` / `act+tag@<fqdn>` is only created when a
  box gains a genuinely separate security context (separate OS user,
  rootless container, read-only consult agent). The `AGE-SECRET-KEY` never
  leaves its box (0600) and never travels the mailbox; only the `age1`
  public recipient is sent, and it must be signed into `.git-veil/keyring`
  (each machine pins trust with the committed `owner.verifying`).
- **Canary proof.** The repo carries `.git-veil-canary.txt.secret`. An
  agent's key setup is not done until `git-veil cat .git-veil-canary.txt`
  succeeds on its box and it reports the canary content back.
- **Inventories and setup docs are sealed files** (git-veil tracked). To
  work on them: `reveal`, edit, `hide`, commit only the ciphertext.

## Tag law (releases)

- **Tags are immutable history. You never delete a tag — you bump.** A new
  state on `main` is a new tag (`<YYYY.MM.DD>-<short-sha>` on the merged
  head). Deleting a tag rewrites history that `git describe --tags` has
  already stamped into versioned messages and deployed `VERSION` files;
  a deleted tag can never be recalled reliably once anyone fetched.
- **Release objects are disposable.** Exactly one release exists at a
  time, marked Latest, on the newest tag. When you release again, kill
  the old release objects — the tags they pointed at stay forever.

## Tooling law (estate tools)

We are vps-grapevine; this section binds the estate, not the tools.

- **Prebuilt tagged releases only.** Estate tools (git-veil,
  total-recall, the codex proxies, …) are installed on a box as the
  prebuilt binary from the tool's tagged GitHub release
  (`gh release download <tag> --pattern '*linux-x86_64*'` and friends) —
  never built from source on a box. Source builds are the upstream
  projects' business; a box that compiles its own tools has silently
  diverged. (Compiling is for developing the tool itself, in its own
  checkout, on a dev box.)
- **Boxes stay in sync.** Every box runs the same tagged release of each
  estate tool. `--version` on any box must name the current release tag;
  a mismatch is a bug on that box — upgrade it to the tag, do not
  downgrade the estate.
- **We document here.** The estate's habits are recorded in this repo
  and never pushed onto the upstream tools' own docs — the tools are
  agnostic; vps-grapevine is where "we" is defined.

## Leaving a box (offboarding)

When a box leaves the estate: stop the daemon, remove provider-specific files,
and encrypt every agent key/config with the user's chosen secret-encryption
tool (e.g. git-veil) so keys are never left plaintext on a dead box.
