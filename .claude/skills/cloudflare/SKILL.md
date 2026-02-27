---
name: cloudflare
description: Cloudflare API operations for the VPS — DNS records, tunnel ingress config, multi-domain and multi-zone support. Never exposes the API token to Claude Code directly.
---

# Cloudflare API Skill

Handle any Cloudflare DNS or tunnel operation for VPS-hosted apps.

**Execution model:** All API calls run on the VPS via `ssh vps 'doppler run --project vps --config prod -- bash -c '"'"'...'"'"''`. The API token (`CF_API_TOKEN`) stays in Doppler — never passed as a CLI argument, never visible to Claude Code, never logged.

---

## Infrastructure Context

### VPS Tunnel

The VPS has a single Cloudflare Tunnel. Its ID is stored in Doppler as `CF_TUNNEL_ID`.

**Current tunnel IDs visible in jkrumm.com DNS:**
- `13f91961-...` — VPS (this server)
- `f270cecf-...` — HomeLab
- `b99c010f-...` — other server

**Wildcard ingress rule:** `*.DOMAIN → https://traefik:443` (TLS verify: off)
- Set once after provisioning
- Catches all subdomains that have a CNAME DNS record pointing to this tunnel
- Does NOT affect other Cloudflare tunnels — each tunnel evaluates its own ingress rules independently

**To reach a new app publicly:**
1. Add a DNS CNAME record pointing the subdomain to `${CF_TUNNEL_ID}.cfargotunnel.com`
2. The wildcard ingress rule already routes it to Traefik
3. Traefik routes based on the `Host()` label on the container

### Doppler Secrets (project: vps, config: prod)

| Secret | What it is |
|-|-|
| `CF_API_TOKEN` | API token — Zone:Read + DNS:Edit (all zones) + Tunnel:Edit (all accounts). Passed to Traefik as `CF_DNS_API_TOKEN` (lego requires that name) |
| `CF_ACCOUNT_ID` | Cloudflare account ID (same for all zones/tunnels) |
| `CF_ZONE_ID` | Zone ID for `DOMAIN` (jkrumm.com) |
| `CF_TUNNEL_ID` | UUID of the VPS Cloudflare Tunnel |
| `DOMAIN` | Primary domain |

### Multi-Domain / Multi-Zone Support

Domains accessible with this token: `basalt-ui.com`, `jkrumm.com`, `rollhook.com`, `shutterflow.app`. For any domain not stored as `CF_ZONE_ID`, look up its zone ID first (see below).

---

## Authentication Pattern

Use single-quote wrapping so `${VARS}` are expanded by the VPS shell after doppler injects them:

```bash
ssh vps 'doppler run --project vps --config prod -- bash -c '"'"'
  curl -s "https://api.cloudflare.com/client/v4/zones" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    | python3 -m json.tool
'"'"''
```

**Why:** Double-quote SSH commands cause the local shell to expand `${CF_API_TOKEN}` before it reaches the VPS (producing empty string and an auth error). The `'...' '"'"' '...'` pattern passes the inner string literally to the VPS where doppler has already injected the secrets.

---

## Common Operations

### List all zones

```bash
ssh vps 'doppler run --project vps --config prod -- bash -c '"'"'curl -s "https://api.cloudflare.com/client/v4/zones" -H "Authorization: Bearer ${CF_API_TOKEN}" | python3 -c "import json,sys; r=json.load(sys.stdin); [print(z[\"name\"],z[\"id\"]) for z in r[\"result\"]] if r[\"success\"] else print(\"ERR:\",r[\"errors\"])"'"'"''
```

### Check current tunnel ingress config

```bash
ssh vps 'doppler run --project vps --config prod -- bash -c '"'"'curl -s "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${CF_TUNNEL_ID}/configurations" -H "Authorization: Bearer ${CF_API_TOKEN}" | python3 -c "import json,sys; r=json.load(sys.stdin); [print(i.get(\"hostname\",\"catch-all\"),\"→\",i[\"service\"]) for i in r[\"result\"][\"config\"][\"ingress\"]] if r[\"success\"] else print(\"ERR:\",r[\"errors\"])"'"'"''
```

### List DNS records for a zone

```bash
ssh vps 'doppler run --project vps --config prod -- bash -c '"'"'curl -s "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?per_page=100" -H "Authorization: Bearer ${CF_API_TOKEN}" | python3 -c "import json,sys; r=json.load(sys.stdin); [print(rec[\"type\"],rec[\"name\"],\"→\",rec[\"content\"]) for rec in r[\"result\"]] if r[\"success\"] else print(\"ERR:\",r[\"errors\"])"'"'"''
```

### Add a DNS CNAME record (new app subdomain on primary domain)

```bash
ssh vps 'doppler run --project vps --config prod -- bash -c '"'"'curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" --data "{\"type\":\"CNAME\",\"name\":\"SUBDOMAIN\",\"content\":\"${CF_TUNNEL_ID}.cfargotunnel.com\",\"proxied\":true}" | python3 -c "import json,sys; r=json.load(sys.stdin); print(\"OK:\",r[\"result\"][\"name\"]) if r[\"success\"] else print(\"ERR:\",r[\"errors\"])"'"'"''
```

Replace `SUBDOMAIN` with the actual subdomain before running.

### Delete a DNS record

First list records to find the ID, then:

```bash
ssh vps 'doppler run --project vps --config prod -- bash -c '"'"'curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/RECORD_ID" -H "Authorization: Bearer ${CF_API_TOKEN}" | python3 -c "import json,sys; r=json.load(sys.stdin); print(\"OK\" if r[\"success\"] else r[\"errors\"])"'"'"''
```

### Look up Zone ID for a secondary domain

```bash
ssh vps 'doppler run --project vps --config prod -- bash -c '"'"'curl -s "https://api.cloudflare.com/client/v4/zones?name=other-domain.com" -H "Authorization: Bearer ${CF_API_TOKEN}" | python3 -c "import json,sys; r=json.load(sys.stdin)[\"result\"]; print(r[0][\"id\"],r[0][\"name\"]) if r else print(\"not found\")"'"'"''
```

### Set/update wildcard tunnel ingress rule

```bash
ssh vps 'doppler run --project vps --config prod -- bash -c '"'"'curl -s -X PUT "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${CF_TUNNEL_ID}/configurations" -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" --data "{\"config\":{\"ingress\":[{\"hostname\":\"*.${DOMAIN}\",\"service\":\"https://traefik:443\",\"originRequest\":{\"noTLSVerify\":true}},{\"service\":\"http_status:404\"}]}}" | python3 -c "import json,sys; r=json.load(sys.stdin); print(\"OK — version\",r[\"result\"][\"version\"]) if r[\"success\"] else print(\"ERR:\",r[\"errors\"])"'"'"''
```

---

## Workflow: Add a New Public App

1. Deploy the app compose to VPS (confirm running: `make ps`)
2. Add DNS CNAME record (subdomain → VPS tunnel)
3. Verify: `curl -I https://myapp.<DOMAIN>/health`
4. No tunnel config changes needed — wildcard ingress already catches it

## Workflow: Add App on a Secondary Domain

1. Look up the zone ID for the secondary domain
2. Use it directly in the curl call — zone IDs are not secret (visible in the Cloudflare dashboard)
3. If the secondary domain isn't covered by the wildcard ingress, add a specific hostname rule to the tunnel config before the `http_status:404` catch-all

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
