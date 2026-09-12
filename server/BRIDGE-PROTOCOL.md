# Bridge Mailbox Protocol v2

The vibe-bridge is now an async mailbox. No more blocking `send --wait`:
post a message, get a uuid, keep working, poll for the reply.

## Layout (host, /opt/vibe-bridge/mail/)

- `inbox.jsonl` — append-only. One JSON per line:
  `{"uuid", "ts", "from", "text", "attachments":[{"name","path"}]}`
- `inbox/{uuid}/files/…` — attachments I pushed, named server-side
- `outbox.jsonl` — append-only. One JSON per line:
  `{"uuid", "ts", "path"}` where `path` names the reply file/folder to scp down
- `outbox/{uuid}/reply.md` — your reply text (plus any artifacts alongside)

## Your side (hostinger-manager agent)

When the daemon wakes you for message `{uuid}`:

1. Read the inbox line for `{uuid}` and its attachments under
   `inbox/{uuid}/files/`.
2. Do the work.
3. Write `outbox/{uuid}/reply.md` (plus artifacts in that folder). Never put
   secrets in reply.md.
4. Append to `outbox.jsonl`:
   `{"uuid":"<uuid>","ts":"<iso ts>","path":"/opt/vibe-bridge/mail/outbox/<uuid>"}`
   — the `ts` must be written AFTER the reply files are complete.
5. Final stdout: one line `processed <uuid>`.

Lane discipline: the inbox/outbox may carry messages from other client
agents. Only act on messages addressed to you (from=opencode-simon or the
daemon dispatch itself); never reply to other agents' messages.

## Operator side (the User's agents over SSH)

- `vibe-bridge new-id` → `{uuid, files_dir}`; scp attachments there
- `vibe-bridge post-message <uuid> <from> "<text>"` → stamps ts, appends inbox
- `vibe-bridge check-messages --after <ts>` → `{now, inbox[], outbox[]}`:
  your new inbox messages and any agent replies newer than `after`; scp down
  the reply `path` when present.
- `vibe-bridge status` / `stop` unchanged; daemon dispatches each inbox
  message as one serialized `vibe -p` run (split-brain flock unchanged).
