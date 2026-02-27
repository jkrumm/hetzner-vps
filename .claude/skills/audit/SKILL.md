---
name: audit
description: Full health audit of the Hetzner VPS — system resources, containers, Cloudflare tunnel, Tailscale, errors, backup status, and manual upgrade checks
---

# VPS Audit

Run a full health audit of the Hetzner VPS across 7 sequential phases, then offer to fix each issue found.

**Execution:** Always via `ssh vps "..."` — never local commands

---

## Instructions

Run all 7 phases first to gather data. Produce the structured report after all phases complete. Then for each WARN/CRITICAL finding, propose the specific fix and ask for confirmation before executing.

### Phase 1: System Resources

```bash
ssh vps "uptime && echo '---' && free -h && echo '---' && df -h"
```

**Thresholds:**
- WARN: disk >80% on any mount, available memory <1GB, load average >4
- CRITICAL: disk >95% on any mount, load average >8

### Phase 2: Container Health

```bash
ssh vps "docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.RunningFor}}'"
```

```bash
ssh vps "docker ps -a --format '{{.Names}}\t{{.Status}}' | grep -v ' Up '"
```

```bash
ssh vps "docker inspect \$(docker ps -q) --format '{{.Name}} restarts={{.RestartCount}}' 2>/dev/null | grep -v 'restarts=0'"
```

```bash
ssh vps "docker system df"
```

**Expected running containers:**
- Networking: `cloudflared`, `traefik`, `socket-proxy`
- Infra: `postgres`, `redis`
- Monitoring: `otel-collector`, `beszel-agent`, `dozzle`, `watchtower`, `socket-proxy-watchtower`, `socket-proxy-monitoring`

**Thresholds:**
- CRITICAL: any expected container not running
- WARN: restart count >3 on any container
- WARN: reclaimable Docker images >500MB (offer `docker image prune -f`)

### Phase 3: Cloudflare Tunnel Health

```bash
ssh vps "docker logs cloudflared --tail=30 2>&1"
```

**Thresholds:**
- CRITICAL: `failed`, `connection refused`, or `ERR` repeated in last 30 lines
- WARN: `reconnecting` events in last 30 lines

### Phase 4: Tailscale Connectivity

```bash
ssh vps "tailscale status"
```

**Thresholds:**
- CRITICAL: Tailscale not running, offline, or no peers visible

### Phase 5: Recent Errors (Log Scan)

```bash
ssh vps "for svc in traefik cloudflared otel-collector; do echo \"=== \$svc ===\"; docker logs \$svc --tail=20 2>&1 | grep -iE 'error|fatal|panic|crash' | tail -5; done && journalctl -p err -n 10 --no-pager 2>/dev/null"
```

**Thresholds:**
- CRITICAL: panic / fatal lines in any service
- WARN: repeated error patterns (3+ times in 20 lines)

### Phase 6: Backup Status

List recent S3 backups to verify the daily cron ran:

```bash
ssh vps "doppler run --project vps --config prod -- aws s3 ls \${AWS_S3_BUCKET}/backups/ --endpoint-url \${AWS_S3_ENDPOINT} | tail -5"
```

**Thresholds:**
- CRITICAL: no backup file from the last 48 hours
- WARN: no backup file from the last 25 hours (missed last daily run at 03:00)

If backup looks stale, also check cron logs:

```bash
ssh vps "grep pg-backup /var/log/syslog 2>/dev/null | tail -5 || journalctl -u cron -n 10 --no-pager"
```

### Phase 7: Manual Upgrade Check

Postgres and Valkey are excluded from Watchtower. Check their current versions vs latest available:

```bash
ssh vps "docker inspect postgres --format '{{.Config.Image}}' && docker inspect redis --format '{{.Config.Image}}'"
```

Then use WebSearch to check:
- Latest stable `postgres` major version on hub.docker.com/\_/postgres
- Latest stable `valkey/valkey` major version on hub.docker.com/r/valkey/valkey
- Any active CVEs for the running major versions

**Thresholds:**
- WARN: a newer major version has been stable for 3+ months
- INFO: patch/minor updates within pinned major (Watchtower handles image pulls on restart)

---

## Report Format

```
# VPS Audit — <timestamp>

## Summary
🟢 X healthy  🟡 Y warnings  🔴 Z critical

## [1/7] System Resources      🟢/🟡/🔴
<disk %, memory available, load — numbers only>

## [2/7] Container Health      🟢/🟡/🔴
<list non-running or high-restart containers; "all running" if clean>
<Docker disk usage summary if reclaimable >500MB>

## [3/7] Cloudflare Tunnel     🟢/🟡/🔴
<connection status, any reconnect events>

## [4/7] Tailscale             🟢/🟡/🔴
<online status, peer count>

## [5/7] Recent Errors         🟢/🟡/🔴
<per-service summary; "no errors" if clean>

## [6/7] Backup Status         🟢/🟡/🔴
<last backup timestamp + file size>

## [7/7] Manual Upgrades       🟢/🟡/🔴
postgres: running X, latest Y — <up to date / upgrade available>
valkey:   running X, latest Y — <up to date / upgrade available>

## Recommendations
- [CRITICAL] <finding> → <proposed fix>
- [WARN] <finding> → <proposed fix>
```

---

## Repair Actions

For each CRITICAL/WARN finding, propose the fix and ask for confirmation before running.

| Finding | Proposed Fix |
|-|-|
| Container not running (networking) | `ssh vps "cd ~/hetzner-vps && doppler run --project vps --config prod -- docker compose -f compose.networking.yml up -d <name>"` |
| Container not running (infra) | `ssh vps "cd ~/hetzner-vps && doppler run --project vps --config prod -- docker compose -f compose.infra.yml up -d <name>"` |
| Container not running (monitoring) | `ssh vps "cd ~/hetzner-vps && doppler run --project vps --config prod -- docker compose -f compose.monitoring.yml up -d <name>"` |
| Container restart count >3 | Show `docker logs <name> --tail=20`, offer restart via appropriate stack |
| Cloudflared errors | `ssh vps "cd ~/hetzner-vps && doppler run --project vps --config prod -- docker compose -f compose.networking.yml up -d --force-recreate cloudflared"` |
| Tailscale down | `ssh vps "sudo systemctl restart tailscaled"` |
| Docker image bloat | `ssh vps "docker image prune -f"` (dangling only — safe) |
| Disk >95% | Report + offer `docker image prune -f` — confirm before running; do NOT auto-run `system prune` |
| Backup >48h old | Trigger manual backup: `ssh vps "cd ~/hetzner-vps && doppler run --project vps --config prod -- ./scripts/backup-pg.sh"` |
| Postgres upgrade available | See "Upgrade Procedures" in CLAUDE.md — backup first, then pull + recreate |
| Valkey upgrade available | See "Upgrade Procedures" in CLAUDE.md — pull + recreate (data in volume) |

**After each repair:** Re-run the relevant phase command to verify the fix worked before moving to the next issue.

**Never:** Reboot the server, run `docker compose down` across all stacks, delete volumes, or take any action affecting all services simultaneously without explicit discussion.
