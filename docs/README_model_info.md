# Model Info Protocol

## Overview

Both the client (laptop agent) and server (box-manager agent) should know
their own model card and make it available on request. This enables
capability-aware communication — for example, a server that knows the client
has no vision capability can instruct it to use screenshot->PNG->tesseract
instead of DOM queries when interacting with web pages.

## Model Card JSON Format

Save to `~/.vibe/info.json` on both client and server:

```json
{
  "model": "zai-glm-5-2",
  "version": "v5.2",
  "context_size": "1M",
  "max_output": "128k",
  "modalities": {
    "text": true,
    "vision": false,
    "audio": false,
    "code": true
  },
  "provider": "Mistral AI",
  "url": "https://docs.mistral.ai/models/zai-glm-5-2"
}
```

Also write a human-readable copy to `/root/docs/info.md` (server) or
`docs/info.md` (client project).

## Short Info String

When a request includes `X-Request-Info: true` in its headers, the server
appends this line to the end of `reply.md`:

```
[info] model=zai-glm-5-2 ctx=1M out=128k modalities=text,code vision=no audio=no
```

This is placed at the end to minimise impact on context caching.

## Server Setup Steps

1. On first boot or when model changes, write the model card to:
   - `~/.vibe/info.json` (machine-readable)
   - `/root/docs/info.md` (human-readable)
2. Store the model card in long-term memory (box-state.md or equivalent).
3. When a request has `X-Request-Info: true` in its headers, append the
   short info string to the end of `reply.md`.
4. When a request has `X-Info` in its headers, note the client's modalities.
   If the client has `vision=no` and you need it to interact with a web page,
   include instructions to use screenshot->PNG->tesseract on every page.

## Client Setup Steps

1. Know your own model card (same JSON format).
2. Post `X-Info` header with every message to the server.
3. The client is free to add any other `X-*` headers as metadata.
