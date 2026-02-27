# hetzner-vps

Infrastructure-as-code for a Hetzner CX33 VPS (4 vCPU · 8 GB · 80 GB SSD · Ubuntu 24.04) — primary `vps`. Docker Compose only. No Swarm, no Kubernetes. Three compose files by concern: networking, infra (databases), and monitoring.

---

## Quick Reference

```bash
# Primary operations
make up                  # start all stacks in order (networking → infra → monitoring)
make down                # stop all stacks in reverse order

# Targeted restart (one stack)
make networking-up / make networking-down
make infra-up    / make infra-down
make monitoring-up / make monitoring-down

# Status + ops
make ps                  # docker ps with name/status/ports
make shell-postgres      # psql shell
make backup              # manual pg_dump → S3
make firewall            # reapply Hetzner Cloud Firewall via hcloud CLI

# Local dev
make dev-up              # Postgres + Valkey with ports exposed, no Doppler
make dev-down

# Deploy config changes to server
git push && ssh vps "cd ~/hetzner-vps && git pull"
```

> **Note:** `vps` was originally IPv6-only (GitHub unreachable). A public IPv4 was added — git now works normally. SSH access remains via Tailscale only (sshd bound to Tailscale interface).

---

## Skills

| Skill | Context | Purpose |
|-|-|-|
| `/audit` | main | 7-phase health audit: resources, containers, tunnel, Tailscale, errors, backup, manual upgrades (Postgres + Valkey) |
| `/docs` | main | Documentation maintenance — sync compose files against README/CLAUDE.md, verify Secrets section coverage |

---

## Secrets

Doppler project `vps`, config `prod`. Variable names and setup instructions in README.md → Secrets section.

**Never write actual values in this repo** — use `<placeholder>` format in docs.

Key variables:

| Variable | Used by |
|-|-|
| `DOMAIN` | Traefik labels (wildcard cert: `*.DOMAIN`) |
| `ACME_EMAIL` | `TRAEFIK_CERTIFICATESRESOLVERS_LETSENCRYPT_ACME_EMAIL` env var on Traefik |
| `CF_DNS_API_TOKEN` | Traefik → lego → Cloudflare DNS-01 challenge |
| `CLOUDFLARE_TUNNEL_TOKEN` | cloudflared tunnel auth (from Cloudflare dashboard) |
| `POSTGRES_DB/USER/PASSWORD` | Postgres container + backup script |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_S3_BUCKET`, `AWS_S3_ENDPOINT`, `UPTIME_KUMA_PUSH_URL` | `scripts/backup-pg.sh` |
| `WATCHTOWER_PUSHOVER_TOKEN/USER_KEY` | Watchtower → Pushover via shoutrrr |
| `ROLLHOOK_ADMIN_TOKEN/WEBHOOK_TOKEN` | RollHook API auth (add when deploying RollHook) |
| `VPS_TAILSCALE_IP` | Traefik port binding (`${VPS_TAILSCALE_IP}:443:443`) — Tailscale-only dashboard access |
| `BESZEL_AGENT_KEY` | Beszel agent `KEY` env var |
| `SIGNOZ_OTLP_ENDPOINT` | OTel collector config (`otel/config.yaml`) |

---

## Object Storage — Bucket Layout

Hetzner Object Storage, bucket `jkrumm` (`fsn1`). All paths are prefixed to avoid collisions across sources:

```
jkrumm/
└── backups/
    ├── vps/
    │   └── postgres/       ← backup-pg.sh (daily cron, 14-day retention)
    └── homelab/
        ├── clickhouse/     ← future: ClickHouse backups
        ├── postgres/       ← future: HomeLab Postgres (if any)
        ├── uptime-kuma/    ← future: Uptime Kuma data
        ├── images/         ← future: container images / ISOs
        └── documents/      ← future: personal documents / files
```

HomeLab backup scripts should write to `backups/homelab/<service>/` using the same `AWS_*` credentials (stored in HomeLab secrets manager, not Doppler `vps`).

---

## Networks

External networks (pre-created by `setup.sh`, referenced as `external: true`):

| Network | Purpose | Who connects |
|-|-|-|
| `proxy` | Traefik routing | Traefik, all apps |
| `postgres-net` | Postgres access | Postgres, apps needing DB |
| `valkey-net` | Valkey/Redis access | Valkey, apps needing cache |
| `monitoring-net` | Observability bus | OTel, Beszel, Dozzle, apps sending OTel |

Internal networks (created by Docker Compose, not external):

| Network | Purpose |
|-|-|
| `socket-proxy-net` | Traefik → socket-proxy (read-only, POST=0) |
| `socket-proxy-watchtower-net` | Watchtower → socket-proxy-watchtower (POST=1, write access) |
| `socket-proxy-monitoring-net` | Dozzle + Beszel → socket-proxy-monitoring (read-only, LOGS+STATS) |

**Traffic routing model:**

| Traffic type | Path |
|-|-|
| Public apps + RollHook | Internet → Cloudflare edge → cloudflared (outbound) → Traefik → service |
| Traefik dashboard | Same tunnel path, restricted by `tailscale-only` middleware |
| OTel data from apps | app → otel-collector:4317 → SigNoz on HomeLab via Tailscale |
| Postgres / Valkey | Internal Docker networks only — zero exposure |

**Key gotcha:** `traefik.yml` static config does NOT support `${ENV_VAR}` substitution. Domain-specific config uses two workarounds:
- ACME email → `TRAEFIK_CERTIFICATESRESOLVERS_LETSENCRYPT_ACME_EMAIL` env var on the Traefik container
- Wildcard cert domains → `tls.domains` labels on the dashboard router in `compose.networking.yml` (Docker Compose DOES substitute `${DOMAIN}` in labels)

---

## File Map

```
compose.networking.yml        Networking/proxy (cloudflared, Traefik, socket-proxy)
compose.infra.yml             Databases (Postgres, Valkey)
compose.monitoring.yml        Monitoring (OTel, Beszel, Dozzle, Watchtower + two socket-proxy instances)
compose.dev.yml               Local dev (Postgres + Valkey with ports exposed, no Doppler)
traefik/traefik.yml           Static config: entrypoints, ACME (DNS-01/Cloudflare)
traefik/dynamic/middlewares.yml  rate-limit, security-headers, tailscale-only
traefik/acme.json             TLS certs — gitignored, chmod 600, auto-managed by Traefik
otel/config.yaml              OTLP receiver → batch processor → SigNoz exporter (Tailscale)
scripts/setup.sh              Server provisioning (user, SSH, sysctl, UFW, Docker, networks, cron)
scripts/backup-pg.sh          pg_dump → S3 + Uptime Kuma push ping
scripts/restore-pg.sh         Restore from S3 (interactive confirmation, drops DB first)
scripts/firewall.sh           hcloud CLI firewall rules — IaC for Hetzner Cloud Firewall
cron/pg-backup                Dropped into /etc/cron.d/ — runs backup at 03:00 daily
README.md → Secrets           All Doppler variable names with setup instructions (no values in repo)
Makefile                      Operational shortcuts
```

---

## Service Notes

**cloudflared** — handles all public ingress via Cloudflare Tunnel. Makes outbound connections to Cloudflare edge only — no ports exposed. Configure public hostnames in Cloudflare dashboard (Zero Trust → Tunnels): `*.DOMAIN` → `https://traefik:443` with TLS verify disabled (internal cert). `--no-autoupdate` lets Watchtower manage the image.

**Traefik** — reads Docker labels via `socket-proxy` (TCP, not docker.sock). No ports exposed — receives traffic from cloudflared internally on port 443. Wildcard cert via DNS-01 (still required so cloudflared can verify the TLS handshake).

**Valkey** — `container_name: redis` so apps reference it as `redis:6379`. Persistence enabled (`--save 60 1`). Major version pinned — update manually.

**Watchtower** — connects to Docker via `socket-proxy-watchtower` (TCP, not docker.sock). Dedicated proxy instance with `POST=1` (write access required for pull/recreate), isolated on `socket-proxy-watchtower-net` so Traefik's read-only proxy is unaffected. Auto-updates all containers except Postgres and Valkey (opted out via `com.centurylinklabs.watchtower.enable=false`). Pushover via shoutrrr at warn level (failures only). Runs daily at 04:00.

**OTel Collector** — ports `4317` (gRPC) and `4318` (HTTP) bound to all interfaces. Apps on `monitoring-net` reach it by hostname. Protected from public internet by Hetzner Firewall + UFW.

---

## App Integration Pattern

```yaml
networks:
  proxy:
    external: true
  postgres-net:   # if using Postgres
    external: true
  monitoring-net: # if sending OTel — needed to reach otel-collector by hostname
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
      - "traefik.http.routers.myapp.rule=Host(`app.${DOMAIN}`)"
      - "traefik.http.routers.myapp.entrypoints=websecure"
      - "traefik.http.routers.myapp.tls.certresolver=letsencrypt"
      - "traefik.http.services.myapp.loadbalancer.server.port=3000"
      - "traefik.http.routers.myapp.middlewares=rate-limit@file,security-headers@file"
      # Active health check — Traefik stops routing to draining instance immediately
      - "traefik.http.services.myapp.loadbalancer.healthcheck.path=/health"
      - "traefik.http.services.myapp.loadbalancer.healthcheck.interval=5s"
    networks:
      - proxy
    security_opt: [no-new-privileges:true]
    logging:
      driver: json-file
      options: { max-size: "10m", max-file: "3" }
```

---

## RollHook — Zero-Downtime Deployments

RollHook (port 7700, behind Traefik, publicly accessible via Cloudflare at `rollhook-vps.<DOMAIN>`) receives webhook calls from GitHub Actions to trigger rolling deployments. It pulls the new image and scales one container at a time, waiting for healthchecks before removing the old instance.

### Hard constraints for RollHook-managed apps

| Constraint | Why |
|-|-|
| No `ports:` | Docker DNS routes traffic; `ports` blocks scaling to 2 instances |
| No `container_name:` | Fixed names prevent creating the second instance during rollout |
| `healthcheck:` required | Rollout waits for healthy before removing old container |
| Image: `${IMAGE_TAG:-<registry>/<image>:latest}` | RollHook passes `IMAGE_TAG=<full-uri>` as inline env var |
| Graceful SIGTERM | Return `503` from `/health`, wait 2-3s, drain requests, exit cleanly |

See `~/SourceRoot/rollhook/README.md` for implementation details (shutdown patterns, GitHub Actions step).

### Doppler secrets (when adding RollHook to compose)

| Variable | Purpose |
|-|-|
| `ROLLHOOK_ADMIN_TOKEN` | Admin API — never leave the server |
| `ROLLHOOK_WEBHOOK_TOKEN` | Deploy webhook — goes into GitHub repo secrets |

---

## Security Invariants

Never violate these:

- No `ports:` for any service except OTel (4317/4318 Tailscale-reachable) and monitoring agents
- Zero inbound ports on Hetzner Firewall — cloudflared is outbound-only, SSH via Tailscale only
- No SSH rule in Hetzner Cloud Firewall (`scripts/firewall.sh`)
- No actual IPs, secrets, tokens, or credentials in any tracked file
- `traefik/acme.json` must remain chmod 600 (Traefik refuses to start otherwise)
- Postgres and Valkey: no auto-update via Watchtower — manual only

---

## Deployment Order (fresh server)

1. `bash setup.sh` (as root)
2. `sudo tailscale up`
3. Set `ListenAddress` in `/etc/ssh/sshd_config.d/99-hardening.conf` → `systemctl restart sshd`
4. `doppler login && doppler setup`
5. Cloudflare dashboard → Zero Trust → Tunnels → Create tunnel → copy token to Doppler as `CLOUDFLARE_TUNNEL_TOKEN`
6. `make firewall` → assign firewall to server in hcloud dashboard (zero inbound rules)
7. `make up`
10. Cloudflare dashboard → tunnel → Public Hostnames → add `*.DOMAIN` → `https://traefik:443` (TLS verify: off)

---

## Upgrade Procedures

**Patch/minor (same major):**
```bash
make backup
doppler run -- docker compose -f compose.infra.yml pull <service>
doppler run -- docker compose -f compose.infra.yml up -d <service>
```

**Postgres major version (e.g., 18 → 19):**
Use `scripts/restore-pg.sh` pattern: dump from old, update image tag in `compose.infra.yml`, restore into new. Or use `pg_upgrade` in place. Always test on a copy first.
