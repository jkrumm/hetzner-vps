#!/usr/bin/env bash
# =============================================================================
# PostgreSQL liveness check — runs SELECT 1 inside the postgres container,
# pushes result to Uptime Kuma with query latency. Triggered by cron every
# minute (see cron/pg-health). Reports query latency as the ping value.
#
# Required env vars (sourced from /etc/vps/pg-health.env — see cron/pg-health):
#   POSTGRES_DB, POSTGRES_USER
#   UPTIME_KUMA_POSTGRES_PUSH_URL
# =============================================================================
set -euo pipefail

ping_kuma() {
  local status="$1" msg="$2" ping="${3:-}"
  [[ -n "${UPTIME_KUMA_POSTGRES_PUSH_URL:-}" ]] || return 0
  # --max-time is load-bearing: this runs every minute, and an unreachable Kuma
  # would otherwise hang on curl's ~2min default connect timeout, piling up
  # overlapping cron jobs. The push is best-effort — bound it and move on.
  curl -fsSL --max-time 10 "${UPTIME_KUMA_POSTGRES_PUSH_URL}?status=${status}&msg=${msg}&ping=${ping}" \
    >/dev/null 2>&1 || true
}

START=$(date +%s%3N)
if docker exec postgres psql -tAc "SELECT 1" \
     -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1; then
  ping_kuma up ok "$(( $(date +%s%3N) - START ))"
else
  ping_kuma down query_failed
  exit 1
fi
