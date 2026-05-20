#!/usr/bin/env bash
# =============================================================================
# MariaDB restore from S3 → OVERWRITES the PRODUCTION FPP database.
#
# THIS IS A LAST-RESORT DISASTER-RECOVERY TOOL. There is deliberately NO `make`
# target for it. It is heavily gated (see guard below). Read
# docs/disaster-recovery.md FIRST.
#
# Usage (human, deliberate):
#   op run --env-file=.env.tpl -- ./apps/fpp/scripts/restore-mariadb.sh
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

# ─── PRODUCTION RESTORE GUARD ────────────────────────────────────────────────
# Overwrites PROD. No make target. Human-only. See docs/disaster-recovery.md.
#   1. refuses on passwordless-sudo hosts (the VPS) unless BREAK_GLASS=1
#   2. requires a real sudo password (proves a present human / local machine)
#   3. requires typing the exact database name
echo
echo "##############################################################"
echo "#  DANGER: about to DROP & RESTORE the PRODUCTION database.   #"
echo " Source: s3://${AWS_S3_BUCKET}/${BACKUP_PREFIX}/${BACKUP_FILE}"
echo "##############################################################"
sudo -k 2>/dev/null || true
if [[ "${BREAK_GLASS:-}" != "1" ]] && sudo -n true 2>/dev/null; then
  echo "REFUSED: passwordless sudo detected — this looks like the VPS."
  echo "Run from your local machine (password-protected sudo). For genuine"
  echo "on-server DR, re-run with BREAK_GLASS=1. See docs/disaster-recovery.md."
  exit 1
fi
echo "Authenticate as a human operator (sudo password required):"
sudo -v
read -rp "Type the database name to confirm: " CONFIRM
[[ "${CONFIRM}" != "${MARIADB_DB}" ]] && { echo "Mismatch — abort."; exit 1; }
# ─────────────────────────────────────────────────────────────────────────────

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

log "Restore complete. Run 'make fpp-mariadb-setup' to ensure fpp user grants are intact."
