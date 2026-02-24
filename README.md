# hetzner-vps

Production Docker Compose stack for Hetzner CX43 VPS. Serves as the infrastructure foundation for all deployed applications.

## Architecture

```
Internet (:80/:443)
    │
Cloudflare DNS (grey cloud — DNS only, wildcard cert via DNS-01 ACME)
    │
Hetzner Cloud Firewall — allow 80, 443 only
    │
UFW — second layer, deny all except 80/443 + tailscale0
    │
Traefik v3 ─── middleware chain: CrowdSec → rate-limit → security-headers
    ├── app-1 (external: proxy network)
    └── app-2 (external: proxy network)
         │
Internal networks (never exposed publicly):
    ├── postgres-net  → postgres (PostgreSQL 18)
    ├── valkey-net    → redis    (Valkey 9, hostname: redis)
    └── monitoring-net
            ├── otel-collector ──→ SigNoz on homelab (Tailscale)
            ├── beszel-agent   ──→ Beszel hub on homelab (Tailscale)
            └── dozzle         ──→ Dozzle hub on homelab (Tailscale)

SSH: Tailscale only (no public port)
WUD: container update tracking, accessible via Tailscale
```

## Stack

| Service | Image | Purpose | Updates |
|-|-|-|-|
| socket-proxy | tecnativa/docker-socket-proxy | Secure Docker API | MINOR auto |
| traefik | traefik:v3 | Reverse proxy + HTTPS | MINOR auto |
| postgres | postgres:18 | Primary database | notify only |
| valkey | valkey/valkey:9 | Cache/queues (`hostname: redis`) | notify only |
| crowdsec | crowdsecurity/crowdsec | IP threat protection | MINOR auto |
| otel-collector | otel/opentelemetry-collector-contrib | Telemetry → SigNoz | MINOR auto |
| beszel-agent | henrygd/beszel-agent | Server metrics | MINOR auto |
| dozzle | amir20/dozzle | Log viewer (agent mode) | MINOR auto |
| wud | fmartinou/whats-up-docker | Update tracking + Pushover | MINOR auto |

## Prerequisites

- Hetzner CX43 server with Ubuntu 24.04
- Tailscale account (VPS and homelab connected to same tailnet)
- Cloudflare account with domain registered (Cloudflare DNS)
- Doppler account with `hetzner-vps` project configured
- hcloud CLI installed and authenticated locally

## Initial VPS Setup

Run on a fresh server as root:

```bash
# Clone repo first
git clone https://github.com/jkrumm/hetzner-vps /home/jkrumm/hetzner-vps

# Run setup script
bash /home/jkrumm/hetzner-vps/scripts/setup.sh
```

The script will:
1. Create user `jkrumm` with SSH keys from GitHub
2. Harden SSH (key-only, no root login)
3. Configure sysctl (kernel hardening, `vm.overcommit_memory=1` for Valkey)
4. Set up UFW (allow 80/443 + all Tailscale traffic)
5. Enable unattended-upgrades (OS security only)
6. Install Docker, awscli, Doppler CLI, hcloud CLI, Tailscale
7. Create Docker networks
8. Install cron job for daily Postgres backup

**Post-setup steps (manual):**

```bash
# 1. Connect to Tailscale
sudo tailscale up

# 2. Update SSH to bind to Tailscale interface only
# Edit /etc/ssh/sshd_config.d/99-hardening.conf
# Uncomment: ListenAddress <your-tailscale-ip>
# Then: systemctl restart sshd

# 3. Configure Doppler (as jkrumm)
su - jkrumm
doppler login
doppler setup   # select project: hetzner-vps, config: prd

# 4. Apply Hetzner Cloud Firewall
cd ~/hetzner-vps
make firewall
# Then in hcloud dashboard: assign firewall to server

# 5. Start stacks
make up
make monitoring-up

# 6. Register CrowdSec
docker exec crowdsec cscli capi register
# Generates CROWDSEC_BOUNCER_KEY — add to Doppler, then restart traefik
docker exec crowdsec cscli bouncers add traefik-bouncer
```

## Deployment

```bash
# Start core infra (Traefik, Postgres, Valkey, CrowdSec)
make up

# Start monitoring (OTel, Beszel, Dozzle, WUD)
make monitoring-up

# View all running containers
make ps

# Follow logs
make logs
```

## Secrets (Doppler)

Project: `hetzner-vps`, config: `prd`

Required variables are documented in `.env.example` (names only — all values in Doppler).

Key variables:
- `DOMAIN` — your apex domain (wildcard cert covers `*.<domain>`)
- `CF_DNS_API_TOKEN` — Cloudflare API token (Zone:DNS:Edit)
- `POSTGRES_*` — database credentials
- `CROWDSEC_BOUNCER_KEY` — generated after CrowdSec setup
- `AWS_*` — object storage credentials for backups
- `UPTIME_KUMA_PUSH_URL` — backup heartbeat monitor URL
- `WUD_TRIGGER_PUSHOVER_*` — Pushover notification credentials
- `BESZEL_AGENT_KEY` — from Beszel hub (Settings > Add System)
- `SIGNOZ_OTLP_ENDPOINT` — SigNoz OTLP endpoint via Tailscale

## Connecting an App

Each app repo needs:

```yaml
# compose.yml (in app repo)
networks:
  proxy:
    external: true
  postgres-net:      # only if app uses Postgres
    external: true

services:
  myapp:
    image: ghcr.io/jkrumm/myapp:latest
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.myapp.rule=Host(`app.<your-domain>`)"
      - "traefik.http.routers.myapp.entrypoints=websecure"
      - "traefik.http.routers.myapp.tls.certresolver=letsencrypt"
      - "traefik.http.services.myapp.loadbalancer.server.port=3000"
      - "traefik.http.routers.myapp.middlewares=crowdsec@file,rate-limit@file,security-headers@file"
      - "wud.tag.include=^\\d+\\.\\d+\\.\\d+$$"
      - "wud.watch=true"
    networks: [proxy, postgres-net]
    security_opt: [no-new-privileges:true]
    logging:
      driver: json-file
      options: { max-size: "10m", max-file: "3" }
    environment:
      DATABASE_URL: postgresql://user:pass@postgres:5432/mydb
      REDIS_URL: redis://redis:6379
      OTEL_EXPORTER_OTLP_ENDPOINT: http://otel-collector:4318
```

Deploy: `doppler run -- docker compose up -d`

App containers connect to `postgres` (hostname `postgres`) and Valkey (hostname `redis`).
OTel: send to `http://otel-collector:4317` (gRPC) or `http://otel-collector:4318` (HTTP). OTel collector must be on same network or use Tailscale IP.

## Backups

**Schedule:** Daily at 3:00 AM via cron (`cron/pg-backup`)

**Manual trigger:**
```bash
make backup
```

**What it does:**
1. Runs `pg_dump` in a one-shot `postgres:18` container
2. Streams compressed dump to object storage
3. Prunes backups older than 14 days
4. Pings Uptime Kuma push monitor (status: up on success, down on failure)

**Restore:**
```bash
# List available backups
./scripts/restore-pg.sh

# Restore specific backup
BACKUP_FILE=postgres_mydb_20260224_030000.dump ./scripts/restore-pg.sh
```

## Container Updates

WUD (What's Up Docker) monitors all containers and sends Pushover notifications.

**Policy:**
- MINOR auto-update: all infrastructure and monitoring services
- **Notify only** (manual update): `postgres`, `valkey` (redis)

**Dashboard:** Accessible via Tailscale at `http://<tailscale-ip>:3000`

**Upgrading Postgres or Valkey manually:**
```bash
# 1. Run a backup first
make backup

# 2. Pull new image and restart
docker compose pull postgres
docker compose up -d postgres

# 3. Verify
docker exec postgres psql -U $POSTGRES_USER -c "SELECT version();"
```

For Postgres **major version** upgrades (e.g., 18 → 19): use `pg_upgrade` or dump/restore.

## Monitoring

All monitoring services are accessible via Tailscale only:
- **Beszel** — server metrics (check homelab Beszel hub)
- **Dozzle** — container logs (check homelab Dozzle hub)
- **SigNoz** — traces, metrics, logs (check homelab SigNoz)
- **WUD** — update tracking at `http://<tailscale-ip>:3000`
- **Traefik** — dashboard at `https://traefik.<your-domain>` (Tailscale-only middleware)

## Firewall Management

```bash
make firewall
```

Applies Hetzner Cloud Firewall rules via hcloud CLI (IaC). Rules in `scripts/firewall.sh`.

After changing rules, assign firewall to server in hcloud dashboard if not already done.
