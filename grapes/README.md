# Grapes — self-contained apps installed by the box agent

A **grape** is one application packaged as a folder that the VPS agent can
install on the box without any human hand-holding. The name: one grape per
vine; the box carries a bunch of them.

## What a grape is

A folder named after the app containing exactly:

| file | what it is |
|---|---|
| `grape-<app>.md` | agent skill: EXACT install steps, verification steps, and rollback steps. Written so the box agent can execute it verbatim. |
| `docker-compose.yml` | the app's compose file (self-sufficient: networks, volumes, healthchecks) |
| `.env.example` | every variable the compose file consumes, with placeholder values and a one-line comment per variable |

Rules for `grape-<app>.md`:

1. **Install** must be idempotent and must not reboot the box, must not
   touch other grapes, and must state every system-level change it makes.
2. **Verify** must include at least one command whose exit status proves the
   app actually works (health endpoint, `docker compose ps`, auth round-trip).
3. **Rollback** must restore the prior state (`docker compose down -v` +
   files to delete + any config that was changed).
4. Secrets come from `/opt/vps-grapevine/.env` or the grape's own `.env`
   (git-veil-encrypted in transit); the skill never contains a real key.

## Naming + versioning

- Folder name = app name, lowercase, hyphens (`grapes/forgejo/`).
- Grape versions **track repo tags**: a grape folder is frozen at whatever
  repo tag ships it. Changes to a grape mean a new repo tag. Reference the
   tag in `grape-<app>.md` ("landed at v0.2.1").
- Provider- or box-specific values (domains, IPs, client secrets) never live
  in the grape folder — they live in `.env` on the box.

## How grapes are installed

The box agent installs grapes from either:

1. a **tagged repo zip** — public, curl-able:
   `https://github.com/simbo1905/vps-grapevine/archive/refs/tags/<tag>.zip`
2. a **presigned bucket object** — for anything the agent should not fetch
   from the public internet (see `server/BOOTSTRAP.md` for the presign flow;
   presigned URLs expire after 1h).

Unpack under `/opt/vps-grapevine/grapes/<app>/`, then follow
`grape-<app>.md` install steps exactly.
