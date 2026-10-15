#!/bin/bash
# zitadel-scrubbed-dump.sh — nightly passwordless backup of the Zitadel users.
#
# Design (owner-specified): a dedicated backup schema (zitadel_backup) holds
# correctly-shaped tables of NAMED COLUMNS ONLY. SECURITY DEFINER procs there
# know the source columns and copy users/orgs/memberships in. The export runs
# AS the least-privilege role zitadel_export (it may only truncate + call +
# read that schema; it has no rights on any source table). The dump exports
# ONLY the backup schema — password hashes (eventstore encodedHash), secrets
# (SMTP/OIDC/TOTP, AES-encrypted with box keys), tokens and sessions never
# enter any file. No scratch DB, no full-DB copy: nothing is moved around.
#
# On restore: users exist, passwords do NOT — everyone resets their password
# via the (working) transactional SMTP.
set -euo pipefail
TS=$(date -u +%Y%m%dT%H%M%SZ)
OUT_DIR=/opt/backup/zitadel
AGE_KEY=$(cat /opt/backups/age-public-key.txt)          # owner-held private key
BOX_AGE_ID=/root/.secrets/age-backup-identity.txt      # box-local verify identity
BOX_AGE_PUB=$(age-keygen -y "$BOX_AGE_ID")              # dual recipient: box can verify
LOG() { echo "$(date -u +%FT%TZ) $*"; }

# 1. as the export role: truncate, call the procs (they copy named columns)
sudo -u postgres psql -d zitadel -q -v ON_ERROR_STOP=1 -c "
SET ROLE zitadel_export;
TRUNCATE zitadel_backup.orgs, zitadel_backup.users, zitadel_backup.users_humans, zitadel_backup.org_members, zitadel_backup.user_grants;
CALL zitadel_backup.copy_orgs();
CALL zitadel_backup.copy_users();
CALL zitadel_backup.copy_users_humans();
CALL zitadel_backup.copy_org_members();
CALL zitadel_backup.copy_user_grants();
RESET ROLE;" >/dev/null

N=$(sudo -u postgres psql -d zitadel -At -c "SELECT count(*) FROM zitadel_backup.users")

# 2. read out ONLY the backup schema, as the export role, gzip + age-encrypt
mkdir -p "$OUT_DIR"; chmod 700 "$OUT_DIR"
OUT="$OUT_DIR/zitadel-users-$TS.sql.gz.age"
sudo -u postgres pg_dump --role=zitadel_export --schema=zitadel_backup --no-owner --no-privileges zitadel \
  | gzip | age -r "$AGE_KEY" -r "$BOX_AGE_PUB" > "$OUT"

# 3. SOUND verification: decrypt must succeed, content must be non-empty,
#    must contain the users, and must contain zero credential markers.
VERIFY_TMP=$(mktemp)
if ! age -d -i "$BOX_AGE_ID" "$OUT" 2>"$VERIFY_TMP.err" | zcat > "$VERIFY_TMP" 2>>"$VERIFY_TMP.err"; then
  rm -f "$OUT" "$VERIFY_TMP" "$VERIFY_TMP.err"; LOG "FAIL: decrypt/decompress failed: $(head -1 "$VERIFY_TMP.err")"; exit 1
fi
BYTES=$(stat -c%s "$VERIFY_TMP"); MARKERS=$(grep -ciE '\$argon2|encodedhash|client_secret|totp_secret|password_hash' "$VERIFY_TMP" || true)
HAVE_USERS=$(grep -c "COPY zitadel_backup" "$VERIFY_TMP")
rm -f "$VERIFY_TMP" "$VERIFY_TMP.err"
if [ "$MARKERS" != "0" ] || [ "$HAVE_USERS" -lt 5 ] || [ "$BYTES" -lt 1000 ] || [ "$N" = "0" ]; then
  rm -f "$OUT"; LOG "FAIL: dump rejected (markers: $MARKERS, copy stmts: $HAVE_USERS, bytes: $BYTES, users: $N)"; exit 1
fi

ls -1t "$OUT_DIR"/zitadel-users-*.sql.gz.age | tail -n +11 | xargs -r rm -f
LOG "OK: $OUT ($(stat -c%s "$OUT")B) — $N users, zero credential markers verified"
