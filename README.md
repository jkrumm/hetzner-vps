# hetzner-vps

Production Docker Compose stack for a Hetzner CX43 (8 vCPU · 16 GB · 160 GB SSD · Ubuntu 24.04). Single-node, no orchestration, no complexity. Traefik in front, Postgres + Valkey behind, CrowdSec for threat protection, full observability routed to homelab via Tailscale.

---

## Quick Reference

```bash
# Daily operations
make up              # start core infra
make monitoring-up   # start monitoring stack
make down            # stop core infra
make ps              # container status
make logs            # follow core logs
make backup          # manual pg_dump → S3
make shell-postgres  # psql into Postgres
make firewall        # reapply Hetzner Cloud Firewall rules

# CrowdSec
docker exec crowdsec cscli decisions list         # see blocked IPs
docker exec crowdsec cscli alerts list            # see recent alerts
docker exec crowdsec cscli metrics                # detection stats
docker exec crowdsec cscli bouncers list          # verify bouncer connected

# Postgres
doppler run -- docker compose pull postgres       # pull new image (check WUD first)
doppler run -- docker compose up -d postgres      # restart after image update

# Traefik cert debug
docker exec traefik traefik version
docker logs traefik 2>&1 | grep -i acme           # cert issuance logs
```

**Internal hostnames (container-to-container):**

| Service | Hostname | Port |
|-|-|-|
| PostgreSQL | `postgres` | `5432` |
| Valkey/Redis | `redis` | `6379` |
| OTel Collector (gRPC) | `otel-collector` | `4317` |
| OTel Collector (HTTP) | `otel-collector` | `4318` |
| CrowdSec LAPI | `crowdsec` | `8080` |

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
  │ :80/:443
Hetzner Cloud Firewall ── allow 80, 443 only (IaC: scripts/firewall.sh)
  │
UFW ── second layer: allow 80/443 + all tailscale0, deny rest
  │
Traefik v3
  ├─ HTTP→HTTPS redirect (entrypoint: web)
  ├─ Wildcard TLS via Cloudflare DNS-01 ACME (*.yourdomain.com)
  ├─ Middleware chain on all routers: CrowdSec → rate-limit → security-headers
  ├─ app-1  (network: proxy)
  └─ app-2  (network: proxy)

Internal networks — never exposed publicly:
  postgres-net  ── postgres:5432
  valkey-net    ── redis:6379          (Valkey 9, hostname aliased to "redis")
  crowdsec-net  ── crowdsec:8080       (Traefik bouncer ↔ CrowdSec LAPI only)
  monitoring-net
    ├─ crowdsec          reads Traefik access logs, community IP blocklists
    ├─ otel-collector    receives OTLP → forwards to SigNoz on homelab
    ├─ beszel-agent      pushes server + container metrics → Beszel hub
    └─ dozzle            streams container logs → Dozzle hub

Homelab connectivity: Tailscale
  VPS → SigNoz, Beszel hub, Dozzle hub (Tailscale IPs, no public ports)
  SSH → Tailscale only (sshd ListenAddress bound to tailscale0, port 22 firewalled)

WUD: watches all containers via docker-socket-proxy, Pushover on MINOR updates
     Postgres + Valkey: notify-only (deliberate manual upgrades)
```

---

## Stack

| Service | Image | Purpose | Update policy |
|-|-|-|-|
| socket-proxy | tecnativa/docker-socket-proxy | Read-only Docker API for Traefik + WUD | MINOR auto |
| traefik | traefik:v3 | Reverse proxy, TLS termination | MINOR auto |
| postgres | postgres:18 | Primary DB — pinned major version | **notify only** |
| valkey | valkey/valkey:9 | Cache + queues — `container_name: redis` | **notify only** |
| crowdsec | crowdsecurity/crowdsec | IP blocklists + behavioral detection | MINOR auto |
| otel-collector | otel/opentelemetry-collector-contrib | OTLP pipeline → SigNoz | MINOR auto |
| beszel-agent | henrygd/beszel-agent | Server metrics agent | MINOR auto |
| dozzle | amir20/dozzle | Log streaming agent | MINOR auto |
| wud | fmartinou/whats-up-docker | Update tracking, Pushover alerts | MINOR auto |

---

## Design Decisions

**Cloudflare DNS, no proxy.** Domain and DNS managed at Cloudflare (grey cloud). Direct internet → VPS. DNS-01 ACME challenge issues a single wildcard cert (`*.yourdomain.com`) covering all subdomains — no per-service cert management. Toggle orange cloud per-subdomain later if CDN/DDoS proxy is ever needed.

**CrowdSec over fail2ban.** Fail2ban parses logs reactively per-host. CrowdSec adds community threat intelligence (shared blocklists) and behavioral detection, runs natively as a Docker container, integrates directly as a Traefik plugin, and uses Valkey as its cache backend. Zero added complexity for substantially better protection.

**Two separate firewalls.** Hetzner Cloud Firewall blocks at the network edge (before traffic reaches the VM). UFW is the host-level second layer. Non-redundant: different enforcement points, different failure modes.

**SSH via Tailscale only.** `sshd` binds to the Tailscale interface IP only. Port 22 is absent from both Hetzner Firewall rules and UFW. Zero SSH attack surface from the public internet.

**No Terraform.** Hetzner Firewall managed as a hcloud CLI script (`scripts/firewall.sh`). DNS managed in the Cloudflare UI. State management overhead of Terraform isn't justified for a single-server solo setup.

**WUD over Watchtower.** Watchtower is fire-and-forget with no visibility. WUD provides a dashboard, semver-aware filtering, and per-container notification control. Postgres and Valkey are set to notify-only: even minor version bumps can have data format implications — updates should be deliberate, with a backup run first.

**`container_name: redis` for Valkey.** Every app can reference `redis:6379` without modification.

**Doppler for secrets.** All sensitive values live in Doppler project `hetzner-vps`, config `prd`. The repo contains zero actual secrets. Variable names are documented in `.env.example`. Deploy always with `doppler run -- docker compose up -d` (or `make up`).

---

## Provisioning a Fresh Server

### 1. Run setup.sh

On the fresh Hetzner server as root:

```bash
git clone https://github.com/jkrumm/hetzner-vps /home/jkrumm/hetzner-vps
bash /home/jkrumm/hetzner-vps/scripts/setup.sh
```

Creates user `jkrumm`, hardens SSH, applies sysctl, sets up UFW, installs Docker + toolchain (awscli, Doppler, hcloud, Tailscale), creates external Docker networks, drops the cron job for Postgres backups.

### 2. Post-setup (manual, as jkrumm)

```bash
# Connect to Tailscale — required before locking down SSH
sudo tailscale up

# Bind sshd to Tailscale interface only
# Edit /etc/ssh/sshd_config.d/99-hardening.conf
# Uncomment and set: ListenAddress <tailscale-ip>
sudo systemctl restart sshd
# ⚠ Verify Tailscale SSH works before closing this session

# Configure Doppler
doppler login && doppler setup   # project: hetzner-vps, config: prd

# Apply cloud firewall, then assign to server in hcloud dashboard
cd ~/hetzner-vps && make firewall

# Start stacks
make up
make monitoring-up
```

### 3. CrowdSec one-time setup

```bash
# Register with CrowdSec Central API (community threat intel)
docker exec crowdsec cscli capi register

# Add Traefik bouncer and capture the generated key
docker exec crowdsec cscli bouncers add traefik-bouncer
# → copy the key to Doppler as CROWDSEC_BOUNCER_KEY

# Reload Traefik to pick up the key
make up
```

---

## Secrets

Doppler project `hetzner-vps`, config `prd`. Full list in `.env.example`.

| Variable | Description |
|-|-|
| `DOMAIN` | Apex domain — wildcard cert covers `*.DOMAIN` |
| `ACME_EMAIL` | Let's Encrypt registration email |
| `CF_DNS_API_TOKEN` | Cloudflare token with `Zone:DNS:Edit` scope |
| `POSTGRES_DB/USER/PASSWORD` | Database credentials |
| `CROWDSEC_BOUNCER_KEY` | Generated by `cscli bouncers add` |
| `AWS_ACCESS_KEY_ID/SECRET_ACCESS_KEY` | Object storage credentials |
| `AWS_S3_BUCKET/ENDPOINT` | Backup destination |
| `UPTIME_KUMA_PUSH_URL` | Heartbeat push URL for backup monitor |
| `WUD_TRIGGER_PUSHOVER_TOKEN/USER` | Pushover app token + user key |
| `BESZEL_AGENT_KEY` | SSH public key from Beszel hub |
| `SIGNOZ_OTLP_ENDPOINT` | `<tailscale-ip>:4317` of homelab SigNoz |

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
    image: ghcr.io/jkrumm/myapp:latest
    networks: [proxy, postgres-net, monitoring-net]
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.myapp.rule=Host(`app.<your-domain>`)"
      - "traefik.http.routers.myapp.entrypoints=websecure"
      - "traefik.http.routers.myapp.tls.certresolver=letsencrypt"
      - "traefik.http.services.myapp.loadbalancer.server.port=3000"
      - "traefik.http.routers.myapp.middlewares=crowdsec@file,rate-limit@file,security-headers@file"
      - "wud.tag.include=^\\d+\\.\\d+\\.\\d+$$"
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

**Hostname summary:** `postgres:5432`, `redis:6379`, `otel-collector:4317` (gRPC) or `:4318` (HTTP). OTel requires joining `monitoring-net`.

---

## Backups

Daily cron at 03:00 via `/etc/cron.d/pg-backup`. Triggers `scripts/backup-pg.sh`:
1. Runs `pg_dump` in a one-shot `postgres:18` container
2. Streams compressed dump (`-Fc --compress=9`) to object storage via awscli
3. Prunes backups older than 14 days
4. Pings Uptime Kuma push monitor (`UPTIME_KUMA_PUSH_URL`) — status `up` or `down`

```bash
make backup                                                    # manual trigger

BACKUP_FILE=postgres_mydb_20260224_030000.dump \
  doppler run -- ./scripts/restore-pg.sh                      # restore (drops + recreates DB)
```

---

## Upgrading Postgres or Valkey

WUD notifies via Pushover when new versions are available. Do not auto-apply.

**Patch/minor upgrade (same major):**
```bash
make backup
doppler run -- docker compose pull postgres   # or valkey
doppler run -- docker compose up -d postgres
make shell-postgres   # verify: SELECT version();
```

**Postgres major upgrade (e.g., 18 → 19):** Use `pg_upgrade` or dump/restore via `scripts/restore-pg.sh`. Update the image tag in `compose.yml` and add a comment with the upgrade date.

---

## Monitoring

All monitoring dashboards are Tailscale-only — no public routes.

| Tool | Access | What it shows |
|-|-|-|
| Beszel | homelab Beszel hub | CPU, RAM, disk, network per container |
| Dozzle | homelab Dozzle hub | Live container logs |
| SigNoz | homelab SigNoz | Traces, metrics, logs (OTLP) |
| WUD | `http://<tailscale-ip>:3000` | Container update status |
| Traefik | `https://traefik.<your-domain>` | Router/service map, cert status |

Traefik dashboard is publicly DNS-resolvable but protected by `tailscale-only` middleware (IP allowlist: `100.64.0.0/10`).

---

## TODOs

- **Private registry auth:** When pulling images from `registry.jkrumm.com`, add idempotent login to `setup.sh`:
  ```bash
  doppler secrets get ZOT_PASSWORD --plain | docker login registry.jkrumm.com -u jkrumm --password-stdin
  ```
  Add `ZOT_PASSWORD` to Doppler. Docker stores creds in `~/.docker/config.json` — Compose picks them up automatically, no changes to `compose.yml` needed.
