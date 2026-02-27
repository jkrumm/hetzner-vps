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
  ├─ Wildcard TLS via Cloudflare DNS-01 ACME (*.yourdomain.com)
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

**Cloudflare Tunnel, zero inbound ports.** cloudflared makes outbound connections to Cloudflare edge only. Hetzner Firewall has zero inbound rules. No ports 80/443 exposed on the host. DNS-01 ACME still issues a wildcard cert (`*.yourdomain.com`) — required so cloudflared can verify the TLS handshake with Traefik internally.

**Three socket proxy instances, no docker.sock mounts.** Traefik gets read-only access (container/network enumeration). Dozzle and Beszel share a second read-only proxy scoped to CONTAINERS+LOGS+STATS. Watchtower gets a dedicated proxy with POST=1 on an isolated network — write access isolated from the others.

**SSH via Tailscale only.** `sshd` binds to the Tailscale interface IP only. Port 22 is absent from both Hetzner Firewall and UFW. Zero SSH attack surface from the public internet.

**Watchtower over WUD.** Auto-updates all containers except Postgres and Valkey (opted out via label). Pushover notifications at warn level (failures only — not every update). Postgres and Valkey are excluded: major version bumps can have data format implications, updates must be deliberate with a backup first.

**`container_name: redis` for Valkey.** Every app references `redis:6379` without modification.

**Doppler for secrets.** All sensitive values in Doppler project `vps`, config `prod`. Zero secrets in the repo. Variable names documented in `.env.example`. Deploy always with `doppler run -- docker compose up -d` (or `make up`).

**No Terraform.** Hetzner Firewall managed via hcloud CLI script (`scripts/firewall.sh`). Single-server setup doesn't justify state management overhead.

---

## Provisioning a Fresh Server

### 1. Run setup.sh

On the fresh Hetzner server as root:

```bash
git clone https://github.com/jkrumm/hetzner-vps /home/jkrumm/hetzner-vps
bash /home/jkrumm/hetzner-vps/scripts/setup.sh
```

Creates user `jkrumm`, hardens SSH, applies sysctl, sets up UFW, installs Docker + toolchain (awscli, Doppler, hcloud, Tailscale), creates external Docker networks, drops the cron job for Postgres backups.

### 2. Post-setup (as jkrumm)

```bash
# Connect to Tailscale — required before locking down SSH
sudo tailscale up

# Bind sshd to Tailscale interface only
# Edit /etc/ssh/sshd_config.d/99-hardening.conf → set ListenAddress <tailscale-ip>
sudo systemctl restart sshd
# ⚠ Verify Tailscale SSH works before closing this session

# Configure Doppler
doppler login && doppler setup   # project: vps, config: prod

# Apply cloud firewall, then assign to server in hcloud dashboard
cd ~/hetzner-vps && make firewall

# Cloudflare dashboard → Zero Trust → Tunnels → create tunnel → copy token to Doppler as CLOUDFLARE_TUNNEL_TOKEN

# Start everything
make up

# Cloudflare dashboard → tunnel → Public Hostnames → *.DOMAIN → https://traefik:443 (TLS verify: off)
```

---

## Secrets

Doppler project `vps`, config `prod`. Full list in `.env.example`.

| Variable | Description |
|-|-|
| `DOMAIN` | Apex domain — wildcard cert covers `*.DOMAIN` |
| `ACME_EMAIL` | Let's Encrypt registration email |
| `CF_DNS_API_TOKEN` | Cloudflare token with `Zone:DNS:Edit` scope (DNS-01 challenge) |
| `CLOUDFLARE_TUNNEL_TOKEN` | Tunnel token from Cloudflare dashboard → Zero Trust → Tunnels |
| `POSTGRES_DB/USER/PASSWORD` | Database credentials |
| `AWS_ACCESS_KEY_ID/SECRET_ACCESS_KEY` | Object storage credentials |
| `AWS_S3_BUCKET/ENDPOINT` | Backup destination |
| `UPTIME_KUMA_PUSH_URL` | Heartbeat push URL for backup monitor |
| `WATCHTOWER_PUSHOVER_TOKEN/USER_KEY` | Pushover app token + user key |
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
      - "traefik.http.routers.myapp.rule=Host(`app.<your-domain>`)"
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

## Monitoring

All dashboards are Tailscale-only — no public routes.

| Tool | Access | What it shows |
|-|-|-|
| Beszel | homelab Beszel hub | CPU, RAM, disk, network per container |
| Dozzle | homelab Dozzle hub | Live container logs |
| SigNoz | homelab SigNoz | Traces, metrics, logs (OTLP) |
| Watchtower | Pushover only (warn level) | Container update failures |
| Traefik | `https://traefik.<your-domain>` | Router/service map, cert status |

Traefik dashboard is publicly DNS-resolvable but protected by `tailscale-only` middleware (IP allowlist: `100.64.0.0/10`).

---

## TODOs

- **Private registry auth:** When pulling images from `registry.jkrumm.com`, add idempotent login to `setup.sh`:
  ```bash
  doppler secrets get ZOT_PASSWORD --plain | docker login registry.jkrumm.com -u jkrumm --password-stdin
  ```
  Add `ZOT_PASSWORD` to Doppler. Docker stores creds in `~/.docker/config.json` — Compose picks them up automatically.
