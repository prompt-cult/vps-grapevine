# Secrets runtime pattern — vault, backup rule, tested-before-clobber

Law: passwords and secrets are git-veil sealed, never plaintext
(DECISION-LOG 2026-10-09T13:05Z), refined with tested-before-clobber
(2026-10-09T13:20Z). This file is the box-facing how-to.

## Vault location contract

Every box clones the secrets vault repo (simbo1905/crispy-computing-machine)
to a canonical path (`/opt/crispy-computing-machine` on vps0; parameterize
via `BACKUP_VAULT_DIR` in scripts). Before first use:

    cd <vault-path>
    git-veil trust <repo-id> <owner-verifying-keyfile>
    git-veil verify-keyring && git-veil list-keys   # trust
    git-veil cat .vault                             # reveal TEST — must decrypt

## Runtime sourcing pattern (reference implementation)

`server/backup-to-scaleway.sh` is the reference implementation:

    _vault=$(cd "$BACKUP_VAULT_DIR" && git-veil cat .vault 2>/dev/null)
    AWS_ACCESS_KEY_ID=$(printf '%s\n' "$_vault" | sed -n 's/^#   access_key: //p')
    AWS_SECRET_ACCESS_KEY=$(printf '%s\n' "$_vault" | sed -n 's/^#   secret_key: //p')
    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

Rules: vault → in-memory parse → env vars → consuming command. Never write
a decrypted copy to disk, never echo the value into agent context or logs.
Vault sections use `#   key: value` comment lines (parser contract).

## Backup rule

- Nightly sweep: `/opt/box-tools/backup-sweep.sh` (cron 03:37 UTC) →
  `/opt/backup` (bundles + fileset tars + MANIFEST.json, retention 10).
  LOCAL-ONLY, never pushed — it exists to revert human error. CHECK THE
  OUTPUT for FAIL/WARN lines every run.
- Optional nightly S3: `/opt/box-tools/backup-to-scaleway.sh` (cron 03:00
  UTC) — age public-key encrypts the tarball, then uploads over HTTPS;
  creds from the sealed vault at runtime. Same bucket/creds for all boxes.
- Box tooling is itself git-tracked (`/opt/box-tools`, in the sweep REPOS,
  autocommit) and ships in `server/` of this repo for new boxes.

## Tested-before-clobber

The vault is the CANONICAL record; the runtime env copy (600 file / compose
env) is the WORKING state. Before a vault reveal replaces a runtime secret:
prove the new value works (auth probe / endpoint check / S3 ls). Keep the
old value recoverable (sweep bundle + tag) until the new one is proven.
Never overwrite a working env location with an untested reveal — a bad
reveal that locks you out is worse than a stale secret.

Worked examples (2026-10-09): Fastmail rotation (auth probe → Zitadel PUT →
vault re-seal) and the Scaleway S3 cutover (upload test before retiring the
plaintext creds file).

Env vars are acceptable runtime plumbing on a single-root box
(`/proc/*/environ` is root-only); 600 runtime files are swept nightly in
the box-secrets fileset.
