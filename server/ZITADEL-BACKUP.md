# Zitadel passwordless users dump — per-box deployment

The tested reference implementation lives on the box that validated it
(box-tools commit with subject `zitadel-scrubbed-dump: backup-schema design
(named-column procs, least-privilege export role, dual-recipient age, sound
verify)`). The two canonical files here are byte-identical to the tested
code:

- `zitadel-backup-setup.sql` — one-time DB setup (backup schema + shape-copied
  tables + SECURITY DEFINER copy procs + least-privilege `zitadel_export` role)
- `zitadel-scrubbed-dump.sh` — the nightly job

## Threat model

The dump artifact alone grants NOBODY a login. Users survive; password
hashes do not — on restore everyone resets their password via the (working)
transactional SMTP. AES-encrypted secrets (SMTP provider, OIDC clients,
TOTP, PATs) stay encrypted in place; the keys live ONLY in the box secrets
fileset, never in the same artifact.

## Per-box setup

1. Run `zitadel-backup-setup.sql` as postgres against the Zitadel DB —
   VERIFY the projection table/column names against your Zitadel version
   first (see the header comment).
2. Install `zitadel-scrubbed-dump.sh` in the box tools dir (mode +x). It
   needs: an age public key file for the owner-held recipient, and a
   box-local verify identity (mode 600, covered by the box-secrets fileset)
   — generate with `age-keygen -o <identity>`; derive its public key with
   `age-keygen -y` for the dual-recipient encrypt.
3. Cron it (pick an offset that rides your box's sweep/S3 windows).
4. Run once by hand and CHECK THE OUTPUT LINE:
   `OK: <path> (<bytes>B) — N users, zero credential markers verified`

## Sound verification (non-negotiable)

A pass means ALL of: decrypt exits 0 (checked, never stderr-swallowed),
decompressed bytes > 0, >= 5 COPY statements, users present in the data,
zero credential markers (`$argon2`, `encodedhash`, `client_secret`,
`totp_secret`, `password_hash`). Grep-zero-on-empty is NOT a pass — that
exact false pass shipped once on the reference box and was caught by
reading the artifact back.

## Restore story

The artifact is plain SQL of the backup schema: users, orgs, memberships,
grants come back; passwords do not exist in it. Each user resets their
password via transactional email. A thief with the dump gets a phone book.
