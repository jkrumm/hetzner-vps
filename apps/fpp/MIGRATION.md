# FPP Migration Runbook

Cutover from the old SDS Hetzner VPS to this VPS. Order matters — read top to bottom.

Acceptable downtime: **~5 minutes write-locked + 2-3 minutes total perceived outage** while DNS propagates and Vercel picks up the new `DATABASE_URL`.

---

## Prerequisites (before scheduling cutover)

1. **`fpp-server` and `fpp-analytics` deployed on this VPS.** Images built, pushed to `registry.jkrumm.com`, services in `apps/fpp/compose.yml`, RollHook wired up, healthchecks green at `https://fpp-server-new.jkrumm.com/health` (use a temporary subdomain to avoid clashing with the live `fpp-server.jkrumm.com` CNAME until cutover).
2. **MariaDB on this VPS already accepting connections.** Verify: `make fpp-shell` inside vps repo, or external probe `curl -sIk fpp-db.jkrumm.com:33306` (TCP open).
3. **Drizzle migrations idempotent.** Confirm by running `npm run db:migrate` against a copy of prod data locally — should be a no-op on a fresh restore.
4. **Vercel preview/staging tested** with a `DATABASE_URL` pointing at a staging copy of MariaDB on this VPS. Eliminates Vercel-side surprises (TLS config, IP family, connection pool).
5. **Backup of old SDS DB exists in S3.** Final pre-cutover dump goes here too.

---

## Cutover (production)

Aim for low-traffic window. ~5 min write-locked + DNS propagation.

### 1. Pause writes on old SDS

Either set FPP into maintenance mode (preferred) or kill the old `fpp-server` so no new sessions accept votes:

```bash
ssh sds "cd ~/sideproject-docker-stack && docker compose stop fpp-server fpp-analytics-updater"
```

### 2. Final dump from old SDS → S3

```bash
ssh sds "cd ~/sideproject-docker-stack && docker exec mariadb mariadb-dump \
  -u root -p\$DB_ROOT_PW \
  --single-transaction --routines --triggers --events \
  --databases free-planning-poker | gzip -9 > /tmp/fpp-cutover.sql.gz"
ssh sds "aws s3 cp /tmp/fpp-cutover.sql.gz s3://jkrumm/backups/vps/mariadb/cutover_$(date +%Y%m%d_%H%M%S).sql.gz \
  --endpoint-url <B2_ENDPOINT>"
```

(Old SDS uses Doppler — adjust the credential injection accordingly.)

### 3. Restore on new VPS

```bash
ssh vps "cd ~/vps && ENV=prod make fpp-restore"
# enter the cutover_*.sql.gz filename when prompted
# enter "free-planning-poker" to confirm
```

Then re-apply grants (idempotent; keeps `fpp@'%'` REQUIRE SSL intact even if the dump touched user tables):

```bash
ssh vps "cd ~/vps && make fpp-mariadb-setup"
```

### 4. Run any pending Drizzle migrations

If the deploy to this VPS includes new migrations not yet applied to the dump:

```bash
# from a machine that can reach fpp-db.jkrumm.com:33306
DATABASE_URL='mysql://fpp:<password>@fpp-db.jkrumm.com:33306/free-planning-poker?ssl={"rejectUnauthorized":true}' \
  npm run db:migrate
```

### 5. Flip Vercel `DATABASE_URL`

Vercel dashboard → free-planning-poker project → Settings → Environment Variables → update `DATABASE_URL`:

```
mysql://fpp:<FPP_PASSWORD>@fpp-db.jkrumm.com:33306/free-planning-poker?ssl={"rejectUnauthorized":true}
```

`<FPP_PASSWORD>` from `op://vps/mariadb/FPP_PASSWORD`.

Trigger a redeploy (Vercel auto-redeploys on env-var change in production for some configs — verify a fresh deployment lands).

### 6. Flip CNAMEs from old SDS tunnel → new VPS tunnel

Use `/cloudflare` skill to UPDATE the DNS records (don't add new ones — these subdomains already exist pointing at the SDS tunnel).

```
fpp-server.jkrumm.com    CNAME → ${VPS_TUNNEL_ID}.cfargotunnel.com   (proxied: true)
fpp-analytics.jkrumm.com CNAME → ${VPS_TUNNEL_ID}.cfargotunnel.com   (proxied: true)
```

### 7. Smoke test

```bash
curl -sI https://free-planning-poker.com/                # frontend (Vercel)
curl -s  https://fpp-server.jkrumm.com/health            # WebSocket API
curl -s  https://fpp-analytics.jkrumm.com/health         # FastAPI
# create a room via UI, vote, confirm Drizzle writes hit fpp-db.jkrumm.com
ssh vps "docker logs --since=5m mariadb 2>&1 | grep -i 'connect\|query' | tail -10"
```

### 8. Resume writes

If you used maintenance mode in step 1, disable it now. Cutover complete.

---

## Post-cutover (24-48h)

- Watch Uptime Kuma: **FPP - Frontend**, **FPP - Server**, **FPP - Analytics**, **FPP - DB**, **FPP - DB Backup**, **FPP - Analytics Readmodel** all green.
- Watch fail2ban: `ssh vps "sudo fail2ban-client status mariadb"` — bans should be sporadic (random scanners), not a flood from one IP suggesting the old DB is being probed somewhere.
- Confirm tomorrow's 03:30 backup ran by checking S3 listing + Kuma push status.

---

## Rollback (if needed before step 8)

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
