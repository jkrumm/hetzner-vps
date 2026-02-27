#!/usr/bin/env bash
# =============================================================================
# Cloudflare Tunnel ingress management
#
# Usage (always via doppler so the token never touches your shell):
#   doppler run -- ./scripts/cf-tunnel-ingress.sh get
#   doppler run -- ./scripts/cf-tunnel-ingress.sh set-wildcard
#   doppler run -- ./scripts/cf-tunnel-ingress.sh add-dns <subdomain>
#
# Required Doppler secrets (project: vps, config: prod):
#   CF_API_TOKEN  — needs Cloudflare Tunnel:Edit + DNS:Edit permissions
#   CF_ACCOUNT_ID     — Cloudflare account ID
#   CF_ZONE_ID        — Zone ID for DOMAIN
#   CF_TUNNEL_ID      — Tunnel UUID (from cloudflared logs or dashboard)
#   DOMAIN            — e.g. jkrumm.com
#
# All API calls are made inside this script. The token is read from the
# environment injected by doppler — never passed as a CLI argument or logged.
# =============================================================================
set -euo pipefail

: "${CF_API_TOKEN:?CF_API_TOKEN not set — run via: doppler run -- $0}"
: "${CF_ACCOUNT_ID:?CF_ACCOUNT_ID not set}"
: "${CF_ZONE_ID:?CF_ZONE_ID not set}"
: "${CF_TUNNEL_ID:?CF_TUNNEL_ID not set}"
: "${DOMAIN:?DOMAIN not set}"

API="https://api.cloudflare.com/client/v4"
AUTH=(-H "Authorization: Bearer ${CF_API_TOKEN}")

cf_api() {
  local method="$1" path="$2"; shift 2
  curl -s -X "${method}" "${API}${path}" "${AUTH[@]}" "$@"
}

cmd="${1:-help}"

case "${cmd}" in

  get)
    # Show current tunnel ingress configuration
    cf_api GET "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${CF_TUNNEL_ID}/configurations" \
      | python3 -m json.tool
    ;;

  set-wildcard)
    # Set *.DOMAIN → https://traefik:443 (noTLSVerify) as the catch-all ingress rule.
    #
    # This wildcard only matches requests that arrive at THIS tunnel (13f91961-...).
    # HomeLab and other subdomains have CNAMEs pointing to different tunnel IDs —
    # they never reach this tunnel, so they are unaffected by this rule.
    # The wildcard means: "anything DNS-routed to the VPS tunnel goes to Traefik."
    #
    # Run this once after provisioning, or to reset to the standard config.
    result=$(cf_api PUT "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${CF_TUNNEL_ID}/configurations" \
      -H "Content-Type: application/json" \
      --data "{
        \"config\": {
          \"ingress\": [
            {
              \"hostname\": \"*.${DOMAIN}\",
              \"service\": \"https://traefik:443\",
              \"originRequest\": { \"noTLSVerify\": true }
            },
            { \"service\": \"http_status:404\" }
          ]
        }
      }")
    echo "${result}" | python3 -c "
import json,sys
r=json.load(sys.stdin)
print('OK — version', r['result']['version']) if r['success'] else print('ERR:', r['errors'])
"
    ;;

  add-dns)
    # Add a proxied CNAME DNS record pointing <subdomain>.DOMAIN to the VPS tunnel.
    # Run this whenever a new app subdomain is needed.
    # Usage: doppler run -- ./scripts/cf-tunnel-ingress.sh add-dns rollhook-vps
    subdomain="${2:?Usage: $0 add-dns <subdomain>}"
    result=$(cf_api POST "/zones/${CF_ZONE_ID}/dns_records" \
      -H "Content-Type: application/json" \
      --data "{
        \"type\": \"CNAME\",
        \"name\": \"${subdomain}\",
        \"content\": \"${CF_TUNNEL_ID}.cfargotunnel.com\",
        \"proxied\": true
      }")
    echo "${result}" | python3 -c "
import json,sys
r=json.load(sys.stdin)
print('OK:', r['result']['name']) if r['success'] else print('ERR:', r['errors'])
"
    ;;

  help|*)
    echo "Usage: doppler run -- $0 <command>"
    echo ""
    echo "Commands:"
    echo "  get                  Show current tunnel ingress config"
    echo "  set-wildcard         Set *.DOMAIN → traefik:443 catch-all rule"
    echo "  add-dns <subdomain>  Add proxied CNAME for <subdomain>.DOMAIN → tunnel"
    ;;

esac
