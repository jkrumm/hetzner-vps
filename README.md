# vps

Production Docker Compose stack for a VPS (12 vCPU · 24 GB · 180 GB SSD · Ubuntu 24.04). Single-node, no orchestration. Cloudflare Tunnel handles all public ingress — zero inbound ports on the server. Three compose stacks by concern: networking, infra, monitoring.

---

## Quick Reference

```bash
# Primary operations
make up              # start all stacks (networking → infra → monitoring → fpp)
make down            # stop all stacks (reverse order)
make ps              # container status

# Targeted restart (one stack)
make monitoring-up
make monitoring-down

# Postgres
make backup          # manual pg_dump → S3 (prod)
make shell-postgres  # psql shell
# Restoring PROD from S3 has NO make target by design — see docs/disaster-recovery.md

# Postgres — dev seeding / DR from prod (ENV=dev — gated)
make restore-local              # pull latest (or BACKUP_FILE=) S3 pg backup → local (validates DR chain). Drops whole DB.
make sync-from-prod             # whole-DB ssh+docker exec pg_dump VPS → local (fresh, no S3). Drops whole DB.
make pg-sync-schema SCHEMA=argo # one schema only (least-priv, leaves other schemas intact)

# FPP / MariaDB (apps/fpp/)
make fpp-up                  # start MariaDB (and fpp-server / fpp-analytics later)
make fpp-down
make fpp-mariadb-setup       # provision fpp user + grants (idempotent)
make fpp-cert-sync           # extract *.${DOMAIN} cert for MariaDB TLS
make fpp-backup              # manual mariadb-dump → S3
make fpp-shell               # mariadb shell as root

# Dev seeding from prod (ENV=dev — both gated)
make fpp-restore-local       # pull latest S3 backup into local mariadb (validates DR chain)
make fpp-sync-from-prod      # direct ssh+docker exec mariadb-dump from VPS → local (fresh, no S3)

# Ops
make firewall        # show UFW status

# Traefik cert debug
docker logs traefik 2>&1 | grep -i acme

# Local dev (Postgres + Valkey + ClickStack, ENV=dev in .env)
make up              # same command — detects ENV=dev automatically
make down
```

**Internal hostnames (container-to-container):**

| Service | Hostname | Port |
|-|-|-|
| PostgreSQL | `postgres` | `5432` |
| MariaDB (FPP) | `mariadb` | `3306` |
| Valkey/Redis | `redis` | `6379` |
| ClickStack OTel (gRPC) | `clickstack` | `4317` |
| ClickStack OTel (HTTP) | `clickstack` | `4318` |
| ClickStack UI (HyperDX) | `clickstack` | `8080` |

**External Docker networks (apps join these):**

| Network | Join when |
|-|-|
| `proxy` | Always — Traefik routing |
| `postgres-net` | App uses Postgres |
| `mariadb-net` | App uses FPP MariaDB |
| `valkey-net` | App uses Valkey/Redis |
| `monitoring-net` | App sends OTel telemetry |

---

## Architecture

```
Internet
  │
Cloudflare edge (Tunnel — outbound-only from VPS, zero inbound ports)
  │
cloudflared (compose.networking.yml)
  │
Traefik v3
  ├─ Wildcard TLS via Cloudflare DNS-01 ACME (*.<DOMAIN>)
  ├─ Middleware chain: rate-limit → security-headers
  ├─ Traefik dashboard (tailscale-only IP allowlist)
  ├─ app-1  (network: proxy)
  └─ app-2  (network: proxy)

Internal networks — never exposed publicly:
  postgres-net  ── postgres:5432
  valkey-net    ── redis:6379          (Valkey 9, hostname aliased to "redis")
  monitoring-net
    ├─ clickstack        all-in-one observability (ClickHouse + OTel + HyperDX UI)
    ├─ beszel-agent      pushes server + container metrics → Beszel hub
    └─ dozzle            streams container logs → Dozzle hub

Homelab connectivity: Tailscale
  VPS → Beszel hub, Dozzle hub (Tailscale IPs, no public ports)
  SSH → Tailscale only (sshd ListenAddress bound to tailscale0, port 22 firewalled)

Docker API access — no direct docker.sock mounts:
  socket-proxy             (read-only)  → Traefik
  socket-proxy-rollhook    (POST=1)     → RollHook
  socket-proxy-watchtower  (POST=1)     → Watchtower
  socket-proxy-monitoring  (read-only)  → Dozzle + Beszel
```

---

## Stack

| Service | Image | Purpose | Update policy |
|-|-|-|-|
| cloudflared | cloudflare/cloudflared | Public ingress via Cloudflare Tunnel | auto |
| socket-proxy | tecnativa/docker-socket-proxy | Read-only Docker API for Traefik | auto |
| traefik | traefik:v3 | Reverse proxy, TLS termination | auto |
| socket-proxy-rollhook | tecnativa/docker-socket-proxy | Write Docker API for RollHook | auto |
| rollhook | ghcr.io/jkrumm/rollhook | Zero-downtime rolling deployments via webhook | auto |
| postgres | postgres:18 | Primary DB — pinned major version | **manual only** |
| valkey | valkey/valkey:9 | Cache + queues — `container_name: redis` | **manual only** |
| clickstack | clickhouse/clickstack-all-in-one | Observability — OTel + ClickHouse + HyperDX UI. See [docs/observability.md](docs/observability.md) for the two-tier ingest design and how to add a service. | auto |
| beszel-agent | henrygd/beszel-agent | Server metrics agent | auto |
| dozzle | amir20/dozzle | Log streaming agent | auto |
| socket-proxy-monitoring | tecnativa/docker-socket-proxy | Read-only Docker API for Dozzle + Beszel | auto |
| socket-proxy-watchtower | tecnativa/docker-socket-proxy | Write Docker API for Watchtower | auto |
| watchtower | containrrr/watchtower | Auto-updates containers, Pushover on failure | auto |
| photo-gallery | nginx:alpine | Static Astro photo gallery — content rsynced from laptop via photo-flow CLI | auto |

---

## Design Decisions

**Cloudflare Tunnel, zero inbound ports.** cloudflared makes outbound connections to Cloudflare edge only. No ports 80/443 exposed on the host. DNS-01 ACME still issues a wildcard cert (`*.<DOMAIN>`) — required so cloudflared can verify the TLS handshake with Traefik internally.

**Four socket proxy instances, no docker.sock mounts.** Traefik gets read-only access (container/network enumeration). Dozzle and Beszel share a second read-only proxy scoped to CONTAINERS+LOGS+STATS. RollHook and Watchtower each get a dedicated proxy with POST=1 on isolated networks — write access never shared between them.

**SSH via Tailscale only.** `sshd` binds to the Tailscale interface IP only — nothing listens on port 22 of the public IP. UFW blocks all remaining public inbound. Zero SSH attack surface from the internet.

**Watchtower over WUD.** Auto-updates all containers except Postgres and Valkey (opted out via label). Pushover notifications at warn level (failures only — not every update). Postgres and Valkey are excluded: major version bumps can have data format implications, updates must be deliberate with a backup first.

**`container_name: redis` for Valkey.** Every app references `redis:6379` without modification.

**1Password for secrets.** All sensitive values in 1Password vaults `vps` + `common`. Zero secrets in the repo — `.env.tpl` contains only `op://` references. Variable names and setup instructions documented in the Secrets section below. Deploy always with `op run --env-file=.env.tpl -- docker compose up -d` (or `make up`).

**No Terraform.** Single-server setup doesn't justify state management overhead. UFW is the only firewall layer — the hosting provider has no panel firewall. This is sufficient given sshd binds to Tailscale only and cloudflared is outbound-only.

---

## Provisioning a Fresh Server

### 1. Create server

Order a VPS (Ubuntu 24.04) with a public IPv4. Add your SSH public key for root access via the hosting panel.

### 2. Run setup.sh

SSH as root, then:

```bash
git clone https://github.com/jkrumm/vps /home/jkrumm/vps
bash /home/jkrumm/vps/scripts/setup.sh
```

Creates user `jkrumm`, hardens SSH, applies sysctl, sets up UFW, installs Docker + toolchain (awscli, 1Password CLI, Tailscale), creates external Docker networks, drops cron job for Postgres backups.

### 3. Tailscale

```bash
sudo tailscale up --ssh --advertise-tags=tag:vps   # complete auth in browser
tailscale ip -4                                     # note the assigned Tailscale IP (100.x.x.x)
```

Then bind sshd to the Tailscale interface:
```bash
# Edit /etc/ssh/sshd_config.d/99-hardening.conf
# Uncomment and set: ListenAddress <tailscale-ip>
sudo systemctl restart ssh
# ⚠ Open a second SSH session via Tailscale IP to verify before closing this one
```

`--ssh` enables Tailscale SSH — identity-based auth via your Tailscale account, no SSH keys required once active. The `authorized_keys` populated by `setup.sh` is only needed for this bootstrap window.

Add the server to your local `~/.ssh/config`:
```
Host vps
    HostName <tailscale-ip>
    User jkrumm
```

SSH agent is handled globally via 1Password (`IdentityAgent` in `~/.ssh/config`).

### 4. 1Password CLI

```bash
# Add to ~/.bashrc as jkrumm:
export OP_SERVICE_ACCOUNT_TOKEN="<token>"
source ~/.bashrc
op vault list   # verify access to vps + common vaults
```

### 5. Verify secrets

All secrets are pre-populated in 1Password (`vps` + `common` vaults). See the **Secrets** section below.

### 6. Cloudflare Tunnel

Tunnel token already in 1Password (`vps/cloudflare-tunnel/TOKEN`). The `.env.tpl` references it automatically.

### 7. Firewall

HostingFuchs has no panel firewall, so UFW is the only host-level filter. UFW denies all inbound by default and only allows the Tailscale interface — that's sufficient for everything except FPP MariaDB.

**Note on Docker + UFW:** Docker publishes ports via its own iptables rules that bypass UFW entirely. Adding `ports: ["33306:3306"]` to `apps/fpp/compose.yml` makes MariaDB reachable on the public IP automatically — UFW does not block it. fail2ban operates on the `DOCKER-USER` chain (not the UFW chain) to ban auth-failure source IPs.

Verify UFW on the server: `make firewall`

### 8. Start the stack

```bash
make networking-up        # issues *.${DOMAIN} cert via DNS-01
make fpp-cert-sync        # extracts wildcard cert for MariaDB TLS
make up                   # full stack (networking → infra → monitoring → fpp)
make postgres-setup       # provision Postgres schemas + users
make fpp-mariadb-setup    # provision MariaDB fpp user + grants
```

Verify: `make ps` — all containers should be running within ~30 seconds.

Add a DNS-only A record `fpp-db.${DOMAIN}` → VPS public IP (grey cloud, **not** proxied — Cloudflare can't proxy MySQL).

### 9. Photo gallery host directory

```bash
mkdir -p /home/jkrumm/photo-gallery-dist
```

Content (built Astro `dist/`) is rsynced from the developer laptop by the `photo-flow` CLI — see `~/SourceRoot/photo-flow`. Sync at least an `index.html` before `make photo-gallery-up` so the healthcheck passes.

### 10. Cloudflare tunnel ingress + DNS

Use the `/cloudflare` Claude Code skill to set the wildcard ingress rule and add DNS records. The skill handles all API calls via `ssh vps "op run --env-file=.env.tpl --"` — the token never leaves 1Password.

- Set wildcard ingress: `*.DOMAIN → https://traefik:443` (once after provisioning)
- Add DNS record per app subdomain (CNAME → tunnel)

Traefik will issue a wildcard cert via DNS-01 on first request (may take 1–2 min — check `docker logs traefik | grep -i acme`).

> **Wildcard ingress scope:** Only matches requests already DNS-routed to the VPS tunnel. Other subdomains pointing to different tunnels (HomeLab, etc.) are unaffected.

---

## Secrets

1Password vaults: `vps` + `common`. No `.env` file with real values — `.env.tpl` contains only `op://` references.

**Domain + TLS**

| Variable | Value | How to get |
|-|-|-|
| `DOMAIN` | `example.com` | Your apex domain — wildcard cert covers `*.DOMAIN` |
| `ACME_EMAIL` | `you@example.com` | Email for Let's Encrypt notifications |
All Cloudflare env vars use the unified `CLOUDFLARE_*` prefix (matches the `/cloudflare` skill at `~/.claude/skills/cloudflare/`).

| Variable | Source | Notes |
|-|-|-|
| `CLOUDFLARE_API_TOKEN` | `op://common/cloudflare/DNS_API_TOKEN` | Cloudflare → My Profile → API Tokens → needs **DNS:Edit** + **Cloudflare Tunnel:Edit** for all zones. Same token as HomeLab. Traefik receives it as `CF_DNS_API_TOKEN` via `compose.networking.yml` env mapping (lego requires that exact name). |
| `CLOUDFLARE_ACCOUNT_ID` | `op://common/cloudflare/ACCOUNT_ID` | Account ID — same for all zones/tunnels. |
| `CLOUDFLARE_ZONE_ID` | `op://common/cloudflare/ZONE_ID_JKRUMM_COM` | Zone ID for `jkrumm.com`. Other zones (basalt-ui.com, rollhook.com, shutterflow.app) are looked up on demand by the skill. |
| `CLOUDFLARE_TUNNEL_ID` | `op://vps/cloudflare-tunnel/TUNNEL_ID` | UUID of the **VPS** tunnel (different from HomeLab's — separate tunnels). |
| `CLOUDFLARE_TUNNEL_TOKEN` | `op://vps/cloudflare-tunnel/TOKEN` | Per-server cloudflared auth. Cloudflare → Zero Trust → Networks → Tunnels → Create tunnel → copy token. |

**PostgreSQL**

| Variable | Value | How to get |
|-|-|-|
| `POSTGRES_USER` | `postgres` | Superuser name (default: `postgres`) |
| `POSTGRES_DB` | `postgres` | Default database name |
| `POSTGRES_PASSWORD` | `<generated>` | Generate: `openssl rand -hex 32` |

Apps create their own users and databases on top of this superuser.

**MariaDB (FPP)**

Single-tenant database for Free Planning Poker. Lives in `apps/fpp/` because it's exposed publicly on TCP 33306 — the deviation is quarantined out of shared infra. Vercel connects with `?ssl={"rejectUnauthorized":true}` against `fpp-db.${DOMAIN}`.

| Variable | Value | How to get |
|-|-|-|
| `MARIADB_DB` | `free-planning-poker` | Database name (in 1Password: `vps/config/MARIADB_DB`) |
| `MARIADB_ROOT_PASSWORD` | `<generated>` | Generate: `openssl rand -hex 32` — used by backup/restore/setup scripts |
| `MARIADB_FPP_PASSWORD` | `<generated>` | Generate: `openssl rand -hex 32` — application user (REQUIRE SSL) |
| `UPTIME_KUMA_FPP_BACKUP_PUSH_URL` | `https://...` | Separate Uptime Kuma monitor for the MariaDB backup cron |

**FPP application services** (`apps/fpp/compose.yml` — fpp-server, fpp-analytics, updater)

| Variable | Value | How to get |
|-|-|-|
| `FPP_SERVER_SECRET` | `<generated>` | `openssl rand -hex 32` — bearer token between Vercel and fpp-server |
| `FPP_SERVER_SENTRY_DSN` | `https://...@sentry.io/...` | Sentry project for fpp-server |
| `FPP_ANALYTICS_SECRET_TOKEN` | `<generated>` | `openssl rand -hex 32` — bearer token between Vercel and fpp-analytics |
| `FPP_ANALYTICS_SENTRY_DSN` | `https://...@sentry.io/...` | Sentry project for fpp-analytics |
| `FPP_BEA_BASE_URL` | `https://...` | Bun email API base URL (used by fpp-analytics for survey emails) |
| `FPP_BEA_SECRET_KEY` | `<secret>` | Auth key for the bun email API |
| `UPTIME_KUMA_FPP_ANALYTICS_UPDATER_PUSH_URL` | `https://...` | Heartbeat URL for the 10-min sync sidecar (separate Kuma monitor) |

**Backups (S3-compatible object storage)**

| Variable | Value | How to get |
|-|-|-|
| `AWS_ACCESS_KEY_ID` | `<key>` | Object storage provider access key |
| `AWS_SECRET_ACCESS_KEY` | `<secret>` | Object storage provider secret |
| `AWS_S3_BUCKET` | `<bucket>` | Bucket name |
| `AWS_S3_ENDPOINT` | `https://...` | S3-compatible provider endpoint URL |
| `UPTIME_KUMA_PUSH_URL` | `https://...` | Uptime Kuma → Add monitor → Push type → copy URL |

**Watchtower (Slack notifications)**

| Variable | Value | How to get |
|-|-|-|
| `SLACK_WATCHTOWER_URL` | `slack://hook:...@webhook` | `op read "op://common/slack/WATCHTOWER_URL" --account tkrumm` |

**Monitoring**

| Variable | Value | How to get |
|-|-|-|
| `BESZEL_AGENT_KEY` | `ssh-ed25519 AAAA...` | Beszel hub UI → Add System → address `<tailscale-ip>:45876` → copy SSH public key shown |
| `EXPRESS_SESSION_SECRET` | `<generated>` | Generate: `openssl rand -hex 32` — HyperDX session encryption |
| `HYPERDX_API_KEY` | `<ingestion-key>` | HyperDX UI → Team Settings → API Keys → Ingestion API Key. Auth header on OTLP export from Traefik (`op://vps/clickstack/HYPERDX_API_KEY_PROD`) |

**RollHook**

| Variable | Value | How to get |
|-|-|-|
| `ROLLHOOK_SECRET` | `<generated>` | In 1Password: `vps/rollhook/SECRET` |
| `ZOT_PASSWORD` | `<generated>` | In 1Password: `common/zot/PASSWORD` — used for `docker login rollhook.jkrumm.com` |
| `SLACK_WEBHOOK_URL` | reuses `SLACK_WATCHTOWER_URL` | Deploy success/failure pings to Slack `#updates`. No new op item — points at `op://common/slack/WATCHTOWER_URL`. |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://clickstack:4319` | Unauthed OTLP HTTP receiver on the docker bridge (see `clickstack/otel-custom.yaml`). RollHook is on `monitoring-net` to reach it. |
| `DEPLOY_ENVIRONMENT` | `prod` | Tag attached to deploy logs/markers. |

---

## Adding an App

Minimal `compose.yml` in the app repo:

```yaml
networks:
  proxy:
    external: true
  postgres-net:   # omit if app doesn't use Postgres
    external: true
  monitoring-net: # include to reach clickstack by hostname
    external: true

services:
  myapp:
    image: ${IMAGE_TAG:-ghcr.io/jkrumm/myapp:latest}
    # NO container_name — RollHook must scale to 2 instances during rollout
    # NO ports — Traefik routes via Docker DNS; ports prevent scaling
    healthcheck:
      test: [CMD, curl, -f, http://localhost:3000/health]
      interval: 5s
      timeout: 5s
      start_period: 10s
      retries: 5
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.myapp.rule=Host(`app.<DOMAIN>`)"
      - "traefik.http.routers.myapp.entrypoints=websecure"
      - "traefik.http.routers.myapp.tls.certresolver=letsencrypt"
      - "traefik.http.services.myapp.loadbalancer.server.port=3000"
      - "traefik.http.routers.myapp.middlewares=rate-limit@file,security-headers@file"
      - "traefik.http.services.myapp.loadbalancer.healthcheck.path=/health"
      - "traefik.http.services.myapp.loadbalancer.healthcheck.interval=5s"
    networks: [proxy, postgres-net, monitoring-net]
    security_opt: [no-new-privileges:true]
    logging:
      driver: json-file
      options: { max-size: "10m", max-file: "3" }
    environment:
      DATABASE_URL: postgresql://<user>:<pass>@postgres:5432/<db>
      REDIS_URL: redis://redis:6379
      OTEL_EXPORTER_OTLP_ENDPOINT: http://clickstack:4318
```

Deploy: `op run --env-file=.env.tpl -- docker compose up -d`

See `CLAUDE.md` → RollHook section for zero-downtime deployment constraints.

---

## Backups

Two daily backups, both stream to the same `jkrumm` B2 bucket under `backups/vps/`. Retention (14-day hide → delete) enforced by a single B2 lifecycle rule on the `backups/vps/` prefix — append-only key, no client-side pruning.

| Cron | Time | Script | S3 path | Kuma var |
|-|-|-|-|-|
| `/etc/cron.d/pg-backup` | 03:00 | `scripts/backup-pg.sh` | `backups/vps/postgres/` | `UPTIME_KUMA_PUSH_URL` |
| `/etc/cron.d/fpp-mariadb-backup` | 03:30 | `apps/fpp/scripts/backup-mariadb.sh` | `backups/vps/mariadb/` | `UPTIME_KUMA_FPP_BACKUP_PUSH_URL` |
| `/etc/cron.d/pg-health` | every minute | `scripts/health-pg.sh` | n/a (liveness) | `UPTIME_KUMA_POSTGRES_PUSH_URL` |

```bash
# Manual triggers
make backup           # Postgres
make fpp-backup       # MariaDB

# Restoring PROD from S3 overwrites the live DB → NO make target by design.
# Gated, human-only DR tools (scripts/restore-pg.sh, apps/fpp/scripts/restore-mariadb.sh).
# Full procedure: docs/disaster-recovery.md

# Dev restore / seeding (ENV=dev). restore-* validate the S3 DR chain;
# sync-* pull fresh over SSH (no S3). Whole-DB variants drop the local DB.
make restore-local                      # Postgres: latest (or BACKUP_FILE=) S3 dump → local
make sync-from-prod                     # Postgres: whole-DB pg_dump over SSH → local
make pg-sync-schema SCHEMA=argo         # Postgres: one schema only (least-priv)
make fpp-restore-local                  # MariaDB: latest (or BACKUP_FILE=) S3 dump → local
make fpp-sync-from-prod                 # MariaDB: mariadb-dump over SSH → local

make db-counts                          # exact per-table COUNT(*) (both DBs), diff-friendly
```

App repos delegate their local DB seeding to these targets rather than
re-implementing them — e.g. `free-planning-poker` calls `make -C ../vps fpp-sync-from-prod`,
and `argo`'s `bun db:sync` calls `make -C ../vps pg-sync-schema SCHEMA=argo`.

**Verifying a restore/sync is faithful.** `make db-counts` prints stable-sorted
`schema|table|rows` for both DBs. Capture it after a `sync-from-prod` (= live prod)
and after a `restore-local` (= the S3 backup), then `diff` the two: Postgres should be
identical and MariaDB should differ only by a small *positive* delta on hot tables
(`fpp_events`, `fpp_page_views`) — live writes between the backup and the sync. Any
other difference is a real problem. Don't trust the summaries the sync/restore scripts
print: those use Postgres `n_live_tup` (stale until ANALYZE) and MariaDB `TABLE_ROWS`
(an InnoDB estimate). Only `db-counts` runs an actual `COUNT(*)`.

---

## Upgrading Postgres or Valkey

Both are excluded from Watchtower auto-updates. Apply manually.

**Patch/minor (same major):**
```bash
make backup
op run --env-file=.env.tpl -- docker compose -f compose.infra.yml pull postgres   # or valkey
op run --env-file=.env.tpl -- docker compose -f compose.infra.yml up -d postgres
make shell-postgres   # verify: SELECT version();
```

**Postgres major upgrade (e.g., 18 → 19):** Dump with current version, update image tag in `compose.infra.yml`, restore into new container via the gated `scripts/restore-pg.sh` (see `docs/disaster-recovery.md`). Always backup first.

---

## Local Database Access (DataGrip / psql)

Postgres is Docker-internal — no ports exposed on the host. Access via SSH tunnel over Tailscale.

### DataGrip

Create a new **PostgreSQL** data source:

**SSH/SSL tab → Use SSH tunnel:**
| Field | Value |
|-|-|
| Host | `<VPS_TAILSCALE_IP>` (from 1Password: `op read "op://vps/config/VPS_TAILSCALE_IP"`) |
| Port | `22` |
| Username | `jkrumm` |
| Auth type | Key pair |
| Private key | `~/.ssh/id_rsa` |

**General tab:**
| Field | Value |
|-|-|
| Host | `172.19.0.2` (Postgres container IP on Docker bridge — fixed, doesn't change) |
| Port | `5432` |
| User | from 1Password: `op read "op://vps/config/POSTGRES_USER"` |
| Password | from 1Password: `op read "op://vps/postgres/PASSWORD"` |
| Database | from 1Password: `op read "op://vps/config/POSTGRES_DB"` |

> **Why not `postgres` as host?** DataGrip resolves the DB hostname locally before establishing the tunnel. `postgres` only resolves inside Docker networks, not on the VPS host. Use the container's bridge IP instead.

### psql via terminal

```bash
ssh -L 5432:172.19.0.2:5432 vps   # keep open
psql -h localhost -p 5432 -U $(op read "op://vps/config/POSTGRES_USER") postgres
```

---

## Integrating Umami on a New Website

### Embed snippet

The Umami dashboard shows `script.js` in its tracking code UI — **ignore it**. The actual script path is renamed to bypass ad blockers. Always use:

```html
<script defer src="https://umami.jkrumm.com/p.js" data-website-id="<website-id>"></script>
```

Get `data-website-id` from the Umami dashboard (Settings → Websites → your site).

### Why `/p.js` and not `/script.js`

`TRACKER_SCRIPT_NAME=p.js` and `COLLECT_API_ENDPOINT=/api/p` are set in `compose.monitoring.yml`. This renames both endpoints so they don't match ad blocker filter lists (uBlock, Helium, etc.), which target known paths like `/script.js` and `/api/send`.

Brave Shields can still block third-party analytics origins regardless of path. If that matters for a site, the next step is proxying both endpoints through the site's own domain (same-origin requests can't be blocked without breaking the site itself). For an Astro site this means adding rewrites; for Next.js use `next.config.js` rewrites:

```js
// next.config.js
rewrites: async () => [
  { source: '/p.js', destination: 'https://umami.jkrumm.com/p.js' },
  { source: '/api/p', destination: 'https://umami.jkrumm.com/api/p' },
]
// Then embed: <script defer src="/p.js" data-website-id="...">
```

---

## Monitoring

All dashboards are Tailscale-only — no public routes.

| Tool | Access | What it shows |
|-|-|-|
| Beszel | homelab Beszel hub | CPU, RAM, disk, network per container |
| Dozzle | homelab Dozzle hub | Live container logs |
| HyperDX (ClickStack) | `https://hyperdx.<DOMAIN>` (tailscale-only) | Traces, metrics, logs, session replay |
| Watchtower | Pushover only (warn level) | Container update failures |
| RollHook | Slack `#updates` | Deploy success/failure (reuses Watchtower webhook) |
| RollHook | HyperDX (ClickStack) | OTLP deploy markers, `service.name=rollhook` |
| Traefik | `https://traefik.<DOMAIN>` | Router/service map, cert status |

Traefik dashboard is publicly DNS-resolvable but protected by `tailscale-only` middleware (IP allowlist: `100.64.0.0/10`).

