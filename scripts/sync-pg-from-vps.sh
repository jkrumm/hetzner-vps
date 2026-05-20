#!/usr/bin/env bash
# =============================================================================
# Direct VPS → local Postgres whole-DB sync via SSH (Tailscale). Dev-only.
#
# Streams a fresh pg_dump of the entire prod database directly into the local
# dev container. No S3 round trip, no temp files — the dump rides the SSH tunnel.
#
# Why this over restore-pg-local.sh (S3 path)?
#   - Always fresh (vs. up to 24h stale from nightly backup).
#   - Faster: no upload to B2 + re-download.
#   - No secrets cross the wire — the dump is gzipped over SSH; pg_dump inside
#     the prod container authenticates via the local socket (no password).
#
# When to use the S3 path instead: validating the actual DR chain works, or
# restoring a specific point-in-time version (restore-pg-local.sh BACKUP_FILE=).
#
# WARNING: drops and recreates the entire local ${POSTGRES_DB} — every local
# schema is replaced. For a single app's schema only, use
# sync-pg-schema-from-vps.sh.
#
# Prerequisites:
#   - `ssh vps` resolves (Tailscale up + SSH config in ~/.ssh/config).
#   - Local `postgres` container running (make up).
#   - Local + remote POSTGRES_DB / superuser match (same op item).
#
# Usage:  make sync-from-prod
#
# Required local env (resolved by op run --env-file=.env.tpl):
#   POSTGRES_DB, POSTGRES_USER, POSTGRES_PASSWORD
# =============================================================================
set -euo pipefail

log() { echo "[$(date +%H:%M:%S)] $*"; }

docker inspect -f '{{.State.Status}}' postgres >/dev/null 2>&1 || {
  echo "ERROR: local 'postgres' container not running. Run 'make up' first."; exit 1;
}

log "Dropping and recreating local database ${POSTGRES_DB}..."
docker exec -i -e PGPASSWORD="${POSTGRES_PASSWORD}" postgres \
  dropdb -U "${POSTGRES_USER}" --if-exists --force "${POSTGRES_DB}"
docker exec -i -e PGPASSWORD="${POSTGRES_PASSWORD}" postgres \
  createdb -U "${POSTGRES_USER}" "${POSTGRES_DB}"

log "Streaming pg_dump from VPS over SSH (custom format, compressed)..."
# Remote pg_dump runs inside the prod postgres container and authenticates via
# the local unix socket (trust) — no password leaves the VPS. Stdout (custom
# format) flows back through SSH into the local pg_restore.
ssh vps "docker exec postgres pg_dump -U '${POSTGRES_USER}' -d '${POSTGRES_DB}' --format=custom --compress=9" \
  | docker exec -i -e PGPASSWORD="${POSTGRES_PASSWORD}" postgres \
      pg_restore -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" --no-owner --no-privileges

log "Re-applying schema grants (setup-postgres.sh) — dropdb wiped per-DB grants..."
"$(dirname "$0")/setup-postgres.sh"

log "Sync complete. Schema summary:"
docker exec -i -e PGPASSWORD="${POSTGRES_PASSWORD}" postgres \
  psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -P pager=off -c \
  "SELECT schemaname, count(*) AS tables, COALESCE(sum(n_live_tup),0) AS approx_rows
     FROM pg_stat_user_tables GROUP BY schemaname ORDER BY schemaname;"
