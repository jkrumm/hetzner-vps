# pg-health cron env template — materialized to /etc/vps/pg-health.env via
# `make cron-env-seed` (scripts/seed-cron-env.sh, `op inject`).
#
# Why this exists: the pg-health cron used to call `op run --env-file=.env.tpl`
# every minute, which resolves ~30 secrets per run — 1Password rate-limits
# that frequency and silently kills the monitor. This template is scoped to
# only what health-pg.sh needs, seeded once, and re-seeded manually after
# rotating any referenced secret (`make cron-env-seed`).

POSTGRES_DB=op://vps/config/POSTGRES_DB
POSTGRES_USER=op://vps/config/POSTGRES_USER
UPTIME_KUMA_POSTGRES_PUSH_URL=op://vps/config/UPTIME_KUMA_POSTGRES_PUSH_URL
