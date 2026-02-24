# hetzner-vps

Infrastructure-as-code for a Hetzner CX43 VPS (8 vCPU · 16 GB · 160 GB SSD · Ubuntu 24.04). Docker Compose only. No Swarm, no Kubernetes. Two compose files: `compose.yml` (core infra, always running) and `compose.monitoring.yml` (observability + update tracking).

---

## Quick Reference

```bash
# Infra
make up                  # doppler run -- docker compose up -d
make down
make monitoring-up       # doppler run -- docker compose -f compose.monitoring.yml up -d
make monitoring-down
make ps                  # docker ps with name/status/ports
make logs                # follow core stack logs
make logs-monitoring

# DB
make shell-postgres      # psql shell
make backup              # manual pg_dump → S3

# Ops
make firewall            # reapply Hetzner Cloud Firewall via hcloud CLI

# CrowdSec
docker exec crowdsec cscli decisions list
docker exec crowdsec cscli alerts list
docker exec crowdsec cscli metrics
docker exec crowdsec cscli bouncers list

# Deploy with Doppler (explicit form)
doppler run -- docker compose up -d
doppler run -- docker compose -f compose.monitoring.yml up -d
```

---

## Secrets

Doppler project `hetzner-vps`, config `prd`. Variable names in `.env.example`.

**Never write actual values in this repo** — use `<placeholder>` format in docs.

Key variables:

| Variable | Used by |
|-|-|
| `DOMAIN` | Traefik labels (wildcard cert: `*.DOMAIN`) |
| `ACME_EMAIL` | `TRAEFIK_CERTIFICATESRESOLVERS_LETSENCRYPT_ACME_EMAIL` env var on Traefik |
| `CF_DNS_API_TOKEN` | Traefik → lego → Cloudflare DNS-01 challenge |
| `POSTGRES_DB/USER/PASSWORD` | Postgres container + backup script |
| `CROWDSEC_BOUNCER_KEY` | Traefik env → CrowdSec bouncer plugin |
| `AWS_*` + `UPTIME_KUMA_PUSH_URL` | `scripts/backup-pg.sh` |
| `WUD_TRIGGER_PUSHOVER_TOKEN/USER` | WUD (env vars mapped to `_1_` instance) |
| `BESZEL_AGENT_KEY` | Beszel agent `KEY` env var |
| `SIGNOZ_OTLP_ENDPOINT` | OTel collector config (`otel/config.yaml`) |

---

## Networks

External networks (pre-created by `setup.sh`, referenced as `external: true`):

| Network | Purpose | Who connects |
|-|-|-|
| `proxy` | Traefik routing | Traefik, all apps |
| `postgres-net` | Postgres access | Postgres, apps needing DB |
| `valkey-net` | Valkey/Redis access | Valkey, apps needing cache |
| `monitoring-net` | Observability bus | OTel, CrowdSec, Beszel, Dozzle, apps sending OTel |

Internal networks (created by Docker Compose, not external):

| Network | Purpose |
|-|-|
| `socket-proxy-net` | Traefik + WUD → docker-socket-proxy (no external internet) |
| `crowdsec-net` | Traefik bouncer plugin → CrowdSec LAPI only |

**Key gotcha:** `traefik.yml` static config does NOT support `${ENV_VAR}` substitution. Domain-specific config uses two workarounds:
- ACME email → `TRAEFIK_CERTIFICATESRESOLVERS_LETSENCRYPT_ACME_EMAIL` env var on the Traefik container
- Wildcard cert domains → `tls.domains` labels on the dashboard router in `compose.yml` (Docker Compose DOES substitute `${DOMAIN}` in labels)

---

## File Map

```
compose.yml                   Core infra (Traefik, Postgres, Valkey, CrowdSec, socket-proxy)
compose.monitoring.yml        Monitoring (OTel, Beszel, Dozzle, WUD, socket-proxy-monitoring)
traefik/traefik.yml           Static config: entrypoints, ACME (DNS-01/Cloudflare), plugin
traefik/dynamic/middlewares.yml  CrowdSec bouncer, rate-limit, security-headers, tailscale-only
traefik/acme.json             TLS certs — gitignored, chmod 600, auto-managed by Traefik
otel/config.yaml              OTLP receiver → batch processor → SigNoz exporter (Tailscale)
scripts/setup.sh              Server provisioning (user, SSH, sysctl, UFW, Docker, networks, cron)
scripts/backup-pg.sh          pg_dump → S3 + Uptime Kuma push ping
scripts/restore-pg.sh         Restore from S3 (interactive confirmation, drops DB first)
scripts/firewall.sh           hcloud CLI firewall rules — IaC for Hetzner Cloud Firewall
cron/pg-backup                Dropped into /etc/cron.d/ — runs backup at 03:00 daily
.env.example                  All Doppler variable names (no values)
Makefile                      Operational shortcuts
```

---

## Service Notes

**Traefik** — reads Docker labels via `socket-proxy` (TCP, not docker.sock). Wildcard cert covers all app subdomains. CrowdSec bouncer plugin runs inside Traefik, calls `crowdsec:8080` via `crowdsec-net`. Full access logging enabled (not filtered) so CrowdSec can detect behavioral patterns.

**Valkey** — `container_name: redis` so apps reference it as `redis:6379`. On both `valkey-net` (for apps) and `monitoring-net` (CrowdSec uses it as bouncer cache on DB 1). Persistence enabled (`--save 60 1`). Major version pinned — update manually.

**CrowdSec** — pre-installs `crowdsecurity/traefik` collection via `COLLECTIONS` env var. Reads Traefik access logs from the shared `traefik-logs` volume. One-time post-deploy setup required: `cscli capi register` + `cscli bouncers add traefik-bouncer` → key goes to Doppler.

**WUD** — connects to Docker via `WUD_WATCHER_LOCAL_HOST=socket-proxy-monitoring` (not docker.sock). Pushover trigger uses instance index: `WUD_TRIGGER_PUSHOVER_1_TOKEN`. Postgres and Valkey: no auto-update, WUD just notifies (WUD never auto-updates without an explicit Docker trigger configured).

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
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.myapp.rule=Host(`app.${DOMAIN}`)"
      - "traefik.http.routers.myapp.entrypoints=websecure"
      - "traefik.http.routers.myapp.tls.certresolver=letsencrypt"
      - "traefik.http.services.myapp.loadbalancer.server.port=3000"
      - "traefik.http.routers.myapp.middlewares=crowdsec@file,rate-limit@file,security-headers@file"
      - "wud.tag.include=^\\d+\\.\\d+\\.\\d+$$"
    security_opt: [no-new-privileges:true]
    logging:
      driver: json-file
      options: { max-size: "10m", max-file: "3" }
```

---

## Security Invariants

Never violate these:

- No `ports:` for Postgres, Valkey, CrowdSec, Beszel, or Dozzle
- No SSH rule in Hetzner Cloud Firewall (`scripts/firewall.sh`)
- No actual IPs, secrets, tokens, or credentials in any tracked file
- `traefik/acme.json` must remain chmod 600 (Traefik refuses to start otherwise)
- Postgres and Valkey: no auto-update via WUD — manual only

---

## Deployment Order (fresh server)

1. `bash setup.sh` (as root)
2. `sudo tailscale up`
3. Set `ListenAddress` in `/etc/ssh/sshd_config.d/99-hardening.conf` → `systemctl restart sshd`
4. `doppler login && doppler setup`
5. `make firewall` → assign firewall to server in hcloud dashboard
6. `make up`
7. `make monitoring-up`
8. `docker exec crowdsec cscli capi register`
9. `docker exec crowdsec cscli bouncers add traefik-bouncer` → add key to Doppler
10. `make up` (Traefik reloads with `CROWDSEC_BOUNCER_KEY`)

---

## Upgrade Procedures

**Patch/minor (same major):**
```bash
make backup
doppler run -- docker compose pull <service>
doppler run -- docker compose up -d <service>
```

**Postgres major version (e.g., 18 → 19):**
Use `scripts/restore-pg.sh` pattern: dump from old, update image tag in `compose.yml`, restore into new. Or use `pg_upgrade` in place. Always test on a copy first.
