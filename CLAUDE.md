# vps

Infrastructure-as-code for a VPS (12 vCPU · 24 GB · 180 GB SSD · Ubuntu 24.04) — primary `vps`. Docker Compose only. No Swarm, no Kubernetes. Three compose files by concern: networking (incl. RollHook), infra (databases), and monitoring.

> **Public repo.** Never commit real IPs, hostnames, Tailscale IPs, passwords, tokens, or provider-specific details. Use `<placeholder>` in docs. All actual values in 1Password.

---

## Quick Reference

Environment is controlled by `.env` (gitignored). Locally: `ENV=dev`. On server: `ENV=prod`.
Secrets: `op run --env-file=.env.tpl` — 1Password vaults: `vps` + `common`.

All container operations go through the Makefile — never raw `docker`/`docker compose` (global rule `docker-makefile.md`). Bare `make` prints an ENV-aware help: targets available in the current ENV are highlighted, prod-only / dev-only targets are listed dimmed under "Requires ENV=…". Prod-only and dev-only targets are gated by `require-prod` / `require-dev` prerequisites and refuse to run with the wrong ENV.

```bash
make                     # show ENV-aware help (default target)
# Primary operations — adapts to ENV automatically
make up                  # dev: compose.dev.yml | prod: networking → infra → monitoring
make down                # dev: compose.dev.yml | prod: reverse order

# Targeted restart (prod only — individual stacks)
make networking-up / make networking-down
make infra-up    / make infra-down
make monitoring-up / make monitoring-down
make fpp-up      / make fpp-down
make imgproxy-up / make imgproxy-down

# Manual image upgrades — Postgres/Valkey/MariaDB are excluded from Watchtower
make infra-upgrade       # postgres + valkey (run make backup first)
make fpp-mariadb-upgrade # mariadb only (run make fpp-backup first)

# DB schema/user provisioning — idempotent, works for both envs
make postgres-setup      # run after make infra-up, before make monitoring-up
make fpp-mariadb-setup   # run after make fpp-up
make cron-env-seed       # materialize /etc/vps/*.env for cron jobs from 1Password (re-run after secret rotation)

# FPP TLS cert sync (extracts *.free-planning-poker.com from traefik/acme.json into apps/fpp/certs/)
make fpp-cert-sync       # run once after networking-up; cron does it every 6h

# Status + ops
make ps                  # docker ps with name/status/ports
make db-counts           # exact per-table COUNT(*) (Postgres + MariaDB) — diff to verify a sync/restore matches prod
make shell-postgres      # psql shell (uses op run with .env.tpl)
make fpp-shell           # mariadb shell (uses op run with .env.tpl)
make backup              # manual pg_dump → S3 (prod only — guarded)
make fpp-backup          # manual mariadb-dump → S3 (prod only — guarded)

# Dev — local seeding / DR from prod (all dev-only, never touch prod)
make sync-from-prod      # whole-DB ssh+docker exec pg_dump from VPS → local (fresh, no S3). Drops whole local DB.
make restore-local       # pull latest (or BACKUP_FILE=) S3 pg backup → local. Drops whole local DB.
make pg-sync-schema SCHEMA=argo  # one schema only (least-priv, leaves other schemas intact)
make fpp-sync-from-prod  # direct ssh+docker exec mariadb-dump from VPS → local (fresh, no S3)
make fpp-restore-local   # pull latest S3 backup into local mariadb (DR drill / seed)
make firewall            # show UFW status and rules

# Restoring PROD from S3 has NO make target by design (it overwrites production).
# Gated, human-only DR scripts: scripts/restore-pg.sh + apps/fpp/scripts/restore-mariadb.sh
# → see docs/disaster-recovery.md

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
| `/cloudflare` | main | Cloudflare API operations — DNS records, tunnel ingress config, multi-domain support. Global skill at `~/.claude/skills/cloudflare/` (sourced from dotfiles), shared with HomeLab |

---

## Secrets

1Password vaults: `vps` + `common`. Variable names and setup instructions in README.md → Secrets section.

**Never write actual values in this repo** — use `<placeholder>` format in docs.

### Injection — two runners, two templates

**Runner** (`SECRET_RUNNER`, Makefile top): `secrets-run` wherever it exists, plain
`op run --account tkrumm` otherwise. In practice the two Macs use the shim and the
VPS uses `op` directly — the VPS has no `secrets-run` and a working `op`, so **prod
is unchanged**. On the MacBook the shim passes straight through to biometric `op`, so
that is unchanged too.

The mini is the reason for the indirection. A bare `op` on a headless machine has no
human to answer its biometric prompt, so `make up` does not fail — it **blocks**. One
such run sat wedged for 19 hours (2026-08-01 15:16 → 2026-08-02). `secrets-run` fails
closed in a second instead.

**Template**: prod targets get the full `.env.tpl`; `require-dev` targets get
`.env.dev.tpl`.

| Variable | Template | Used by |
|-|-|-|
| `$(OP_RUN)` | `.env.tpl` (~40 refs) | `require-prod` targets |
| `$(OP_RUN_DEV)` | `.env.dev.tpl` (~12 refs) | `require-dev` targets |
| `$(OP_RUN_ENV)` | follows `$(ENV)` | the "works in both envs" targets — `postgres-setup`, `shell-postgres`, `fpp-shell` |

**The dev stack belongs on the mini** — it is the always-on dev host and every app
repo lives there, so the local Postgres/MariaDB/Valkey/ClickStack those apps develop
against has to run there too. Until 2026-08-02 it could not: `make up` in dev
resolved the *entire* prod `.env.tpl` to start four throwaway containers, so making
it work headlessly would have meant caching the Cloudflare tunnel token, the
bucket-wide B2 credential, the RollHook admin token and every FPP/Sentry secret on
the mini. The split is what makes it possible to cache only what the dev stack
actually needs.

Three least-privilege choices inside `.env.dev.tpl`, each explained at its line
there — read that header before adding to it:

- **Dev-only superuser passwords** (`op://mini/vps-dev/*`). Prod's postgres superuser
  and mariadb root passwords stay off the mini. Only the role *name* has to match
  prod (`sync-pg-from-vps.sh` restores a dump carrying `OWNER TO <role>`); the
  password does not.
- **No S3 credential, because none is needed.** `sync-from-prod` (whole DB) and
  `pg-sync-schema SCHEMA=x` (one schema) run `pg_dump` *inside* the prod container
  against its local socket and stream the dump back over keyless Tailscale SSH — no
  credential crosses the wire either way, and the data is fresher than the nightly
  backup. `fpp-sync-from-prod` is the same shape for MariaDB. Don't "simplify" these
  into a direct remote connection; that would put a prod DB login on the mini.
- **`restore-local` / `fpp-restore-local` are the exception and stay MacBook-only.**
  They read S3, so they keep the full `.env.tpl`. They are not a data path — they are
  the DR drill that proves the backup chain replays, which belongs on a clean machine.
  Don't cache an S3 credential to make them run on the mini; `sync-from-prod` already
  covers the case that motivates it.

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
| `IMGPROXY_B2_KEY_ID`, `IMGPROXY_B2_APP_KEY` | imgproxy (`apps/imgproxy/compose.yml`) — **read-only, `--name-prefix img/`** B2 key in `op://vps/imgproxy`. Distinct from the bucket-wide `AWS_*` backup credential. See `docs/image-cdn.md` |
| `IMGPROXY_B2_BUCKET`, `IMGPROXY_B2_ENDPOINT`, `IMGPROXY_B2_REGION` | imgproxy — bucket coordinates reused from `op://common/backblaze-s3` (same bucket as backups) |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_S3_BUCKET`, `AWS_S3_ENDPOINT`, `UPTIME_KUMA_PUSH_URL` | `scripts/backup-pg.sh` |
| `UPTIME_KUMA_POSTGRES_PUSH_URL` | `scripts/health-pg.sh` — per-minute Postgres liveness heartbeat (separate monitor from pg-backup) |
| `SLACK_WATCHTOWER_URL` | Watchtower → Slack #updates via shoutrrr (`common/slack/WATCHTOWER_URL`) |
| `ROLLHOOK_SECRET` | RollHook admin token **and** the registry password — `docker login rollhook.jkrumm.com -u rollhook`. RollHook derives Zot's credential from it (identity function) and writes .htpasswd on start; there is no separate registry secret. In `vps` vault. |
| `VPS_TAILSCALE_IP` | Traefik port binding (`${VPS_TAILSCALE_IP}:443:443`) — Tailscale-only dashboard access |
| `BESZEL_AGENT_KEY` | Beszel agent `KEY` env var |
| `EXPRESS_SESSION_SECRET` | HyperDX session encryption — `openssl rand -hex 32` |
| `HYPERDX_API_KEY` | (no longer required by Traefik — see `docs/observability.md`. Browser SDKs still embed `op://vps/argo/HYPERDX_API_KEY_PROD` for the authed public ingress) |
| `UMAMI_DB_PASSWORD` | Umami Postgres user password — `setup-postgres.sh` + `compose.monitoring.yml` |
| `UMAMI_APP_SECRET` | Umami session secret — 32+ char random string (`openssl rand -hex 32`) |
| `BASALT_UI_PLAYGROUND_DB_PASSWORD` | basalt-ui-playground Postgres user password — `setup-postgres.sh` |
| `ARGO_DB_PASSWORD` | argo Postgres user password — `setup-postgres.sh` |

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
apps/basalt-ui-marketing/compose.yml  basalt-ui.com marketing site (Astro docs) — managed by RollHook
apps/bun-email-api/compose.yml  bun-email-api (Bun + Resend) — sends FPP contact-form + daily-analytics emails. RollHook-managed.
apps/imgproxy/compose.yml     imgproxy — image CDN (resize/convert) over a private B2 bucket, served at img.DOMAIN
apps/photo-gallery/compose.yml  photo-gallery — static Astro gallery served by nginx from /home/jkrumm/photo-gallery-dist (rsynced from laptop via photo-flow CLI)
apps/fpp/compose.yml          FPP — MariaDB now (port 33306 exposed for Vercel); fpp-server + fpp-analytics later
apps/fpp/scripts/setup-mariadb.sh    Idempotent fpp user/grants — run via make fpp-mariadb-setup
apps/fpp/scripts/backup-mariadb.sh   mariadb-dump → S3 + Uptime Kuma push ping
apps/fpp/scripts/restore-mariadb.sh  PROD restore from S3 — gated DR tool, NO make target (docs/disaster-recovery.md)
apps/fpp/scripts/restore-mariadb-local.sh  Dev — non-interactive S3 → local mariadb (DR validation + seeding)
apps/fpp/scripts/sync-mariadb-from-vps.sh  Dev — ssh vps + docker exec mariadb-dump → local mariadb (fresh, no S3)
apps/fpp/scripts/cert-sync.sh        Extract *.free-planning-poker.com cert from traefik/acme.json + FLUSH SSL
apps/fpp/fail2ban/                   filter + jail configs installed by setup.sh
apps/fpp/certs/                      gitignored — populated by cert-sync.sh, mounted RO into mariadb
traefik/traefik.yml           Static config: entrypoints, ACME (DNS-01/Cloudflare)
traefik/dynamic/middlewares.yml  rate-limit, security-headers, tailscale-only
traefik/acme.json             TLS certs — gitignored, chmod 600, auto-managed by Traefik
scripts/setup.sh              Server provisioning (user, SSH, sysctl, UFW, Docker, networks, cron, fail2ban)
scripts/setup-postgres.sh     Idempotent schema/user/grant setup — run via make postgres-setup
scripts/backup-pg.sh          pg_dump → S3 + Uptime Kuma push ping
scripts/health-pg.sh          SELECT 1 → Uptime Kuma push ping (per-minute liveness)
scripts/db-counts.sh          Exact per-table COUNT(*) (Postgres + MariaDB) — read-only, diff-friendly verification (make db-counts)
scripts/restore-pg.sh         PROD restore from S3 — gated DR tool, NO make target (docs/disaster-recovery.md)
scripts/restore-pg-local.sh   Dev — non-interactive S3 → local whole-DB restore (DR validation + seeding)
scripts/sync-pg-from-vps.sh   Dev — ssh vps + docker exec pg_dump (whole DB) → local (fresh, no S3)
scripts/sync-pg-schema-from-vps.sh  Dev — generic per-schema sync (SCHEMA=argo); least-priv, app role only
scripts/firewall.sh           UFW status — provider-level firewall configured via hosting panel
scripts/seed-cron-env.sh      Materializes cron/*.env.tpl → /etc/vps/*.env, chmod 600 — run via make cron-env-seed
cron/pg-backup                Postgres backup, daily 03:00
cron/pg-health                Postgres liveness heartbeat, every minute — sources /etc/vps/pg-health.env (no op run — rate limits)
cron/pg-health.env.tpl        op template for the seeded pg-health cron env (materialized via make cron-env-seed)
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

**ClickStack** — all-in-one observability container (`clickhouse/clickstack-all-in-one`). Bundles ClickHouse, OTel Collector, HyperDX UI, and MongoDB. Two OTLP receivers:
- `:4318` (authed via `bearertokenauth`) — for browser SDKs and any cross-host ingest. Reached publicly via `otel.DOMAIN` and per-app same-origin routes (e.g. `argo.DOMAIN/v1/traces` → `clickstack-otel@docker`).
- `:4319` (no auth, docker-bridge only) — added via `clickstack/otel-custom.yaml` (merged into the base config). Used by Traefik and every internal monitoring-net service. The trust boundary is the docker network, not the bearer token. **Why two tiers**: Traefik 3.x has unfixed bugs around env-var substitution in OTLP headers — see `docs/observability.md`.

HyperDX UI at `hyperdx.DOMAIN` (Tailscale-only via Traefik). UI auth via first-visit account creation (persisted in internal MongoDB). Watchtower auto-updates. Dev: `https://hyperdx.test` (via dotfiles Caddyfile + dnsmasq) or `http://localhost:7707` direct.

**Adding a service to the pipeline**: see `docs/observability.md` for the full
runbook (one-line env addition for backend, four Traefik labels for frontend browser
SDK ingest).

**Umami** — analytics at `umami.DOMAIN`. Lives in `umami` schema of main Postgres database. Dedicated `umami` user — schema-only access. Superuser can JOIN across schemas (e.g., Metabase/Grafana). Watchtower auto-updates. Default credentials: admin/umami — change on first login. Client-side tracking: embed script from dashboard. Server-side: POST /api/send with Bearer token.

**imgproxy** — image CDN at `img.DOMAIN` (public, proxied through Cloudflare so the edge is the cache layer). Renders on-the-fly resizes/format conversions from the **`img/` prefix of the existing backups bucket**; the bucket stays private and is never served directly. URLs are **unsigned** and short — `https://img.DOMAIN/rs:fit:800/misc/x.jpg`. A Traefik catch-all router rewrites that into imgproxy's native form; a higher-priority router passes already-native paths (`/_/…`, `/insecure/…`) through untouched, because the rewrite regex is not idempotent. The `img/` alias (`IMGPROXY_URL_REPLACEMENTS`) resolves to `s3://<bucket>/img/`, so public URLs leak neither the bucket name nor the prefix. Access control is the prefix lock plus non-enumerable object keys, not the URL. Stateless: no volumes, no DB.

Monitored from HomeLab Uptime Kuma (`VPS > Infra`) with **two** monitors: the public edge URL, and `img-origin.DOMAIN` — a DNS-only A record to the Tailscale IP that bypasses Cloudflare so every check does a real B2 fetch + libvips render. imgproxy's `/health` is deliberately not probed: it is liveness only and stays green while every image 404s. Upload/URL tooling is the global `/img` skill (`imgcli`).

> **Load-bearing invariant:** the imgproxy B2 key must be created with `--name-prefix img/`. `backups/vps/postgres/` lives in the same bucket, so that server-side restriction — not `IMGPROXY_S3_ALLOWED_BUCKETS` — is what keeps an unauthenticated public service away from the database dumps. Never point imgproxy at `op://common/backblaze-s3/*` (bucket-wide, has `writeFiles`).

Full design, prefix conventions, the Cloudflare `Vary`/`Accept` caveat, and the B2 provisioning + verification walkthrough: `docs/image-cdn.md`.

**photo-gallery** — static Astro photo gallery at `photos.DOMAIN`. nginx:alpine serves a host-mounted directory (`/home/jkrumm/photo-gallery-dist:/usr/share/nginx/html:ro`). No image registry, no RollHook — content is built on the developer laptop and rsynced via SSH/Tailscale by the `photo-flow` CLI (`photoflow sync-gallery`). Watchtower auto-updates the nginx base image. The host directory must exist (and contain at least `index.html`) before `make photo-gallery-up`, otherwise the healthcheck fails.

---

## FPP MariaDB (apps/fpp/)

Single-tenant database for Free Planning Poker. Lives outside `compose.infra.yml` because **TCP 33306 is exposed publicly** for Vercel — Cloudflare Tunnel can't proxy raw MySQL (TCP origins need cloudflared/WARP client; Spectrum is Enterprise-only). Quarantining the deviation in `apps/fpp/` keeps `compose.infra.yml`'s "no inbound ports" invariant intact.

Defenses on the open port:

- `--require-secure-transport=ON` and `REQUIRE SSL` on the `fpp@'%'` user — no plaintext, ever.
- TLS cert is the wildcard `*.free-planning-poker.com` from Traefik's ACME — extracted by `apps/fpp/scripts/cert-sync.sh` (cron every 6h, `FLUSH SSL` on rotation, no restart).
- fail2ban watches mariadb container's journald logs (`CONTAINER_TAG=mariadb`) and bans repeated auth failures at the iptables `DOCKER-USER` chain (UFW does NOT apply to Docker-published ports — `DOCKER-USER` is what works).
- Schema-scoped user — `fpp@'%'` has `ALL PRIVILEGES` on `${MARIADB_DB}` only, no other DBs, no admin grants.
- `mariadb-dump` backup runs on the internal `mariadb-net` (no public roundtrip).

DNS: `db.free-planning-poker.com` is a **DNS-only A record** (grey cloud) → VPS public IP. Cloudflare can't proxy MySQL anyway, so DNS-only is correct — and CGNAT considerations don't apply since this hits the public IP, not the Tailscale IP.

Vercel connection string:
```
mysql://fpp:<password>@db.free-planning-poker.com:33306/free-planning-poker?ssl={"rejectUnauthorized":true}
```

### FPP application services

`apps/fpp/compose.yml` also defines the application services that consume this DB:

| Service | Image | Network | Deploy |
|-|-|-|-|
| `fpp-server` | `rollhook.jkrumm.com/fpp-server:latest` | `proxy` | RollHook on push to master |
| `fpp-analytics` | `rollhook.jkrumm.com/fpp-analytics:latest` | `proxy` | RollHook on push to master |
| `fpp-analytics-updater` | same as fpp-analytics | `mariadb-net` | manual `docker compose up -d` after image change |

Both `fpp-server` and `fpp-analytics` follow the RollHook contract (no `container_name`, no `ports`, healthcheck, `IMAGE_TAG` env var, `rollhook.allowed_repos=jkrumm/free-planning-poker`). The updater is a sleep-loop sidecar that connects to MariaDB internally with TLS+no-verify (cert CN `*.free-planning-poker.com` doesn't match the `mariadb` hostname).

---

## Postgres Schema Model

All apps share one database (`${POSTGRES_DB}`). Each app gets its own schema and a dedicated user with schema-only access. The superuser can JOIN across schemas natively.

Pattern for new apps:
1. Add `APP_DB_PASSWORD` to 1Password `vps` vault, and the matching `<APP>_DB_PASSWORD` line to `.env.tpl`
2. Add a setup block to `scripts/setup-postgres.sh` (CREATE SCHEMA + ROLE + GRANTs)
3. Run `make postgres-setup`
4. In compose: `DATABASE_URL: postgresql://app:${APP_DB_PASSWORD}@postgres:5432/${POSTGRES_DB}?schema=app`

**Migration journals — own schema, not the shared `drizzle` schema.** drizzle-kit
(and Prisma) default the migration journal to a single `drizzle` schema owned by
whichever app migrates first. On a shared cluster that's a cross-app collision
*and* breaks after a whole-DB restore (`permission denied for schema drizzle`).
Each Postgres app MUST keep its journal in its own schema: drizzle-kit →
`migrations: { schema: '<app>' }` in `drizzle.config.ts` **and** `migrationsSchema`
in the runtime `migrate()` call (Postgres-only option). Then the schema-owning
role owns its journal — no extra grants needed here. Applied: argo
(`argo.__drizzle_migrations`), basalt-ui-playground. N/A for FPP (own MariaDB).

**Local dev seeding** (do not re-implement in the app repo — delegate to vps):
`make pg-sync-schema SCHEMA=<app>` pulls just that schema from prod over SSH, using the
app's own least-priv role. The convention is fixed: **role name == schema name**, and the
password env var is **`UPPER(schema)_DB_PASSWORD`** (so `argo` → `ARGO_DB_PASSWORD`). App
repos call `make -C ../vps pg-sync-schema SCHEMA=<app> ENV=dev` (argo's `bun db:sync` does
exactly this). For a full local mirror of every schema, use `make sync-from-prod`
(whole-DB) or `make restore-local` (whole-DB from S3, version-pickable).

Current schemas:

| Schema | App | User |
|-|-|-|
| public | (main app / reserved) | ${POSTGRES_USER} |
| umami | Umami analytics | umami |
| basalt_ui_playground | basalt-ui-playground | basalt_ui_playground |
| argo | argo (api) | argo |

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
11. `make cron-env-seed` → materialize /etc/vps/*.env for cron jobs from 1Password
12. Add DNS-only A record `db.free-planning-poker.com` → VPS public IP (grey cloud — not proxied)
13. `reboot` → verify kernel updated, all containers restart automatically

**Note:** HostingFuchs has no panel firewall. UFW + sshd Tailscale binding is sufficient for everything except MariaDB. **Docker bypasses UFW for published ports**, so TCP 33306 is publicly reachable as soon as `make fpp-up` runs — no firewall change needed. fail2ban watches MariaDB auth failures via journald and bans source IPs at the iptables `DOCKER-USER` chain (which Docker DOES evaluate before its NAT rules).

**Security Invariants — FPP MariaDB exception**: Vercel needs to reach the FPP database and Cloudflare doesn't proxy MySQL on non-Enterprise plans. Mitigations: TLS required, schema-scoped user, fail2ban. Quarantined to `apps/fpp/` so future apps don't pattern-match.

---

## Upgrade Procedures

Postgres, Valkey and MariaDB opt out of Watchtower, so patch releases only land
by hand. Watchtower is not a fallback here — a plain restart reuses the image
already on disk, so these drift indefinitely until one of these targets runs.

**Patch/minor (same major):**
```bash
make backup && make infra-upgrade        # postgres + valkey
make fpp-backup && make fpp-mariadb-upgrade
```
Both targets are scoped to their services. That matters for MariaDB: a bare
`compose up -d` on `apps/fpp/compose.yml` would also recreate the RollHook-managed
`fpp-server` / `fpp-analytics` off `:latest` and revert the last deploy.

**Postgres major version (e.g., 18 → 19):**
Use the gated `scripts/restore-pg.sh` pattern (see `docs/disaster-recovery.md`): dump from old, update image tag in `compose.infra.yml`, restore into new. Or use `pg_upgrade` in place. Always test on a copy first.
