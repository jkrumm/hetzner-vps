#!/usr/bin/env bash
# =============================================================================
# HyperDX local dev bootstrap — idempotent, dev-only.
#
# Ensures ~/.config/hyperdx/local.env exists (generating dev@hyperdx.test + a
# policy-compliant password if missing), registers the first HyperDX user if
# Mongo is empty, then writes/refreshes HYPERDX_LOCAL_ACCESS_KEY from Mongo
# into the file. Re-running when everything already matches is a no-op
# besides the closing smoke test.
#
# Usage: make hyperdx-dev-bootstrap   (ENV=dev)
# =============================================================================
set -euo pipefail

BASE="http://localhost:7707"
FILE="${HOME}/.config/hyperdx/local.env"

docker inspect -f '{{.State.Status}}' clickstack >/dev/null 2>&1 || {
  echo "ERROR: local 'clickstack' container not running. Run 'make up' first." >&2
  exit 1
}

# Guards against JS-injection into the mongo --eval strings built below.
sanitize() {
  local val="$1"
  if [[ ! "$val" =~ ^[A-Za-z0-9@._-]+$ ]]; then
    echo "ERROR: unexpected characters in a value used inside a Mongo eval query" >&2
    exit 1
  fi
  printf '%s' "$val"
}

# Upsert KEY=VALUE in FILE — in place, portable across BSD and GNU sed (both
# accept `-i.bak` with an explicit suffix; only bare `-i` differs between them).
set_env_var() {
  local file="$1" key="$2" value="$3"
  if grep -q "^${key}=" "$file" 2>/dev/null; then
    sed -i.bak "s|^${key}=.*|${key}=${value}|" "$file" && rm -f "${file}.bak"
  else
    echo "${key}=${value}" >>"$file"
  fi
}

# ---------------------------------------------------------------------------
# 1. Ensure the credentials file exists.
# ---------------------------------------------------------------------------
if [[ ! -f "$FILE" ]]; then
  mkdir -p "$(dirname "$FILE")"
  PASSWORD="Hdx!$(openssl rand -hex 12)Z"
  cat >"$FILE" <<EOF
HYPERDX_LOCAL_EMAIL=dev@hyperdx.test
HYPERDX_LOCAL_PASSWORD=${PASSWORD}
EOF
  chmod 600 "$FILE"
  echo "generated ${FILE}"
fi

# shellcheck disable=SC1090
source "$FILE"
: "${HYPERDX_LOCAL_EMAIL:?missing HYPERDX_LOCAL_EMAIL in $FILE}"
: "${HYPERDX_LOCAL_PASSWORD:?missing HYPERDX_LOCAL_PASSWORD in $FILE}"
HYPERDX_LOCAL_EMAIL=$(sanitize "$HYPERDX_LOCAL_EMAIL")

mongo_eval() {
  docker exec clickstack mongo --quiet hyperdx --eval "$1"
}

# ---------------------------------------------------------------------------
# 2. Register the first user only if Mongo has none yet.
# ---------------------------------------------------------------------------
USER_COUNT_JSON=$(mongo_eval "print(JSON.stringify({count: db.users.countDocuments({})}))")
USER_COUNT=$(python3 -c "import json,sys; print(json.load(sys.stdin)['count'])" <<<"$USER_COUNT_JSON")

if [[ "$USER_COUNT" == "0" ]]; then
  # Password goes through an env var (not argv, not a bash-interpolated JSON
  # literal) and the request body through a heredoc (not a curl argv) so it
  # never appears in `ps`.
  BODY=$(HDX_EMAIL="$HYPERDX_LOCAL_EMAIL" HDX_PW="$HYPERDX_LOCAL_PASSWORD" python3 -c "
import json, os, sys
sys.stdout.write(json.dumps({
    'email': os.environ['HDX_EMAIL'],
    'password': os.environ['HDX_PW'],
    'confirmPassword': os.environ['HDX_PW'],
}))
")
  HTTP_CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "${BASE}/api/register/password" \
    -H "Content-Type: application/json" \
    --data-binary @- <<EOF
$BODY
EOF
)
  if [[ "$HTTP_CODE" != "200" ]]; then
    echo "ERROR: POST /api/register/password returned HTTP ${HTTP_CODE} (expected 200)" >&2
    exit 1
  fi
  echo "registered first user: ${HYPERDX_LOCAL_EMAIL}"
fi

# ---------------------------------------------------------------------------
# 3. Refresh HYPERDX_LOCAL_ACCESS_KEY from Mongo.
# ---------------------------------------------------------------------------
USER_JSON=$(mongo_eval "print(JSON.stringify(db.users.findOne({email:'${HYPERDX_LOCAL_EMAIL}'},{accessKey:1,_id:0})))")
if [[ "$USER_JSON" == "null" ]]; then
  echo "ERROR: user ${HYPERDX_LOCAL_EMAIL} not found in Mongo after bootstrap" >&2
  exit 1
fi
ACCESS_KEY=$(python3 -c "import json,sys; print(json.load(sys.stdin)['accessKey'])" <<<"$USER_JSON")

set_env_var "$FILE" HYPERDX_LOCAL_ACCESS_KEY "$ACCESS_KEY"
chmod 600 "$FILE"
echo "accessKey ok"

# ---------------------------------------------------------------------------
# 4. Smoke test — MCP initialize.
# ---------------------------------------------------------------------------
RESP=$(curl -fsS -X POST "${BASE}/api/mcp" \
  -H "Authorization: Bearer ${ACCESS_KEY}" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"vps-dev-bootstrap","version":"1.0.0"}}}')

python3 -c "
import json, sys
resp = sys.stdin.read()
line = next((l for l in resp.splitlines() if l.startswith('data: ')), None)
if not line:
    print('ERROR: no MCP data line in response', file=sys.stderr)
    sys.exit(1)
info = json.loads(line[6:]).get('result', {}).get('serverInfo', {})
print(f\"MCP serverInfo: {info.get('name')} {info.get('version')}\")
" <<<"$RESP"
