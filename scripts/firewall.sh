#!/usr/bin/env bash
# =============================================================================
# Hetzner Cloud Firewall — IaC via hcloud CLI
# Idempotent: creates or replaces rules on the named firewall.
# Requires: hcloud CLI authenticated (hcloud auth login or HCLOUD_TOKEN env var)
# Usage: ./scripts/firewall.sh
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

# Apply rules (replace-rules is idempotent)
hcloud firewall replace-rules "${FIREWALL_NAME}" \
  --rules-file - << 'RULES'
[
  {
    "direction": "in",
    "port": "80",
    "protocol": "tcp",
    "source_ips": ["0.0.0.0/0", "::/0"],
    "description": "HTTP (Traefik redirect to HTTPS)"
  },
  {
    "direction": "in",
    "port": "443",
    "protocol": "tcp",
    "source_ips": ["0.0.0.0/0", "::/0"],
    "description": "HTTPS (Traefik)"
  }
]
RULES

echo "Firewall rules applied."
echo "Note: SSH is NOT exposed publicly. Access via Tailscale only."
echo ""
echo "To apply this firewall to your server:"
echo "  hcloud firewall apply-to-resource --type server --server <server-name> ${FIREWALL_NAME}"
