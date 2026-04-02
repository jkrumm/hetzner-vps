---
name: audit
description: Full health audit of the VPS — system resources, containers, Cloudflare tunnel, Tailscale, errors, updates, backup status, and manual upgrade checks
---

# VPS Audit

Run a full health audit of the VPS across 8 sequential phases, then offer to fix each issue found.

**Execution:** Always via `ssh vps "..."` — never local commands

---

## Instructions

Run all 8 phases first to gather data. Produce the structured report after all phases complete. Then for each WARN/CRITICAL finding, propose the specific fix and ask for confirmation before executing.

### Phase 1: System Resources

```bash
ssh vps "uptime && echo '---' && free -h && echo '---' && df -h --output=source,target,pcent | grep -v 'tmpfs\|efivarfs\|udev'"
```

**Thresholds:**
- WARN: disk >80% on any mount, available memory <1GB, load average >4
- CRITICAL: disk >95% on any mount, load average >8

### Phase 2: Container Health

**All running containers:**
```bash
ssh vps "docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.RunningFor}}'"
```

**Stopped, restarting, or dead (Docker built-in status filters — avoids tab/space grep mismatch):**
```bash
ssh vps "docker ps -a --filter 'status=exited' --filter 'status=restarting' --filter 'status=dead' --format '{{.Names}}\t{{.Status}}'"
```

**Restart counts (non-zero only):**
```bash
ssh vps "docker inspect \$(docker ps -q) --format '{{.Name}} restarts={{.RestartCount}}' 2>/dev/null | grep -v 'restarts=0'"
```

**Docker disk usage:**
```bash
ssh vps "docker system df"
```

**Expected running containers:**
- Networking: `cloudflared`, `traefik`, `socket-proxy`, `socket-proxy-claude`, `socket-proxy-rollhook`, `rollhook`
- Infra: `postgres`, `redis`
- Monitoring: `clickstack`, `beszel-agent`, `dozzle`, `watchtower`, `socket-proxy-watchtower`, `socket-proxy-monitoring`, `umami`

**Thresholds:**
- CRITICAL: any expected container not running
- WARN: restart count >3 on any container
- WARN: reclaimable Docker images >500MB (offer `docker image prune -f`)
- INFO: `rollhook-marketing-rollhook-marketing-2` is a stale auto-suffixed container from the apps/ compose stack — note its age but do not flag as CRITICAL unless not healthy

### Phase 3: Cloudflare Tunnel Health

```bash
ssh vps "docker logs cloudflared --tail=30 2>&1 | grep -v 'receive buffer'"
```

**Known benign (suppress):** `failed to sufficiently increase receive buffer size` — harmless quic-go UDP startup warning

**Thresholds:**
- CRITICAL: `failed`, `connection refused`, or `ERR` repeated in last 30 lines
- WARN: `reconnecting` events in last 30 lines

### Phase 4: Tailscale Connectivity

```bash
ssh vps "tailscale status"
```

**Thresholds:**
- CRITICAL: Tailscale not running, offline, or no peers visible
- WARN: `# Health check:` section appears with warnings in the output (e.g. DNS configuration failures)
- Known benign: `/etc/resolv.conf` permission warning — harmless on Ubuntu 24.04 with systemd-resolved managing DNS

### Phase 5: Recent Errors (Log Scan)

```bash
ssh vps "for svc in traefik cloudflared clickstack; do echo \"=== \$svc ===\"; docker logs \$svc --tail=20 2>&1 | grep -iE 'error|fatal|panic|crash|exception' | grep -v 'context canceled' | tail -5; done"
```

```bash
ssh vps "journalctl -p err -n 30 --no-pager 2>/dev/null | grep -v 'systemd-networkd-wait-online'"
```

```bash
ssh vps "journalctl -p warning -n 100 --no-pager 2>/dev/null | grep -iE 'sudo|pam_unix|authentication failure|invalid user' | tail -10"
```

**Thresholds:**
- CRITICAL: panic / fatal lines in any service
- WARN: repeated error patterns (3+ times in 20 lines)
- WARN: sudo authentication failures or PAM errors in journalctl
- Known benign (suppress): `"error":"reading: context canceled"` in Dozzle/SSE endpoints — normal browser-disconnect events; `systemd-networkd-wait-online` timeouts — harmless in Docker environments; `pam_unix(sudo:auth): auth could not identify password for [jkrumm]` from VPS sessions where `echo '$ROOT_PW' | sudo -S` was attempted — VPS has NOPASSWD sudo, so this pattern is expected from non-interactive SSH sessions

### Phase 6: Backup Status

List recent S3 backups to verify the daily cron ran:

```bash
ssh vps "cd ~/vps && op run --env-file=.env.tpl -- bash -c 'aws s3 ls \$AWS_S3_BUCKET/backups/ --endpoint-url \$AWS_S3_ENDPOINT --recursive | tail -5'"
```

**Thresholds:**
- CRITICAL: no backup file from the last 48 hours
- WARN: no backup file from the last 25 hours (missed last daily run at 03:00)

If backup looks stale, also check cron logs:

```bash
ssh vps "grep pg-backup /var/log/syslog 2>/dev/null | tail -5 || journalctl -u cron -n 10 --no-pager"
```

### Phase 7: Pending Updates

```bash
ssh vps "docker logs watchtower --tail=10 2>&1 | grep -iE 'scheduling|updated|new version|error' | tail -5 || echo '(no recent watchtower activity)'"
```

```bash
ssh vps "apt list --upgradable 2>/dev/null | grep -v '^Listing'"
```

**Thresholds:**
- WARN: any apt upgradable packages (especially linux-image, docker-ce, security patches)
- INFO: Watchtower auto-updated containers (expected behavior)
- INFO: "Scheduling first run" line with next run time — normal after a restart

### Phase 8: Manual Upgrade Check

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

## [1/8] System Resources      🟢/🟡/🔴
<disk %, memory available, load — numbers only>

## [2/8] Container Health      🟢/🟡/🔴
<list non-running or high-restart containers; "all running" if clean>
<Docker disk usage summary if reclaimable >500MB>

## [3/8] Cloudflare Tunnel     🟢/🟡/🔴
<connection status, any reconnect events>

## [4/8] Tailscale             🟢/🟡/🔴
<online status, peer count, any health warnings>

## [5/8] Recent Errors         🟢/🟡/🔴
<per-service summary; "no errors" if clean>

## [6/8] Backup Status         🟢/🟡/🔴
<last backup timestamp + file size>

## [7/8] Pending Updates       🟢/🟡/🔴
<watchtower activity + apt package count>

## [8/8] Manual Upgrades       🟢/🟡/🔴
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
| Container not running (networking/rollhook) | `ssh vps "cd ~/vps && op run --env-file=.env.tpl -- docker compose -f compose.networking.yml up -d <name>"` |
| Container not running (infra) | `ssh vps "cd ~/vps && op run --env-file=.env.tpl -- docker compose -f compose.infra.yml up -d <name>"` |
| Container not running (monitoring) | `ssh vps "cd ~/vps && op run --env-file=.env.tpl -- docker compose -f compose.monitoring.yml up -d <name>"` |
| Container restart count >3 | Show `docker logs <name> --tail=20`, offer restart via appropriate stack |
| Cloudflared errors | `ssh vps "cd ~/vps && op run --env-file=.env.tpl -- docker compose -f compose.networking.yml up -d --force-recreate cloudflared"` |
| Tailscale down | `ssh vps "sudo systemctl restart tailscaled"` |
| Docker image bloat | `ssh vps "docker image prune -f"` (dangling only — safe) |
| Disk >95% | Report + offer `docker image prune -f` — confirm before running; do NOT auto-run `system prune` |
| Apt security updates available | `ssh vps "sudo apt upgrade -y --only-upgrade"` (VPS has NOPASSWD sudo) |
| Backup >48h old | Trigger manual backup: `ssh vps "cd ~/vps && op run --env-file=.env.tpl -- ./scripts/backup-pg.sh"` |
| Postgres upgrade available | See "Upgrade Procedures" in CLAUDE.md — backup first, then pull + recreate |
| Valkey upgrade available | See "Upgrade Procedures" in CLAUDE.md — pull + recreate (data in volume) |

**After each repair:** Re-run the relevant phase command to verify the fix worked before moving to the next issue.

**Never:** Reboot the server, run `docker compose down` across all stacks, delete volumes, or take any action affecting all services simultaneously without explicit discussion.
