#!/usr/bin/env bash
# =============================================================================
# Hetzner Cloud Firewall — IaC via hcloud CLI
# Idempotent: creates or replaces rules on the named firewall.
# Requires: hcloud CLI authenticated (hcloud auth login or HCLOUD_TOKEN env var)
# Usage: ./scripts/firewall.sh
#
# Zero inbound rules — this is intentional:
#   - Public HTTP/HTTPS traffic enters via Cloudflare Tunnel (outbound from VPS)
#   - SSH is accessible via Tailscale only (no public SSH rule)
#   - All inbound TCP/UDP from the internet is blocked by default
# =============================================================================
set -euo pipefail

FIREWALL_NAME="vps-firewall"

# Check for hcloud CLI
if ! command -v hcloud &>/dev/null; then
  echo "hcloud CLI not found. Install from: https://github.com/hetznercloud/cli"
  exit 1
fi

# Check for authentication
if ! hcloud server list &>/dev/null; then
  echo "hcloud CLI not authenticated. Run: hcloud auth login"
  exit 1
fi

echo "Applying firewall rules to: ${FIREWALL_NAME}"

# Create firewall if it doesn't exist
if ! hcloud firewall describe "${FIREWALL_NAME}" &>/dev/null; then
  echo "Creating firewall: ${FIREWALL_NAME}"
  hcloud firewall create --name "${FIREWALL_NAME}"
fi

# Zero inbound rules — all public ingress goes through Cloudflare Tunnel
hcloud firewall replace-rules "${FIREWALL_NAME}" \
  --rules-file - << 'RULES'
[]
RULES

echo "Firewall rules applied (zero inbound — deny all)."
echo "Note: SSH via Tailscale only. Public traffic via Cloudflare Tunnel only."
echo ""
echo "To apply this firewall to your server:"
echo "  hcloud firewall apply-to-resource --type server --server <server-name> ${FIREWALL_NAME}"
