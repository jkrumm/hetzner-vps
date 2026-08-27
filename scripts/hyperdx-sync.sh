#!/usr/bin/env bash
# =============================================================================
# HyperDX dashboards-as-code — REST v2, both envs.
#
# Mongo (the dashboard store) has no backup — observability/dashboards/*.json
# IS the backup. `export` pulls every dashboard down; `apply` validates and
# upserts (by NAME — HyperDX dashboard ids are per-env Mongo ObjectIds and
# don't round-trip) from those files back into an env.
#
# Usage:
#   scripts/hyperdx-sync.sh export <dev|prod>
#   scripts/hyperdx-sync.sh apply  <dev|prod> [file ...]   # default: every
#                                                            # *.json in
#                                                            # observability/dashboards/
#
# Env/key resolution:
#   dev  → ~/.config/hyperdx/local.env (HYPERDX_LOCAL_ACCESS_KEY), base
#          http://localhost:7707
#   prod → $HYPERDX_PROD_ACCESS_KEY if set, else `secrets-run read
#          op://vps/clickstack/AGENT_ACCESS_KEY` if secrets-run exists, else
#          `op read op://vps/clickstack/AGENT_ACCESS_KEY`. Base URL follows
#          the same ladder via $HYPERDX_PROD_BASE_URL / op://vps/config/DOMAIN.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DASH_DIR="${REPO_ROOT}/observability/dashboards"

usage() {
  echo "Usage: $0 export <dev|prod>" >&2
  echo "       $0 apply  <dev|prod> [file ...]" >&2
}

resolve_env() {
  case "$1" in
  dev)
    local file="${HOME}/.config/hyperdx/local.env"
    [[ -f "$file" ]] || {
      echo "ERROR: ${file} not found — run 'make hyperdx-dev-bootstrap' first." >&2
      exit 1
    }
    # shellcheck disable=SC1090
    source "$file"
    : "${HYPERDX_LOCAL_ACCESS_KEY:?missing HYPERDX_LOCAL_ACCESS_KEY in ${file} — run 'make hyperdx-dev-bootstrap'}"
    BASE="http://localhost:7707"
    KEY="$HYPERDX_LOCAL_ACCESS_KEY"
    ;;
  prod)
    if [[ -n "${HYPERDX_PROD_ACCESS_KEY:-}" ]]; then
      KEY="$HYPERDX_PROD_ACCESS_KEY"
    elif command -v secrets-run >/dev/null 2>&1; then
      KEY=$(secrets-run read "op://vps/clickstack/AGENT_ACCESS_KEY")
    else
      KEY=$(op read "op://vps/clickstack/AGENT_ACCESS_KEY")
    fi
    if [[ -n "${HYPERDX_PROD_BASE_URL:-}" ]]; then
      BASE="$HYPERDX_PROD_BASE_URL"
    elif command -v secrets-run >/dev/null 2>&1; then
      BASE="https://hyperdx.$(secrets-run read "op://vps/config/DOMAIN")"
    else
      BASE="https://hyperdx.$(op read "op://vps/config/DOMAIN")"
    fi
    ;;
  *)
    echo "ERROR: unknown env '$1' (expected dev|prod)" >&2
    exit 1
    ;;
  esac
}

cmd_export() {
  local env="$1"
  resolve_env "$env"
  mkdir -p "$DASH_DIR"

  local resp
  resp=$(curl -fsS "${BASE}/api/api/v2/dashboards" -H "Authorization: Bearer ${KEY}")

  HDX_RESP="$resp" HDX_DIR="$DASH_DIR" python3 <<'PY'
import json
import os
import re

STRIP_KEYS = {"id", "_id", "createdAt", "updatedAt", "team"}


def slugify(name):
    s = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    return s or "dashboard"


def strip(obj):
    if isinstance(obj, dict):
        return {k: strip(v) for k, v in obj.items() if k not in STRIP_KEYS}
    if isinstance(obj, list):
        return [strip(v) for v in obj]
    return obj


resp = json.loads(os.environ["HDX_RESP"])
out_dir = os.environ["HDX_DIR"]
dashboards = resp.get("data", [])
count = 0
for dash in dashboards:
    cleaned = strip(dash)
    slug = slugify(dash.get("name", "dashboard"))
    path = os.path.join(out_dir, f"{slug}.json")
    with open(path, "w") as f:
        json.dump(cleaned, f, indent=2, sort_keys=True)
        f.write("\n")
    count += 1
print(f"exported {count} dashboard(s) to {out_dir}")
PY
}

cmd_apply() {
  local env="$1"
  shift
  resolve_env "$env"

  local files=("$@")
  if [[ ${#files[@]} -eq 0 ]]; then
    shopt -s nullglob
    files=("$DASH_DIR"/*.json)
    shopt -u nullglob
  fi
  if [[ ${#files[@]} -eq 0 ]]; then
    echo "no dashboard files to apply"
    return 0
  fi

  local existing
  existing=$(curl -fsS "${BASE}/api/api/v2/dashboards" -H "Authorization: Bearer ${KEY}")

  local failed=0
  for file in "${files[@]}"; do
    echo "--> ${file}"

    local validate_resp valid
    validate_resp=$(curl -fsS -X POST "${BASE}/api/api/v2/dashboards/validate" \
      -H "Authorization: Bearer ${KEY}" \
      -H "Content-Type: application/json" \
      --data-binary @"$file")
    valid=$(python3 -c "import json,sys; print(json.load(sys.stdin)['valid'])" <<<"$validate_resp")

    if [[ "$valid" != "True" ]]; then
      echo "  ✗ invalid:"
      python3 -c "
import json, sys
for e in json.load(sys.stdin)['errors']:
    print(f\"    {e['path']}: {e['message']}\")
" <<<"$validate_resp"
      failed=1
      continue
    fi

    local name existing_id
    name=$(python3 -c "import json,sys; print(json.load(sys.stdin)['name'])" <"$file")
    existing_id=$(HDX_NAME="$name" python3 -c "
import json, os, sys
name = os.environ['HDX_NAME']
data = json.loads(sys.stdin.read()).get('data', [])
match = next((d for d in data if d.get('name') == name), None)
print(match['id'] if match else '')
" <<<"$existing")

    if [[ -n "$existing_id" ]]; then
      curl -fsS -X PUT "${BASE}/api/api/v2/dashboards/${existing_id}" \
        -H "Authorization: Bearer ${KEY}" \
        -H "Content-Type: application/json" \
        --data-binary @"$file" >/dev/null
      echo "  ✓ updated ${name} (${existing_id})"
    else
      curl -fsS -X POST "${BASE}/api/api/v2/dashboards" \
        -H "Authorization: Bearer ${KEY}" \
        -H "Content-Type: application/json" \
        --data-binary @"$file" >/dev/null
      echo "  ✓ created ${name}"
    fi
  done

  [[ "$failed" -eq 0 ]]
}

main() {
  [[ $# -ge 1 ]] || {
    usage
    exit 1
  }
  local sub="$1"
  shift
  case "$sub" in
  export)
    [[ $# -ge 1 ]] || {
      usage
      exit 1
    }
    cmd_export "$1"
    ;;
  apply)
    [[ $# -ge 1 ]] || {
      usage
      exit 1
    }
    local env="$1"
    shift
    cmd_apply "$env" "$@"
    ;;
  *)
    usage
    exit 1
    ;;
  esac
}

main "$@"
