#!/usr/bin/env bash
# =============================================================================
# VPS Firewall — UFW status and documentation
#
# UFW is the only programmatic firewall layer on this server.
# The hosting provider's panel firewall (zero inbound rules) must be configured
# manually via the control panel — there is no CLI tool for it.
#
# UFW rules (configured by setup.sh):
#   - Default: deny incoming, allow outgoing
#   - Allow all traffic on tailscale0 interface (SSH, OTel, monitoring)
#   - No ports 80/443 — public traffic enters via Cloudflare Tunnel (outbound)
# =============================================================================
set -euo pipefail

echo "=== UFW status ==="
ufw status verbose

echo ""
echo "=== Active rules ==="
ufw status numbered

echo ""
echo "Note: Public HTTP/HTTPS enters via Cloudflare Tunnel (outbound-only)."
echo "      SSH is accessible via Tailscale only."
echo "      Configure zero-inbound rules on the provider firewall via hosting panel."
