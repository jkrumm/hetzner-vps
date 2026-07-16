#!/usr/bin/env bash
# =============================================================================
# Direct VPS → local MariaDB sync via SSH (Tailscale). Dev-only.
#
# Streams a fresh mariadb-dump from the prod container directly into the local
# dev container. No S3 round trip, no temp files, no public exposure of the DB
# protocol — the dump rides the SSH tunnel.
#
# Why this over restore-mariadb-local.sh (S3 path)?
#   - Always fresh (vs. up to 24h stale from nightly backup).
#   - Faster: no upload to B2 + re-download.
#   - No secrets cross the wire — VPS resolves MARIADB_ROOT_PASSWORD itself
#     via its own op service account, the dump is gzipped over SSH.
#
# When to use the S3 path instead: validating the actual DR chain works.
#
# Needs NO local 1Password access, so it runs anywhere — headless Mac mini
# included. Both halves resolve their own credentials where they already live:
#   - PROD: the VPS resolves MARIADB_ROOT_PASSWORD itself via its op service
#     account, inside the `ssh vps ... op run` below. Nothing prod ever reaches
#     this machine except the dump on stdout.
#   - LOCAL: the root password is read from the dev container's OWN environment
#     (compose.dev.yml started it with MARIADB_ROOT_PASSWORD already set), so
#     the credential never enters the host shell. Same trick as fpp's
#     scripts/db-setup-local.sh.
#
# Prerequisites:
#   - `ssh vps` resolves (Tailscale up + SSH config in ~/.ssh/config).
#   - Local `mariadb` container running (make up).
#
# Usage:  make fpp-sync-from-prod
# =============================================================================
set -euo pipefail

log() { echo "[$(date +%H:%M:%S)] $*"; }

CONTAINER="${MARIADB_CONTAINER:-mariadb}"

docker inspect -f '{{.State.Status}}' "$CONTAINER" >/dev/null 2>&1 || {
  echo "ERROR: local '$CONTAINER' container not running. Run 'make up' first."; exit 1;
}

# Database name (not a secret) — take it from the container unless overridden.
MARIADB_DB="${MARIADB_DB:-$(docker exec "$CONTAINER" printenv MARIADB_DATABASE)}"
[[ -n "${MARIADB_DB}" ]] || { echo "ERROR: could not resolve MARIADB_DB."; exit 1; }

# In every `docker exec` below the `sh -c` body is single-quoted so the HOST
# shell leaves it alone — $MARIADB_ROOT_PASSWORD expands inside the container,
# from the container's env. Heredocs/SQL stay unquoted so the host expands the
# values it does own (the DB name).
log "Recreating local database ${MARIADB_DB}..."
docker exec -i "$CONTAINER" \
  sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb -u root' <<SQL
DROP DATABASE IF EXISTS \`${MARIADB_DB}\`;
CREATE DATABASE \`${MARIADB_DB}\`
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
SQL

log "Streaming mariadb-dump from VPS over SSH (TLS skipped on internal docker net)..."
# Remote command: VPS resolves its own secrets via op service account, runs
# docker exec → mariadb-dump → gzip. Stdout flows back through SSH to our pipe.
# --ssl-verify-server-cert=0 matches backup-mariadb.sh — the wildcard cert CN
# (*.free-planning-poker.com) doesn't match the internal hostname `mariadb`, but encryption
# still applies via --require-secure-transport=ON.
ssh vps 'cd ~/vps && op run --env-file=.env.tpl -- bash -c "
  docker exec -e MYSQL_PWD=\"\$MARIADB_ROOT_PASSWORD\" mariadb mariadb-dump \
    --user=root \
    --ssl-verify-server-cert=0 \
    --single-transaction \
    --routines --triggers --events \
    --databases \"\$MARIADB_DB\" \
  | gzip
"' \
  | gunzip \
  | docker exec -i "$CONTAINER" \
      sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb -u root "$1"' \
      sh "${MARIADB_DB}"

log "Sync complete. Table summary:"
docker exec -i "$CONTAINER" \
  sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb -u root "$1" -e "$2"' \
  sh "${MARIADB_DB}" "
SELECT TABLE_NAME, TABLE_ROWS
  FROM information_schema.TABLES
 WHERE TABLE_SCHEMA='${MARIADB_DB}'
 ORDER BY TABLE_ROWS DESC;"
