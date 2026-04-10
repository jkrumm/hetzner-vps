# VPS .env.tpl — secrets and config via 1Password
# Usage: op run --env-file=.env.tpl -- docker compose up -d

# --- Cloudflare ---
CF_API_TOKEN=op://common/cloudflare/DNS_API_TOKEN
CLOUDFLARE_TUNNEL_TOKEN=op://vps/cloudflare-tunnel/TOKEN

# --- Postgres ---
POSTGRES_DB=op://vps/config/POSTGRES_DB
POSTGRES_USER=op://vps/config/POSTGRES_USER
POSTGRES_PASSWORD=op://vps/postgres/PASSWORD

# --- Services ---
UMAMI_DB_PASSWORD=op://vps/umami/DB_PASSWORD
UMAMI_APP_SECRET=op://vps/umami/APP_SECRET
ROLLHOOK_SECRET=op://vps/rollhook/SECRET
BESZEL_AGENT_KEY=op://vps/beszel/AGENT_KEY
EXPRESS_SESSION_SECRET=op://vps/clickstack/EXPRESS_SESSION_SECRET

# --- Notifications ---
SLACK_WATCHTOWER_URL=op://common/slack/WATCHTOWER_URL

# --- Backups ---
AWS_ACCESS_KEY_ID=op://common/backblaze-s3/ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY=op://common/backblaze-s3/SECRET_ACCESS_KEY
AWS_S3_BUCKET=op://common/backblaze-s3/BUCKET
AWS_S3_ENDPOINT=op://common/backblaze-s3/ENDPOINT

# --- Registry ---
ZOT_PASSWORD=op://common/zot/PASSWORD

# --- Monitoring ---
UPTIME_KUMA_PUSH_URL=op://vps/config/UPTIME_KUMA_PUSH_URL

# --- Network config ---
VPS_TAILSCALE_IP=op://vps/config/VPS_TAILSCALE_IP
DOMAIN=op://vps/config/DOMAIN
ACME_EMAIL=op://vps/config/ACME_EMAIL
