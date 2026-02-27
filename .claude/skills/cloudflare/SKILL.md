---
name: cloudflare
description: Cloudflare API operations for the VPS — DNS records, tunnel ingress config, multi-domain and multi-zone support. Never exposes the API token to Claude Code directly.
---

# Cloudflare API Skill

Handle any Cloudflare DNS or tunnel operation for VPS-hosted apps.

**Execution model:** All API calls run on the VPS via `ssh vps "doppler run --project vps --config prod -- ..."`. The API token (`CF_API_TOKEN`) stays in Doppler — never passed as a CLI argument, never visible to Claude Code, never logged.

---

## Infrastructure Context

### VPS Tunnel

The VPS has a single Cloudflare Tunnel. Its ID is stored in Doppler as `CF_TUNNEL_ID`.

**Wildcard ingress rule:** `*.DOMAIN → https://traefik:443` (TLS verify: off)
- Set once after provisioning (see "Set wildcard tunnel ingress rule" below)
- Catches all subdomains that have a CNAME DNS record pointing to this tunnel
- Does NOT affect other Cloudflare tunnels (HomeLab, etc.) — each tunnel evaluates its own ingress rules independently

**To reach a new app publicly:**
1. Add a DNS CNAME record pointing the subdomain to this tunnel
2. The wildcard ingress rule already routes it to Traefik
3. Traefik routes based on the `Host()` label on the container

### Doppler Secrets (project: vps, config: prod)

| Secret | What it is |
|-|-|
| `CF_API_TOKEN` | API token with DNS:Edit + Cloudflare Tunnel:Edit for all zones. Passed to Traefik as `CF_DNS_API_TOKEN` (lego requires that name) |
| `CF_ACCOUNT_ID` | Cloudflare account ID (same for all zones/tunnels) |
| `CF_ZONE_ID` | Zone ID for the primary domain (`DOMAIN`) |
| `CF_TUNNEL_ID` | UUID of the VPS Cloudflare Tunnel |
| `DOMAIN` | Primary domain (e.g. example.com) |

### Multi-Domain / Multi-Zone Support

`CF_ZONE_ID` is the zone for the primary `DOMAIN`. For other domains:
1. Look up the zone ID via API (see below)
2. The same `CF_API_TOKEN` works as long as it's scoped to "All zones"

---

## Authentication Pattern

Always authenticate via Doppler. Construct API calls like this:

```bash
ssh vps "doppler run --project vps --config prod -- \
  curl -s -X GET 'https://api.cloudflare.com/client/v4/zones' \
    -H 'Authorization: Bearer \${CF_API_TOKEN}' \
    | python3 -m json.tool"
```

The `doppler run --` prefix injects all secrets as environment variables. `${CF_API_TOKEN}` is expanded by the shell on the VPS — never passed as a literal value.

---

## Common Operations

### Check current tunnel ingress config

```bash
ssh vps "doppler run --project vps --config prod -- \
  curl -s 'https://api.cloudflare.com/client/v4/accounts/\${CF_ACCOUNT_ID}/cfd_tunnel/\${CF_TUNNEL_ID}/configurations' \
    -H 'Authorization: Bearer \${CF_API_TOKEN}' \
    | python3 -m json.tool"
```

### Add a DNS CNAME record (new app subdomain)

```bash
ssh vps "doppler run --project vps --config prod -- \
  curl -s -X POST 'https://api.cloudflare.com/client/v4/zones/\${CF_ZONE_ID}/dns_records' \
    -H 'Authorization: Bearer \${CF_API_TOKEN}' \
    -H 'Content-Type: application/json' \
    --data '{\"type\":\"CNAME\",\"name\":\"<subdomain>\",\"content\":\"\${CF_TUNNEL_ID}.cfargotunnel.com\",\"proxied\":true}' \
    | python3 -c 'import json,sys; r=json.load(sys.stdin); print(\"OK:\",r[\"result\"][\"name\"]) if r[\"success\"] else print(\"ERR:\",r[\"errors\"])'"
```

### List DNS records for a zone

```bash
ssh vps "doppler run --project vps --config prod -- \
  curl -s 'https://api.cloudflare.com/client/v4/zones/\${CF_ZONE_ID}/dns_records?per_page=100' \
    -H 'Authorization: Bearer \${CF_API_TOKEN}' \
    | python3 -c 'import json,sys; [print(r[\"type\"],r[\"name\"],\"→\",r[\"content\"]) for r in json.load(sys.stdin)[\"result\"]]'"
```

### Delete a DNS record

First find the record ID from the list above, then:

```bash
ssh vps "doppler run --project vps --config prod -- \
  curl -s -X DELETE 'https://api.cloudflare.com/client/v4/zones/\${CF_ZONE_ID}/dns_records/<record-id>' \
    -H 'Authorization: Bearer \${CF_API_TOKEN}' \
    | python3 -c 'import json,sys; r=json.load(sys.stdin); print(\"OK\" if r[\"success\"] else r[\"errors\"])'"
```

### Look up Zone ID for a domain

Needed when working with a secondary domain (not stored in Doppler as `CF_ZONE_ID`):

```bash
ssh vps "doppler run --project vps --config prod -- \
  curl -s 'https://api.cloudflare.com/client/v4/zones?name=<other-domain.com>' \
    -H 'Authorization: Bearer \${CF_API_TOKEN}' \
    | python3 -c 'import json,sys; r=json.load(sys.stdin)[\"result\"]; print(r[0][\"id\"],r[0][\"name\"]) if r else print(\"not found\")'"
```

### Set/update wildcard tunnel ingress rule

```bash
ssh vps "doppler run --project vps --config prod -- \
  curl -s -X PUT 'https://api.cloudflare.com/client/v4/accounts/\${CF_ACCOUNT_ID}/cfd_tunnel/\${CF_TUNNEL_ID}/configurations' \
    -H 'Authorization: Bearer \${CF_API_TOKEN}' \
    -H 'Content-Type: application/json' \
    --data '{\"config\":{\"ingress\":[{\"hostname\":\"*.\${DOMAIN}\",\"service\":\"https://traefik:443\",\"originRequest\":{\"noTLSVerify\":true}},{\"service\":\"http_status:404\"}]}}'"
```

---

## Workflow: Add a New Public App

1. Deploy the app compose to VPS (confirm it's running: `make ps`)
2. Add DNS record (subdomain → VPS tunnel CNAME)
3. Verify: `curl -I https://myapp.<DOMAIN>/health`
4. No tunnel config changes needed — wildcard ingress already catches it

---

## Workflow: Add App on a Secondary Domain

When the app subdomain belongs to a different domain than `DOMAIN`:

1. Look up the zone ID for the secondary domain (see "Look up Zone ID" above)
2. Use it inline — zone IDs are not secret (visible in Cloudflare dashboard):
   ```bash
   SECONDARY_ZONE_ID=<found-zone-id>
   ssh vps "doppler run --project vps --config prod -- \
     curl -s -X POST 'https://api.cloudflare.com/client/v4/zones/${SECONDARY_ZONE_ID}/dns_records' \
       -H 'Authorization: Bearer \${CF_API_TOKEN}' \
       -H 'Content-Type: application/json' \
       --data '{\"type\":\"CNAME\",\"name\":\"myapp\",\"content\":\"\${CF_TUNNEL_ID}.cfargotunnel.com\",\"proxied\":true}' \
       | python3 -m json.tool"
   ```
3. If the secondary domain isn't covered by the wildcard, add a specific ingress rule to the tunnel config (add before the `http_status:404` catch-all)

---

## Useful Reference

CF API base: `https://api.cloudflare.com/client/v4`

| Endpoint | Method | Purpose |
|-|-|-|
| `/zones` | GET | List zones (filter: `?name=domain.com`) |
| `/zones/{zone_id}/dns_records` | GET | List DNS records |
| `/zones/{zone_id}/dns_records` | POST | Create DNS record |
| `/zones/{zone_id}/dns_records/{id}` | PUT | Update DNS record |
| `/zones/{zone_id}/dns_records/{id}` | DELETE | Delete DNS record |
| `/accounts/{account_id}/cfd_tunnel/{tunnel_id}/configurations` | GET | Get tunnel ingress config |
| `/accounts/{account_id}/cfd_tunnel/{tunnel_id}/configurations` | PUT | Replace tunnel ingress config |
| `/accounts/{account_id}/cfd_tunnel` | GET | List all tunnels |

All responses: `{"success": bool, "result": ..., "errors": [...]}`.
