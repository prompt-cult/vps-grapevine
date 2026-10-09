#!/bin/bash
# Backup script for VPS Grapevine
# Backs up critical directories to IONOS S3 Object Storage
# Usage: ./backup-to-s3.sh [--dry-run] [--force]

set -euo pipefail

# Configuration
BUCKET="stenographer1-backup"
S3_ENDPOINT="https://s3.eu-central-3.ionoscloud.com"
BACKUP_DIR="/tmp/vps-grapevine-backup"
RETENTION_DAYS=28  # Keep 4 weeks of backups
DATE=$(date +%Y%m%d-%H%M%S)
BACKUP_NAME="vps-grapevine-${DATE}.tar.gz"
ENCRYPTED_NAME="vps-grapevine-${DATE}.tar.gz.age"
FINAL_NAME="${ENCRYPTED_NAME}"

# Directories to backup
BACKUP_PATHS=(
    "/opt/vps-grapevine/"
    "/root/.vibe/"
    "/home/apps/config/"
    "/home/apps/data/"
)

# Check if this is a dry run
DRY_RUN=false
FORCE=false

for arg in "$@"; do
    case "$arg" in
        --dry-run)
            DRY_RUN=true
            echo "[DRY RUN] No changes will be made"
            ;;
        --force)
            FORCE=true
            ;;
    esac
done

# Check if age encryption key exists
AGE_KEY_FILE="$HOME/.age/keys.txt"
USE_ENCRYPTION=false

if [ -f "$AGE_KEY_FILE" ]; then
    USE_ENCRYPTION=true
    echo "[INFO] Age key found at $AGE_KEY_FILE, will encrypt backup"
else
    echo "[WARNING] No age key found at $AGE_KEY_FILE, backup will NOT be encrypted"
    echo "[INFO] To enable encryption, create a key with: age-keygen -o $AGE_KEY_FILE"
fi

# Check if S3 credentials are configured
if [ -z "${AWS_ACCESS_KEY_ID:-}" ] || [ -z "${AWS_SECRET_ACCESS_KEY:-}" ]; then
    echo "[ERROR] AWS credentials not found in environment"
    echo "[INFO] Set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY environment variables"
    echo "[INFO] Or create bucket manually via IONOS Cloud Panel"
    exit 1
fi

# Check if aws-cli is available
if ! command -v aws &> /dev/null; then
    echo "[ERROR] aws-cli not found. Please install: pip install awscli"
    exit 1
fi

# Verify S3 endpoint connectivity
echo "[INFO] Verifying S3 endpoint connectivity..."
if ! aws s3 ls --endpoint-url "$S3_ENDPOINT" &> /dev/null; then
    echo "[ERROR] Cannot connect to S3 endpoint: $S3_ENDPOINT"
    echo "[INFO] Check your AWS credentials and endpoint URL"
    exit 1
fi

echo "[INFO] S3 endpoint $S3_ENDPOINT is accessible"

# Create temporary backup directory
mkdir -p "$BACKUP_DIR"
echo "[INFO] Created temporary directory: $BACKUP_DIR"

# Create tarball
TARBALL_PATH="$BACKUP_DIR/$BACKUP_NAME"
echo "[INFO] Creating tarball: $TARBALL_PATH"

if [ "$DRY_RUN" = true ]; then
    echo "[DRY RUN] Would create tarball from:"
    for path in "${BACKUP_PATHS[@]}"; do
        echo "[DRY RUN]   $path"
    done
else
    tar czf "$TARBALL_PATH" "${BACKUP_PATHS[@]}" 2>&1 | while read -r line; do echo "[TAR] $line"; done
    echo "[INFO] Tarball created successfully"
    ls -lh "$TARBALL_PATH"
fi

# Encrypt with age if key exists
if [ "$USE_ENCRYPTION" = true ]; then
    ENCRYPTED_PATH="$BACKUP_DIR/$ENCRYPTED_NAME"
    echo "[INFO] Encrypting backup with age..."
    
    if [ "$DRY_RUN" = true ]; then
        echo "[DRY RUN] Would encrypt: $TARBALL_PATH -> $ENCRYPTED_PATH"
    else
        # Get the first age key from the file
        AGE_RECIPIENT=$(head -n 1 "$AGE_KEY_FILE" | grep -oP 'age1\S+' | head -n 1)
        if [ -z "$AGE_RECIPIENT" ]; then
            echo "[ERROR] No valid age key found in $AGE_KEY_FILE"
            rm -rf "$BACKUP_DIR"
            exit 1
        fi
        
        age -R "$AGE_KEY_FILE" -o "$ENCRYPTED_PATH" "$TARBALL_PATH"
        echo "[INFO] Encryption complete"
        FINAL_NAME="$ENCRYPTED_NAME"
        rm "$TARBALL_PATH"
    fi
else
    FINAL_NAME="$BACKUP_NAME"
fi

# Upload to S3
FINAL_PATH="$BACKUP_DIR/$FINAL_NAME"
S3_KEY="backups/${FINAL_NAME}"

echo "[INFO] Uploading to S3: $S3_KEY"

if [ "$DRY_RUN" = true ]; then
    echo "[DRY RUN] Would upload: $FINAL_PATH -> s3://$BUCKET/$S3_KEY"
else
    aws s3 cp "$FINAL_PATH" "s3://$BUCKET/$S3_KEY" \
        --endpoint-url "$S3_ENDPOINT" \
        --storage-class STANDARD \
        2>&1 | while read -r line; do echo "[S3 UPLOAD] $line"; done
    
    echo "[INFO] Upload complete"
    
    # Verify upload
    aws s3 ls "s3://$BUCKET/$S3_KEY" --endpoint-url "$S3_ENDPOINT" --human-readable
fi

# Cleanup local files
if [ "$DRY_RUN" = false ]; then
    echo "[INFO] Cleaning up temporary files..."
    rm -f "$FINAL_PATH"
    rm -rf "$BACKUP_DIR"
    echo "[INFO] Temporary files removed"
fi

# Retention: Clean up old backups (older than RETENTION_DAYS)
echo "[INFO] Checking for old backups to clean up (retention: ${RETENTION_DAYS} days)..."

if [ "$DRY_RUN" = true ]; then
    echo "[DRY RUN] Would list and delete backups older than $(date -d "$RETENTION_DAYS days ago" +%Y-%m-%d)"
else
    # List all backups in S3
    OLD_BACKUPS=$(aws s3 ls "s3://$BUCKET/backups/" --endpoint-url "$S3_ENDPOINT" --recursive | \
        grep -v 'PRE' | \
        awk '{print $4}')
    
    CUTOFF_DATE=$(date -d "$RETENTION_DAYS days ago" +%Y-%m-%d)
    
    for backup in $OLD_BACKUPS; do
        # Extract date from filename: vps-grapevine-YYYYMMDD-HHMMSS.tar.gz.age
        BACKUP_DATE_STR=$(basename "$backup" | grep -oP '\d{8}' | head -1)
        
        if [ -n "$BACKUP_DATE_STR" ]; then
            BACKUP_DATE=$(date -d "${BACKUP_DATE_STR:0:4}-${BACKUP_DATE_STR:4:2}-${BACKUP_DATE_STR:6:2}" +%Y-%m-%d)
            
            if [[ "$BACKUP_DATE" < "$CUTOFF_DATE" ]]; then
                echo "[INFO] Deleting old backup: $backup (date: $BACKUP_DATE)"
                aws s3 rm "s3://$BUCKET/$backup" --endpoint-url "$S3_ENDPOINT" --quiet
                echo "[INFO] Deleted: $backup"
            fi
        fi
    done
    
    echo "[INFO] Retention cleanup complete"
fi

echo "[SUCCESS] Backup completed successfully"
echo "Backup: $FINAL_NAME"
echo "S3 Location: s3://$BUCKET/$S3_KEY"
