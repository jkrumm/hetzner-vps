# Local Database Access (DataGrip / psql)

Postgres is Docker-internal — no ports exposed on the host. Access via SSH
tunnel over Tailscale.

## DataGrip

Create a new **PostgreSQL** data source:

**SSH/SSL tab → Use SSH tunnel:**

| Field | Value |
|-|-|
| Host | `<VPS_TAILSCALE_IP>` (from 1Password: `op read "op://vps/config/VPS_TAILSCALE_IP"`) |
| Port | `22` |
| Username | `jkrumm` |
| Auth type | Key pair |
| Private key | `~/.ssh/id_rsa` |

**General tab:**

| Field | Value |
|-|-|
| Host | `172.19.0.2` (Postgres container IP on the Docker bridge — fixed, doesn't change) |
| Port | `5432` |
| User | from 1Password: `op read "op://vps/config/POSTGRES_USER"` |
| Password | from 1Password: `op read "op://vps/postgres/PASSWORD"` |
| Database | from 1Password: `op read "op://vps/config/POSTGRES_DB"` |

> **Why not `postgres` as host?** DataGrip resolves the DB hostname locally
> before establishing the tunnel. `postgres` only resolves inside Docker
> networks, not on the VPS host. Use the container's bridge IP instead.

## psql via terminal

```bash
ssh -L 5432:172.19.0.2:5432 vps   # keep open
psql -h localhost -p 5432 -U $(op read "op://vps/config/POSTGRES_USER") postgres
```
