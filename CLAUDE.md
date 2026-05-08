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
make fpp-up      / make fpp-down

# DB schema/user provisioning — idempotent, works for both envs
make postgres-setup      # run after make infra-up, before make monitoring-up
make fpp-mariadb-setup   # run after make fpp-up

# FPP TLS cert sync (extracts *.${DOMAIN} from traefik/acme.json into apps/fpp/certs/)
make fpp-cert-sync       # run once after networking-up; cron does it every 6h

# Status + ops
make ps                  # docker ps with name/status/ports
make shell-postgres      # psql shell (uses op run with .env.tpl)
make fpp-shell           # mariadb shell (uses op run with .env.tpl)
make backup              # manual pg_dump → S3 (prod only — guarded)
make fpp-backup          # manual mariadb-dump → S3 (prod only — guarded)
make fpp-restore         # interactive mariadb restore from S3 (prod only)
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
| `/cloudflare` | main | Cloudflare API operations — DNS records, tunnel ingress config, multi-domain support. Centralized at `~/SourceRoot/.claude/skills/cloudflare/` (sourced from dotfiles), shared with HomeLab |

---

## Secrets

1Password vaults: `vps` + `common`. Variable names and setup instructions in README.md → Secrets section.

**Never write actual values in this repo** — use `<placeholder>` format in docs.

Key variables:

| Variable | Used by |
|-|-|
| `DOMAIN` | Traefik labels (wildcard cert: `*.DOMAIN`) |
| `ACME_EMAIL` | `TRAEFIK_CERTIFICATESRESOLVERS_LETSENCRYPT_ACME_EMAIL` env var on Traefik |
| `CLOUDFLARE_API_TOKEN` | `op://common/cloudflare/DNS_API_TOKEN` — DNS:Edit + Tunnel:Edit. Passed to Traefik as `CF_DNS_API_TOKEN` (lego expects that name). Same token as HomeLab |
| `CLOUDFLARE_ACCOUNT_ID` | `op://common/cloudflare/ACCOUNT_ID` — same across all zones/tunnels |
| `CLOUDFLARE_ZONE_ID` | `op://common/cloudflare/ZONE_ID_JKRUMM_COM` — primary zone; other zones looked up on demand |
| `CLOUDFLARE_TUNNEL_TOKEN` | `op://vps/cloudflare-tunnel/TOKEN` — per-server cloudflared auth |
| `CLOUDFLARE_TUNNEL_ID` | `op://vps/cloudflare-tunnel/TUNNEL_ID` — VPS tunnel UUID (HomeLab has its own tunnel) |
| `POSTGRES_DB/USER/PASSWORD` | Postgres container + backup script |
| `MARIADB_DB`, `MARIADB_ROOT_PASSWORD`, `MARIADB_FPP_PASSWORD` | FPP MariaDB (`apps/fpp/compose.yml` + setup/backup/restore scripts) |
| `UPTIME_KUMA_FPP_BACKUP_PUSH_URL` | `apps/fpp/scripts/backup-mariadb.sh` (separate monitor from pg-backup) |
| `FPP_SERVER_SECRET`, `FPP_SERVER_SENTRY_DSN` | fpp-server (Bun WebSocket) — see `apps/fpp/compose.yml` |
| `FPP_ANALYTICS_SECRET_TOKEN`, `FPP_ANALYTICS_SENTRY_DSN`, `FPP_BEA_BASE_URL`, `FPP_BEA_SECRET_KEY` | fpp-analytics (FastAPI) + updater sidecar |
| `BEA_SECRET_KEY`, `BEA_RESEND_API_KEY`, `BEA_RECEIVER_EMAIL` | bun-email-api (`apps/bun-email-api/compose.yml`). `SECRET_KEY` is the same bearer token as `FPP_BEA_SECRET_KEY` (consumer side) |
| `UPTIME_KUMA_FPP_ANALYTICS_UPDATER_PUSH_URL` | fpp-analytics-updater 10-min sync heartbeat (separate Kuma monitor) |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_S3_BUCKET`, `AWS_S3_ENDPOINT`, `UPTIME_KUMA_PUSH_URL` | `scripts/backup-pg.sh` |
| `SLACK_WATCHTOWER_URL` | Watchtower → Slack #updates via shoutrrr (`common/slack/WATCHTOWER_URL`) |
| `ZOT_PASSWORD` | Private registry auth (`docker login rollhook.jkrumm.com`) — in `common` vault |
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
    │   ├── postgres/       ← backup-pg.sh (daily cron 03:00, 14-day retention)
    │   └── mariadb/        ← apps/fpp/scripts/backup-mariadb.sh (daily cron 03:30)
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
| `mariadb-net` | FPP MariaDB access | MariaDB, FPP services, backup container |
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
compose.infra.yml             Databases (Postgres, Valkey) — internal-only, no exposed ports
compose.monitoring.yml        Monitoring (ClickStack, Beszel, Dozzle, Watchtower, Umami + two socket-proxy instances)
compose.dev.yml               Local dev (Postgres + Valkey + MariaDB + ClickStack with ports exposed)
apps/rollhook-marketing/compose.yml  rollhook.com marketing site — managed by RollHook
apps/bun-email-api/compose.yml  bun-email-api (Bun + Resend) — sends FPP contact-form + daily-analytics emails. RollHook-managed.
apps/fpp/compose.yml          FPP — MariaDB now (port 33306 exposed for Vercel); fpp-server + fpp-analytics later
apps/fpp/scripts/setup-mariadb.sh    Idempotent fpp user/grants — run via make fpp-mariadb-setup
apps/fpp/scripts/backup-mariadb.sh   mariadb-dump → S3 + Uptime Kuma push ping
apps/fpp/scripts/restore-mariadb.sh  Restore from S3 (interactive confirmation, drops DB first)
apps/fpp/scripts/cert-sync.sh        Extract *.${DOMAIN} cert from traefik/acme.json + FLUSH SSL
apps/fpp/fail2ban/                   filter + jail configs installed by setup.sh
apps/fpp/certs/                      gitignored — populated by cert-sync.sh, mounted RO into mariadb
config/rollhook/rollhook.config.yaml  RollHook app registry — one entry per deployed app
traefik/traefik.yml           Static config: entrypoints, ACME (DNS-01/Cloudflare)
traefik/dynamic/middlewares.yml  rate-limit, security-headers, tailscale-only
traefik/acme.json             TLS certs — gitignored, chmod 600, auto-managed by Traefik
scripts/setup.sh              Server provisioning (user, SSH, sysctl, UFW, Docker, networks, cron, fail2ban)
scripts/setup-postgres.sh     Idempotent schema/user/grant setup — run via make postgres-setup
scripts/backup-pg.sh          pg_dump → S3 + Uptime Kuma push ping
scripts/restore-pg.sh         Restore from S3 (interactive confirmation, drops DB first)
scripts/firewall.sh           UFW status — provider-level firewall configured via hosting panel
cron/pg-backup                Postgres backup, daily 03:00
cron/fpp-mariadb-backup       MariaDB backup, daily 03:30
cron/fpp-cert-sync            MariaDB TLS cert sync, every 6h
README.md → Secrets           All secret variable names with setup instructions (no values in repo)
Makefile                      Operational shortcuts
```

---

## Service Notes

**cloudflared** — handles all public ingress via Cloudflare Tunnel. Makes outbound connections to Cloudflare edge only — no ports exposed. Configure public hostnames in Cloudflare dashboard (Zero Trust → Tunnels): `*.DOMAIN` → `https://traefik:443` with TLS verify disabled (internal cert). `--no-autoupdate` lets Watchtower manage the image.

**Traefik** — reads Docker labels via `socket-proxy` (TCP, not docker.sock). No ports exposed — receives traffic from cloudflared internally on port 443. Wildcard cert via DNS-01 (still required so cloudflared can verify the TLS handshake).

**Valkey** — `container_name: redis` so apps reference it as `redis:6379`. Persistence enabled (`--save 60 1`). Major version pinned — update manually.

**Watchtower** — connects to Docker via `socket-proxy-watchtower` (TCP, not docker.sock). Dedicated proxy instance with `POST=1` (write access required for pull/recreate), isolated on `socket-proxy-watchtower-net` so Traefik's read-only proxy is unaffected. Auto-updates all containers except Postgres and Valkey (opted out via `com.centurylinklabs.watchtower.enable=false`). Slack #updates via shoutrrr at warn level (failures only). Runs daily at 04:00.

**ClickStack** — all-in-one observability container (`clickhouse/clickstack-all-in-one`). Bundles ClickHouse, OTel Collector, HyperDX UI, and MongoDB. Apps on `monitoring-net` send OTLP to `clickstack:4318`. HyperDX UI at `hyperdx.DOMAIN` (Tailscale-only via Traefik). OTel HTTP endpoint at `otel.DOMAIN` (public, for browser SDKs/session replay). Watchtower auto-updates. No auth needed for OTel ingestion; UI auth via first-visit account creation (persisted in internal MongoDB). Dev: `http://hyperdx.local:7707`.

**Umami** — analytics at `umami.DOMAIN`. Lives in `umami` schema of main Postgres database. Dedicated `umami` user — schema-only access. Superuser can JOIN across schemas (e.g., Metabase/Grafana). Watchtower auto-updates. Default credentials: admin/umami — change on first login. Client-side tracking: embed script from dashboard. Server-side: POST /api/send with Bearer token.

---

## FPP MariaDB (apps/fpp/)

Single-tenant database for Free Planning Poker. Lives outside `compose.infra.yml` because **TCP 33306 is exposed publicly** for Vercel — Cloudflare Tunnel can't proxy raw MySQL (TCP origins need cloudflared/WARP client; Spectrum is Enterprise-only). Quarantining the deviation in `apps/fpp/` keeps `compose.infra.yml`'s "no inbound ports" invariant intact.

Defenses on the open port:

- `--require-secure-transport=ON` and `REQUIRE SSL` on the `fpp@'%'` user — no plaintext, ever.
- TLS cert is the wildcard `*.${DOMAIN}` from Traefik's ACME — extracted by `apps/fpp/scripts/cert-sync.sh` (cron every 6h, `FLUSH SSL` on rotation, no restart).
- fail2ban watches mariadb container's journald logs (`CONTAINER_TAG=mariadb`) and bans repeated auth failures at the iptables `DOCKER-USER` chain (UFW does NOT apply to Docker-published ports — `DOCKER-USER` is what works).
- Schema-scoped user — `fpp@'%'` has `ALL PRIVILEGES` on `${MARIADB_DB}` only, no other DBs, no admin grants.
- `mariadb-dump` backup runs on the internal `mariadb-net` (no public roundtrip).

DNS: `fpp-db.${DOMAIN}` is a **DNS-only A record** (grey cloud) → VPS public IP. Cloudflare can't proxy MySQL anyway, so DNS-only is correct — and CGNAT considerations don't apply since this hits the public IP, not the Tailscale IP.

Vercel connection string:
```
mysql://fpp:<password>@fpp-db.${DOMAIN}:33306/free-planning-poker?ssl={"rejectUnauthorized":true}
```

### FPP application services

`apps/fpp/compose.yml` also defines the application services that consume this DB:

| Service | Image | Network | Deploy |
|-|-|-|-|
| `fpp-server` | `rollhook.jkrumm.com/fpp-server:latest` | `proxy` | RollHook on push to master |
| `fpp-analytics` | `rollhook.jkrumm.com/fpp-analytics:latest` | `proxy` | RollHook on push to master |
| `fpp-analytics-updater` | same as fpp-analytics | `mariadb-net` | manual `docker compose up -d` after image change |

Both `fpp-server` and `fpp-analytics` follow the RollHook contract (no `container_name`, no `ports`, healthcheck, `IMAGE_TAG` env var, `rollhook.allowed_repos=jkrumm/free-planning-poker`). The updater is a sleep-loop sidecar that connects to MariaDB internally with TLS+no-verify (cert CN `*.${DOMAIN}` doesn't match the `mariadb` hostname). See `apps/fpp/MIGRATION.md` for the bootstrap and cutover runbook.

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

- No `ports:` for any service except OTel (4317/4318 Tailscale-reachable), monitoring agents, **and the FPP MariaDB exception below**
- Zero inbound ports — cloudflared is outbound-only, SSH via Tailscale only — **except 33306 (FPP MariaDB)**
- Provider firewall: only TCP 33306 inbound (FPP MariaDB), nothing else
- No actual IPs, secrets, tokens, or credentials in any tracked file
- `traefik/acme.json` must remain chmod 600 (Traefik refuses to start otherwise)
- Postgres, Valkey, and MariaDB: no auto-update via Watchtower — manual only

**FPP MariaDB exception (TCP 33306 inbound):** Vercel needs to reach the FPP database and Cloudflare doesn't proxy MySQL on non-Enterprise plans. Mitigations: TLS required (`--require-secure-transport=ON` + `REQUIRE SSL` on the user), schema-scoped `fpp@'%'` user, fail2ban on auth failures via `DOCKER-USER` chain, no remote root. The deviation is contained in `apps/fpp/` so future apps don't pattern-match off it. See **FPP MariaDB** section above.

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
6. `cd ~/vps && make networking-up` → wait for Traefik to issue `*.${DOMAIN}` cert (1–2 min, check `docker logs traefik | grep -i acme`)
7. `make fpp-cert-sync` → extracts wildcard cert into `apps/fpp/certs/`
8. `make up` → starts everything (idempotent — re-runs networking-up too)
9. `make postgres-setup` → provision Postgres schemas/users
10. `make fpp-mariadb-setup` → provision MariaDB fpp user + grants
11. Add DNS-only A record `fpp-db.${DOMAIN}` → VPS public IP (grey cloud — not proxied)
12. `reboot` → verify kernel updated, all containers restart automatically

**Note:** HostingFuchs has no panel firewall. UFW + sshd Tailscale binding is sufficient for everything except MariaDB. **Docker bypasses UFW for published ports**, so TCP 33306 is publicly reachable as soon as `make fpp-up` runs — no firewall change needed. fail2ban watches MariaDB auth failures via journald and bans source IPs at the iptables `DOCKER-USER` chain (which Docker DOES evaluate before its NAT rules).

**Security Invariants — FPP MariaDB exception**: Vercel needs to reach the FPP database and Cloudflare doesn't proxy MySQL on non-Enterprise plans. Mitigations: TLS required, schema-scoped user, fail2ban. Quarantined to `apps/fpp/` so future apps don't pattern-match.

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
