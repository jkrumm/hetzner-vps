# hetzner-vps

Production Docker Compose stack for a Hetzner CX33 (4 vCPU · 8 GB · 80 GB SSD · Ubuntu 24.04). Single-node, no orchestration. Cloudflare Tunnel handles all public ingress — zero inbound ports on the server. Three compose stacks by concern: networking, infra, monitoring.

---

## Quick Reference

```bash
# Primary operations
make up              # start all stacks (networking → infra → monitoring)
make down            # stop all stacks (reverse order)
make ps              # container status

# Targeted restart (one stack)
make monitoring-up
make monitoring-down

# Postgres
make backup          # manual pg_dump → S3
make shell-postgres  # psql shell

# Ops
make firewall        # reapply Hetzner Cloud Firewall rules

# Traefik cert debug
docker logs traefik 2>&1 | grep -i acme

# Local dev (Postgres + Valkey, ports exposed, no Doppler)
make dev-up
make dev-down
```

**Internal hostnames (container-to-container):**

| Service | Hostname | Port |
|-|-|-|
| PostgreSQL | `postgres` | `5432` |
| Valkey/Redis | `redis` | `6379` |
| OTel Collector (gRPC) | `otel-collector` | `4317` |
| OTel Collector (HTTP) | `otel-collector` | `4318` |

**External Docker networks (apps join these):**

| Network | Join when |
|-|-|
| `proxy` | Always — Traefik routing |
| `postgres-net` | App uses Postgres |
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
    ├─ otel-collector    receives OTLP → forwards to SigNoz on homelab
    ├─ beszel-agent      pushes server + container metrics → Beszel hub
    └─ dozzle            streams container logs → Dozzle hub

Homelab connectivity: Tailscale
  VPS → SigNoz, Beszel hub, Dozzle hub (Tailscale IPs, no public ports)
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
| otel-collector | otel/opentelemetry-collector-contrib | OTLP pipeline → SigNoz | auto |
| beszel-agent | henrygd/beszel-agent | Server metrics agent | auto |
| dozzle | amir20/dozzle | Log streaming agent | auto |
| socket-proxy-monitoring | tecnativa/docker-socket-proxy | Read-only Docker API for Dozzle + Beszel | auto |
| socket-proxy-watchtower | tecnativa/docker-socket-proxy | Write Docker API for Watchtower | auto |
| watchtower | containrrr/watchtower | Auto-updates containers, Pushover on failure | auto |

---

## Design Decisions

**Cloudflare Tunnel, zero inbound ports.** cloudflared makes outbound connections to Cloudflare edge only. Hetzner Firewall has zero inbound rules. No ports 80/443 exposed on the host. DNS-01 ACME still issues a wildcard cert (`*.<DOMAIN>`) — required so cloudflared can verify the TLS handshake with Traefik internally.

**Four socket proxy instances, no docker.sock mounts.** Traefik gets read-only access (container/network enumeration). Dozzle and Beszel share a second read-only proxy scoped to CONTAINERS+LOGS+STATS. RollHook and Watchtower each get a dedicated proxy with POST=1 on isolated networks — write access never shared between them.

**SSH via Tailscale only.** `sshd` binds to the Tailscale interface IP only. Port 22 is absent from both Hetzner Firewall and UFW. Zero SSH attack surface from the public internet.

**Watchtower over WUD.** Auto-updates all containers except Postgres and Valkey (opted out via label). Pushover notifications at warn level (failures only — not every update). Postgres and Valkey are excluded: major version bumps can have data format implications, updates must be deliberate with a backup first.

**`container_name: redis` for Valkey.** Every app references `redis:6379` without modification.

**Doppler for secrets.** All sensitive values in Doppler project `vps`, config `prod`. Zero secrets in the repo — no `.env` or `.env.example`. Variable names and setup instructions documented in the Secrets section below. Deploy always with `doppler run -- docker compose up -d` (or `make up`).

**No Terraform.** Hetzner Firewall managed via hcloud CLI script (`scripts/firewall.sh`). Single-server setup doesn't justify state management overhead.

---

## Provisioning a Fresh Server

### 1. Hetzner — Create server

In the [Hetzner Cloud Console](https://console.hetzner.cloud):
- Create CX33 (4 vCPU · 8 GB · 80 GB SSD), Ubuntu 24.04
- Add a public IPv4 (required — GitHub and most tooling is IPv4-only)
- Add your SSH public key for root access

### 2. Run setup.sh

SSH as root, then:

```bash
git clone https://github.com/jkrumm/hetzner-vps /home/jkrumm/hetzner-vps
bash /home/jkrumm/hetzner-vps/scripts/setup.sh
```

Creates user `jkrumm`, hardens SSH, applies sysctl, sets up UFW, installs Docker + toolchain (awscli, Doppler, hcloud, Tailscale), creates external Docker networks, drops cron job for Postgres backups.

### 3. Tailscale

```bash
sudo tailscale up   # complete auth in browser
tailscale ip -4     # note the assigned Tailscale IP (100.x.x.x)
```

Then bind sshd to the Tailscale interface:
```bash
# Edit /etc/ssh/sshd_config.d/99-hardening.conf
# Uncomment and set: ListenAddress <tailscale-ip>
sudo systemctl restart ssh
# ⚠ Open a second SSH session via Tailscale IP to verify before closing this one
```

Add the server to your local `~/.ssh/config`:
```
Host vps
    HostName <tailscale-ip>
    User jkrumm
```

### 4. Doppler

```bash
# On server as jkrumm:
doppler login
doppler setup   # select project: vps, config: prod
```

Create the Doppler project first at [dashboard.doppler.com](https://dashboard.doppler.com) if it doesn't exist.

### 5. Populate Doppler secrets

See the **Secrets** section below for each variable and how to obtain it. All must be set before `make up`.

### 6. Cloudflare Tunnel

1. [Cloudflare dashboard](https://dash.cloudflare.com) → Zero Trust → Networks → Tunnels → **Create tunnel**
2. Name it (e.g. `vps`), copy the tunnel token
3. Set in Doppler: `CLOUDFLARE_TUNNEL_TOKEN=<token>`

### 7. Hetzner Firewall

```bash
cd ~/hetzner-vps && make firewall
```

Then in Hetzner console: **Firewalls** → assign `vps-firewall` to the server. This enforces zero inbound rules at the Hetzner level.

### 8. Start the stack

```bash
make up
```

Verify: `make ps` — all containers should be running within ~30 seconds.

### 9. Cloudflare tunnel ingress + DNS

Use the `/cloudflare` Claude Code skill to set the wildcard ingress rule and add DNS records. The skill handles all API calls via `ssh vps "doppler run --"` — the token never leaves Doppler.

- Set wildcard ingress: `*.DOMAIN → https://traefik:443` (once after provisioning)
- Add DNS record per app subdomain (CNAME → tunnel)

Traefik will issue a wildcard cert via DNS-01 on first request (may take 1–2 min — check `docker logs traefik | grep -i acme`).

> **Wildcard ingress scope:** Only matches requests already DNS-routed to the VPS tunnel. Other subdomains pointing to different tunnels (HomeLab, etc.) are unaffected.

---

## Secrets

Doppler project `vps`, config `prod`. No `.env` file — Doppler is the only secrets store.

**Domain + TLS**

| Variable | Value | How to get |
|-|-|-|
| `DOMAIN` | `example.com` | Your apex domain — wildcard cert covers `*.DOMAIN` |
| `ACME_EMAIL` | `you@example.com` | Email for Let's Encrypt notifications |
| `CF_API_TOKEN` | `<token>` | Cloudflare → My Profile → API Tokens → Create Token → needs **DNS:Edit** + **Cloudflare Tunnel:Edit** for all zones. Traefik receives it as `CF_DNS_API_TOKEN` (compose mapping — lego requires that name) |
| `CLOUDFLARE_TUNNEL_TOKEN` | `<token>` | Cloudflare → Zero Trust → Networks → Tunnels → Create tunnel → copy token |

**Cloudflare API context (used by `scripts/cf-tunnel-ingress.sh` and `/cloudflare` skill)**

| Variable | Value | How to get |
|-|-|-|
| `CF_ACCOUNT_ID` | `<id>` | Cloudflare dashboard → any zone → Overview → right sidebar (Account ID) |
| `CF_ZONE_ID` | `<id>` | Cloudflare dashboard → your zone → Overview → right sidebar (Zone ID) |
| `CF_TUNNEL_ID` | `<uuid>` | Cloudflare → Zero Trust → Networks → Tunnels → click tunnel → copy ID from URL |

**PostgreSQL**

| Variable | Value | How to get |
|-|-|-|
| `POSTGRES_USER` | `postgres` | Superuser name (default: `postgres`) |
| `POSTGRES_DB` | `postgres` | Default database name |
| `POSTGRES_PASSWORD` | `<generated>` | Generate: `openssl rand -hex 32` |

Apps create their own users and databases on top of this superuser.

**Backups (S3-compatible object storage)**

| Variable | Value | How to get |
|-|-|-|
| `AWS_ACCESS_KEY_ID` | `<key>` | Object storage provider access key |
| `AWS_SECRET_ACCESS_KEY` | `<secret>` | Object storage provider secret |
| `AWS_S3_BUCKET` | `<bucket>` | Bucket name |
| `AWS_S3_ENDPOINT` | `https://...` | Provider endpoint URL (e.g. Hetzner Object Storage) |
| `UPTIME_KUMA_PUSH_URL` | `https://...` | Uptime Kuma → Add monitor → Push type → copy URL |

**Watchtower (ntfy notifications)**

| Variable | Value | How to get |
|-|-|-|
| `NTFY_TOKEN` | `tk_xxx` | `docker exec ntfy ntfy token list jkrumm` on HomeLab, or from Doppler `homelab/prod` |

**Monitoring**

| Variable | Value | How to get |
|-|-|-|
| `BESZEL_AGENT_KEY` | `ssh-ed25519 AAAA...` | Beszel hub UI → Add System → address `<tailscale-ip>:45876` → copy SSH public key shown |
| `SIGNOZ_OTLP_ENDPOINT` | `<tailscale-ip>:4317` | Tailscale IP of the homelab running SigNoz |

**RollHook**

| Variable | Value | How to get |
|-|-|-|
| `ROLLHOOK_ADMIN_TOKEN` | `<generated>` | Copy from homelab Doppler — shared token |
| `ROLLHOOK_WEBHOOK_TOKEN` | `<generated>` | Copy from homelab Doppler — shared token |
| `ZOT_PASSWORD` | `<generated>` | Copy from homelab Doppler — used for `docker login registry.jkrumm.com` |

---

## Adding an App

Minimal `compose.yml` in the app repo:

```yaml
networks:
  proxy:
    external: true
  postgres-net:   # omit if app doesn't use Postgres
    external: true
  monitoring-net: # include to reach otel-collector by hostname
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
      OTEL_EXPORTER_OTLP_ENDPOINT: http://otel-collector:4318
```

Deploy: `doppler run -- docker compose up -d`

See `CLAUDE.md` → RollHook section for zero-downtime deployment constraints.

---

## Backups

Daily cron at 03:00 via `/etc/cron.d/pg-backup`. Triggers `scripts/backup-pg.sh`:
1. Runs `pg_dump` in a one-shot `postgres:18` container
2. Streams compressed dump (`-Fc --compress=9`) to object storage via awscli
3. Prunes backups older than 14 days
4. Pings Uptime Kuma push monitor — status `up` or `down`

```bash
make backup                                                    # manual trigger

BACKUP_FILE=postgres_mydb_20260224_030000.dump \
  doppler run -- ./scripts/restore-pg.sh                      # restore (drops + recreates DB)
```

---

## Upgrading Postgres or Valkey

Both are excluded from Watchtower auto-updates. Apply manually.

**Patch/minor (same major):**
```bash
make backup
doppler run -- docker compose -f compose.infra.yml pull postgres   # or valkey
doppler run -- docker compose -f compose.infra.yml up -d postgres
make shell-postgres   # verify: SELECT version();
```

**Postgres major upgrade (e.g., 18 → 19):** Dump with current version, update image tag in `compose.infra.yml`, restore into new container via `scripts/restore-pg.sh`. Always backup first.

---

## Local Database Access (DataGrip / psql)

Postgres is Docker-internal — no ports exposed on the host. Access via SSH tunnel over Tailscale.

### DataGrip

Create a new **PostgreSQL** data source:

**SSH/SSL tab → Use SSH tunnel:**
| Field | Value |
|-|-|
| Host | `<VPS_TAILSCALE_IP>` (from Doppler: `doppler secrets get VPS_TAILSCALE_IP --project vps --config prod --plain`) |
| Port | `22` |
| Username | `jkrumm` |
| Auth type | Key pair |
| Private key | `~/.ssh/id_rsa` |

**General tab:**
| Field | Value |
|-|-|
| Host | `172.19.0.2` (Postgres container IP on Docker bridge — fixed, doesn't change) |
| Port | `5432` |
| User | from Doppler: `POSTGRES_USER` |
| Password | from Doppler: `POSTGRES_PASSWORD` |
| Database | from Doppler: `POSTGRES_DB` |

> **Why not `postgres` as host?** DataGrip resolves the DB hostname locally before establishing the tunnel. `postgres` only resolves inside Docker networks, not on the VPS host. Use the container's bridge IP instead.

### psql via terminal

```bash
ssh -L 5432:172.19.0.2:5432 vps   # keep open
psql -h localhost -p 5432 -U $(doppler secrets get POSTGRES_USER --project vps --config prod --plain) postgres
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

`TRACKER_SCRIPT_NAME=p.js` and `COLLECT_API_ENDPOINT=/api/p` are set in `compose.umami.yml`. This renames both endpoints so they don't match ad blocker filter lists (uBlock, Helium, etc.), which target known paths like `/script.js` and `/api/send`.

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
| SigNoz | homelab SigNoz | Traces, metrics, logs (OTLP) |
| Watchtower | Pushover only (warn level) | Container update failures |
| Traefik | `https://traefik.<DOMAIN>` | Router/service map, cert status |

Traefik dashboard is publicly DNS-resolvable but protected by `tailscale-only` middleware (IP allowlist: `100.64.0.0/10`).

