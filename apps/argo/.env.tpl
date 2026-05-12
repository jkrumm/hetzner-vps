# argo scoped env template — materialized via `op inject` to apps/argo/.env
# so RollHook's `docker compose up --scale` (which doesn't go through `op run`)
# can resolve ${VAR} interpolations in apps/argo/compose.yml.
#
# Refresh after rotating any secret:
#   make argo-env
#
# The resulting apps/argo/.env is gitignored, chmod 644, lives on VPS only.

DOMAIN=op://vps/config/DOMAIN
HOMELAB_TAILSCALE_IP=op://common/config/HOMELAB_TAILSCALE_IP

# --- argo API ---
API_SECRET=op://common/api/SECRET
TICKTICK_API_KEY=op://common/ticktick/API_KEY
UPTIME_KUMA_USERNAME=jkrumm
UPTIME_KUMA_PASSWORD=op://common/uptime-kuma/PASSWORD
UPTIME_KUMA_API_KEY=op://common/uptime-kuma/API_KEY
SLACK_BOT_TOKEN=op://common/slack/BOT_TOKEN
SLACK_USER_TOKEN=op://common/slack/USER_TOKEN
GOOGLE_CLIENT_ID=op://common/google-oauth/CLIENT_ID
GOOGLE_CLIENT_SECRET=op://common/google-oauth/CLIENT_SECRET

# Garmin: argo only needs the bearer to talk to homelab's garmin-collector.
# Email/password stay in homelab vault — only the collector consumes them.
GARMIN_COLLECTOR_TOKEN=op://common/garmin-collector/TOKEN
# UK push URL — argo's garmin-sync cron pings after each successful pull.
GARMIN_HEARTBEAT_URL=op://common/garmin-collector/PUSH_URL

# --- Postgres (shared VPS postgres, schema `argo`) ---
POSTGRES_DB=op://vps/config/POSTGRES_DB
ARGO_DB_PASSWORD=op://vps/argo/DB_PASSWORD
