#!/bin/bash
# Daily backup script to Scaleway S3
# Creates encrypted tarballs of /opt/zitadel /home/apps/config /root/.vibe
# Uploads to vps0-stenographer-cloud bucket
# Retention: 28 days

set -euo pipefail

# creds come from the git-veil sealed vault at runtime; never plaintext on disk
_vault=$(cd "${BACKUP_VAULT_DIR:-/opt/crispy-computing-machine}" && git-veil cat .vault 2>/dev/null) || { echo "FATAL: vault unreadable"; exit 1; }
AWS_ACCESS_KEY_ID=$(printf '%s\n' "$_vault" | sed -n 's/^#   access_key: //p')
AWS_SECRET_ACCESS_KEY=$(printf '%s\n' "$_vault" | sed -n 's/^#   secret_key: //p')
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
[ -n "$AWS_ACCESS_KEY_ID" ] && [ -n "$AWS_SECRET_ACCESS_KEY" ] || { echo "FATAL: creds missing from vault"; exit 1; }

# Configuration
BUCKET="vps0-stenographer-cloud"
ENDPOINT="https://s3.fr-par.scw.cloud"
PUBLIC_KEY="age1uk0efx42gknc4etrpn9hpanam6ugqdw7uv5eatw9e86kkw2lngyq69wxs8"
BACKUP_DATE=$(date +%F)
BACKUP_FILE="backup-${BACKUP_DATE}.tar.gz.age"
S3_PATH="s3://${BUCKET}/${BACKUP_FILE}"

# Directories to backup
BACKUP_DIRS=(
  "/opt/zitadel"
  "/home/apps/config"
  "/root/.vibe"
)

# Exclude patterns
EXCLUDE_PATTERNS=(
  "*.key"
  "*.pem"
  ".env"
)

# Build exclude arguments for tar
EXCLUDE_ARGS=()
for pattern in "${EXCLUDE_PATTERNS[@]}"; do
  EXCLUDE_ARGS+=("--exclude" "$pattern")
done

log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

log "Starting backup to Scaleway S3..."

# Create tarball and encrypt with age, then upload to S3
# Using aws s3 cp as mc client is not available
log "Creating encrypted tarball..."

# Create temporary file for the tarball
temp_tar=$(mktemp /tmp/backup-XXXXXX.tar.gz)
trap "rm -f $temp_tar" EXIT

# Create tarball with excludes
log "Creating tarball..."
tar czf "$temp_tar" "${EXCLUDE_ARGS[@]}" "${BACKUP_DIRS[@]}" 2>&1 | while read line; do log "tar: $line"; done

# Encrypt and upload in one pipe to avoid large temp files
# First, let's just encrypt to a temp file, then upload
log "Encrypting tarball with age..."
temp_age=$(mktemp /tmp/backup-XXXXXX.tar.gz.age)
trap "rm -f $temp_age" EXIT

age -r "$PUBLIC_KEY" -o "$temp_age" "$temp_tar"

log "Uploading to S3..."
aws s3 --endpoint-url "$ENDPOINT" cp "$temp_age" "$S3_PATH" 2>&1 | while read line; do log "aws s3: $line"; done

log "Backup uploaded successfully: $S3_PATH"

# Cleanup old backups (older than 28 days)
log "Cleaning up backups older than 28 days..."
aws s3 --endpoint-url "$ENDPOINT" ls "s3://${BUCKET}/" | while read -r line; do
  # Skip header lines
  if [[ $line == "PRE "* || $line == "" ]]; then
    continue
  fi
  
  # Extract date and key from the line
  # S3 ls output: 2026-09-15 10:00:00   12345 backup-2026-09-01.tar.gz.age
  backup_date=$(echo "$line" | awk '{print $1}')
  backup_key=$(echo "$line" | awk '{print $4}')
  
  # Check if backup is older than 28 days
  if [[ -n "$backup_date" && -n "$backup_key" ]]; then
    backup_ts=$(date -d "$backup_date" +%s 2>/dev/null || echo 0)
    current_ts=$(date +%s)
    age_days=$(( (current_ts - backup_ts) / 86400 ))
    
    if [[ $age_days -gt 28 ]]; then
      log "Deleting old backup: $backup_key (age: ${age_days} days)"
      aws s3 --endpoint-url "$ENDPOINT" rm "s3://${BUCKET}/${backup_key}" 2>&1 | while read line; do log "aws s3 rm: $line"; done
    fi
  fi
done

log "Backup completed successfully."
