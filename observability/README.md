# Observability — dashboards as code

`dashboards/*.json` is the on-disk source of truth for HyperDX dashboards.
**Mongo (the dashboard store inside `clickstack`) has no backup** — this
directory is the backup, and the only way to move a dashboard between dev and
prod.

Each file is one dashboard, named `<slug>.json` (slugified from the dashboard
name), with keys sorted and ids/timestamps/team stripped so the file is
env-portable — dashboard and tile ids are per-env Mongo ObjectIds and never
round-trip between dev and prod.

## Loop

```bash
# Pull every dashboard from an env down to this directory
make hyperdx-export ENV=dev
make hyperdx-export ENV=prod

# Edit dashboards/*.json by hand, or via HyperDX MCP tools against dev, then
# export again to capture the result.

# Validate + upsert (by dashboard NAME) from this directory into an env
make hyperdx-apply ENV=dev
make hyperdx-apply ENV=prod
```

`apply` runs `POST /dashboards/validate` on every file first and prints its
errors before touching anything. A dashboard whose name already exists in the
target env is updated in place (`PUT`); a new name is created (`POST`).

See `docs/observability.md` → "Agent access — MCP + REST" for the full HTTP
contract and the dedicated agent user this tooling authenticates as.
