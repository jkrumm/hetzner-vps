# hetzner-vps — Claude Code Instructions

## Repo Purpose

Infrastructure-as-code for Hetzner CX43 VPS (8 vCPU, 16 GB RAM, 160 GB SSD, Ubuntu 24.04).
Solo developer setup. Docker Compose only — no Swarm, no Kubernetes.

## Stack Overview

- **Traefik v3** — reverse proxy, HTTPS via Cloudflare DNS-01 wildcard cert
- **PostgreSQL 18** — primary database (manual updates only)
- **Valkey 9** — cache/queue (`container_name: redis` for app compatibility)
- **CrowdSec** — IP threat protection + Traefik bouncer plugin
- **WUD** — container update tracking with Pushover notifications
- **OTel Collector** — telemetry pipeline to SigNoz on homelab
- **Beszel Agent + Dozzle** — metrics/logs to homelab hubs, Tailscale transport

## Docker Networks

All external networks must be created before first `make up` (done by `setup.sh`).

| Network | Purpose |
|-|-|
| `proxy` | Traefik-routed services (apps connect here) |
| `postgres-net` | Postgres access (apps connect here for DB) |
| `valkey-net` | Valkey access (apps connect here for cache) |
| `monitoring-net` | Internal: OTel, CrowdSec, Beszel, Dozzle |
| `socket-proxy-net` | Internal: Traefik/WUD → docker-socket-proxy |

## Doppler Setup

Project: `hetzner-vps`, config: `prd`

All secrets managed in Doppler. Never write actual values anywhere in this repo.
Variable names documented in `.env.example`.

Deploy always with: `doppler run -- docker compose up -d`
Or use Makefile: `make up`

## Makefile Commands

| Command | Purpose |
|-|-|
| `make up` | Start core infra (Traefik, Postgres, Valkey, CrowdSec) |
| `make down` | Stop core infra |
| `make monitoring-up` | Start monitoring stack |
| `make monitoring-down` | Stop monitoring stack |
| `make logs` | Follow logs from core stack |
| `make ps` | Show running containers |
| `make backup` | Trigger manual pg_dump backup |
| `make firewall` | Apply Hetzner Cloud Firewall rules via hcloud CLI |
| `make shell-postgres` | Open psql shell in running Postgres container |

## Deployment Order

1. `setup.sh` (once, on fresh server)
2. Connect Tailscale + update SSH ListenAddress
3. `make firewall`
4. `make up`
5. `make monitoring-up`
6. CrowdSec: `docker exec crowdsec cscli capi register` + `cscli bouncers add traefik-bouncer`
7. Add `CROWDSEC_BOUNCER_KEY` to Doppler → `make up` (Traefik picks up new key)

## Backup Schedule

Daily at 3:00 AM via `/etc/cron.d/pg-backup`.
Retention: 14 days.
Uptime Kuma push monitor URL: stored in Doppler as `UPTIME_KUMA_PUSH_URL`.

## Postgres/Valkey Manual Upgrade Procedure

1. `make backup` — always backup first
2. Update image tag in `compose.yml`
3. `docker compose pull <service>`
4. `docker compose up -d <service>`
5. Verify: `make shell-postgres` → `SELECT version();`

For Postgres **major version** upgrade: use pg_dump/restore (see restore-pg.sh) or pg_upgrade.

## Security Rules

- Never expose Postgres (5432) or Valkey (6379) ports in compose files
- Never add `ports:` to monitoring services (Beszel, Dozzle communicate via Tailscale)
- SSH is Tailscale-only — never add SSH to Hetzner Cloud Firewall rules
- All secrets, IPs, hostnames, tokens go in Doppler — never in this repo
- Use placeholders in docs: `<your-domain>`, `<tailscale-ip>`, `<see-doppler>`

## Traefik Configuration

Static config: `traefik/traefik.yml`
Dynamic config (middlewares): `traefik/dynamic/middlewares.yml`
ACME certs: `traefik/acme.json` (gitignored, chmod 600)

Standard middleware chain for all routers:
```
traefik.http.routers.<name>.middlewares=crowdsec@file,rate-limit@file,security-headers@file
```

## App Integration Pattern

Apps in separate repos connect via:
- `proxy` network (for Traefik routing)
- `postgres-net` (if using Postgres)
- `valkey-net` (if using Valkey/Redis)

Hostname references: `postgres:5432`, `redis:6379`, `otel-collector:4317`

## CrowdSec Notes

After first deploy, run once:
```bash
docker exec crowdsec cscli capi register
docker exec crowdsec cscli collections install crowdsecurity/traefik
docker exec crowdsec cscli bouncers add traefik-bouncer
```
Copy the generated key to Doppler as `CROWDSEC_BOUNCER_KEY`, then restart Traefik.
