#!/usr/bin/env bash
# =============================================================================
# PostgreSQL backup — pg_dump → object storage (S3-compatible)
# Runs via cron (see cron/pg-backup). Can also be triggered manually: make backup
# On success: pings Uptime Kuma push monitor.
# On failure: sends down status to Uptime Kuma + exits non-zero.
#
# Required env vars (from Doppler):
#   POSTGRES_DB, POSTGRES_USER, POSTGRES_PASSWORD
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
#   AWS_S3_BUCKET, AWS_S3_ENDPOINT
#   UPTIME_KUMA_PUSH_URL
# =============================================================================
set -euo pipefail

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILENAME="postgres_${POSTGRES_DB}_${TIMESTAMP}.dump"
BACKUP_PREFIX="backups/vps/postgres"
RETENTION_DAYS=14

log() { echo "[$(date +%H:%M:%S)] $*"; }

ping_kuma() {
  local status="$1"
  local msg="$2"
  if [[ -n "${UPTIME_KUMA_PUSH_URL:-}" ]]; then
    curl -fsSL "${UPTIME_KUMA_PUSH_URL}?status=${status}&msg=${msg}&ping=" > /dev/null 2>&1 || true
  fi
}

cleanup() {
  if [[ $? -ne 0 ]]; then
    log "Backup FAILED: ${BACKUP_FILENAME}"
    ping_kuma "down" "backup_failed"
  fi
}
trap cleanup EXIT

log "Starting backup: ${BACKUP_FILENAME}"

# Run pg_dump in a one-shot container, stream directly to S3
# Uses the same postgres:18 image as the running database for compatibility.
docker run --rm \
  --network postgres-net \
  -e PGPASSWORD="${POSTGRES_PASSWORD}" \
  postgres:18 \
  pg_dump \
    --host=postgres \
    --username="${POSTGRES_USER}" \
    --dbname="${POSTGRES_DB}" \
    --format=custom \
    --compress=9 \
  | aws s3 cp - "s3://${AWS_S3_BUCKET}/${BACKUP_PREFIX}/${BACKUP_FILENAME}" \
    --endpoint-url "${AWS_S3_ENDPOINT}" \
    --storage-class STANDARD

log "Backup uploaded: s3://${AWS_S3_BUCKET}/${BACKUP_PREFIX}/${BACKUP_FILENAME}"

# Remove old backups (retention policy)
log "Pruning backups older than ${RETENTION_DAYS} days..."
aws s3 ls "s3://${AWS_S3_BUCKET}/${BACKUP_PREFIX}/" \
    --endpoint-url "${AWS_S3_ENDPOINT}" \
  | awk '{print $4}' \
  | while read -r key; do
    # Parse date from filename: postgres_<db>_YYYYMMDD_HHMMSS.dump
    filedate=$(echo "${key}" | grep -oP '\d{8}' | head -1) || continue
    [[ -z "${filedate}" ]] && continue
    cutoff=$(date -d "${RETENTION_DAYS} days ago" +%Y%m%d)
    if [[ "${filedate}" < "${cutoff}" ]]; then
      log "Deleting old backup: ${key}"
      aws s3 rm "s3://${AWS_S3_BUCKET}/${BACKUP_PREFIX}/${key}" \
        --endpoint-url "${AWS_S3_ENDPOINT}"
    fi
  done

log "Backup complete."
ping_kuma "up" "backup_ok"
