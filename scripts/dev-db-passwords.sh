#!/usr/bin/env bash
# =============================================================================
# Converge the LOCAL dev superuser passwords onto .env.dev.tpl. Dev-only.
#
# Why this is needed at all
# -------------------------
# Both images apply their password variable ONLY when initializing an empty data
# directory. `POSTGRES_PASSWORD` / `MARIADB_ROOT_PASSWORD` are read by the
# entrypoint on first init and ignored on every subsequent start. So a volume
# created before the dev-only credentials existed keeps whatever password
# initialized it — silently. Nothing warns, the containers come up healthy, the
# healthchecks pass (they use the unix socket), and `make postgres-setup`
# succeeds (also the socket). Only a TCP connection using the template's value
# fails, which is every app.
#
# Measured on the mini 2026-08-02: vps_postgres-dev-data and vps_mariadb-dev-data
# were both created 2026-05-24, so both still held the values from the old
# whole-.env.tpl era. Verified by recomputing the SCRAM verifier rather than
# guessed.
#
# This is idempotent and safe to re-run: on a freshly-initialized volume it is a
# no-op, because the password already matches.
#
# Usage:  make dev-db-passwords
#
# Required env (resolved by secrets-run run --env-file=.env.dev.tpl):
#   POSTGRES_DB, POSTGRES_USER, POSTGRES_PASSWORD, MARIADB_ROOT_PASSWORD
# =============================================================================
set -euo pipefail

log() { echo "[$(date +%H:%M:%S)] $*"; }

docker inspect -f '{{.State.Status}}' postgres >/dev/null 2>&1 || {
  echo "ERROR: local 'postgres' container not running. Run 'make up' first."; exit 1;
}

# --- Postgres ----------------------------------------------------------------
# Reachable without the CURRENT password: the image's pg_hba.conf has
# `local all all trust`, so a `docker exec` over the unix socket authenticates
# unconditionally. That is what makes this convergeable in place, with no data
# loss and without needing prod's credential anywhere.
#
# `-v pw=` + `:'pw'` has psql do the quoting, so a password containing a quote
# or backslash cannot break out of the statement — and the password never appears
# in argv, where `ps auxww` would show it.
#
# The statement goes in on STDIN, not `-c`: psql does not interpolate variables
# into a `-c` string, it ships it to the server verbatim, and the server then
# fails on the literal `:'pw'` with a syntax error. Interpolation only happens on
# the script path.
log "Converging the Postgres superuser password..."
printf "%s\n" "ALTER ROLE CURRENT_USER WITH PASSWORD :'pw';" \
  | docker exec -i \
      -e PGOPTIONS=--client-min-messages=warning \
      postgres psql -v ON_ERROR_STOP=1 -q \
      -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
      -v pw="${POSTGRES_PASSWORD}" >/dev/null
log "  ✓ postgres superuser now matches .env.dev.tpl"

# --- MariaDB -----------------------------------------------------------------
# Deliberately NOT converged here, because it cannot be. MariaDB's root has no
# socket-trust equivalent (`docker exec mariadb mariadb -u root` returns
# ERROR 1045), so changing the password requires knowing the CURRENT one — which
# on a stale volume is prod's op://vps/mariadb/ROOT_PASSWORD, deliberately absent
# from this machine's cache. Fetching it here would defeat the entire point of
# the dev-only split.
#
# So: report accurately and name both routes. Do not "fix" this by caching the
# prod ref.
if ! docker inspect -f '{{.State.Status}}' mariadb >/dev/null 2>&1; then
  log "  · mariadb container not running — skipping its check"
  exit 0
fi

if docker exec -e MYSQL_PWD="${MARIADB_ROOT_PASSWORD}" mariadb \
     mariadb -h 127.0.0.1 -u root -e "select 1" >/dev/null 2>&1; then
  log "  ✓ mariadb root already matches .env.dev.tpl — nothing to do"
  exit 0
fi

cat <<'EOF'

  ! mariadb root does NOT match .env.dev.tpl, and this script cannot fix it.
    Its volume predates the dev-only credentials, and changing a MariaDB
    password requires the current one — which is prod's, and is deliberately
    not cached on this machine.

    Two ways out, both fine:

      a) Recreate the volume (loses local FPP dev data, which is re-syncable):
           make down
           docker volume rm vps_mariadb-dev-data
           make up                  # re-inits with the dev-only password
           make fpp-sync-from-prod  # repopulate; needs no credential

      b) From the MacBook, where prod's password resolves:
           ALTER USER 'root'@'%' IDENTIFIED BY '<the dev-only password>';

EOF
exit 1
