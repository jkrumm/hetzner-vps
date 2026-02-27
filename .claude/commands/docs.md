# VPS Documentation Maintenance

**Context:** main

**When to use:**
- After adding or removing services in any compose file
- After creating or modifying scripts
- After changing Traefik config, middleware, or OTel config
- Before committing infrastructure changes

**What this skill does:**
1. Diffs compose files against README.md and CLAUDE.md service tables
2. Verifies README.md Secrets section covers every `${VAR}` referenced in compose files and scripts
3. Checks Makefile targets match what CLAUDE.md Quick Reference documents
4. Flags internal socket-proxy networks that are missing from CLAUDE.md Networks section
5. Detects services with `com.centurylinklabs.watchtower.enable=false` not documented in upgrade procedures
6. Updates stale documentation

**What this skill does NOT do:**
- Execute infrastructure changes
- Commit changes (use `/commit` after review)
- Modify scripts, configs, or compose files

---

## Audit Checklist

### Service Inventory
- [ ] All services in `compose.networking.yml` appear in README stack table
- [ ] All services in `compose.infra.yml` appear in README stack table
- [ ] All services in `compose.monitoring.yml` appear in README stack table
- [ ] No removed services still referenced in README or CLAUDE.md

### Secret Coverage
- [ ] Every `${VAR}` in compose files appears in README.md Secrets section
- [ ] Every `${VAR}` in `scripts/` appears in README.md Secrets section
- [ ] No variables documented in README.md Secrets that are no longer used in any compose file or script

### Network Documentation
- [ ] All external networks in compose files match what `setup.sh` creates
- [ ] All internal socket-proxy networks documented in CLAUDE.md Networks section
- [ ] New proxy consumers (services using socket-proxy via `DOCKER_HOST`) noted in service notes

### Middleware Consistency
- [ ] Middleware names in CLAUDE.md App Integration Pattern match `traefik/dynamic/middlewares.yml`
- [ ] Same middleware names in README.md Adding an App section

### Makefile ↔ CLAUDE.md Sync
- [ ] Every `make <target>` in CLAUDE.md Quick Reference exists in Makefile
- [ ] No Makefile targets that should be documented but aren't

### Manually-Managed Containers
Services with `com.centurylinklabs.watchtower.enable=false` require manual upgrades. Currently:
- `postgres` — documented in CLAUDE.md and README Upgrade Procedures
- `redis` (valkey) — documented in CLAUDE.md and README Upgrade Procedures

If a new excluded container appears, flag it and prompt to add upgrade procedure.

---

## Validation Checklist

After updates:
- [ ] README stack table image names match compose files
- [ ] README.md Secrets section covers all vars (run: `grep -h '\${' compose*.yml scripts/*.sh | grep -oE '\$\{[A-Z_]+\}' | sort -u`)
- [ ] No stale service names (CrowdSec, WUD, etc.) remain anywhere
- [ ] Middleware names consistent across CLAUDE.md, README.md, and compose examples
- [ ] CLAUDE.md Quick Reference matches Makefile

---

## Output Format

```
## Documentation Audit

### Changes Found
- [file]: [specific stale or missing content]

### Changes Made
- README.md: [what was updated]
- CLAUDE.md: [what was updated]

### No Action Needed
- [item]: already accurate

### Flagged for Review
- New Watchtower-excluded container: [name] — add upgrade procedure?

Next: /commit
```
