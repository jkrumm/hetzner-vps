#!/usr/bin/env bash
set -euo pipefail

# Idempotent Postgres schema + user setup.
# Runs against the main Postgres database (${POSTGRES_DB}).
# Each app gets its own schema and a dedicated user with schema-only access.
# Run via: make postgres-setup
# Requires: postgres container running, Doppler secrets in environment.

psql_main() {
  docker exec -i postgres psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" "$@"
}

echo "==> Setting up Postgres schemas and users..."

# ---------------------------------------------------------------------------
# Umami analytics — schema: umami, user: umami
# ---------------------------------------------------------------------------
echo "--> umami"

psql_main <<SQL
-- Create schema if not exists
CREATE SCHEMA IF NOT EXISTS umami;

-- pgcrypto must be created by superuser; place it in umami schema so Prisma
-- migration's "CREATE EXTENSION IF NOT EXISTS pgcrypto" finds it there
CREATE EXTENSION IF NOT EXISTS pgcrypto SCHEMA umami;

-- Create role if not exists, always sync password (for Doppler rotations)
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'umami') THEN
    CREATE ROLE umami WITH LOGIN PASSWORD '${UMAMI_DB_PASSWORD}';
  ELSE
    ALTER ROLE umami WITH PASSWORD '${UMAMI_DB_PASSWORD}';
  END IF;
END
\$\$;

-- Grant database connect
GRANT CONNECT ON DATABASE "${POSTGRES_DB}" TO umami;

-- Grant schema access (no access to public schema)
GRANT USAGE, CREATE ON SCHEMA umami TO umami;

-- Grants on existing + future objects in umami schema
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA umami TO umami;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA umami TO umami;
ALTER DEFAULT PRIVILEGES IN SCHEMA umami GRANT ALL ON TABLES TO umami;
ALTER DEFAULT PRIVILEGES IN SCHEMA umami GRANT ALL ON SEQUENCES TO umami;
SQL

# ---------------------------------------------------------------------------
# Future apps: add blocks here following the same pattern
# ---------------------------------------------------------------------------

echo "==> Postgres setup complete."
