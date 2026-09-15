# Headers Protocol

## Overview

The mailbox protocol supports custom headers in the JSONL message format.
Headers enable capability-aware communication between client and server
agents. Both sides should always check for headers and act on them.

## Message Format with Headers

### Inbox (incoming message)

```json
{
  "uuid": "...",
  "ts": "...",
  "from": "coordinator",
  "text": "...",
  "headers": {
    "X-Info": "model=zai-glm-5-2;modalities=text,code;vision=no;audio=no",
    "X-Output-Format": "folder",
    "X-Request-Info": "true"
  },
  "attachments": []
}
```

### Outbox (reply)

The outbox JSONL line is unchanged:
```json
{"uuid":"...","ts":"...","path":"/opt/vps-grapevine/mail/outbox/..."}
```

The reply itself (`reply.md` or folder of files) may include the info string
at the end if `X-Request-Info: true` was in the request headers.

## Standard Headers

| Header | Set By | Purpose |
|---|---|---|
| `X-Info` | Client | Client model card: `model=...;modalities=...;vision=...;audio=...` |
| `X-Request-Info` | Client | `true` — server appends its model info string to the reply |
| `X-Output-Format` | Client | `folder` — client expects a folder of files in `outbox/{uuid}/`. If the server has no files to output, it creates the folder and puts a single `empty_folder` file in it. Default (no header) is `reply.md` text. |

## Custom Headers

Clients are free to add any other `X-*` headers as metadata. The server
should always parse all headers and check for ones it recognises. Unknown
headers should be ignored (not cause errors).

## Server Behaviour

1. **Always parse headers** from incoming messages.
2. If `X-Info` is present, note the client's modalities. If the client has
   `vision=no` and you need it to interact with a web page, include
   instructions to use screenshot->PNG->tesseract on every page to "see"
   what is on screen before attempting any DOM reads/writes.
3. If `X-Request-Info: true`, append the short info string to the end of
   `reply.md`:
   ```
   [info] model=zai-glm-5-2 ctx=1M out=128k modalities=text,code vision=no audio=no
   ```
4. If `X-Output-Format: folder`, create `outbox/{uuid}/` as a folder and
   put reply files in it. If there are no files to output, create the folder
   and put a single file named `empty_folder` in it so the client knows the
   server processed the request but had no files to return.

## Client Behaviour

1. Know your own model card (see `docs/README_model_info.md`).
2. Post `X-Info` header with every message.
3. Set `X-Request-Info: true` when you want the server's model info in the
   reply.
4. Set `X-Output-Format: folder` when you expect the reply to be a folder
   of files rather than a single `reply.md`.
5. You may add any other `X-*` headers as metadata.
