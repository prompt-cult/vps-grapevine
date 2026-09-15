# One-time bucket bootstrap — presign on the laptop, curl on the fresh box

This is the "no scp, no rsync, no secrets over ssh" cold-start flow for a
fresh Ubuntu box. The laptop pushes the kit + secrets into a private Scaleway
Object Storage bucket, presigns short-lived download URLs, and the box pulls
them with plain `curl`. Nothing persistent is left in the bucket except the
encrypted env bundle; presigned URLs die after one hour.

## Vocabulary

- **laptop** — the operator machine with `scw` + `mc` + the repo checkout
- **box** — the fresh VPS being bootstrapped (Ubuntu 24.04/26.04)
- **bucket** — Scaleway Object Storage bucket `vps-grapevine-<yyyymmdd>`
  (private; only presigned URLs ever grant read access)
- **env bundle** — `env/bundle.tar.gz.age` (or `.gpg`): an encrypted tarball
  holding the box's `.env`. It NEVER contains an unencrypted secret, and it
  is only decrypted on the box (or locally, to test the decrypt command, then
  the test file is deleted).

## 1. Laptop: one-time Scaleway setup

```bash
# mc config for Scaleway S3 (writes ~/.mc/config.json)
scw object config install type=mc region=fr-par
mc alias set vpsgrapevine https://s3.fr-par.scw.cloud <SCW_ACCESS_KEY> <SCW_SECRET_KEY>

# create the bucket (region fr-par)
mc mb vpsgrapevine/vps-grapevine-20260913
```

## 2. Laptop: upload the payload

Two objects:

1. the repo zip at the current tag (public, also curl-able straight from
   GitHub — the bucket copy exists so the box does not depend on GitHub);
2. the encrypted env bundle (private).

```bash
TAG=v0.2.1
cd <repo checkout>
curl -L -o /tmp/repo.zip https://github.com/simbo1905/vps-grapevine/archive/refs/tags/${TAG}.zip

# env bundle: tar a TEMPLATE .env (placeholders only) and encrypt.
# age (recipient pubkey):      tar cz .env | age -r <age-recipient> -o env/bundle.tar.gz.age
# gpg symmetric (passphrase):  tar cz .env | gpg -c -o env/bundle.tar.gz.gpg
# The template .env carries placeholder values, never real keys:
#   MISTRAL_API_KEY=<placeholder>

mc cp /tmp/repo.zip vpsgrapevine/vps-grapevine-20260913/repo-${TAG}.zip
mc cp env/bundle.tar.gz.age vpsgrapevine/vps-grapevine-20260913/env/bundle.tar.gz.age

# sanity: the bucket must be private (no anonymous download)
mc anonymous get vpsgrapevine/vps-grapevine-20260913
# expect: "Access permission for `vpsgrapevine/vps-grapevine-20260913` is `private`"
```

## 3. Laptop: presign (1 hour, download only)

```bash
# presign the env bundle (and, if GitHub is unreachable from the box, the zip)
mc share download --expire 1h vpsgrapevine/vps-grapevine-20260913/env/bundle.tar.gz.age
mc share download --expire 1h vpsgrapevine/vps-grapevine-20260913/repo-${TAG}.zip
```

`mc share download` prints the presigned URL; copy it to the box by hand.

Smoke test before handing it over (laptop):

```bash
curl -s -o /dev/null -w '%{http_code}\n' '<presigned-url>'   # expect: 200
# (Scaleway presigns are method-bound: a HEAD against this GET URL
# returns 403, so check with a plain GET, not curl -I)
# after expiry (1h) the same GET returns 403 — that is the point.
```

## 4. Box: install from the presigned URL

On the fresh box, as root:

```bash
curl -fsSL https://raw.githubusercontent.com/simbo1905/vps-grapevine/v0.2.1/scripts/bootstrap.sh -o /tmp/bootstrap.sh
# only if GitHub is unreachable from the box, also presign the repo zip and:
#   export VPS_GRAPEVINE_BUCKET_ZIP_URL='<presigned-repo-zip-url>'
bash /tmp/bootstrap.sh '<presigned-env-bundle-url>'
```

`scripts/bootstrap.sh` then:

1. downloads the repo zip (GitHub tag URL, bucket fallback) and unpacks the
   server kit to `/opt/vps-grapevine/`;
2. creates `/opt/vps-grapevine/mail/{inbox,outbox}` and `drop-in/`;
3. downloads the encrypted env bundle from the presigned URL, decrypts it
   (age identity at `/root/age-identity.txt`, or gpg symmetric passphrase on
   the terminal), installs `.env` at `/opt/vps-grapevine/.env` mode 600, and
   deletes every temporary copy;
4. installs `vibed.service`, appends `/root/AGENTS.md` from the template,
   creates the agent profile, runs the first-run `vibe -p READY`, and starts
   the daemon. It never reboots the box.

Afterwards run once over ssh: `vibe --setup` (agent API key), then the
normal `scripts/grapevine` flow takes over (see SKILL.md).

## Rules

- No IPs, no hostnames of real boxes in this file — placeholders only.
- The env bundle is encrypted at rest in the bucket; presigned URLs are the
  only key to it and they expire. Never presign with `--expire >1h`.
- If a presigned URL leaks before expiry: `mc share abort` revokes ALL
  presigned URLs for that alias.

## Footnote: Debian vs Ubuntu

This bootstrap flow is OS-agnostic — it only needs `curl` and a tarball.
What differs by OS is what runs *after* it:

- **Ubuntu 24.04/26.04**: Docker + ufw; see `SETUP-NOTES.md`.
- **Debian 13 (Trixie)**: Podman Quadlet, rootless `apps` user, nftables
  kernel port-redirect (no `CAP_NET_BIND_SERVICE`); see
  `***SCRUBBED***.md` and `nftables/nftables-debian.conf`, and use
  `AGENTS.md.template.debian` as the box policy template.
