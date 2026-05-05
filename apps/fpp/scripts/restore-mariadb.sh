#!/usr/bin/env bash
# =============================================================================
# MariaDB restore — pull dump from S3 → restore into running mariadb container.
# Interactive: confirms destructive action before dropping the database.
#
# Usage: make fpp-restore   (or invoke directly with op run)
# Required env vars: MARIADB_DB, MARIADB_ROOT_PASSWORD, AWS_*
# =============================================================================
set -euo pipefail

BACKUP_PREFIX="backups/vps/mariadb"

log() { echo "[$(date +%H:%M:%S)] $*"; }

log "Listing recent backups in s3://${AWS_S3_BUCKET}/${BACKUP_PREFIX}/ ..."
aws s3 ls "s3://${AWS_S3_BUCKET}/${BACKUP_PREFIX}/" \
  --endpoint-url "${AWS_S3_ENDPOINT}" \
  | sort -r | head -10

echo
read -rp "Enter exact filename to restore (e.g. mariadb_${MARIADB_DB}_20260505_030000.sql.gz): " BACKUP_FILE
[[ -z "${BACKUP_FILE}" ]] && { echo "No filename — abort."; exit 1; }

echo
echo "============================================================"
echo " DESTRUCTIVE: this will DROP and recreate database '${MARIADB_DB}'"
echo " Source:      s3://${AWS_S3_BUCKET}/${BACKUP_PREFIX}/${BACKUP_FILE}"
echo "============================================================"
read -rp "Type the database name to confirm: " CONFIRM
[[ "${CONFIRM}" != "${MARIADB_DB}" ]] && { echo "Mismatch — abort."; exit 1; }

log "Dropping and recreating ${MARIADB_DB}..."
docker exec -i \
  -e MYSQL_PWD="${MARIADB_ROOT_PASSWORD}" \
  mariadb mariadb -u root <<SQL
DROP DATABASE IF EXISTS \`${MARIADB_DB}\`;
CREATE DATABASE \`${MARIADB_DB}\`
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
SQL

log "Streaming ${BACKUP_FILE} from S3 → mariadb..."
aws s3 cp "s3://${AWS_S3_BUCKET}/${BACKUP_PREFIX}/${BACKUP_FILE}" - \
  --endpoint-url "${AWS_S3_ENDPOINT}" \
  | gunzip \
  | docker exec -i \
      -e MYSQL_PWD="${MARIADB_ROOT_PASSWORD}" \
      mariadb mariadb -u root "${MARIADB_DB}"

log "Restore complete. Re-run 'make fpp-mariadb-setup' to ensure fpp user grants are intact."
