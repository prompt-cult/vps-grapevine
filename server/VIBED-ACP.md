# vibed — the persistent ACP harness (new transport, same mailbox law)

Status: release `2026-09-21-2` audited green on prod (vps0). The old
one-shot harness (Python `vibe-bridge` dispatch spawning
`vibe -p --resume` per message) is tagged `2026.09.21-595d76a`. This
document is the setup and operating law for its replacement.

## Architecture — three layers, one owner per session

    scripts/grapevine (client, SSH)          — unchanged
        └── vibe-bridge (mailbox front)      — keeps inbox/outbox law
                └── vibed (Rust daemon)      — transport + supervision
                        └── vibe-acp (stock) — the agent itself

- **vibe-bridge stays** as the mailbox front: it drains `inbox.jsonl`,
  wraps the message with the dispatch instructions (reply.md path,
  `[version]` footer), pushes it, and the agent writes its own
  `outbox/<uuid>/reply.md` with its file tools during the turn. The
  bridge's ONLY change is dispatch: `subprocess.run(vibe -p --resume …)`
  becomes `vibed-cli push <text>` over the unix socket.
- **vibed** owns the child: spawns stock `vibe-acp` (bare name from
  PATH — never downloaded, patched, or forked), handshakes, and holds
  ONE session id, persisted on disk.
- **No second opener ever.** Exactly one process may have the pinned
  session open. vibed is that process (flock-guarded); everyone else
  talks to it through the socket. The old crash class — concurrent or
  repeated resume of one session, and cold one-shot processes that
  cannot compact — is structurally gone.

## The durable session — what "memory" actually is

Two artifacts, nothing else:

1. The pinned session id in `VIBED_STATE` (default
   `/var/lib/vibed/session_id`, unit file sets it explicitly).
2. The vibe session store on disk (unified store; every turn is
   persisted as it happens, compaction is internal and keeps the id).

On boot vibed runs `initialize` → `session/load <pinned id>`. Proven in
audit: a session minted by `vibe -p`, later loaded by a separate
vibe-acp child, recalled the exact earlier instruction across process
death. The daemon never needs to know about compaction — load, push,
persist the id, that is the whole job.

Note: `vibe-acp` injects a `"Say ok"` / `"Ok"` health-probe turn at
every `session/load`. Miners and recall tooling must ignore probe
turns.

## Install law (pinned release, verified)

    # 1. fetch the release asset for the box arch and CHECK the sha256
    #    against the release notes before installing (grape law).
    curl -LO <release tarball url>
    sha256sum <tarball>            # must match the published digest
    tar -xzf <tarball>             # → vibed, vibed-cli
    install -m755 vibed vibed-cli /usr/local/bin/

    # 2. unit (repo: vibed/vibed.service) — sock/lock live under
    #    RuntimeDirectory=/run/vibed, state at /var/lib/vibed/session_id.
    install -m644 vibed/vibed.service /etc/systemd/system/vibed.service
    systemctl daemon-reload

    # 3. mint the session (FIRST-RUN only — resume flags fail on a box
    #    with zero saved sessions):
    echo 'remember this box' | vibe -p
    # find the newest session id by STORE MTIME — the unified-store
    # index is sorted alphabetically, entries[-1] is NOT the newest.
    install -d /var/lib/vibed
    echo -n '<session id>' > /var/lib/vibed/session_id

    # 4. start; verify boot handshake in the journal
    systemctl enable --now vibed
    journalctl -u vibed -n 20      # expect: session/load ok / session ready
    vibed-cli status                # {"ok":true,"up":true,"session":"…"}

Naming collision warning: the OLD Python bridge unit was also called
`vibed.service` on some boxes (`server/vibed.service.debian`). Disable
and remove the old unit at cutover, or the two will fight over
`/run/vibed` paths.

## PIN_LOST — losing the pin is a loud failure

If `session/load` fails (store wiped, corrupt, wrong HOME), vibed:
writes `session_id.<old id>.bak`, leaves `session_id` UNCHANGED, prints
`PIN_LOST: …` and exits 3. It never boots a blank session over a lost
one. Human ack procedure: find why the store lost the entry (restore
from backup if needed), fix or deliberately re-pin, only then restart.
`Restart=always` with `RestartSec=5` means systemd keeps trying — the
exit-3 loop in the journal IS the alarm; wire an `OnFailure=` alert if
you have a channel.

## Model config law — the silent-fallback crash (apply on EVERY box)

Root cause of the prod outage this harness replaces: a model alias that
exists only via a live feature/experiment is invisible to fresh
processes. Fresh `vibe -p`/`vibe-acp` processes then log
`Active model 'X' is not in your configured models; falling back` and
silently switch to a fallback with a smaller context. A large mailbox
prompt then dies on a 308k-token prompt against a 262k model — the
daemon looked "up" while every dispatch crashed.

Law:

- Every model the box uses gets an explicit `[[models]]` entry in
  `~/.vibe/config.toml` (id, display name, provider, context limit,
  `auto_compact` threshold comfortably below the context limit).
- Never rely on experiment-injected models for the pinned session.
- After ANY model config change, grep the vibe log for
  `falling back` — that line is the oracle. A model's self-report of
  its own identity is NOT reliable evidence.
- Keep a cheap small-model agent profile (e.g. `scout`) for harness
  tests; never smoke-test with the prod thinker profile.

## The `vibe` shim law (when humans SSH in)

If the habit `ssh -t <box> vibe --resume <pinned id>` exists, install a
shim so it can no longer open a SECOND copy of the pinned session:

- intercept ONLY `--resume <pinned id>`; pass every other invocation
  through to the real binary untouched (one-shot `-p`, other sessions,
  setup commands).
- when vibed is up, forward the interactive turn over the socket;
- when vibed is down, REFUSE with the message "vibed is down; run:
  systemctl start vibed" — never fall back to a direct resume. The
  fallback IS the corruption we are eliminating.

## Acceptance suite (run on every release before cutover)

All against a THROWAWAY session id, never the pinned one:

1. **Pin refusal.** Garbage id in state → daemon exits 3, stderr has
   `PIN_LOST`, `session_id.*.bak` exists, state file unchanged.
2. **Lock-free status.** Long push in flight → `vibed-cli status`
   replies in <1s with `busy:true, busy_since_secs` climbing; clears
   after end_turn.
3. **Child kill regression.** `kill -9` the vibe-acp child → status
   reports honest `up:false, restarts:1` → respawn → `session/load`
   restores the SAME id → push → `end_turn`.
4. **Cross-process recall.** Mint session with `vibe -p`, load it via
   vibed, ask what the earlier instruction was → the reply must quote
   it exactly.
5. **Flock.** Start a second vibed against the same lock → exits 1
   immediately; the first is untouched.

## Test harness

`vibed/tests/run.sh` (red/green/regression phases, EXIT-trap cleans
everything) is the permanent harness the builder maintains. New fixes
land red/green against it.
