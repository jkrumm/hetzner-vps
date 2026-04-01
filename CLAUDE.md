# vps

Infrastructure-as-code for a VPS (12 vCPU · 24 GB · 180 GB SSD · Ubuntu 24.04) — primary `vps`. Docker Compose only. No Swarm, no Kubernetes. Three compose files by concern: networking (incl. RollHook), infra (databases), and monitoring.

> **Public repo.** Never commit real IPs, hostnames, Tailscale IPs, passwords, tokens, or provider-specific details. Use `<placeholder>` in docs. All actual values in 1Password.

---

## Quick Reference

Environment is controlled by `.env` (gitignored). Locally: `ENV=dev`. On server: `ENV=prod`.
Secrets: `op run --env-file=.env.tpl` — 1Password vaults: `vps` + `common`.

```bash
# Primary operations — adapts to ENV automatically
make up                  # dev: compose.dev.yml | prod: networking → infra → monitoring
make down                # dev: compose.dev.yml | prod: reverse order

# Targeted restart (prod only — individual stacks)
make networking-up / make networking-down
make infra-up    / make infra-down
make monitoring-up / make monitoring-down

# Postgres schema/user provisioning — idempotent, works for both envs
make postgres-setup      # run after make infra-up, before make monitoring-up

# Status + ops
make ps                  # docker ps with name/status/ports
make shell-postgres      # psql shell (uses op run with .env.tpl)
make backup              # manual pg_dump → S3 (prod only — guarded)
make firewall            # show UFW status and rules

# Deploy config changes to server
git push && ssh vps "cd ~/vps && git pull"
```

> **SSH:** Tailscale only — sshd binds to Tailscale interface, not the public IP. `ssh vps` uses the Tailscale IP from `~/.ssh/config`.

---

## Skills

| Skill | Context | Purpose |
|-|-|-|
| `/audit` | main | 7-phase health audit: resources, containers, tunnel, Tailscale, errors, backup, manual upgrades (Postgres + Valkey) |
| `/docs` | main | Documentation maintenance — sync compose files against README/CLAUDE.md, verify Secrets section coverage |
| `/cloudflare` | main | Cloudflare API operations — DNS records, tunnel ingress config, multi-domain support |

---

## Secrets

1Password vaults: `vps` + `common`. Variable names and setup instructions in README.md → Secrets section.

**Never write actual values in this repo** — use `<placeholder>` format in docs.

Key variables:

| Variable | Used by |
|-|-|
| `DOMAIN` | Traefik labels (wildcard cert: `*.DOMAIN`) |
| `ACME_EMAIL` | `TRAEFIK_CERTIFICATESRESOLVERS_LETSENCRYPT_ACME_EMAIL` env var on Traefik |
| `CF_API_TOKEN` | Cloudflare API token — needs DNS:Edit + Tunnel:Edit. Passed to Traefik as `CF_DNS_API_TOKEN` (lego expects that name) |
| `CLOUDFLARE_TUNNEL_TOKEN` | cloudflared tunnel auth (from Cloudflare dashboard) |
| `CF_ACCOUNT_ID` | Cloudflare account ID — used by `scripts/cf-tunnel-ingress.sh` and `/cloudflare` skill |
| `CF_ZONE_ID` | Zone ID for `DOMAIN` — used by `scripts/cf-tunnel-ingress.sh` |
| `CF_TUNNEL_ID` | VPS tunnel UUID — used by `scripts/cf-tunnel-ingress.sh` |
| `POSTGRES_DB/USER/PASSWORD` | Postgres container + backup script |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_S3_BUCKET`, `AWS_S3_ENDPOINT`, `UPTIME_KUMA_PUSH_URL` | `scripts/backup-pg.sh` |
| `NTFY_TOKEN` | Watchtower → ntfy (`ntfy.jkrumm.com/vps-watchtower`) via shoutrrr |
| `ZOT_PASSWORD` | Private registry auth (`docker login registry.jkrumm.com`) — in `common` vault |
| `VPS_TAILSCALE_IP` | Traefik port binding (`${VPS_TAILSCALE_IP}:443:443`) — Tailscale-only dashboard access |
| `BESZEL_AGENT_KEY` | Beszel agent `KEY` env var |
| `EXPRESS_SESSION_SECRET` | HyperDX session encryption — `openssl rand -hex 32` |
| `UMAMI_DB_PASSWORD` | Umami Postgres user password — `setup-postgres.sh` + `compose.monitoring.yml` |
| `UMAMI_APP_SECRET` | Umami session secret — 32+ char random string (`openssl rand -hex 32`) |
| `BASALT_UI_PLAYGROUND_DB_PASSWORD` | basalt-ui-playground Postgres user password — `setup-postgres.sh` |

---

## Object Storage — Bucket Layout

S3-compatible object storage, bucket `jkrumm`. All paths are prefixed to avoid collisions across sources:

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

HomeLab backup scripts should write to `backups/homelab/<service>/` using the same `AWS_*` credentials (stored in `common` vault).

---

## Networks

External networks (pre-created by `setup.sh`, referenced as `external: true`):

| Network | Purpose | Who connects |
|-|-|-|
| `proxy` | Traefik routing | Traefik, all apps |
| `postgres-net` | Postgres access | Postgres, apps needing DB |
| `valkey-net` | Valkey/Redis access | Valkey, apps needing cache |
| `monitoring-net` | Observability bus | ClickStack, Beszel, Dozzle, apps sending OTel |

Internal networks (created by Docker Compose, not external):

| Network | Purpose |
|-|-|
| `socket-proxy-net` | Traefik → socket-proxy (read-only, POST=0) |
| `socket-proxy-rollhook-net` | RollHook → socket-proxy-rollhook (POST=1, write access) |
| `socket-proxy-watchtower-net` | Watchtower → socket-proxy-watchtower (POST=1, write access) |
| `socket-proxy-monitoring-net` | Dozzle + Beszel → socket-proxy-monitoring (read-only, LOGS+STATS) |

**Traffic routing model:**

| Traffic type | Path |
|-|-|
| Public apps + RollHook | Internet → Cloudflare edge → cloudflared (outbound) → Traefik → service |
| Traefik dashboard | DNS-only A → Tailscale IP → Traefik (CGNAT unreachable from internet) |
| OTel data from apps | app → clickstack:4318 (via monitoring-net) |
| HyperDX UI | DNS-only A → Tailscale IP → Traefik → clickstack:8080 (CGNAT unreachable from internet) |
| OTel from browsers | Cloudflare → Traefik → clickstack:4318 (public, otel.DOMAIN) |
| Postgres / Valkey | Internal Docker networks only — zero exposure |

**Key gotchas:**

- `traefik.yml` static config does NOT support `${ENV_VAR}` substitution. Domain-specific config uses two workarounds:
  - ACME email → `TRAEFIK_CERTIFICATESRESOLVERS_LETSENCRYPT_ACME_EMAIL` env var on the Traefik container
  - Wildcard cert domains → `tls.domains` labels on the dashboard router in `compose.networking.yml` (Docker Compose DOES substitute `${DOMAIN}` in labels)

- **`ipAllowList` (tailscale-only middleware) does NOT work behind Docker published ports.** Docker NAT masquerades the source IP to the bridge gateway (`172.x.x.x`) before it reaches the Traefik container — the real client IP is never visible. The correct pattern for Tailscale-only services is **DNS-based**: set an A record (DNS-only, grey cloud) pointing to the Tailscale IP (`100.x.x.x`). CGNAT addresses are unreachable from the public internet, so the DNS record itself is the access control — no middleware needed.

---

## File Map

```
compose.networking.yml        Networking/proxy (cloudflared, Traefik, socket-proxy, RollHook)
compose.infra.yml             Databases (Postgres, Valkey)
compose.monitoring.yml        Monitoring (ClickStack, Beszel, Dozzle, Watchtower, Umami + two socket-proxy instances)
compose.dev.yml               Local dev (Postgres + Valkey + ClickStack with ports exposed)
apps/rollhook-marketing/compose.yml  rollhook.com marketing site — managed by RollHook
config/rollhook/rollhook.config.yaml  RollHook app registry — one entry per deployed app
traefik/traefik.yml           Static config: entrypoints, ACME (DNS-01/Cloudflare)
traefik/dynamic/middlewares.yml  rate-limit, security-headers, tailscale-only
traefik/acme.json             TLS certs — gitignored, chmod 600, auto-managed by Traefik
scripts/setup.sh              Server provisioning (user, SSH, sysctl, UFW, Docker, networks, cron)
scripts/setup-postgres.sh     Idempotent schema/user/grant setup — run via make postgres-setup
scripts/backup-pg.sh          pg_dump → S3 + Uptime Kuma push ping
scripts/restore-pg.sh         Restore from S3 (interactive confirmation, drops DB first)
scripts/firewall.sh           UFW status — provider-level firewall configured via hosting panel
cron/pg-backup                Dropped into /etc/cron.d/ — runs backup at 03:00 daily
README.md → Secrets           All secret variable names with setup instructions (no values in repo)
Makefile                      Operational shortcuts
```

---

## Service Notes

**cloudflared** — handles all public ingress via Cloudflare Tunnel. Makes outbound connections to Cloudflare edge only — no ports exposed. Configure public hostnames in Cloudflare dashboard (Zero Trust → Tunnels): `*.DOMAIN` → `https://traefik:443` with TLS verify disabled (internal cert). `--no-autoupdate` lets Watchtower manage the image.

**Traefik** — reads Docker labels via `socket-proxy` (TCP, not docker.sock). No ports exposed — receives traffic from cloudflared internally on port 443. Wildcard cert via DNS-01 (still required so cloudflared can verify the TLS handshake).

**Valkey** — `container_name: redis` so apps reference it as `redis:6379`. Persistence enabled (`--save 60 1`). Major version pinned — update manually.

**Watchtower** — connects to Docker via `socket-proxy-watchtower` (TCP, not docker.sock). Dedicated proxy instance with `POST=1` (write access required for pull/recreate), isolated on `socket-proxy-watchtower-net` so Traefik's read-only proxy is unaffected. Auto-updates all containers except Postgres and Valkey (opted out via `com.centurylinklabs.watchtower.enable=false`). Pushover via shoutrrr at warn level (failures only). Runs daily at 04:00.

**ClickStack** — all-in-one observability container (`clickhouse/clickstack-all-in-one`). Bundles ClickHouse, OTel Collector, HyperDX UI, and MongoDB. Apps on `monitoring-net` send OTLP to `clickstack:4318`. HyperDX UI at `hyperdx.DOMAIN` (Tailscale-only via Traefik). OTel HTTP endpoint at `otel.DOMAIN` (public, for browser SDKs/session replay). Watchtower auto-updates. No auth needed for OTel ingestion; UI auth via first-visit account creation (persisted in internal MongoDB). Dev: `http://hyperdx.local:7707`.

**Umami** — analytics at `umami.DOMAIN`. Lives in `umami` schema of main Postgres database. Dedicated `umami` user — schema-only access. Superuser can JOIN across schemas (e.g., Metabase/Grafana). Watchtower auto-updates. Default credentials: admin/umami — change on first login. Client-side tracking: embed script from dashboard. Server-side: POST /api/send with Bearer token.

---

## Postgres Schema Model

All apps share one database (`${POSTGRES_DB}`). Each app gets its own schema and a dedicated user with schema-only access. The superuser can JOIN across schemas natively.

Pattern for new apps:
1. Add `APP_DB_PASSWORD` to 1Password `vps` vault
2. Add a setup block to `scripts/setup-postgres.sh` (CREATE SCHEMA + ROLE + GRANTs)
3. Run `make postgres-setup`
4. In compose: `DATABASE_URL: postgresql://app:${APP_DB_PASSWORD}@postgres:5432/${POSTGRES_DB}?schema=app`

Current schemas:

| Schema | App | User |
|-|-|-|
| public | (main app / reserved) | ${POSTGRES_USER} |
| umami | Umami analytics | umami |
| watchdog | Watchdog | watchdog |
| basalt_ui_playground | basalt-ui-playground | basalt_ui_playground |

---

## App Integration Pattern

```yaml
networks:
  proxy:
    external: true
  postgres-net:   # if using Postgres
    external: true
  monitoring-net: # if sending OTel — needed to reach clickstack by hostname
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

RollHook (port 7700, behind Traefik, publicly accessible via Cloudflare at `rollhook.<DOMAIN>`) receives webhook calls from GitHub Actions to trigger rolling deployments. It pulls the new image and scales one container at a time, waiting for healthchecks before removing the old instance.

### Hard constraints for RollHook-managed apps

| Constraint | Why |
|-|-|
| No `ports:` | Docker DNS routes traffic; `ports` blocks scaling to 2 instances |
| No `container_name:` | Fixed names prevent creating the second instance during rollout |
| `healthcheck:` required | Rollout waits for healthy before removing old container |
| Image: `${IMAGE_TAG:-<registry>/<image>:latest}` | RollHook passes `IMAGE_TAG=<full-uri>` as inline env var |
| Graceful SIGTERM | Return `503` from `/health`, wait 2-3s, drain requests, exit cleanly |

See `~/SourceRoot/rollhook/README.md` for implementation details (shutdown patterns, GitHub Actions step).

### 1Password secrets (RollHook)

| 1Password Path | Purpose |
|-|-|
| `vps/rollhook/SECRET` | RollHook webhook authentication |

---

## Security Invariants

Never violate these:

- No `ports:` for any service except OTel (4317/4318 Tailscale-reachable) and monitoring agents
- Zero inbound ports — cloudflared is outbound-only, SSH via Tailscale only
- Provider firewall: zero inbound rules (configured via hosting panel)
- No actual IPs, secrets, tokens, or credentials in any tracked file
- `traefik/acme.json` must remain chmod 600 (Traefik refuses to start otherwise)
- Postgres and Valkey: no auto-update via Watchtower — manual only

---

## Deployment Order (fresh server)

```bash
git clone https://github.com/jkrumm/vps /home/jkrumm/vps
bash /home/jkrumm/vps/scripts/setup.sh
```

1. `tailscale up` → complete browser auth → note Tailscale IP
2. Add `OP_SERVICE_ACCOUNT_TOKEN` to `~/.bashrc` → `source ~/.bashrc && op vault list`
3. Uncomment `ListenAddress <tailscale-ip>` in `/etc/ssh/sshd_config.d/99-hardening.conf` → `systemctl restart sshd`
4. `tailscale set --ssh --accept-risk=lose-ssh` → enables SSH badge in Tailscale admin
5. Tunnel token already in 1Password (`vps/cloudflare-tunnel/TOKEN`)
6. `cd ~/vps && make up`
7. `make postgres-setup` → then start any app needing Postgres
8. `reboot` → verify kernel updated, all containers restart automatically

**Note:** HostingFuchs has no panel firewall — UFW + sshd Tailscale binding is sufficient.

---

## Upgrade Procedures

**Patch/minor (same major):**
```bash
make backup
op run --env-file=.env.tpl -- docker compose -f compose.infra.yml pull <service>
op run --env-file=.env.tpl -- docker compose -f compose.infra.yml up -d <service>
```

**Postgres major version (e.g., 18 → 19):**
Use `scripts/restore-pg.sh` pattern: dump from old, update image tag in `compose.infra.yml`, restore into new. Or use `pg_upgrade` in place. Always test on a copy first.
