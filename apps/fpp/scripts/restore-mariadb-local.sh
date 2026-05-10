#!/usr/bin/env bash
# =============================================================================
# Local MariaDB restore from S3 — non-interactive, dev-only.
#
# Pulls the latest (or named) backup from S3 and restores it into the local
# `mariadb` container started by compose.dev.yml. Used to:
#   - Validate the prod backup chain is replayable (DR drill from a clean Mac)
#   - Seed local dev with prod data when fresh-from-DB sync isn't desired
#
# For fresh-from-prod data (no S3 round trip), use sync-mariadb-from-vps.sh.
# Prod restore (interactive, drops prod DB) is restore-mariadb.sh.
#
# Usage:  make fpp-restore-local
#         BACKUP_FILE=mariadb_..._YYYYMMDD_HHMMSS.sql.gz make fpp-restore-local
#
# Required env (resolved by op run --env-file=.env.tpl):
#   MARIADB_DB, MARIADB_ROOT_PASSWORD
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_S3_BUCKET, AWS_S3_ENDPOINT
# =============================================================================
set -euo pipefail

BACKUP_PREFIX="backups/vps/mariadb"

log() { echo "[$(date +%H:%M:%S)] $*"; }

docker inspect -f '{{.State.Status}}' mariadb >/dev/null 2>&1 || {
  echo "ERROR: local 'mariadb' container not running. Run 'make up' first."; exit 1;
}

if [[ -n "${BACKUP_FILE:-}" ]]; then
  FILE="${BACKUP_FILE}"
else
  log "Resolving latest backup in s3://${AWS_S3_BUCKET}/${BACKUP_PREFIX}/ ..."
  FILE=$(aws s3 ls "s3://${AWS_S3_BUCKET}/${BACKUP_PREFIX}/" \
      --endpoint-url "${AWS_S3_ENDPOINT}" \
    | awk '{print $4}' \
    | grep -E "^mariadb_${MARIADB_DB}_[0-9]+_[0-9]+\.sql\.gz$" \
    | sort -r | head -1)
  [[ -z "${FILE}" ]] && { echo "ERROR: no matching backup found."; exit 1; }
fi
log "Using: ${FILE}"

log "Dropping and recreating local database ${MARIADB_DB}..."
docker exec -i \
  -e MYSQL_PWD="${MARIADB_ROOT_PASSWORD}" \
  mariadb mariadb -u root <<SQL
DROP DATABASE IF EXISTS \`${MARIADB_DB}\`;
CREATE DATABASE \`${MARIADB_DB}\`
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
SQL

log "Streaming ${FILE} from S3 → local mariadb..."
aws s3 cp "s3://${AWS_S3_BUCKET}/${BACKUP_PREFIX}/${FILE}" - \
    --endpoint-url "${AWS_S3_ENDPOINT}" \
  | gunzip \
  | docker exec -i \
      -e MYSQL_PWD="${MARIADB_ROOT_PASSWORD}" \
      mariadb mariadb -u root "${MARIADB_DB}"

log "Restore complete. Table summary:"
docker exec -i \
  -e MYSQL_PWD="${MARIADB_ROOT_PASSWORD}" \
  mariadb mariadb -u root "${MARIADB_DB}" -e "
SELECT TABLE_NAME, TABLE_ROWS
  FROM information_schema.TABLES
 WHERE TABLE_SCHEMA='${MARIADB_DB}'
 ORDER BY TABLE_ROWS DESC;"
