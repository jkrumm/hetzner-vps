# FPP Migration Runbook

Cutover from the old SDS Hetzner VPS to this VPS. Order matters — read top to bottom.

Acceptable downtime: **~5 minutes write-locked + ~1 minute Vercel redeploy** — no DNS race, all `free-planning-poker.com` endpoints already point at the new VPS. Cutover collapses to a Vercel env flip.

---

## Architecture (after migration)

```
                ┌────────────────────┐
                │  Vercel (NextJS)   │  free-planning-poker.com  (apex, Vercel anycast)
                └──────────┬─────────┘
                           │ mysql TLS (rejectUnauthorized:true)
                           ▼
db.free-planning-poker.com:33306 ──► VPS public IP ──► MariaDB (apps/fpp/compose.yml)
                                                              ▲
                                                              │ TLS no-verify (internal)
                                                              │
                ┌────────────────────┐                        │
                │ fpp-analytics-     │ ───────────────────────┘
                │ updater (sidecar)  │   sync MariaDB → parquet every 10 min
                └────────────────────┘

Cloudflare Tunnel ──► Traefik ──► server.free-planning-poker.com     (Bun WebSocket — fpp-server)
                            └──► analytics.free-planning-poker.com   (FastAPI — fpp-analytics)
```

`free-planning-poker.com` zone is hosted on Cloudflare (migrated from Porkbun). Vercel apex (`A 76.76.21.21`) stays grey-cloud so Vercel's edge handles caching as before. The three operational subdomains (`server`, `analytics`, `db`) are CF-managed:

- `server` and `analytics` → orange-cloud CNAMEs to the VPS Cloudflare Tunnel (Traefik routes by Host).
- `db` → grey-cloud A record to the VPS public IP (CF can't proxy raw MySQL on non-Enterprise plans).

MariaDB serves the `*.free-planning-poker.com` wildcard cert (synced from Traefik's acme.json by `apps/fpp/scripts/cert-sync.sh`), so Vercel's strict-verify connect to `db.free-planning-poker.com` validates without overrides.

Both `fpp-server` and `fpp-analytics` are deployed via **RollHook** (zero-downtime rolling deploys) on every push to `jkrumm/free-planning-poker:master`. Auth is GitHub Actions OIDC — no secrets in CI.

---

## Phase 1 — Bootstrap (one-time, before any deploy)

Done before the cutover window so the registry has images and the compose file has running containers RollHook can authorize against.

### 1.1 Create the 1Password items expected by `apps/fpp/compose.yml`

Variables referenced in `vps/.env.tpl`:

| Var | 1Password path |
|-|-|
| `FPP_SERVER_SECRET` | `op://vps/fpp/SERVER_SECRET` |
| `FPP_SERVER_SENTRY_DSN` | `op://vps/fpp/SERVER_SENTRY_DSN` |
| `FPP_ANALYTICS_SECRET_TOKEN` | `op://vps/fpp/ANALYTICS_SECRET_TOKEN` |
| `FPP_ANALYTICS_SENTRY_DSN` | `op://vps/fpp/ANALYTICS_SENTRY_DSN` |
| `FPP_BEA_BASE_URL` | `op://vps/fpp/BEA_BASE_URL` |
| `FPP_BEA_SECRET_KEY` | `op://vps/fpp/BEA_SECRET_KEY` |
| `UPTIME_KUMA_FPP_ANALYTICS_UPDATER_PUSH_URL` | `op://vps/config/UPTIME_KUMA_FPP_ANALYTICS_UPDATER_PUSH_URL` |

Carry the existing values across from old SDS Doppler (or generate fresh secrets if rotating). Update Vercel envs to match the new tokens after cutover.

### 1.2 Push the initial images to RollHook's registry

RollHook authorizes deploys by reading `rollhook.allowed_repos` off a **running** container. The first deploy has nothing to authorize against, so seed the registry manually from the FPP repo:

```bash
cd ~/SourceRoot/free-planning-poker

# Auth to the registry (one-shot — only needed for bootstrap).
ROLLHOOK_SECRET=$(op --account tkrumm read "op://vps/rollhook/SECRET")
docker login rollhook.jkrumm.com -u rollhook --password-stdin <<< "$ROLLHOOK_SECRET"

# Build + push fpp-server and fpp-analytics with an :initial tag.
docker build -t rollhook.jkrumm.com/fpp-server:initial -f fpp-server/Dockerfile fpp-server
docker push rollhook.jkrumm.com/fpp-server:initial

docker build -t rollhook.jkrumm.com/fpp-analytics:initial -f fpp-analytics/Dockerfile fpp-analytics
docker push rollhook.jkrumm.com/fpp-analytics:initial
```

### 1.3 Start the containers on the VPS

```bash
ssh vps "cd ~/vps && IMAGE_TAG=rollhook.jkrumm.com/fpp-server:initial \
  ENV=prod make fpp-up"
# This brings up mariadb, fpp-server, fpp-analytics, fpp-analytics-updater.
# fpp-analytics-updater will retry the DB connection until cutover step 3 (restore).
```

Verify all four containers are healthy:

```bash
ssh vps "docker ps --filter name=mariadb --filter name=fpp- --format 'table {{.Names}}\t{{.Status}}'"
```

### 1.4 Set up GitHub Variables

In `jkrumm/free-planning-poker` → Settings → Variables, set:

| Name | Value |
|-|-|
| `ROLLHOOK_URL` | `https://rollhook.jkrumm.com` (already hardcoded in deploy.yml — variable not strictly required) |

Set up secret only if `master` is branch-protected and `secrets.GITHUB_TOKEN` can't push:

| Name | Value |
|-|-|
| `RELEASE_TOKEN` | Personal access token with `contents: write, repo:status, workflow` |

### 1.5 Verify continuous deploy

Push a no-op commit to `master`. Watch `.github/workflows/deploy.yml` complete both `fpp-server` and `fpp-analytics` jobs — RollHook now manages all subsequent deploys via OIDC. No more `docker login` from your laptop.

---

## Phase 2 — Cutover (production)

Aim for a low-traffic window. ~5 min write-locked + Vercel redeploy. **No DNS flip during the window** — all `free-planning-poker.com` records already point at the new VPS (added during Phase 1 prep). The cutover is purely a data migration + Vercel env flip.

### 2.1 Pause writes on old SDS

Either set FPP into maintenance mode (preferred) or kill the old `fpp-server` so no new sessions accept votes:

```bash
ssh sideproject-docker-stack "cd ~/sideproject-docker-stack && docker compose stop fpp-server fpp-analytics-updater"
```

### 2.2 Final dump from old SDS → VPS → S3

SDS uses Doppler for secrets. Dump on SDS, transfer over Tailscale, push to S3 with a `cutover_` prefix so it's distinguishable from any earlier `presync_*` validation dump:

```bash
# Dump on SDS (logical, version-tolerant — SDS is MariaDB 11.3, VPS is 11.4)
ssh sideproject-docker-stack 'PW=$(doppler secrets get DB_ROOT_PW --plain -p sideproject-docker-stack -c prod) && docker exec -e MYSQL_PWD="$PW" mariadb mariadb-dump -u root --single-transaction --routines --triggers --events free-planning-poker | gzip -9 > /tmp/fpp-cutover.sql.gz'

# Transfer SDS → VPS over Tailscale
ssh sideproject-docker-stack "cat /tmp/fpp-cutover.sql.gz" | ssh vps "cat > /tmp/fpp-cutover.sql.gz"

# Push to S3 with cutover_<timestamp> prefix (uses VPS's existing AWS creds)
ssh vps 'cd ~/vps && op run --env-file=.env.tpl -- bash -c "aws s3 cp /tmp/fpp-cutover.sql.gz s3://\$AWS_S3_BUCKET/backups/vps/mariadb/cutover_$(date +%Y%m%d_%H%M%S).sql.gz --endpoint-url \$AWS_S3_ENDPOINT"'
```

### 2.3 Restore on new VPS

```bash
ssh vps "cd ~/vps && ENV=prod make fpp-restore"
# enter the cutover_*.sql.gz filename when prompted
# enter "free-planning-poker" to confirm
```

Re-apply grants (idempotent; keeps `fpp@'%'` REQUIRE SSL intact even if the dump touched user tables):

```bash
ssh vps "cd ~/vps && make fpp-mariadb-setup"
```

### 2.4 Run any pending Drizzle migrations

If the master branch on this VPS includes new migrations not yet applied to the dump:

```bash
# from a machine that can reach db.free-planning-poker.com:33306
DATABASE_URL='mysql://fpp:<password>@db.free-planning-poker.com:33306/free-planning-poker?ssl={"rejectUnauthorized":true}' \
  npm run db:migrate
```

### 2.5 Flip Vercel environment variables

Vercel dashboard → free-planning-poker project → Settings → Environment Variables. Update **all four** (the new tokens were rotated when the new SERVER_SECRET / ANALYTICS_SECRET_TOKEN items landed in 1Password — Vercel was still pointing at the old SDS values until now):

| Var | New value |
|-|-|
| `DATABASE_URL` | `mysql://fpp:<FPP_PASSWORD>@db.free-planning-poker.com:33306/free-planning-poker?ssl={"rejectUnauthorized":true}` |
| WebSocket URL (likely `NEXT_PUBLIC_FPP_SERVER_URL` or similar) | `https://server.free-planning-poker.com` |
| Analytics URL | `https://analytics.free-planning-poker.com` |
| `FPP_SERVER_SECRET` | from `op://vps/fpp/SERVER_SECRET` |
| `FPP_ANALYTICS_SECRET_TOKEN` | from `op://vps/fpp/ANALYTICS_SECRET_TOKEN` |

`<FPP_PASSWORD>` from `op://vps/mariadb/FPP_PASSWORD`.

Trigger a redeploy on Vercel. Production cuts over to the new VPS the moment the Vercel deployment goes live.

### 2.6 Restart fpp-analytics-updater

Now that MariaDB has the post-cutover data, kick the updater so parquet files refresh:

```bash
ssh vps "docker restart fpp-analytics-updater && docker logs --tail 50 -f fpp-analytics-updater"
```

The first sync writes `fpp_*.parquet` under the `fpp-analytics-data` volume. fpp-analytics serves them from there.

### 2.7 Smoke test

```bash
curl -sI https://free-planning-poker.com/                       # frontend (Vercel apex)
curl -s  https://server.free-planning-poker.com/health          # WebSocket API
curl -s  https://analytics.free-planning-poker.com/health       # FastAPI (should be "ok", no longer "degraded")
# create a room via UI, vote, confirm rows land in MariaDB
ssh vps "docker logs --since=5m mariadb 2>&1 | grep -i 'connect\|query' | tail -10"
```

### 2.8 Resume writes

If you used maintenance mode in step 2.1, disable it now. Cutover complete.

---

## Phase 3 — Post-cutover (24-48h)

- Watch Uptime Kuma: **FPP - Frontend**, **FPP - Server**, **FPP - Analytics**, **FPP - DB**, **FPP - DB Backup**, **FPP - Analytics Readmodel** all green.
- Watch fail2ban: `ssh vps "sudo fail2ban-client status mariadb"` — bans should be sporadic (random scanners), not a flood from one IP suggesting the old DB is being probed somewhere.
- Confirm tomorrow's 03:30 backup ran by checking S3 listing + Kuma push status.
- Watch RollHook deploy logs after the next push to master: `https://rollhook.${DOMAIN}` dashboard.

---

## Rollback (if needed before step 2.9)

The old SDS is untouched until you decommission it. Rollback = reverse the flips:

1. In Vercel, set `DATABASE_URL` back to the old SDS connection string.
2. `/cloudflare` skill: flip both CNAMEs back to the SDS tunnel.
3. Restart `fpp-server` and `fpp-analytics-updater` on SDS.
4. Investigate what broke on the new VPS without time pressure.

Data written to the new MariaDB during the brief cutover window is lost on rollback (same as pre-cutover writes that arrived after the dump). Drizzle's idempotent migrations make re-restore from `cutover_*.sql.gz` safe.

---

## Decommission SDS (after 1-2 weeks of stability)

1. Stop and remove all SDS containers (`docker compose down`).
2. Cancel the SDS Hetzner box.
3. Remove old `~/sideproject-docker-stack` repo from local + GitHub if desired.
4. Update README in this repo if it still references SDS.

---

## Operational notes

### Updating fpp-analytics-updater

The updater shares its image with `fpp-analytics` but is **not** auto-deployed. RollHook can't safely scale it (two concurrent `update_readmodel.py` runs would race on parquet writes). After a deploy of `fpp-analytics`, the updater stays on its old image until manually bounced:

```bash
ssh vps "cd ~/vps && docker compose -f apps/fpp/compose.yml pull fpp-analytics-updater \
  && docker compose -f apps/fpp/compose.yml up -d fpp-analytics-updater"
```

In practice the updater changes rarely — bounce it after a release where `fpp-analytics/update_readmodel.py` or its imports actually changed.

### `make release` flow

`make release` (in the FPP repo) runs `gh workflow run release.yml`, which:

1. Runs `release-it --ci` → bumps version, regenerates CHANGELOG, creates tag, pushes chore commit, creates GitHub release.
2. The chore commit push to master triggers `deploy.yml` automatically.
3. Vercel's GitHub integration picks up the same commit and deploys NextJS.

The redeploy from the chore commit is essentially a no-op (same source = same image digest), so there's no churn cost.
