#!/usr/bin/env bash
# =============================================================================
# HyperDX Slack webhook setup — idempotent, prod-only.
#
# Ensures a HyperDX webhook named "Slack #alerts" (service `slack`) exists,
# pointed at the incoming-webhook URL from op://common/slack/VPS_WEBHOOK_ALERTS.
# Create-or-update by NAME: a PUT rotates the URL if it already differs. Run
# this before `make hyperdx-apply` — alerts-as-code (scripts/hyperdx-sync.sh)
# resolves a `channel.webhook` reference against this webhook by name.
#
# Access key: $HYPERDX_PROD_ACCESS_KEY if set, else `op read
# op://vps/clickstack/AGENT_ACCESS_KEY` (same user provisioned by
# hyperdx-agent-setup.sh). Base URL: https://hyperdx.<DOMAIN> from
# op://vps/config/DOMAIN. Never prints the webhook URL or the access key.
#
# Usage: make hyperdx-webhook-setup   (ENV=prod, runs on the VPS host)
# =============================================================================
set -euo pipefail

WEBHOOK_NAME="Slack #alerts"

read_secret() {
  local ref="$1" hint="$2" val
  if ! val=$(op read "$ref" 2>/dev/null); then
    echo "ERROR: could not read ${ref} — ${hint}" >&2
    exit 1
  fi
  printf '%s' "$val"
}

if [[ -n "${HYPERDX_PROD_ACCESS_KEY:-}" ]]; then
  KEY="$HYPERDX_PROD_ACCESS_KEY"
else
  KEY=$(read_secret "op://vps/clickstack/AGENT_ACCESS_KEY" "run 'make hyperdx-agent-setup' first.")
fi

DOMAIN=$(read_secret "op://vps/config/DOMAIN" "check the vps vault's 'config' item.")
BASE="https://hyperdx.${DOMAIN}"

SLACK_URL=$(read_secret "op://common/slack/VPS_WEBHOOK_ALERTS" "create this field in 1Password first (common vault, item 'slack').")

BODY=$(WEBHOOK_NAME="$WEBHOOK_NAME" SLACK_URL="$SLACK_URL" python3 -c "
import json, os
print(json.dumps({
    'name': os.environ['WEBHOOK_NAME'],
    'service': 'slack',
    'url': os.environ['SLACK_URL'],
}))
")

EXISTING=$(curl -fsS "${BASE}/api/api/v2/webhooks" -H "Authorization: Bearer ${KEY}")
EXISTING_ID=$(WEBHOOK_NAME="$WEBHOOK_NAME" python3 -c "
import json, os, sys
name = os.environ['WEBHOOK_NAME']
data = json.loads(sys.stdin.read()).get('data', [])
match = next((w for w in data if w.get('name') == name), None)
print(match['id'] if match else '')
" <<<"$EXISTING")

if [[ -n "$EXISTING_ID" ]]; then
  curl -fsS -X PUT "${BASE}/api/api/v2/webhooks/${EXISTING_ID}" \
    -H "Authorization: Bearer ${KEY}" \
    -H "Content-Type: application/json" \
    --data-binary "$BODY" >/dev/null
  echo "webhook ok (${EXISTING_ID})"
else
  RESP=$(curl -fsS -X POST "${BASE}/api/api/v2/webhooks" \
    -H "Authorization: Bearer ${KEY}" \
    -H "Content-Type: application/json" \
    --data-binary "$BODY")
  NEW_ID=$(python3 -c "import json,sys; print(json.load(sys.stdin)['data']['id'])" <<<"$RESP")
  echo "webhook ok (${NEW_ID})"
fi
