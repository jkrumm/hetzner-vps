#!/usr/bin/env bash
# =============================================================================
# PostgreSQL restore from object storage backup.
# WARNING: Drops and recreates the target database. Use with caution.
# Usage: BACKUP_FILE=postgres_mydb_20260224_030000.dump ./scripts/restore-pg.sh
#
# Required env vars (from Doppler):
#   POSTGRES_DB, POSTGRES_USER, POSTGRES_PASSWORD
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
#   AWS_S3_BUCKET, AWS_S3_ENDPOINT
# =============================================================================
set -euo pipefail

BACKUP_FILE="${BACKUP_FILE:-}"

if [[ -z "${BACKUP_FILE}" ]]; then
  echo "Usage: BACKUP_FILE=<filename> ./scripts/restore-pg.sh"
  echo ""
  echo "Available backups:"
  aws s3 ls "s3://${AWS_S3_BUCKET}/backups/" \
    --endpoint-url "${AWS_S3_ENDPOINT}" \
    | awk '{print $4}' | sort
  exit 1
fi

echo "WARNING: This will drop and restore the database: ${POSTGRES_DB}"
echo "Backup file: ${BACKUP_FILE}"
echo ""
read -rp "Type 'yes' to confirm: " confirm
[[ "${confirm}" != "yes" ]] && echo "Aborted." && exit 1

echo "Downloading ${BACKUP_FILE} from S3..."
TMPFILE=$(mktemp /tmp/pg_restore_XXXXXX.dump)
trap "rm -f ${TMPFILE}" EXIT

aws s3 cp "s3://${AWS_S3_BUCKET}/backups/${BACKUP_FILE}" "${TMPFILE}" \
  --endpoint-url "${AWS_S3_ENDPOINT}"

echo "Restoring into ${POSTGRES_DB}..."
docker run --rm \
  --network postgres-net \
  -e PGPASSWORD="${POSTGRES_PASSWORD}" \
  -v "${TMPFILE}:/backup.dump:ro" \
  postgres:18 \
  sh -c "
    dropdb --host=postgres --username=${POSTGRES_USER} --if-exists ${POSTGRES_DB} &&
    createdb --host=postgres --username=${POSTGRES_USER} ${POSTGRES_DB} &&
    pg_restore --host=postgres --username=${POSTGRES_USER} --dbname=${POSTGRES_DB} --no-owner --no-privileges /backup.dump
  "

echo "Restore complete: ${POSTGRES_DB}"
